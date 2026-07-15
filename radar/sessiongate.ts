// possessio-radar — sessiongate.ts: the §0 SESSION GATE writer.
//
// §4 COMPLIANCE (rulebook, binding): holds NO keys, signs NOTHING, trades
// NOTHING. It reads the birth tape and writes one regime reading. No order is
// ever placed. "There is no state in which a key exists and the rulebook does
// not."
//
// WHAT §0 ASKS FOR: "is right now a day worth playing at all?" — trailing
// volume (last 1–24h of Solana meme/DEX activity) vs its own trailing 7-day
// average, a RELATIVE threshold. Sit out if trailing < ~60–70% of the 7d avg.
// The cutoff (default 0.65) is a research-based STARTING POINT, tuned later by
// ledger correlation, never frozen (§0/§7) — hence env-overridable + stored
// per-reading (threshold_used).
//
// ── THE VOLUME PROXY — CHOSEN: (A) INTRINSIC. births/hour (pump.fun launch
// rate), derived from data the radar already measures (the `births` table,
// written every tick by birthScan). NO new external dependency.
//
// WHY births/hour and not a dollar-volume figure: §0's own stated reasoning is
// "a rational creator launches into attention, not silence. Healthy ambient
// volume is a proxy for 'creators are choosing to launch right now, into a crowd
// that will show up'." The launch RATE measures precisely that — creators
// choosing to launch — arguably more on-the-nose for §0's reasoning than raw
// DEX dollars. And §0 gates on the RELATIVE figure (window vs its own 7d avg),
// which a relative launch-rate self-corrects exactly the way a relative dollar
// volume does. The `births` table is the radar's most reliable, longest-lived
// signal (never deleted — status flips to 'expired', rows stay), so a real 7-day
// baseline is available where the pruned mc_ticks tape (~48h) is not.
//
// HONEST LIMITS (documented in code AND the stored `basis` string AND SPEC §5a):
//   - It is a LAUNCH-COUNT proxy, not a dollar-volume measure. §0 names "Solana
//     meme/DEX volume"; births/hour is a count of pump.fun creations the radar
//     OBSERVED — a sample of pump.fun launch activity, itself a proxy for the
//     broader Solana meme regime. It is honest about being pump.fun-scoped.
//   - Observation-gap bias: if the watcher is down / PUMPFUN_FEED_URL unset,
//     births aren't recorded. Window and baseline draw from the SAME source, so
//     a persistent sampling ceiling largely cancels in the ratio; a gap
//     concentrated in the trailing window would bias it (the fail-soft +
//     insufficient-history guards below refuse to fabricate through the worst
//     of these).
//   - Feed-cap bias: birthScan slices 500/tick and the feed URL caps its page,
//     so extreme burst minutes undercount (see watcher.ts R-3). This caps the
//     metric in exactly the hot regime it should flag — a CONSERVATIVE bias
//     (understates a raging session, never overstates a dead one). Acceptable.
//
// If a keyless, stable public Solana DEX dollar-volume source is later adopted
// (option B), swap the query below and the `basis`/`source` label; the schema,
// route, cadence, and threshold plumbing are source-agnostic by design.

import type { WatcherEnv } from "./watcher";

// §0/§7 defaults — every one is env-overridable; NONE is frozen.
const DEFAULT_THRESHOLD = 0.65;        // §0 "~60–70%" starting point, tuned by ledger correlation
const DEFAULT_WINDOW_HOURS = 24;       // §0 "last 1–24h" — the wide end; a launch-rate is stabler over 24h at 60s sampling
const DEFAULT_BASELINE_DAYS = 7;       // §0 "trailing 7-day average"
const DEFAULT_RECOMPUTE_MS = 3_600_000; // hourly — plenty for a 7-day baseline; avoids recomputing every 60s tick
const MIN_SPAN_HOURS = 1;              // insufficient-history floor: refuse to average a tape younger than this

function numCfg(v: string | undefined, dflt: number): number {
  const n = v == null ? NaN : Number(v);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}
const round4 = (x: number) => Math.round(x * 1e4) / 1e4;

