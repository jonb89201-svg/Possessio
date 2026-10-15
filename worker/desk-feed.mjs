// THE DESK'S TWO LISTS (2026-10-15, Architect).
//
//   VERIFIED — automatic. Jupiter's verified Solana tokens, newest first, after
//   hard filters. Replaces the radar feed as the desk's default list: the radar
//   cron has been paused since 2026-08-23 and it screened brand-new pump.fun
//   launches, which the Architect no longer wants to buy.
//
//   TRENDING — manual only. The Architect finds a coin by address and adds it,
//   or deletes it, "like an admin". Every add and delete is signed by the wallet
//   and gated by the SAME allowlist as arming the keeper (deskArmingAllowed).
//
// This module holds the pure parts (filters, the signed message) and the two
// handlers. The handlers take their helpers as arguments, so worker/index.ts
// keeps one implementation of the allowlist, base58 and Ed25519, and the tests
// can drive the real handlers offline.

// The two Solana token programs. Jupiter is Solana-only, but the feed checks
// anyway: "Solana network only" is a requirement, not an assumption.
export const SOLANA_TOKEN_PROGRAMS = new Set([
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",   // SPL Token
  "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",   // Token-2022
]);

// Tokenized stocks and other real-world assets (Architect: "filter tokenized
// stocks out"). MEASURED 2026-10-15: of 3,984 verified tokens, 2,008 carry one
// of these tags (AVGO, TSM and CMG are "Backpack Securities" stocks).
export const EXCLUDED_TAGS = new Set(["stocks", "xstocks", "equities", "prestocks", "rwa"]);

export const VERIFIED_SOURCE = "https://lite-api.jup.ag/tokens/v2/tag?query=verified";
export const VERIFIED_DEFAULTS = Object.freeze({ minLiquidityUsd: 25_000, limit: 20, cacheSeconds: 600 });

/// Filter Jupiter's verified list down to what the desk may offer. Pure.
///
/// Every rule is a reason a coin can hurt the person who buys it, or a reason
/// it is not what the Architect asked for:
///   - verified, and on a Solana token program;
///   - no stock / RWA tag;
///   - MINT authority off: nobody can print more. This also drops coins bridged
///     onto Solana from other chains, whose bridge keeps the mint authority
///     (WLD, SHIB, ONDO, QNT: all "verified", all mintable on Solana);
///   - FREEZE authority off: a freezable account can block the keeper's exit;
///   - liquidity at least minLiquidityUsd, so an exit has somewhere to go;
///   - a first-pool date, so "newest" means something.
/// Unknown is never treated as safe: an audit field that is missing fails.
export function filterVerified(rows, { minLiquidityUsd = VERIFIED_DEFAULTS.minLiquidityUsd, limit = VERIFIED_DEFAULTS.limit, isMint = () => true } = {}) {
  const dropped = {};
  const drop = (why) => { dropped[why] = (dropped[why] || 0) + 1; };
  const kept = [];
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || r.isVerified !== true) { drop("not verified"); continue; }
    if (!SOLANA_TOKEN_PROGRAMS.has(r.tokenProgram) || typeof r.id !== "string" || !isMint(r.id)) { drop("not a Solana token"); continue; }
    if ((r.tags || []).some((t) => EXCLUDED_TAGS.has(t))) { drop("tokenized stock / RWA"); continue; }
    const a = r.audit || {};
    if (a.mintAuthorityDisabled !== true) { drop("mint authority not off"); continue; }
    if (a.freezeAuthorityDisabled !== true) { drop("freeze authority not off"); continue; }
    if (!(Number(r.liquidity) >= minLiquidityUsd)) { drop("liquidity below floor"); continue; }
    const firstPoolAt = Date.parse(r.firstPool && r.firstPool.createdAt);
    if (!Number.isFinite(firstPoolAt)) { drop("no first-pool date"); continue; }
    kept.push({
      mint: r.id,
      symbol: String(r.symbol || "").slice(0, 16),
      name: String(r.name || "").slice(0, 40),
      icon: typeof r.icon === "string" && /^https:\/\//.test(r.icon) ? r.icon.slice(0, 300) : null,
      priceUsd: Number(r.usdPrice) || null,
      mcapUsd: Number(r.mcap) || null,
      liquidityUsd: Number(r.liquidity) || null,
      holders: Number(r.holderCount) || null,
      top10Pct: Number.isFinite(Number(a.topHoldersPercentage)) ? Math.round(Number(a.topHoldersPercentage) * 10) / 10 : null,
      organic: r.organicScoreLabel || null,
      change24hPct: Number.isFinite(Number(r.stats24h && r.stats24h.priceChange)) ? Math.round(Number(r.stats24h.priceChange) * 10) / 10 : null,
      firstPoolAt,
    });
  }
  kept.sort((x, y) => y.firstPoolAt - x.firstPoolAt);
  return { tokens: kept.slice(0, limit), matched: kept.length, dropped };
}

