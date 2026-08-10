// possessio tape engine — the PumpTape state machine, extracted from
// radar/pumptape.ts so it can run OFF the Cloudflare Durable Object.
//
// WHY (board row 90): Workers are request-scoped and hostile to long-lived
// sockets — pumptapeTrades sat in socket_down for days while the 60s cron
// carried the tape, which is exactly the resolution the ledger verdict of
// 2026-07-11 proved untradable (0/118 targets in the 4-8k band; runners cross
// 4k->20k inside one tick). The Railway host proven by the keeper's K2 soak
// (row 90: 8h flat, 0.14% CPU) is the natural home for one subscriber.
//
// This module is PURE: no sockets, no D1, no clock of its own. The host feeds
// it messages and timestamps; it returns effect objects whose `p` arrays bind
// 1:1 to the SQL the radar's ingest route executes — the SAME statements
// pumptape.ts ran, so every existing query over earlies/early_cycles reads
// identically. The paper-ladder semantics (§0 v3, Architect-ratified
// 2026-07-11) are ported unchanged; drift here would silently re-grade the
// research ledger, which is why tape/test/engine.test.js pins the numbers.
"use strict";

const TRACK_MAX_AGE_MS = 8 * 60000; // stop caring after the §1 window closes

// §0 v3 — THE LADDER (Architect-ratified 2026-07-11): buy the $3,500
// crossing; scale out 50% @ $6k, 25% @ $8k, 12.5% @ $10k, 12.5% @ $12k;
// remainder exits at the age-2:00 bell at market. Rungs fill AT the rung
// price (conservative-honest paper fill).
const PLAY_HIT_USD = 3500;
const RUNG_FRACS = [0.5, 0.25, 0.125, 0.125];
const L1_RUNGS = [6000, 8000, 10000, 12000];
// THE CYCLE: a full ladder waits for a 15% dip, re-buys, runs the next ladder
// one octave up (L2 14/16/18/20k, L3 22/24/26/28k, ...). Full reinvestment.
const DIP_FRAC = 0.85;
const PLAY_EXIT_AGE_MS = 2 * 60000;
const TRADE_SILENCE_MS = 5 * 60000;

function rungsFor(level) {
  if (level <= 1) return L1_RUNGS;
  const base = 12000 + 8000 * (level - 2);
  return [base + 2000, base + 4000, base + 6000, base + 8000];
}

function num(v) {
  const n = typeof v === "string" ? parseFloat(v) : v;
  return Number.isFinite(n) ? n : null;
}

class TapeEngine {
  constructor() {
    this.solUsd = 0; // pushed by the host from the verified pump.fun ratio read
    this.coins = new Map();
    this.rawSamples = [];
    this.stats = {
      msgs: 0, parsed: 0, births: 0, trades: 0,
      hits: 0, targets: 0, exits: 0, gaps: 0, noPrice: 0,
      lastBirthMs: 0, lastTradeMs: 0,
    };
  }

  setSolUsd(p) { const n = num(p); if (n !== null && n > 0) this.solUsd = n; }

