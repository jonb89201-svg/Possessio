// possessio-radar — watcher.ts: the two feeds and a clock (RADAR_HANDOFF).
// Jobs land here as handed off; the HTTP surface lives in x402-toll.ts (the
// handoff's X402_TOLL_SEAM, already executed - the toll'd routes supersede
// the reference file's free ones; boundary tests proven 2026-07-06).
//
// §4 COMPLIANCE (rulebook, binding): this service holds NO keys, signs NOTHING,
// trades NOTHING. It observes and writes rows. It can run today without touching
// the activation sequence. "There is no state in which a key exists and the
// rulebook does not."
//
// PRODUCT BOUNDARY (ratified: sell the measurements, not the edge): the
// pre-discovery 'watching' list is the agent's eyes only - no HTTP surface
// returns those rows. Enforced in x402-toll.ts; any diff relaxing it is HIGH.
//
// VERIFY-FIRST gate: birthScan idles until PUMPFUN_FEED_URL is set with a
// LIVE-VERIFIED endpoint (handoff §Feeds - pump.fun has no stable official
// REST feed; candidates are the frontend coins-by-created API and third-party
// streams like PumpPortal's WebSocket; polling v1, Durable-Object WebSocket is
// the precision upgrade seam). The sandbox cannot reach the feeds (egress
// blocked), so live verification is the MCP seat's or the Architect's; then
// set the var and normalize the item shape below if it differs.

import type { Env } from "./x402-toll";

export type WatcherEnv = Env & {
  PUMPFUN_FEED_URL: string;
  DEXSCREENER_TOKEN_URL: string;
  DISCOVERY_BATCH: string;
  EXPIRE_HOURS: string;
};

export async function birthScan(env: WatcherEnv): Promise<void> {
  if (!env.PUMPFUN_FEED_URL) {
    console.warn("PUMPFUN_FEED_URL unset — birthScan idle (VERIFY-FIRST gate)");
    return;
  }
  const res = await fetch(env.PUMPFUN_FEED_URL, {
    headers: { accept: "application/json", "user-agent": "possessio-radar/0.2" },
  });
  if (!res.ok) {
    console.warn("birth feed", res.status);
    return;
  }
  const now = Date.now();
  const body: any = await res.json();
  // Shape is feed-dependent — normalize after live verification (handoff §Feeds).
  const items: any[] = Array.isArray(body) ? body : body?.coins ?? body?.data ?? [];

  // R-3 (2026-07-07): capture the WHOLE poll window, not a slice of it. A real
  // winning token (FY9y...pump, $11K->$22K) was MISSED when >50 births landed
  // in one 60s tick: the limit=50 feed URL AND this slice(0,100) both silently
  // dropped the overflow - and burst minutes are exactly the rising-volume
  // regime trades live in, so the tape was blind where it mattered most.
  // Fix: feed limit raised to 300 (VERIFY-FIRST: /coins default limit is 1000),
  // slice raised to 500, and inserts BATCHED so the extra volume is one D1
  // call rather than N subrequests (avoids the Workers subrequest ceiling).
  const stmts: any[] = [];
  for (const it of items.slice(0, 500)) {
    // Shape pinned against the LIVE-VERIFIED frontend-api-v3 /coins response
    // (2026-07-06): `mint`, `created_timestamp` (ms), `usd_market_cap`.
    // UNIT-CORRUPTION RULE: usd_market_cap is the ONLY market-cap field we
    // read - never raw `market_cap` (SOL-denominated on this feed).
    const addr = it.mint ?? it.address ?? it.tokenAddress;
    if (!addr) continue;
    stmts.push(
      env.RADAR_DB.prepare(
        `INSERT INTO births
           (token_address, chain, symbol, name, creator, api_created_ms,
            pumpfun_first_seen_ms, status, last_checked_ms,
            mc_at_birth_usd, raw_birth_json)
         VALUES (?1,'solana',?2,?3,?4,?5,?6,'watching',?6,?7,?8)
         ON CONFLICT(token_address) DO NOTHING`
      ).bind(
        addr,
        it.symbol ?? null,
        it.name ?? null,
        it.creator ?? null,
        numOrNull(it.created_timestamp ?? it.createdAt),
        now,
        numOrNull(it.usd_market_cap ?? it.marketCapUsd),
        JSON.stringify(it).slice(0, 4000)
      )
    );
  }
  if (stmts.length > 0) await env.RADAR_DB.batch(stmts);
}

