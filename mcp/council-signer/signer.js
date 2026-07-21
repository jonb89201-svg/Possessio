// The scoped signer. Every signature/tx it can produce is bound to the seat +
// hook + chain (SPEC_CouncilSigner_v3 §7). There is NO function that takes an
// arbitrary `to`, an arbitrary selector, a transfer/approve/raw call, or a second
// hook — the surface itself is the sandbox. The chain guard (§7.7) refuses to
// sign anything when the connected chain != the bound chainId.
"use strict";
const { createPublicClient, createWalletClient, http, encodeFunctionData } = require("viem");
const cfg = require("./config");

// A minimal chain object built from the immutable binding (viem needs a chain to
// send). rpcUrls point only at the bound RPC; id is the bound chainId.
function boundChain(binding) {
  return {
    id: binding.chainId,
    name: "bound",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [binding.rpcUrl] } },
  };
}
function publicClient(binding) {
  if (!binding.rpcUrl) throw new Error("no COUNCIL_RPC_URL configured for on-chain calls");
  return createPublicClient({ chain: boundChain(binding), transport: http(binding.rpcUrl) });
}

// §7.7 — refuse to sign/submit anything when the connected chain is not the bound
// chain. A connector pointed at mainnet while the operator believes it is testnet
// is how a practice vote becomes real.
async function guardChain(binding, pub) {
  const id = await pub.getChainId();
  if (Number(id) !== binding.chainId)
    throw new Error(`ChainMismatch: bound to ${binding.chainId}, connected to ${id} — refusing to sign`);
}

// ── statement (EIP-712, off-chain attribution; SIGNS, NEVER submits — §7.4) ──
async function signStatement(binding, body, nonce) {
  const signature = await binding._account.signTypedData({
    domain: cfg.STATEMENT_DOMAIN, types: cfg.STATEMENT_TYPES, primaryType: "Statement",
    message: { body, nonce: BigInt(nonce) },
  });
  return { seat: binding.seatAddress, body, nonce: String(nonce), signature };
}

// ── approveInventBySig (EIP-712 vote; a relayer submits; seat pays no gas) ──
async function approveBySig(binding, proposalHash, expiry) {
  const domain = {
    name: cfg.HOOK_DOMAIN_NAME, version: cfg.HOOK_DOMAIN_VERSION,
    chainId: binding.chainId, verifyingContract: binding.hookAddress,
  };
  const signature = await binding._account.signTypedData({
    domain, types: cfg.APPROVE_INVENT_TYPES, primaryType: "ApproveInvent",
    message: { proposalHash, expiry: BigInt(expiry) },
  });
  return { proposalHash, expiry: String(expiry), signature, seat: binding.seatAddress, hook: binding.hookAddress, chainId: binding.chainId };
}

// ── direct tx (to == bound hook ONLY — §7.1; only allowlisted selectors — §7.2) ──
async function submitCouncilTx(binding, fnName, args) {
  const pub = publicClient(binding);
  await guardChain(binding, pub);                                   // §7.7
  const data = encodeFunctionData({ abi: cfg.HOOK_ABI, functionName: fnName, args }); // §7.2
  const wallet = createWalletClient({ account: binding._account, chain: boundChain(binding), transport: http(binding.rpcUrl) });
  const hash = await wallet.sendTransaction({ to: binding.hookAddress, data }); // §7.1 — `to` is hardcoded
  return { hash, to: binding.hookAddress, fn: fnName };
}
async function proposeInvent(binding, proposalHash) { return submitCouncilTx(binding, "proposeInvent", [proposalHash]); }
async function approveInvent(binding, proposalHash) { return submitCouncilTx(binding, "approveInvent", [proposalHash]); }

async function status(binding, proposalHash) {
  const pub = publicClient(binding);
  const [approvals, expiry, executed] = await pub.readContract({
    address: binding.hookAddress, abi: cfg.HOOK_ABI, functionName: "getProposalStatus", args: [proposalHash],
  });
  return { proposalHash, approvals: Number(approvals), expiry: String(expiry), executed };
}

module.exports = { guardChain, signStatement, approveBySig, proposeInvent, approveInvent, status };
