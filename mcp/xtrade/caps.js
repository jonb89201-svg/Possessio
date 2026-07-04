// RULEBOOK Sec3 - caps. Server-enforced, never client-trusted.
"use strict";

// caps: the effective (LAW, possibly env-tightened) cap set from runtimeEnv.
// state: { todayCount, todayExposureUsd } read from the ledger (Sec5).
function checkCaps({ notionalUsd, slippageBps, todayCount, todayExposureUsd }, caps) {
  const fails = [];
  const n = Number(notionalUsd), s = Number(slippageBps);

  if (!Number.isFinite(n) || n <= 0)
    fails.push("notional must be a positive number");
  else if (n > caps.maxNotionalUsd)
    fails.push(`notional $${n} exceeds max $${caps.maxNotionalUsd}/trade`);

  if (!Number.isFinite(s) || s < 0)
    fails.push("slippage must be a non-negative number");
  else if (s > caps.maxSlippageBps)
    fails.push(`slippage ${s}bps exceeds ceiling ${caps.maxSlippageBps}bps`);

  if (Number(todayCount) >= caps.maxTradesPerDay)
    fails.push(`daily trade count ${todayCount} at/over max ${caps.maxTradesPerDay}`);

  if (Number(todayExposureUsd) + (Number.isFinite(n) ? n : 0) > caps.maxDailyExposureUsd)
    fails.push(
      `would push daily exposure to $${Number(todayExposureUsd) + n} over max $${caps.maxDailyExposureUsd}`
    );

  return { ok: fails.length === 0, fails };
}

module.exports = { checkCaps };
