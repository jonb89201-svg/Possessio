// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
        POSSESSIO POOL - BASE MAINNET FORK SUITE (gate 1 of 3)

  src/PossessioPool.sol header, PENDING before immutable freeze:
    (1) fork-prove on Base   <- THIS FILE
    (2) calibrate CAP/FLOOR/PER_UNIT/HALFLIFE to real data
    (3) cold-seat re-audit

  The offline suite (PossessioPool.t.sol) proves the mechanism
  against a mock. This suite proves ONLY what the mock cannot:
  the pool's accounting, valve, floor, and one-way draw against
  the REAL Circle USDC on Base (FiatTokenProxy -> FiatTokenV2_2:
  6 decimals, proxied storage, blacklist-capable, returns-bool
  transfer semantics). No mechanism test is duplicated wholesale;
  every test here moves REAL token state.

  DEPLOY-SHAPE MIRROR: construction mirrors
  script/DeployPossessioPool.s.sol - pinned Base USDC, a source
  set shaped like [factory, x402Core, whisky], immutable
  operator/treasury destinations, same constructor arg order -
  so this fork run proves the deploy path, not a divergent
  construction.

  FLOOR PARAMS BELOW ARE TEST VALUES, NOT THE RATIFIED ONES.
  The real CAP / ABSOLUTE_FLOOR / FLOOR_PER_UNIT /
  VELOCITY_HALFLIFE remain OPEN until gate (2) calibration
  against real throughput + infrastructure-cost data (v0.1
  header: "FLOOR PARAMS ARE SOFT"). Likewise the whisky-market
  source membership remains OPEN (Architect ratifies; see the
  deploy script's WHISKY_MARKET_ADDR xor WHISKY_MARKET_EXCLUDED
  gate) - it is included here ONLY to exercise the 3-source
  shape. Nothing in this file ratifies any number or set.

  SKIP DISCIPLINE (house pattern - PossessioFactoryFork /
  PaymentsFork / LSTExchangeRateFork): try BASE_RPC_URL in
  setUp, forked = (chainid == 8453), `if (!forked) return;` in
  setUp AND every test, so the suite lives green without an RPC.

  RUN:
    BASE_RPC_URL="https://mainnet.base.org" \
      forge test --match-path test/PossessioPoolFork.t.sol -vv
