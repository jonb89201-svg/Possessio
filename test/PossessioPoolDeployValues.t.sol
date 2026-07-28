// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   POSSESSIO POOL — THE DEPLOYMENT CONFIGURATION, UNDER TEST

   Codebyte Law, Prime Directive: if it can't be tested, it doesn't
   exist. That applies to the CONFIGURATION, not only the contract.

   The Pool's four economics are immutable at construction and there
   is exactly ONE Pool for the protocol — it is not a template, its
   constructor cannot pass through deployTemplate, and every factory
   tier and every toll routes into it forever. A wrong constant is not
   a redeployable mistake.

   The existing suites prove the MECHANISM at convenient numbers:
     PossessioPool.t.sol      CAP 1,000  FLOOR 100  PER_UNIT 0  HL 1d
     PossessioPoolFork.t.sol  CAP 5,000  FLOOR 500  PER_UNIT 25 HL 7d
   The values we intend to broadcast (DEPLOY_CALIBRATION §22) are
     CAP 700  FLOOR 60  PER_UNIT 20  HL 7d
   — of which only the half-life appears in any suite. In particular
   the unit suite pins FLOOR_PER_UNIT = 0 deliberately ("so the floor
   is a flat ABSOLUTE_FLOOR"), so the velocity-scaled floor — the
   mechanism that makes the floor throughput-derived and ungameable —
   is exercised at NO shipping value anywhere.

   This suite runs the real economics at the real numbers.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioPool} from "../src/PossessioPool.sol";
import {MockUSDC} from "./PossessioPool.t.sol";

