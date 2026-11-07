// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  Re-audit 2026-11-07, R-2 (Low): each timelocked action accepts only its own id.
    Before the fix, tlPassed checked only that an id had matured, so resumeAuctions
    took an owner-grant id (and stranded that grant), and executeForwarderUpdate
    took any matured id, skipping its 48 h. Each test below fails on 73fa334.
*/

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";

contract ReAudit20261107_R2 is PaymentsV3Base {
    address CO_OWNER = makeAddr("co-owner");

    function _delay() internal view returns (uint256) { return pay.TIMELOCK() + 1; }

    function test_R2_resumeAuctions_refusesAnOwnerGrantId_andTheGrantSurvives() public {
        vm.prank(OWNER);
        bytes32 grantId = pay.queueOwnerGrant(CO_OWNER);
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        pay.pauseAuctions();

        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.resumeAuctions(grantId);
        assertTrue(pay.auctionsPaused(), "still paused");

        vm.prank(OWNER);
        pay.executeOwnerGrant(CO_OWNER, grantId);       // the grant is not stranded
        assertTrue(pay.hasRole(pay.OWNER_ROLE(), CO_OWNER));
    }

    function test_R2_resumeAuctions_aNewQueueReplacesTheOldId() public {
        vm.startPrank(OWNER);
        pay.pauseAuctions();
        bytes32 first = pay.queueResumeAuctions();
        vm.warp(block.timestamp + 1 hours);
        bytes32 second = pay.queueResumeAuctions();
        vm.warp(block.timestamp + _delay());
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.resumeAuctions(first);
        pay.resumeAuctions(second);
        vm.stopPrank();
        assertFalse(pay.auctionsPaused());
        assertEq(pay.pendingResumeId(), bytes32(0));
    }

    function test_R2_forwarderUpdate_refusesAForeignMaturedId() public {
        address first = makeAddr("forwarder-1");
        address evil  = makeAddr("forwarder-2");
        vm.startPrank(OWNER);
        pay.setForwarder(first);
        bytes32 oldId = pay.queueResumeAuctions();
        vm.stopPrank();
        vm.warp(block.timestamp + _delay());

        vm.startPrank(OWNER);
        pay.queueForwarderUpdate(evil);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeForwarderUpdate(oldId);
        vm.stopPrank();
        assertEq(pay.automationForwarder(), first, "forwarder unchanged");
    }

    /// A second queue changes the pending address; the first id must not then
    /// install the second address early.
    function test_R2_forwarderUpdate_aNewQueueRestartsTheClock() public {
        address first = makeAddr("forwarder-1");
        address good  = makeAddr("forwarder-good");
        address evil  = makeAddr("forwarder-evil");
        vm.startPrank(OWNER);
        pay.setForwarder(first);
        bytes32 goodId = pay.queueForwarderUpdate(good);
        vm.stopPrank();
        vm.warp(block.timestamp + _delay());

        vm.startPrank(OWNER);
        bytes32 evilId = pay.queueForwarderUpdate(evil);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeForwarderUpdate(goodId);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.executeForwarderUpdate(evilId);
        vm.warp(block.timestamp + _delay());
        pay.executeForwarderUpdate(evilId);
        vm.stopPrank();
        assertEq(pay.automationForwarder(), evil);
        assertEq(pay.pendingForwarderId(), bytes32(0));
    }
}
