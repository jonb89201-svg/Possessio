// RULEBOOK Sec0/Sec1/Sec2 - THE FACTS LAYER (closes AUDIT 2026-07-14 W-2).
//
// Before this module, every gate "fact" (mintRenounced, lpLockedOrBurned,
// creatorHoldingPct, mc, ageMin, onDexScreener) arrived as a TOOL ARGUMENT -
// the caller's word. gatherFacts() replaces that with SERVER-SIDE reads,
// each fact tagged with its source, basis, and fetch status. Fail-closed
// everywhere: a fact that cannot be fetched is UNAVAILABLE, and the server
// refuses rather than falling back to the caller's assertion.
//
// Source classes, in order of authority:
//   1. "solana-rpc"       - Solana JSON-RPC (direct SOLANA_RPC_URL, or the
//                           read-only solana-mcp Worker proxy via
//                           SOLANA_MCP_URL + SOLANA_MCP_KEY). Chain truth.
//   2. "dexscreener"      - DexScreener public token endpoint. R-1 semantics
//                           (RADAR_FIX_R1R2): only NON-pumpfun dexId pairs
//                           count as discovery/graduation - the bonding-curve
//                           index entry (dexId "pumpfun") appears ~60s after
//                           birth and must NEVER trip onDexScreener.
//   3. "radar" /          - the radar tape (/radar/candidates) and the
//      "pumpfun-frontend"   pump.fun frontend API fallback. Advisory
//                           enrichment: good enough for build-mode gating,
//                           NOT chain-read for the hot-path precondition.
//
// FACTS_VERIFIED_ON_DEVICE is no longer a constant anywhere: it is the
// per-call value `allChainRead` - true iff EVERY gate-critical fact came
// from source class 1 or 2 on THIS call.
//
// ageMin and mc are now CHAIN-READ (the last W-2 data gap, closed):
//   mc     - class 1 pre-DEX: the pump.fun bonding-curve PDA is derived
//            locally (program 6EF8..F6P, seed "bonding-curve"+mint; the
//            derivation is cross-validated against @solana/web3.js),
//            getAccountInfo(base64) decodes the u64 LE reserves, and MC =
//            (vSol/vTok)*supply/1e9 SOL - the EXACT formula radar/screen.ts
//            curveMcUsd verified to 5 decimals vs pump.fun (2026-07-11) -
//            priced with a class-2 SOL/USD read (DexScreener wSOL pair).
//            Curve missing or complete (graduated) -> class-2 DexScreener
//            MC. The radar tape is DEMOTED to a cross-check: >25%
//            tape-vs-chain disagreement is logged in basis, chain wins.
//   ageMin - class 1: getSignaturesForAddress walked to exhaustion (the
//            oldest signature's blockTime = first activity). Pagination is
//            capped at MAX_SIG_PAGES; past the cap the fact carries the
//            PROVEN LOWER BOUND on age ("older than N min"), which fails
//            the 4-7min entry window in the fail-closed direction.
// The tape/pump.fun-frontend paths remain as class-3 FALLBACKS only when
// the chain read itself is unreachable - build-mode still works, but
// allChainRead is then honestly false and hot refuses.
//
// NOTE (what still blocks hot): hotFactsGuard can now pass on a live
// pre-DEX token, but sessionGate remains the FINAL REFUSER - nothing
// writes the radar sessions table yet, so /radar/session-gate answers
// NO_READING_YET and build_trade/execute_trade refuse at Sec0. That is
// correct and intended until the radar grows a sessions writer. Sec4
// steps 3-5 (device verify, key ceremony, ALLOW_HOT ratification) also
// remain open.
//
// All network I/O goes through the injected `deps.fetchImpl` so tests run
// fully offline. 5s AbortSignal timeout per attempt, at most ONE retry,
// never more. Nothing here signs, sends, or holds a key.
"use strict";

const FETCH_TIMEOUT_MS = 5000;

// The facts the Sec0/Sec1/Sec2 gates consume. sessionGate is handled
// separately (its own status + fail-closed refusal in server.js).
const GATE_CRITICAL = Object.freeze([
  "mintRenounced", "lpLockedOrBurned", "creatorHoldingPct",
  "onDexScreener", "ageMin", "mc",
]);

// Source classes 1 and 2: the only sources that satisfy the hot-path
// facts precondition (RULEBOOK Sec4 / W-2). Radar tape is class 3.
const CHAIN_SOURCES = new Set(["solana-rpc", "dexscreener"]);

function factsEnv(env = process.env) {
  return {
    // class 1: direct RPC wins; else the read-only solana-mcp proxy.
    solanaRpcUrl: env.SOLANA_RPC_URL || env.SOLANA_RPC || "",
    solanaMcpUrl: env.SOLANA_MCP_URL || "",
    solanaMcpKey: env.SOLANA_MCP_KEY || "",
    // class 2
    dexscreenerBase: env.DEXSCREENER_BASE || "https://api.dexscreener.com",
    // class 3
    radarUrl: env.RADAR_URL || "https://possessio-radar.jonb89201.workers.dev",
    pumpfunBase: env.PUMPFUN_API_BASE || "https://frontend-api.pump.fun",
    // ARCHITECT-ONLY (documented in README): lets a supervised run pass
    // Sec0 while no live session-gate data source exists. Never a default.
    sessionGateOverride: env.SESSION_GATE_OVERRIDE === "pass",
  };
}

