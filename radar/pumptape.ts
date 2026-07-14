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

// §0 v3 — THE LADDER (Architect-ratified 2026-07-11): buy the $3,500
// crossing; scale out 50% @ $6k, 25% @ $8k, 12.5% @ $10k, 12.5% @ $12k
// (fractions sum to 1.0, verified); whatever remains unsold exits at the
// age-2:00 bell at market. Rungs fill AT the rung price (a market-sell
// triggered at >=rung fills at-or-above it, so rung price is the
// conservative-honest paper fill). Full ladder = 2.21x on a $3.5k entry;
// rung 1 alone floors the trade near 0.86x — the first sell pays for the
// ticket. Detected already at/past rung 1 -> 'gap' (no honest entry).
const PLAY_HIT_USD     = 3_500;
const RUNG_FRACS = [0.5, 0.25, 0.125, 0.125];
const L1_RUNGS = [6_000, 8_000, 10_000, 12_000];

// THE CYCLE (Architect, same ratification): if a ladder completes fully
// before its bell, wait for A DIP, re-buy, and run the next ladder one
// octave up — L2 sells toward $20k (14/16/18/20k), L3 toward $28k
// (22/24/26/28k), "continue that trend all the way up." Proceeds fully
// reinvest at each re-entry, so the play compounds. DESIGN CALLS (flagged,
// ledger-tunable §7): a dip = 15% retrace from the post-ladder peak; each
// level gets its own 2:00 bell from its entry; the whole cycle caps at the
// 8min tracking window (graduation takes the tape to the DEX anyway).
const DIP_FRAC         = 0.85;
function rungsFor(level: number): number[] {
  if (level <= 1) return L1_RUNGS;
  const base = 12_000 + 8_000 * (level - 2); // top of the previous ladder
  return [base + 2_000, base + 4_000, base + 6_000, base + 8_000];
}

const PLAY_EXIT_AGE_MS = 2 * 60_000;
const ALARM_EVERY_MS   = 30_000;
const STALE_SOCKET_MS  = 90_000;
// R-6 (AUDIT 2026-07-14): the WS-upgrade fetch is a fetch like any other and
// obeys the same bounded-fetch law as watcher.ts/screen.ts — a hung upgrade
// must throw, never hang the alarm handler that called it.
const WS_CONNECT_TIMEOUT_MS = 10_000;

