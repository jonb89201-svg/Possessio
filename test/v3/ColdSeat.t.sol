// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.sol";

/// Cold-seat audit of v3.0 (2026-10-18; the record is COLD_SEAT_AUDIT_20261018.md
/// in the council sandbox). One test per finding that changed code, written so
/// that the finding would have failed it, plus the residual checks the seat asked
/// for: G-1 the sequencer uptime gate, G-2 the open lot's USDC reserve, G-3 the
/// Morpho principal accounting, R-2 a fee-on-transfer cbETH, and the whole-revert
/// of a redeem above the daily limit.
contract PaymentsV3ColdSeat is PaymentsV3Base {

    // ═══════════════ G-1: the sequencer uptime feed gates kick and take ═══════

    function test_G1_kickRefusedWhileTheSequencerIsDown() public {
        _fund(FLOAT + 1_000e6);
        feedSeq.setAnswer(1);                                   // down
        assertFalse(pay.canKick(), "canKick sees the outage");
        (bool needed,) = pay.checkUpkeep("");
        assertFalse(needed, "Automation would not kick");
        vm.expectRevert(PossessioPayments.SequencerDown.selector);
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 0, "no lot");
        assertEq(vault.balanceOf(address(pay)), 0, "nothing deposited");
    }

    function test_G1_afterARestartKicksWaitTheGracePeriod() public {
        _fund(FLOAT + 1_000e6);
        feedSeq.setAnswer(1);
        vm.expectRevert(PossessioPayments.SequencerDown.selector);
        _kick();
        feedSeq.setAnswer(0);                                   // back up, just now
        feedSeq.setStartedAt(vm.getBlockTimestamp());
        assertFalse(pay.canKick(), "still in the grace period");
        vm.expectRevert(PossessioPayments.SequencerGracePeriod.selector);
        _kick();
        _warpFresh(vm.getBlockTimestamp() + pay.SEQUENCER_GRACE() - 1);
        assertFalse(pay.canKick(), "one second short");
        vm.expectRevert(PossessioPayments.SequencerGracePeriod.selector);
        _kick();
        _warpFresh(vm.getBlockTimestamp() + 1);
        assertTrue(pay.canKick(), "the grace period is over");
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "the lot opened");
    }

    function test_G1_takeWaitsTooAndALongLotSurvivesIt() public {
        _owner(); pay.setAuctionLength(2 hours);                // longer than the grace, so the lot outlives it
        _fundAndKick(1_000e6);
        _warpTo(30 minutes);
        _freshFeeds();
        feedSeq.setAnswer(1);
        uint256 required = pay.currentRequired();               // the view still prices; the take does not settle
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectRevert(PossessioPayments.SequencerDown.selector);
        pay.take();
        vm.stopPrank();
        feedSeq.setAnswer(0);
        feedSeq.setStartedAt(vm.getBlockTimestamp());
        vm.prank(TAKER);
        vm.expectRevert(PossessioPayments.SequencerGracePeriod.selector);
        pay.take();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6, "the lot is untouched");
        _warpFresh(vm.getBlockTimestamp() + pay.SEQUENCER_GRACE());
        assertTrue(pay.lotOpen(), "1h30 into a 2h lot");
        _take(TAKER);
        assertEq(usdc.balanceOf(TAKER), 500e6, "taken once the grace period passed");
    }

    function test_G1_callbackTakesAreGatedToo() public {
        _fundAndKick(1_000e6);
        HonestTaker_V3 taker = new HonestTaker_V3(address(cbeth));
        _warpTo(20 minutes);
        _freshFeeds();
        cbeth.mint(address(taker), pay.currentRequired() * 2);
        feedSeq.setAnswer(1);
        vm.expectRevert(PossessioPayments.SequencerDown.selector);
        taker.go(address(pay), "");
        feedSeq.setAnswer(0);
        feedSeq.setStartedAt(vm.getBlockTimestamp() - 1 days);
        taker.go(address(pay), "");
        assertEq(usdc.balanceOf(address(taker)), 500e6, "settled once the sequencer is fine");
    }

    function test_G1_aRevertingUptimeFeedFailsClosed() public {
        _fund(FLOAT + 1_000e6);
        feedSeq.setReverts(true);
        assertFalse(pay.canKick(), "canKick does not revert, it says no");
        vm.expectRevert();
        _kick();
    }

    // ═══════════════ G-2: an open lot's USDC is reserved for its taker ════════

    function test_G2_sendUSDCKeepsTheLotReserved() public {
        _fundAndKick(1_000e6);                                  // balance 1,500: the float plus the 500 lot
        assertTrue(pay.lotOpen());
        assertEq(usdc.balanceOf(address(pay)), 1_500e6);
        _owner();
        vm.expectRevert(PossessioPayments.LotReserved.selector);
        pay.sendUSDC(1_001e6, PAYEE);
        _owner(); pay.sendUSDC(1_000e6, PAYEE);                  // down to exactly the lot
        assertEq(usdc.balanceOf(address(pay)), 500e6);
        _owner();
        vm.expectRevert(PossessioPayments.LotReserved.selector);
        pay.sendUSDC(1, PAYEE);
        _take(TAKER);                                            // the lot is still takeable
        assertEq(usdc.balanceOf(TAKER), 500e6, "the taker got the whole lot");
        assertEq(usdc.balanceOf(address(pay)), 0);
        assertFalse(pay.lotOpen());
    }

    function test_G2_anExpiredLotReservesNothing() public {
        _fundAndKick(1_000e6);
        _warpTo(pay.auctionLength());                           // expired, not yet cleared
        assertFalse(pay.lotOpen());
        _owner(); pay.sendUSDC(1_500e6, PAYEE);                  // everything, the dead lot's USDC included
        assertEq(usdc.balanceOf(address(pay)), 0);
        _fund(FLOAT + 400e6);                                    // the next kick clears the dead lot and proceeds
        _warpFresh(vm.getBlockTimestamp() + pay.kickDelay());
        vm.expectEmit(true, true, true, true);
        emit PossessioPayments.LotExpired(500e6);
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 200e6);
    }

    function test_G2_anEmergencyUSDCExitCancelsTheLot() public {
        _owner(); pay.queueEmergencyWithdraw(address(usdc), type(uint256).max);
        _warpFresh(vm.getBlockTimestamp() + 7 days - 10 minutes);
        _fundAndKick(1_000e6);                                  // a lot opens ten minutes before the emergency is ready
        _warpFresh(vm.getBlockTimestamp() + 10 minutes);
        assertTrue(pay.lotOpen(), "the lot is open at execution time");
        vm.expectEmit(true, true, true, true);
        emit PossessioPayments.LotCancelled(500e6);
        _owner(); pay.executeEmergencyWithdraw(address(usdc), PAYEE);
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 0, "the lot is gone, not left standing untakeable");
        assertEq(usdc.balanceOf(PAYEE), 1_500e6, "everything went to the payee");
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.currentRequired();
    }

    // ═══════════════ G-3: the Morpho principal follows the shares ═════════════

    function test_G3_principalFallsProRataOnRedeem() public {
        _fundAndKick(1_000e6);
        assertEq(pay.morphoDepositedPrincipal(), 500e6, "the principal is the deposit");
        uint256 shares = vault.balanceOf(address(pay));
        _owner(); pay.redeemMorpho(shares / 2, PAYEE);
        assertApproxEqAbs(pay.morphoDepositedPrincipal(), 250e6, 1, "half the shares, half the principal");
        uint256 rest = vault.balanceOf(address(pay));          // read before the prank: a view call would consume it
        _owner(); pay.redeemMorpho(rest, PAYEE);
        assertEq(pay.morphoDepositedPrincipal(), 0, "no shares, no principal");
        assertEq(vault.balanceOf(address(pay)), 0);
    }

    function test_G3_twoDepositsThenAFifthOut() public {
        _fundAndKick(1_000e6);
        _warpFresh(vm.getBlockTimestamp() + pay.kickDelay());
        _fund(1_000e6);
        _kick();                                                // clears the dead lot; sells 1,500: 750 to Morpho
        assertEq(pay.morphoDepositedPrincipal(), 1_250e6);
        uint256 shares = vault.balanceOf(address(pay));
        _owner(); pay.redeemMorpho(shares / 5, PAYEE);
        assertApproxEqAbs(pay.morphoDepositedPrincipal(), 1_000e6, 1);
    }

    function test_G3_principalIsDepositsNotValue() public {
        _fundAndKick(1_000e6);
        vault.addYield(100e6);                                  // the vault earned: value 600, principal 500
        (, uint256 value) = pay.getMorphoBalance();
        assertEq(value, 600e6);
        assertEq(pay.morphoDepositedPrincipal(), 500e6, "principal ignores the gain");
        uint256 shares = vault.balanceOf(address(pay));
        _owner(); uint256 out = pay.redeemMorpho(shares / 2, PAYEE);
        assertEq(out, 300e6, "half the value came out");
        assertEq(pay.morphoDepositedPrincipal(), 250e6, "half the principal left with it");
    }

    function test_G3_anEmergencyExitOfSharesTakesItsPrincipal() public {
        _fundAndKick(1_000e6);
        uint256 shares = vault.balanceOf(address(pay));
        _owner(); pay.queueEmergencyWithdraw(address(vault), shares / 2);
        _warpFresh(vm.getBlockTimestamp() + 7 days);
        _owner(); pay.executeEmergencyWithdraw(address(vault), PAYEE);
        assertEq(vault.balanceOf(PAYEE), shares / 2, "the payee holds the shares");
        assertApproxEqAbs(pay.morphoDepositedPrincipal(), 250e6, 1, "half the principal went with them");
    }

    // ═══════════════ residual checks the seat asked for ═══════════════════════

    /// R-2: a cbETH that skims on transfer is, from the contract's side, a short
    /// delivery. The balance check holds whatever the token does.
    function test_R2_feeOnTransferCbEthIsAShortDelivery() public {
        _fundAndKick(1_000e6);
        cbeth.setFeeBps(10);                                    // a 0.1% skim on every transfer
        _freshFeeds();
        uint256 required = pay.currentRequired();
        cbeth.mint(TAKER, required);
        vm.startPrank(TAKER);
        cbeth.approve(address(pay), required);
        vm.expectRevert(PossessioPayments.ShortDelivery.selector);
        pay.take();
        vm.stopPrank();
        assertTrue(pay.lotOpen(), "the lot is still there");
        assertEq(usdc.balanceOf(TAKER), 0, "nothing left");
    }

    /// A redeem above the daily limit reverts whole: the vault redemption that
    /// already happened inside the call is undone with it.
    function test_R_redeemMorphoOverTheDailyLimitRevertsWhole() public {
        _fundAndKick(30_000e6);                                 // 15,000 to Morpho, above the 10,000 USDC limit
        uint256 shares = vault.balanceOf(address(pay));
        uint256 principal = pay.morphoDepositedPrincipal();
        _owner();
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        pay.redeemMorpho(shares, PAYEE);
        assertEq(vault.balanceOf(address(pay)), shares, "no shares left the vault");
        assertEq(pay.morphoDepositedPrincipal(), principal, "the principal is untouched");
        assertEq(usdc.balanceOf(PAYEE), 0, "the payee got nothing");
    }
}
