// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HandshakeLib
/// @notice Self-contained hashing + Merkle verification for MerkleHandshakeAuth.
///         Bundled in-repo on purpose (NOT an external auth module reference), per
///         the self-contained / full-primitive discipline (SPEC S6).
///
/// @dev LOAD-BEARING BYTE DISCIPLINE. Must match script/gen_proof.py exactly:
///        inner   = sha256( abi.encode(secret, caller) )   // 64-byte preimage
///        leaf    = sha256( abi.encode(inner) )             // 32-byte preimage (double hash)
///        node(a,b) = sha256( abi.encodePacked(lo, hi) )    // sorted-pair, 64-byte preimage
///      If the off-chain builder diverges by ONE byte, every real proof fails.
///      That divergence-intolerance is a FEATURE (proven on-chain by vm.ffi, off-chain
///      by script/selftest_offchain.py).
///
///      Why sha256 (not keccak): the leaf is mempool-exposed, but sha256 preimage
///      resistance (Grover-halved to ~128-bit) is uncrackable inside the pending-tx
///      window even at quantum speed, and the proof is single-use. The terminal
///      attack is not fought - it is MOOTED (SPEC S1). This library is the structural
///      sidestep itself.
library HandshakeLib {
    /// @notice leaf = sha256(sha256(abi.encode(secret, caller)))
    /// @dev abi.encode(bytes32, address) => 64 bytes (address left-padded to 32).
    ///      Matches gen_proof.hash_leaf().
    function hashLeaf(bytes32 secret, address caller) internal pure returns (bytes32) {
        bytes32 inner = sha256(abi.encode(secret, caller));
        // abi.encode(bytes32) == 32 bytes, identical to packing a single word.
        return sha256(abi.encode(inner));
    }

    /// @notice sorted-pair parent node: sha256(min(a,b) || max(a,b))
    function hashNode(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b
            ? sha256(abi.encodePacked(a, b))
            : sha256(abi.encodePacked(b, a));
    }

    /// @notice Recompute the root from a leaf and a bottom-up sibling proof.
    ///         Mirror of gen_proof.verify() / make_proof().
    function processProof(bytes32 leaf, bytes32[] memory proof)
        internal
        pure
        returns (bytes32 computedRoot)
    {
        computedRoot = leaf;
        uint256 len = proof.length;
        for (uint256 i = 0; i < len; ) {
            computedRoot = hashNode(computedRoot, proof[i]);
            unchecked { ++i; }
        }
    }

    /// @notice True iff `proof` proves `leaf` is a member of the tree under `root`.
    function verify(bytes32 root, bytes32 leaf, bytes32[] memory proof)
        internal
        pure
        returns (bool)
    {
        return processProof(leaf, proof) == root;
    }
}