type Coin = {
  createdMs: number;
  symbol: string | null;
  name: string | null;
  buys: number;
  sells: number;
  solNet: number;                       // net SOL flow since create (buys - sells)
  buyerSol: Map<string, number>;        // trader -> cumulative SOL bought (cap 500)
  mcSol: number | null;                 // last seen marketCap in SOL
  hit4kMs: number | null;               // the $3.5k crossing (column name t4k_ms is historical)
  // ---- cycle state ----
  level: number;                        // 1-based ladder level
  levelEntryMc: number;                 // this level's entry (crossing or dip re-buy)
  levelEntryMs: number;                 // this level's bell starts here
  mode: "holding" | "awaiting_dip";
  dipPeak: number;                      // post-ladder peak while awaiting the dip
  compoundMult: number;                 // Π level multiples (full reinvestment)
  rungIdx: number;                      // next unfilled rung in this level
  soldFrac: number;                     // fraction scaled out this level
  soldValue: number;                    // Σ frac × rung MC this level (blended exit)
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
    // ARM THE WATCHDOG FIRST (R-6): the upgrade fetch below is fallible —
    // before it was timed, a hang here could consume a fired alarm's handler
    // and die before re-arming, leaving the DO with NO alarm at all: a dead
    // watchdog that every per-minute cron poke then re-entered. Alarm before
    // any fallible work, so the worst case is a wasted 30s tick, never silence.
    const cur = await this.state.storage.getAlarm();
    if (cur === null) await this.state.storage.setAlarm(Date.now() + ALARM_EVERY_MS);
    if (this.ws) return;
    // SHAPE PINNED (live samples via /radar/ws-status, 2026-07-11):
    // subscribeNewToken is FREE and answers anonymously; subscribeTokenTrade /
    // subscribeAccountTrade require an API key funded with >=0.02 SOL (their
    // own error message). Key rides the URL. Set it as a Worker secret:
    //   npx wrangler secret put PUMPPORTAL_API_KEY
    let url = (this.env as any).PUMPPORTAL_WS_URL || "wss://pumpportal.fun/api/data";
    const key = (this.env as any).PUMPPORTAL_API_KEY;
    if (key) url += (url.includes("?") ? "&" : "?") + "api-key=" + key;
    try {
      // Workers outbound WebSocket: fetch with Upgrade, then accept().
      // Timed (R-6): a hung upgrade throws into the catch below instead of
      // freezing whichever caller (alarm or cron poke) awaited ensure().
      const resp = await fetch(url.replace(/^wss:/, "https:"), {
        headers: { Upgrade: "websocket" },
        signal: AbortSignal.timeout(WS_CONNECT_TIMEOUT_MS),
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
      // subscribeNewToken is FREE and keyless (verified live). It carries the
      // DEV BUY on every create event — buyer #1's size and share — which is
      // real, actionable birth intelligence at zero cost. The trade stream
      // stays gated behind a funded key; we deliberately DON'T pay for it, so
      // the ladder is scored on the free 15s tape (screen.ts) instead. If a
      // funded key ever appears, per-coin trade subs light up automatically.
      ws.send(JSON.stringify({ method: "subscribeNewToken" }));
      this.ws = ws;
      this.stats.connects++;
      this.stats.lastConnectMs = Date.now();
      this.stats.lastMsgMs = Date.now();
    } catch (e) {
      console.error("pumptape connect", e);
      this.ws = null;
    }
    // (alarm already armed at the top — see R-6 note)
  }

  // Layer 2: the watchdog. Reconnect a dead/stale socket, sweep unresolved
  // plays past their 2:00 bell, prune coins past the tracking window.
  async alarm(): Promise<void> {
    const now = Date.now();
    // RE-ARM FIRST (R-6): everything below can throw or hang (ensure()'s
    // upgrade fetch, D1 writes), and a fired alarm is CONSUMED — if this
    // handler died before setting the next one, the chain was dead and the
    // watchdog with it. setAlarm before the fallible work makes the chain
    // unbreakable; the sweep/reconnect below is best-effort per tick.
    await this.state.storage.setAlarm(now + ALARM_EVERY_MS);
    if (this.ws && now - this.stats.lastMsgMs > STALE_SOCKET_MS) {
      try { this.ws.close(); } catch {}
      this.ws = null;
    }
    if (!this.ws) await this.ensure();

    const pruned: string[] = [];
    for (const [mint, c] of this.coins) {
      const usd = c.mcSol !== null && this.solUsd > 0 ? c.mcSol * this.solUsd : null;
      // quiet coin past its bell while holding — sweep the remainder at last MC
      if (c.hit4kMs && !c.resolved && c.mode === "holding" &&
          now - c.levelEntryMs >= PLAY_EXIT_AGE_MS && usd !== null) {
        this.advancePlay(mint, c, usd, now);
      }
      if (now - c.createdMs > TRACK_MAX_AGE_MS) {
        // window over: holding remainder marks to last MC; awaiting_dip is
        // already all-cash. Book the final state either way.
        if (c.hit4kMs && !c.resolved) {
          if (c.mode === "holding" && usd !== null) {
            const exitVal = c.soldValue + (1 - c.soldFrac) * usd;
            c.compoundMult *= exitVal / c.levelEntryMc;
            this.stats.exits++;
            this.writeCycle(mint, c.level, "window", c.levelEntryMc, exitVal, c.rungIdx, now);
            if (c.level === 1) this.writeLevel1(mint, c, "exit2m", exitVal, now);
          }
          c.resolved = true;
          this.updateHeadline(mint, c);
        }
        pruned.push(mint);
        this.coins.delete(mint);
      }
    }
    if (pruned.length && this.ws) {
      try {
        this.ws.send(JSON.stringify({ method: "unsubscribeTokenTrade", keys: pruned }));
      } catch {}
    }
    // (next alarm already armed at the top — see R-6 note)
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
        // PINNED SHAPE: the create event carries the DEV BUY — solAmount is
        // the creator's initial buy in SOL (live sample: 4.938), trader is
        // the creator. Seed the flow aggregates with it: the dev is buyer #1
        // and their share is exactly the whale-concentration signal.
        const devSol = num(j.solAmount) ?? 0;
        const creator: string = j.traderPublicKey ?? j.creator ?? "";
        const buyerSol = new Map<string, number>();
        if (devSol > 0 && creator) buyerSol.set(creator, devSol);
        this.coins.set(mint, {
          createdMs: now,
          symbol: j.symbol ?? null,
          name: j.name ?? null,
          buys: devSol > 0 ? 1 : 0, sells: 0, solNet: devSol,
          buyerSol,
          mcSol: num(j.marketCapSol ?? j.market_cap_sol),
          hit4kMs: null,
          level: 1, levelEntryMc: 0, levelEntryMs: 0,
          mode: "holding", dipPeak: 0, compoundMult: 1,
          rungIdx: 0, soldFrac: 0, soldValue: 0, resolved: false,
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

    // ---- §0 v3 (the ladder + the cycle), at trade resolution ----
    if (this.solUsd <= 0) { this.stats.noPrice++; return; }
    if (c.mcSol === null) return;
    const usd = c.mcSol * this.solUsd;
    const age = now - c.createdMs;

    if (c.hit4kMs === null && usd >= PLAY_HIT_USD && age <= TRACK_MAX_AGE_MS) {
      c.hit4kMs = now;
      this.stats.hits++;
      this.recordHit(mint, c, usd, now);
      if (!c.resolved) { c.levelEntryMc = usd; c.levelEntryMs = now; }
      return; // crossing trade scored on the NEXT trade — entry can't also be exit
    }
    if (c.hit4kMs !== null && !c.resolved) this.advancePlay(mint, c, usd, now);
  }

  // One step of the cycle: fill rungs, ring bells, hunt dips, re-enter.
  advancePlay(mint: string, c: Coin, usd: number, now: number): void {
    if (c.mode === "awaiting_dip") {
      if (usd > c.dipPeak) { c.dipPeak = usd; return; }
      if (usd <= c.dipPeak * DIP_FRAC) {
        // THE DIP — re-buy with full proceeds, next ladder up, fresh bell.
        c.level++;
        c.levelEntryMc = usd; c.levelEntryMs = now;
        c.rungIdx = 0; c.soldFrac = 0; c.soldValue = 0;
        c.mode = "holding";
        this.writeCycle(mint, c.level, "entry", usd, null, 0, now);
      }
      return;
    }
    // holding: fill any rungs this trade's MC clears (fills AT rung price —
    // a sell triggered at >=rung executes at-or-above it, so this is the
    // conservative-honest paper fill)
    const rungs = rungsFor(c.level);
    while (c.rungIdx < rungs.length && usd >= rungs[c.rungIdx]) {
      c.soldValue += RUNG_FRACS[c.rungIdx] * rungs[c.rungIdx];
      c.soldFrac += RUNG_FRACS[c.rungIdx];
      c.rungIdx++;
    }
    if (c.rungIdx === rungs.length) {
      // FULL LADDER — all sold. Book the level, arm the dip hunt.
      const mult = c.soldValue / c.levelEntryMc;
      c.compoundMult *= mult;
      this.stats.targets++;
      this.writeCycle(mint, c.level, "ladder", c.levelEntryMc, c.soldValue, c.rungIdx, now);
      if (c.level === 1) this.writeLevel1(mint, c, "target", c.soldValue, now);
      c.mode = "awaiting_dip";
      c.dipPeak = usd;
      this.updateHeadline(mint, c);
      return;
    }
    if (now - c.levelEntryMs >= PLAY_EXIT_AGE_MS) {
      // THE BELL — remainder sells at market; the cycle ends here.
      const exitVal = c.soldValue + (1 - c.soldFrac) * usd;
      c.compoundMult *= exitVal / c.levelEntryMc;
      c.resolved = true;
      this.stats.exits++;
      this.writeCycle(mint, c.level, "bell", c.levelEntryMc, exitVal, c.rungIdx, now);
      if (c.level === 1) this.writeLevel1(mint, c, "exit2m", exitVal, now);
      this.updateHeadline(mint, c);
    }
  }

  // The $4k crossing, with the flow-quality read an agent would decide on:
  // everything that happened between create and this moment.
  recordHit(mint: string, c: Coin, usd: number, now: number): void {
    const ageSec = Math.round((now - c.createdMs) / 1000);
    let buySol = 0, topSol = 0;
    for (const v of c.buyerSol.values()) { buySol += v; if (v > topSol) topSol = v; }
    const topShare = buySol > 0 ? topSol / buySol : null;
    // Detected already at/past the first sell rung -> 'gap': you can't open
    // a position that's already at its first exit. Same honest-tally rule.
    const gap = usd >= rungsFor(1)[0];
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

  // Level-1 outcome into the earlies ledger (play_exit_mc = BLENDED exit:
  // sold rungs at rung price + remainder at final MC — so exit/entry stays
  // the true multiple in every existing query).
  writeLevel1(mint: string, c: Coin, outcome: "target" | "exit2m", exitVal: number, now: number): void {
    void (
      this.env.RADAR_DB.prepare(
        `UPDATE earlies SET play_outcome=?2, play_exit_mc=?3, play_outcome_ms=?4, rungs_filled=?5
          WHERE token_address=?1 AND play_outcome IS NULL`
      ).bind(mint, outcome, exitVal, now, c.rungIdx)
        .run().catch((e) => { this.stats.d1Errors++; console.error("pumptape level1", e); })
    );
  }

  // Every level event (entry / ladder / bell / window) lands in early_cycles —
  // the research ledger for the fractal exit design.
  writeCycle(mint: string, level: number, outcome: string, entryMc: number,
             exitValue: number | null, rungsFilled: number, now: number): void {
    void (
      this.env.RADAR_DB.prepare(
        `INSERT INTO early_cycles (token_address, level, outcome, entry_mc, exit_value, rungs_filled, ms)
         VALUES (?1,?2,?3,?4,?5,?6,?7)`
      ).bind(mint, level, outcome, entryMc, exitValue, rungsFilled, now)
        .run().catch((e) => { this.stats.d1Errors++; console.error("pumptape cycle", e); })
    );
  }

  // The headline on the earlies row: how deep the cycle went, compounded.
  updateHeadline(mint: string, c: Coin): void {
    void (
      this.env.RADAR_DB.prepare(
        `UPDATE earlies SET levels=?2, compound_mult=?3 WHERE token_address=?1`
      ).bind(mint, c.level, Math.round(c.compoundMult * 1000) / 1000)
        .run().catch((e) => { this.stats.d1Errors++; console.error("pumptape headline", e); })
    );
  }
}
