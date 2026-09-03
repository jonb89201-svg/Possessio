// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   x402CORE — THE DEPLOYMENT CONFIGURATION, UNDER TEST

   Companion to PossessioPoolDeployValues.t.sol, same law: the Prime
   Directive applies to the CONFIGURATION, not only the mechanism.

   x402Core's economics are immutable at construction and its address
   is a fixed CREATE3 anchor. DEPLOY_CALIBRATION §22 ships:
     OPERATIONAL_CAP $150 · ABSOLUTE_FLOOR $15 · FLOOR_PER_UNIT $5
     VELOCITY_HALFLIFE 1 day · DUST_FLOOR $1 · REGISTRATION_FEE $5
     HANDSHAKE_ROOT = bytes32(0)  (merkle path unused; open+priced replaces it)

   Every existing suite runs different numbers:
     Gauntlet / Testnet / OpenRegister:
       CAP $100 · FLOOR $10 · PER_UNIT $1 · HALFLIFE 1 HOUR
   Four of six shipping values are exercised nowhere. The half-life is
   off by 24x, which is the one that governs how fast the floor relaxes
   — i.e. how long a burst of traffic keeps the machine's minimum
   elevated. That is not a detail; it is the self-funding behaviour.

   This suite runs the real economics at the real numbers.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {MockEIP3009USDC, MockInfraSink} from "./X402TestnetMocks.sol";

/// A real Pool marker that does NOT list the caller as a source (X-H2).
contract UnlistedHeart {
    function isInfraSink() external pure returns (bool) { return true; }
    function isAuthorizedSource(address) external pure returns (bool) { return false; }
}

