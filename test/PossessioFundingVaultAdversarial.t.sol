// SPDX-License-Identifier: MIT
// Adversarial gauntlet for PossessioFundingVault (SPEC_FundingVault.md §9).
// Every cap breach refused; every role boundary held; reentrancy blocked;
// no arbitrary-recipient path; no double-clear; the asymmetric timelock enforced.
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Malicious ERC20 that re-enters the vault on transfer, to prove the
///      nonReentrant + CEI discipline (§5.6). Used as the payToken.
contract ReentrantUSDC is ERC20 {
    PossessioFundingVault public vault;
    bool public armed;
    uint8 public mode; // 1 = reenter drawForTrade, 2 = reenter withdraw
    uint256 public reenterId;

    constructor() ERC20("Re USDC", "rUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function arm(PossessioFundingVault v, uint8 m, uint256 id) external {
        vault = v; armed = true; mode = m; reenterId = id;
    }
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && address(vault) != address(0)) {
            armed = false; // one-shot to avoid infinite loop before the guard trips
            if (mode == 1)      vault.drawForTrade(reenterId, 1);
            else if (mode == 2) vault.withdraw(1);
        }
    }
}

abstract contract Fixture is Test {
    MockUSDC internal usdc;
    PossessioFundingVault internal vault;

    address internal owner    = makeAddr("owner");
    address internal trader   = makeAddr("trader");
    address internal rail     = makeAddr("tradeDestination");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant MAX_PER_TRADE   = 3_500e6;
    uint256 internal constant MAX_OUTSTANDING = 10_000e6;
    uint256 internal constant DAILY_DRAW_CAP  = 20_000e6;

    function _deploy() internal {
        usdc = new MockUSDC();
        vault = new PossessioFundingVault(
            IERC20(address(usdc)), owner, trader, rail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
    }

    function _fund(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    function _railApprove(uint256 amount) internal {
        vm.prank(rail);
        usdc.approve(address(vault), amount);
    }
}

contract PossessioFundingVaultAdversarialTest is Fixture {
    function setUp() public { _deploy(); }

    // ───────────────────────── role boundaries ─────────────────────────────

    function test_nonOwner_cannotWithdraw() public {
        _fund(5_000e6);
        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotOwner.selector);
        vault.withdraw(1_000e6);
    }

    function test_trader_cannotWithdraw() public {
        _fund(5_000e6);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.NotOwner.selector);
        vault.withdraw(1_000e6);
    }

    function test_nonTrader_cannotDraw() public {
        _fund(5_000e6);
        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotTrader.selector);
        vault.drawForTrade(1, 1_000e6);
    }

    function test_owner_cannotDraw() public {
        _fund(5_000e6);
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.NotTrader.selector);
        vault.drawForTrade(1, 1_000e6);
    }

    function test_nonTrader_cannotReturn() public {
        _fund(5_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 1_000e6);
        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotTrader.selector);
        vault.returnProceeds(1, 1_000e6);
    }

    function test_nonOwner_cannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotOwner.selector);
        vault.pause();
    }

    function test_nonOwner_cannotAdjustCaps() public {
        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotOwner.selector);
        vault.decreaseCap(PossessioFundingVault.Cap.PerTrade, 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(PossessioFundingVault.NotOwner.selector);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, 9_000e6);
    }

    // ───────────────────────── cap breaches ────────────────────────────────

    function test_perTradeCap_breachRefused() public {
        _fund(MAX_OUTSTANDING);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.PerTradeCapExceeded.selector);
        vault.drawForTrade(1, MAX_PER_TRADE + 1);
    }

    function test_outstandingCap_breachRefused() public {
        _fund(50_000e6); // plenty of balance + daily headroom; only outstanding bites
        // Raise per-trade so outstanding is the binding cap. Fill to the cap.
        vm.prank(owner);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, MAX_OUTSTANDING);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.executeCapIncrease(PossessioFundingVault.Cap.PerTrade);

        vm.prank(trader);
        vault.drawForTrade(1, MAX_OUTSTANDING);       // outstanding == cap exactly
        assertEq(vault.outstanding(), MAX_OUTSTANDING);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.OutstandingCapExceeded.selector);
        vault.drawForTrade(2, 1);                      // +1 over the concurrency cap
    }

    function test_dailyCap_breachRefused() public {
        _fund(DAILY_DRAW_CAP * 2);
        // Raise per-trade + outstanding so ONLY the daily cap can bite; draw,
        // return (frees outstanding + balance), repeat until the window fills.
        vm.startPrank(owner);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, DAILY_DRAW_CAP);
        vault.queueCapIncrease(PossessioFundingVault.Cap.Outstanding, DAILY_DRAW_CAP * 2);
        vm.stopPrank();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.startPrank(owner);
        vault.executeCapIncrease(PossessioFundingVault.Cap.PerTrade);
        vault.executeCapIncrease(PossessioFundingVault.Cap.Outstanding);
        vm.stopPrank();

        vm.prank(trader);
        vault.drawForTrade(1, DAILY_DRAW_CAP);        // consume the whole window
        _railApprove(DAILY_DRAW_CAP);
        vm.prank(trader);
        vault.returnProceeds(1, DAILY_DRAW_CAP);      // outstanding + balance freed

        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.DailyCapExceeded.selector);
        vault.drawForTrade(2, 1);                      // window exhausted → refused
    }

    function test_draw_cannotExceedIdleBalance() public {
        _fund(1_000e6);                                // only 1k in the vault
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.InsufficientAvailable.selector);
        vault.drawForTrade(1, 2_000e6);                // under caps, but no USDC
    }

    // ────────────────── owner-can-exit vs committed capital ────────────────

    function test_withdraw_cannotExceedIdle() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);                // 3k out at rail, 7k idle
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.ExceedsAvailable.selector);
        vault.withdraw(7_000e6 + 1);                   // can't pull at-rail capital
    }

    // ─────────────────────── asymmetric timelock ───────────────────────────

    function test_capRaise_notInstant() public {
        // Cannot raise via decreaseCap (must be lower)
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.InvalidCap.selector);
        vault.decreaseCap(PossessioFundingVault.Cap.PerTrade, MAX_PER_TRADE + 1);
    }

    function test_capRaise_beforeDelayRefused() public {
        vm.prank(owner);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, 9_000e6);
        // one second early
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.TimelockNotPassed.selector);
        vault.executeCapIncrease(PossessioFundingVault.Cap.PerTrade);
    }

    function test_capDecrease_mustBeLower() public {
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.InvalidCap.selector);
        vault.decreaseCap(PossessioFundingVault.Cap.PerTrade, MAX_PER_TRADE);
    }

    function test_capQueue_mustBeHigher() public {
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.InvalidCap.selector);
        vault.queueCapIncrease(PossessioFundingVault.Cap.PerTrade, MAX_PER_TRADE);
    }

    function test_executeWithoutQueue_refused() public {
        vm.prank(owner);
        vm.expectRevert(PossessioFundingVault.NoIncreaseQueued.selector);
        vault.executeCapIncrease(PossessioFundingVault.Cap.DailyDraw);
    }

    // compromised-key drill: lower instantly still works, raise still delayed
    function test_lowerCap_tightens_immediately_blocksDraw() public {
        _fund(10_000e6);
        vm.prank(owner);
        vault.decreaseCap(PossessioFundingVault.Cap.PerTrade, 500e6);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.PerTradeCapExceeded.selector);
        vault.drawForTrade(1, 600e6);                  // instantly tighter
    }

    // ─────────────────────── trade-lifecycle abuse ─────────────────────────

    function test_doubleReturn_refused() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);
        _railApprove(3_000e6);
        vm.prank(trader);
        vault.returnProceeds(1, 3_000e6);
        // second return on the same (now CLOSED) intent
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.TradeNotOpen.selector);
        vault.returnProceeds(1, 1);
    }

    function test_returnUnknownIntent_refused() public {
        _fund(10_000e6);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.TradeNotOpen.selector);
        vault.returnProceeds(777, 100e6);              // never drawn
    }

    function test_reuseIntentId_refused() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 1_000e6);
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.TradeAlreadyOpen.selector);
        vault.drawForTrade(1, 500e6);                  // id already OPEN
    }

    function test_reuseClosedIntentId_refused() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 1_000e6);
        _railApprove(1_000e6);
        vm.prank(trader);
        vault.returnProceeds(1, 1_000e6);
        // id is CLOSED — permanently consumed, cannot be re-drawn
        vm.prank(trader);
        vm.expectRevert(PossessioFundingVault.TradeAlreadyOpen.selector);
        vault.drawForTrade(1, 1_000e6);
    }

    // ─────────────────────────── reentrancy ────────────────────────────────

    function test_reentrancy_onDraw_blocked() public {
        // Deploy a vault whose payToken re-enters drawForTrade on transfer.
        ReentrantUSDC evil = new ReentrantUSDC();
        PossessioFundingVault v = new PossessioFundingVault(
            IERC20(address(evil)), owner, trader, rail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
        evil.mint(owner, 10_000e6);
        vm.startPrank(owner);
        evil.approve(address(v), 10_000e6);
        v.fund(10_000e6);
        vm.stopPrank();

        evil.arm(v, 1, 2);                             // re-enter drawForTrade(2,1)
        vm.prank(trader);
        vm.expectRevert();                             // ReentrancyGuardReentrantCall
        v.drawForTrade(1, 1_000e6);
    }

    function test_reentrancy_onWithdraw_blocked() public {
        ReentrantUSDC evil = new ReentrantUSDC();
        PossessioFundingVault v = new PossessioFundingVault(
            IERC20(address(evil)), owner, trader, rail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
        evil.mint(owner, 10_000e6);
        vm.startPrank(owner);
        evil.approve(address(v), 10_000e6);
        v.fund(10_000e6);
        vm.stopPrank();

        evil.arm(v, 2, 0);                             // re-enter withdraw(1)
        vm.prank(owner);
        vm.expectRevert();
        v.withdraw(1_000e6);
    }

    // ───────────────────── no arbitrary-recipient path ─────────────────────

    // There is no function that lets any caller name a recipient. This test
    // documents that invariant structurally: draws land ONLY at tradeDestination
    // and withdraws ONLY at owner, regardless of who calls or what they pass.
    function test_recipients_areHardcoded() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);
        assertEq(usdc.balanceOf(rail), 3_000e6);       // draw → rail, always
        assertEq(usdc.balanceOf(trader), 0);           // never the caller
        assertEq(usdc.balanceOf(attacker), 0);

        vm.prank(owner);
        vault.withdraw(1_000e6);
        assertEq(usdc.balanceOf(owner), 1_000e6);      // withdraw → owner, always
    }

    // ──────────────────── drain-attempt via cap edges ──────────────────────

    // Even with the daily cap fully available, per-trade + outstanding + idle
    // balance jointly bound a single-block drain. Attacker (as trader, worst
    // case a compromised keeper) cannot pull more than maxOutstanding concurrently
    // nor more than the vault physically holds.
    function test_compromisedTrader_boundedByCaps() public {
        _fund(100_000e6);                              // huge balance
        // trader is compromised; tries to drain in one window. 2 draws fit
        // (7,000 ≤ 10,000); the 3rd (10,500) breaches the outstanding cap.
        vm.startPrank(trader);
        vault.drawForTrade(1, MAX_PER_TRADE);
        vault.drawForTrade(2, MAX_PER_TRADE);
        vm.expectRevert(PossessioFundingVault.OutstandingCapExceeded.selector);
        vault.drawForTrade(3, MAX_PER_TRADE);          // 10,500 > cap → refused
        vm.stopPrank();
        // outstanding + at-rail exposure both capped regardless of balance
        assertLe(vault.outstanding(), MAX_OUTSTANDING);
        assertLe(usdc.balanceOf(rail), MAX_OUTSTANDING);
    }
}
