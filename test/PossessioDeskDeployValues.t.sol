// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   THE DESK — DEPLOYMENT CONFIGURATION, UNDER TEST

   Fifth in the series with Pool / x402Core / Account / Factory.

   The desk is the one place where the sweep found NO divergence: all
   six existing suites (FundingVault x3, Rail x3) and TradingDeskCreate3
   run the identical 3,500 / 10,000 / 20,000, and STOP_BPS = 1000 is a
   hardcoded constant, so the stop is inherently exercised at its
   shipping value everywhere. That is worth stating plainly rather than
   manufacturing a finding.

   But the desk differs from every other contract in the system in a way
   that changes what "the deployment configuration" even means: the caps
   are chosen by the USER at their own launch. There is no single
   shipping triple to pin. 3,500 / 10,000 / 20,000 is one customer's
   configuration, not the protocol's.

   So the test that matters here is not "does it work at those three
   numbers" — six suites already prove that — but "do the invariants
   hold across the whole range a customer might choose". That is what
   this suite adds, by fuzzing the caps themselves.

   PER_TX_FEE was the one divergence this sweep found: $0.02 in all three
   AutoTarget suites and $1 in TradingDeskCreate3. It was never a conflict
   — it was SPEC_AutoTarget §7 open decision #2 still open, with the $1 a
   placeholder in a test that only cares about addresses. RATIFIED
   2026-07-28 at $0.02, the bottom of the spec's own suggested range and
   the tape-toll price. The placeholder is corrected and $0.02 is now
   pinned as the shipping value here.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {MockUSDC} from "./PossessioFundingVault.t.sol";

contract MockInfraPoolDesk {
    function isInfraSink() external pure returns (bool) { return true; }
    function isAuthorizedSource(address) external pure returns (bool) { return true; }
}

