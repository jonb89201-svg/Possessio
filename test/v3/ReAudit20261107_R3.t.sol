// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  Re-audit 2026-11-07, R-3 (Low): an executed limit increase settles the bucket
    at the old rate before the new limit applies. Before the fix, _drained used
    the new limit for the time since the last spend, freeing up to
    (new - old) x elapsed / 24 h that the bucket never earned. The first two
    tests fail on 73fa334.
*/

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";

contract ReAudit20261107_R3 is PaymentsV3Base {
    PossessioPayments.DailyLimitAsset constant AUSDC  = PossessioPayments.DailyLimitAsset.USDC;
    PossessioPayments.DailyLimitAsset constant ACBETH = PossessioPayments.DailyLimitAsset.CBETH;

    /// Spend 10k, raise to 20k 12 h later: 5k is still in the bucket, 15k free.
    function test_R3_usdcIncrease_settlesThePastAtTheOldRate() public {
        _fund(40_000e6);
        uint256 t0 = vm.getBlockTimestamp();   // not block.timestamp: via-ir re-reads it after a warp
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(AUSDC, 2 * USDC_LIMIT);
        vm.warp(t0 + 12 hours);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT, PAYEE);
        vm.warp(t0 + 24 hours);
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(AUSDC);

        assertEq(pay.usdcDailyRemaining(), 15_000e6, "20k limit less the 5k not yet drained");
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.sendUSDC(2 * USDC_LIMIT, PAYEE);
        vm.prank(OWNER);
        pay.sendUSDC(15_000e6, PAYEE);
        assertEq(usdc.balanceOf(PAYEE), 25_000e6, "25k out in 12 h, as the bucket allows");
    }

    function test_R3_cbEthIncrease_settlesThePastAtTheOldRate() public {
        cbeth.mint(address(pay), 20 ether);
        uint256 t0 = vm.getBlockTimestamp();   // not block.timestamp: via-ir re-reads it after a warp
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(ACBETH, 2 * CBETH_LIMIT);
        vm.warp(t0 + 12 hours);
        vm.prank(OWNER);
        pay.sendCbETH(CBETH_LIMIT, PAYEE);
        vm.warp(t0 + 24 hours);
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(ACBETH);
        assertEq(pay.cbEthDailyRemaining(), 2 * CBETH_LIMIT - CBETH_LIMIT / 2);
    }

    /// After the raise, the bucket drains at the new rate from the moment it applies.
    function test_R3_afterTheIncrease_theNewRateApplies() public {
        _fund(40_000e6);
        uint256 t0 = vm.getBlockTimestamp();   // not block.timestamp: via-ir re-reads it after a warp
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(AUSDC, 2 * USDC_LIMIT);
        vm.warp(t0 + 12 hours);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT, PAYEE);
        vm.warp(t0 + 24 hours);
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(AUSDC);
        vm.warp(t0 + 24 hours + 6 hours);                       // 6 h at 20k/day drains 5k
        assertEq(pay.usdcDailyRemaining(), 2 * USDC_LIMIT);
    }

    /// No spend before the raise: nothing to settle, the full new limit is free.
    function test_R3_increaseWithNoSpend_freesTheFullNewLimit() public {
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(AUSDC, 2 * USDC_LIMIT);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(AUSDC);
        assertEq(pay.usdcDailyRemaining(), 2 * USDC_LIMIT);
    }
}