// ---- fact constructors: every fact carries value/source/basis/status ----
function ok(value, source, basis) {
  return { value, source, basis, status: "ok" };
}
function unavailable(source, basis) {
  return { value: null, source, basis, status: "UNAVAILABLE" };
}

// ---- bounded fetch: 5s timeout, ONE retry max, fail-closed on the rest ----
async function fetchJson(fetchImpl, url, init = {}) {
  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) { // 1 try + 1 retry, never more
    try {
      const signal = typeof AbortSignal !== "undefined" && AbortSignal.timeout
        ? AbortSignal.timeout(FETCH_TIMEOUT_MS) : undefined;
      const res = await fetchImpl(url, { ...init, signal });
      if (!res.ok) throw new Error("HTTP " + res.status);
      return await res.json();
    } catch (e) { lastErr = e; }
  }
  throw lastErr;
}

// ============================================================
// Chain-read ageMin/mc plumbing (closes the last W-2 data gap).
// Pure node:crypto + BigInt - no new dependencies, nothing signs.
// ============================================================
const { createHash } = require("node:crypto");
const sha256 = (...bufs) => {
  const h = createHash("sha256");
  for (const b of bufs) h.update(b);
  return h.digest();
};

// pump.fun bonding-curve program + PDA seed (mirrors what pump.fun's own
// program derives; the radar reads the same curve state via the pump.fun
// feed - radar/screen.ts curveMcUsd - this is the pure-RPC route to it).
const PUMPFUN_PROGRAM = "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P";
const CURVE_SEED = "bonding-curve";
// Anchor account discriminator: sha256("account:BondingCurve")[0..8]
// = [23,183,248,55,96,216,172,96] - computed, never hardcoded.
const BONDING_CURVE_DISCRIMINATOR = sha256("account:BondingCurve").subarray(0, 8);

// ---- base58 (Bitcoin alphabet - Solana addresses) ----
const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const B58_MAP = new Map([...B58_ALPHABET].map((c, i) => [c, BigInt(i)]));
function base58Decode(s) {
  let n = 0n;
  for (const ch of s) {
    const v = B58_MAP.get(ch);
    if (v === undefined) throw new Error("invalid base58 character: " + ch);
    n = n * 58n + v;
  }
  const bytes = [];
  while (n > 0n) { bytes.unshift(Number(n & 0xffn)); n >>= 8n; }
  for (const ch of s) { if (ch === "1") bytes.unshift(0); else break; }
  return Buffer.from(bytes);
}
function base58Encode(buf) {
  let n = 0n;
  for (const b of buf) n = (n << 8n) | BigInt(b);
  let out = "";
  while (n > 0n) { out = B58_ALPHABET[Number(n % 58n)] + out; n /= 58n; }
  for (const b of buf) { if (b === 0) out = "1" + out; else break; }
  return out;
}

// ---- ed25519 on-curve check (RFC 8032 point decompression) ----
// A PDA is valid iff its bytes are NOT a decompressible curve point.
// Cross-validated against @solana/web3.js findProgramAddressSync /
// PublicKey.isOnCurve (200 random mints + 50 real pubkeys, 2026-07-15).
const ED_P = 2n ** 255n - 19n;
function edMod(a) { const r = a % ED_P; return r < 0n ? r + ED_P : r; }
function edPow(b, e) {
  let r = 1n; b = edMod(b);
  while (e > 0n) { if (e & 1n) r = (r * b) % ED_P; b = (b * b) % ED_P; e >>= 1n; }
  return r;
}
const ED_D = edMod(-121665n * edPow(121666n, ED_P - 2n)); // d = -121665/121666
function isOnCurve(bytes32) {
  const sign = (bytes32[31] & 0x80) >> 7;
  let y = 0n;
  for (let i = 31; i >= 0; i--) y = (y << 8n) | BigInt(i === 31 ? bytes32[i] & 0x7f : bytes32[i]);
  if (y >= ED_P) return false;
  const y2 = edMod(y * y);
  const u = edMod(y2 - 1n);            // x^2 = (y^2-1)/(d*y^2+1)
  const v = edMod(ED_D * y2 + 1n);
  const v3 = edMod(v * v * v);
  const v7 = edMod(v3 * v3 * v);
  let x = edMod(u * v3 * edPow(edMod(u * v7), (ED_P - 5n) / 8n)); // candidate root
  const vx2 = edMod(v * x * x);
  if (vx2 !== u) {
    if (vx2 !== edMod(-u)) return false;
    x = edMod(x * edPow(2n, (ED_P - 1n) / 4n));
  }
  if (x === 0n && sign === 1) return false;
  return true;
}

const PDA_MARKER = Buffer.from("ProgramDerivedAddress");
function findProgramAddress(seeds, programId) {
  const prog = base58Decode(programId);
  for (let bump = 255; bump >= 0; bump--) {
    const h = sha256(Buffer.concat([...seeds, Buffer.from([bump]), prog, PDA_MARKER]));
    if (!isOnCurve(h)) return { address: base58Encode(h), bump };
  }
  throw new Error("no viable PDA bump");
}
function derivePumpCurvePda(mint) {
  const mintBytes = base58Decode(mint);
  if (mintBytes.length !== 32) throw new Error("mint does not decode to 32 bytes: " + mint);
  return findProgramAddress([Buffer.from(CURVE_SEED), mintBytes], PUMPFUN_PROGRAM);
}

