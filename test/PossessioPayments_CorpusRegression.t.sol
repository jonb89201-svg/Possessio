// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentsV3Base} from "./v3/Base.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";

/*
 * Corpus regression (audit corpus AF-2, AF-8, AF-14), re-cut for v3.0: the
 * split conservation now runs at the kick (the lot plus the Morpho deposit is
 * the whole kick, the residue to Morpho), the bps bounds are unchanged, and a
 * stale or non-positive cbETH feed refuses the kick instead of the sweep.
 */
contract PossessioPaymentsCorpusRegression is PaymentsV3Base {
    uint256 constant BIG = type(uint128).max;

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        pay.setUsdcFloat(0);                                   // the whole balance is sellable
        pay.setMinSwapBatch(1);
        vm.stopPrank();
    }

    // AF-2 — the ENTIRE kick is split between the two legs with NO USDC stranded,
    // for every bps in [1000, 9000] and every size. The residue of the integer
    // division lands in the Morpho leg by construction.
    function testFuzz_AF2_splitConservesInput_noDust(uint16 bpsSeed, uint256 amtSeed) public {
        uint16 bps = uint16(1000 + (bpsSeed % 8001));
        uint256 amt = 1 + (amtSeed % (500_000 * 1e6));
        vm.prank(OWNER);
        pay.setCbEthBps(bps);
        _fund(amt);
        _kick();
        uint256 lotExpected = (amt * bps) / 10000;
        uint256 morphoExpected = amt - lotExpected;
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, lotExpected, "AF-2: the lot is the cbETH share");
        assertEq(pay.morphoDepositedPrincipal(), morphoExpected, "AF-2: the residue is in the Morpho leg");
        assertEq(lotUsdc + pay.morphoDepositedPrincipal(), amt, "AF-2: the legs sum to the kick");
        assertEq(usdc.balanceOf(address(pay)), lotUsdc, "AF-2: only the open lot's USDC remains");
    }

    function test_AF2_truncatingSplit_remainderToMorpho() public {
        uint16 bps = 3333;
        uint256 amt = 10_000_001;
        assertTrue((amt * bps) % 10000 != 0, "test setup: no truncation");
        vm.prank(OWNER);
        pay.setCbEthBps(bps);
        _fund(amt);
        _kick();
        uint256 lotExpected = (amt * bps) / 10000;
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, lotExpected);
        assertEq(pay.morphoDepositedPrincipal(), amt - lotExpected, "AF-2: truncation remainder in Morpho");
    }

    // AF-8 — setCbEthBps is bounded to [1000, 9000].
    function test_AF8_setCbEthBps_belowMin_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        pay.setCbEthBps(999);
    }

    function test_AF8_setCbEthBps_aboveMax_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        pay.setCbEthBps(9001);
    }

    function test_AF8_setCbEthBps_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        pay.setCbEthBps(0);
    }

    function test_AF8_setCbEthBps_boundariesAccepted() public {
        vm.startPrank(OWNER);
        pay.setCbEthBps(1000); assertEq(pay.cbEthBps(), 1000);
        pay.setCbEthBps(9000); assertEq(pay.cbEthBps(), 9000);
        vm.stopPrank();
    }

    function testFuzz_AF8_setCbEthBps_bound(uint16 bps) public {
        vm.prank(OWNER);
        if (bps < 1000 || bps > 9000) {
            vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
            pay.setCbEthBps(bps);
        } else {
            pay.setCbEthBps(bps);
            assertEq(pay.cbEthBps(), bps);
        }
    }

    // AF-14 — the cbETH/ETH feed gates the kick: stale or non-positive refuses.
    function test_AF14_staleCbEthFeed_revertsKick() public {
        _fund(1_000e6);
        feedCb.setStale();
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        _kick();
    }

    function test_AF14_nonPositiveCbEthAnswer_revertsKick() public {
        _fund(1_000e6);
        feedCb.setAnswer(0);
        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        _kick();
        feedCb.setAnswer(-1);
        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        _kick();
    }

    function test_AF14_control_freshFeeds_kickSucceeds() public {
        _fund(1_000e6);
        _kick();
        (uint256 lotUsdc,,) = _lot();
        assertEq(lotUsdc, 500e6);
    }
}
