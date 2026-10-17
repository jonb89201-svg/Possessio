// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";
import {deployPayments} from "../PaymentsDeployHelper.sol";
import {MockFeed_V3} from "./PaymentsV3Mocks.sol";

/// Behaviours carried over from the retired main suite and the Gauntlet whose
/// tests had no v3 equivalent yet (REVIEW: the coverage diff in the sandbox's
/// AUCTION_PROTOTYPE note). Each test names the old test it replaces.
contract CarryoverTest is PaymentsV3Base {
    /// Deploy_AttackerHasNoRoles, Deploy_ImmutablesSet, TreasuryGauge_ZeroAtDeployment
    function test_deploy_stateAndImmutables() public view {
        assertFalse(pay.hasRole(pay.OWNER_ROLE(), STRANGER));
        assertFalse(pay.hasRole(pay.DEFAULT_ADMIN_ROLE(), STRANGER));
        assertFalse(pay.hasRole(pay.DEFAULT_ADMIN_ROLE(), OWNER), "no admin backdoor");
        assertEq(address(pay.USDC()), address(usdc));
        assertEq(address(pay.CBETH()), address(cbeth));
        assertEq(address(pay.MORPHO_VAULT()), address(vault));
        assertEq(address(pay.CHAINLINK()), address(feedCb));
        assertEq(address(pay.CHAINLINK_USDC_USD()), address(feedUsdc));
        assertEq(address(pay.CHAINLINK_ETH_USD()), address(feedEth));
        assertEq(address(pay.LST_RATES()), address(lst));
        assertEq(pay.getTreasuryGauge(), 0, "gauge zero at deployment");
        assertEq(pay.lastKickAt(), 0);
        assertEq(pay.morphoDepositedPrincipal(), 0);
        assertFalse(pay.auctionsPaused());
        assertEq(pay.sellableUsdc(), 0);
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 0);
    }

    /// Roles_OwnerCanGrantOperator / AttackerCannotGrant, as owner rotation:
    /// OWNER_ROLE administers itself, so a Safe can hand over to a new Safe.
    function test_roles_ownerRotation() public {
        address NEW_OWNER = makeAddr("new-owner");
        bytes32 role = pay.OWNER_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.grantRole(role, STRANGER);
        vm.prank(OWNER);
        pay.grantRole(role, NEW_OWNER);
        vm.prank(NEW_OWNER);
        pay.revokeRole(role, OWNER);
        assertFalse(pay.hasRole(role, OWNER));
        _fund(10e6);
        vm.prank(OWNER);
        vm.expectRevert();
        pay.setUsdcFloat(1);
        vm.prank(NEW_OWNER);
        pay.setUsdcFloat(1);
    }

    /// Deploy_RevertsOnWrongUsdcUsdOracleDecimals (the third feed class)
    function test_deploy_wrongUsdcUsdDecimalsRefused() public {
        PossessioPayments.DeployParams memory p = _params();
        p.chainlinkUsdcUsd = address(new MockFeed_V3(1e8, 18));
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        deployPayments(p);
    }

    /// SetForwarder_RevertsZeroAddress, SetUpkeepID_OwnerOnly / StoresValue,
    /// QueueForwarderUpdate_RevertZeroAddress
    function test_automation_settingsGuards() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        pay.setForwarder(address(0));
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        pay.queueForwarderUpdate(address(0));
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.setUpkeepID(7);
        vm.prank(OWNER);
        pay.setUpkeepID(7);
        assertEq(pay.upkeepID(), 7);
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.pauseUpkeep();
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.setForwarder(STRANGER);
    }

    /// Invariant_NoDanglingApprovals, Attack_NoApprovalAfterSuccessfulSweep
    function test_kick_leavesNoDanglingApproval() public {
        _fundAndKick(1_000e6);
        assertEq(usdc.allowance(address(pay), address(vault)), 0, "vault approval reset");
    }

    /// Sweep_RevertsMorphoNoShares: a vault that takes the USDC and mints nothing
    function test_kick_vaultMintingNothingReverts() public {
        _fund(FLOAT + 1_000e6);
        vault.setMintNothing(true);
        vm.expectRevert(PossessioPayments.MorphoDepositFailed.selector);
        _kick();
        assertEq(usdc.balanceOf(address(pay)), FLOAT + 1_000e6, "nothing left the contract");
    }

    /// Attack_OracleRevertsOnRead: a reverting cbETH feed refuses the kick and
    /// the take, and canKick says so without reverting.
    function test_oracleRevertingOnRead_failsClosed() public {
        _fund(FLOAT + 1_000e6);
        feedCb.setReverts(true);
        assertFalse(pay.canKick());
        vm.expectRevert();
        _kick();
        feedCb.setReverts(false);
        _kick();
        _warpTo(810);
        feedEth.setReverts(true);
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        pay.currentRequired();
        cbeth.mint(TAKER, 1 ether);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), 1 ether);
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        pay.take();
        vm.stopPrank();
    }

    /// Attack_EmergencyCancelByAttacker, Emergency_AttackerCannotQueue,
    /// ExitLimit_EmergencyPath_CbEthBeyondCapStillWorks
    function test_emergency_attackerCannotTouchIt_andCbEthBeyondTheCapWorks() public {
        cbeth.mint(address(pay), 100 ether);            // far above the 5 cbETH daily cap
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(cbeth), 100 ether);
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.cancelEmergencyWithdraw(address(cbeth));
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.queueEmergencyWithdraw(address(cbeth), 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.executeEmergencyWithdraw(address(cbeth), PAYEE);
        vm.prank(OWNER);
        pay.executeEmergencyWithdraw(address(cbeth), PAYEE);
        assertEq(cbeth.balanceOf(PAYEE), 100 ether, "the 7-day path is the way above the cap");
    }

    /// Invariant_NoUnreachableLSTBalances, as the standing rule: every asset
    /// the contract can hold has an exit. USDC, cbETH and vault shares.
    function test_everyHeldAssetHasAnExit() public {
        _fundAndKick(2_000e6);
        _warpTo(810);
        uint256 required = _take(TAKER);
        (uint256 shares,) = pay.getMorphoBalance();
        assertGt(shares, 0); assertGt(required, 0); assertGt(usdc.balanceOf(address(pay)), 0);
        vm.startPrank(OWNER);
        pay.sendUSDC(usdc.balanceOf(address(pay)), PAYEE);
        pay.sendCbETH(required, PAYEE);
        pay.redeemMorpho(shares, PAYEE);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(pay)), 0);
        assertEq(cbeth.balanceOf(address(pay)), 0);
        (shares,) = pay.getMorphoBalance();
        assertEq(shares, 0, "nothing is stranded");
    }

    /// Attack_OperatingCapitalNotHostage: the float is never auctioned.
    function test_floatIsNeverAuctioned() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        _take(TAKER);
        assertEq(usdc.balanceOf(address(pay)), FLOAT, "the float stayed");
        vm.prank(OWNER);
        pay.sendUSDC(FLOAT, PAYEE);                     // and is the merchant's to use
        assertEq(usdc.balanceOf(PAYEE), FLOAT);
    }

    /// Sequence_MultiActionStateIntegrity: a week in the life of an Account.
    function test_sequence_aWeekOfOperations() public {
        // Day 1: payments arrive, a kick, a take at par.
        _fundAndKick(4_000e6);
        _warpTo(810);
        uint256 cb1 = _take(TAKER);
        assertEq(pay.morphoDepositedPrincipal(), 2_000e6);
        // Day 2: the merchant pays a supplier (a new payee, proposed day 1 would
        // not be active yet), and the daily limit holds.
        vm.prank(OWNER);
        pay.proposePayee(STRANGER);
        _warpFresh(vm.getBlockTimestamp() + 1 days);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.sendUSDC(100e6, STRANGER);
        vm.prank(OWNER);
        pay.sendUSDC(FLOAT, PAYEE);
        // Day 3: the payee is active; more payments; a second kick with the
        // split changed to 90% cbETH; the lot expires untaken.
        _warpFresh(vm.getBlockTimestamp() + 1 days);
        _fund(FLOAT + 1_000e6 + 1e6);                   // the week's payments arrive
        vm.prank(OWNER);
        pay.sendUSDC(1e6, STRANGER);
        vm.prank(OWNER);
        pay.setCbEthBps(9000);
        _kick();
        (uint256 lot2,,) = _lot();
        assertEq(lot2, 900e6);
        // Day 4: the expired lot is re-kicked and taken at the floor.
        _warpFresh(vm.getBlockTimestamp() + 1 days);
        _kick();
        (uint256 lot3,,) = _lot();
        assertEq(lot3, 810e6, "the untaken 900 was sold again: 90% of it");
        _warpTo(1750);
        uint256 cb3 = _take(TAKER);
        assertGe(cb3 * 100, _oracleCbEth(810e6) * 99);
        // Day 5: the merchant moves cbETH out within the cap and redeems some Morpho.
        _warpFresh(vm.getBlockTimestamp() + 1 days);
        (uint256 shares,) = pay.getMorphoBalance();
        vm.startPrank(OWNER);
        pay.sendCbETH(cb1 + cb3 > CBETH_LIMIT ? CBETH_LIMIT : cb1 + cb3, PAYEE);
        pay.redeemMorpho(shares / 2, PAYEE);
        vm.stopPrank();
        // Day 6: a pause, and nothing kicks or takes; day 8: resumed.
        vm.prank(OWNER);
        pay.pauseAuctions();
        _fund(5_000e6);
        _warpFresh(vm.getBlockTimestamp() + 1 days);
        assertFalse(pay.canKick());
        vm.prank(OWNER);
        bytes32 id = pay.queueResumeAuctions();
        _warpFresh(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        pay.resumeAuctions(id);
        assertTrue(pay.canKick());
        _kick();
        assertEq(pay.getTreasuryGauge(), pay.getTreasuryGauge(), "gauge reads");
        assertGt(pay.getTreasuryGauge(), 0);
    }

    /// View_*: the views a console reads.
    function test_views() public {
        assertEq(pay.getUSDCBalance(), 0);
        assertEq(pay.getCbETHBalance(), 0);
        _fund(FLOAT + 250e6);
        assertEq(pay.getUSDCBalance(), FLOAT + 250e6);
        assertEq(pay.sellableUsdc(), 250e6);
        assertEq(pay.nextKickAllowed(), 24 hours, "never kicked: lastKickAt 0 + delay");
        assertEq(pay.usdcDailyRemaining(), USDC_LIMIT);
        assertEq(pay.cbEthDailyRemaining(), CBETH_LIMIT);
        assertEq(pay.currentMultiplier(), 0, "no lot");
        assertFalse(pay.isEmergencyQueued(address(usdc)));
        assertFalse(pay.emergencyReady(address(usdc)));
    }
}