// ---- BondingCurve account decode (anchor layout) ----
// 8B discriminator, then u64 LE x5: virtual_token_reserves,
// virtual_sol_reserves, real_token_reserves, real_sol_reserves,
// token_total_supply, then complete: bool (1B). Newer program versions
// append creator: Pubkey - trailing bytes are ignored, never required.
function decodeBondingCurve(buf) {
  if (!buf || buf.length < 49) return null;
  for (let i = 0; i < 8; i++) if (buf[i] !== BONDING_CURVE_DISCRIMINATOR[i]) return null;
  return {
    virtualTokenReserves: buf.readBigUInt64LE(8),
    virtualSolReserves: buf.readBigUInt64LE(16),
    realTokenReserves: buf.readBigUInt64LE(24),
    realSolReserves: buf.readBigUInt64LE(32),
    tokenTotalSupply: buf.readBigUInt64LE(40),
    complete: buf[48] !== 0,
  };
}

// MIRRORS radar/screen.ts curveMcUsd EXACTLY - same field order, same
// clamps, same overflow ordering. Verified there to 5 decimals against
// pump.fun's own market_cap field (2026-07-11). Do not "improve" this.
function numOrNull(v) {
  const n = typeof v === "string" ? parseFloat(v) : Number(v);
  return Number.isFinite(n) ? n : null;
}
function curveMcUsd(it, solUsd) {
  if (solUsd === null) return null;
  const vsol = numOrNull(it.virtual_sol_reserves);
  const vtok = numOrNull(it.virtual_token_reserves);
  const supply = numOrNull(it.total_supply);
  if (vsol === null || vtok === null || supply === null || vtok <= 0) return null;
  // order matters: vsol*supply (~3e25) would blow past JS's 2^53 safe-integer
  // range, so divide first - (vsol/vtok)~2.8e-5, x supply ~2.8e10, all safe.
  const mcSol = (vsol / vtok) * supply / 1e9; // -> SOL
  return mcSol * solUsd;
}

// ---- source class 1: Solana JSON-RPC (direct, or via the read-only proxy) ----
// The solana-mcp Worker (mcp/solana-mcp/worker.js) is a capability-URL
// server: the access key is a PATH SEGMENT (/<key>/mcp), not a bearer
// header, and only allowlisted read methods are forwarded. We also send
// the key as x-access-key for forward-compat if the worker ever moves to
// header auth; the worker ignores unknown headers today.
async function solanaRpcCall(cfg, fetchImpl, method, params) {
  if (cfg.solanaRpcUrl) {
    const j = await fetchJson(fetchImpl, cfg.solanaRpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params || [] }),
    });
    if (j && j.error) throw new Error("solana rpc error: " + JSON.stringify(j.error));
    return j.result;
  }
  if (cfg.solanaMcpUrl && cfg.solanaMcpKey) {
    const url = cfg.solanaMcpUrl.replace(/\/+$/, "") + "/" + cfg.solanaMcpKey + "/mcp";
    const j = await fetchJson(fetchImpl, url, {
      method: "POST",
      headers: {
        "content-type": "application/json", accept: "application/json",
        "x-access-key": cfg.solanaMcpKey,
      },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "solana_rpc_request", arguments: { method, params: params || [] } },
      }),
    });
    if (j && j.error) throw new Error("solana-mcp error: " + JSON.stringify(j.error));
    const c = j && j.result && j.result.content && j.result.content[0];
    if (!c || j.result.isError) throw new Error("solana-mcp: " + (c ? c.text : "empty result"));
    return JSON.parse(c.text);
  }
  throw new Error(
    "no Solana RPC source configured - set SOLANA_RPC_URL (direct) or " +
    "SOLANA_MCP_URL + SOLANA_MCP_KEY (read-only proxy)");
}

// getAccountInfo(jsonParsed) + getTokenSupply + getTokenLargestAccounts.
// Settled individually so one failed read does not blank the others.
async function fetchMintReads(cfg, fetchImpl, token) {
  const [acct, supply, largest] = await Promise.allSettled([
    solanaRpcCall(cfg, fetchImpl, "getAccountInfo", [token, { encoding: "jsonParsed" }]),
    solanaRpcCall(cfg, fetchImpl, "getTokenSupply", [token]),
    solanaRpcCall(cfg, fetchImpl, "getTokenLargestAccounts", [token]),
  ]);
  return { acct, supply, largest };
}

// creator wallet's total balance of the mint, atomic units.
async function fetchCreatorHolding(cfg, fetchImpl, creator, mint) {
  const r = await solanaRpcCall(cfg, fetchImpl, "getTokenAccountsByOwner",
    [creator, { mint }, { encoding: "jsonParsed" }]);
  const arr = (r && r.value) || [];
  return arr.reduce((s, a) =>
    s + Number((((((a || {}).account || {}).data || {}).parsed || {}).info || {})
      .tokenAmount?.amount || 0), 0);
}

// ---- class 1: bonding-curve account state for the mint ----
// Derive the PDA locally, read it base64, decode the reserves. Returns
// {decoded:true, curve, pda} or {decoded:false, pda, reason} (missing /
// wrong owner / not a BondingCurve account) - the caller falls through
// to the class-2 path on decoded:false; only a SUCCESSFUL pre-graduation
// decode engages the strict class-1 mc (no class-3 fallback after that).
async function fetchCurveState(cfg, fetchImpl, mint) {
  const pda = derivePumpCurvePda(mint); // throws on non-base58/non-32B mint
  const r = await solanaRpcCall(cfg, fetchImpl, "getAccountInfo",
    [pda.address, { encoding: "base64" }]);
  const v = r && r.value;
  if (!v) return { decoded: false, pda: pda.address, bump: pda.bump,
    reason: "curve account missing (never created, or closed after graduation)" };
  if (v.owner && v.owner !== PUMPFUN_PROGRAM)
    return { decoded: false, pda: pda.address, bump: pda.bump,
      reason: `account owner ${v.owner} is not the pump.fun program` };
  const raw = Array.isArray(v.data) && v.data[1] === "base64"
    ? Buffer.from(v.data[0], "base64")
    : typeof v.data === "string" ? Buffer.from(v.data, "base64") : null;
  const curve = raw ? decodeBondingCurve(raw) : null;
  if (!curve) return { decoded: false, pda: pda.address, bump: pda.bump,
    reason: "account data is not a decodable BondingCurve (discriminator/length mismatch)" };
  return { decoded: true, pda: pda.address, bump: pda.bump, curve };
}