contract PossessioDeskDeployValuesTest is Test {
    // ── the desk's own consistent configuration ──────────────────────────
    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;

    // ── AT_PER_TX_FEE — ratified 2026-07-28 (§22) ────────────────────────
    uint256 constant PER_TX_FEE_SHIPPING = 20_000;  // $0.02, flat, per intent

    uint16  constant STOP_BPS_EXPECTED = 1000;   // -10%, hardcoded constant

    MockUSDC usdc;
    PossessioFundingVault vault;
    address owner  = makeAddr("ownerPasskey");
    address trader = makeAddr("desk");
    address rail   = makeAddr("rail");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new PossessioFundingVault(
            IERC20(address(usdc)), owner, trader, rail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
    }

    function _fund(PossessioFundingVault v, uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(v), amount);
        v.fund(amount);
        vm.stopPrank();
    }

    // ── K1. The stop is a constant and cannot be widened by anyone ───────
    //      The one economic value in the desk that is NOT the user's to
    //      choose. It is hardcoded, so it is tested at its shipping value
    //      by construction — asserted here so a future change to a
    //      constructor parameter breaks a test.
    function test_K1_stopIsAHardcodedConstant() public {
        PossessioAutoTarget at =
            new PossessioAutoTarget(address(usdc), makeAddr("tollSink"), makeAddr("keeper"), PER_TX_FEE_SHIPPING);
        assertEq(at.STOP_BPS(), STOP_BPS_EXPECTED, "the -10% stop must be 1000 bps, always");
    }

    // ── K2. The ratified per-tx fee is $0.02, and it is immutable ────────
    //      §22 AT_PER_TX_FEE=20000, closing SPEC_AutoTarget §7 decision #2.
    //      Pinned so the deploy env, the desk-assembly test and AutoTarget's
    //      own suites can never drift apart again -- which is exactly how a
    //      $1 placeholder survived in the tree unnoticed.
    function test_K2_ratifiedPerTxFeeIsTwoCents() public {
        MockInfraPoolDesk pool = new MockInfraPoolDesk();
        address keeper = makeAddr("keeper");

        PossessioAutoTarget at =
            new PossessioAutoTarget(address(usdc), makeAddr("tollSink"), keeper, PER_TX_FEE_SHIPPING);

        assertEq(at.PER_TX_FEE(), PER_TX_FEE_SHIPPING, "shipping fee must be $0.02");
        assertEq(at.STOP_BPS(), STOP_BPS_EXPECTED, "the stop never varies with the fee");

        // no setter may reprice a live desk -- the fee is the user's terms
        (bool ok, ) = address(at).call(abi.encodeWithSignature("setPerTxFee(uint256)", uint256(1e6)));
        assertFalse(ok, "no setPerTxFee may exist");
        assertEq(at.PER_TX_FEE(), PER_TX_FEE_SHIPPING, "fee immutable for the desk's life");
    }

    // ── K3. The caps land exactly as constructed ─────────────────────────
    function test_K3_capsLandAsConstructed() public view {
        assertEq(vault.maxPerTrade(),    MAX_PER_TRADE,   "maxPerTrade");
        assertEq(vault.maxOutstanding(), MAX_OUTSTANDING, "maxOutstanding");
        assertEq(vault.dailyDrawCap(),   DAILY_DRAW_CAP,  "dailyDrawCap");
        assertEq(vault.owner(),          owner,           "owner immutable");
        assertEq(vault.trader(),         trader,          "trader immutable");
        assertEq(vault.tradeDestination(), rail,          "rail immutable");
    }

    // ── K4. FUZZED CAPS: per-trade bound holds for ANY customer choice ───
    //      This is the point of the suite. The caps are user-chosen, so
    //      proving them at one triple proves one customer's launch. The
    //      invariant must hold across the range.
    function testFuzz_K4_perTradeBoundHoldsAtAnyCap(
        uint256 perTrade, uint256 outstanding, uint256 daily
    ) public {
        perTrade    = bound(perTrade,    1e6,      1_000_000e6);
        outstanding = bound(outstanding, perTrade, 5_000_000e6);
        daily       = bound(daily,       perTrade, 10_000_000e6);

        PossessioFundingVault v = new PossessioFundingVault(
            IERC20(address(usdc)), owner, trader, rail, perTrade, outstanding, daily
        );
        _fund(v, outstanding);

        // one unit over the customer's own per-trade cap must always fail
        vm.prank(trader);
        vm.expectRevert();
        v.drawForTrade(1, perTrade + 1);

        // exactly at the cap must always succeed
        vm.prank(trader);
        v.drawForTrade(2, perTrade);
        assertEq(v.outstanding(), perTrade, "draw at the cap lands");
    }

    // ── K5. FUZZED CAPS: concurrent bound holds for ANY customer choice ──
    function testFuzz_K5_outstandingBoundHoldsAtAnyCap(uint256 perTrade, uint256 outstanding)
        public
    {
        perTrade    = bound(perTrade,    1e6, 100_000e6);
        outstanding = bound(outstanding, perTrade, perTrade * 4);

        PossessioFundingVault v = new PossessioFundingVault(
            IERC20(address(usdc)), owner, trader, rail,
            perTrade, outstanding, type(uint128).max   // daily cap out of the way
        );
        _fund(v, outstanding * 4);

        // draw at the per-trade cap until the concurrent cap is the binding limit
        uint256 drawn;
        uint256 id;
        while (drawn + perTrade <= outstanding) {
            vm.prank(trader);
            v.drawForTrade(++id, perTrade);
            drawn += perTrade;
        }
        assertEq(v.outstanding(), drawn, "accounting tracks every draw");
        assertLe(v.outstanding(), outstanding, "outstanding NEVER exceeds the customer's cap");

        // the next full-size draw must break the concurrent bound
        if (drawn + perTrade > outstanding) {
            vm.prank(trader);
            vm.expectRevert();
            v.drawForTrade(++id, perTrade);
        }
    }

    // ── K6. FUZZED CAPS: the owner can never be locked out of their own ──
    //      funds by the desk. withdraw must always leave outstanding whole
    //      and must always return the free balance, at any configuration.
    function testFuzz_K6_ownerAlwaysRecoversFreeBalance(uint256 perTrade, uint256 funded)
        public
    {
        perTrade = bound(perTrade, 1e6, 100_000e6);
        funded   = bound(funded,   perTrade * 2, perTrade * 10);

        PossessioFundingVault v = new PossessioFundingVault(
            IERC20(address(usdc)), owner, trader, rail,
            perTrade, perTrade * 2, type(uint128).max
        );
        _fund(v, funded);

        vm.prank(trader);
        v.drawForTrade(1, perTrade);                    // some capital is out

        uint256 free = usdc.balanceOf(address(v));
        uint256 before_ = usdc.balanceOf(owner);

        vm.prank(owner);
        v.withdraw(free);                               // everything not in flight

        assertEq(usdc.balanceOf(owner) - before_, free, "owner recovers the whole free balance");
        assertEq(v.outstanding(), perTrade, "capital in flight is untouched by a withdraw");
    }

    // ── K7. The desk's roles are immutable — no setter can redirect it ───
    //      trader and tradeDestination are the desk's authority surface.
    //      If either could be changed, the caps would be decoration.
    function test_K7_noSetterCanRedirectTheDesk() public {
        (bool ok, ) = address(vault).call(abi.encodeWithSignature("setTrader(address)", address(1)));
        assertFalse(ok, "no setTrader may exist");
        (ok, ) = address(vault).call(abi.encodeWithSignature("setTradeDestination(address)", address(1)));
        assertFalse(ok, "no setTradeDestination may exist");
        (ok, ) = address(vault).call(abi.encodeWithSignature("setOwner(address)", address(1)));
        assertFalse(ok, "no setOwner may exist");

        assertEq(vault.trader(), trader, "trader unchanged");
        assertEq(vault.tradeDestination(), rail, "rail unchanged");
    }
}
