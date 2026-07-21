import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { proposalHash } = require("../preimage.js");

const HOOK = "0x1111111111111111111111111111111111111111";
// The single canonical vector — also asserted in test/CouncilPreimageRoundTrip.t.sol
// against keccak256(abi.encode(hook, 1000000, bytes(""))). If these two ever
// disagree, the connector and the contract have drifted (SPEC §8).
const VECTOR = "0x0ce6e878504942fc9b2c97261f39155bd5bab981d7fd9a74b43a39e95e0099a0";

test("preimage matches the Solidity round-trip vector", () => {
  assert.equal(proposalHash(HOOK, 1000000n, "0x"), VECTOR);
});

test("preimage is deterministic and type-agnostic on amount", () => {
  assert.equal(proposalHash(HOOK, 1000000n, "0x"), proposalHash(HOOK, "1000000", "0x"));
  assert.equal(proposalHash(HOOK, 1000000, "0x"), VECTOR);
});

test("every field changes the hash (abi.encode, collision-safe)", () => {
  const base = proposalHash(HOOK, 1000000n, "0x");
  assert.notEqual(base, proposalHash("0x2222222222222222222222222222222222222222", 1000000n, "0x"));
  assert.notEqual(base, proposalHash(HOOK, 1000001n, "0x"));
  assert.notEqual(base, proposalHash(HOOK, 1000000n, "0x01"));
});

test("empty metadata normalizes '' -> '0x'", () => {
  assert.equal(proposalHash(HOOK, 1000000n, ""), VECTOR);
  assert.equal(proposalHash(HOOK, 1000000n, null), VECTOR);
});

test("bad inputs throw (not silently mis-encode)", () => {
  assert.throws(() => proposalHash("not-an-address", 1n, "0x"));
  assert.throws(() => proposalHash(HOOK, 1n, "0xZZ"));
  assert.throws(() => proposalHash(HOOK, 1n, "0x1")); // odd-length hex
});