/// GET /api/desk/verified. One upstream fetch per cache period per Cloudflare
/// location: the source list is about 5 MB, so phones never download it.
export async function handleVerified(request, env, { json, isMint, cache = (typeof caches !== "undefined" ? caches.default : null), fetchImpl = fetch, now = Date.now }) {
  if (request.method !== "GET") return json({ error: "METHOD" }, 405);
  const opts = {
    minLiquidityUsd: Number(env.DESK_VERIFIED_MIN_LIQUIDITY_USD) > 0 ? Number(env.DESK_VERIFIED_MIN_LIQUIDITY_USD) : VERIFIED_DEFAULTS.minLiquidityUsd,
    limit: VERIFIED_DEFAULTS.limit,
  };
  const key = new Request("https://possessio.io/__cache/desk-verified-v1?minliq=" + opts.minLiquidityUsd);
  if (cache) {
    const hit = await cache.match(key);
    if (hit) return hit;
  }
  let rows;
  try {
    const r = await fetchImpl(VERIFIED_SOURCE, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(15_000) });
    if (!r.ok) return json({ error: "UPSTREAM", status: r.status }, 502);
    rows = await r.json();
  } catch (e) {
    return json({ error: "UPSTREAM", detail: String((e && e.message) || e).slice(0, 120) }, 502);
  }
  const out = filterVerified(rows, { ...opts, isMint });
  const body = JSON.stringify({
    tokens: out.tokens, matched: out.matched, dropped: out.dropped, fetchedAt: now(),
    source: "jupiter tokens/v2 tag=verified",
    filters: { solanaOnly: true, excludedTags: [...EXCLUDED_TAGS], mintAuthorityOff: true, freezeAuthorityOff: true, minLiquidityUsd: opts.minLiquidityUsd },
  });
  const res = new Response(body, {
    status: 200,
    headers: { "content-type": "application/json", "cache-control": `public, max-age=${VERIFIED_DEFAULTS.cacheSeconds}` },
  });
  if (cache) await cache.put(key, res.clone());
  return res;
}

// ── TRENDING: the hand-curated list ─────────────────────────────────────────

export const TRENDING_MAX = 50;
export const TRENDING_SIG_WINDOW_MS = 10 * 60 * 1000;

/// The exact bytes the wallet signs for an add or a delete. MUST stay
/// byte-identical to trendingMessage() in public/miniapp-solana.js;
/// worker/test/desk-feed.test.mjs lifts both and compares the bytes.
///
/// Replay guard: the message names the action, the mint and a timestamp. The
/// worker accepts it only within TRENDING_SIG_WINDOW_MS of its own clock and
/// records every nonce, so a captured "delete" can never be replayed later to
/// pull a coin the Architect re-added, nor a captured "add" to put one back.
export function trendingPreimage({ action, owner, mint, ts, nonce }) {
  const msg =
    "possessio.desk.trending.v1\n" +
    `action:${action}\n` +
    `owner:${owner}\n` +
    `mint:${mint}\n` +
    `ts:${ts}\n` +
    `nonce:${nonce}`;
  return new TextEncoder().encode(msg);
}