// ---- class 2: SOL/USD from the DexScreener wSOL pairs (single call) ----
// Fetched at most once per gatherFacts call, only when a pre-graduation
// curve actually decoded. Deepest-liquidity wSOL-base pair wins.
const WSOL_MINT = "So11111111111111111111111111111111111111112";
async function fetchSolUsd(cfg, fetchImpl) {
  const data = await fetchJson(fetchImpl,
    cfg.dexscreenerBase + "/latest/dex/tokens/" + WSOL_MINT,
    { headers: { accept: "application/json" } });
  const pairs = ((Array.isArray(data) ? data : (data && data.pairs) || []))
    .filter((p) => p && p.baseToken && p.baseToken.address === WSOL_MINT &&
      Number.isFinite(Number(p.priceUsd)) && Number(p.priceUsd) > 0);
  if (!pairs.length) throw new Error("no wSOL pair with a numeric priceUsd");
  pairs.sort((a, b) =>
    (Number(b.liquidity && b.liquidity.usd) || 0) - (Number(a.liquidity && a.liquidity.usd) || 0));
  const best = pairs[0];
  return {
    solUsd: Number(best.priceUsd),
    basis: `SOL/USD=${best.priceUsd} from DexScreener wSOL pair ` +
      `${best.dexId || "?"}:${best.pairAddress || "?"} (deepest liquidity)`,
  };
}

// ---- class 1: token age from the mint's signature history ----
// getSignaturesForAddress is newest-first; walk `before`-paginated pages
// until the FIRST (oldest) signature is reached - its blockTime is the
// token's first activity. For the method's targets (minutes-old tokens)
// that is one page. Pagination is CAPPED: a token with thousands of
// signatures is far past the pre-DEX window, so past the cap we return
// the PROVEN LOWER BOUND on age instead of walking forever (fail-closed
// in the right direction - the bound already fails the entry window).
const SIG_PAGE_LIMIT = 1000;
const MAX_SIG_PAGES = 5;
async function fetchOldestSignatureAge(cfg, fetchImpl, mint, nowMs) {
  let before = null, pages = 0, count = 0, nulls = 0;
  let oldestBlockTime = null, oldestSig = null, exhausted = false;
  while (pages < MAX_SIG_PAGES) {
    const opts = { limit: SIG_PAGE_LIMIT };
    if (before) opts.before = before;
    const page = await solanaRpcCall(cfg, fetchImpl, "getSignaturesForAddress", [mint, opts]);
    if (!Array.isArray(page)) throw new Error("getSignaturesForAddress: no array result");
    pages++;
    count += page.length;
    for (const e of page) {
      if (!e) continue;
      // newest-first within the page, pages walk older: the LAST finite
      // blockTime seen across the whole walk is the oldest. Entries with
      // null blockTime (not yet finalized / pruned) are skipped, counted.
      if (Number.isFinite(e.blockTime)) { oldestBlockTime = e.blockTime; oldestSig = e.signature; }
      else nulls++;
    }
    if (page.length) before = page[page.length - 1].signature;
    if (page.length < SIG_PAGE_LIMIT) { exhausted = true; break; }
  }
  return {
    ageMin: oldestBlockTime !== null ? (nowMs - oldestBlockTime * 1000) / 60000 : null,
    pages, count, nulls, oldestSig, oldestBlockTime,
    exhausted, boundExceeded: !exhausted,
  };
}

// ---- source class 2: DexScreener, R-1 semantics ----
async function fetchDex(cfg, fetchImpl, token) {
  const data = await fetchJson(fetchImpl,
    cfg.dexscreenerBase + "/latest/dex/tokens/" + token,
    { headers: { accept: "application/json" } });
  const pairs = Array.isArray(data) ? data : (data && data.pairs) || [];
  // R-1 (RADAR_FIX_R1R2, declared INVALID otherwise): DexScreener indexes
  // the pump.fun bonding curve itself as dexId "pumpfun" ~60s after birth.
  // That curve entry is NOT discovery. Only a NON-pumpfun pair means the
  // token graduated to the real surface.
  const gradPairs = pairs.filter((p) => p && p.dexId && p.dexId !== "pumpfun");
  const curvePair = pairs.find((p) => p && p.dexId === "pumpfun") || null;
  const gradMc = gradPairs.length
    ? (Number(gradPairs[0].marketCap) || Number(gradPairs[0].fdv) || null)
    : null;
  return { pairs, gradPairs, curvePair, onDexScreener: gradPairs.length > 0, gradMc };
}

