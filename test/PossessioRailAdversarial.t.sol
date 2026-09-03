// SPDX-License-Identifier: MIT
// Adversarial gauntlet for PossessioRail (SPEC_RailAndKeeper.md §8).
// Every role boundary held; every cap enforced by the vault; the sell rule
// un-bypassable except by the owner; proceeds only ever go home.
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";
import {MockUSDC, MockToken, MockSwapRouter, MockAutoTarget} from "./PossessioRail.t.sol";

contract PossessioRailAdversarialTest is Test {
    uint256 internal constant MIN_SETTLE_BPS = 5_000; // R-H1: keeper settle/exit floor (50%)
    MockUSDC usdc; MockToken token; MockToken weth; MockSwapRouter router; MockAutoTarget at;
    address remoteAgent = makeAddr("remoteAgent");
    uint256 constant REMOTE_TIMEOUT = 24 hours;
    PossessioFundingVault vault; PossessioRail rail;

    address owner  = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;
    uint24  constant FEE = 3000;

    function setUp() public {
        usdc = new MockUSDC(); token = new MockToken(); weth = new MockToken(); router = new MockSwapRouter(); at = new MockAutoTarget();
        uint256 n = vm.getNonce(address(this));
        address predictedRail = vm.computeCreateAddress(address(this), n + 1);
        vault = new PossessioFundingVault(IERC20(address(usdc)), owner, predictedRail, predictedRail, MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP);
        rail  = new PossessioRail(IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)), keeper, ISwapRouter(address(router)), address(weth), remoteAgent, REMOTE_TIMEOUT, MIN_SETTLE_BPS);
        vm.prank(owner); rail.setRouteAllowed(address(token), false, FEE, 0, true);   // R-H1 route whitelist
        require(address(rail) == predictedRail, "prewire");
        usdc.mint(owner, 100_000e6);
        vm.startPrank(owner); usdc.approve(address(vault), 100_000e6); vault.fund(100_000e6); vm.stopPrank();
        token.mint(address(router), 10_000_000e18);
        usdc.mint(address(router), 10_000_000e6);
    }
    function _open(uint256 id, uint8 status) internal { at.setIntent(id, address(token), 8453, status); }
    function _enter(uint256 id, uint256 size) internal { _open(id,1); router.setOut(100e18); vm.prank(keeper); rail.enter(id, address(token), size, 1e18, false, FEE, 0); }

    // ─────────────────────── zero / input guards ───────────────────────────
    function test_enter_zeroToken() public { _open(1,1); vm.prank(keeper); vm.expectRevert(PossessioRail.ZeroAddress.selector); rail.enter(1, address(0), 1_000e6, 1e18, false, FEE, 0); }
    function test_enter_zeroSize() public { _open(1,1); vm.prank(keeper); vm.expectRevert(PossessioRail.ZeroAmount.selector); rail.enter(1, address(token), 0, 1e18, false, FEE, 0); }
    function test_enter_zeroMinOut_reverts() public { _open(1,1); vm.prank(keeper); vm.expectRevert(PossessioRail.ZeroMinOut.selector); rail.enter(1, address(token), 1_000e6, 0, false, FEE, 0); }
    function test_exit_zeroMinOut_reverts() public { _enter(1, 1_000e6); at.setStatus(1,2); vm.prank(keeper); vm.expectRevert(PossessioRail.ZeroMinOut.selector); rail.exit(1, 0); }

    // ─────────────────────── role boundaries ───────────────────────────────
    function test_attacker_cannotEnter() public { _open(1,1); vm.prank(attacker); vm.expectRevert(PossessioRail.NotKeeper.selector); rail.enter(1, address(token), 1_000e6, 1e18, false, FEE, 0); }
    function test_attacker_cannotExit() public { _enter(1,1_000e6); at.setStatus(1,2); vm.prank(attacker); vm.expectRevert(PossessioRail.NotKeeper.selector); rail.exit(1, 1); }
    function test_attacker_cannotOwnerExit() public { _enter(1,1_000e6); vm.prank(attacker); vm.expectRevert(PossessioRail.NotOwner.selector); rail.ownerExit(1, 1); }
    function test_keeper_cannotOwnerExit() public { _enter(1,1_000e6); vm.prank(keeper); vm.expectRevert(PossessioRail.NotOwner.selector); rail.ownerExit(1, 1); }
    function test_attacker_cannotSweep() public { MockToken s=new MockToken(); s.mint(address(rail),1e18); vm.prank(attacker); vm.expectRevert(PossessioRail.NotOwner.selector); rail.sweep(address(s)); }

    // ─────────────────── the sell rule is un-bypassable ────────────────────
    function test_keeper_cannotSell_openIntent() public {
        _enter(1,1_000e6); // intent Open, never resolved
        vm.prank(keeper); vm.expectRevert(PossessioRail.ExitNotAuthorized.selector); rail.exit(1, 1);
    }
    function test_keeper_cannotSell_cancelledIntent() public {
        _enter(1,1_000e6); at.setStatus(1,4); // Cancelled, not Resolved
        vm.prank(keeper); vm.expectRevert(PossessioRail.ExitNotAuthorized.selector); rail.exit(1, 1);
    }
    function test_exit_unknownPosition_reverts() public {
        _open(9,2); vm.prank(keeper); vm.expectRevert(PossessioRail.PositionNotOpen.selector); rail.exit(9, 1);
    }

    // ─────────────────── caps are the vault's, enforced ────────────────────
    function test_outstandingCap_blocksThirdConcurrent_noPosition() public {
        _enter(1, MAX_PER_TRADE); _enter(2, MAX_PER_TRADE);      // 7,000 outstanding
        _open(3,1); router.setOut(100e18);
        vm.prank(keeper);
        vm.expectRevert(PossessioFundingVault.OutstandingCapExceeded.selector); // 10,500 > 10,000
        rail.enter(3, address(token), MAX_PER_TRADE, 1e18, false, FEE, 0);
        (, , , PossessioRail.Status st) = rail.getPosition(3);
        assertEq(uint8(st), uint8(PossessioRail.Status.None));
        assertLe(vault.outstanding(), MAX_OUTSTANDING);
    }
    function test_dailyCap_blocksDraw_noPosition() public {
        vm.prank(owner); vault.decreaseCap(PossessioFundingVault.Cap.DailyDraw, 500e6); // tighten daily to 500
        _open(1,1); router.setOut(100e18);
        vm.prank(keeper);
        vm.expectRevert(PossessioFundingVault.DailyCapExceeded.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE, 0);
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.None));
    }

    // ─────────────────── slippage floor cannot be loosened ─────────────────
    function test_buy_slippage_enforced_atRouter() public {
        _open(1,1); router.setOut(400e18); // router will pay 400 MEME
        vm.prank(keeper);
        vm.expectRevert(bytes("slippage"));                 // demand 401 -> router refuses
        rail.enter(1, address(token), 1_000e6, 401e18, false, FEE, 0);
    }
    function test_sell_slippage_enforced_atRouter() public {
        _enter(1,1_000e6); at.setStatus(1,2); router.setOut(900e6);
        vm.prank(keeper);
        vm.expectRevert(bytes("slippage"));                 // demand 901 USDC -> refuses
        rail.exit(1, 901e6);
    }

    // ─────────────── proceeds ONLY go home; dead keeper ────────────────────
    function test_proceeds_onlyToVault_notKeeperOrAttacker() public {
        _enter(1, 3_000e6); at.setStatus(1,2); router.setOut(3_600e6);
        uint256 vBefore = usdc.balanceOf(address(vault));
        vm.prank(keeper); rail.exit(1, 1_500e6); /* R-H1: keeper floor = 50% of usdcIn */
        assertEq(usdc.balanceOf(address(vault)) - vBefore, 3_600e6); // vault got exactly the proceeds
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(address(rail)), 0);                  // nothing stranded at the rail
    }
    function test_deadKeeper_ownerCanStillExit() public {
        _enter(1, 3_000e6);            // keeper opened, then "dies" (never resolves)
        router.setOut(2_800e6);
        vm.prank(owner); rail.ownerExit(1, 1);        // owner is never trapped
        assertEq(vault.outstanding(), 0);
    }

    // ─────────────────── lifecycle terminal-state abuse ────────────────────
    function test_reenter_afterClose_reverts() public {
        _enter(1, 3_000e6); at.setStatus(1,2); router.setOut(3_600e6);
        vm.prank(keeper); rail.exit(1, 1_500e6); /* R-H1: keeper floor = 50% of usdcIn */            // Closed
        _open(1,1);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.PositionExists.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE, 0);
    }
    function test_ownerExit_thenExit_reverts() public {
        _enter(1, 3_000e6); router.setOut(2_500e6);
        vm.prank(owner); rail.ownerExit(1, 1);        // owner closed it
        at.setStatus(1,2);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.PositionNotOpen.selector);
        rail.exit(1, 1);
    }
    /*//////////////////////////////////////////////////////////////
        R-H1 (re-audit 2026-09-01) — keeper-key drain bounds
    //////////////////////////////////////////////////////////////*/
    function _openRemote(uint256 id) internal { at.setIntent(id, address(0), 101, 1); }   // Solana-tagged, Open

    /// RED on the pre-fix rail: openRemoteLeg → 1 wei back → settleRemoteLeg cleared
    /// outstanding; repeated, 49,999.999999 USDC reached the agent in 3 days.
    function test_RH1_remoteLeg_dustSettleIsKeeperBlocked_ownerOnly() public {
        _openRemote(1);
        vm.prank(keeper); rail.openRemoteLeg(1, 3_000e6);
        usdc.mint(address(rail), 1);                       // "the agent returned 1 wei"
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioRail.SettleBelowMinimum.selector, 1, 1_500e6));
        rail.settleRemoteLeg(1);
        assertEq(vault.outstanding(), 3_000e6, "exposure stays charged until an honest settle");
        _openRemote(2);                                    // and the next leg cannot open on top of it
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.RemoteLegPending.selector);
        rail.openRemoteLeg(2, 3_000e6);
        vm.prank(owner); rail.ownerSettleRemoteLeg(1);     // a genuinely bad leg is the owner's call
        assertEq(vault.outstanding(), 0);
        assertEq(rail.pendingRemoteLegs(), 0);
    }

    function test_RH1_remoteLeg_honestReturnSettles() public {
        _openRemote(1);
        vm.prank(keeper); rail.openRemoteLeg(1, 3_000e6);
        usdc.mint(address(rail), 2_800e6);
        vm.prank(keeper); rail.settleRemoteLeg(1);
        assertEq(vault.outstanding(), 0);
        assertEq(rail.pendingRemoteLegs(), 0);
    }

    /// RED on the pre-fix rail: exit(minUsdcOut = 1) through a rigged venue took 17,500 USDC.
    function test_RH1_baseLeg_keeperExitFloor_ownerExitUnbounded() public {
        _enter(1, 3_000e6); at.setStatus(1, 2); router.setOut(100e6);   // venue pays 100 of 3,000 back
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioRail.ExitFloorBelowMinimum.selector, 1, 1_500e6));
        rail.exit(1, 1);
        vm.prank(keeper);
        vm.expectRevert(bytes("slippage"));                 // floor-compliant min the venue cannot meet
        rail.exit(1, 1_500e6);
        vm.prank(owner); rail.ownerExit(1, 1);              // the owner's call, on the record
        assertEq(vault.outstanding(), 0);
    }

    /// RED on the pre-fix rail: any (token, fee tier) the keeper named was a valid venue.
    function test_RH1_enter_routeMustBeOwnerAllowed() public {
        _open(1, 1); router.setOut(100e18);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.RouteNotAllowed.selector);
        rail.enter(1, address(token), 3_000e6, 1e18, false, 10000, 0);   // 1% tier: not allowed
        vm.prank(attacker);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.setRouteAllowed(address(token), false, 10000, 0, true);
        vm.prank(owner); rail.setRouteAllowed(address(token), false, 10000, 0, true);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, 10000, 0);
    }
}
