// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
   DoD -- PossessioRail V2: the constrained multi-hop route and the
   remote (Solana) leg.

   Two additions, one Rail:

   1. MULTI-HOP, CONSTRAINED IN CODE. V1 spoke only exactInputSingle, so it
      could reach a token ONLY through a direct USDC pool -- and real Base
      liquidity for new tokens is overwhelmingly TOKEN/WETH, which put most of
      the desk's intended universe out of reach (Architect, ledger row 68).
      V2 opens the universe without opening a routing surface: the caller
      supplies a SHAPE (viaWeth + fee tiers), never path bytes, and the Rail
      assembles the path from its own immutables. The route is RECORDED at
      entry and REPLAYED reversed at exit, so entry/exit are mirrored
      structurally rather than by keeper discipline.

   2. THE REMOTE LEG. draw -> pending -> settle, all measured in USDC, so the
      vault's caps, its outstanding ledger and its one-trader wiring are
      untouched. The load-bearing rule: settlement MEASURES the balance delta
      and never accepts a reported amount.
//////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";
import {MockUSDC, MockToken, MockSwapRouter, MockAutoTarget} from "./PossessioRail.t.sol";

contract PossessioRailV2Test is Test {
    uint256 internal constant MIN_SETTLE_BPS = 0; // R-H1 floor OFF here: this suite proves pre-existing behaviour; the floor is proven in PossessioRailAdversarial
    MockUSDC usdc; MockToken token; MockToken weth; MockSwapRouter router; MockAutoTarget at;
    PossessioFundingVault vault; PossessioRail rail;

    address owner  = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address rando  = makeAddr("rando");
    address remoteAgent = makeAddr("remoteAgent");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;
    uint256 constant REMOTE_TIMEOUT  = 24 hours;

    uint24 constant FEE_USDC_WETH = 500;
    uint24 constant FEE_WETH_TOK  = 3000;
    uint32 constant SOL = 101;

    function setUp() public {
        usdc = new MockUSDC(); token = new MockToken(); weth = new MockToken();
        router = new MockSwapRouter(); at = new MockAutoTarget();

        uint256 n = vm.getNonce(address(this));
        address predictedRail = vm.computeCreateAddress(address(this), n + 1);
        vault = new PossessioFundingVault(
            IERC20(address(usdc)), owner, predictedRail, predictedRail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
        rail = new PossessioRail(
            IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)),
            keeper, ISwapRouter(address(router)), address(weth), remoteAgent, REMOTE_TIMEOUT, MIN_SETTLE_BPS
        );
        vm.startPrank(owner);   // R-H1 route whitelist
        rail.setRouteAllowed(address(token), false, FEE_WETH_TOK, 0, true);
        rail.setRouteAllowed(address(token), true, FEE_USDC_WETH, FEE_WETH_TOK, true);
        vm.stopPrank();
        require(address(rail) == predictedRail, "prewire");

        usdc.mint(owner, 100_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.fund(50_000e6);
        vm.stopPrank();

        // the mock venue can pay either side out
        usdc.mint(address(router), 1_000_000e6);
        token.mint(address(router), 1_000_000e18);
        weth.mint(address(router), 1_000_000e18);
    }

    function _openIntent(uint256 id, address tok, uint32 chain) internal {
        at.setIntent(id, tok, chain, 1); // status 1 = Open
    }

    //  1. MULTI-HOP: THE UNIVERSE OPENS 

    /// The finding that held the broadcast: a token with NO direct USDC pool is
    /// now reachable through the one permitted hop.
    function test_V2_1_enterViaWeth_reachesTokenWithNoUsdcPool() public {
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);

        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);

        (address t, uint256 usdcIn, uint256 tokenAmt, PossessioRail.Status st) = rail.getPosition(1);
        assertEq(t, address(token), "token");
        assertEq(usdcIn, 1_000e6, "drawn");
        assertEq(tokenAmt, 500e18, "bought");
        assertEq(uint8(st), uint8(PossessioRail.Status.Open), "open");
        assertEq(token.balanceOf(address(rail)), 500e18, "rail holds the position");
    }

    /// The path the Rail assembled must be USDC-feeA-WETH-feeB-token, built from
    /// its own immutables. Proven by decoding the bytes the router received.
    function test_V2_2_pathIsAssembledFromImmutables_notFromCaller() public {
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);

        bytes memory expected = abi.encodePacked(
            address(usdc), FEE_USDC_WETH, address(weth), FEE_WETH_TOK, address(token)
        );
        assertEq(router.lastPath(), expected, "path == USDC-feeA-WETH-feeB-token");
        assertEq(router.lastPath().length, 66, "two-hop V3 path length (20+3+20+3+20)");
    }

    /// THE MIRROR, STRUCTURAL: exit takes no route arguments at all, so it can
    /// only ever replay the recorded entry route, reversed.
    function test_V2_3_exitReplaysTheRecordedRouteReversed() public {
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);

        (bool viaWeth, uint24 feeA, uint24 feeB) = rail.getRoute(1);
        assertTrue(viaWeth, "route recorded: viaWeth");
        assertEq(feeA, FEE_USDC_WETH, "feeA recorded");
        assertEq(feeB, FEE_WETH_TOK, "feeB recorded");

        at.setIntent(1, address(token), 8453, 2); // Resolved
        router.setOut(1_100e6);
        vm.prank(keeper);
        rail.exit(1, 1e6); // <- no route args exist to get wrong

        bytes memory expected = abi.encodePacked(
            address(token), FEE_WETH_TOK, address(weth), FEE_USDC_WETH, address(usdc)
        );
        assertEq(router.lastPath(), expected, "exit path is the entry path reversed");
        assertEq(token.balanceOf(address(rail)), 0, "position fully sold");
        assertEq(usdc.balanceOf(address(rail)), 0, "nothing stranded at the rail");
    }

    /// A direct-route position still uses the single-hop call (cheaper, and the
    /// same mirror guarantee).
    function test_V2_4_directRouteStillSingleHop_andMirrors() public {
        _openIntent(1, address(token), 8453);
        router.setOut(400e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE_WETH_TOK, 0);
        (bool viaWeth,,) = rail.getRoute(1);
        assertFalse(viaWeth, "direct route recorded");

        at.setIntent(1, address(token), 8453, 2);
        router.setOut(1_050e6);
        vm.prank(keeper);
        rail.exit(1, 1e6);
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.Closed), "closed");
    }

    //  2. ROUTE HYGIENE (no third route exists) 

    function test_V2_5_badRoutes_allRefused() public {
        _openIntent(1, address(token), 8453);
        router.setOut(1e18);

        // zero fee tier is never a real pool
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.BadRoute.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, false, 0, 0);

        // feeB is meaningless on a direct route -- refused, not ignored
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.BadRoute.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE_WETH_TOK, FEE_WETH_TOK);

        // viaWeth needs both tiers
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.BadRoute.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, 0);

        // WETH itself through WETH is the direct route, not a hop
        _openIntent(2, address(weth), 8453);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.RouteHopIsWeth.selector);
        rail.enter(2, address(weth), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);
    }

    /// The owner's bail-out is the ONLY place a route may differ from the
    /// recorded one -- and it still cannot invent a third shape or a new
    /// destination.
    function test_V2_6_ownerExitVia_overridesVenueOnly() public {
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        router.setOut(900e6);
        vm.prank(owner);
        rail.ownerExitVia(1, 1e6, false, 10000, 0); // migrate to a direct 1% pool

        bytes memory expected = abi.encodePacked(address(token), uint24(10000), address(usdc));
        // single-hop override goes through exactInputSingle, so lastPath is the
        // earlier entry path -- assert the MONEY instead: home to the vault.
        expected; // silence unused
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 900e6, "proceeds home to the vault");
        assertEq(usdc.balanceOf(address(rail)), 0, "rail holds nothing");

        // and an override still cannot be a nonsense route
        _openIntent(2, address(token), 8453);
        router.setOut(100e18);
        vm.prank(keeper);
        rail.enter(2, address(token), 500e6, 1e18, false, FEE_WETH_TOK, 0);
        vm.prank(owner);
        vm.expectRevert(PossessioRail.BadRoute.selector);
        rail.ownerExitVia(2, 1e6, true, FEE_USDC_WETH, 0);
    }

    function test_V2_7_ownerExitVia_ownerOnly() public {
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE_WETH_TOK, 0);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.ownerExitVia(1, 1e6, false, FEE_WETH_TOK, 0);
    }

    //  3. THE REMOTE LEG 

    function test_V2_8_openRemoteLeg_drawsUnderCaps_andHandsOff() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);

        (, uint256 usdcIn, , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(usdcIn, 1_000e6, "drawn");
        assertEq(uint8(st), uint8(PossessioRail.Status.Pending), "pending");
        assertEq(usdc.balanceOf(remoteAgent), 1_000e6, "agent holds the capital");
        assertEq(usdc.balanceOf(address(rail)), 0, "rail holds nothing mid-leg");
        assertEq(vault.outstanding(), 1_000e6, "vault charges outstanding");
        assertEq(rail.pendingRemoteLegs(), 1, "one leg pending");
    }

    /// Inv. 9 -- a remote leg cannot skip the caps.
    function test_V2_9_remoteLeg_overPerTradeCap_reverts() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        vm.expectRevert();
        rail.openRemoteLeg(1, MAX_PER_TRADE + 1);
        assertEq(vault.outstanding(), 0, "nothing drawn");
    }

    /// Inv. 11 -- the leg mode is decided by the authored intent, not the caller.
    function test_V2_10_crossRouting_refusedBothDirections() public {
        _openIntent(1, address(token), 8453); // a BASE intent
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.WrongChain.selector);
        rail.openRemoteLeg(1, 100e6);

        _openIntent(2, address(token), SOL);  // a SOLANA intent
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.WrongChain.selector);
        rail.enter(2, address(token), 100e6, 1e18, false, FEE_WETH_TOK, 0);
    }

    /// THE LOAD-BEARING RULE (Inv. 10). The agent returns an amount DIFFERENT
    /// from the draw and different from anything reported; the vault must be
    /// credited with the MEASURED figure.
    function test_V2_11_settle_creditsTheMeasuredDelta_notAClaim() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);

        // the leg comes home 23.7% up -- a number nobody told the contract
        usdc.mint(remoteAgent, 237e6); // the off-chain gain
        vm.prank(remoteAgent);
        usdc.transfer(address(rail), 1_237e6);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(keeper);
        rail.settleRemoteLeg(1);

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 1_237e6, "vault credited the MEASURED delta");
        assertEq(vault.outstanding(), 0, "exposure cleared");
        assertEq(usdc.balanceOf(address(rail)), 0, "nothing left at the rail");
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.Closed), "terminal");
    }

    /// settleRemoteLeg has NO amount parameter -- the ABI itself refuses a claim.
    function test_V2_12_settle_hasNoAmountParameter() public {
        // If an amount param existed this selector would not be the one-arg form.
        assertEq(
            PossessioRail.settleRemoteLeg.selector,
            bytes4(keccak256("settleRemoteLeg(uint256)")),
            "settle takes only the intent id -- a reported amount cannot be passed"
        );
    }

    function test_V2_13_settle_withNothingBack_reverts() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.NothingReturned.selector);
        rail.settleRemoteLeg(1);
        assertEq(vault.outstanding(), 1_000e6, "still charged -- a lost leg starves the next draw");
    }

    function test_V2_14_doubleSettle_reverts() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        vm.prank(remoteAgent);
        usdc.transfer(address(rail), 900e6);
        vm.prank(keeper);
        rail.settleRemoteLeg(1);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.PositionNotPending.selector);
        rail.settleRemoteLeg(1);
    }

    /// One leg at a time -- the constraint that makes the measurement provable
    /// rather than an attribution guess.
    function test_V2_15_onlyOneRemoteLegAtATime() public {
        _openIntent(1, address(0), SOL);
        _openIntent(2, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 500e6);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.RemoteLegPending.selector);
        rail.openRemoteLeg(2, 500e6);
    }

    function test_V2_16_abandon_beforeTimeout_reverts() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        vm.prank(owner);
        vm.expectRevert(PossessioRail.TimeoutNotElapsed.selector);
        rail.abandonRemoteLeg(1);
    }

    /// After the timeout the owner releases the cap charge -- and a PARTIAL
    /// return is banked, not stranded (the Rail's `sweep` cannot move USDC).
    function test_V2_17_abandon_afterTimeout_banksPartialReturn() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);

        vm.prank(remoteAgent);
        usdc.transfer(address(rail), 300e6); // only 30% ever came home
        vm.warp(block.timestamp + REMOTE_TIMEOUT + 1);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(owner);
        rail.abandonRemoteLeg(1);

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 300e6, "partial return banked, not stranded");
        assertEq(vault.outstanding(), 0, "cap charge released");
        assertEq(usdc.balanceOf(address(rail)), 0, "rail clean");
        assertEq(rail.pendingRemoteLegs(), 0, "slot freed");
    }

    function test_V2_18_abandon_totalLoss_releasesWithoutConjuringUsdc() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        vm.warp(block.timestamp + REMOTE_TIMEOUT + 1);
        vm.prank(owner);
        rail.abandonRemoteLeg(1);
        assertEq(vault.outstanding(), 0, "released");
        // The loss is real: the vault got nothing back.
        assertEq(usdc.balanceOf(address(vault)), 50_000e6 - 1_000e6, "loss recorded, not papered over");
    }

    function test_V2_19_abandon_ownerOnly_keeperCannot() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        vm.warp(block.timestamp + REMOTE_TIMEOUT + 1);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.abandonRemoteLeg(1);
    }

    function test_V2_20_remoteLeg_keeperOnly() public {
        _openIntent(1, address(0), SOL);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotKeeper.selector);
        rail.openRemoteLeg(1, 100e6);
    }

    //  4. THE STRAND, CLOSED 

    /// Exit-audit finding (ledger row 62): USDC arriving outside an atomic flow
    /// had NO exit -- `sweep` refuses USDC unconditionally. It now goes home.
    function test_V2_21_sweepUsdcHome_recoversMisSentUsdc() public {
        usdc.mint(rando, 777e6);
        vm.prank(rando);
        usdc.transfer(address(rail), 777e6); // a mis-send that used to be burned

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(owner);
        rail.sweepUsdcHome();

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 777e6, "mis-sent USDC recovered to the vault");
        assertEq(usdc.balanceOf(address(rail)), 0, "rail clean");
    }

    /// It goes HOME, never to a caller -- the direction is the safety property.
    function test_V2_22_sweepUsdcHome_ownerOnly_andNeverToCaller() public {
        usdc.mint(address(rail), 100e6);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.sweepUsdcHome();

        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        rail.sweepUsdcHome();
        assertEq(usdc.balanceOf(owner), ownerBefore, "not one cent to the caller");
    }

    /// It cannot front-run a settlement measurement.
    function test_V2_23_sweepUsdcHome_blockedWhileLegPending() public {
        _openIntent(1, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(1, 1_000e6);
        usdc.mint(remoteAgent, 100e6);
        vm.prank(remoteAgent);
        usdc.transfer(address(rail), 1_100e6);

        vm.prank(owner);
        vm.expectRevert(PossessioRail.RemoteLegPending.selector);
        rail.sweepUsdcHome();

        // the settle still measures the full return
        vm.prank(keeper);
        rail.settleRemoteLeg(1);
        assertEq(vault.outstanding(), 0, "settled normally");
    }

    function test_V2_24_sweepUsdcHome_zeroBalance_reverts() public {
        vm.prank(owner);
        vm.expectRevert(PossessioRail.ZeroAmount.selector);
        rail.sweepUsdcHome();
    }

    //  5. CONSTRUCTOR 

    function test_V2_25_constructor_rejectsZeroAndZeroTimeout() public {
        vm.expectRevert(PossessioRail.ZeroAddress.selector);
        new PossessioRail(IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)),
            keeper, ISwapRouter(address(router)), address(0), remoteAgent, REMOTE_TIMEOUT, MIN_SETTLE_BPS);
        vm.expectRevert(PossessioRail.ZeroAddress.selector);
        new PossessioRail(IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)),
            keeper, ISwapRouter(address(router)), address(weth), address(0), REMOTE_TIMEOUT, MIN_SETTLE_BPS);
        vm.expectRevert(PossessioRail.ZeroAmount.selector);
        new PossessioRail(IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)),
            keeper, ISwapRouter(address(router)), address(weth), remoteAgent, 0, MIN_SETTLE_BPS);
    }

    /// Inv. 8 -- one Rail, one vault, both legs settle through the same door.
    function test_V2_26_bothLegsSettleThroughTheSameVault() public {
        // a Base leg
        _openIntent(1, address(token), 8453);
        router.setOut(500e18);
        vm.prank(keeper);
        rail.enter(1, address(token), 1_000e6, 1e18, true, FEE_USDC_WETH, FEE_WETH_TOK);
        at.setIntent(1, address(token), 8453, 2);
        router.setOut(1_100e6);
        vm.prank(keeper);
        rail.exit(1, 1e6);

        // and a remote leg, same vault, same ledger
        _openIntent(2, address(0), SOL);
        vm.prank(keeper);
        rail.openRemoteLeg(2, 1_000e6);
        usdc.mint(remoteAgent, 50e6);
        vm.prank(remoteAgent);
        usdc.transfer(address(rail), 1_050e6);
        vm.prank(keeper);
        rail.settleRemoteLeg(2);

        assertEq(vault.outstanding(), 0, "both legs cleared through the one vault");
        assertEq(usdc.balanceOf(address(rail)), 0, "rail nets to zero across both legs");
        assertEq(address(vault.trader()), address(rail), "one trader");
    }
}
