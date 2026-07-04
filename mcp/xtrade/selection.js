// RULEBOOK Sec2 - Identity & Selection Law.
// F-1 (absolute): mutating calls accept CONTRACT ADDRESSES ONLY.
// A symbol/ticker in a buy/sell call is a REFUSAL, not a lookup.
"use strict";

class RefusalError extends Error {
  constructor(msg) { super(msg); this.name = "RefusalError"; this.refusal = true; }
}

// Solana mint = base58, 32-44 chars (base58 excludes 0 O I l).
const SOL_MINT = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

// Enforce F-1 on any mutating call. Returns the address if valid;
// THROWS RefusalError otherwise. A ticker like "AERO"/"$AERO" fails the
// base58 length test and is refused - which is the entire point (a live
// "aerodrome" query returned 1 real token and 22 seeded impostors).
function assertContractAddress(id) {
  if (typeof id !== "string" || !SOL_MINT.test(id.trim())) {
    throw new RefusalError(
      "F-1: mutating calls accept a Solana contract address only, never a " +
      "symbol/ticker. Resolve the symbol in the read-only search layer, " +
      "review candidates + spam scores, then pass the exact mint address."
    );
  }
  return id.trim();
}

// RULEBOOK Sec2 rug gate. Pure evaluator over facts fetched on-device
// (mint/LP/creator% come from chain reads - see server device-verify).
// Any sub-check false -> skip the token. No override.
function rugGate({ mintRenounced, lpLockedOrBurned, creatorHoldingPct }, tune) {
  const fails = [];
  if (mintRenounced !== true) fails.push("mint authority not renounced");
  if (lpLockedOrBurned !== true) fails.push("LP not locked or burned");
  const pct = Number(creatorHoldingPct);
  if (!Number.isFinite(pct)) fails.push("creator holding % unknown");
  else if (pct > tune.rugMaxCreatorPct)
    fails.push(`creator holds ${pct}% > max ${tune.rugMaxCreatorPct}%`);
  return { ok: fails.length === 0, fails };
}

module.exports = { assertContractAddress, rugGate, RefusalError, SOL_MINT };
