// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  v3.0.3: the owner role moves only through a cancellable 48 h queue, and the last
    owner can never be removed. The last test is the regression for the council's
    finding of 2026-10-21: a holder of the owner key could hand the role over in one
    block and lock the merchant out; a probe measured it on v3.0.2 before this fix. */

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";

contract OwnerRoleTimelockTest is PaymentsV3Base {
    function _role() internal view returns (bytes32) { return pay.OWNER_ROLE(); }
    function _delay() internal view returns (uint256) { return pay.TIMELOCK() + 1; }

    /// The direct AccessControl paths are closed for OWNER_ROLE, even to an owner.
    function test_directRolePaths_revertForOwnerRole() public {
        address who = makeAddr("who");
        bytes32 role = _role();   // hoisted: a view call in the argument position eats the cheatcode
        vm.startPrank(OWNER);
        vm.expectRevert(PossessioPayments.OwnerRoleIsTimelocked.selector);
        pay.grantRole(role, who);
        vm.expectRevert(PossessioPayments.OwnerRoleIsTimelocked.selector);
        pay.revokeRole(role, OWNER);
        vm.expectRevert(PossessioPayments.OwnerRoleIsTimelocked.selector);
        pay.renounceRole(role, OWNER);
        vm.stopPrank();
        assertTrue(pay.hasRole(_role(), OWNER));
        assertEq(pay.ownerCount(), 1);
    }

    /// A stranger can queue nothing.
    function test_queues_areOwnerOnly() public {
        vm.startPrank(STRANGER);
        vm.expectRevert();
        pay.queueOwnerGrant(STRANGER);
        vm.expectRevert();
        pay.queueOwnerRevoke(OWNER);
        vm.expectRevert();
        pay.cancelOwnerGrant(STRANGER);
        vm.stopPrank();
    }

    /// Grant: queued, not executable early, cancellable, executable after the delay, once.
    function test_ownerGrant_queuedCancellableThenExecutable() public {
        address who = makeAddr("new-owner");
        vm.prank(OWNER);
        bytes32 id = pay.queueOwnerGrant(who);
        assertEq(pay.pendingOwnerGrant(who), id);

        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.AlreadyQueued.selector);
        pay.queueOwnerGrant(who);

        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.executeOwnerGrant(who, id);

        vm.prank(OWNER);
        pay.cancelOwnerGrant(who);
        assertEq(pay.pendingOwnerGrant(who), bytes32(0));
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeOwnerGrant(who, id);                      // cancelled: gone for good
        assertFalse(pay.hasRole(_role(), who));

        vm.prank(OWNER);
        bytes32 id2 = pay.queueOwnerGrant(who);
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        pay.executeOwnerGrant(who, id2);
        assertTrue(pay.hasRole(_role(), who));
        assertEq(pay.ownerCount(), 2);

        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeOwnerGrant(who, id2);                     // not twice
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.AlreadyOwner.selector);
        pay.queueOwnerGrant(who);
    }

    /// Revoke: refused for the last owner, at the queue and again at execution.
    function test_ownerRevoke_lastOwnerIsNeverRemoved() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.LastOwner.selector);
        pay.queueOwnerRevoke(OWNER);

        // Two owners: queue a revoke of each while both hold the role, execute one,
        // and the other must fail the re-check at execution.
        address second = _addOwner("second");
        vm.prank(OWNER);
        bytes32 rA = pay.queueOwnerRevoke(OWNER);
        vm.prank(second);
        bytes32 rB = pay.queueOwnerRevoke(second);
        vm.warp(block.timestamp + _delay());
        vm.prank(second);
        pay.executeOwnerRevoke(OWNER, rA);
        assertFalse(pay.hasRole(_role(), OWNER));
        assertEq(pay.ownerCount(), 1);
        vm.prank(second);
        vm.expectRevert(PossessioPayments.LastOwner.selector);
        pay.executeOwnerRevoke(second, rB);
        assertTrue(pay.hasRole(_role(), second));
    }

    /// Revoke: any current owner can cancel a queued revoke, including its target.
    function test_ownerRevoke_cancellableByAnyOwner() public {
        address second = _addOwner("second");
        vm.prank(second);
        bytes32 r = pay.queueOwnerRevoke(OWNER);
        vm.prank(OWNER);                                     // the target cancels
        pay.cancelOwnerRevoke(OWNER);
        vm.warp(block.timestamp + _delay());
        vm.prank(second);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeOwnerRevoke(OWNER, r);
        assertTrue(pay.hasRole(_role(), OWNER));
        assertEq(pay.ownerCount(), 2);
    }

    /// REGRESSION (council finding, 2026-10-21): with the merchant's key, a thief can
    /// no longer lock the merchant out or seat a payee unseen. Both parties act
    /// through the same key (OWNER); the merchant's cancels close every window.
    function test_stolenOwnerKey_cannotLockOutTheMerchant() public {
        address thief2 = makeAddr("thief-second-address");
        address drain  = makeAddr("drain");

        // Thief: hand the role over. Queued, not immediate; the merchant cancels.
        vm.prank(OWNER);
        bytes32 g = pay.queueOwnerGrant(thief2);
        vm.prank(OWNER);
        pay.cancelOwnerGrant(thief2);
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeOwnerGrant(thief2, g);
        assertFalse(pay.hasRole(_role(), thief2));

        // Thief: revoke the merchant. The merchant is the only owner: refused.
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.LastOwner.selector);
        pay.queueOwnerRevoke(OWNER);
        bytes32 role = _role();   // hoisted, as above
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.OwnerRoleIsTimelocked.selector);
        pay.revokeRole(role, OWNER);

        // Thief: seat a payee. The merchant removes it inside the 48 h; nothing leaves.
        vm.prank(OWNER);
        pay.proposePayee(drain);
        vm.prank(OWNER);
        pay.removePayee(drain);
        _fund(10e6);
        vm.warp(block.timestamp + pay.PAYEE_DELAY() + 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, drain));
        pay.sendUSDC(1e6, drain);

        assertTrue(pay.hasRole(role, OWNER), "the merchant still holds the role");
        assertEq(pay.ownerCount(), 1);
    }

    function _addOwner(string memory label) internal returns (address who) {
        who = makeAddr(label);
        vm.prank(OWNER);
        bytes32 id = pay.queueOwnerGrant(who);
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        pay.executeOwnerGrant(who, id);
        assertTrue(pay.hasRole(_role(), who));
    }
}
