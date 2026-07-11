// possessio-radar — pumptape.ts: Layers 2+3 of the latency ladder.
//
// Layer 3 (real-time): a Durable Object holding PumpPortal's WebSocket
// (wss://pumpportal.fun/api/data) — per-TRADE data, sub-second. Layer 2
// (degraded mode): the DO's 30s alarm is a watchdog that reconnects a dead
// socket; while the socket is down, Layer 1 (the cron poller in screen.ts)
// keeps the tape alive at 15s. Each layer is the fallback of the one above.
//
// WHY (ledger verdict, 2026-07-11): at 15s resolution the 4-8k band is
// structurally untradable — 0/118 targets, and the real runners cross
// 4k->20k inside one tick ('gap'). Only trade-level data can (a) see the
// crossing within ~1s and (b) read flow QUALITY — steady accumulation across
// many distinct buyers vs one whale spike — which is the hypothesized
// separator between the $20k runners and the 6-8k spike-and-dump trap.
//
// VERIFY-FIRST STATUS: the sandbox cannot reach pumpportal.fun (proxy 403),
// so the live gate executes THROUGH this deployment: the DO ships observing,
// /radar/ws-status exposes connection state + parse rate + raw samples, and
// the message normalizer below is DEFENSIVE (multiple field spellings, a
// lamports-vs-SOL heuristic) until real samples pin the shape. Flow metrics
// are only written when fields parse to finite numbers — never guessed.
//
// §4 COMPLIANCE unchanged: no keys, no orders. This observes and writes rows.

import type { WatcherEnv } from "./watcher";

const TRACK_MAX_AGE_MS = 8 * 60_000;   // stop caring after the §1 window closes
const PLAY_TARGET_USD  = 8_000;        // §0 v2 — same ratified rule, real resolution
const PLAY_HIT_USD     = 4_000;
const PLAY_EXIT_AGE_MS = 2 * 60_000;
const ALARM_EVERY_MS   = 30_000;
const STALE_SOCKET_MS  = 90_000;

type Coin = {
  createdMs: number;
  symbol: string | null;
  name: string | null;
  buys: number;
  sells: number;
  solNet: number;                       // net SOL flow since create (buys - sells)
  buyerSol: Map<string, number>;        // trader -> cumulative SOL bought (cap 500)
  mcSol: number | null;                 // last seen marketCap in SOL
  hit4kMs: number | null;
  resolved: boolean;
};

