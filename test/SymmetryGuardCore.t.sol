// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SymmetryGuardCore} from "../src/SymmetryGuardCore.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";

/// Concrete harness over the abstract v3 core. Exposes the internal guard hook so
/// the V4-independent logic can be gauntleted directly (no V4 compile needed).
contract CoreHarness is SymmetryGuardCore {
    constructor(bytes32 root, uint256 dustFloor) SymmetryGuardCore(root, dustFloor) {}
    function observe(address sender, bytes32 poolId, bool zeroForOne, uint256 absIn) external {
        _observe(sender, poolId, zeroForOne, absIn);
    }
    function hashLeafPub(bytes32 secret, address caller) external pure returns (bytes32) {
        return HandshakeLib.hashLeaf(secret, caller);
    }
}

/// @notice v3 V4-INDEPENDENT gauntlet. Handshake teeth + spine carried from v2;
///         behavioral section rewritten for the typed additive toll (base + typed
///         penalties, itemized, total-clamped, self-curing). Runs with only forge-std.
contract SymmetryGuardCoreGauntlet is Test {
    CoreHarness internal core;

    bytes32 constant S0 = bytes32(uint256(0x01) * (2**248) | 0x1111);
    bytes32 constant S1 = bytes32(uint256(0x02) * (2**248) | 0x2222);
    bytes32 constant S2 = bytes32(uint256(0x03) * (2**248) | 0x3333);
    bytes32 constant S3 = bytes32(uint256(0x04) * (2**248) | 0x4444);

    address constant A0 = address(0xa0A0000000000000000000000000000000000001);
    address constant A1 = address(0xA1A1000000000000000000000000000000000002);
    address constant A2 = address(0xA2A2000000000000000000000000000000000003);
    address constant A3 = address(0xA3A3000000000000000000000000000000000004);

    bytes32 constant POOL = keccak256("POOL/A");
    bytes32 constant POOL2 = keccak256("POOL/B");

    uint256 constant DUST = 1e6;        // $1 floor @ 6dp
    uint256 constant LEG  = 100e6;      // $100: normal (not small, not dust)
    uint256 constant SMALL = 2e6;       // $2: in dust-spam band [1e6, 5e6)

    uint256 constant BASE = 200;        // mirror of core BASE_FEE_BPS
    uint256 constant MAXTOTAL = 500;    // mirror of core MAX_TOTAL_FEE_BPS

    // re-declared for vm.expectEmit (event lives in the core)
    event Tolled(address indexed sender, bytes32 indexed poolId,
                 uint256 baseBps, uint256 roundTripBps, uint256 dustBps, uint256 totalBpsAfterClamp);

    // -------- ffi byte-discipline helpers --------
    function _toHex32(bytes32 v) internal pure returns (string memory) { return vm.toString(v); }
    function _toHex20(address a) internal pure returns (string memory) { return vm.toString(a); }
    function _word(bytes memory b, uint256 wordIndex) internal pure returns (bytes32 w) {
        uint256 off = wordIndex * 32;
        require(b.length >= off + 32, "word oob");
        assembly { w := mload(add(add(b, 0x20), off)) }
    }
    function _ffiRoot() internal returns (bytes32 root) {
        string[] memory c = new string[](12);
        c[0]="python3"; c[1]="script/gen_proof.py"; c[2]="root"; c[3]="4";
        c[4]=_toHex32(S0); c[5]=_toHex20(A0);
        c[6]=_toHex32(S1); c[7]=_toHex20(A1);
        c[8]=_toHex32(S2); c[9]=_toHex20(A2);
        c[10]=_toHex32(S3); c[11]=_toHex20(A3);
        bytes memory out = vm.ffi(c);
        root = _word(out, 0);
    }
    function _ffiProof(uint256 i) internal returns (bytes32 root, bytes32[] memory proof) {
        string[] memory c = new string[](13);
        c[0]="python3"; c[1]="script/gen_proof.py"; c[2]="proof";
        c[3]=vm.toString(i); c[4]="4";
        c[5]=_toHex32(S0); c[6]=_toHex20(A0);
        c[7]=_toHex32(S1); c[8]=_toHex20(A1);
        c[9]=_toHex32(S2); c[10]=_toHex20(A2);
        c[11]=_toHex32(S3); c[12]=_toHex20(A3);
        bytes memory out = vm.ffi(c);
        require(out.length >= 32 && (out.length - 32) % 32 == 0, "bad ffi blob");
        root = _word(out, 0);
        uint256 n = (out.length - 32) / 32;
        proof = new bytes32[](n);
        for (uint256 k = 0; k < n; k++) proof[k] = _word(out, k + 1);
    }

    function setUp() public {
        bytes32 root = _ffiRoot();
        core = new CoreHarness(root, DUST);
    }

    // ================= HANDSHAKE TEETH + ffi BYTE-MATCH (carried) =================
    function test_ffi_leaf_matches_onchain() public {
        string[] memory cc = new string[](5);
        cc[0]="python3"; cc[1]="script/gen_proof.py"; cc[2]="leaf";
        cc[3]=_toHex32(S0); cc[4]=_toHex20(A0);
        bytes memory out = vm.ffi(cc);
        assertEq(_word(out,0), core.hashLeafPub(S0,A0), "ffi leaf must match on-chain byte-for-byte");
    }
    function test_register_valid_fresh() public {
        (, bytes32[] memory proof) = _ffiProof(0);
        vm.prank(A0); core.register(S0, proof);
        assertTrue(core.registered(A0));
    }
    function test_register_replay_reverts() public {
        (, bytes32[] memory proof) = _ffiProof(0);
        vm.prank(A0); core.register(S0, proof);
        vm.prank(A0); vm.expectRevert(SymmetryGuardCore.AlreadyUsed.selector);
        core.register(S0, proof);
    }
    function test_garbage_proof_not_authorized_and_not_consumed() public {
        (, bytes32[] memory good) = _ffiProof(0);
        good[0] = bytes32(uint256(good[0]) ^ 1);
        bytes32 leaf = core.hashLeafPub(S0, A0);
        vm.prank(A0); vm.expectRevert(SymmetryGuardCore.NotAuthorized.selector);
        core.register(S0, good);
        assertFalse(core.consumed(leaf), "leaf must NOT be consumed on failed verify");
    }
    /// S6.1 front-run closed: a copied (secret,proof) raced from the WRONG address
    /// reverts, because the leaf is reconstructed from msg.sender.
    function test_copied_proof_from_wrong_addr_reverts() public {
        (, bytes32[] memory proof) = _ffiProof(0);
        vm.prank(A1); vm.expectRevert(SymmetryGuardCore.NotAuthorized.selector);
        core.register(S0, proof);
    }
    function test_truncated_bad_auth_data() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(A0); vm.expectRevert(SymmetryGuardCore.BadAuthData.selector);
        core.register(S0, empty);
    }

    // ================= SPINE S9 (single-use survives repeated swaps) =================
    function test_spine_single_use_survives_repeated_swaps() public {
        (, bytes32[] memory proof) = _ffiProof(0);
        bytes32 leaf = core.hashLeafPub(S0, A0);
        vm.prank(A0); core.register(S0, proof);
        assertTrue(core.consumed(leaf), "nullifier burned at registration");
        for (uint256 i = 0; i < 25; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, i % 2 == 0, LEG); }
        assertTrue(core.consumed(leaf), "nullifier still burned after repeated swaps");
        vm.prank(A0); vm.expectRevert(SymmetryGuardCore.AlreadyUsed.selector);
        core.register(S0, proof);
    }

    // ================= S6.3 HONEST PATH = BASE ONLY =================
    function test_honest_pays_exactly_base() public {
        // varied honest one-way flow, spaced; no trigger of any kind.
        for (uint256 i = 0; i < 12; i++) { vm.roll(block.number + 10); core.observe(A1, POOL, true, LEG + i * DUST); }
        (uint256 b, uint256 rt, uint256 d, uint256 t) = core.feeBreakdown(A1, POOL);
        assertEq(t, BASE, "honest total must be exactly base");
        assertEq(rt, 0, "no round-trip penalty"); assertEq(d, 0, "no dust penalty"); assertEq(b, BASE);
        assertFalse(core.isFlaggedRoundTrip(A1, POOL));
        assertFalse(core.isFlaggedDustSpam(A1, POOL));
    }

    /// FIX1 carried: honest high-volume whale (round-trips a MINORITY of flow) = base only.
    function test_FIX1_honest_whale_not_flagged() public {
        bool dir = true;
        for (uint256 cycle = 0; cycle < 10; cycle++) {
            vm.roll(block.number + 1); core.observe(A0, POOL, dir, LEG);
            vm.roll(block.number + 1); core.observe(A0, POOL, !dir, LEG);
            for (uint256 j = 0; j < 8; j++) { vm.roll(block.number + 1); core.observe(A0, POOL, true, LEG + j * DUST); }
            dir = !dir;
        }
        assertGt(core.guardObservations(A0, POOL), 50);
        assertEq(core.totalFeeBps(A0, POOL), BASE, "FIX1: honest whale pays base only");
        assertFalse(core.isFlaggedRoundTrip(A0, POOL));
    }

    function test_FIX1_small_sample_never_flagged() public {
        bool dir = true;
        for (uint256 i = 0; i < 4; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, dir, LEG); dir = !dir; }
        assertFalse(core.isFlaggedRoundTrip(A0, POOL));
        assertEq(core.totalFeeBps(A0, POOL), BASE);
    }

    // ================= ROUND-TRIP TRIGGER =================
    function test_roundtrip_extractor_base_plus_penalty() public {
        bool dir = true;
        for (uint256 i = 0; i < 16; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, dir, LEG); dir = !dir; }
        (, uint256 rt, uint256 d, uint256 t) = core.feeBreakdown(A0, POOL);
        assertTrue(core.isFlaggedRoundTrip(A0, POOL));
        assertGt(rt, 0, "round-trip penalty scales");
        assertEq(d, 0, "no dust trigger (legs are normal size)");
        assertGt(t, BASE); assertLe(t, MAXTOTAL);
    }

    function test_borderline_small_penalty_never_frozen() public {
        bool dir = true;
        for (uint256 i = 0; i < 6; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, dir, LEG); dir = !dir; }
        (, uint256 rt, , uint256 t) = core.feeBreakdown(A0, POOL);
        assertGt(rt, 0, "borderline still flagged");
        assertLt(t, MAXTOTAL, "borderline is a small penalty, never frozen");
    }

    // ================= DUST-SPAM TRIGGER =================
    function test_dust_spammer_base_plus_penalty() public {
        // same-direction small flood, rapid (no round-trip mirroring).
        for (uint256 i = 0; i < 14; i++) { vm.roll(block.number + 2); core.observe(A0, POOL, true, SMALL); }
        (, uint256 rt, uint256 d, uint256 t) = core.feeBreakdown(A0, POOL);
        assertTrue(core.isFlaggedDustSpam(A0, POOL));
        assertGt(d, 0, "dust penalty scales");
        assertEq(rt, 0, "no round-trip (same direction)");
        assertGt(t, BASE); assertLe(t, MAXTOTAL);
    }

    /// FALSE-POSITIVE GUARD (provisional-constant validation): an honest small trader
    /// whose legs are spaced BEYOND the rolling window never clusters -> NOT dust-flagged.
    function test_honest_spaced_small_trader_not_flagged() public {
        for (uint256 i = 0; i < 30; i++) { vm.roll(block.number + 21); core.observe(A0, POOL, true, SMALL); }
        assertFalse(core.isFlaggedDustSpam(A0, POOL), "spaced small trader must NOT trip dust-spam");
        assertEq(core.totalFeeBps(A0, POOL), BASE);
    }

    function test_FIX2_subfloor_legs_excluded() public {
        for (uint256 i = 0; i < 30; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, i % 2 == 0, DUST - 1); }
        assertEq(core.guardObservations(A0, POOL), 0, "sub-floor legs do not count");
        assertEq(core.guardDustHits(A0, POOL), 0, "sub-floor legs do not feed dust-spam");
        assertEq(core.totalFeeBps(A0, POOL), BASE);
    }

    // ================= BOTH TRIGGERS, ADDITIVE, CLAMPED =================
    function test_both_triggers_additive_and_clamped() public {
        // small + mirrored + alternating + rapid => trips BOTH.
        bool dir = true;
        for (uint256 i = 0; i < 60; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, dir, SMALL); dir = !dir; }
        (uint256 b, uint256 rt, uint256 d, uint256 t) = core.feeBreakdown(A0, POOL);
        assertTrue(core.isFlaggedRoundTrip(A0, POOL));
        assertTrue(core.isFlaggedDustSpam(A0, POOL));
        assertGt(rt, 0); assertGt(d, 0);
        assertEq(t, MAXTOTAL, "sum clamps to total ceiling");
        // S4/S5 itemization: pre-clamp terms remain legible even though total flattened.
        assertGt(b + rt + d, MAXTOTAL, "itemized breakdown exceeds clamp -> behavior stays legible");
    }

    // ================= SELF-CURE (both triggers) ON CESSATION =================
    function test_self_cures_on_cessation() public {
        bool dir = true;
        for (uint256 i = 0; i < 24; i++) { vm.roll(block.number + 1); core.observe(A0, POOL, dir, SMALL); dir = !dir; }
        assertGt(core.totalFeeBps(A0, POOL), BASE, "flagged first");
        vm.roll(block.number + 100_000); // long idle, no observe
        assertEq(core.totalFeeBps(A0, POOL), BASE, "self-cures to base");
        assertEq(core.guardShapeHits(A0, POOL), 0);
        assertEq(core.guardDustHits(A0, POOL), 0);
    }

    // ================= S6.5 PER-SENDER KEYING =================
    function test_attacker_flood_cannot_inflate_victim() public {
        bool dir = true;
        for (uint256 i = 0; i < 40; i++) { vm.roll(block.number + 1); core.observe(A2, POOL, dir, SMALL); dir = !dir; }
        assertGt(core.totalFeeBps(A2, POOL), BASE, "attacker's own slot flagged");
        // victim (different sender) and a different pool are untouched.
        assertEq(core.totalFeeBps(A1, POOL), BASE, "victim sender untouched");
        assertEq(core.totalFeeBps(A2, POOL2), BASE, "attacker's other pool untouched");
    }

    // ================= S5 Tolled EVENT ITEMIZES =================
    function test_Tolled_emitted_with_itemization() public {
        // honest first leg => Tolled(A0, POOL, 200, 0, 0, 200)
        vm.expectEmit(true, true, false, true, address(core));
        emit Tolled(A0, POOL, BASE, 0, 0, BASE);
        core.observe(A0, POOL, true, LEG);
    }

    // ================= metadata =================
    function test_metadata_declared() public view {
        (string memory r, string memory p, string memory c) = core.metadata();
        assertGt(bytes(r).length, 0); assertGt(bytes(p).length, 0); assertGt(bytes(c).length, 0);
    }
}
