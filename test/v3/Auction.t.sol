// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";
import {HonestTaker_V3, ReentrantTaker_V3} from "./PaymentsV3Mocks.sol";

contract AuctionTest is PaymentsV3Base {
    /*──────────────────────────── kick ────────────────────────────*/

    function test_kick_refusesWhenNothingIsAboveTheFloat() public {
        _fund(FLOAT);
        vm.expectRevert(PossessioPayments.BatchTooSmall.selector);
        _kick();
        _fund(BATCH - 1);
        vm.expectRevert(PossessioPayments.BatchTooSmall.selector);
        _kick();
        assertFalse(pay.canKick());
    }

    function test_kick_opensALotAndDepositsTheMorphoShare() public {
        _fund(FLOAT + 1_000e6);
        assertTrue(pay.canKick());
        vm.expectEmit(address(pay));
        emit PossessioPayments.Kicked(KEEPER, 1_000e6, 500e6, 500e6, vm.getBlockTimestamp() + 30 minutes);
        _kick();
        (uint256 lotUsdc, uint256 startedAt, uint256 endsAt) = _lot();
        assertEq(lotUsdc, 500e6, "half to the lot");
        assertEq(startedAt, vm.getBlockTimestamp());
        assertEq(endsAt, vm.getBlockTimestamp() + 30 minutes);
        assertEq(pay.morphoDepositedPrincipal(), 500e6, "half to Morpho");
        assertGt(vault.balanceOf(address(pay)), 0, "shares held");
        assertEq(usdc.balanceOf(address(pay)), FLOAT + 500e6, "the lot stays until taken");
        assertEq(pay.lastKickAt(), vm.getBlockTimestamp());
        assertEq(pay.nextKickAllowed(), vm.getBlockTimestamp() + 24 hours);
        assertFalse(pay.canKick(), "a lot is open");
    }

    function test_kick_anyoneMayKick() public {
        _fund(FLOAT + 1_000e6);
        vm.prank(STRANGER);
        pay.kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6);
    }

    function test_kick_refusesWhileALotIsOpen() public {
        _fundAndKick(1_000e6);
        _fund(1_000e6);
        vm.expectRevert(PossessioPayments.LotOpen.selector);
        _kick();
    }

    function test_kick_refusesBeforeTheDelay() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        _take(TAKER);
        _fund(1_000e6);
        vm.expectRevert(PossessioPayments.KickTooEarly.selector);
        _kick();
        _warpFresh(pay.nextKickAllowed());
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6);
    }

    function test_kick_closesAnExpiredLotFirst() public {
        _fundAndKick(1_000e6);
        _warpFresh(pay.nextKickAllowed());                 // 24 h later: the 30-minute lot expired untaken
        _fund(200e6);
        vm.expectEmit(address(pay));
        emit PossessioPayments.LotExpired(500e6);
        _kick();
        (uint256 lotUsdc, uint256 startedAt,) = _lot();
        // sellable = FLOAT + 500 (old lot) + 200 - FLOAT = 700; half each
        assertEq(lotUsdc, 350e6, "the old lot's USDC is sold again");
        assertEq(startedAt, vm.getBlockTimestamp());
        assertEq(pay.morphoDepositedPrincipal(), 850e6);
    }

    function test_kick_capAppliesToBothLegsTogether() public {
        vm.prank(OWNER);
        pay.setMaxKickUsdc(200e6);
        _fund(FLOAT + 1_000e6);
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 100e6, "half of the capped kick");
        assertEq(pay.morphoDepositedPrincipal(), 100e6, "the other half");
        assertEq(pay.sellableUsdc(), 900e6, "the rest waits (the open lot included)");
    }

    function test_kick_splitFollowsCbEthBps() public {
        vm.prank(OWNER);
        pay.setCbEthBps(9000);
        _fundAndKick(1_000e6);
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 900e6);
        assertEq(pay.morphoDepositedPrincipal(), 100e6);
    }

    function test_kick_failsClosedOnStaleOrInvalidFeeds() public {
        _fund(FLOAT + 1_000e6);
        feedCb.setStale();
        assertFalse(pay.canKick());
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        _kick();
        feedCb.setAnswer(1.05e18);                      // fresh again
        feedCb.setIncomplete();
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        _kick();
        feedCb.setAnswer(0);
        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        _kick();
        feedCb.setAnswer(1.05e18);
        feedEth.setStale();                             // 2 h old on a 1 h window
        assertFalse(pay.canKick());
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        _kick();
        feedEth.setAnswer(3000e8);
        feedUsdc.setUpdatedAt(vm.getBlockTimestamp() - 100_000); // past the 25 h window
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        _kick();
        feedUsdc.setAnswer(1e8);
        assertTrue(pay.canKick());
        _kick();                                        // control
    }

    function test_kick_vaultMisbehaviourReverts() public {
        _fund(FLOAT + 1_000e6);
        vault.setLeakageMode(true);
        vm.expectRevert(PossessioPayments.LeakageDetected.selector);
        _kick();
        vault.setLeakageMode(false);
        vault.setDepositReverts(true);
        vm.expectRevert(PossessioPayments.MorphoDepositFailed.selector);
        _kick();
        vault.setDepositReverts(false);
        _kick();                                        // control
    }

    function test_kick_refusedWhenPaused() public {
        _fund(FLOAT + 1_000e6);
        vm.prank(OWNER);
        pay.pauseAuctions();
        assertFalse(pay.canKick());
        vm.expectRevert(PossessioPayments.Paused.selector);
        _kick();
    }

    /*──────────────────────────── take ────────────────────────────*/

    function test_take_deliversCbEthAndReceivesTheLot() public {
        _fundAndKick(1_000e6);
        _warpTo(810);                                   // par
        uint256 required = pay.currentRequired();
        assertEq(required, _oracleCbEth(500e6));
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectEmit(address(pay));
        emit PossessioPayments.LotTaken(TAKER, 500e6, required, ONE);
        pay.take();
        vm.stopPrank();
        assertEq(usdc.balanceOf(TAKER), 500e6, "the lot");
        assertEq(cbeth.balanceOf(address(pay)), required, "the cbETH");
        assertEq(cbeth.balanceOf(TAKER), 0);
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 0, "lot cleared");
        assertEq(usdc.balanceOf(address(pay)), FLOAT, "the float is untouched");
    }

    function test_take_needsTheApproval() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        cbeth.mint(TAKER, pay.currentRequired());
        vm.prank(TAKER);
        vm.expectRevert();
        pay.take();
    }

    function test_take_shortDeliveryIsRefused() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        uint256 required = pay.currentRequired();
        cbeth.mint(TAKER, required);
        cbeth.setShortBy(1);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectRevert(PossessioPayments.ShortDelivery.selector);
        pay.take();
        vm.stopPrank();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "the lot is still open");
    }

    function test_take_afterExpiryAndTwiceAreRefused() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        _take(TAKER);
        vm.prank(TAKER);
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.take();
        _warpFresh(pay.nextKickAllowed());
        _fund(1_000e6);
        _kick();
        _warpTo(1800);
        vm.prank(TAKER);
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.take();
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.currentRequired();
    }

    function test_take_whenPausedIsRefused() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        uint256 required = pay.currentRequired();
        vm.prank(OWNER);
        pay.pauseAuctions();
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectRevert(PossessioPayments.Paused.selector);
        pay.take();
        vm.stopPrank();
    }

    function test_take_inPhaseOneIsFlagged() public {
        _fundAndKick(1_000e6);
        _warpTo(180);                                   // m = 48x
        uint256 required = pay.currentRequired();
        assertEq(required, _ceilMul(_oracleCbEth(500e6), 48 * ONE));
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectEmit(address(pay));
        emit PossessioPayments.ParOvershoot(TAKER, 48 * ONE);
        pay.take();
        vm.stopPrank();
    }

    function test_take_atTheFloorGetsOnePercentOffTheOracle() public {
        _fundAndKick(1_000e6);
        _warpTo(1750);
        uint256 required = _take(TAKER);
        assertEq(required, _ceilMul(_oracleCbEth(500e6), 99 * ONE / 100));
        assertLt(required, _oracleCbEth(500e6));
        assertGe(required * 100, _oracleCbEth(500e6) * 99, "never below 99%");
    }

    function test_take_raceSecondTakerFails() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        uint256 required = pay.currentRequired();
        cbeth.mint(TAKER, required);
        cbeth.mint(STRANGER, required);
        vm.prank(TAKER);    cbeth.approve(address(pay), required);
        vm.prank(STRANGER); cbeth.approve(address(pay), required);
        vm.prank(TAKER);
        pay.take();
        vm.prank(STRANGER);
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.take();
        assertEq(cbeth.balanceOf(STRANGER), required, "the loser keeps the cbETH");
    }

    /// An owner exit during an open lot can make the lot untakeable (the
    /// transfer fails), never pay a taker twice. The lot stays open.
    function test_take_whenTheOwnerDrainedBelowTheLot() public {
        _fundAndKick(1_000e6);
        vm.prank(OWNER);
        pay.sendUSDC(1_200e6, PAYEE);                   // balance now 300 < lot 500
        _warpTo(810);
        uint256 required = pay.currentRequired();
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectRevert();
        pay.take();
        vm.stopPrank();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "still open");
        assertEq(cbeth.balanceOf(TAKER), required, "nothing taken from the taker");
    }

    /*──────────────────────── takeWithCallback ────────────────────*/

    function test_callback_honestTakerSettles() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        HonestTaker_V3 taker = new HonestTaker_V3(address(cbeth));
        uint256 required = pay.currentRequired();
        cbeth.mint(address(taker), required);
        taker.go(address(pay), "");
        assertEq(usdc.balanceOf(address(taker)), 500e6);
        assertEq(cbeth.balanceOf(address(pay)), required);
        assertEq(taker.lastUsdcOut(), 500e6);
        assertEq(taker.lastRequired(), required);
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 0);
    }

    function test_callback_shortDeliveryRevertsAndKeepsTheLot() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        HonestTaker_V3 taker = new HonestTaker_V3(address(cbeth));
        uint256 required = pay.currentRequired();
        cbeth.mint(address(taker), required);
        taker.setDeliverOverride(required - 1);
        vm.expectRevert(PossessioPayments.ShortDelivery.selector);
        taker.go(address(pay), "");
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "the revert restored the lot");
        assertEq(usdc.balanceOf(address(taker)), 0, "and the USDC");
    }

    function _reentry(uint8 mode) internal {
        _fundAndKick(1_000e6);
        _warpTo(810);
        ReentrantTaker_V3 taker = new ReentrantTaker_V3(address(cbeth));
        taker.setMode(mode);
        cbeth.mint(address(taker), pay.currentRequired());
        taker.go(address(pay));
        assertTrue(taker.reentered(), "the callback did try");
        assertEq(taker.innerRevert(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"), "and hit the guard");
        assertEq(usdc.balanceOf(address(taker)), 500e6, "the honest outer take still settled");
    }

    function test_callback_reentryIntoTakeIsBlocked() public { _reentry(1); }
    function test_callback_reentryIntoKickIsBlocked() public { _reentry(2); }
    function test_callback_reentryIntoCallbackIsBlocked() public { _reentry(3); }

    function test_callback_whenPausedIsRefused() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        HonestTaker_V3 taker = new HonestTaker_V3(address(cbeth));
        cbeth.mint(address(taker), pay.currentRequired());
        vm.prank(OWNER);
        pay.pauseAuctions();
        vm.expectRevert(PossessioPayments.Paused.selector);
        taker.go(address(pay), "");
    }

    /*──────────────────────────── pause ───────────────────────────*/

    function test_pause_isTheOwnersAndResumesAfter48h() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        pay.pauseAuctions();
        vm.prank(OWNER);
        pay.pauseAuctions();
        assertTrue(pay.auctionsPaused());
        vm.prank(OWNER);
        bytes32 id = pay.queueResumeAuctions();
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.resumeAuctions(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.resumeAuctions(keccak256("other"));
        vm.prank(OWNER);
        pay.resumeAuctions(id);
        assertFalse(pay.auctionsPaused());
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotQueued.selector);
        pay.resumeAuctions(id);                         // spent
    }

    /*────────────────────────── automation ────────────────────────*/

    function test_upkeep_checkNeedsTheHysteresis() public {
        _fund(FLOAT + 110e6);                           // above the batch, below 120%
        assertTrue(pay.canKick());
        (bool needed,) = pay.checkUpkeep("");
        assertFalse(needed, "hysteresis");
        _fund(10e6);
        (needed,) = pay.checkUpkeep("");
        assertTrue(needed);
    }

    function test_upkeep_checkIsFalseWhenAKickWouldNotHappen() public {
        _fund(FLOAT + 1_000e6);
        vm.prank(OWNER);
        pay.pauseUpkeep();
        (bool needed,) = pay.checkUpkeep("");
        assertFalse(needed, "upkeep paused");
        vm.prank(OWNER);
        pay.unpauseUpkeep();
        vm.prank(OWNER);
        pay.pauseAuctions();
        (needed,) = pay.checkUpkeep("");
        assertFalse(needed, "auctions paused");
        vm.prank(OWNER);
        bytes32 id = pay.queueResumeAuctions();
        _warpFresh(vm.getBlockTimestamp() + 48 hours);
        vm.prank(OWNER);
        pay.resumeAuctions(id);
        (needed,) = pay.checkUpkeep("");
        assertTrue(needed);
        _kick();
        (needed,) = pay.checkUpkeep("");
        assertFalse(needed, "lot open");
        _warpTo(810);
        _take(TAKER);
        _fund(1_000e6);
        (needed,) = pay.checkUpkeep("");
        assertFalse(needed, "before the delay");
        _warpFresh(pay.nextKickAllowed());
        (needed,) = pay.checkUpkeep("");
        assertTrue(needed);
        feedEth.setStale();
        (needed,) = pay.checkUpkeep("");
        assertFalse(needed, "stale oracle");
    }

    function test_upkeep_performIsTheForwardersKick() public {
        address FWD = makeAddr("forwarder");
        _fund(FLOAT + 1_000e6);
        vm.prank(FWD);
        vm.expectRevert(PossessioPayments.ForwarderNotSet.selector);
        pay.performUpkeep("");
        vm.prank(OWNER);
        pay.setForwarder(FWD);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ForwarderAlreadySet.selector);
        pay.setForwarder(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(PossessioPayments.NotForwarder.selector);
        pay.performUpkeep("");
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.NotForwarder.selector);
        pay.performUpkeep("");
        vm.prank(FWD);
        pay.performUpkeep("");
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "kicked");
        assertEq(pay.executedUpkeepCount(), 1);
        vm.prank(FWD);
        vm.expectRevert(PossessioPayments.LotOpen.selector);
        pay.performUpkeep("");                          // same block: the kick's own rules refuse
        vm.prank(OWNER);
        pay.pauseUpkeep();
        vm.prank(FWD);
        vm.expectRevert(PossessioPayments.UpkeepIsPaused.selector);
        pay.performUpkeep("");
    }

    function test_upkeep_forwarderUpdateTakes48h() public {
        address FWD = makeAddr("forwarder");
        address FWD2 = makeAddr("forwarder2");
        vm.prank(OWNER);
        pay.setForwarder(FWD);
        vm.prank(OWNER);
        bytes32 id = pay.queueForwarderUpdate(FWD2);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        pay.executeForwarderUpdate(id);
        _warpFresh(vm.getBlockTimestamp() + 48 hours);
        vm.prank(OWNER);
        pay.executeForwarderUpdate(id);
        assertEq(pay.automationForwarder(), FWD2);
        _fund(FLOAT + 1_000e6);
        vm.prank(FWD);
        vm.expectRevert(PossessioPayments.NotForwarder.selector);
        pay.performUpkeep("");
        vm.prank(FWD2);
        pay.performUpkeep("");
    }

    /*────────────────────────────  gauge ──────────────────────────*/

    function test_gauge_countsBothLegsAndDowngradesPerLeg() public {
        _fundAndKick(1_000e6);
        _warpTo(810);
        uint256 required = _take(TAKER);
        uint256 cbLeg = (required * 1.05e18) / ONE;
        (uint256 shares, uint256 morphoUsdc) = pay.getMorphoBalance();
        assertGt(shares, 0);
        assertEq(morphoUsdc, 500e6);
        uint256 morphoLeg = (morphoUsdc * 1e12 * 1e8) / 3000e8;
        assertEq(pay.getTreasuryGauge(), cbLeg + morphoLeg, "both legs");
        lst.setReverts(true);
        assertEq(pay.getTreasuryGauge(), morphoLeg, "cbETH leg downgraded");
        lst.setReverts(false);
        vault.setConvertReverts(true);
        assertEq(pay.getTreasuryGauge(), cbLeg, "Morpho leg downgraded");
        vault.setConvertReverts(false);
        feedUsdc.setUpdatedAt(vm.getBlockTimestamp() - 100_000);
        assertEq(pay.getTreasuryGauge(), cbLeg, "stale USDC feed: Morpho leg unpriced, no revert");
    }
}