function num(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

export class PumpTape {
  state: DurableObjectState;
  env: WatcherEnv;
  ws: WebSocket | null = null;
  solUsd = 0;                           // pushed by screenScan from verified pump.fun fields
  coins = new Map<string, Coin>();
  rawSamples: string[] = [];
  stats = {
    connects: 0, msgs: 0, parsed: 0, births: 0, trades: 0,
    hits: 0, targets: 0, exits: 0, gaps: 0, noPrice: 0,
    lastMsgMs: 0, lastConnectMs: 0, d1Errors: 0,
  };

  constructor(state: DurableObjectState, env: WatcherEnv) {
    this.state = state;
    this.env = env;
  }

  async fetch(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    if (path === "/ensure") {
      await this.ensure();
      return Response.json({ connected: this.ws !== null });
    }
    if (path === "/solusd" && req.method === "POST") {
      const j: any = await req.json().catch(() => null);
      const p = num(j?.solUsd);
      if (p !== null && p > 0) this.solUsd = p;
      return Response.json({ solUsd: this.solUsd });
    }
    if (path === "/status") {
      return Response.json({
        connected: this.ws !== null,
        solUsd: this.solUsd,
        tracked: this.coins.size,
        stats: this.stats,
        rawSamples: this.rawSamples,   // the VERIFY-FIRST surface: pin the shape from these
      });
    }
    return new Response("not found", { status: 404 });
  }

  async ensure(): Promise<void> {
    if (this.ws) return;
    const url = (this.env as any).PUMPPORTAL_WS_URL || "wss://pumpportal.fun/api/data";
    try {
      // Workers outbound WebSocket: fetch with Upgrade, then accept().
      const resp = await fetch(url.replace(/^wss:/, "https:"), {
        headers: { Upgrade: "websocket" },
      });
      const ws = (resp as any).webSocket as WebSocket | null;
      if (!ws) {
        console.error("pumptape: no webSocket in response", resp.status);
        return;
      }
      ws.accept();
      ws.addEventListener("message", (e: MessageEvent) => this.onMessage(e.data));
      ws.addEventListener("close", () => { this.ws = null; });
      ws.addEventListener("error", () => { this.ws = null; });
      ws.send(JSON.stringify({ method: "subscribeNewToken" }));
      this.ws = ws;
      this.stats.connects++;
      this.stats.lastConnectMs = Date.now();
      this.stats.lastMsgMs = Date.now();
    } catch (e) {
      console.error("pumptape connect", e);
      this.ws = null;
    }
    const cur = await this.state.storage.getAlarm();
    if (cur === null) await this.state.storage.setAlarm(Date.now() + ALARM_EVERY_MS);
  }

  // Layer 2: the watchdog. Reconnect a dead/stale socket, sweep unresolved
  // plays past their 2:00 bell, prune coins past the tracking window.
  async alarm(): Promise<void> {
    const now = Date.now();
    if (this.ws && now - this.stats.lastMsgMs > STALE_SOCKET_MS) {
      try { this.ws.close(); } catch {}
      this.ws = null;
    }
    if (!this.ws) await this.ensure();

    const pruned: string[] = [];
    for (const [mint, c] of this.coins) {
      if (c.hit4kMs && !c.resolved && now - c.createdMs >= PLAY_EXIT_AGE_MS) {
        this.resolvePlay(mint, c, "exit2m", now);
      }
      if (now - c.createdMs > TRACK_MAX_AGE_MS) {
        pruned.push(mint);
        this.coins.delete(mint);
      }
    }
    if (pruned.length && this.ws) {
      try {
        this.ws.send(JSON.stringify({ method: "unsubscribeTokenTrade", keys: pruned }));
      } catch {}
    }
    await this.state.storage.setAlarm(now + ALARM_EVERY_MS);
  }

  onMessage(data: unknown): void {
    const now = Date.now();
    this.stats.msgs++;
    this.stats.lastMsgMs = now;
    const text = typeof data === "string" ? data : "";
    if (this.rawSamples.length < 8) this.rawSamples.push(text.slice(0, 500));
    let j: any;
    try { j = JSON.parse(text); } catch { return; }
    const mint: string | undefined = j.mint ?? j.token ?? j.ca;
    if (!mint) return;
    this.stats.parsed++;
    const txType: string = j.txType ?? j.type ?? "";

    if (txType === "create") {
      this.stats.births++;
      if (!this.coins.has(mint)) {
        this.coins.set(mint, {
          createdMs: now,
          symbol: j.symbol ?? null,
          name: j.name ?? null,
          buys: 0, sells: 0, solNet: 0,
          buyerSol: new Map(),
          mcSol: num(j.marketCapSol ?? j.market_cap_sol),
          hit4kMs: null, resolved: false,
        });
        if (this.ws) {
          try { this.ws.send(JSON.stringify({ method: "subscribeTokenTrade", keys: [mint] })); } catch {}
        }
      }
      return;
    }

    if (txType !== "buy" && txType !== "sell") return;
    const c = this.coins.get(mint);
    if (!c) return; // trade for a coin we never saw born (pre-connect) — skip
    this.stats.trades++;

    // lamports-vs-SOL heuristic until raw samples pin the unit: a single
    // pump.fun trade above 100k "SOL" does not exist; that magnitude is lamports.
    let sol = num(j.solAmount ?? j.sol_amount) ?? 0;
    if (sol > 100_000) sol = sol / 1e9;
    const mcSol = num(j.marketCapSol ?? j.market_cap_sol);
    if (mcSol !== null) c.mcSol = mcSol;
    const trader: string = j.traderPublicKey ?? j.trader ?? "";

    if (txType === "buy") {
      c.buys++;
      c.solNet += sol;
      if (trader && c.buyerSol.size < 500) {
        c.buyerSol.set(trader, (c.buyerSol.get(trader) ?? 0) + sol);
      }
    } else {
      c.sells++;
      c.solNet -= sol;
    }

    // ---- §0 v2, at trade resolution ----
    if (this.solUsd <= 0) { this.stats.noPrice++; return; }
    if (c.mcSol === null) return;
    const usd = c.mcSol * this.solUsd;
    const age = now - c.createdMs;

    if (c.hit4kMs === null && usd >= PLAY_HIT_USD && age <= TRACK_MAX_AGE_MS) {
      c.hit4kMs = now;
      this.stats.hits++;
      this.recordHit(mint, c, usd, now);
      return; // crossing trade scored on the NEXT trade — entry can't also be exit
    }
    if (c.hit4kMs !== null && !c.resolved) {
      if (usd >= PLAY_TARGET_USD) this.resolvePlay(mint, c, "target", now, usd);
      else if (age >= PLAY_EXIT_AGE_MS) this.resolvePlay(mint, c, "exit2m", now, usd);
    }
  }

  // The $4k crossing, with the flow-quality read an agent would decide on:
  // everything that happened between create and this moment.
  recordHit(mint: string, c: Coin, usd: number, now: number): void {
    const ageSec = Math.round((now - c.createdMs) / 1000);
    let buySol = 0, topSol = 0;
    for (const v of c.buyerSol.values()) { buySol += v; if (v > topSol) topSol = v; }
    const topShare = buySol > 0 ? topSol / buySol : null;
    // Detected already at/above target -> 'gap', same honest-tally rule as v1.
    const gap = usd >= PLAY_TARGET_USD;
    if (gap) { c.resolved = true; this.stats.gaps++; }
    // fire-and-forget with its own catch — the DO stays alive on the socket,
    // and depending on state.waitUntil (deprecated) would risk a runtime TypeError
    void (
      this.env.RADAR_DB.prepare(
        `INSERT INTO earlies
           (token_address, symbol, name, first_hit_ms, first_hit_mc, age_sec_at_hit,
            status, ws, t4k_ms, buys_hit, sells_hit, sol_net_hit, uniq_buyers_hit,
            top_buyer_share, play_outcome, play_exit_mc, play_outcome_ms)
         VALUES (?1,?2,?3,?4,?5,?6,'watching',1,?7,?8,?9,?10,?11,?12,?13,?14,?15)
         ON CONFLICT(token_address) DO UPDATE SET
           ws=1, t4k_ms=?7, buys_hit=?8, sells_hit=?9, sol_net_hit=?10,
           uniq_buyers_hit=?11, top_buyer_share=?12`
      ).bind(
        mint, c.symbol, c.name, now, usd, ageSec,
        now - c.createdMs, c.buys, c.sells, Math.round(c.solNet * 1000) / 1000,
        c.buyerSol.size, topShare,
        gap ? "gap" : null, gap ? usd : null, gap ? now : null,
      ).run().catch((e) => { this.stats.d1Errors++; console.error("pumptape hit", e); })
    );
  }

  resolvePlay(mint: string, c: Coin, outcome: "target" | "exit2m", now: number, usd?: number): void {
    c.resolved = true;
    if (outcome === "target") this.stats.targets++; else this.stats.exits++;
    const exitMc = usd ?? (c.mcSol !== null && this.solUsd > 0 ? c.mcSol * this.solUsd : null);
    void (
      this.env.RADAR_DB.prepare(
        `UPDATE earlies SET play_outcome=?2, play_exit_mc=?3, play_outcome_ms=?4
          WHERE token_address=?1 AND play_outcome IS NULL`
      ).bind(mint, outcome, exitMc, now)
        .run().catch((e) => { this.stats.d1Errors++; console.error("pumptape resolve", e); })
    );
  }
}
