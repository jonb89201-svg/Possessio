// SPDX-License-Identifier: MIT
// DoD suite for PossessioFundingVault (SPEC_FundingVault.md §9).
// Certifies the happy paths + the two never-regress invariants:
//   §5.1 owner-always-can-exit   §5.2 trader-is-bounded
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";

/// @dev 6-decimal USDC stand-in.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

abstract contract VaultFixture is Test {
    MockUSDC internal usdc;
    PossessioFundingVault internal vault;

    address internal owner   = makeAddr("owner");   // operator passkey account
    address internal trader  = makeAddr("trader");  // desk + keeper
    // Under ratified Option A tradeDestination == owner's Base Account. Use a
    // distinct rail address here so draw-recipient vs withdraw-recipient are
    // independently asserted (the contract hardcodes each separately).
    address internal rail    = makeAddr("tradeDestination");
    address internal outsider = makeAddr("outsider");

    // Caps (6-dec USDC). Small launch values per §8.2.
    uint256 internal constant MAX_PER_TRADE    = 3_500e6;   // ~$3.5k per trade
    uint256 internal constant MAX_OUTSTANDING  = 10_000e6;  // ~$10k concurrent
    uint256 internal constant DAILY_DRAW_CAP   = 20_000e6;  // ~$20k / 24h

    function _deploy() internal {
        usdc = new MockUSDC();
        vault = new PossessioFundingVault(
            IERC20(address(usdc)),
            owner,
            trader,
            rail,
            MAX_PER_TRADE,
            MAX_OUTSTANDING,
            DAILY_DRAW_CAP
        );
    }

    /// @dev owner funds `amount` into the vault.
    function _fund(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    /// @dev rail approves the vault to pull returns (Option A: owner==rail would
    ///      approve; here the rail account approves).
    function _railApprove(uint256 amount) internal {
        vm.prank(rail);
        usdc.approve(address(vault), amount);
    }
}

contract PossessioFundingVaultTest is VaultFixture {
    function setUp() public { _deploy(); }

    // ─────────────────────────── construction ──────────────────────────────

    function test_immutables_set() public view {
        assertEq(address(vault.payToken()), address(usdc));
        assertEq(vault.owner(), owner);
        assertEq(vault.trader(), trader);
        assertEq(vault.tradeDestination(), rail);
        assertEq(vault.maxPerTrade(), MAX_PER_TRADE);
        assertEq(vault.maxOutstanding(), MAX_OUTSTANDING);
        assertEq(vault.dailyDrawCap(), DAILY_DRAW_CAP);
        assertEq(vault.outstanding(), 0);
        assertFalse(vault.paused());
    }

    // ────────────────────────────── fund ───────────────────────────────────

    function test_fund_pullsUSDC() public {
        _fund(5_000e6);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(vault.available(), 5_000e6);
    }

    function test_fund_anyoneCanTopUp() public {
        usdc.mint(outsider, 1_000e6);
        vm.startPrank(outsider);
        usdc.approve(address(vault), 1_000e6);
        vault.fund(1_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_fund_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.ZeroAmount.selector);
        vault.fund(0);
    }

    // ───────────────────────────── withdraw ────────────────────────────────

    function test_withdraw_toOwnerOnly() public {
        _fund(5_000e6);
        vm.prank(owner);
        vault.withdraw(2_000e6);
        assertEq(usdc.balanceOf(owner), 2_000e6);
        assertEq(vault.available(), 3_000e6);
    }

    // §5.1 owner-always-can-exit: withdraw works with trades outstanding, down
    // to exactly `outstanding`.
    function test_withdraw_downToOutstanding_withOpenTrades() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);           // outstanding = 3k
        assertEq(vault.outstanding(), 3_000e6);
        assertEq(vault.available(), 7_000e6);      // 10k bal − 3k out

        vm.prank(owner);
        vault.withdraw(7_000e6);                    // pull all idle capital
        assertEq(usdc.balanceOf(owner), 7_000e6);
        assertEq(vault.available(), 0);
        assertEq(vault.outstanding(), 3_000e6);     // committed capital untouched
    }

    // §5.1: even paused, the owner can exit.
    function test_withdraw_worksWhilePaused() public {
        _fund(4_000e6);
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.withdraw(4_000e6);
        assertEq(usdc.balanceOf(owner), 4_000e6);
    }

    // ─────────────────────────── drawForTrade ──────────────────────────────

    function test_draw_sendsToRail_andAccounts() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(42, 3_000e6);
        assertEq(usdc.balanceOf(rail), 3_000e6);   // hardcoded recipient
        assertEq(vault.outstanding(), 3_000e6);
        (uint256 drawn, uint256 returned, PossessioFundingVault.TradeStatus status) = vault.getTrade(42);
        assertEq(drawn, 3_000e6);
        assertEq(returned, 0);
        assertEq(uint8(status), uint8(PossessioFundingVault.TradeStatus.Open));
    }

    function test_draw_multipleIntents_accumulateOutstanding() public {
        _fund(10_000e6);
        vm.startPrank(trader);
        vault.drawForTrade(1, 3_000e6);
        vault.drawForTrade(2, 2_500e6);
        vm.stopPrank();
        assertEq(vault.outstanding(), 5_500e6);
        assertEq(usdc.balanceOf(rail), 5_500e6);
    }

    // ────────────────────────── returnProceeds ─────────────────────────────

    function test_return_profit_clearsExactDraw_pnlPositive() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(7, 3_000e6);

        // rail sells, gets 3,600 back and returns it
        usdc.mint(rail, 600e6);                     // profit lands at rail
        _railApprove(3_600e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PossessioFundingVault.TradeClosed(7, 3_000e6, 3_600e6, int256(600e6));
        vm.prank(trader);
        vault.returnProceeds(7, 3_600e6);

        assertEq(vault.outstanding(), 0);                       // exposure cleared
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 3_600e6); // war chest grew
        (,, PossessioFundingVault.TradeStatus status) = vault.getTrade(7);
        assertEq(uint8(status), uint8(PossessioFundingVault.TradeStatus.Closed));
    }

    function test_return_loss_clearsExactDraw_pnlNegative() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(8, 3_000e6);

        // rail sells at a loss, returns only 2,000
        _railApprove(2_000e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PossessioFundingVault.TradeClosed(8, 3_000e6, 2_000e6, -int256(1_000e6));
        vm.prank(trader);
        vault.returnProceeds(8, 2_000e6);

        assertEq(vault.outstanding(), 0);                        // full draw cleared
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 2_000e6); // net −1k realized
    }

    function test_return_zero_totalLoss_stillClearsExposure() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(9, 3_000e6);
        vm.prank(trader);
        vault.returnProceeds(9, 0);                  // rug: nothing comes back
        assertEq(vault.outstanding(), 0);            // exposure still cleared exactly
        assertEq(usdc.balanceOf(address(vault)), 7_000e6);
    }

    // ─────────────────────────── caps: happy ───────────────────────────────

    function test_draw_atExactPerTradeCap_ok() public {
        _fund(MAX_PER_TRADE);
        vm.prank(trader);
        vault.drawForTrade(1, MAX_PER_TRADE);        // == cap, allowed
        assertEq(vault.outstanding(), MAX_PER_TRADE);
    }

    function test_drawableToday_tracksWindow() public {
        _fund(DAILY_DRAW_CAP);
        assertEq(vault.drawableToday(), DAILY_DRAW_CAP);
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);
        assertEq(vault.drawableToday(), DAILY_DRAW_CAP - 3_000e6);
        // roll the window forward → resets
        vm.warp(block.timestamp + 24 hours + 1);
        assertEq(vault.drawableToday(), DAILY_DRAW_CAP);
    }

    function test_dailyWindow_resetsAfter24h() public {
        _fund(DAILY_DRAW_CAP);
        // Exhaust the whole daily window: draw MAX_PER_TRADE, return it (rail has
        // the USDC from the draw and approves the vault to pull it back), repeat.
        // Returning frees outstanding + idle balance so only the daily cap bites.
        uint256 id = 1;
        uint256 drawnToday = 0;
        while (drawnToday + MAX_PER_TRADE <= DAILY_DRAW_CAP) {
            vm.prank(trader);
            vault.drawForTrade(id, MAX_PER_TRADE);
            _railApprove(MAX_PER_TRADE);
            vm.prank(trader);
            vault.returnProceeds(id, MAX_PER_TRADE);
            drawnToday += MAX_PER_TRADE;
            id++;
        }
        // daily window is now near-exhausted; a fresh draw would breach it
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.DailyCapExceeded.selector);
        vault.drawForTrade(id, MAX_PER_TRADE);

        // roll the window → daily counter resets, can draw again
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(trader);
        vault.drawForTrade(999, MAX_PER_TRADE);      // fresh window, ok
        assertEq(vault.outstanding(), MAX_PER_TRADE);
    }

    // ────────────────────────────── pause ──────────────────────────────────

    function test_pause_blocksDraw_notWithdraw() public {
        _fund(5_000e6);
        vm.prank(owner);
        vault.pause();
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.IsPaused.selector);
        vault.drawForTrade(1, 1_000e6);
        // withdraw still works (asserted separately) — pause is draw-only
        assertTrue(vault.paused());
    }

    function test_unpause_restoresDraw() public {
        _fund(5_000e6);
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        vm.prank(trader);
        vault.drawForTrade(1, 1_000e6);
        assertEq(vault.outstanding(), 1_000e6);
    }

    // ─────────────────────── cap adjustment: happy ─────────────────────────

    function test_decreaseCap_instant() public {
        vm.prank(owner);
        vault.decreaseCap(PossessioFundingVault.Cap.PerTrade, 1_000e6);
        assertEq(vault.maxPerTrade(), 1_000e6);
    }

    function test_raiseCap_afterDelay() public {
        vm.prank(owner);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, 5_000e6);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.executeCapIncrease(PossessioFundingVault.Cap.PerTrade);
        assertEq(vault.maxPerTrade(), 5_000e6);
    }

    function test_cancelQueuedRaise() public {
        vm.prank(owner);
        vault.queueCapIncrease(PossessioFundingVault.Cap.Outstanding, 50_000e6);
        vm.prank(owner);
        vault.cancelCapIncrease(PossessioFundingVault.Cap.Outstanding);
        // now the raise cannot be executed
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.NoIncreaseQueued.selector);
        vault.executeCapIncrease(PossessioFundingVault.Cap.Outstanding);
        assertEq(vault.maxOutstanding(), MAX_OUTSTANDING);
    }

    // ─────────────────── exact-exposure accounting invariant ───────────────

    // §5.4: outstanding == Σdrawn(open) − Σcleared, exactly.
    function test_exposureAccounting_exact_mixedTrades() public {
        _fund(10_000e6);
        vm.startPrank(trader);
        vault.drawForTrade(1, 3_000e6);
        vault.drawForTrade(2, 2_000e6);
        vault.drawForTrade(3, 1_500e6);
        vm.stopPrank();
        assertEq(vault.outstanding(), 6_500e6);

        // close #2 at a profit — clears exactly its 2,000 draw
        usdc.mint(rail, 500e6);
        _railApprove(2_500e6);
        vm.prank(trader);
        vault.returnProceeds(2, 2_500e6);
        assertEq(vault.outstanding(), 4_500e6);      // 6,500 − 2,000 (the draw)

        // close #1 at a loss — still clears exactly its 3,000 draw
        _railApprove(1_000e6);
        vm.prank(trader);
        vault.returnProceeds(1, 1_000e6);
        assertEq(vault.outstanding(), 1_500e6);      // only #3 left
    }
}