/// GET  /api/desk/trending  → { trending: [{ mint, addedAt }] }, newest first.
/// POST /api/desk/trending  { action: "add"|"remove", owner, mint, ts, nonce, signature }
export async function handleTrending(request, env, { json, isMint, verifyEd25519, deskArmingAllowed, now = Date.now }) {
  const db = env.COUNCIL_DB;
  if (!db) return json({ error: "COUNCIL_DB_UNBOUND" }, 503);

  if (request.method === "GET") {
    const { results } = await db
      .prepare("SELECT mint, ts_ms FROM desk_trending ORDER BY ts_ms DESC LIMIT ?1")
      .bind(TRENDING_MAX)
      .all();
    return json({ trending: (results || []).map((r) => ({ mint: r.mint, addedAt: r.ts_ms })) });
  }
  if (request.method !== "POST") return json({ error: "METHOD" }, 405);

  let b;
  try { b = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }
  const { action, owner, mint, ts, nonce, signature } = b || {};
  if (action !== "add" && action !== "remove") return json({ error: "BAD_ACTION" }, 400);
  if (typeof owner !== "string" || !isMint(owner)) return json({ error: "BAD_OWNER" }, 400);
  // THE SAME GATE AS ARMING. Before any other work, and on the verified signer
  // below, so it cannot be bypassed with curl.
  if (!deskArmingAllowed(env, owner)) return json({ error: "DESK_PRIVATE_BETA" }, 403);
  if (typeof mint !== "string" || !isMint(mint)) return json({ error: "BAD_MINT" }, 400);
  if (!Number.isSafeInteger(ts)) return json({ error: "BAD_TS" }, 400);
  if (Math.abs(now() - ts) > TRENDING_SIG_WINDOW_MS) return json({ error: "STALE_SIGNATURE" }, 400);
  if (typeof nonce !== "string" || !nonce.length || nonce.length > 64) return json({ error: "BAD_NONCE" }, 400);
  if (typeof signature !== "string" || signature.length > 200) return json({ error: "BAD_SIGNATURE" }, 400);

  let verified = false;
  try { verified = await verifyEd25519(owner, signature, trendingPreimage({ action, owner, mint, ts, nonce })); }
  catch { return json({ error: "BAD_SIGNATURE" }, 400); }
  if (!verified) return json({ error: "SIGNER_MISMATCH" }, 401);

  // Spend the nonce first: a replay of this exact signature stops here.
  try {
    await db.prepare("INSERT INTO desk_trending_nonces (nonce, ts_ms) VALUES (?1, ?2)").bind(nonce, now()).run();
  } catch (e) {
    if (/UNIQUE|constraint/i.test(String((e && e.message) || e))) return json({ error: "NONCE_ALREADY_USED" }, 409);
    throw e;
  }
  // Keep the nonce ledger bounded: anything older than the window can no longer verify anyway.
  await db.prepare("DELETE FROM desk_trending_nonces WHERE ts_ms < ?1").bind(now() - 2 * TRENDING_SIG_WINDOW_MS).run();

  if (action === "remove") {
    const r = await db.prepare("DELETE FROM desk_trending WHERE mint = ?1").bind(mint).run();
    return json({ ok: true, removed: (r && r.meta && r.meta.changes) || 0 });
  }
  const count = await db.prepare("SELECT COUNT(*) AS n FROM desk_trending").first();
  const exists = await db.prepare("SELECT mint FROM desk_trending WHERE mint = ?1").bind(mint).first();
  if (exists) return json({ ok: true, added: 0, note: "already trending" });
  if (count && Number(count.n) >= TRENDING_MAX) return json({ error: "TRENDING_FULL", max: TRENDING_MAX }, 409);
  // OR IGNORE: two adds racing on one mint end as one row, never a 500.
  const ins = await db.prepare("INSERT OR IGNORE INTO desk_trending (mint, added_by, ts_ms) VALUES (?1, ?2, ?3)").bind(mint, owner, now()).run();
  return json({ ok: true, added: (ins && ins.meta && ins.meta.changes) || 0 });
}