export async function discoveryScan(env: WatcherEnv): Promise<void> {
  const now = Date.now();
  // R-2 (2026-07-07): batched discovery. DexScreener's tokens endpoint takes
  // up to 30 comma-joined addresses per request at 300 req/min (VERIFY-FIRST
  // against docs.dexscreener.com/api/reference, confirmed 2026-07-07), so a
  // tick sweeps DISCOVERY_BATCH tokens in ceil(n/30) requests - full
  // watching-set coverage every 1-3 min at current birth rates.
  const perTick = parseInt(env.DISCOVERY_BATCH || "300", 10);
  const expireMs = parseInt(env.EXPIRE_HOURS || "24", 10) * 3600_000;

  const { results } = await env.RADAR_DB.prepare(
    `SELECT token_address, pumpfun_first_seen_ms FROM births
      WHERE status = 'watching'
      ORDER BY last_checked_ms ASC LIMIT ?1`
  )
    .bind(perTick)
    .all();

  const stmts: any[] = [];
  const live: { addr: string }[] = [];
  for (const row of results as any[]) {
    // Expiry first, no network needed. Post-R-1 this is the COMMON path:
    // ~98% of births never graduate (the prior; the tape now measures it).
    if (now - (row.pumpfun_first_seen_ms as number) > expireMs) {
      stmts.push(
        env.RADAR_DB.prepare(
          `UPDATE births SET status='expired', last_checked_ms=?2 WHERE token_address=?1`
        ).bind(row.token_address, now)
      );
    } else {
      live.push({ addr: row.token_address as string });
    }
  }

  for (let c = 0; c < live.length; c += 30) {
    const chunk = live.slice(c, c + 30);
    const res = await fetch(env.DEXSCREENER_TOKEN_URL + chunk.map((t) => t.addr).join(","), {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.2" },
    });
    if (res.status === 429) {
      console.warn("dexscreener 429 — yielding this tick");
      break; // polite backoff; cron returns in 60s; batched writes still land
    }
    if (!res.ok) continue;

    const data: any = await res.json();
    const byToken = new Map<string, any[]>();
    for (const p of (data?.pairs ?? []) as any[]) {
      const base = p?.baseToken?.address;
      if (!base) continue;
      const list = byToken.get(base) ?? [];
      list.push(p);
      byToken.set(base, list);
    }

    for (const { addr } of chunk) {
      const pairs = byToken.get(addr) ?? [];
      // R-1 (2026-07-07, first-audit finding): DexScreener indexes the pump.fun
      // BONDING CURVE itself as dexId 'pumpfun' ~60s after birth. That is
      // machine latency, not the market event. The event is GRADUATION: the
      // first non-pumpfun pair ($69K MC surface - 6.9x entry, 3.45x TP).
      const curvePair = pairs.find((p) => p?.dexId === "pumpfun");
      const gradPairs = pairs.filter((p) => p?.dexId && p.dexId !== "pumpfun");

      if (curvePair) {
        // telemetry: first sighting of the curve index entry (write-once)
        stmts.push(
          env.RADAR_DB.prepare(
            `UPDATE births SET curve_pair_seen_ms = COALESCE(curve_pair_seen_ms, ?2)
              WHERE token_address = ?1`
          ).bind(addr, now)
        );
      }

      if (gradPairs.length > 0) {
        // THE event: graduation surface reached. gap_ms = birth -> graduation.
        // graduation_dex (migration 0004) records WHICH dex triggered, so the
        // read can segment TRUE graduations (pumpswap/raydium migration, MC
        // consistent with curve completion) from SIDE-POOLS. A side-pool /
        // LP-at-birth is a strong BAIT marker -> this flag feeds the rug-gate.
        const mc = numOrNull(gradPairs[0]?.marketCap ?? gradPairs[0]?.fdv);
        const dex = gradPairs[0]?.dexId ?? null;
        stmts.push(
          env.RADAR_DB.prepare(
            `UPDATE births SET status='discovered',
                    dexscreener_first_seen_ms=?2,
                    gap_ms=?2 - pumpfun_first_seen_ms,
                    mc_at_discovery_usd=?3,
                    graduation_dex=?4,
                    last_checked_ms=?2
              WHERE token_address=?1 AND status='watching'`
          ).bind(addr, now, mc, dex)
        );
      } else {
        stmts.push(
          env.RADAR_DB.prepare(
            `UPDATE births SET last_checked_ms=?2 WHERE token_address=?1`
          ).bind(addr, now)
        );
      }
    }
  }

  if (stmts.length > 0) await env.RADAR_DB.batch(stmts);
}

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}
