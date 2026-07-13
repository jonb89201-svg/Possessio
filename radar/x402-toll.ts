// x402-toll.ts — sell-side toll for possessio-radar
//
// AUDIT LAW THIS FILE OBEYS: never hand-roll payment verification. Signature checking,
// settlement, and replay protection belong to the official x402 middleware + facilitator.
// This file is CONFIGURATION around the official package, nothing more. A homemade 402
// verifier in a money path would be a HIGH finding — including one written by this seat.
//
// VERIFY-FIRST EXECUTED (Claude Code, 2026-07-06, against the packages themselves):
//   - The handed-off snapshot named `x402-hono` (v1). That package is DEPRECATED
//     (npm README: v1, security patches only). The current official stack is x402 v2:
//     `@x402/hono` 2.17.0 + `@x402/core` + `@x402/evm` — API confirmed from the
//     package's own README + dist/*.d.mts, not from docs-site memory.
//   - v2 shape: paymentMiddleware(routes, resourceServer) where resourceServer =
//     new x402ResourceServer(new HTTPFacilitatorClient({url})).register(caip2, new
//     ExactEvmScheme()). Networks are CAIP-2 ("eip155:84532" = Base Sepolia).
//   - Default facilitator: https://facilitator.x402.org. Coinbase CDP facilitator is
//     the mainnet choice at cutover (FACILITATOR_URL var — flip with the wave, like
//     every chain check).
//
// Behavior: while TOLL_SINK is the zero address, routes serve FREE with an honest
// "TOLL_NOT_ARMED" header — same placeholder pattern as the fuel pool's POOL_NOT_DEPLOYED.
// The moment the wave writes the sink, the same routes start charging. No code change.

import { Hono } from "hono";
import { paymentMiddleware, x402ResourceServer } from "@x402/hono";
import { HTTPFacilitatorClient } from "@x402/core/server";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { FEED_HTML } from "./feed";

export type Env = {
  RADAR_DB: D1Database;
  TOLL_SINK: string;
  TOLL_NETWORK: "base" | "base-sepolia"; // human name in config; CAIP-2 derived below
  FACILITATOR_URL?: string;
  PRICE_GAP_STATS: string;   // OPEN — Architect prices after the tape has data
  PRICE_SESSION_GATE: string;
  PRICE_TAPE: string;
};

const ZERO = "0x0000000000000000000000000000000000000000";
const CAIP2: Record<string, string> = { base: "eip155:8453", "base-sepolia": "eip155:84532" };

