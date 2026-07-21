// Council Signer — the immutable binding. Loaded ONCE from env at process start,
// frozen, never mutated. Scoped to exactly one seat key, one hook, one chain
// (SPEC_CouncilSigner_v3 §1). No setter, no re-point (§7.5). Uses viem (the same
// EVM lib the console worker uses), so the statement domain matches byte-for-byte.
"use strict";
const { isAddress, getAddress } = require("viem");
const { privateKeyToAccount } = require("viem/accounts");

// The ONLY selectors this connector can ever reach on the bound hook (§7.2).
// savBurn is DELIBERATELY ABSENT (§2, §7.8) — burning is not voting, and a
// leaked connector must never destroy a seat's claim.
const HOOK_ABI = [
  { type: "function", name: "proposeInvent", stateMutability: "nonpayable", inputs: [{ name: "proposalHash", type: "bytes32" }], outputs: [] },
  { type: "function", name: "approveInvent", stateMutability: "nonpayable", inputs: [{ name: "proposalHash", type: "bytes32" }], outputs: [] },
  { type: "function", name: "approveInventBySig", stateMutability: "nonpayable", inputs: [{ name: "proposalHash", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "signature", type: "bytes" }], outputs: [] },
  { type: "function", name: "getProposalStatus", stateMutability: "view", inputs: [{ name: "proposalHash", type: "bytes32" }], outputs: [{ name: "approvals", type: "uint8" }, { name: "expiry", type: "uint256" }, { name: "executed", type: "bool" }] },
];
Object.freeze(HOOK_ABI);

// EIP-712 domain of the bound hook — must match PossessioHook's
// EIP712("PossessioHook","1") so approveInventBySig verifies on-chain.
const HOOK_DOMAIN_NAME = "PossessioHook";
const HOOK_DOMAIN_VERSION = "1";
const APPROVE_INVENT_TYPES = {
  ApproveInvent: [
    { name: "proposalHash", type: "bytes32" },
    { name: "expiry", type: "uint256" },
  ],
};

// Off-chain statement attribution (§2a) — its domain is DELIBERATELY distinct
// from the hook's (no chainId, no verifyingContract) so a statement signature can
// never be replayed as an on-chain vote (§7.4). Must match worker/index.ts.
const STATEMENT_DOMAIN = { name: "PossessioCouncilStatement", version: "1" };
const STATEMENT_TYPES = {
  Statement: [
    { name: "body", type: "string" },
    { name: "nonce", type: "uint256" },
  ],
};

// Exact raw key strings seen at load, used ONLY by redact() to mask them if they
// ever appear in a tool result or error. Never exposed. Matching the EXACT key
// (not a length pattern) avoids masking bytes32 hashes, which are also 64-hex.
const _secrets = new Set();

function loadBinding(env) {
  env = env || process.env;
  const seatKey = env.COUNCIL_SEAT_KEY;
  const hookAddress = env.COUNCIL_HOOK_ADDRESS;
  const chainId = Number(env.COUNCIL_CHAIN_ID);
  const rpcUrl = env.COUNCIL_RPC_URL || "";
  const ledgerUrl = env.COUNCIL_LEDGER_URL || "https://possessio.io/api/council/ledger";

  if (!seatKey || !/^0x[0-9a-fA-F]{64}$/.test(seatKey))
    throw new Error("COUNCIL_SEAT_KEY missing or not a 32-byte hex key");
  if (!hookAddress || !isAddress(hookAddress))
    throw new Error("COUNCIL_HOOK_ADDRESS missing or not a valid address");
  if (!Number.isInteger(chainId) || chainId <= 0)
    throw new Error("COUNCIL_CHAIN_ID missing or invalid");

  _secrets.add(seatKey.toLowerCase());
  _secrets.add(seatKey.slice(2).toLowerCase());
  const account = privateKeyToAccount(seatKey);
  const binding = {
    hookAddress: getAddress(hookAddress),
    chainId,
    rpcUrl,
    ledgerUrl,
    seatAddress: account.address,
  };
  // _account is non-enumerable: JSON.stringify(binding), Object.keys, and spreads
  // never surface the key material (§7.6).
  Object.defineProperty(binding, "_account", { value: account, enumerable: false, writable: false, configurable: false });
  return Object.freeze(binding);
}

// Scrub the exact seat key before anything leaves the process (§7.6) — belt over
// the non-enumerable-key suspenders. Masks only the exact key (and its no-0x
// form), so bytes32 hashes and 65-byte signatures pass through unharmed.
function redact(value) {
  let s = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  for (const k of _secrets) if (k) s = s.split(k).join("<redacted-seat-key>");
  return s;
}

module.exports = {
  loadBinding, redact,
  HOOK_ABI, HOOK_DOMAIN_NAME, HOOK_DOMAIN_VERSION, APPROVE_INVENT_TYPES,
  STATEMENT_DOMAIN, STATEMENT_TYPES,
};