contract PossessioPoolDeployValuesTest is Test {
    // ── DEPLOY_CALIBRATION §22 — the exact broadcast values ──────────────
    uint256 constant CAP      = 700_000000;   // $700  — ~3 months of $235/mo burn
    uint256 constant FLOOR    =  60_000000;   // $60   — $55 infra + ~$5 amortized
    uint256 constant PER_UNIT =  20_000000;   // $20   — buffer per velocity unit
    uint256 constant HALFLIFE =     604800;   // 7 days

    MockUSDC usdc;
    PossessioPool pool;
    address operator = makeAddr("operatorPasskey");
    address treasury = makeAddr("treasuryPasskey");
    address srcA     = makeAddr("factory");
    address srcB     = makeAddr("x402Core");

    function setUp() public {
        usdc = new MockUSDC();
        address[] memory srcs = new address[](2);
        srcs[0] = srcA;
        srcs[1] = srcB;
        pool = new PossessioPool(address(usdc), srcs, operator, treasury, CAP, FLOOR, PER_UNIT, HALFLIFE);
        usdc.mint(srcA, 10_000_000e6);
        usdc.mint(srcB, 10_000_000e6);
        vm.prank(srcA); usdc.approve(address(pool), type(uint256).max);
        vm.prank(srcB); usdc.approve(address(pool), type(uint256).max);
    }

    function _feed(address src, uint256 amt) internal {
        vm.prank(src);
        pool.receiveInfraFunds(amt);
    }

    // ── D1. The constants land exactly as calibrated ─────────────────────
    function test_D1_immutablesMatchCalibration() public view {
        assertEq(pool.OPERATIONAL_CAP(),   CAP,      "OPERATIONAL_CAP != $700");
        assertEq(pool.ABSOLUTE_FLOOR(),    FLOOR,    "ABSOLUTE_FLOOR != $60");
        assertEq(pool.FLOOR_PER_UNIT(),    PER_UNIT, "FLOOR_PER_UNIT != $20");
        assertEq(pool.VELOCITY_HALFLIFE(), HALFLIFE, "VELOCITY_HALFLIFE != 7 days");
    }

    // ── D2. At rest the floor is the absolute floor: $60 ─────────────────
    function test_D2_restingFloorIsAbsoluteFloor() public view {
        assertEq(pool.getRunningMinimumFloor(), FLOOR, "cold floor must be exactly $60");
    }

    // ── D3. The cap holds at $700; every cent above it leaves one-way ────
    function test_D3_capBoundary_surplusForcedToTreasury() public {
        _feed(srcA, CAP - 1_000000);                       // $699 in
        assertEq(pool.poolBalance(), CAP - 1_000000);
        assertEq(usdc.balanceOf(treasury), 0, "nothing should have overflowed yet");

        _feed(srcB, 50_000000);                            // $50 more -> $49 over cap
        assertEq(pool.poolBalance(), CAP, "balance must pin at exactly $700");
        assertEq(usdc.balanceOf(treasury), 49_000000, "exact overflow must reach treasury");
        assertEq(usdc.balanceOf(address(pool)), CAP, "no unaccounted residue");
    }

    // ── D4. The operator can never draw the machine below its floor ──────
    function test_D4_drawCannotBreachFloor() public {
        _feed(srcA, CAP);                                  // full at $700
        uint256 floor = pool.getRunningMinimumFloor();
        uint256 surplus = pool.drawableSurplus();
        assertEq(surplus, CAP - floor, "drawable must be balance - floor");

        vm.prank(operator);
        vm.expectRevert();
        pool.settleOperationalCosts(surplus + 1);           // one cent too far

        vm.prank(operator);
        pool.settleOperationalCosts(surplus);               // exactly to the floor
        assertEq(pool.poolBalance(), floor, "must rest exactly on the floor");

        vm.prank(operator);
        vm.expectRevert();
        pool.settleOperationalCosts(1);                     // nothing left, ever
    }

    // ── D5. THE UNTESTED MECHANISM: the floor rises with throughput ──────
    //      At PER_UNIT = $20 this is what makes the floor ungameable. The
    //      unit suite pins PER_UNIT = 0 and never reaches this path.
    function test_D5_velocityRaisesFloorAtShippingPerUnit() public {
        uint256 cold = pool.getRunningMinimumFloor();
        assertEq(cold, FLOOR, "precondition: cold floor is $60");

        _feed(srcA, 100_000000);                           // $100 of throughput
        uint256 hot = pool.getRunningMinimumFloor();

        assertGt(hot, cold, "floor MUST rise with inflow velocity at PER_UNIT=$20");
        // floor = ABSOLUTE_FLOOR + (whole velocity units * PER_UNIT)
        assertEq((hot - cold) % PER_UNIT, 0, "rise must be a whole multiple of $20");
        console2.log("cold floor (USDC 6dp):", cold);
        console2.log("hot  floor (USDC 6dp):", hot);
        console2.log("units of throughput  :", (hot - cold) / PER_UNIT);
    }

    // ── D6. The raised floor is enforced, not cosmetic ───────────────────
    function test_D6_raisedFloorActuallyBlocksTheDraw() public {
        _feed(srcA, 100_000000);
        uint256 hot = pool.getRunningMinimumFloor();
        assertGt(hot, FLOOR, "precondition: floor is elevated");

        uint256 drawable = pool.drawableSurplus();
        uint256 balance  = pool.poolBalance();
        assertEq(drawable, balance - hot, "surplus measured against the HOT floor");

        // Hoisted: evaluating a view inside the call args would consume the
        // cheatcodes before settleOperationalCosts is ever reached.
        uint256 legalAtColdFloor = balance - FLOOR;
        assertGt(legalAtColdFloor, drawable, "precondition: cold-floor draw exceeds the hot surplus");

        vm.prank(operator);
        vm.expectRevert();
        pool.settleOperationalCosts(legalAtColdFloor);  // legal at $60, must fail at $80
    }

    // ── D7. Decay: after one half-life the velocity contribution halves ──
    function test_D7_floorDecaysOverTheShippingHalflife() public {
        _feed(srcA, 400_000000);
        uint256 hot = pool.getRunningMinimumFloor();
        assertGt(hot, FLOOR, "precondition: elevated");

        vm.warp(block.timestamp + HALFLIFE);
        uint256 halved = pool.getRunningMinimumFloor();

        assertLt(halved, hot,   "floor must decay as throughput ages");
        assertGe(halved, FLOOR, "floor may NEVER fall below the absolute floor");

        vm.warp(block.timestamp + 20 * HALFLIFE);
        assertEq(pool.getRunningMinimumFloor(), FLOOR, "quiet machine returns to exactly $60");
    }

    // ── D8. $60 floor vs the real bill: one month of burn is protected ───
    //      §22 sizes ABSOLUTE_FLOOR at $55 infra + ~$5 amortized. This
    //      asserts the shipped floor actually covers the stated monthly
    //      bill — the calibration's own premise, under test.
    function test_D8_floorCoversStatedMonthlyInfraBill() public view {
        uint256 statedMonthlyInfra = 55_000000;            // $55/mo — §22
        assertGe(FLOOR, statedMonthlyInfra,
            "ABSOLUTE_FLOOR must cover the stated monthly infra bill");
        assertGe(pool.OPERATIONAL_CAP(), FLOOR * 3,
            "cap should hold at least ~3 months of floor-level burn");
    }

    // ── D10. SEMANTIC PIN: the floor tracks EVENTS, not amounts ──────────
    //      _bumpVelocity() adds a flat 1e18 per inflow regardless of size,
    //      so a $1 toll and a $10,000 deploy fee each raise the floor by
    //      exactly one PER_UNIT. That is defensible — burn scales with call
    //      count (RPC, inference), not with revenue — but it is a real
    //      economic property and must not be discovered later by surprise.
    //      Pinned here so a future change to amount-weighting breaks a test
    //      rather than silently re-pricing the machine's floor.
    function test_D10_floorScalesWithEventCountNotAmount() public {
        uint256 base = pool.getRunningMinimumFloor();

        _feed(srcA, 1_000000);            // $1
        uint256 afterTiny = pool.getRunningMinimumFloor();
        assertEq(afterTiny - base, PER_UNIT, "$1 inflow raises the floor by exactly one unit");

        _feed(srcB, 500_000000);          // $500 — 500x larger
        uint256 afterLarge = pool.getRunningMinimumFloor();
        assertEq(afterLarge - afterTiny, PER_UNIT,
            "a 500x larger inflow raises the floor by the SAME one unit");
    }

    // ── D9. Full-cap runway against the stated total burn ────────────────
    //      §22 sizes the $700 cap as ~3 months of $235/mo total burn.
    function test_D9_capGivesStatedRunway() public view {
        uint256 statedMonthlyTotal = 235_000000;           // $235/mo — §22
        uint256 runwayMonths = CAP / statedMonthlyTotal;
        assertGe(runwayMonths, 2, "cap must hold at least 2 months of total burn");
        assertLe(runwayMonths, 6, "cap should not hoard beyond ~6 months (surplus belongs to treasury)");
    }
}
