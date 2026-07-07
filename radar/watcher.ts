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
    headers: { accept: "application/json", "user-agent": "possessio-radar/0.1" },
  });
  if (!res.ok) {
    console.warn("birth feed", res.status);
    return;
  }
  const now = Date.now();
  const body: any = await res.json();
  // Shape is feed-dependent — normalize after live verification (handoff §Feeds).
  const items: any[] = Array.isArray(body) ? body : body?.coins ?? body?.data ?? [];

  for (const it of items.slice(0, 100)) {
    // Shape pinned against the LIVE-VERIFIED frontend-api-v3 /coins response
    // (2026-07-06): `mint`, `created_timestamp` (ms), `usd_market_cap`.
    // UNIT-CORRUPTION RULE: usd_market_cap is the ONLY market-cap field we
    // read - never raw `market_cap` (SOL-denominated on this feed).
    const addr = it.mint ?? it.address ?? it.tokenAddress;
    if (!addr) continue;
    await env.RADAR_DB.prepare(
      `INSERT INTO births
         (token_address, chain, symbol, name, creator, api_created_ms,
          pumpfun_first_seen_ms, status, last_checked_ms,
          mc_at_birth_usd, raw_birth_json)
       VALUES (?1,'solana',?2,?3,?4,?5,?6,'watching',?6,?7,?8)
       ON CONFLICT(token_address) DO NOTHING`
    )
      .bind(
        addr,
        it.symbol ?? null,
        it.name ?? null,
        it.creator ?? null,
        numOrNull(it.created_timestamp ?? it.createdAt),
        now,
        numOrNull(it.usd_market_cap ?? it.marketCapUsd),
        JSON.stringify(it).slice(0, 4000)
      )
      .run();
  }
}

export async function discoveryScan(env: WatcherEnv): Promise<void> {
  const now = Date.now();
  const batch = parseInt(env.DISCOVERY_BATCH || "25", 10);
  const expireMs = parseInt(env.EXPIRE_HOURS || "24", 10) * 3600_000;

  const { results } = await env.RADAR_DB.prepare(
    `SELECT token_address, pumpfun_first_seen_ms FROM births
      WHERE status = 'watching'
      ORDER BY last_checked_ms ASC LIMIT ?1`
  )
    .bind(batch)
    .all();

  for (const row of results as any[]) {
    const addr = row.token_address as string;
    const born = row.pumpfun_first_seen_ms as number;

    if (now - born > expireMs) {
      await env.RADAR_DB.prepare(
        `UPDATE births SET status='expired', last_checked_ms=?2 WHERE token_address=?1`
      )
        .bind(addr, now)
        .run();
      continue;
    }

    const res = await fetch(env.DEXSCREENER_TOKEN_URL + addr, {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.1" },
    });
    if (res.status === 429) {
      console.warn("dexscreener 429 — yielding this tick");
      return; // polite backoff; cron returns in 60s
    }
    if (!res.ok) continue;

    const data: any = await res.json();
    const pairs: any[] = data?.pairs ?? [];
    if (pairs.length > 0) {
      // DISCOVERY — the index found it. The gap closes here; measure it.
      const mc = numOrNull(pairs[0]?.marketCap ?? pairs[0]?.fdv);
      await env.RADAR_DB.prepare(
        `UPDATE births SET status='discovered',
                dexscreener_first_seen_ms=?2,
                gap_ms=?2 - pumpfun_first_seen_ms,
                mc_at_discovery_usd=?3,
                last_checked_ms=?2
          WHERE token_address=?1 AND status='watching'`
      )
        .bind(addr, now, mc)
        .run();
    } else {
      await env.RADAR_DB.prepare(
        `UPDATE births SET last_checked_ms=?2 WHERE token_address=?1`
      )
        .bind(addr, now)
        .run();
    }
  }
}

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}