  // One inbound WS message -> { effects, subscribe, unsubscribe } for the host.
  onMessage(text, now) {
    const out = { effects: [], subscribe: [], unsubscribe: [] };
    this.stats.msgs++;
    if (typeof text !== "string") return out;
    if (this.rawSamples.length < 8) this.rawSamples.push(text.slice(0, 500));
    let j;
    try { j = JSON.parse(text); } catch { return out; }
    const mint = j.mint ?? j.token ?? j.ca;
    if (!mint) return out;
    this.stats.parsed++;
    const txType = j.txType ?? j.type ?? "";

    if (txType === "create") {
      this.stats.births++;
      this.stats.lastBirthMs = now; // free/keyless stream — see stats.lastTradeMs
      if (!this.coins.has(mint)) {
        // PINNED SHAPE (live samples 2026-07-11): the create event carries the
        // DEV BUY — solAmount is the creator's initial buy in SOL, trader is
        // the creator. The dev is buyer #1; their share is the whale signal.
        const devSol = num(j.solAmount) ?? 0;
        const creator = j.traderPublicKey ?? j.creator ?? "";
        const buyerSol = new Map();
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
        out.subscribe.push(mint);
      }
      return out;
    }

    // THE MIGRATION (2026-08-10): the coin's DEX pair is born — the exact
    // moment the Architect's graded edges hunt in. Stamped into births via
    // the ingest so the feed's "just listed" section is sub-second instead of
    // discovery-scan-late. PumpPortal announces it on subscribeMigration.
    if (txType === "migrate" || txType === "migration") {
      out.effects.push({ k: "listing", p: [mint, now, String(j.pool ?? j.dex ?? "pumpswap").slice(0, 30)] });
      return out;
    }

    if (txType !== "buy" && txType !== "sell") return out;
    const c = this.coins.get(mint);
    if (!c) return out; // trade for a coin we never saw born — skip
    this.stats.trades++;
    this.stats.lastTradeMs = now; // KEY-GATED stream — silence here vs live births = drained/revoked key

    // lamports-vs-SOL heuristic: a single pump.fun trade above 100k "SOL"
    // does not exist; that magnitude is lamports.
    let sol = num(j.solAmount ?? j.sol_amount) ?? 0;
    if (sol > 100000) sol = sol / 1e9;
    const mcSol = num(j.marketCapSol ?? j.market_cap_sol);
    if (mcSol !== null) c.mcSol = mcSol;
    const trader = j.traderPublicKey ?? j.trader ?? "";

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

    if (this.solUsd <= 0) { this.stats.noPrice++; return out; } // never guessed
    if (c.mcSol === null) return out;
    const usd = c.mcSol * this.solUsd;
    const age = now - c.createdMs;

    if (c.hit4kMs === null && usd >= PLAY_HIT_USD && age <= TRACK_MAX_AGE_MS) {
      c.hit4kMs = now;
      this.stats.hits++;
      out.effects.push(this.hitEffect(mint, c, usd, now));
      if (!c.resolved) { c.levelEntryMc = usd; c.levelEntryMs = now; }
      return out; // crossing trade scored on the NEXT trade — entry can't also be exit
    }
    if (c.hit4kMs !== null && !c.resolved) this.advancePlay(mint, c, usd, now, out);
    return out;
  }

  // Layer 2 duties on the host's watchdog tick: ring overdue bells, book and
  // prune coins past the tracking window.
  sweep(now) {
    const out = { effects: [], subscribe: [], unsubscribe: [] };
    for (const [mint, c] of this.coins) {
      const usd = c.mcSol !== null && this.solUsd > 0 ? c.mcSol * this.solUsd : null;
      if (c.hit4kMs && !c.resolved && c.mode === "holding" &&
          now - c.levelEntryMs >= PLAY_EXIT_AGE_MS && usd !== null) {
        this.advancePlay(mint, c, usd, now, out);
      }
      if (now - c.createdMs > TRACK_MAX_AGE_MS) {
        if (c.hit4kMs && !c.resolved) {
          if (c.mode === "holding" && usd !== null) {
            const exitVal = c.soldValue + (1 - c.soldFrac) * usd;
            c.compoundMult *= exitVal / c.levelEntryMc;
            this.stats.exits++;
            out.effects.push({ k: "cycle", p: [mint, c.level, "window", c.levelEntryMc, exitVal, c.rungIdx, now] });
            if (c.level === 1) out.effects.push(this.level1Effect(mint, c, "exit2m", exitVal, now));
          }
          c.resolved = true;
          out.effects.push(this.headlineEffect(mint, c));
        }
        out.unsubscribe.push(mint);
        this.coins.delete(mint);
      }
    }
    return out;
  }

  // One step of the cycle: fill rungs, ring bells, hunt dips, re-enter.
  advancePlay(mint, c, usd, now, out) {
    if (c.mode === "awaiting_dip") {
      if (usd > c.dipPeak) { c.dipPeak = usd; return; }
      if (usd <= c.dipPeak * DIP_FRAC) {
        c.level++;
        c.levelEntryMc = usd; c.levelEntryMs = now;
        c.rungIdx = 0; c.soldFrac = 0; c.soldValue = 0;
        c.mode = "holding";
        out.effects.push({ k: "cycle", p: [mint, c.level, "entry", usd, null, 0, now] });
      }
      return;
    }
    const rungs = rungsFor(c.level);
    while (c.rungIdx < rungs.length && usd >= rungs[c.rungIdx]) {
      c.soldValue += RUNG_FRACS[c.rungIdx] * rungs[c.rungIdx];
      c.soldFrac += RUNG_FRACS[c.rungIdx];
      c.rungIdx++;
    }
    if (c.rungIdx === rungs.length) {
      const mult = c.soldValue / c.levelEntryMc;
      c.compoundMult *= mult;
      this.stats.targets++;
      out.effects.push({ k: "cycle", p: [mint, c.level, "ladder", c.levelEntryMc, c.soldValue, c.rungIdx, now] });
      if (c.level === 1) out.effects.push(this.level1Effect(mint, c, "target", c.soldValue, now));
      c.mode = "awaiting_dip";
      c.dipPeak = usd;
      out.effects.push(this.headlineEffect(mint, c));
      return;
    }
    if (now - c.levelEntryMs >= PLAY_EXIT_AGE_MS) {
      const exitVal = c.soldValue + (1 - c.soldFrac) * usd;
      c.compoundMult *= exitVal / c.levelEntryMc;
      c.resolved = true;
      this.stats.exits++;
      out.effects.push({ k: "cycle", p: [mint, c.level, "bell", c.levelEntryMc, exitVal, c.rungIdx, now] });
      if (c.level === 1) out.effects.push(this.level1Effect(mint, c, "exit2m", exitVal, now));
      out.effects.push(this.headlineEffect(mint, c));
    }
  }