contract PossessioX402CoreDeployValuesTest is Test {
    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    // ── DEPLOY_CALIBRATION §22 — the exact broadcast values ──────────────
    uint256 constant OPERATIONAL_CAP   = 150_000000;  // $150
    uint256 constant ABSOLUTE_FLOOR    =  15_000000;  // $15
    uint256 constant FLOOR_PER_UNIT    =   5_000000;  // $5
    uint256 constant VELOCITY_HALFLIFE =      86400;  // 1 day
    uint256 constant DUST_FLOOR        =   1_000000;  // $1
    uint256 constant REG_FEE           =   5_000000;  // $5
    bytes32 constant ROOT              = bytes32(0);  // merkle unused

    MockEIP3009USDC   usdc;
    MockInfraSink     heart;
    PossessioX402Core core;

    address operator  = makeAddr("operatorPasskey");
    address feeSource = makeAddr("feeSource");
    address seller    = makeAddr("seller");
    uint256 buyerPk   = 0xB0B;
    address buyer;
    bytes32 channelId = keccak256("deploy-values-channel");
    uint256 nonceCounter;

    function setUp() public {
        buyer = vm.addr(buyerPk);
        usdc  = new MockEIP3009USDC();
        heart = new MockInfraSink(address(usdc));
        core  = new PossessioX402Core({
            root:                 ROOT,
            dustFloor:            DUST_FLOOR,
            _payToken:            address(usdc),
            _heartSink:           address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: feeSource,
            _operationalCap:      OPERATIONAL_CAP,
            _absoluteFloor:       ABSOLUTE_FLOOR,
            _floorPerUnit:        FLOOR_PER_UNIT,
            _velocityHalflife:    VELOCITY_HALFLIFE,
            _registrationFee:     REG_FEE
        });
        vm.prank(seller);
        core.setBasePrice(channelId, 100_000000);   // $100 channel
    }

    struct Auth { uint256 value; uint256 validAfter; uint256 validBefore; bytes32 nonce; uint8 v; bytes32 r; bytes32 s; }

    function _sign(uint256 pk, uint256 value) internal returns (Auth memory a) {
        a.value = value;
        a.validAfter  = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600;
        a.nonce = keccak256(abi.encode("dv", ++nonceCounter));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                vm.addr(pk), address(core), a.value, a.validAfter, a.validBefore, a.nonce))
        ));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    function _register(uint256 pk) internal {
        usdc.mint(vm.addr(pk), REG_FEE);
        Auth memory a = _sign(pk, REG_FEE);
        vm.prank(vm.addr(pk));
        core.registerOpen(a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    /// @dev Deployment-fee inflow. Feeds the operating pool. Does NOT bump
    ///      velocity -- verified: _bumpVelocity() is called only from
    ///      settleCall (PossessioX402Core.sol:516).
    function _feeInflow(uint256 amount) internal {
        usdc.mint(feeSource, amount);
        vm.prank(feeSource);
        usdc.approve(address(core), amount);
        vm.prank(feeSource);
        core.receiveDeploymentFee(amount);
    }

    /// @dev A settled toll call -- the ONLY thing that moves x402Core's
    ///      velocity, and therefore the only thing that raises its floor.
    function _settle(uint256 saltSeed) internal {
        uint256 bps   = core.totalFeeBps(buyer, channelId);
        uint256 value = 100_000000 + (100_000000 * bps) / 10_000;
        bytes32 salt  = keccak256(abi.encode("settle", saltSeed));
        bytes32 commit = keccak256(abi.encode(seller, channelId, value, salt));

        usdc.mint(buyer, value);
        Auth memory a;
        a.value = value;
        a.validAfter  = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600;
        a.nonce = commit;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                buyer, address(core), a.value, a.validAfter, a.validBefore, a.nonce))));
        (a.v, a.r, a.s) = vm.sign(buyerPk, digest);

        core.settleCall(buyer, seller, channelId, salt, a.value,
                        a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    // ── X1. The constants land exactly as calibrated ─────────────────────
    function test_X1_immutablesMatchCalibration() public view {
        assertEq(core.OPERATIONAL_CAP(),   OPERATIONAL_CAP,   "OPERATIONAL_CAP != $150");
        assertEq(core.ABSOLUTE_FLOOR(),    ABSOLUTE_FLOOR,    "ABSOLUTE_FLOOR != $15");
        assertEq(core.FLOOR_PER_UNIT(),    FLOOR_PER_UNIT,    "FLOOR_PER_UNIT != $5");
        assertEq(core.VELOCITY_HALFLIFE(), VELOCITY_HALFLIFE, "VELOCITY_HALFLIFE != 1 day");
        assertEq(core.REGISTRATION_FEE(),  REG_FEE,           "REGISTRATION_FEE != $5");
    }

    // ── X2. Cold floor is exactly the absolute floor: $15 ────────────────
    function test_X2_restingFloorIsAbsoluteFloor() public view {
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR, "cold floor must be exactly $15");
    }

    // ── X3. Registration costs exactly $5 — not a cent more or less ──────
    function test_X3_registrationCostsExactlyFive() public {
        uint256 poolBefore = core.operationalPoolBalance();
        _register(buyerPk);
        assertTrue(core.registered(buyer), "buyer registered");
        assertEq(core.operationalPoolBalance() - poolBefore, REG_FEE,
            "the $5 rotation tax must land in the operating pool, whole");

        // under-pay and over-pay both die
        uint256 pk2 = 0xBEEF01;
        usdc.mint(vm.addr(pk2), REG_FEE * 2);
        Auth memory under = _sign(pk2, REG_FEE - 1);
        vm.prank(vm.addr(pk2));
        vm.expectRevert();
        core.registerOpen(under.value, under.validAfter, under.validBefore, under.nonce, under.v, under.r, under.s);

        Auth memory over = _sign(pk2, REG_FEE + 1);
        vm.prank(vm.addr(pk2));
        vm.expectRevert();
        core.registerOpen(over.value, over.validAfter, over.validBefore, over.nonce, over.v, over.r, over.s);
    }

    // ── X4. The cap holds at $150; surplus routes one-way to the Heart ───
    function test_X4_capBoundary_surplusRoutesToHeart() public {
        uint256 heartBefore = usdc.balanceOf(address(heart));

        _feeInflow(OPERATIONAL_CAP - 10_000000);       // $140 in
        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP - 10_000000);
        assertEq(usdc.balanceOf(address(heart)), heartBefore, "nothing over the cap yet");

        _feeInflow(30_000000);                          // $30 more -> $20 over
        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "must pin at exactly $150");
        assertEq(usdc.balanceOf(address(heart)) - heartBefore, 20_000000,
            "exact surplus must reach the Heart");
    }

    // ── X5. THE UNTESTED MECHANISM: floor rises $5 per inflow unit ───────
    function test_X5_velocityRaisesFloorAtShippingPerUnit() public {
        _register(buyerPk);
        uint256 cold = core.getRunningMinimumFloor();
        assertEq(cold, ABSOLUTE_FLOOR, "precondition: $15");

        _settle(1);
        uint256 hot = core.getRunningMinimumFloor();

        assertGt(hot, cold, "floor MUST rise with velocity at PER_UNIT=$5");
        assertEq((hot - cold) % FLOOR_PER_UNIT, 0, "rise is a whole multiple of $5");
        console2.log("cold floor:", cold);
        console2.log("hot  floor:", hot);
    }

    // ── X6. The operator can never draw below the live floor ────────────
    function test_X6_drawCannotBreachFloor() public {
        _register(buyerPk);
        _feeInflow(OPERATIONAL_CAP);
        uint256 floor    = core.getRunningMinimumFloor();
        uint256 surplus  = core.drawableSurplus();
        assertEq(surplus, core.operationalPoolBalance() - floor, "surplus vs live floor");

        vm.prank(operator);
        vm.expectRevert();
        core.settleOperationalCosts(surplus + 1);

        vm.prank(operator);
        core.settleOperationalCosts(surplus);
        assertEq(core.operationalPoolBalance(), floor, "rests exactly on the floor");
    }

    // ── X7. Decay over the SHIPPING 1-day half-life (suites use 1 hour) ──
    //      24x difference from every existing suite. This governs how long
    //      a traffic burst keeps the machine's minimum elevated.
    function test_X7_floorDecaysOverOneDayHalflife() public {
        _register(buyerPk);
        _settle(7); _settle(8); _settle(9);
        uint256 hot = core.getRunningMinimumFloor();
        assertGt(hot, ABSOLUTE_FLOOR, "precondition: elevated");

        // one hour -- what the other suites treat as a FULL half-life --
        // must barely move this floor.
        vm.warp(block.timestamp + 3600);
        uint256 afterHour = core.getRunningMinimumFloor();
        assertGt(afterHour, ABSOLUTE_FLOOR, "one hour must NOT relax the floor to baseline");

        vm.warp(block.timestamp + VELOCITY_HALFLIFE);
        uint256 afterDay = core.getRunningMinimumFloor();
        assertLt(afterDay, hot,             "a full day must decay it");
        assertGe(afterDay, ABSOLUTE_FLOOR,  "never below $15");

        vm.warp(block.timestamp + 40 * VELOCITY_HALFLIFE);
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR, "quiet returns to exactly $15");
    }

    // ── X8. ROOT = 0 ships: merkle path dead, open path alive ───────────
    //      §22 sets HANDSHAKE_ROOT = bytes32(0) because open+priced replaces
    //      the allowlist. Proves the toll is NOT bricked by that choice.
    function test_X8_zeroRoot_tollNotBricked() public {
        assertEq(core.HANDSHAKE_ROOT(), bytes32(0), "shipping root is zero");
        _register(buyerPk);
        assertTrue(core.registered(buyer), "open path registers under a zero root");

        uint256 bps   = core.totalFeeBps(buyer, channelId);
        uint256 value = 100_000000 + (100_000000 * bps) / 10_000;
        bytes32 salt  = keccak256("x8");
        bytes32 commit = keccak256(abi.encode(seller, channelId, value, salt));

        usdc.mint(buyer, value);
        Auth memory a;
        a.value = value; a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600; a.nonce = commit;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                buyer, address(core), a.value, a.validAfter, a.validBefore, a.nonce))));
        (a.v, a.r, a.s) = vm.sign(buyerPk, digest);

        uint256 sellerBefore = usdc.balanceOf(seller);
        core.settleCall(buyer, seller, channelId, salt, a.value,
                        a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
        assertEq(usdc.balanceOf(seller) - sellerBefore, 100_000000,
            "seller nets exactly basePrice -- the toll works under a zero root");
    }

    // ── X9. Rotation tax at the shipping price: N identities cost N x $5 ─
    function test_X9_rotationTaxAtShippingPrice() public {
        uint256 before_ = core.operationalPoolBalance();
        for (uint256 i = 1; i <= 4; i++) _register(0xA0000 + i);
        assertEq(core.operationalPoolBalance() - before_, 4 * REG_FEE,
            "four identities cost exactly 4 x $5");
    }


    // ── X11. SEMANTIC PIN: x402Core velocity tracks SETTLEMENTS, not fees ─
    //      _bumpVelocity() is called ONLY from settleCall (:516). A
    //      deployment fee raises the operating balance but NOT the floor.
    //      This differs from PossessioPool, whose velocity bumps on every
    //      receiveInfraFunds -- same floor formula, different meaning of
    //      "velocity". Pinned so the divergence is deliberate and visible
    //      rather than discovered during an incident.
    function test_X11_deploymentFeesDoNotRaiseTheFloor() public {
        uint256 cold = core.getRunningMinimumFloor();
        _feeInflow(100_000000);                       // $100 of fee inflow
        assertEq(core.getRunningMinimumFloor(), cold,
            "deployment fees must NOT move the floor -- only settled calls do");
        assertGt(core.operationalPoolBalance(), 0, "but they DO fund the pool");

        _register(buyerPk);
        _settle(11);
        assertGt(core.getRunningMinimumFloor(), cold,
            "a settled call DOES move the floor");
    }

    // ── X10. §22 sizing premise: the x402 floor is smaller than the Heart's
    //      The Heart carries the protocol's floor ($60); x402Core is one
    //      organ and must not reserve more than the Heart it feeds.
    function test_X10_organFloorIsSubordinateToHeartFloor() public pure {
        uint256 heartFloor = 60_000000;   // §22 POOL_ABS_FLOOR
        uint256 heartCap   = 700_000000;  // §22 POOL_OP_CAP
        assertLt(ABSOLUTE_FLOOR, heartFloor, "organ floor must sit below the Heart's floor");
        assertLt(OPERATIONAL_CAP, heartCap,  "organ cap must sit below the Heart's cap");
    }
    /*//////////////////////////////////////////////////////////////
        RE-AUDIT 2026-09-01 regressions (X-H1 / X-H2 / X-L3)
    //////////////////////////////////////////////////////////////*/

    function _settleOn(bytes32 ch, uint256 basePrice, uint256 saltSeed) internal {
        uint256 bps   = core.totalFeeBps(buyer, ch);
        uint256 value = basePrice + (basePrice * bps) / 10_000;
        bytes32 salt  = keccak256(abi.encode("settleOn", saltSeed));
        bytes32 commit = keccak256(abi.encode(seller, ch, value, salt));
        usdc.mint(buyer, value);
        Auth memory a;
        a.value = value;
        a.validAfter  = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600;
        a.nonce = commit;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                buyer, address(core), a.value, a.validAfter, a.validBefore, a.nonce))));
        (a.v, a.r, a.s) = vm.sign(buyerPk, digest);
        core.settleCall(buyer, seller, ch, salt, a.value,
                        a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    /// X-H1 draw-room invariant. RED on the pre-fix core: 40 settles inside one
    /// decay window pinned floor = $15 + 40*$5 = $215 > CAP $150, so
    /// drawableSurplus was 0 with no escape (an absorbing lock).
    function test_XH1_drawRoomInvariant_settleStormCannotLockOperatorOut() public {
        _register(buyerPk);
        _feeInflow(OPERATIONAL_CAP);                       // pool full
        for (uint256 i = 0; i < 40; ++i) _settle(1000 + i); // 40 × $100 settles, one block
        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP);
        assertEq(core.getRunningMinimumFloor(), OPERATIONAL_CAP - ABSOLUTE_FLOOR, "floor caps at CAP - FLOOR");
        assertEq(core.drawableSurplus(), ABSOLUTE_FLOOR, "one absolute floor of draw room remains");
        vm.prank(operator);
        core.settleOperationalCosts(ABSOLUTE_FLOOR);       // the draw that used to revert forever
    }

    /// X-H1 dust gate. RED on the pre-fix core: every settle bumped velocity by a
    /// full unit regardless of size, so wei-sized self-settles were the cheapest
    /// door to the lock.
    function test_XH1_dustSettleDoesNotBumpVelocity() public {
        _register(buyerPk);
        bytes32 dustChannel = keccak256("dust-channel");
        vm.prank(seller);
        core.setBasePrice(dustChannel, 10);                // 0.00001 USDC, far below DUST_FLOOR $1
        uint256 base = core.getRunningMinimumFloor();
        for (uint256 i = 0; i < 40; ++i) _settleOn(dustChannel, 10, i);
        assertEq(core.getRunningMinimumFloor(), base, "sub-dust settles are not throughput");
        _settle(2000);                                     // one real $100 settle
        assertEq(core.getRunningMinimumFloor(), base + FLOOR_PER_UNIT, "a real settle counts one unit");
    }

    /// X-H2: a live Pool that does not list this core used to construct clean and
    /// then revert every surplus push at the cap — a permanent dead x402Core.
    function test_XH2_ctor_heartDoesNotListCore_reverts() public {
        address unlisted = address(new UnlistedHeart());
        vm.expectRevert(PossessioX402Core.HeartSourceNotAuthorized.selector);
        new PossessioX402Core(ROOT, DUST_FLOOR, address(usdc), unlisted, operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE, REG_FEE);
    }

    /// X-L3: floor-parameter bounds the floor math relies on.
    function test_XL3_ctor_floorParamBounds_revert() public {
        vm.expectRevert(PossessioX402Core.FloorParamsInvalid.selector);
        new PossessioX402Core(ROOT, DUST_FLOOR, address(usdc), address(heart), operator, feeSource,
            2 * ABSOLUTE_FLOOR - 1, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE, REG_FEE);
        vm.expectRevert(PossessioX402Core.FloorParamsInvalid.selector);
        new PossessioX402Core(ROOT, DUST_FLOOR, address(usdc), address(heart), operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, uint256(type(uint128).max) + 1, REG_FEE);
    }
}
