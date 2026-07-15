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
// from source class 1 or 2 on THIS call. Today ageMin/mc have no class-1/2
// source (pump.fun first-seen lives only on the tape), so allChainRead is
// false for every pre-DEX token and the hot path keeps refusing - honestly
// computed instead of hardcoded. That is the intended posture until a
// chain-read age/MC source (curve-account decode or signature-walk) lands
// and is ratified.
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

  const [rpcR, dexR, radarR, sgR] = await Promise.allSettled([
    fetchMintReads(cfg, fetchImpl, tokenAddress),
    fetchDex(cfg, fetchImpl, tokenAddress),
    fetchRadar(cfg, fetchImpl, tokenAddress),
    fetchSessionGateReading(cfg, fetchImpl),
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

  // ---- ageMin + mc (Sec1): radar tape first, pump.fun frontend fallback ----
  let ageFact = null, mcFact = null;
  if (radar) {
    const L = radar.live, E = radar.early;
    let firstSeenMs = null, ageBasis = null;
    if (L && Number.isFinite(L.qualified_ms) && Number.isFinite(L.entry_age_sec)) {
      firstSeenMs = L.qualified_ms - L.entry_age_sec * 1000;
      ageBasis = "radar tape live row: qualified_ms - entry_age_sec (pump.fun first-seen)";
    } else if (E && Number.isFinite(E.first_hit_ms) && Number.isFinite(E.age_sec_at_hit)) {
      firstSeenMs = E.first_hit_ms - E.age_sec_at_hit * 1000;
      ageBasis = "radar tape early row: first_hit_ms - age_sec_at_hit (pump.fun first-seen)";
    }
    if (firstSeenMs !== null) {
      ageFact = ok((nowMs - firstSeenMs) / 60000, "radar", ageBasis);
    }
    const ticks = radar.ticks;
    if (ticks && ticks.length) {
      const last = ticks[ticks.length - 1];
      if (Number.isFinite(Number(last.mc))) {
        mcFact = ok(Number(last.mc), "radar",
          `radar mc_ticks, freshest tick (${new Date(last.ms).toISOString()})`);
      }
    }
    if (!mcFact && L && Number.isFinite(Number(L.last_mc))) {
      mcFact = ok(Number(L.last_mc), "radar", "radar tape live row last_mc");
    }
  }
  // graduated tokens: DexScreener MC is authoritative (class 2)
  if (!mcFact && dex && dex.onDexScreener && Number.isFinite(dex.gradMc)) {
    mcFact = ok(dex.gradMc, "dexscreener",
      "marketCap/fdv of the first graduated (non-pumpfun) pair");
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
    "token not on the radar tape and pump.fun frontend age not trivially " +
    "available - fail-closed, never fabricated");
  facts.mc = mcFact || unavailable("radar",
    "token not on the radar tape, no graduated pair MC, and pump.fun frontend " +
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
// radar tape (class 3). Today ageMin/mc have no class-1/2 source, so this
// refuses for every pre-DEX token - honest computation, same posture.
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
};