  // The $3.5k crossing, with the flow-quality read. Param order binds 1:1 to
  // the earlies INSERT the ingest route executes (?1..?15) — same statement
  // pumptape.ts ran.
  hitEffect(mint, c, usd, now) {
    const ageSec = Math.round((now - c.createdMs) / 1000);
    let buySol = 0, topSol = 0;
    for (const v of c.buyerSol.values()) { buySol += v; if (v > topSol) topSol = v; }
    const topShare = buySol > 0 ? topSol / buySol : null;
    // Detected already at/past the first sell rung -> 'gap': you can't open a
    // position that's already at its first exit.
    const gap = usd >= rungsFor(1)[0];
    if (gap) { c.resolved = true; this.stats.gaps++; }
    return {
      k: "hit",
      p: [mint, c.symbol, c.name, now, usd, ageSec,
          now - c.createdMs, c.buys, c.sells, Math.round(c.solNet * 1000) / 1000,
          c.buyerSol.size, topShare,
          gap ? "gap" : null, gap ? usd : null, gap ? now : null],
    };
  }

  level1Effect(mint, c, outcome, exitVal, now) {
    return { k: "level1", p: [mint, outcome, exitVal, now, c.rungIdx] };
  }

  headlineEffect(mint, c) {
    return { k: "headline", p: [mint, c.level, Math.round(c.compoundMult * 1000) / 1000] };
  }

  // THE DRAINING METER (audit 2026-07-24), ported: judged behaviorally from
  // the two streams' own timestamps. subscribeNewToken is free and keyless;
  // subscribeTokenTrade needs a key funded >=0.02 SOL, and when the key drains
  // the SOCKET STAYS UP — births keep flowing while the trade stream dies.
  health(now, connected, keyed) {
    const s = this.stats;
    const birth_age_ms = s.lastBirthMs ? now - s.lastBirthMs : null;
    const trade_age_ms = s.lastTradeMs ? now - s.lastTradeMs : null;
    const birthsLive = birth_age_ms !== null && birth_age_ms < TRADE_SILENCE_MS;
    const tradesSilent = trade_age_ms === null || trade_age_ms > TRADE_SILENCE_MS;

    let status = "ok";
    let detail = null;
    if (!connected) {
      status = "socket_down";
      detail = "WebSocket is down; the 30s watchdog reconnects. Layer 1 (60s cron) carries the tape meanwhile.";
    } else if (!keyed) {
      status = "trades_unsubscribed";
      detail = "No PUMPPORTAL_API_KEY set — births only, BY CONFIG, not by failure. " +
        "Trade-level tape (and every claim graded against it) is not accruing. " +
        "subscribeTokenTrade needs a key funded >=0.02 SOL.";
    } else if (this.coins.size > 0 && birthsLive && tradesSilent) {
      status = "trade_stream_dead";
      detail = `Births are arriving (${Math.round(birth_age_ms / 1000)}s ago) but NO trade ` +
        `message in ${trade_age_ms === null ? "this session" : Math.round(trade_age_ms / 1000) + "s"} ` +
        `while tracking ${this.coins.size} coins — the key-gated stream is gone while the socket reads healthy. ` +
        "Most likely the PumpPortal key fell below 0.02 SOL (it degrades SILENTLY; the socket stays up). " +
        "Also consistent with a revoked key or an upstream API change. The tape is NOT accruing: " +
        "do not grade any forward claim against this window.";
    }
    return { status, connected, keyed, tracked: this.coins.size, birth_age_ms, trade_age_ms, detail };
  }
}

module.exports = { TapeEngine, PLAY_HIT_USD, L1_RUNGS, RUNG_FRACS, rungsFor, TRACK_MAX_AGE_MS, PLAY_EXIT_AGE_MS };
