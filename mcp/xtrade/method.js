// RULEBOOK Sec1 - The Method. Entry band + four exit triggers.
// Mechanical: first trigger to fire wins, no judgment calls.
"use strict";

// ENTRY (all must hold): pre-DEX, age 4-7 min, MC in the entry band.
// facts: { onDexScreener, ageMin, mc }
function entryOk(facts, law, tune) {
  const fails = [];
  if (facts.onDexScreener === true)
    fails.push("already on DexScreener - the pre-discovery edge is gone");
  const age = Number(facts.ageMin);
  if (!Number.isFinite(age) || age < law.entryAgeMinLo || age > law.entryAgeMinHi)
    fails.push(`age ${facts.ageMin}min outside ${law.entryAgeMinLo}-${law.entryAgeMinHi}min`);
  const mc = Number(facts.mc);
  if (!Number.isFinite(mc) || mc < tune.entryMcBandLo || mc > tune.entryMcBandHi)
    fails.push(
      `entry MC ${facts.mc} outside band $${tune.entryMcBandLo}-$${tune.entryMcBandHi} ` +
      `(band edges NON-RATIFIED - see spec Non-Proven)`
    );
  return { ok: fails.length === 0, fails };
}

// EXIT: evaluate all four; if several are true at once, priority follows
// the rulebook's numbered table (take-profit, stop-loss, edge-loss,
// time-stop). In live monitoring "first to fire" is temporal; at a single
// evaluation this priority is the deterministic tiebreak.
// state: { mc, onDexScreener, elapsedMin }
function exitTrigger(state, law) {
  const mc = Number(state.mc);
  if (Number.isFinite(mc) && mc >= law.takeProfitMc)
    return sell(1, "take-profit", `MC >= $${law.takeProfitMc}`);
  if (Number.isFinite(mc) && mc <= law.stopLossMc)
    return sell(2, "stop-loss", `MC <= $${law.stopLossMc}`);
  if (state.onDexScreener === true)
    return sell(3, "edge-loss", "token appeared on DexScreener - thesis rule, sell at market");
  if (Number(state.elapsedMin) >= law.timeStopMin)
    return sell(4, "time-stop", `${law.timeStopMin}min elapsed`);
  return { sell: false };
}

function sell(trigger, name, reason) {
  return { sell: true, trigger, name, reason };
}

module.exports = { entryOk, exitTrigger };