//////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amt) external returns (bool);
    function approve(address spender, uint256 amt) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract PossessioPoolForkTest is Test {
    // ---- Base mainnet Circle USDC (cast-verified; same constant pinned by
    //      DeployPossessioPool.s.sol / the factory + payments fork suites) ----
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ---- TEST floor params (NOT ratified - gate 2 calibration is OPEN).
    //      Chosen at realistic USDC-6-decimals magnitudes so the math runs
    //      at mainnet scale, nothing more. ----
    uint256 constant CAP       = 5_000e6;  // 5,000 USDC operating reserve cap
    uint256 constant ABS_FLOOR =   500e6;  // 500 USDC hard baseline
    uint256 constant PER_UNIT  =    25e6;  // 25 USDC buffer per velocity unit
    uint256 constant HALFLIFE  = 7 days;   // velocity half-life

    PossessioPool internal pool;
    IUSDC internal usdc;

    // Sources are just addresses to the pool (organs authorize at
    // construction, call whenever ready). These stand in for the deploy
    // script's predicted-factory / pre-derived-x402Core / mined-whisky
    // addresses - plausible EOAs impersonated via vm.prank.
    address internal srcFactory;
    address internal srcX402;
    address internal srcWhisky;
    address internal operator;
    address internal treasury;
    address internal outsider;

    bool internal forked;

    event InfraFundsReceived(address indexed from, uint256 amount);
    event TreasurySurplusSwept(uint256 amount);
    event OperationalExpensesPaid(uint256 amount, address indexed operator);

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        if (!forked) return;

        usdc = IUSDC(USDC);

        srcFactory = makeAddr("predictedFactory"); // deploy-script source[0]
        srcX402    = makeAddr("x402CoreCreate3");  // deploy-script source[1]
        srcWhisky  = makeAddr("whiskyMarket");     // deploy-script source[2] (membership OPEN)
        operator   = makeAddr("infraOperator");
        treasury   = makeAddr("sovereignTreasury");
        outsider   = makeAddr("outsider");

        pool = _deployMirroringScript(operator, treasury);

        // Fund + approve the sources with REAL USDC. forge-std `deal`
        // writes the FiatTokenProxy's balance slot directly - its
        // compatibility with Circle's proxied storage layout is itself
        // asserted in test_fork_dealCompatibleWithRealUSDC (and already
        // relied on by PossessioFactoryFork.t.sol).
        deal(USDC, srcFactory, 1_000_000e6);
        deal(USDC, srcX402,    1_000_000e6);
        deal(USDC, srcWhisky,  1_000_000e6);
        vm.prank(srcFactory);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(srcX402);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(srcWhisky);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// Constructor call shaped exactly like DeployPossessioPool.s.sol:
    /// pinned Base USDC, sources = [factory, x402Core, whisky], then
    /// (operator, treasury, cap, floor, perUnit, halflife) in that order.
    function _deployMirroringScript(address op, address tr) internal returns (PossessioPool p) {
        address[] memory sources = new address[](3);
        sources[0] = srcFactory;
        sources[1] = srcX402;
        sources[2] = srcWhisky;
        p = new PossessioPool(USDC, sources, op, tr, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE);
    }

    /// N same-timestamp inflows of `each` from srcFactory (velocity += N
    /// units, zero intra-batch decay since dt == 0).
    function _inflowN(uint256 n, uint256 each) internal {
        for (uint256 i = 0; i < n; ++i) {
            vm.prank(srcFactory);
            pool.receiveInfraFunds(each);
        }
    }

    /*//////////////////////////////////////////////////////////////
        1. CONSTRUCTION against the real token, deploy-script shape
    //////////////////////////////////////////////////////////////*/

    function test_fork_constructionMirrorsDeployShape() public view {
        if (!forked) return;

        // The pay token is the live Circle contract: real code, 6 decimals.
        assertGt(USDC.code.length, 0, "USDC has no code on fork");
        assertEq(usdc.decimals(), 6, "Base USDC must be 6 decimals");
        assertEq(address(pool.payTokenERC20()), USDC);

        // Immutable destinations + params read back exactly as constructed.
        assertEq(pool.operatorDestination(), operator);
        assertEq(pool.treasuryDestination(), treasury);
        assertEq(pool.OPERATIONAL_CAP(), CAP);
        assertEq(pool.ABSOLUTE_FLOOR(), ABS_FLOOR);
        assertEq(pool.FLOOR_PER_UNIT(), PER_UNIT);
        assertEq(pool.VELOCITY_HALFLIFE(), HALFLIFE);

        // The 3-source set landed intact and closed.
        assertEq(pool.authorizedSourceCount(), 3);
        assertTrue(pool.isAuthorizedSource(srcFactory));
        assertTrue(pool.isAuthorizedSource(srcX402));
        assertTrue(pool.isAuthorizedSource(srcWhisky));
        assertFalse(pool.isAuthorizedSource(operator));
        assertFalse(pool.isAuthorizedSource(treasury));
        assertFalse(pool.isAuthorizedSource(outsider));

        // Fresh pool: zero accounting, floor at the absolute baseline.
        assertEq(pool.poolBalance(), 0);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR);
        assertEq(pool.drawableSurplus(), 0);
    }

    function test_fork_ctorValveGuards_holdOnRealUSDC() public {
        if (!forked) return;

        // source == operator -> refuse to exist (per-source valve check).
        address[] memory bad = new address[](2);
        bad[0] = srcFactory;
        bad[1] = operator;
        vm.expectRevert(PossessioPool.ValveIntegrityViolation.selector);
        new PossessioPool(USDC, bad, operator, treasury, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE);

        // source == treasury -> same.
        bad[1] = treasury;
        vm.expectRevert(PossessioPool.ValveIntegrityViolation.selector);
        new PossessioPool(USDC, bad, operator, treasury, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE);

        // duplicate source (deploy-config mistake) -> refuse.
        bad[1] = srcFactory;
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.DuplicateSource.selector, srcFactory));
        new PossessioPool(USDC, bad, operator, treasury, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE);

        // empty organ set -> refuse.
        vm.expectRevert(PossessioPool.EmptySourceSet.selector);
        new PossessioPool(USDC, new address[](0), operator, treasury, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE);
    }

    /*//////////////////////////////////////////////////////////////
        2. deal() vs Circle's proxied storage (load-bearing cheat)
    //////////////////////////////////////////////////////////////*/

    /// Every funded actor in this suite gets USDC via forge-std `deal`,
    /// which pokes the token's balance storage slot. Circle USDC is a
    /// FiatTokenProxy - prove the cheat actually landed in the REAL
    /// contract's layout AND that the poked balance moves through the
    /// real transfer code path (not just reads back).
    function test_fork_dealCompatibleWithRealUSDC() public {
        if (!forked) return;

        address probe = makeAddr("dealProbe");
        assertEq(usdc.balanceOf(probe), 0);
        deal(USDC, probe, 123_456789); // 123.456789 USDC
        assertEq(usdc.balanceOf(probe), 123_456789, "deal failed on proxied USDC");

        // The dealt balance is spendable through the live FiatToken code.
        address sink = makeAddr("dealSink");
        vm.prank(probe);
        assertTrue(usdc.transfer(sink, 23_456789));
        assertEq(usdc.balanceOf(sink), 23_456789);
        assertEq(usdc.balanceOf(probe), 100_000000);
    }

    /*//////////////////////////////////////////////////////////////
        3. receiveInfraFunds: real-token pull, accounting, valve
    //////////////////////////////////////////////////////////////*/

    function test_fork_receiveInfraFunds_pullsAndAccountsRealUSDC() public {
        if (!forked) return;

        uint256 srcBefore = usdc.balanceOf(srcFactory);

        vm.expectEmit(true, false, false, true, address(pool));
        emit InfraFundsReceived(srcFactory, 750e6);
        vm.prank(srcFactory);
        pool.receiveInfraFunds(750e6);

        // Accounting AND the real token agree, to the unit.
        assertEq(pool.poolBalance(), 750e6, "accounting");
        assertEq(usdc.balanceOf(address(pool)), 750e6, "real tokens held");
        assertEq(usdc.balanceOf(srcFactory), srcBefore - 750e6, "source debited");
        assertEq(usdc.balanceOf(treasury), 0, "no surplus below cap");

        // Inflow bumped the velocity window: floor rose by one unit.
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + PER_UNIT);
        assertEq(pool.drawableSurplus(), 750e6 - (ABS_FLOOR + PER_UNIT));
    }

    function test_fork_multiSourceFungible_oneBalanceOnRealToken() public {
        if (!forked) return;

        vm.prank(srcFactory);
        pool.receiveInfraFunds(300e6);
        vm.prank(srcX402);
        pool.receiveInfraFunds(200e6);
        vm.prank(srcWhisky);
        pool.receiveInfraFunds(100e6);

        // Three organs, ONE fungible balance, real tokens at one address.
        assertEq(pool.poolBalance(), 600e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        // Three inflow events -> three velocity units.
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 3 * PER_UNIT);
    }

    function test_fork_capThenSurplus_exactSweepToTreasuryInRealUSDC() public {
        if (!forked) return;

        // Overfill in one tx: cap 5,000, inflow 6,234.567890.
        uint256 inflow = CAP + 1_234_567890;

        vm.expectEmit(false, false, false, true, address(pool));
        emit TreasurySurplusSwept(1_234_567890);
        vm.prank(srcFactory);
        pool.receiveInfraFunds(inflow);

        // Balance pinned at cap; the EXACT overflow left as real USDC in
        // the treasury, atomically, same tx.
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(address(pool)), CAP);
        assertEq(usdc.balanceOf(treasury), 1_234_567890);

        // A second over-cap inflow sweeps its own exact overflow too.
        vm.prank(srcX402);
        pool.receiveInfraFunds(1); // pool at cap -> the whole unit is surplus
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(address(pool)), CAP);
        assertEq(usdc.balanceOf(treasury), 1_234_567890 + 1);
    }

    /*//////////////////////////////////////////////////////////////
        4. Velocity floor engaging on real-token draws
    //////////////////////////////////////////////////////////////*/

    function test_fork_floorHolds_drawToFloorThenRefuse() public {
        if (!forked) return;

        // 4 same-timestamp inflows of 1,000 USDC (below cap, no sweep):
        // velocity = 4 units -> floor = 500 + 4*25 = 600 USDC.
        _inflowN(4, 1_000e6);
        assertEq(pool.poolBalance(), 4_000e6);
        uint256 floor = pool.getRunningMinimumFloor();
        assertEq(floor, ABS_FLOOR + 4 * PER_UNIT); // 600e6
        uint256 surplus = pool.drawableSurplus();
        assertEq(surplus, 4_000e6 - floor); // 3,400e6

        // One unit over the surplus -> exact-args revert; nothing moves.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioPool.ExceedsDrawableSurplus.selector, surplus + 1, surplus)
        );
        pool.settleOperationalCosts(surplus + 1);
        assertEq(usdc.balanceOf(operator), 0);

        // The exact surplus draws clean, in real USDC.
        vm.expectEmit(true, false, false, true, address(pool));
        emit OperationalExpensesPaid(surplus, operator);
        vm.prank(operator);
        pool.settleOperationalCosts(surplus);
        assertEq(usdc.balanceOf(operator), surplus);
        assertEq(pool.poolBalance(), floor);
        assertEq(usdc.balanceOf(address(pool)), floor); // real tokens sit AT the floor

        // Second immediate draw - even one unit - respects the floor.
        vm.prank(operator);
        vm.expectRevert(PossessioPool.InsufficientOperationalFunds.selector);
        pool.settleOperationalCosts(1);
        assertEq(usdc.balanceOf(address(pool)), floor, "floor breached");
    }

    function test_fork_velocityDecay_matchesHalflifeMath() public {
        if (!forked) return;

        // 4 units of velocity at t0 (same-timestamp inflows).
        _inflowN(4, 1_000e6);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 4 * PER_UNIT);

        // Exactly one half-life: v = 4e18 >> 1 = 2e18 -> 2 units.
        vm.warp(block.timestamp + HALFLIFE);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 2 * PER_UNIT);

        // Half a window further (1.5 half-lives total): halvings stay 1,
        // partial-window chord takes v -= v*rem/(2*HL): 2e18 - 2e18/4 =
        // 1.5e18 -> 1 whole unit. Chord sits ABOVE true exponential decay
        // (~1.414e18) -> floor errs HIGH, the safe direction (v0.6 FIX #4).
        vm.warp(block.timestamp + HALFLIFE / 2);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 1 * PER_UNIT);

        // Two full half-lives from t0: v = 4e18 >> 2 = 1e18 -> 1 unit.
        // (Also proves decay is computed from t0's ledger, not the view calls.)
        vm.warp(block.timestamp + HALFLIFE / 2);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 1 * PER_UNIT);

        // Deep decay: past 128 half-lives velocity is exactly zero, the
        // floor rests at the immutable baseline, and the freed surplus is
        // actually drawable as real USDC.
        vm.warp(block.timestamp + 200 * HALFLIFE);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR);
        uint256 freed = pool.drawableSurplus();
        assertEq(freed, 4_000e6 - ABS_FLOOR); // 3,500e6 - decay freed 100e6 vs t0
        vm.prank(operator);
        pool.settleOperationalCosts(freed);
        assertEq(usdc.balanceOf(operator), freed);
        assertEq(usdc.balanceOf(address(pool)), ABS_FLOOR);
    }

    function test_fork_floorReenagesAfterDecay_freshInflowRaisesIt() public {
        if (!forked) return;

        // Traffic up -> floor up; traffic gone -> floor decays; traffic
        // returns -> floor re-arms. Full cycle on real transfers.
        _inflowN(2, 1_000e6);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + 2 * PER_UNIT);

        vm.warp(block.timestamp + 200 * HALFLIFE);
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR);

        vm.prank(srcX402);
        pool.receiveInfraFunds(500e6); // fresh inflow re-arms one unit
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR + PER_UNIT);
        assertEq(pool.poolBalance(), 2_500e6);
        assertEq(pool.drawableSurplus(), 2_500e6 - (ABS_FLOOR + PER_UNIT));
    }

    /*//////////////////////////////////////////////////////////////
        5. One-way operator draw + valve-by-omission on the live token
    //////////////////////////////////////////////////////////////*/

    function test_fork_operatorDraw_isOneWay_operatorCannotPushBack() public {
        if (!forked) return;

        _inflowN(1, 3_000e6);
        uint256 surplus = pool.drawableSurplus();

        // Only the immutable operator draws; a funded outsider cannot.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, outsider));
        pool.settleOperationalCosts(1e6);

        vm.prank(operator);
        pool.settleOperationalCosts(surplus);
        assertEq(usdc.balanceOf(operator), surplus);

        // ONE-WAY: the operator now holds real USDC with max allowance to
        // the pool - and still has NO door back in. Valve-by-omission on
        // the live token, not the mock.
        vm.startPrank(operator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, operator));
        pool.receiveInfraFunds(surplus);
        vm.stopPrank();

        // Same for treasury after a real surplus sweep.
        vm.prank(srcFactory);
        pool.receiveInfraFunds(CAP + 100e6); // sweeps 100e6 + refill to cap
        assertGt(usdc.balanceOf(treasury), 0);
        vm.startPrank(treasury);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, treasury));
        pool.receiveInfraFunds(1e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        6. Negative probes with real USDC in hand
    //////////////////////////////////////////////////////////////*/

    function test_fork_unauthorizedSourceRefused_evenFundedAndApproved() public {
        if (!forked) return;

        // The outsider holds real USDC and has approved the pool - money
        // and allowance don't open the door, only construction membership.
        deal(USDC, outsider, 10_000e6);
        vm.startPrank(outsider);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, outsider));
        pool.receiveInfraFunds(10_000e6);
        vm.stopPrank();
        assertEq(pool.poolBalance(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    /// Pool DoD #14: raw USDC pushed straight to the pool address is dead
    /// weight by design - no sync door exists. Proven on the real token.
    function test_fork_rawUSDCTransfer_uncredited_deadWeight() public {
        if (!forked) return;

        address stranger = makeAddr("stranger");
        deal(USDC, stranger, 900e6);
        vm.prank(stranger);
        assertTrue(usdc.transfer(address(pool), 900e6)); // real FiatToken transfer

        // Tokens arrived; accounting did not move.
        assertEq(usdc.balanceOf(address(pool)), 900e6);
        assertEq(pool.poolBalance(), 0, "raw transfer must not credit");
        assertEq(pool.drawableSurplus(), 0, "raw transfer must not create surplus");
        assertEq(pool.getRunningMinimumFloor(), ABS_FLOOR, "raw transfer must not bump velocity");

        // The stranded 900 stays stranded through normal operation:
        // an accounted inflow over cap sweeps ONLY its own exact overflow,
        // and the operator draw is bounded by ACCOUNTED surplus.
        vm.prank(srcFactory);
        pool.receiveInfraFunds(CAP + 50e6);
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(treasury), 50e6, "sweep must ignore stranded tokens");
        assertEq(usdc.balanceOf(address(pool)), CAP + 900e6, "stranded tokens remain");

        uint256 surplus = pool.drawableSurplus(); // accounted only
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioPool.ExceedsDrawableSurplus.selector, surplus + 900e6, surplus)
        );
        pool.settleOperationalCosts(surplus + 900e6); // stranded funds unreachable
    }

    /// Destination/source separation across a full live cycle: the only
    /// egress paths are treasury (surplus) and operator (floored draw);
    /// sources only ever pay in; real token conservation holds to the unit.
    function test_fork_destinationSourceSeparation_conservation() public {
        if (!forked) return;

        uint256 f0 = usdc.balanceOf(srcFactory);
        uint256 x0 = usdc.balanceOf(srcX402);
        uint256 w0 = usdc.balanceOf(srcWhisky);

        vm.prank(srcFactory);
        pool.receiveInfraFunds(4_000e6);
        vm.prank(srcX402);
        pool.receiveInfraFunds(2_000e6); // total 6,000 -> 1,000 sweeps

        uint256 surplus = pool.drawableSurplus();
        vm.prank(operator);
        pool.settleOperationalCosts(surplus);

        // Sources strictly debited, never credited.
        assertEq(usdc.balanceOf(srcFactory), f0 - 4_000e6);
        assertEq(usdc.balanceOf(srcX402), x0 - 2_000e6);
        assertEq(usdc.balanceOf(srcWhisky), w0);

        // Egress went ONLY to the two immutable destinations, and the
        // real tokens left behind equal the accounted balance exactly.
        assertEq(usdc.balanceOf(treasury), 1_000e6);
        assertEq(usdc.balanceOf(operator), surplus);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
        assertEq(
            usdc.balanceOf(address(pool)) + usdc.balanceOf(treasury) + usdc.balanceOf(operator),
            6_000e6,
            "token conservation"
        );
    }
}