// The §0 session-gate reading. Computed on a CADENCE (hourly by default, not
// every tick), bounded, and FAIL-SOFT: any failure logs and returns, leaving
// the last good reading untouched — it never throws into the cron.
export async function sessionGateScan(env: WatcherEnv, now: number = Date.now()): Promise<void> {
  try {
    const recomputeMs = numCfg(env.SESSION_RECOMPUTE_MS, DEFAULT_RECOMPUTE_MS);

    // CADENCE GATE: one cheap read of the freshest reading's clock; bail if it's
    // younger than the interval. ms-based off the stored row (not an in-memory
    // counter), so it survives isolate eviction/restart — the same discipline
    // the rest of the worker keeps.
    const last = await env.RADAR_DB.prepare(
      `SELECT MAX(recorded_ms) AS last_ms FROM sessions`
    ).first<any>();
    const lastMs = last?.last_ms == null ? null : Number(last.last_ms);
    if (lastMs !== null && now - lastMs < recomputeMs) return; // not due yet — last reading stands

    const threshold = numCfg(env.SESSION_GATE_THRESHOLD, DEFAULT_THRESHOLD);
    const windowHours = numCfg(env.SESSION_WINDOW_HOURS, DEFAULT_WINDOW_HOURS);
    const baselineDays = numCfg(env.SESSION_BASELINE_DAYS, DEFAULT_BASELINE_DAYS);
    const baselineHours = baselineDays * 24;
    const winStart = now - windowHours * 3_600_000;
    const baseStart = now - baselineHours * 3_600_000;

    // ONE read over the birth tape: window count, baseline count, and the oldest
    // birth INSIDE the baseline lookback (for the span-capped denominator).
    const row = await env.RADAR_DB.prepare(
      `SELECT
         SUM(CASE WHEN pumpfun_first_seen_ms >= ?1 THEN 1 ELSE 0 END) AS win_n,
         COUNT(*)                                                     AS base_n,
         MIN(pumpfun_first_seen_ms)                                   AS oldest_ms
       FROM births WHERE pumpfun_first_seen_ms >= ?2`
    ).bind(winStart, baseStart).first<any>();

    const winN = Number(row?.win_n ?? 0);
    const baseN = Number(row?.base_n ?? 0);
    const oldest = row?.oldest_ms == null ? null : Number(row.oldest_ms);

    // INSUFFICIENT-HISTORY guard. No births to average, or a tape younger than
    // MIN_SPAN_HOURS, means there is no honest baseline yet. Fabricating a ratio
    // here would be dishonest — LEAVE the last good reading (fail-soft), log, and
    // return. (The route then keeps serving the prior reading, or NO_READING_YET
    // if this is genuinely the first-ever run.)
    const spanHours = oldest === null ? 0 : (now - oldest) / 3_600_000;
    if (baseN === 0 || spanHours < MIN_SPAN_HOURS) {
      console.warn(
        `sessionGateScan insufficient history base_n=${baseN} span_h=${round4(spanHours)} — leaving last reading`,
      );
      return;
    }

    // SPAN-CAPPED denominators. Before a full week (or a full window) of tape
    // exists, average over the time we ACTUALLY observed, not over hours we
    // didn't. This keeps a cold-start ratio ≈ 1 (neutral) instead of a spurious
    // pass/fail from an under-seeded denominator, and it converges to the true
    // relative signal as history accumulates. Once span exceeds the spans, these
    // are just windowHours / baselineHours as written.
    const winDenomH = Math.min(windowHours, spanHours);
    const baseDenomH = Math.min(baselineHours, spanHours);
    const windowRate = winN / winDenomH;      // births/hour, trailing window
    const baselineRate = baseN / baseDenomH;  // births/hour, trailing baseline
    const ratio = baselineRate > 0 ? windowRate / baselineRate : 1;
    const pass = ratio >= threshold ? 1 : 0;

    const sessionDate = new Date(now).toISOString().slice(0, 10); // YYYY-MM-DD UTC
    const basis =
      `births/hour (pump.fun launch rate; intrinsic proxy for the Solana meme ` +
      `regime, §0). window=${windowHours}h baseline=${baselineDays}d, both ` +
      `span-capped; win_n=${winN} base_n=${baseN} span_h=${round4(spanHours)}`;

    // Upsert today's row. Recomputing intra-day just refreshes it; the daily key
    // preserves one row per day for the §5 ledger correlation the tuning needs.
    await env.RADAR_DB.prepare(
      `INSERT INTO sessions
         (session_date, trailing_vol, avg_7d_vol, ratio, gate_pass, threshold_used, basis, notes, recorded_ms)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8)
       ON CONFLICT(session_date) DO UPDATE SET
         trailing_vol=excluded.trailing_vol, avg_7d_vol=excluded.avg_7d_vol,
         ratio=excluded.ratio, gate_pass=excluded.gate_pass,
         threshold_used=excluded.threshold_used, basis=excluded.basis,
         recorded_ms=excluded.recorded_ms`
    ).bind(
      sessionDate, round4(windowRate), round4(baselineRate), round4(ratio),
      pass, threshold, basis, now,
    ).run();
  } catch (e) {
    // FAIL-SOFT: never throw into the cron. A failed computation logs and leaves
    // the last good reading in place (§0 keeps whatever the previous tick wrote).
    console.warn("sessionGateScan failed — last reading preserved", String(e));
  }
}

// The /radar/session-gate response shaper. Kept here (not inline in the route)
// so it is unit-testable without booting the Hono/x402 stack, and so the exact
// contract the xtrade Sec0 reader depends on lives next to the writer.
//
// CONTRACT with mcp/xtrade/facts.js (fetchSessionGateReading, VERIFIED
// 2026-07-15): it accepts the reading iff `typeof j.ratio === "number" &&
// "gate_pass" in j`, then reads j.gate_pass, j.ratio, j.session_date. Those
// three NATIVE keys MUST be present or Sec0 falls back to refusal — so they are
// emitted verbatim alongside the friendly task-spec aliases. row === null (no
// reading yet) returns the honest NO_READING_YET the reader already handles.
export function sessionGateResponse(row: any): Record<string, unknown> {
  if (!row) return { error: "NO_READING_YET" };
  return {
    // friendly shape (task spec)
    pass: !!row.gate_pass,
    ratio: row.ratio,
    window_metric: row.trailing_vol,
    baseline_7d: row.avg_7d_vol,
    threshold: row.threshold_used,
    measured_at: row.recorded_ms,
    basis: row.basis,
    // native keys the xtrade facts.js reader consumes verbatim — do NOT drop.
    session_date: row.session_date,
    gate_pass: row.gate_pass,
  };
}
