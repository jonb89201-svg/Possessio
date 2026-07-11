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
  YOUNG_WINDOW_MIN: string;
  BASE_RPC_URL?: string;
  CHAINLINK_BTC_USD?: string;
  PUMPPORTAL_WS_URL?: string;
  PUMPTAPE?: DurableObjectNamespace; // Layer 3 engine (pumptape.ts)
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
  const perTick = parseInt(env.DISCOVERY_BATCH || "900", 10);
  const expireMs = parseInt(env.EXPIRE_HOURS || "24", 10) * 3600_000;
  const youngMs = parseInt(env.YOUNG_WINDOW_MIN || "30", 10) * 60_000; // R-8: default fallback matches the tightened config

  // R-5 (2026-07-07, from the Acceptance-3 read): expire the aged-out watching
  // set in ONE bulk write - no per-token polling. At ~1,277 births/hr a 24h
  // watching set balloons past 30k; re-checking corpses starved the YOUNG
  // tokens where graduations + pumps actually happen (first ~23-56 min), so the
  // grad rate read as a lower bound and gap timing was inflated by our own
  // poll latency (~1.7h/token). Sweep the old out cheaply.
  await env.RADAR_DB.prepare(
    `UPDATE births SET status='expired', last_checked_ms=?1
      WHERE status='watching' AND pumpfun_first_seen_ms < ?2`
  ).bind(now, now - expireMs).run();

  // R-5: poll ONLY young watching tokens (within the pump/graduation window),
  // least-recently-checked first. The edge lives here - birth -> 8-13k -> peak,
  // all pre-graduation - so this is where the whole poll budget goes.
  const { results } = await env.RADAR_DB.prepare(
    `SELECT token_address FROM births
      WHERE status='watching' AND pumpfun_first_seen_ms >= ?2
      ORDER BY last_checked_ms ASC LIMIT ?1`
  )
    .bind(perTick, now - youngMs)
    .all();

  const live = (results as any[]).map((r) => ({ addr: r.token_address as string }));
  const stmts: any[] = [];

  // R-2: batched discovery - 30 comma-joined addresses per request at
  // 300 req/min (VERIFY-FIRST vs docs.dexscreener.com/api/reference).
  for (let c = 0; c < live.length; c += 30) {
    const chunk = live.slice(c, c + 30);
    const res = await fetch(env.DEXSCREENER_TOKEN_URL + chunk.map((t) => t.addr).join(","), {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.3" },
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
      // R-1: DexScreener indexes the pump.fun BONDING CURVE as dexId 'pumpfun'
      // ~minutes after birth (machine latency, not the market). The market
      // event is GRADUATION: the first non-pumpfun pair ($69K surface).
      const curvePair = pairs.find((p) => p?.dexId === "pumpfun");
      const gradPairs = pairs.filter((p) => p?.dexId && p.dexId !== "pumpfun");

      // R-4: the current MC = max marketCap across the token's pairs (the live
      // curve MC while on the curve). Track the PEAK so the birth->pump
      // trajectory - the actual trade window - is measurable. Generic peak
      // only; any band (8-13k) is a PRIVATE read-time threshold (Sec6).
      let currentMc: number | null = null;
      for (const p of pairs) {
        const m = numOrNull(p?.marketCap ?? p?.fdv);
        if (m !== null && (currentMc === null || m > currentMc)) currentMc = m;
      }

      if (curvePair) {
        // telemetry: first sighting of the curve index entry (write-once)
        stmts.push(
          env.RADAR_DB.prepare(
            `UPDATE births SET curve_pair_seen_ms = COALESCE(curve_pair_seen_ms, ?2)
              WHERE token_address = ?1`
          ).bind(addr, now)
        );
      }

      if (currentMc !== null) {
        // write-if-higher peak; first reading sets it (COALESCE 0 baseline).
        stmts.push(
          env.RADAR_DB.prepare(
            `UPDATE births
                SET mc_peak_ms  = CASE WHEN ?2 > COALESCE(mc_peak_usd, 0) THEN ?3 ELSE mc_peak_ms END,
                    mc_peak_usd = MAX(COALESCE(mc_peak_usd, 0), ?2)
              WHERE token_address = ?1`
          ).bind(addr, currentMc, now)
        );
      }

      if (gradPairs.length > 0) {
        // THE event: graduation surface reached. gap_ms = birth -> graduation.
        // graduation_dex (0004) segments true grads (pumpswap/raydium) from
        // side-pools (LP-at-birth = bait marker -> rug-gate input).
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

// R-7 (2026-07-07): the BTC regime tape. Memecoin risk appetite rides BTC;
// news acts on this market THROUGH BTC, so one Chainlink read per tick gives
// the Session Gate an objective regime input. Feed self-verified on-chain
// (description() == "BTC / USD"). Failure here never touches the birth tape.
export async function btcScan(env: WatcherEnv): Promise<void> {
  const feed = env.CHAINLINK_BTC_USD || "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F";
  const rpc = env.BASE_RPC_URL || "https://mainnet.base.org";
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [{ to: feed, data: "0xfeaf968c" }, "latest"] }), // latestRoundData()
  });
  if (!res.ok) { console.warn("btc feed rpc", res.status); return; }
  const j: any = await res.json();
  const hex: string = j?.result;
  if (!hex || hex.length < 2 + 64 * 5) { console.warn("btc feed short result"); return; }
  const word = (i: number) => BigInt("0x" + hex.slice(2 + 64 * i, 2 + 64 * (i + 1)));
  const answer = word(1);            // int256 price, 8 decimals (positive in practice)
  const updatedAt = Number(word(3)); // unix seconds
  const price = Number(answer) / 1e8;
  if (!(price > 0)) return;
  await env.RADAR_DB.prepare(
    `INSERT INTO regime_ticks (ts_ms, btc_usd, feed_updated_at)
     VALUES (?1, ?2, ?3) ON CONFLICT(ts_ms) DO NOTHING`
  ).bind(Date.now(), price, updatedAt * 1000).run();
}

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}
