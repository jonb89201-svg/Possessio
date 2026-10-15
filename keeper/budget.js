// RPC BUDGET — the keeper can see what it spends, and stops before it overspends.
//
// v1 had "NO PERCEPTION OF COST" (keeper/index.js): a billed read and a free one
// look identical at the call site, so ~245M reads went by in three weeks with
// nothing in the loop noticing. Here every RPC request goes through a metered
// connection, counted against a daily ceiling. Past the ceiling the keeper makes
// no further RPC calls until the next UTC day, and says so loudly.
//
// Architect directive 2026-10-15: no overages, no QuickNode. The endpoint guard
// below refuses QuickNode outright. The default endpoint is Solana's public RPC,
// which rate-limits rather than bills, so the ceiling is the second wall, not
// the only one.
"use strict";

const PUBLIC_RPC = "https://api.mainnet-beta.solana.com";

class BudgetExhausted extends Error {
  constructor(used, limit) { super(`RPC budget exhausted: ${used}/${limit} today`); this.name = "BudgetExhausted"; }
}

const utcDay = (ms) => Math.floor(ms / 86400000);

function createBudget({ dailyLimit, clock = Date.now, onExhausted = () => {} }) {
  if (!Number.isInteger(dailyLimit) || dailyLimit <= 0) throw new Error("dailyLimit must be a positive integer");
  let day = utcDay(clock()), used = 0, total = 0, refused = 0, tripped = false;
  const byMethod = {};
  const roll = () => { const d = utcDay(clock()); if (d !== day) { day = d; used = 0; refused = 0; tripped = false; for (const k in byMethod) delete byMethod[k]; } };
  return {
    /// Charge one request. Throws BudgetExhausted instead of making it.
    spend(method, n = 1) {
      roll();
      if (used + n > dailyLimit) {
        refused += n;
        if (!tripped) { tripped = true; onExhausted({ used, limit: dailyLimit }); }
        throw new BudgetExhausted(used, dailyLimit);
      }
      used += n; total += n;
      byMethod[method] = (byMethod[method] || 0) + n;
    },
    ok() { roll(); return used < dailyLimit; },
    // refused: requests turned away today. An exhausted keeper should go quiet,
    // not keep knocking, so this stays near zero.
    report() { roll(); return { day, used, limit: dailyLimit, total, refused, byMethod: { ...byMethod } }; },
  };
}

// Every Connection method that makes a network request. Anything else on the
// object (commitment, rpcEndpoint, helpers) passes through untouched.
const METERED = new Set([
  "getAccountInfo", "getMultipleAccountsInfo", "getParsedAccountInfo", "getTokenAccountBalance",
  "getLatestBlockhash", "getSignatureStatus", "getSignatureStatuses", "getSlot", "getBalance",
  "sendRawTransaction", "sendTransaction", "simulateTransaction", "confirmTransaction",
  "getProgramAccounts", "getTransaction",
  "onAccountChange", "onSignature", "onLogs", "onSlotChange", "onProgramAccountChange",
]);

// confirmTransaction subscribes and polls signature statuses internally; charge
// it as several requests so the meter over-counts rather than under-counts.
const WEIGHT = { confirmTransaction: 5 };

/// Wrap a web3.js Connection so every request is charged to the budget first.
/// A method the keeper calls that is not listed is refused, so a new call site
/// cannot quietly bypass the meter.
function meteredConnection(connection, budget) {
  return new Proxy(connection, {
    get(target, prop, recv) {
      const v = Reflect.get(target, prop, recv);
      if (typeof v !== "function" || typeof prop !== "string") return v;
      if (prop.startsWith("remove") || prop === "constructor") return v.bind(target);
      if (METERED.has(prop)) return (...a) => { budget.spend(prop, WEIGHT[prop] || 1); return v.apply(target, a); };
      // Private helpers spl-token reaches for, and anything unknown: refuse.
      if (prop.startsWith("_")) return v.bind(target);
      return () => { throw new Error(`unmetered RPC method "${prop}" — add it to METERED before using it`); };
    },
  });
}

/// Refuse endpoints the Architect has ruled out, and anything not https/wss.
function assertAllowedRpc(url) {
  let u;
  try { u = new URL(url); } catch { throw new Error(`SOLANA_RPC_URL is not a URL`); }
  if (!/^(https|wss):$/.test(u.protocol)) throw new Error(`SOLANA_RPC_URL must be https`);
  if (/quiknode|quicknode/i.test(u.hostname)) throw new Error("QuickNode is not allowed (Architect directive 2026-10-15). Use the public RPC or a free-tier endpoint.");
  return u.toString();
}

module.exports = { PUBLIC_RPC, BudgetExhausted, createBudget, meteredConnection, assertAllowedRpc, METERED, WEIGHT };
