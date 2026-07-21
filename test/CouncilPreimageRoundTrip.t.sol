// SPDX-License-Identifier: MIT
// Round-trip proof (SPEC_CouncilSigner_v3 §8): the connector's viem-computed F3
// preimage must equal the contract's Solidity abi.encode formula for the same
// inputs — otherwise a one-field drift makes every published preimage fail to
// recompute and nobody can tell a bug from a lie.
//
// The vector below is produced by mcp/council-signer/preimage.js
// (proposalHash(0x1111...1111, 1000000, "0x")) and asserted identical to the
// contract-side keccak256(abi.encode(...)). The JS side asserts the same vector
// in mcp/council-signer/test/preimage.test.mjs — the two meet here.
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

contract CouncilPreimageRoundTripTest is Test {
    function test_connector_preimage_matches_solidity_abi_encode() public pure {
        address hook = 0x1111111111111111111111111111111111111111;
        bytes32 fromConnector = 0x0ce6e878504942fc9b2c97261f39155bd5bab981d7fd9a74b43a39e95e0099a0;
        bytes32 fromContract  = keccak256(abi.encode(hook, uint256(1_000_000), bytes("")));
        assertEq(fromContract, fromConnector, "connector preimage must equal the contract formula");
    }
}
