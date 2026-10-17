// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";

/// The price curve (SPEC §4.3), measured through the live contract: a lot is
/// opened, time is warped, and currentMultiplier() is read.
contract CurveTest is PaymentsV3Base {
    // Reference table for a 30-minute auction, computed in Python from the
    // spec's formula (evidence: review folder, curve_reference.py). Phase
    // boundaries at 360 s, 810 s and 1710 s.
    uint256[19] T = [0,1,36,71,72,180,359,360,361,500,809,810,811,1000,1500,1709,1710,1711,1799];
    uint256[19] M = [
        1536000000000000000000, 1514666666666666667264, 768000000000000000000, 394666666666666666752,
        384000000000000000000, 48000000000000000000, 1541666666666666667, 1500000000000000000,
        1498888888888888889, 1344444444444444445, 1001111111111111112, 1000000000000000000,
        999988888888888889, 997888888888888889, 992333333333333334, 990011111111111112,
        990000000000000000, 990000000000000000, 990000000000000000
    ];

    function test_curve_matchesTheReferenceTable() public {
        _fundAndKick(1_000e6);
        for (uint256 i = 0; i < T.length; i++) {
            _warpTo(T[i]);
            assertEq(pay.currentMultiplier(), M[i], "reference point");
        }
    }

    function test_curve_isMonotoneEverySecond() public {
        _fundAndKick(1_000e6);
        _warpTo(0);
        uint256 prev = pay.currentMultiplier();
        assertEq(prev, 1536 * ONE, "1536x at the start");
        for (uint256 t = 1; t < 1800; t++) {
            _warpTo(t);
            uint256 m = pay.currentMultiplier();
            assertLe(m, prev, "never rises");
            prev = m;
        }
        assertEq(prev, 99 * ONE / 100, "floor at the end");
        _warpTo(1800);
        assertEq(pay.currentMultiplier(), 0, "no lot after expiry");
        vm.expectRevert(PossessioPayments.NoLot.selector);
        pay.currentRequired();
    }

    function test_curve_phaseBoundaries_atEveryAllowedLength() public {
        uint64[3] memory lengths = [uint64(600), uint64(1800), uint64(7200)];
        vm.prank(OWNER);
        pay.setKickDelay(1 hours);
        for (uint256 i = 0; i < lengths.length; i++) {
            uint256 L = lengths[i];
            vm.prank(OWNER);
            pay.setAuctionLength(uint64(L));
            _warpFresh(vm.getBlockTimestamp() + 3 hours);       // past the previous lot and the delay
            _fundAndKick(1_000e6);
            uint256 p1 = L * 20 / 100; uint256 p2 = L * 45 / 100; uint256 p3 = L * 95 / 100;
            _warpTo(0);      assertEq(pay.currentMultiplier(), 1536 * ONE, "start");
            _warpTo(p1);     assertEq(pay.currentMultiplier(), 15 * ONE / 10, "1.5x at 20%");
            _warpTo(p2);     assertEq(pay.currentMultiplier(), ONE, "par at 45%");
            _warpTo(p3);     assertEq(pay.currentMultiplier(), 99 * ONE / 100, "floor at 95%");
            _warpTo(L - 1);  assertEq(pay.currentMultiplier(), 99 * ONE / 100, "floor held");
            _warpTo(L);      assertEq(pay.currentMultiplier(), 0, "expired");
        }
    }

    function test_required_isTheOracleAmountAtPar_roundedUp() public {
        _fundAndKick(1_000e6);
        (uint256 lotUsdc,,) = _lot();
        _warpTo(810);                                         // m = 1.0
        assertEq(pay.currentRequired(), _oracleCbEth(lotUsdc), "par");
        _warpTo(1710);                                        // floor
        assertEq(pay.currentRequired(), _ceilMul(_oracleCbEth(lotUsdc), 99 * ONE / 100), "99% of the oracle");
        _warpTo(0);
        assertEq(pay.currentRequired(), _ceilMul(_oracleCbEth(lotUsdc), 1536 * ONE), "1536x at the start");
    }

    /// SPEC §4.6: the anchor is live. The oracle moving during the auction
    /// moves what a take must deliver.
    function test_required_followsTheLiveOracle() public {
        _fundAndKick(1_000e6);
        (uint256 lotUsdc,,) = _lot();
        _warpTo(810);
        uint256 before = pay.currentRequired();
        feedEth.setAnswer(6000e8);                            // ETH doubles: half the cbETH buys the lot
        assertEq(pay.currentRequired(), _oracleCbEth(lotUsdc), "re-priced");
        assertApproxEqAbs(pay.currentRequired() * 2, before, 1, "half, to a wei of rounding");
        feedCb.setAnswer(1.10e18);                            // cbETH worth more ETH: fewer cbETH
        assertEq(pay.currentRequired(), _oracleCbEth(lotUsdc), "re-priced again");
    }
}
