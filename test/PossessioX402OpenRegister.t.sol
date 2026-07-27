// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";
import {MockEIP3009USDC, MockInfraSink} from "./X402TestnetMocks.sol";

/// @notice DoD for OPEN + PRICED registration (SPEC_X402OpenRegister).
///         settleCall gates on registered[caller]; the merkle path is a fixed
///         allowlist and cannot serve an open toll. registerOpen is the second
///         path: anyone registers, paying REGISTRATION_FEE once, accountless
///         (EIP-3009). The fee is the ROTATION TAX - it prices identity
///         evasion, it does not gate honesty.
///
///         The load-bearing property proven here is NO NEW DRAIN: the fee moves
///         only TOWARD the pool, through the accounted door the toll already
///         uses. registerOpen has no outbound path to the registrant.
contract PossessioX402OpenRegisterTest is Test {
    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    uint256 constant OPERATIONAL_CAP   = 100_000000; // 100 USDC
    uint256 constant VELOCITY_HALFLIFE = 3600;
    uint256 constant ABSOLUTE_FLOOR    = 10_000000;
    uint256 constant FLOOR_PER_UNIT    = 1_000000;
    uint256 constant DUST_FLOOR        = 1_000000;
    uint256 constant REG_FEE           = 5_000000;   // $5 rotation tax

    MockEIP3009USDC internal usdc;
    MockInfraSink   internal heart;
    PossessioX402Core internal core;

    address internal operator  = makeAddr("operator");
    address internal feeSource = makeAddr("feeSource");
    address internal seller    = makeAddr("seller");

    uint256 internal buyerPk = 0xB0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0;
    address internal buyer;

    bytes32 internal channelId = keccak256("open-register-channel");
    bytes32 internal merkleRoot;
    bytes32 internal leafA;
    bytes32 internal leafB;
    bytes32 internal secretB = keccak256("secretB");

    uint256 internal nonceCounter;

    function setUp() public {
        buyer = vm.addr(buyerPk);
        usdc  = new MockEIP3009USDC();
        heart = new MockInfraSink(address(usdc));

        // A REAL merkle root, so the merkle-path regression (DoD 11) is honest.
        leafA = HandshakeLib.hashLeaf(keccak256("secretA"), makeAddr("allowlisted"));
        leafB = HandshakeLib.hashLeaf(secretB, buyer);
        merkleRoot = HandshakeLib.hashNode(leafA, leafB);

        core = _deployCore(merkleRoot, REG_FEE);

        vm.prank(seller);
        core.setBasePrice(channelId, 100_000000);
    }

    function _deployCore(bytes32 root, uint256 regFee) internal returns (PossessioX402Core) {
        return new PossessioX402Core({
            root:                 root,
            dustFloor:            DUST_FLOOR,
            _payToken:            address(usdc),
            _heartSink:           address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: feeSource,
            _operationalCap:      OPERATIONAL_CAP,
            _absoluteFloor:       ABSOLUTE_FLOOR,
            _floorPerUnit:        FLOOR_PER_UNIT,
            _velocityHalflife:    VELOCITY_HALFLIFE,
            _registrationFee:     regFee
        });
    }

    struct Auth { uint256 value; uint256 validAfter; uint256 validBefore; bytes32 nonce; uint8 v; bytes32 r; bytes32 s; }

    /// @dev Sign an EIP-3009 auth for `who` (pk) paying `value` to `target`.
    function _signReg(uint256 pk, address target, uint256 value) internal returns (Auth memory a) {
        a.value = value;
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600;
        a.nonce = keccak256(abi.encode("reg", ++nonceCounter));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                vm.addr(pk), target, a.value, a.validAfter, a.validBefore, a.nonce
            ))
        ));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    function _register(uint256 pk, PossessioX402Core c, uint256 value) internal returns (Auth memory a) {
        a = _signReg(pk, address(c), value);
        vm.prank(vm.addr(pk));
        c.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    // ───────────────────────────── DoD 1 ─────────────────────────────
    function test_DoD1_registerOpen_registersAndCreditsPool() public {
        usdc.mint(buyer, REG_FEE);
        assertFalse(core.registered(buyer));
        uint256 poolBefore = core.operationalPoolBalance();

        _register(buyerPk, core, REG_FEE);

        assertTrue(core.registered(buyer), "identity granted");
        assertEq(core.operationalPoolBalance(), poolBefore + REG_FEE, "fee credited to pool");
        assertEq(usdc.balanceOf(buyer), 0, "buyer paid exactly the fee");
    }

    // ───────────────────────────── DoD 2 ─────────────────────────────
    function test_DoD2_wrongFee_reverts_noFundsMoved() public {
        usdc.mint(buyer, 100_000000);
        uint256 balBefore = usdc.balanceOf(buyer);

        Auth memory a = _signReg(buyerPk, address(core), REG_FEE - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.WrongRegistrationFee.selector, REG_FEE - 1, REG_FEE));
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);

        assertFalse(core.registered(buyer), "not registered");
        assertEq(usdc.balanceOf(buyer), balBefore, "no funds moved");
    }

    function test_DoD2_overpay_alsoReverts() public {
        usdc.mint(buyer, 100_000000);
        Auth memory a = _signReg(buyerPk, address(core), REG_FEE + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.WrongRegistrationFee.selector, REG_FEE + 1, REG_FEE));
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
        assertFalse(core.registered(buyer));
    }

    // ───────────────────────────── DoD 3 ─────────────────────────────
    function test_DoD3_alreadyRegistered_refused_noSecondCharge() public {
        usdc.mint(buyer, REG_FEE * 2);
        _register(buyerPk, core, REG_FEE);
        uint256 balAfterFirst = usdc.balanceOf(buyer);

        Auth memory a2 = _signReg(buyerPk, address(core), REG_FEE);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.AlreadyRegistered.selector, buyer));
        core.registerOpen(a2.value, a2.validAfter, a2.validBefore, a2.nonce, a2.v, a2.r, a2.s);

        assertEq(usdc.balanceOf(buyer), balAfterFirst, "NOT charged twice");
    }

    // ───────────────────────────── DoD 4 ─────────────────────────────
    function test_DoD4_registerOpen_thenSettleCall_endToEnd() public {
        usdc.mint(buyer, 1_000_000000);
        _register(buyerPk, core, REG_FEE);

        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        uint256 value = basePrice + (basePrice * tollBps) / 10_000;
        bytes32 salt = bytes32(uint256(1));
        bytes32 nonce = keccak256(abi.encode(seller, channelId, value, salt));

        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 3600;
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, buyer, address(core), value, va, vb, nonce))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);

        core.settleCall(buyer, seller, channelId, salt, value, va, vb, nonce, v, r, s);
        assertEq(usdc.balanceOf(seller), basePrice, "seller netted basePrice -> identity gate passed");
    }

    // ───────────────────────────── DoD 5 : THE ROTATION TAX ──────────
    function test_DoD5_rotationTax_NidentitiesCostNfee() public {
        uint256 n = 5;
        uint256 poolBefore = core.operationalPoolBalance();
        uint256 heartBefore = usdc.balanceOf(address(heart));

        for (uint256 i = 1; i <= n; i++) {
            uint256 pk = 0xA11CE + i;
            address who = vm.addr(pk);
            usdc.mint(who, REG_FEE);
            _register(pk, core, REG_FEE);
            assertTrue(core.registered(who));
            assertEq(usdc.balanceOf(who), 0, "each identity paid the full tax");
        }
        uint256 captured = (core.operationalPoolBalance() - poolBefore)
                         + (usdc.balanceOf(address(heart)) - heartBefore);
        assertEq(captured, n * REG_FEE, "N identities cost exactly N * REGISTRATION_FEE");
    }

    // ───────────────────────────── DoD 6 : NO DRAIN ──────────────────
    function test_DoD6_noDrain_feeOnlyMovesTowardPool() public {
        uint256 coreBefore = usdc.balanceOf(address(core));
        for (uint256 i = 1; i <= 3; i++) {
            uint256 pk = 0xBEEF + i;
            usdc.mint(vm.addr(pk), REG_FEE);
            _register(pk, core, REG_FEE);
            // Registrant never receives anything back.
            assertEq(usdc.balanceOf(vm.addr(pk)), 0, "no outflow to registrant");
        }
        // Everything is accounted: contract holds exactly what the pool says
        // it holds (plus whatever it held before); nothing stranded, nothing lost.
        assertEq(
            usdc.balanceOf(address(core)) - coreBefore,
            core.operationalPoolBalance(),
            "contract USDC == accounted pool balance (no unaccounted residue)"
        );
    }

    function test_DoD6_surplusOverCapRoutesToHeart_notToCaller() public {
        // Fill the pool to just under the cap via the deployment-fee door.
        usdc.mint(feeSource, OPERATIONAL_CAP);
        vm.startPrank(feeSource);
        usdc.approve(address(core), type(uint256).max);
        core.receiveDeploymentFee(OPERATIONAL_CAP - 1_000000); // 1 USDC of headroom
        vm.stopPrank();

        uint256 heartBefore = usdc.balanceOf(address(heart));
        usdc.mint(buyer, REG_FEE);
        _register(buyerPk, core, REG_FEE);

        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool pinned at cap");
        assertEq(usdc.balanceOf(address(heart)) - heartBefore, REG_FEE - 1_000000, "exact surplus to the Heart");
        assertEq(usdc.balanceOf(buyer), 0, "nothing back to the registrant");
    }

    // ───────────────────────────── DoD 7 : front-run closed ──────────
    function test_DoD7_authSignedByA_cannotRegisterB() public {
        usdc.mint(buyer, REG_FEE);
        address mallory = makeAddr("mallory");

        // Buyer's auth (from == buyer), replayed by mallory.
        Auth memory a = _signReg(buyerPk, address(core), REG_FEE);
        vm.prank(mallory);
        vm.expectRevert(); // token: ecrecover(from) != mallory -> invalid signature
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);

        assertFalse(core.registered(mallory), "mallory not registered off someone else's auth");
    }

    // ───────────────────────────── DoD 8 : replay dead ───────────────
    function test_DoD8_sameNonce_cannotRegisterTwice() public {
        uint256 pk = 0xDEAD01;
        address who = vm.addr(pk);
        usdc.mint(who, REG_FEE * 2);

        Auth memory a = _signReg(pk, address(core), REG_FEE);
        vm.prank(who);
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);

        // Even if the identity gate were bypassed, the token burns the nonce.
        vm.prank(who);
        vm.expectRevert(); // AlreadyRegistered (identity) — nonce burn is the second wall
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    // ───────────────────────────── DoD 10 : fee == 0 (free-open) ─────
    function test_DoD10_zeroFee_freeOpenRegistration_noHeartCall() public {
        PossessioX402Core freeCore = _deployCore(merkleRoot, 0);
        uint256 heartBefore = usdc.balanceOf(address(heart));

        uint256 pk = 0xF2EE;
        address who = vm.addr(pk);
        Auth memory a = _signReg(pk, address(freeCore), 0);
        vm.prank(who);
        freeCore.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);

        assertTrue(freeCore.registered(who), "free-open registration works with no USDC at all");
        assertEq(freeCore.operationalPoolBalance(), 0, "no pool credit");
        assertEq(usdc.balanceOf(address(heart)), heartBefore, "no Heart interaction");
    }

    // ───────────────────────────── DoD 11 : merkle path regression ───
    function test_DoD11_merklePath_unchanged_stillFreeAndWorking() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafA;

        uint256 balBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        core.register(secretB, proof);

        assertTrue(core.registered(buyer), "merkle registration still works");
        assertEq(usdc.balanceOf(buyer), balBefore, "merkle path is still FREE");
    }

    function test_DoD11_merkleThenOpen_refused_noDoubleCharge() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafA;
        vm.prank(buyer);
        core.register(secretB, proof);

        usdc.mint(buyer, REG_FEE);
        Auth memory a = _signReg(buyerPk, address(core), REG_FEE);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.AlreadyRegistered.selector, buyer));
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
        assertEq(usdc.balanceOf(buyer), REG_FEE, "merkle-registered identity is never charged");
    }

    // ───────────────────── DoD 12 : root == 0 no longer bricks ───────
    function test_DoD12_zeroRoot_openPathStillRegisters_tollNotBricked() public {
        PossessioX402Core openCore = _deployCore(bytes32(0), REG_FEE);
        vm.prank(seller);
        openCore.setBasePrice(channelId, 100_000000);

        usdc.mint(buyer, 1_000_000000);
        _register(buyerPk, openCore, REG_FEE);
        assertTrue(openCore.registered(buyer), "open path registers under an EMPTY merkle root");

        // ...and the toll actually settles: the trap is dissolved.
        uint256 basePrice = openCore.channelBasePrice(channelId);
        uint256 tollBps = openCore.totalFeeBps(buyer, channelId);
        uint256 value = basePrice + (basePrice * tollBps) / 10_000;
        bytes32 salt = bytes32(uint256(7));
        bytes32 nonce = keccak256(abi.encode(seller, channelId, value, salt));
        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 3600;
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, buyer, address(openCore), value, va, vb, nonce))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        openCore.settleCall(buyer, seller, channelId, salt, value, va, vb, nonce, v, r, s);

        assertEq(usdc.balanceOf(seller), basePrice, "toll settles under root=0 via the open path");
    }

    /// @dev The merkle path is genuinely dead under root=0 (nobody can prove
    ///      membership of an empty tree) - so the open path is the ONLY door,
    ///      which is exactly the intended shape for a permissionless deployment.
    function test_DoD12_zeroRoot_merklePathIsDead() public {
        PossessioX402Core openCore = _deployCore(bytes32(0), REG_FEE);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafA;
        vm.prank(buyer);
        vm.expectRevert(); // NotAuthorized - no membership in an empty tree
        openCore.register(secretB, proof);
    }
}
