// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";

/// @notice Harness exposing the internal library surface for direct testing.
contract HandshakeHarness {
    function hashLeaf(bytes32 secret, address caller) external pure returns (bytes32) {
        return HandshakeLib.hashLeaf(secret, caller);
    }
    function hashNode(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return HandshakeLib.hashNode(a, b);
    }
    function processProof(bytes32 leaf, bytes32[] memory proof) external pure returns (bytes32) {
        return HandshakeLib.processProof(leaf, proof);
    }
    function verify(bytes32 root, bytes32 leaf, bytes32[] memory proof) external pure returns (bool) {
        return HandshakeLib.verify(root, leaf, proof);
    }
}

/// @notice DIRECT gauntlet for HandshakeLib — the cryptographic floor under
///         MerkleHandshakeAuth. Prior to this file the library was exercised ONLY
///         transitively through SymmetryGuardCore's proof-forgery/replay tests; the
///         census flagged that as the weakest-certified security-critical surface.
///         This suite hardens the lib in isolation: byte-discipline KAT, leaf
///         binding, sorted-pair commutativity, proof round-trip + tamper rejection,
///         and — the sharp one — the second-preimage boundary that makes the lib's
///         safety CONSUMER-DEPENDENT.
contract HandshakeLibGauntlet is Test {
    HandshakeHarness internal h;

    function setUp() public {
        h = new HandshakeHarness();
    }

    // ============================ BYTE-DISCIPLINE KAT ============================
    // Known-answer vector computed INDEPENDENTLY (Node.js crypto, off-chain), not
    // by re-running the contract. If hashLeaf's encoding/double-hash ever changes by
    // one byte, this breaks — which is the whole point (every real proof would fail).
    // leaf = sha256(sha256(abi.encode(bytes32 secret, address caller)))
    function test_KAT_hashLeaf_byte_for_byte() public view {
        bytes32 secret = bytes32(uint256(1));
        address caller = address(uint160(1));
        bytes32 inner = sha256(abi.encode(secret, caller));
        assertEq(
            inner,
            0xc3c3a46684c07d12a9c238787df3049a6f258e7af203e5ddb66a8bd66637e108,
            "inner preimage hash drifted"
        );
        assertEq(
            h.hashLeaf(secret, caller),
            0xa504636ef166683af6a46453f69b3217677e620234705da530fb28161d2bd563,
            "hashLeaf drifted from the independent KAT"
        );
    }

    // ============================ LEAF BINDS TO CALLER ==========================
    // The front-run defense: a leaf is a function of (secret, caller). Same secret,
    // different caller => different leaf. Same caller, different secret => different
    // leaf. This is what makes a copied (secret,proof) useless from another address.
    function test_leaf_binds_to_caller() public view {
        bytes32 s = keccak256("s");
        assertTrue(h.hashLeaf(s, address(0xA11CE)) != h.hashLeaf(s, address(0xB0B)),
            "same secret, different caller must give different leaves");
    }
    function test_leaf_binds_to_secret() public view {
        address c = address(0xA11CE);
        assertTrue(h.hashLeaf(keccak256("s1"), c) != h.hashLeaf(keccak256("s2"), c),
            "same caller, different secret must give different leaves");
    }
    function testFuzz_leaf_distinct_per_input(bytes32 s1, bytes32 s2, address c1, address c2) public view {
        vm.assume(s1 != s2 || c1 != c2);
        assertTrue(h.hashLeaf(s1, c1) != h.hashLeaf(s2, c2),
            "distinct (secret,caller) must not collide (sha256 second-preimage)");
    }

    // ============================ SORTED-PAIR NODE ==============================
    // hashNode must be order-independent (sorted pair) — this is what lets a proof
    // omit sibling side-bits. If it were order-sensitive, valid proofs would fail
    // half the time depending on tree position.
    function test_hashNode_commutes_concrete() public view {
        bytes32 a = bytes32(uint256(0x1111) << 240);
        bytes32 b = bytes32(uint256(0x2222) << 240);
        assertEq(h.hashNode(a, b), h.hashNode(b, a), "hashNode must be commutative");
    }
    function testFuzz_hashNode_commutes(bytes32 a, bytes32 b) public view {
        assertEq(h.hashNode(a, b), h.hashNode(b, a), "hashNode must commute for all inputs");
    }
    function test_hashNode_equal_inputs() public view {
        bytes32 a = keccak256("x");
        assertEq(h.hashNode(a, a), sha256(abi.encodePacked(a, a)), "equal inputs hash the pair");
    }

    // ============================ PROOF ROUND-TRIP =============================
    // Build a real 4-leaf tree in-test; every membership proof must reconstruct the
    // root; any tampered sibling or leaf must NOT.
    function _tree() internal view returns (bytes32 L0, bytes32 L1, bytes32 L2, bytes32 L3, bytes32 root) {
        L0 = h.hashLeaf(keccak256("s0"), address(0x10));
        L1 = h.hashLeaf(keccak256("s1"), address(0x11));
        L2 = h.hashLeaf(keccak256("s2"), address(0x12));
        L3 = h.hashLeaf(keccak256("s3"), address(0x13));
        bytes32 n01 = h.hashNode(L0, L1);
        bytes32 n23 = h.hashNode(L2, L3);
        root = h.hashNode(n01, n23);
    }
    function test_valid_proof_reconstructs_root() public view {
        (bytes32 L0, bytes32 L1, bytes32 L2, bytes32 L3, bytes32 root) = _tree();
        bytes32 n23 = h.hashNode(L2, L3);
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = L1;   // sibling of L0
        proof[1] = n23;  // sibling of n01
        assertTrue(h.verify(root, L0, proof), "valid membership proof must verify");
    }
    function test_tampered_sibling_fails() public view {
        (bytes32 L0, bytes32 L1,, bytes32 L3, bytes32 root) = _tree();
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = L1;
        proof[1] = bytes32(uint256(h.hashNode(L0, L3)) ^ 1); // corrupted upper sibling
        assertFalse(h.verify(root, L0, proof), "a tampered proof element must not verify");
    }
    function test_nonmember_leaf_fails() public view {
        (bytes32 L0, bytes32 L1, bytes32 L2, bytes32 L3, bytes32 root) = _tree();
        bytes32 n23 = h.hashNode(L2, L3);
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = L1;
        proof[1] = n23;
        bytes32 outsider = h.hashLeaf(keccak256("not-in-tree"), address(0x99));
        assertFalse(h.verify(root, outsider, proof), "a non-member leaf must not verify");
    }

    // ==================== SECOND-PREIMAGE BOUNDARY (the sharp one) ==============
    // HandshakeLib.verify() is a bare sorted-pair Merkle check with NO leaf/node
    // domain separation. Therefore an INTERNAL NODE presented as a "leaf" verifies:
    // verify(root, n01, [n23]) == hashNode(n01, n23) == root. This is the classic
    // Merkle second-preimage shape. It is NOT a lib bug — it is a boundary the LIB
    // cannot close on its own. The safety comes entirely from the CONSUMER never
    // accepting a caller-supplied leaf: SymmetryGuardCore.register() reconstructs
    // leaf = hashLeaf(secret, msg.sender), so an attacker cannot inject n01 as a leaf
    // (there is no (secret,msg.sender) whose hashLeaf equals n01 without a sha256
    // preimage). This test LOCKS that boundary so nobody refactors the guard to take
    // a precomputed leaf from calldata (its S6.1 invariant) without this failing loudly.
    function test_internal_node_verifies_as_leaf_consumer_must_bind() public view {
        (bytes32 L0, bytes32 L1, bytes32 L2, bytes32 L3, bytes32 root) = _tree();
        bytes32 n01 = h.hashNode(L0, L1);
        bytes32 n23 = h.hashNode(L2, L3);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = n23;
        // The bare Merkle primitive DOES accept the internal node as a leaf:
        assertTrue(h.verify(root, n01, proof),
            "SECURITY BOUNDARY: bare verify() accepts an internal node as a leaf; consumers MUST reconstruct the leaf from msg.sender and never accept a caller-supplied leaf");
    }

    // ============================ EDGE: EMPTY PROOF ============================
    // processProof([]) returns the leaf, so verify(x, x, []) is true for a
    // single-node tree. The CONSUMER (guard) rejects proof.length == 0 with
    // BadAuthData, so this lib edge is closed one layer up — assert both facts.
    function test_empty_proof_is_identity() public view {
        bytes32 x = keccak256("solo");
        bytes32[] memory empty = new bytes32[](0);
        assertEq(h.processProof(x, empty), x, "empty proof is identity on the leaf");
        assertTrue(h.verify(x, x, empty), "verify(root==leaf, leaf, []) is true - guard must gate len==0");
    }

    // ============================ DETERMINISM ============================
    function testFuzz_hashLeaf_deterministic(bytes32 s, address c) public view {
        assertEq(h.hashLeaf(s, c), h.hashLeaf(s, c), "pure hashing must be deterministic");
    }
}
