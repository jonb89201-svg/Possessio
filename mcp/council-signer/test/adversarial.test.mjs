// The §7 adversarial surface as a target, not a retrofit. Each test is a line the
// connector must be UNABLE to cross. (§7 lines that require a live chain — actually
// broadcasting a tx to a wrong `to` — are structurally impossible because no tool
// or function accepts a `to`; we prove that structurally here.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);

// A well-known throwaway test key (anvil #0) — never a real seat.
process.env.COUNCIL_SEAT_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
process.env.COUNCIL_HOOK_ADDRESS = "0x1111111111111111111111111111111111111111";
process.env.COUNCIL_CHAIN_ID = "8453";

const cfg = require("../config.js");
const signer = require("../signer.js");
const { recoverTypedDataAddress, getAddress } = require("viem");

const KEY = process.env.COUNCIL_SEAT_KEY;
const KEY_NO0X = KEY.slice(2).toLowerCase();
const SEAT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // address of anvil #0
const binding = cfg.loadBinding();

test("§7.5 — binding is frozen; there is no way to re-point the hook or chain", () => {
  assert.ok(Object.isFrozen(binding));
  assert.throws(() => { binding.hookAddress = "0x2222222222222222222222222222222222222222"; });
  assert.throws(() => { binding.chainId = 1; });
});

test("§7.6 — the key is never enumerable and never serializes", () => {
  assert.ok(!Object.keys(binding).includes("_account"));
  assert.ok(!JSON.stringify(binding).toLowerCase().includes(KEY_NO0X));
});

test("§7.2/§7.8 — the ABI allowlist is exactly the council selectors; no savBurn/transfer/approve/execute/slash", () => {
  const names = cfg.HOOK_ABI.map((f) => f.name).sort();
  assert.deepEqual(names, ["approveInvent", "approveInventBySig", "getProposalStatus", "proposeInvent"]);
  for (const bad of ["savBurn", "transfer", "approve", "executeInvent", "savSlash", "rescueToken"])
    assert.ok(!names.includes(bad), `${bad} must be absent`);
});

test("server surface (§2/§7): exactly the seven council_* tools, and NEVER a burn or raw-call tool", () => {
  const src = readFileSync(new URL("../server.js", import.meta.url), "utf8");
  const tools = [...src.matchAll(/server\.tool\("([a-z_]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(tools, [
    "council_approve", "council_approve_by_sig", "council_post", "council_propose",
    "council_read_feed", "council_sign_statement", "council_status",
  ]);
  assert.ok(!tools.some((t) => /burn/i.test(t)), "no burn tool in the surface");
  assert.ok(!/server\.tool\("[a-z_]*(?:transfer|approve_token|call|send|burn)[a-z_]*"/i.test(src), "no transfer/raw-call/send/burn tool");
});

test("redact masks the exact seat key but leaves bytes32 hashes and 65-byte sigs intact", () => {
  const hash = "0x0ce6e878504942fc9b2c97261f39155bd5bab981d7fd9a74b43a39e95e0099a0"; // 64 hex
  const sig = "0x" + "ab".repeat(65); // 130 hex
  assert.ok(cfg.redact("k=" + KEY).includes("<redacted-seat-key>"));
  assert.ok(!cfg.redact("k=" + KEY).toLowerCase().includes(KEY_NO0X));
  assert.equal(cfg.redact("h=" + hash), "h=" + hash);
  assert.equal(cfg.redact("s=" + sig), "s=" + sig);
});

test("§2a/§7.4 — a statement signature attributes to the seat but can NEVER pass as a vote", async () => {
  const st = await signer.signStatement(binding, "the -82% tail is rug-driven", "42");
  assert.equal(getAddress(st.seat), getAddress(SEAT));
  // recovers to the seat under the statement domain (attribution works)
  const asStatement = await recoverTypedDataAddress({
    domain: cfg.STATEMENT_DOMAIN, types: cfg.STATEMENT_TYPES, primaryType: "Statement",
    message: { body: "the -82% tail is rug-driven", nonce: 42n }, signature: st.signature,
  });
  assert.equal(getAddress(asStatement), getAddress(SEAT));
  // interpreted as a vote (hook domain / ApproveInvent), it recovers to SOMEONE
  // ELSE — so approveInventBySig's onlyCouncilMember check rejects it.
  const asVote = await recoverTypedDataAddress({
    domain: { name: cfg.HOOK_DOMAIN_NAME, version: cfg.HOOK_DOMAIN_VERSION, chainId: 8453, verifyingContract: binding.hookAddress },
    types: cfg.APPROVE_INVENT_TYPES, primaryType: "ApproveInvent",
    message: { proposalHash: "0x" + "00".repeat(32), expiry: 0n }, signature: st.signature,
  });
  assert.notEqual(getAddress(asVote), getAddress(SEAT), "a statement must not recover as a valid vote");
});

test("§4 — an approveBySig signature IS a valid vote: recovers to the seat under the hook domain", async () => {
  const ph = "0x0ce6e878504942fc9b2c97261f39155bd5bab981d7fd9a74b43a39e95e0099a0";
  const v = await signer.approveBySig(binding, ph, "9999999999");
  const rec = await recoverTypedDataAddress({
    domain: { name: cfg.HOOK_DOMAIN_NAME, version: cfg.HOOK_DOMAIN_VERSION, chainId: 8453, verifyingContract: binding.hookAddress },
    types: cfg.APPROVE_INVENT_TYPES, primaryType: "ApproveInvent",
    message: { proposalHash: ph, expiry: 9999999999n }, signature: v.signature,
  });
  assert.equal(getAddress(rec), getAddress(SEAT));
});

test("§7.7 — the chain guard refuses to sign when the connected chain != bound chainId", async () => {
  await assert.rejects(signer.guardChain(binding, { getChainId: async () => 999 }), /ChainMismatch/);
  await signer.guardChain(binding, { getChainId: async () => 8453 }); // matches -> no throw
});

test("§7.6 — leak sweep: no signing output contains the raw key", async () => {
  const outs = [
    JSON.stringify(await signer.signStatement(binding, "x", "1")),
    JSON.stringify(await signer.approveBySig(binding, "0x" + "00".repeat(32), "1")),
    JSON.stringify({ seat: binding.seatAddress, hook: binding.hookAddress, chainId: binding.chainId }),
  ];
  for (const o of outs) assert.ok(!o.toLowerCase().includes(KEY_NO0X), "raw key leaked in a tool output");
});
