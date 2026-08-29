// SPDX-License-Identifier: MIT
// AUDIT GUARD TESTS — LSTExchangeRate (warm-seat pass, 2026-08-29).
//
// The existing suites prove the HAPPY path (offline math pin + live fork
// valuation) but never force the two fail-closed guards the Moonwell-lens
// audit flagged:
//   * F-2 staleness  -> OracleStale must fire once the feed ages past 24h.
//   * F-1 divergence -> RateDivergence must fire when oracle vs TWAP disagree
//     > 2% (this is the ONLY thing a pool-manipulator can achieve: a REVERT,
//     never a mispricing — the returned value is always Chainlink's).
//
// Both guards firing = fail-closed. These tests assert the revert IS the
// behavior (a manipulator gets a DoS, not extractable value). Forks Base.
//
// RUN:
//   BASE_RPC_URL="https://mainnet.base.org" \
//     forge test --match-contract LSTExchangeRateAuditGuardsTest -vvv

pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LSTExchangeRate} from "../src/LSTExchangeRate.sol";

contract LSTExchangeRateAuditGuardsTest is Test {
    LSTExchangeRate rates;
    address constant CBETH_ETH_FEED = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    bool forked;

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        if (forked) rates = new LSTExchangeRate();
    }

    // Sanity: the guards are quiet under live conditions (baseline green).
    function test_baseline_live_ok() public {
        if (!forked) { vm.skip(true); return; }
        uint256 out = rates.cbEthToEth(1e18);
        assertGt(out, 1e18, "live cbETH must value > 1 ETH");
        console2.log("baseline cbEthToEth(1e18) =", out);
    }

    // F-2 — STALENESS. Age the feed past ORACLE_STALE (24h): the staleness
    // check in _oracleRateWethPerCbEth runs FIRST, so cbEthToEth must revert
    // OracleStale before the TWAP is even consulted. Fail-closed on a frozen feed.
    function test_F2_staleFeed_revertsOracleStale() public {
        if (!forked) { vm.skip(true); return; }
        // Read the live updatedAt, then warp to just past 24h beyond it.
        (, , , uint256 updatedAt, ) = _liveRound();
        vm.warp(updatedAt + 24 hours + 1);
        vm.expectRevert(LSTExchangeRate.OracleStale.selector);
        rates.cbEthToEth(1e18);
    }

    // F-2 boundary — one second INSIDE the window must still price (no false halt).
    function test_F2_justInsideWindow_ok() public {
        if (!forked) { vm.skip(true); return; }
        (, , , uint256 updatedAt, ) = _liveRound();
        vm.warp(updatedAt + 24 hours - 1);
        uint256 out = rates.cbEthToEth(1e18);
        assertGt(out, 0, "must still price 1s inside staleness window");
    }

    // F-1 — DIVERGENCE. Force the oracle > 2% away from the live TWAP by
    // mocking latestRoundData to a rate ~15% high. cbEthToEth must revert
    // RateDivergence: a manipulated/mocked price is REFUSED, not returned.
    // This is the fail-closed proof — the manipulator's ceiling is a revert.
    function test_F1_oracleDivergesHigh_revertsRateDivergence() public {
        if (!forked) { vm.skip(true); return; }
        (uint80 rid, int256 ans, uint256 sAt, uint256 uAt, uint80 air) = _liveRound();
        int256 inflated = (ans * 115) / 100; // +15%, well past the 2% band
        vm.mockCall(
            CBETH_ETH_FEED,
            abi.encodeWithSelector(0xfeaf968c), // latestRoundData()
            abi.encode(rid, inflated, sAt, uAt, air)
        );
        // Selector-only match (RateDivergence carries (oracleRate,marketRate)
        // args, so expectPartialRevert is the correct matcher). Proves the
        // DIVERGENCE guard fired specifically — non-vacuity: the 1%-nudge twin
        // below runs the same mock machinery and prices fine.
        vm.expectPartialRevert(LSTExchangeRate.RateDivergence.selector);
        rates.cbEthToEth(1e18);
    }

    // F-1 boundary — a divergence just UNDER 2% must still price (guard is a
    // band, not a hair-trigger; proves no false-halt on ordinary oracle/spot noise).
    function test_F1_justUnderBand_ok() public {
        if (!forked) { vm.skip(true); return; }
        (uint80 rid, int256 ans, uint256 sAt, uint256 uAt, uint80 air) = _liveRound();
        int256 nudged = (ans * 101) / 100; // +1%, inside the 2% band
        vm.mockCall(
            CBETH_ETH_FEED,
            abi.encodeWithSelector(0xfeaf968c),
            abi.encode(rid, nudged, sAt, uAt, air)
        );
        uint256 out = rates.cbEthToEth(1e18);
        assertGt(out, 0, "1% divergence must not false-halt");
    }

    // F guard — non-positive feed answer must revert OracleInvalid (defense-in-depth).
    function test_negativeFeed_revertsOracleInvalid() public {
        if (!forked) { vm.skip(true); return; }
        (uint80 rid, , uint256 sAt, uint256 uAt, uint80 air) = _liveRound();
        vm.mockCall(
            CBETH_ETH_FEED,
            abi.encodeWithSelector(0xfeaf968c),
            abi.encode(rid, int256(-1), sAt, uAt, air)
        );
        vm.expectRevert(LSTExchangeRate.OracleInvalid.selector);
        rates.cbEthToEth(1e18);
    }

    function _liveRound()
        internal
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (bool ok, bytes memory data) =
            CBETH_ETH_FEED.staticcall(abi.encodeWithSelector(0xfeaf968c));
        require(ok, "live feed read failed");
        return abi.decode(data, (uint80, int256, uint256, uint256, uint80));
    }
}