export function buildTolledApp(env: Env) {
  const app = new Hono();
  const armed = env.TOLL_SINK && env.TOLL_SINK.toLowerCase() !== ZERO;

  if (armed) {
    // ── THE toll. One middleware, three routes, prices from env. ──
    const network = CAIP2[env.TOLL_NETWORK];
    const facilitator = new HTTPFacilitatorClient({
      url: env.FACILITATOR_URL || "https://facilitator.x402.org",
    });
    const server = new x402ResourceServer(facilitator).register(network, new ExactEvmScheme());
    const accepts = (price: string, description: string) => ({
      accepts: { scheme: "exact", price, network, payTo: env.TOLL_SINK as `0x${string}` },
      description,
    });
    app.use(
      paymentMiddleware(
        {
          "GET /radar/gap-stats": accepts(env.PRICE_GAP_STATS,
            "Rolling pump.fun->DexScreener gap distribution (aggregates only)"),
          "GET /radar/session-gate": accepts(env.PRICE_SESSION_GATE,
            "Today's Sec0 regime reading: pass/fail + ratio"),
          "GET /radar/tape": accepts(env.PRICE_TAPE,
            "Discovered-only historical tape, last 100"),
        },
        server,
      ),
    );
  } else {
    app.use("*", async (c, next) => {
      c.header("x-possessio-toll", "TOLL_NOT_ARMED"); // honest free mode pre-wave
      await next();
    });
  }

  // ---- the public LIVE-SELECTION feed (RATIFIED 2026-07-11, Architect,
  // Amendment IV Clause 5). This is the deliberate exception to the boundary
  // below: the screened candidate SELECTION is public — it promotes the
  // x402Core autonomous trader and feeds the pool, and shared visibility on a
  // $10k micro-cap is a tailwind, not a leak. It exposes WHICH coins clear §1,
  // never entry/exit prices or size. Always free, even when the toll is armed
  // (it's marketing for the paid execution product, not a paid data route). ----
  app.get("/feed", (c) => c.html(FEED_HTML));
  // Layer 3 VERIFY-FIRST surface: WS engine state, parse rate, raw samples.
  // Aggregates + public mint data only — nothing here leaks method params.
  app.get("/radar/ws-status", async (c) => {
    const ns = (c.env as any).PUMPTAPE as DurableObjectNamespace | undefined;
    if (!ns) return c.json({ error: "PUMPTAPE_NOT_BOUND" }, 503);
    const stub = ns.get(ns.idFromName("main"));
    const r = await stub.fetch("https://pumptape/status");
    return new Response(r.body, { headers: { "content-type": "application/json" } });
  });
  app.get("/radar/candidates", async (c) => {
    const db = c.env.RADAR_DB;
    const dexCols = `graduated_ms, dex_price_usd, dex_mc, dex_peak_mc, dex_liq_usd,
              dex_vol_h1, dex_chg_m5, dex_chg_h1, dex_last_ms`;
    // img: the coin's launch image (pump.fun image_uri), pulled free from the
    // stored birth JSON — makes cards recognizable at a glance.
    const imgCol = (t: string) =>
      `(SELECT json_extract(b.raw_birth_json,'$.image_uri') FROM births b WHERE b.token_address=${t}.token_address) AS img`;
    const live = await db.prepare(
      `SELECT token_address, symbol, name, qualified_ms, entry_mc, entry_age_sec,
              peak_mc, last_mc, last_tracked_ms, gate_rug, gate_session, ${imgCol("candidates")}, ${dexCols}
         FROM candidates WHERE outcome='live' ORDER BY qualified_ms DESC LIMIT 40`
    ).all();
    const recent = await db.prepare(
      `SELECT token_address, symbol, name, qualified_ms, entry_mc, peak_mc,
              last_mc, outcome, outcome_ms, ${dexCols}
         FROM candidates WHERE outcome!='live' ORDER BY outcome_ms DESC LIMIT 40`
    ).all();
    const tally = await db.prepare(
      `SELECT outcome, COUNT(*) AS n FROM candidates GROUP BY outcome`
    ).all();
    // Screen 0 — the early radar (0-4min, crossed $4k). Same ratified public
    // surface: which coins, never entry/exit prices or size.
    const early = await db.prepare(
      `SELECT token_address, symbol, name, first_hit_ms, first_hit_mc, age_sec_at_hit,
              peak_mc, play_outcome, play_exit_mc, rungs_filled, levels, compound_mult,
              ws, t4k_ms, buys_hit, sells_hit, sol_net_hit, uniq_buyers_hit, top_buyer_share,
              graduated_ms, dex_mc, dex_peak_mc, dex_liq_usd, dex_vol_h1, dex_last_ms,
              ${imgCol("earlies")}
         FROM earlies WHERE status='watching'
        ORDER BY first_hit_ms DESC LIMIT 40`
    ).all();
    // §0 EARLY PLAY paper tally: entry=$4k crossing, target=$8k, exit at age
    // 2:00. avg_mult = paper multiple on resolved plays (exit/entry).
    const earlyPlay = await db.prepare(
      `SELECT play_outcome, COUNT(*) AS n,
              ROUND(AVG(play_exit_mc / first_hit_mc), 2) AS avg_mult
         FROM earlies WHERE play_outcome IS NOT NULL
        GROUP BY play_outcome`
    ).all();
    // CONVICTION FORWARD SCORECARD (migration 0016): the radar grading its own
    // entry hypothesis on coins the thresholds never saw. Only RESOLVED coins
    // count — a concluded §0 play OR born >20min ago (past the run window) — so a
    // still-cooking GO is not scored as a loss. peak = the realized max
    // (post-grad dex_peak_mc if it ran on DEX, else the curve peak_mc).
    const convResolvedBefore = Date.now() - 20 * 60_000;
    const scorecard = await db.prepare(
      `SELECT conv_tag AS tag, COUNT(*) AS n,
              SUM(CASE WHEN COALESCE(dex_peak_mc, peak_mc, 0) >= 20000 THEN 1 ELSE 0 END) AS win20,
              SUM(CASE WHEN conv_entry_mc > 0
                        AND COALESCE(dex_peak_mc, peak_mc, 0) >= 2*conv_entry_mc THEN 1 ELSE 0 END) AS win2x
         FROM earlies
        WHERE conv_tag IS NOT NULL
          AND (play_outcome IS NOT NULL OR first_hit_ms < ?1)
        GROUP BY conv_tag`
    ).bind(convResolvedBefore).all();
    // The oscillation tape for everything currently on screen. 25min covers
    // the longest possible early->qualify->track life; closed coins age out.
    const ticksRaw = await db.prepare(
      `SELECT token_address, ms, mc, sol_reserves, vol_m5 FROM mc_ticks
        WHERE ms >= ?1 ORDER BY ms ASC`
    ).bind(Date.now() - 25 * 60_000).all();
    const ticks: Record<string, { ms: number; mc: number; sol: number | null; v5: number | null }[]> = {};
    for (const t of ticksRaw.results as any[]) {
      (ticks[t.token_address] ??= []).push({ ms: t.ms, mc: t.mc, sol: t.sol_reserves, v5: t.vol_m5 });
    }
    return c.json({
      live: live.results,
      recent: recent.results,
      early: early.results,
      earlyPlay: earlyPlay.results,
      scorecard: scorecard.results,
      ticks,
      tally: tally.results,
      method: "RULEBOOK §1 — pre-DEX, 4-7min, ~$10k entry / $20k target / $6k stop / 10min time-stop (paper-only)",
    });
  });

  // ---- routes: the measurements (the PAID API). ----
  // PRODUCT BOUNDARY (paid routes only, HIGH if relaxed): no route below
  // returns status='watching'. The live-selection feed above is the ratified
  // exception; these aggregate/discovered-only routes are unchanged.

  // R-1/R-2 REFRAME (2026-07-07): 'discovered' = GRADUATED (first non-pumpfun
  // pair, the $69K surface). gap_ms = birth -> graduation, a winners-only
  // survivorship stat (~2% lore prior; first real measurement is the tape's).
  // graduation-rate-per-hour is the measured Session Gate signal.
  // All outputs are AGGREGATES - never rows, never 'watching' addresses.
  app.get("/radar/gap-stats", async (c) => {
    const db = c.env.RADAR_DB;
    const counts = await db.prepare(
      `SELECT COUNT(*) AS births_total,
              SUM(status='watching')   AS watching_count,
              SUM(status='discovered') AS graduated_count,
              SUM(status='expired')    AS expired_count
         FROM births`
    ).first<any>();
    const grad = await db.prepare(
      `SELECT AVG(gap_ms) AS avg_ms, MIN(gap_ms) AS min_ms, MAX(gap_ms) AS max_ms
         FROM births WHERE status='discovered'`
    ).first<any>();
    // median + quartiles via ORDER/OFFSET (SQLite has no percentile fn)
    const pct = async (frac: number) => {
      const n = Number(counts?.graduated_count ?? 0);
      if (!n) return null;
      const row = await db.prepare(
        `SELECT gap_ms FROM births WHERE status='discovered'
          ORDER BY gap_ms LIMIT 1 OFFSET ?1`
      ).bind(Math.min(n - 1, Math.floor(n * frac))).first<any>();
      return row?.gap_ms ?? null;
    };
    // telemetry: the machine's OWN indexing latency (curve sighting), kept
    // separate so it is never again confused with the market.
    const curve = await db.prepare(
      `SELECT COUNT(*) AS n, AVG(curve_pair_seen_ms - pumpfun_first_seen_ms) AS avg_ms
         FROM births WHERE curve_pair_seen_ms IS NOT NULL`
    ).first<any>();
    // Segment graduations by dex (migration 0004): true migrations
    // (pumpswap/raydium) vs side-pools. An aggregate breakdown - a count per
    // dexId, no rows/addresses - stays inside the product boundary.
    const byDex = await db.prepare(
      `SELECT graduation_dex AS dex, COUNT(*) AS n,
              AVG(gap_ms) AS avg_gap_ms, MIN(gap_ms) AS min_gap_ms
         FROM births WHERE status='discovered'
        GROUP BY graduation_dex ORDER BY n DESC`
    ).all();
    // R-4: peak-MC distribution — the trade window (birth->pump), not just
    // graduation. Generic percentiles only; any band (8-13k) is a PRIVATE
    // read-time threshold, never exposed here (Sec6).
    const peak = await db.prepare(
      `SELECT COUNT(*) AS n, MAX(mc_peak_usd) AS max_mc,
              AVG(mc_peak_usd) AS avg_mc
         FROM births WHERE mc_peak_usd IS NOT NULL`
    ).first<any>();
    const total = Number(counts?.births_total ?? 0);
    const graduated = Number(counts?.graduated_count ?? 0);
    return c.json({
      births_total: total,
      watching_count: Number(counts?.watching_count ?? 0),
      graduated_count: graduated,
      expired_count: Number(counts?.expired_count ?? 0),
      graduation_rate: total > 0 ? graduated / total : null,
      grad_gap_ms: {
        avg: grad?.avg_ms ?? null, min: grad?.min_ms ?? null, max: grad?.max_ms ?? null,
        p25: await pct(0.25), median: await pct(0.5), p75: await pct(0.75),
      },
      graduation_by_dex: byDex.results,
      peak_mc: { tracked: Number(peak?.n ?? 0), avg: peak?.avg_mc ?? null, max: peak?.max_mc ?? null },
      curve_index_telemetry: { seen: Number(curve?.n ?? 0), avg_ms: curve?.avg_ms ?? null },
    });
  });

  app.get("/radar/session-gate", async (c) => {
    const row = await c.env.RADAR_DB.prepare(
      `SELECT session_date, ratio, gate_pass FROM sessions
        ORDER BY session_date DESC LIMIT 1`
    ).first();
    return c.json(row ?? { error: "NO_READING_YET" });
  });

  app.get("/radar/tape", async (c) => {
    const rows = await c.env.RADAR_DB.prepare(
      `SELECT token_address, symbol, pumpfun_first_seen_ms,
              dexscreener_first_seen_ms, gap_ms, mc_at_discovery_usd
         FROM births WHERE status='discovered'
        ORDER BY dexscreener_first_seen_ms DESC LIMIT 100`
    ).all();
    return c.json(rows.results);
  });

  return app;
}

// Acceptance (radar handoff §Acceptance items 5–7):
// 5. Unarmed: routes serve free, header TOLL_NOT_ARMED present.
// 6. Armed on base-sepolia with a test sink: unpaid request → HTTP 402 with payment
//    requirements; paid request via any x402 client → 200 + data; settlement visible
//    on-chain at the sink.
// 7. Boundary test unchanged: no route leaks 'watching' rows, armed or not.
