// The CANONICAL F3 preimage formula — SPEC_CouncilSigner_v3 §4/§8. The ONE place
// it lives on the connector side. The hook computes the same thing in Solidity:
//     keccak256(abi.encode(address(this), amount, metadata))
// Single-sourced + round-trip tested against the contract's own vector
// (test/preimage.test.mjs), so a one-field drift can't silently make every
// published preimage fail to recompute.
"use strict";
const { keccak256, encodeAbiParameters, getAddress, isAddress } = require("viem");

/**
 * @param {string} hookAddress  the bound hook (address(this) in the contract)
 * @param {bigint|string|number} amount  the invent amount (uint256)
 * @param {string} metadata  0x-prefixed hex bytes ("0x" for empty)
 * @returns {string} the proposalHash the contract's ProposalHashMismatch check uses
 */
function proposalHash(hookAddress, amount, metadata) {
  if (!isAddress(hookAddress)) throw new Error("proposalHash: bad hookAddress");
  const md = metadata == null || metadata === "" ? "0x" : metadata;
  if (!/^0x([0-9a-fA-F]{2})*$/.test(md)) throw new Error("proposalHash: metadata must be 0x-hex bytes");
  const enc = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "bytes" }],
    [getAddress(hookAddress), BigInt(amount), md]
  );
  return keccak256(enc);
}

module.exports = { proposalHash };
