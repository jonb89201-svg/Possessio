// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments, BaseWiring} from "../../src/PossessioPayments.sol";
import {deployPayments} from "../PaymentsDeployHelper.sol";
import {MockFeed_V3} from "./PaymentsV3Mocks.sol";

/// The carried-over exits, limits (C-2, P-H1, P-M4), the emergency path, the
/// settings' bounds and the constructor's guards.
contract ExitsTest is PaymentsV3Base {
    PossessioPayments.DailyLimitAsset constant AUSDC  = PossessioPayments.DailyLimitAsset.USDC;
    PossessioPayments.DailyLimitAsset constant ACBETH = PossessioPayments.DailyLimitAsset.CBETH;

    function test_sendUSDC_rulesAndLimit() public {
        _fund(FLOAT + 20_000e6);
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.sendUSDC(1e6, PAYEE);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        pay.sendUSDC(0, PAYEE);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendUSDC(USDC_LIMIT + 1, PAYEE);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT, PAYEE);
        assertEq(usdc.balanceOf(PAYEE), USDC_LIMIT);
        assertEq(pay.usdcDailyRemaining(), 0);
    }

    /// P-M4: the limit is a leaky bucket, not a window with a boundary.
    function test_limits_leakyBucketRefillsLinearly() public {
        _fund(FLOAT + 50_000e6);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT, PAYEE);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(pay.usdcDailyRemaining(), USDC_LIMIT / 2, "half back at half the window");
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendUSDC(USDC_LIMIT / 2 + 1, PAYEE);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT / 2, PAYEE);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(pay.usdcDailyRemaining(), USDC_LIMIT, "fully drained after a window");
    }

    function test_sendCbETH_limit() public {
        cbeth.mint(address(pay), 10 ether);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendCbETH(CBETH_LIMIT + 1, PAYEE);
        vm.prank(OWNER);
        pay.sendCbETH(CBETH_LIMIT, PAYEE);
        assertEq(pay.cbEthDailyRemaining(), 0);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        pay.sendCbETH(0, PAYEE);
    }

    /// C-2: a Morpho redemption is a USDC exit and shares the USDC limit.
    function test_redeemMorpho_sharesTheUsdcLimit() public {
        _fundAndKick(1_000e6);                          // 500 USDC into the vault
        (uint256 shares,) = pay.getMorphoBalance();
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        pay.redeemMorpho(0, PAYEE);
        vm.prank(OWNER);
        uint256 out = pay.redeemMorpho(shares, PAYEE);
        assertEq(out, 500e6);
        assertEq(usdc.balanceOf(PAYEE), 500e6);
        assertEq(pay.usdcDailyRemaining(), USDC_LIMIT - 500e6, "counted");
        _fund(20_000e6);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendUSDC(USDC_LIMIT - 500e6 + 1, PAYEE);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT - 500e6, PAYEE);
    }

    /// P-H1: decreases are instant; increases wait 24 h and are capped at 2x
    /// the reference.
    function test_limits_decreaseInstant_increaseDelayedAndCapped() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidLimit.selector);
        pay.decreaseAssetDailyLimit(AUSDC, USDC_LIMIT);
        vm.prank(OWNER);
        pay.decreaseAssetDailyLimit(AUSDC, 1_000e6);
        assertEq(pay.usdcDailyLimit(), 1_000e6);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidLimit.selector);
        pay.queueAssetDailyLimitIncrease(AUSDC, 1_000e6);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.IncreaseTooLarge.selector, 2 * USDC_LIMIT + 1, 2 * USDC_LIMIT));
        pay.queueAssetDailyLimitIncrease(AUSDC, 2 * USDC_LIMIT + 1);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NoIncreaseQueued.selector);
        pay.executeAssetDailyLimitIncrease(AUSDC);
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(AUSDC, 2 * USDC_LIMIT);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.executeAssetDailyLimitIncrease(AUSDC);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(AUSDC);
        assertEq(pay.usdcDailyLimit(), 2 * USDC_LIMIT);
        assertEq(pay.assetLimitRef(uint8(AUSDC)), 2 * USDC_LIMIT, "reference moved");
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(ACBETH, 2 * CBETH_LIMIT);
        vm.prank(OWNER);
        pay.cancelAssetDailyLimitIncrease(ACBETH);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NoIncreaseQueued.selector);
        pay.cancelAssetDailyLimitIncrease(ACBETH);
    }

    function test_limits_zeroIsLockdown() public {
        _fund(FLOAT + 100e6);
        vm.prank(OWNER);
        pay.decreaseAssetDailyLimit(AUSDC, 0);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendUSDC(1, PAYEE);
    }

    function test_emergency_sevenDayPathToAPayee() public {
        _fund(FLOAT + 50_000e6);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        pay.queueEmergencyWithdraw(address(0), 1);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        pay.queueEmergencyWithdraw(address(usdc), 0);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NothingQueued.selector);
        pay.executeEmergencyWithdraw(address(usdc), PAYEE);
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(usdc), 100_000e6);   // more than held
        assertTrue(pay.isEmergencyQueued(address(usdc)));
        assertFalse(pay.emergencyReady(address(usdc)));
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.executeEmergencyWithdraw(address(usdc), PAYEE);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertTrue(pay.emergencyReady(address(usdc)));
        vm.prank(OWNER);
        pay.executeEmergencyWithdraw(address(usdc), PAYEE);
        assertEq(usdc.balanceOf(PAYEE), FLOAT + 50_000e6, "the whole balance, above any daily cap");
        assertFalse(pay.isEmergencyQueued(address(usdc)));
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(cbeth), 1 ether);
        vm.prank(OWNER);
        pay.cancelEmergencyWithdraw(address(cbeth));
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NothingQueued.selector);
        pay.cancelEmergencyWithdraw(address(cbeth));
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(cbeth), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NothingToWithdraw.selector);
        pay.executeEmergencyWithdraw(address(cbeth), PAYEE);   // none held
    }

    function test_settings_boundsAndRoles() public {
        vm.startPrank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector); pay.setCbEthBps(999);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector); pay.setCbEthBps(9001);
        pay.setCbEthBps(1000); pay.setCbEthBps(9000);
        vm.expectRevert(PossessioPayments.OutOfRange.selector); pay.setAuctionLength(599);
        vm.expectRevert(PossessioPayments.OutOfRange.selector); pay.setAuctionLength(7201);
        pay.setAuctionLength(600); pay.setAuctionLength(7200);
        vm.expectRevert(PossessioPayments.OutOfRange.selector); pay.setKickDelay(3599);
        vm.expectRevert(PossessioPayments.OutOfRange.selector); pay.setKickDelay(7 days + 1);
        pay.setKickDelay(1 hours); pay.setKickDelay(7 days);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector); pay.setMinSwapBatch(0);
        pay.setMinSwapBatch(1); pay.setUsdcFloat(0); pay.setMaxKickUsdc(1);
        vm.stopPrank();
        vm.startPrank(STRANGER);
        vm.expectRevert(); pay.setCbEthBps(5000);
        vm.expectRevert(); pay.setAuctionLength(1800);
        vm.expectRevert(); pay.setKickDelay(1 days);
        vm.expectRevert(); pay.setMinSwapBatch(1);
        vm.expectRevert(); pay.setUsdcFloat(1);
        vm.expectRevert(); pay.setMaxKickUsdc(1);
        vm.expectRevert(); pay.proposePayee(STRANGER);
        vm.expectRevert(); pay.queueEmergencyWithdraw(address(usdc), 1);
        vm.stopPrank();
        assertEq(pay.FLOOR_BPS(), 9900, "the floor is a constant");
    }

    function test_ctor_guards() public {
        PossessioPayments.DeployParams memory p;
        address[8] memory zeroables;
        for (uint256 i = 0; i < 8; i++) {
            p = _params();
            if (i == 0) p.usdc = address(0);
            if (i == 1) p.cbeth = address(0);
            if (i == 2) p.morphoVault = address(0);
            if (i == 3) p.chainlink = address(0);
            if (i == 4) p.chainlinkUsdcUsd = address(0);
            if (i == 5) p.chainlinkEthUsd = address(0);
            if (i == 6) p.lstRates = address(0);
            if (i == 7) p.sequencerUptime = address(0);
            vm.expectRevert(PossessioPayments.InvalidAddress.selector);
            deployPayments(p);
        }
        zeroables;
        p = _params();
        p.chainlink = address(new MockFeed_V3(1.05e18, 8));          // wrong class
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        deployPayments(p);
        p = _params();
        p.chainlinkEthUsd = address(new MockFeed_V3(3000e8, 18));
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        deployPayments(p);
        p = _params();
        p.sequencerUptime = address(new MockFeed_V3(0, 8));            // wrong class: the uptime feed is 0-dec (G-1)
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        deployPayments(p);
        // K-3: on Base the mock wiring is refused, field by field (usdc first).
        p = _params();
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NonCanonicalWiring.selector, address(usdc), BaseWiring.USDC));
        deployPayments(p);
        vm.chainId(31337);
        PossessioPayments ok = deployPayments(p);
        assertEq(ok.usdcFloat(), FLOAT);
        assertEq(ok.auctionLength(), 30 minutes);
        assertEq(ok.kickDelay(), 24 hours);
        assertEq(ok.cbEthBps(), 5000);
        assertTrue(ok.hasRole(ok.OWNER_ROLE(), OWNER));
    }
}