// ---- source class 3: radar tape + pump.fun frontend fallback ----
async function fetchRadar(cfg, fetchImpl, token) {
  const j = await fetchJson(fetchImpl, cfg.radarUrl + "/radar/candidates",
    { headers: { accept: "application/json" } });
  const live = ((j && j.live) || []).find((r) => r && r.token_address === token) || null;
  const early = ((j && j.early) || []).find((r) => r && r.token_address === token) || null;
  const ticks = (j && j.ticks && j.ticks[token]) || [];
  return { live, early, ticks, row: live || early };
}

async function fetchSessionGateReading(cfg, fetchImpl) {
  const j = await fetchJson(fetchImpl, cfg.radarUrl + "/radar/session-gate",
    { headers: { accept: "application/json" } });
  if (j && typeof j.ratio === "number" && "gate_pass" in j) return j;
  return null; // NO_READING_YET (nothing writes the sessions table)
}

async function fetchPumpFrontend(cfg, fetchImpl, token) {
  return fetchJson(fetchImpl, cfg.pumpfunBase + "/coins/" + token,
    { headers: { accept: "application/json" } });
}

// ============================================================
// gatherFacts(tokenAddress, deps) - THE entry point.
// deps: { fetchImpl = global fetch, env = process.env, now = Date.now }
// Never throws on fetch failure: failures become UNAVAILABLE facts and
// the caller (server.js) refuses fail-closed, naming the missing fact.
// ============================================================
async function gatherFacts(tokenAddress, deps = {}) {
  const fetchImpl = deps.fetchImpl || globalThis.fetch;
  const cfg = factsEnv(deps.env || process.env);
  const nowMs = typeof deps.now === "function" ? deps.now() : Date.now();

  const [rpcR, dexR, radarR, sgR, curveR, sigR] = await Promise.allSettled([
    fetchMintReads(cfg, fetchImpl, tokenAddress),
    fetchDex(cfg, fetchImpl, tokenAddress),
    fetchRadar(cfg, fetchImpl, tokenAddress),
    fetchSessionGateReading(cfg, fetchImpl),
    fetchCurveState(cfg, fetchImpl, tokenAddress),      // class 1: mc
    fetchOldestSignatureAge(cfg, fetchImpl, tokenAddress, nowMs), // class 1: ageMin
  ]);

  const facts = {};

  // ---- mintRenounced (Sec2): chain truth, never an assertion ----
  if (rpcR.status === "fulfilled" && rpcR.value.acct.status === "fulfilled") {
    const v = rpcR.value.acct.value;
    const parsed = v && v.value && v.value.data && v.value.data.parsed;
    const info = parsed && parsed.info;
    if (!info || parsed.type !== "mint") {
      facts.mintRenounced = unavailable("solana-rpc",
        "getAccountInfo(jsonParsed) did not return a parsed SPL mint - wrong address or unsupported program");
    } else {
      const mintAuth = info.mintAuthority ?? null;
      const freezeAuth = info.freezeAuthority ?? null;
      facts.mintRenounced = ok(mintAuth === null && freezeAuth === null, "solana-rpc",
        `getAccountInfo(jsonParsed): mintAuthority=${mintAuth === null ? "null" : mintAuth}, ` +
        `freezeAuthority=${freezeAuth === null ? "null" : freezeAuth} - renounced requires BOTH null`);
    }
  } else {
    const why = rpcR.status === "rejected" ? rpcR.reason
      : rpcR.value.acct.reason;
    facts.mintRenounced = unavailable("solana-rpc",
      "getAccountInfo failed: " + (why && why.message || why));
  }

  // ---- creatorHoldingPct (Sec2): creator address from the tape if
  // present; else the top-holder CONSERVATIVE PROXY, stated openly ----
  const radar = radarR.status === "fulfilled" ? radarR.value : null;
  const creatorAddr = radar && radar.row &&
    (radar.row.creator || radar.row.creator_address) || null;
  if (rpcR.status === "fulfilled") {
    const supplyOk = rpcR.value.supply.status === "fulfilled";
    const largestOk = rpcR.value.largest.status === "fulfilled";
    const supplyAmt = supplyOk
      ? Number(rpcR.value.supply.value && rpcR.value.supply.value.value &&
               rpcR.value.supply.value.value.amount) : NaN;
    if (creatorAddr && supplyOk && supplyAmt > 0) {
      try {
        const held = await fetchCreatorHolding(cfg, fetchImpl, creatorAddr, tokenAddress);
        facts.creatorHoldingPct = ok((held / supplyAmt) * 100, "solana-rpc",
          `creator wallet ${creatorAddr} (address from radar tape) holds via ` +
          `getTokenAccountsByOwner / getTokenSupply`);
      } catch (e) {
        facts.creatorHoldingPct = unavailable("solana-rpc",
          "creator holding read failed: " + (e && e.message || e));
      }
    } else if (supplyOk && largestOk && supplyAmt > 0) {
      const arr = (rpcR.value.largest.value && rpcR.value.largest.value.value) || [];
      const top = arr.length ? Number(arr[0].amount) : NaN;
      if (Number.isFinite(top)) {
        const topPct = (top / supplyAmt) * 100;
        facts.creatorHoldingPct = ok(topPct, "solana-rpc",
          "CONSERVATIVE PROXY - creator address not on the radar tape, so the " +
          `largest single token account (getTokenLargestAccounts, ${topPct.toFixed(2)}% ` +
          "of getTokenSupply) stands in for creator holding. For a pre-graduation " +
          "pump.fun token this INCLUDES the bonding curve, so it over-refuses " +
          "(fail-closed), never under. Never a silent substitute - this basis says so.");
      } else {
        facts.creatorHoldingPct = unavailable("solana-rpc",
          "getTokenLargestAccounts returned no holders");
      }
    } else {
      const why = !supplyOk ? rpcR.value.supply.reason
        : !largestOk ? rpcR.value.largest.reason : "zero/invalid supply";
      facts.creatorHoldingPct = unavailable("solana-rpc",
        "supply/holders read failed: " + (why && why.message || why));
    }
  } else {
    facts.creatorHoldingPct = unavailable("solana-rpc",
      "RPC unavailable: " + (rpcR.reason && rpcR.reason.message || rpcR.reason));
  }

  // ---- onDexScreener (Sec1 exit-3 / entry predicate): R-1 semantics ----
  const dex = dexR.status === "fulfilled" ? dexR.value : null;
  if (dex) {
    facts.onDexScreener = ok(dex.onDexScreener, "dexscreener",
      dex.onDexScreener
        ? `graduated: ${dex.gradPairs.length} non-pumpfun pair(s) ` +
          `(first dexId=${dex.gradPairs[0].dexId}). R-1: the curve entry alone never counts.`
        : (dex.curvePair
            ? "only the pump.fun bonding-curve index entry (dexId=pumpfun) exists - " +
              "R-1: that is NOT discovery/graduation"
            : "no pairs indexed at all - pre-discovery"));
  } else {
    facts.onDexScreener = unavailable("dexscreener",
      "DexScreener fetch failed: " + (dexR.reason && dexR.reason.message || dexR.reason));
  }

  // ---- lpLockedOrBurned (Sec2): derived, never asserted ----
  // Pre-graduation there IS no external LP - liquidity sits in the
  // program-owned bonding curve, which no creator can pull. Verified by
  // the ABSENCE of non-pumpfun pairs (R-1). Post-graduation an external
  // LP exists and this layer does not verify its lock/burn -> UNAVAILABLE
  // (fail-closed; entry is refused on onDexScreener anyway).
  if (dex && !dex.onDexScreener) {
    facts.lpLockedOrBurned = ok(true, "dexscreener",
      "pre-graduation pump.fun: no non-pumpfun pair exists (R-1), so there is no " +
      "external LP to lock or pull - liquidity is the program-owned bonding curve");
  } else if (dex) {
    facts.lpLockedOrBurned = unavailable("dexscreener",
      "token has graduated pairs; external LP lock/burn is NOT verified by this " +
      "layer - fail-closed");
  } else {
    facts.lpLockedOrBurned = unavailable("dexscreener",
      "cannot derive LP status without the DexScreener read");
  }

  // ---- ageMin + mc (Sec1): CHAIN-READ FIRST (class 1/2); the radar tape
  // is a cross-check (mc) or a fallback only when chain is unreachable ----
  let ageFact = null, mcFact = null;
  // the tape's freshest MC view, kept for the chain cross-check + fallback
  const L = radar && radar.live, E = radar && radar.early;
  let tapeMc = null, tapeMcBasis = null;
  if (radar) {
    const ticks = radar.ticks;
    if (ticks && ticks.length && Number.isFinite(Number(ticks[ticks.length - 1].mc))) {
      tapeMc = Number(ticks[ticks.length - 1].mc);
      tapeMcBasis = `radar mc_ticks, freshest tick (${new Date(ticks[ticks.length - 1].ms).toISOString()})`;
    } else if (L && Number.isFinite(Number(L.last_mc))) {
      tapeMc = Number(L.last_mc);
      tapeMcBasis = "radar tape live row last_mc";
    }
  }

  // -- mc, class 1: pre-graduation bonding-curve decode + class-2 SOL/USD --
  // Once a pre-graduation curve DECODES, the class-1 path is engaged and
  // there is NO class-3 fallback: a failed SOL/USD leg means UNAVAILABLE
  // (fail-closed), never a silent downgrade to advisory sources.
  const curveState = curveR.status === "fulfilled" ? curveR.value : null;
  if (curveState && curveState.decoded && !curveState.curve.complete) {
    const c = curveState.curve;
    let sol = null, solErr = null;
    try { sol = await fetchSolUsd(cfg, fetchImpl); } catch (e) { solErr = e; }
    if (sol) {
      const mcUsd = curveMcUsd({
        virtual_sol_reserves: Number(c.virtualSolReserves),
        virtual_token_reserves: Number(c.virtualTokenReserves),
        total_supply: Number(c.tokenTotalSupply),
      }, sol.solUsd);
      if (mcUsd !== null) {
        let basis = `bonding-curve PDA ${curveState.pda} (program ${PUMPFUN_PROGRAM}, ` +
          `seed "${CURVE_SEED}"+mint, bump ${curveState.bump}) decoded on-chain: ` +
          `vSol=${c.virtualSolReserves} vTok=${c.virtualTokenReserves} ` +
          `supply=${c.tokenTotalSupply} complete=false; ` +
          `MC=(vSol/vTok)*supply/1e9 SOL (radar/screen.ts curveMcUsd formula, ` +
          `verified to 5 decimals 2026-07-11) x ${sol.basis}`;
        if (tapeMc !== null) {
          basis += Math.abs(tapeMc - mcUsd) > 0.25 * Math.abs(mcUsd)
            ? ` | CROSS-CHECK DIVERGENCE: radar tape mc $${tapeMc} disagrees >25% ` +
              `with chain $${mcUsd.toFixed(2)} - chain wins, tape is advisory (${tapeMcBasis})`
            : ` | radar tape cross-check agrees within 25% ($${tapeMc})`;
        }
        mcFact = ok(mcUsd, "solana-rpc", basis);
      } else {
        mcFact = unavailable("solana-rpc",
          "bonding curve decoded but reserves are degenerate " +
          `(vTok=${c.virtualTokenReserves}) - refusing to price, fail-closed`);
      }
    } else {
      mcFact = unavailable("solana-rpc",
        "bonding curve decoded on-chain but the SOL/USD leg (DexScreener wSOL " +
        "pair) failed: " + (solErr && solErr.message || solErr) +
        " - fail-closed, never repriced from advisory (class-3) sources");
    }
  }

  // -- ageMin, class 1: oldest signature's blockTime --
  const sig = sigR.status === "fulfilled" ? sigR.value : null;
  if (sig && sig.boundExceeded) {
    // Past the pagination cap the walk PROVES only a lower bound - which
    // already fails the 4-7min entry window, the fail-closed direction.
    // No tape fallback here: the tape cannot out-know 5000+ signatures.
    ageFact = sig.ageMin !== null
      ? ok(sig.ageMin, "solana-rpc",
          `getSignaturesForAddress PAGINATION BOUND: ${sig.pages} pages / ` +
          `${sig.count} signatures walked without reaching the first transaction - ` +
          `age exceeds pagination bound, older than ${sig.ageMin.toFixed(2)}min ` +
          `(PROVEN LOWER BOUND; a token with thousands of signatures is far past ` +
          `the 4-7min pre-DEX entry window, so this value fails entry fail-closed)`)
      : unavailable("solana-rpc",
          `getSignaturesForAddress pagination bound (${sig.pages} pages / ` +
          `${sig.count} signatures) exceeded with no readable blockTime - fail-closed`);
  } else if (sig && sig.exhausted && sig.ageMin !== null) {
    ageFact = ok(sig.ageMin, "solana-rpc",
      `getSignaturesForAddress walked to exhaustion: oldest of ${sig.count} ` +
      `signature(s) over ${sig.pages} page(s) is ${sig.oldestSig} ` +
      `(blockTime ${new Date(sig.oldestBlockTime * 1000).toISOString()})` +
      (sig.nulls ? ` - ${sig.nulls} null-blockTime entr(y/ies) skipped` : ""));
  }
  // sig exhausted but empty/all-null, or the RPC read failed entirely:
  // fall through to the class-3 tape below (build-mode still gates; the
  // hot guard then honestly refuses on the non-chain source).

  if (radar) {
    let firstSeenMs = null, ageBasis = null;
    if (L && Number.isFinite(L.qualified_ms) && Number.isFinite(L.entry_age_sec)) {
      firstSeenMs = L.qualified_ms - L.entry_age_sec * 1000;
      ageBasis = "radar tape live row: qualified_ms - entry_age_sec (pump.fun first-seen)";
    } else if (E && Number.isFinite(E.first_hit_ms) && Number.isFinite(E.age_sec_at_hit)) {
      firstSeenMs = E.first_hit_ms - E.age_sec_at_hit * 1000;
      ageBasis = "radar tape early row: first_hit_ms - age_sec_at_hit (pump.fun first-seen)";
    }
    if (!ageFact && firstSeenMs !== null) {
      ageFact = ok((nowMs - firstSeenMs) / 60000, "radar", ageBasis);
    }
  }
  // graduated / curve-missing tokens: DexScreener MC is authoritative (class 2)
  if (!mcFact && dex && dex.onDexScreener && Number.isFinite(dex.gradMc)) {
    mcFact = ok(dex.gradMc, "dexscreener",
      "marketCap/fdv of the first graduated (non-pumpfun) pair" +
      (curveState && !curveState.decoded ? ` (curve PDA path: ${curveState.reason})` : ""));
  }
  // class-3 tape fallback - ONLY when no class-1/2 mc engaged above
  if (!mcFact && tapeMc !== null) {
    mcFact = ok(tapeMc, "radar", tapeMcBasis);
  }
  // pump.fun frontend fallback - ONLY when the tape misses the token and
  // the fields are trivially present. Class 3, advisory.
  if (!ageFact || !mcFact) {
    try {
      const p = await fetchPumpFrontend(cfg, fetchImpl, tokenAddress);
      if (!ageFact && p && Number.isFinite(Number(p.created_timestamp))) {
        ageFact = ok((nowMs - Number(p.created_timestamp)) / 60000,
          "pumpfun-frontend", "pump.fun frontend API created_timestamp");
      }
      if (!mcFact && p && Number.isFinite(Number(p.usd_market_cap))) {
        mcFact = ok(Number(p.usd_market_cap),
          "pumpfun-frontend", "pump.fun frontend API usd_market_cap");
      }
    } catch { /* fall through to UNAVAILABLE - never fabricate */ }
  }
  facts.ageMin = ageFact || unavailable("radar",
    "chain signature-walk unavailable" +
    (sigR.status === "rejected" ? ` (${sigR.reason && sigR.reason.message || sigR.reason})` : "") +
    ", token not on the radar tape, and pump.fun frontend age not trivially " +
    "available - fail-closed, never fabricated");
  facts.mc = mcFact || unavailable("radar",
    "chain curve read unavailable" +
    (curveR.status === "rejected" ? ` (${curveR.reason && curveR.reason.message || curveR.reason})` : "") +
    ", token not on the radar tape, no graduated pair MC, and pump.fun frontend " +
    "MC not trivially available - fail-closed, never fabricated");

  // ---- sessionGate (Sec0): live reading > ARCHITECT-ONLY override > REFUSE ----
  // No live source exists yet (/radar/session-gate answers NO_READING_YET;
  // nothing writes sessions). We still ask, so the day a session writer
  // lands the reading is used with zero code change here.
  let sessionGate;
  const reading = sgR.status === "fulfilled" ? sgR.value : null;
  if (reading) {
    sessionGate = {
      status: "ok", play: !!reading.gate_pass, ratio: reading.ratio,
      source: "radar",
      basis: `/radar/session-gate reading for ${reading.session_date}: ` +
        `ratio=${reading.ratio}, gate_pass=${reading.gate_pass}`,
    };
  } else if (cfg.sessionGateOverride) {
    sessionGate = {
      status: "OVERRIDE", play: true, ratio: null, source: "env-override",
      basis: "SESSION_GATE_OVERRIDE=pass - ARCHITECT-ONLY escape hatch for " +
        "supervised runs while Sec0 has no live data source. Not a reading; " +
        "logged as an override, never as a measurement.",
    };
  } else {
    sessionGate = {
      status: "UNAVAILABLE", play: false, ratio: null, source: "none",
      basis: "Sec0 session gate has NO live data source: /radar/session-gate " +
        "returns NO_READING_YET (nothing writes the sessions table). " +
        "Fail-closed - refusing rather than fabricating a regime reading. " +
        "ARCHITECT-ONLY override: SESSION_GATE_OVERRIDE=pass.",
    };
  }
  facts.sessionGate = sessionGate;

  // ---- roll-up ----
  const missing = GATE_CRITICAL.filter((k) => facts[k].status !== "ok");
  const nonChain = GATE_CRITICAL.filter(
    (k) => facts[k].status === "ok" && !CHAIN_SOURCES.has(facts[k].source));
  const gateFacts = {};
  for (const k of GATE_CRITICAL) if (facts[k].status === "ok") gateFacts[k] = facts[k].value;

  return {
    tokenAddress,
    fetchedAt: new Date(nowMs).toISOString(),
    facts,
    gateFacts,          // flat, ok-only values - what the pure gates consume
    missing,            // gate-critical facts that could not be fetched
    nonChain,           // fetched OK but from class-3 (advisory) sources
    allFetched: missing.length === 0,
    // The hot-path precondition (was the FACTS_VERIFIED_ON_DEVICE constant):
    // every gate-critical fact chain-read (class 1/2) on THIS call.
    allChainRead: missing.length === 0 && nonChain.length === 0,
  };
}

