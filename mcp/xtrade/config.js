// ============================================================
// xtrade config - the Trading Agent's Constitution, in code.
// Source of truth: RULEBOOK_TradingAgent.md v1.0 (RATIFIED 2026-07-04)
//   and SPEC_CrossChainTradingMCP.md.
//
// LAW  = ratified line-by-line; frozen. Changing a value here is a
//        constitutional amendment (RULEBOOK Sec6) - not a code edit.
// TUNE = adjustable BY RATIFICATION (a starting point, not frozen);
//        the ledger (Sec5) is the only acceptable evidence to change it.
// ============================================================
"use strict";

// ---- Sec1 method numbers + Sec3 caps: RATIFIED, frozen ----
const LAW = Object.freeze({
  // Sec1 exits (mc = market cap USD)
  takeProfitMc: 20000,   // trigger 1: +~2x, thesis paid
  stopLossMc:    6000,   // trigger 2: thesis failed
  timeStopMin:     10,   // trigger 4: window closed
  // Sec1 entry
  entryAgeMinLo:    4,   // minutes alive, low bound (past instant-rug)
  entryAgeMinHi:    7,   // minutes alive, high bound (before stale)
  // Sec3 caps (server-enforced, never client-trusted)
  maxNotionalUsd:      2,
  maxTradesPerDay:    10,
  maxDailyExposureUsd:20,
  maxSlippageBps:    200,
  // Sec1 scope
  venue: "pump.fun",
  chain: "solana",
  preDexOnly: true,      // token must NOT be on DexScreener at entry
});

// ---- adjustable BY RATIFICATION (flagged NON-frozen starting points) ----
const TUNE = {
  // Sec0 session gate: sit out if trailing vol < cutoff * 7d avg.
  // Rulebook says ~60-70%; 0.65 is the mid starting point, NOT tuned yet.
  sessionGateCutoff: 0.65,   // [NON-RATIFIED starting point, RULEBOOK Sec7]

  // Sec2 rug gate: creator wallet holds <= this % of supply.
  rugMaxCreatorPct: 15,      // [default, UNCONFIRMED by Architect, RULEBOOK Sec7]

  // Sec1 entry MC target ~$10,000. The band edges were NOT given a
  // number; this is a flagged placeholder pending ratification. The
  // build_trade path treats a token outside this band as a skip.
  entryMcTarget: 10000,
  entryMcBandLo:  8000,      // [NON-RATIFIED band edge - see spec Non-Proven]
  entryMcBandHi: 12000,      // [NON-RATIFIED band edge - see spec Non-Proven]
};

// Env-driven runtime config (keys/paths NEVER hardcoded, NEVER logged).
function runtimeEnv(env = process.env) {
  return {
    allowHot:   env.ALLOW_HOT === "1",
    hasSigner:  !!env.TRADING_SIGNER_KEY,   // presence only; value never read here
    ledgerPath: env.LEDGER_PATH || "mcp/xtrade/ledger.jsonl",
    jupiterBase:env.JUPITER_BASE || "https://lite-api.jup.ag/swap/v1",
    solanaRpc:  env.SOLANA_RPC || "",
    // Caps are LAW; env may only make them STRICTER, never looser.
    maxNotionalUsd:   tighten(env.MAX_NOTIONAL_USD, LAW.maxNotionalUsd, "min"),
    maxSlippageBps:   tighten(env.MAX_SLIPPAGE_BPS, LAW.maxSlippageBps, "min"),
    maxTradesPerDay:  tighten(env.MAX_TRADES_PER_DAY, LAW.maxTradesPerDay, "min"),
    maxDailyExposureUsd: tighten(env.MAX_DAILY_EXPOSURE_USD, LAW.maxDailyExposureUsd, "min"),
  };
}

// A cap from env is honored ONLY if it is stricter than LAW. A looser
// env value is ignored - LAW is a ceiling env cannot raise.
function tighten(envVal, lawVal, dir) {
  const n = Number(envVal);
  if (!Number.isFinite(n) || n <= 0) return lawVal;
  return dir === "min" ? Math.min(n, lawVal) : Math.max(n, lawVal);
}

module.exports = { LAW, TUNE, runtimeEnv, tighten };
