// Config for the remote (Solana) execution agent.
// EVERY secret comes from the environment. Nothing here is ever written to
// disk or logged; `redacted()` is what the logger is allowed to print.
"use strict";

function need(name) {
  const v = process.env[name];
  if (!v || !String(v).trim()) throw new Error(`missing required env: ${name}`);
  return String(v).trim();
}
function opt(name, dflt) {
  const v = process.env[name];
  return v == null || !String(v).trim() ? dflt : String(v).trim();
}

const CFG = {
  // ── chains ────────────────────────────────────────────────────────────
  baseRpc: need("BASE_RPC_URL"),
  solanaRpc: need("SOLANA_RPC_URL"),
  jupiterBase: opt("JUPITER_BASE", "https://lite-api.jup.ag/swap/v1"),

  // ── the deployed organs (Base) ────────────────────────────────────────
  rail: need("RAIL_ADDRESS"),
  autoTarget: need("AUTOTARGET_ADDRESS"),
  usdcBase: opt("USDC_BASE", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),

  // ── Solana mints ──────────────────────────────────────────────────────
  usdcSolana: opt("USDC_SOLANA", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),

  // ── keys (never logged) ───────────────────────────────────────────────
  baseKeeperKey: process.env.BASE_KEEPER_KEY || "",
  solanaAgentKey: process.env.SOLANA_AGENT_KEY || "",

  // ── safety ────────────────────────────────────────────────────────────
  // DRY_RUN does everything except sign. Default ON: this service must be
  // switched into live mode deliberately, never by forgetting a flag.
  dryRun: opt("DRY_RUN", "1") !== "0",
  // The agent's OWN ceiling, independent of the vault's caps. Defence in
  // depth: a bug on the Base side that drew too much still cannot make this
  // process spend more than the operator allowed here.
  maxTradeUsdc: Number(opt("MAX_TRADE_USDC", "250")),
  slippageBps: Number(opt("SLIPPAGE_BPS", "300")),
  // Float health. Below these, the operator should rebalance (off trade path).
  floatMinSolanaUsdc: Number(opt("FLOAT_MIN_SOLANA_USDC", "200")),
  floatMinBaseUsdc: Number(opt("FLOAT_MIN_BASE_USDC", "200")),
  // Loop cadence.
  pollMs: Number(opt("POLL_MS", "3000")),
  priceMs: Number(opt("PRICE_MS", "4000")),
  // A leg the agent could not finish is never silently abandoned; it is logged
  // loudly and left for the operator (the contract's own timeout governs).
  legTimeoutMs: Number(opt("LEG_TIMEOUT_MS", String(6 * 60 * 60 * 1000))),
};

function assertRunnable() {
  if (!CFG.dryRun) {
    if (!CFG.baseKeeperKey) throw new Error("live mode needs BASE_KEEPER_KEY");
    if (!CFG.solanaAgentKey) throw new Error("live mode needs SOLANA_AGENT_KEY");
  }
  if (!(CFG.maxTradeUsdc > 0)) throw new Error("MAX_TRADE_USDC must be > 0");
  if (!(CFG.slippageBps > 0 && CFG.slippageBps <= 2000)) {
    throw new Error("SLIPPAGE_BPS out of sane range (1..2000)");
  }
}

/// What the logger may print. Keys are never included, not even truncated.
function redacted() {
  return {
    mode: CFG.dryRun ? "DRY_RUN (signs nothing)" : "LIVE",
    rail: CFG.rail,
    autoTarget: CFG.autoTarget,
    maxTradeUsdc: CFG.maxTradeUsdc,
    slippageBps: CFG.slippageBps,
    hasBaseKey: Boolean(CFG.baseKeeperKey),
    hasSolanaKey: Boolean(CFG.solanaAgentKey),
  };
}

module.exports = { CFG, assertRunnable, redacted };
