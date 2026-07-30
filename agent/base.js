// The Base side: read the authored intent, watch for opened remote legs,
// return proceeds to the Rail, and fire the two keeper calls.
//
// This module NEVER creates an intent. The intent-authoring function is
// deliberately absent from every ABI here, and the DoD greps for it — the
// human-picks law is enforced by absence, and the absence is tested.
"use strict";

const { CFG } = require("./config");

const RAIL_ABI = [
  {
    type: "event", name: "RemoteLegOpened",
    inputs: [
      { indexed: true, name: "intentId", type: "uint256" },
      { indexed: false, name: "usdcOut", type: "uint256" },
      { indexed: true, name: "agent", type: "address" },
    ],
  },
  { type: "function", name: "settleRemoteLeg", stateMutability: "nonpayable",
    inputs: [{ name: "intentId", type: "uint256" }], outputs: [] },
  { type: "function", name: "positions", stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [
      { name: "token", type: "address" }, { name: "usdcIn", type: "uint256" },
      { name: "tokenAmount", type: "uint256" }, { name: "status", type: "uint8" },
      { name: "viaWeth", type: "bool" }, { name: "feeA", type: "uint24" },
      { name: "feeB", type: "uint24" }, { name: "openedAt", type: "uint64" },
      { name: "usdcSnapshot", type: "uint256" },
    ] },
];

const AUTOTARGET_ABI = [
  { type: "function", name: "intents", stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [
      { name: "user", type: "address" }, { name: "tokenRef", type: "bytes32" },
      { name: "chainTag", type: "uint32" }, { name: "entryPrice", type: "uint256" },
      { name: "targetBps", type: "uint16" }, { name: "stopBps", type: "uint16" },
      { name: "status", type: "uint8" }, { name: "exitKind", type: "uint8" },
      { name: "usdcReturned", type: "uint256" },
    ] },
  { type: "function", name: "resolveIntent", stateMutability: "nonpayable",
    inputs: [{ name: "id", type: "uint256" }, { name: "observedPrice", type: "uint256" }],
    outputs: [] },
];

const ERC20_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "transfer", stateMutability: "nonpayable",
    inputs: [{ name: "to", type: "address" }, { name: "v", type: "uint256" }],
    outputs: [{ type: "bool" }] },
];

function makeClients() {
  const { createPublicClient, createWalletClient, http } = require("viem");
  const { base } = require("viem/chains");
  const pub = createPublicClient({ chain: base, transport: http(CFG.baseRpc) });
  let wallet = null, account = null;
  if (CFG.baseKeeperKey) {
    const { privateKeyToAccount } = require("viem/accounts");
    account = privateKeyToAccount(CFG.baseKeeperKey);
    wallet = createWalletClient({ account, chain: base, transport: http(CFG.baseRpc) });
  }
  return { pub, wallet, account };
}

/// The mint a Solana intent points at. AutoTarget stores tokenRef as bytes32,
/// which is exactly the width of a Solana pubkey — so a mint round-trips with
/// no truncation. (An EVM address uses the low 20 bytes instead.)
function mintFromTokenRef(tokenRef) {
  const bs58 = require("bs58");
  return bs58.encode(Buffer.from(tokenRef.slice(2), "hex"));
}

async function readIntent(pub, intentId) {
  const r = await pub.readContract({
    address: CFG.autoTarget, abi: AUTOTARGET_ABI, functionName: "intents", args: [BigInt(intentId)],
  });
  return {
    user: r[0], tokenRef: r[1], chainTag: Number(r[2]), entryPrice: r[3],
    targetBps: Number(r[4]), stopBps: Number(r[5]), status: Number(r[6]),
  };
}

async function usdcBalance(pub, who) {
  return pub.readContract({
    address: CFG.usdcBase, abi: ERC20_ABI, functionName: "balanceOf", args: [who],
  });
}

/// Send the trade's proceeds back to the Rail. The Rail then MEASURES what
/// arrived — this amount is never reported to it, only delivered.
async function returnProceedsToRail(wallet, amountAtomic) {
  if (CFG.dryRun) return { dryRun: true, hash: null };
  const hash = await wallet.writeContract({
    address: CFG.usdcBase, abi: ERC20_ABI, functionName: "transfer",
    args: [CFG.rail, amountAtomic],
  });
  return { dryRun: false, hash };
}

async function resolveIntent(wallet, intentId, observedPrice) {
  if (CFG.dryRun) return { dryRun: true, hash: null };
  const hash = await wallet.writeContract({
    address: CFG.autoTarget, abi: AUTOTARGET_ABI, functionName: "resolveIntent",
    args: [BigInt(intentId), BigInt(observedPrice)],
  });
  return { dryRun: false, hash };
}

async function settleRemoteLeg(wallet, intentId) {
  if (CFG.dryRun) return { dryRun: true, hash: null };
  const hash = await wallet.writeContract({
    address: CFG.rail, abi: RAIL_ABI, functionName: "settleRemoteLeg", args: [BigInt(intentId)],
  });
  return { dryRun: false, hash };
}

/// Poll for legs opened to this agent since `fromBlock`. Polling rather than a
/// socket subscription on purpose: it survives an RPC restart with no state.
async function pollOpenedLegs(pub, agentAddress, fromBlock) {
  const latest = await pub.getBlockNumber();
  if (fromBlock > latest) return { legs: [], nextBlock: fromBlock };
  const logs = await pub.getContractEvents({
    address: CFG.rail, abi: RAIL_ABI, eventName: "RemoteLegOpened",
    args: { agent: agentAddress }, fromBlock, toBlock: latest,
  });
  return {
    legs: logs.map((l) => ({
      intentId: l.args.intentId.toString(),
      usdcOut: l.args.usdcOut,
      block: l.blockNumber,
      tx: l.transactionHash,
    })),
    nextBlock: latest + 1n,
  };
}

module.exports = {
  makeClients, mintFromTokenRef, readIntent, usdcBalance,
  returnProceedsToRail, resolveIntent, settleRemoteLeg, pollOpenedLegs,
  RAIL_ABI, AUTOTARGET_ABI, ERC20_ABI,
};
