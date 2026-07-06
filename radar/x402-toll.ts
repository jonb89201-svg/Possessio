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

  // ---- routes: the measurements. ----
  // PRODUCT BOUNDARY (unchanged, HIGH if relaxed): no route returns status='watching'.

  app.get("/radar/gap-stats", async (c) => {
    const stats = await c.env.RADAR_DB.prepare(
      `SELECT COUNT(*) AS discovered, AVG(gap_ms) AS avg_gap_ms,
              MIN(gap_ms) AS min_gap_ms, MAX(gap_ms) AS max_gap_ms
         FROM births WHERE status='discovered'`
    ).first();
    return c.json(stats ?? {});
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
