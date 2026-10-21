// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";
import {deployPayments} from "../PaymentsDeployHelper.sol";

/// Allowlisted payees (SPEC §5): every exit goes only to an active payee.
contract PayeesTest is PaymentsV3Base {
    function test_ctor_refusesNoPayees() public {
        PossessioPayments.DeployParams memory p = _params();
        p.payees = new address[](0);
        vm.expectRevert(PossessioPayments.NoPayees.selector);
        deployPayments(p);
    }

    function test_ctor_refusesAZeroPayee() public {
        PossessioPayments.DeployParams memory p = _params();
        p.payees = new address[](2);
        p.payees[0] = PAYEE;
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        deployPayments(p);
    }

    function test_ctor_initialPayeesAreActiveAtOnce() public view {
        assertTrue(pay.isPayee(PAYEE));
        assertEq(pay.payeeActiveAt(PAYEE), vm.getBlockTimestamp());
        assertFalse(pay.isPayee(STRANGER));
    }

    function test_propose_isTheOwnersAndActivatesAfter48h() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.proposePayee(STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        pay.proposePayee(address(0));
        vm.prank(OWNER);
        vm.expectEmit(address(pay));
        emit PossessioPayments.PayeeProposed(STRANGER, vm.getBlockTimestamp() + 48 hours);
        pay.proposePayee(STRANGER);
        assertFalse(pay.isPayee(STRANGER), "pending");
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        assertFalse(pay.isPayee(STRANGER), "still pending");
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(pay.isPayee(STRANGER), "active");
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.AlreadyPayee.selector);
        pay.proposePayee(STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.AlreadyPayee.selector);
        pay.proposePayee(PAYEE);
    }

    function test_remove_isInstantAndCancelsAPendingProposal() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.removePayee(STRANGER);
        vm.prank(OWNER);
        pay.proposePayee(STRANGER);
        vm.prank(OWNER);
        vm.expectEmit(address(pay));
        emit PossessioPayments.PayeeRemoved(STRANGER);
        pay.removePayee(STRANGER);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertFalse(pay.isPayee(STRANGER), "the cancelled proposal never activates");
        vm.prank(OWNER);
        pay.removePayee(PAYEE);
        assertFalse(pay.isPayee(PAYEE));
        _fund(10e6);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, PAYEE));
        pay.sendUSDC(1e6, PAYEE);
    }

    function test_exits_goOnlyToActivePayees() public {
        _fundAndKick(1_000e6);                          // Morpho shares + a lot
        _warpTo(810);
        uint256 required = _take(TAKER);                // cbETH in the contract
        // sendUSDC
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.sendUSDC(1e6, STRANGER);
        vm.prank(OWNER);
        pay.sendUSDC(1e6, PAYEE);
        // sendCbETH
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.sendCbETH(required, STRANGER);
        vm.prank(OWNER);
        pay.sendCbETH(required, PAYEE);
        assertEq(cbeth.balanceOf(PAYEE), required);
        // redeemMorpho
        (uint256 shares,) = pay.getMorphoBalance();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.redeemMorpho(shares, STRANGER);
        vm.prank(OWNER);
        pay.redeemMorpho(shares, PAYEE);
        // emergency: a pending payee is not a payee yet
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(usdc), 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(OWNER);
        pay.proposePayee(STRANGER);                     // pending for 48 h
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, STRANGER));
        pay.executeEmergencyWithdraw(address(usdc), STRANGER);
        vm.prank(OWNER);
        pay.executeEmergencyWithdraw(address(usdc), PAYEE);
    }

    /// The stolen-key story: the thief holds the owner key and 48 hours.
    function test_stolenKey_cannotRedirectWithin48hAndTheMerchantCanCancel() public {
        address THIEF_PAYEE = makeAddr("thief-payee");
        _fund(FLOAT + 5_000e6);
        vm.prank(OWNER);                                // the thief, with the owner key
        pay.proposePayee(THIEF_PAYEE);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, THIEF_PAYEE));
        pay.sendUSDC(5_000e6, THIEF_PAYEE);
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(usdc), 6_000e6);
        vm.warp(vm.getBlockTimestamp() + 24 hours);            // the merchant sees the event and acts
        vm.prank(OWNER);
        pay.removePayee(THIEF_PAYEE);
        vm.prank(OWNER);
        pay.sendUSDC(5_000e6, PAYEE);                   // to their own payee, within the limit
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, THIEF_PAYEE));
        pay.executeEmergencyWithdraw(address(usdc), THIEF_PAYEE);
        assertEq(usdc.balanceOf(THIEF_PAYEE), 0, "the thief got nothing");
    }
}