// ---- divergence: asserted hints vs fetched facts (W-2 audit trail) ----
// Booleans: strict mismatch. Numbers: relative drift > 20% (mc/age move
// naturally between the caller's read and ours; a small drift is not a lie).
function divergence(asserted = {}, gathered) {
  const out = [];
  if (!asserted || !gathered || !gathered.facts) return out;
  for (const k of GATE_CRITICAL) {
    if (asserted[k] === undefined) continue;
    const f = gathered.facts[k];
    if (!f || f.status !== "ok") continue;
    const a = asserted[k], v = f.value;
    let diverges;
    if (typeof v === "boolean" || typeof a === "boolean") diverges = a !== v;
    else {
      const an = Number(a), vn = Number(v);
      diverges = !Number.isFinite(an) ||
        Math.abs(an - vn) > 0.2 * Math.max(1, Math.abs(vn));
    }
    if (diverges) out.push({ fact: k, asserted: a, fetched: v, source: f.source });
  }
  return out;
}

// The refusal string when gate-critical facts are missing: NAMES the facts.
function refusalReason(gathered) {
  return "fail-closed: could not verify " + gathered.missing.join(", ") +
    " via server-side reads (" +
    gathered.missing.map((k) => gathered.facts[k].basis).join(" | ") +
    "). Never downgrading to caller-asserted facts.";
}

