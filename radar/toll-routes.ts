// toll-routes.ts — the x402 V2 tolled-route config (payment + Bazaar Discovery).
//
// Split out of x402-toll.ts so the config the worker ships is the SAME object a
// unit test can validate — with NO other module (feed, sessiongate) loaded, so the
// test resolves cleanly under node's native TS loader. This file is pure config
// around the official @x402/extensions package; it does not verify payments (the
// audit law in x402-toll.ts: verification belongs to the middleware + facilitator).
//
// Bazaar Discovery (x402 V2): each route's `extensions` is echoed by a facilitator
// that catalogs the Bazaar (GET /discovery/resources, /search) — how an AI agent
// finds + prices this data API before paying. declareDiscoveryExtension's INPUT
// omits `method` (the server extension sets it from the route verb); these GET
// routes take no query/path params, so we declare OUTPUT only. Bazaar rule the tape
// route obeys: an output EXAMPLE must be an object, so a top-level-array response
// (tape) is described with an output SCHEMA (type:"array") instead of an example.
import { declareDiscoveryExtension } from "@x402/extensions";

export const DISCOVERY_TAGS = ["solana", "memecoins", "pumpfun", "radar", "data"];

export function tollRoutes(opts: {
  network: string;
  payTo: `0x${string}`;
  prices: { gapStats: string; sessionGate: string; tape: string };
  iconUrl: string;
}) {
  const { network, payTo, prices, iconUrl } = opts;
  const accepts = (
    price: string,
    description: string,
    serviceName: string,
    output: { example?: unknown; schema?: Record<string, unknown> },
  ) => ({
    accepts: { scheme: "exact", price, network, payTo },
    description,
    serviceName,
    tags: DISCOVERY_TAGS,
    iconUrl,
    extensions: declareDiscoveryExtension({ output }),
  });
  return {
    "GET /radar/gap-stats": accepts(prices.gapStats,
      "Rolling pump.fun->DexScreener gap distribution (aggregates only)",
      "possessio-gap-stats",
      { example: {
        births_total: 4200, watching_count: 12, graduated_count: 84, expired_count: 4104,
        graduation_rate: 0.02,
        grad_gap_ms: { avg: 640000, min: 90000, max: 3600000, p25: 300000, median: 520000, p75: 800000 },
        graduation_by_dex: [{ dex: "pumpswap", n: 61, avg_gap_ms: 610000, min_gap_ms: 90000 }],
        peak_mc: { tracked: 3800, avg: 14200, max: 210000 },
        curve_index_telemetry: { seen: 4100, avg_ms: 2400 },
      } }),
    // RE-ARMED (2026-07-15): the R-8 UNPRICED note is now spent — a session
    // writer landed (sessiongate.ts, wired into index.ts), so this route
    // serves a REAL §0 regime reading (pass/fail + ratio + basis), not a
    // permanent NO_READING_YET. It is a product now; price it like the
    // other data routes. (Cold-start caveat: like gap-stats before its
    // first tape, it may answer NO_READING_YET for the brief window before
    // the first reading lands — a TRANSIENT gap, not the permanent no-op
    // R-8 refused to sell.)
    "GET /radar/session-gate": accepts(prices.sessionGate,
      "§0 regime reading: pass/fail + ratio (births/hr vs its own 7d avg)",
      "possessio-session-gate",
      { example: {
        pass: true, ratio: 1.18, window_metric: 47, baseline_7d: 40,
        threshold: 0.65, measured_at: 1752700000000,
        basis: "births/hr trailing 24h vs 7d avg",
        session_date: "2026-07-17", gate_pass: 1,
      } }),
    "GET /radar/tape": accepts(prices.tape,
      "Discovered-only historical tape, last 100",
      "possessio-tape",
      // top-level array response → describe with a schema (example must be an
      // object per the Bazaar validator, so an array example is invalid).
      { schema: {
        type: "array",
        items: {
          type: "object",
          properties: {
            token_address: { type: "string" },
            symbol: { type: "string" },
            pumpfun_first_seen_ms: { type: "integer" },
            dexscreener_first_seen_ms: { type: "integer" },
            gap_ms: { type: "integer" },
            mc_at_discovery_usd: { type: "number" },
          },
        },
      } }),
  };
}