// ---- the hot-path facts precondition (replaces FACTS_VERIFIED_ON_DEVICE) ----
// ok:true ONLY when every gate-critical fact was chain-read (class 1/2)
// on this call. Caller assertions can never satisfy it; neither can the
// radar tape (class 3). With the curve-PDA mc and signature-walk ageMin
// (above), a live pre-DEX token CAN now be fully chain-read - but the
// tape/frontend FALLBACK paths still exist for RPC outages, and facts
// served by them keep this guard refusing (source class is per-fact,
// per-call). Even when this guard passes, sessionGate refuses build/hot
// separately until the radar grows a sessions writer (see gatherFacts).
function hotFactsGuard(gathered) {
  if (gathered && gathered.allChainRead === true) return { ok: true };
  const why = !gathered ? "no facts gathered"
    : gathered.missing && gathered.missing.length
      ? "unverified facts: " + gathered.missing.join(", ")
      : "facts fetched but not all chain-read (class-3 advisory sources): " +
        (gathered.nonChain || []).join(", ");
  return {
    ok: false,
    reason: "facts are not chain-read on this call - " + why +
      ". RULEBOOK Sec4 forbids hot execution on anything but the server's " +
      "own chain/API reads (AUDIT W-2); there is no constant to flip.",
  };
}

module.exports = {
  gatherFacts, divergence, refusalReason, hotFactsGuard,
  factsEnv, GATE_CRITICAL, CHAIN_SOURCES, FETCH_TIMEOUT_MS,
  // chain-read ageMin/mc internals, exported for terminal-proof tests
  derivePumpCurvePda, decodeBondingCurve, curveMcUsd,
  PUMPFUN_PROGRAM, BONDING_CURVE_DISCRIMINATOR, MAX_SIG_PAGES, SIG_PAGE_LIMIT,
};
