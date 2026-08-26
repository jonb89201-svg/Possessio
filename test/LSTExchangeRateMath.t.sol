// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LSTExchangeRate} from "../src/LSTExchangeRate.sol";

// ============================================================================
// LSTExchangeRate — OFFLINE MATH PIN (cold-seat audit, 2026-08-26)
//
// The repo ships only LSTExchangeRateFork.t.sol, so the pure tick->rate math
// (_tickToRate18 / _getSqrtRatioAtTick) — the exact place a decimal/scaling
// bug would hide — is exercised ONLY against the live Base fork, never pinned
// as an isolated offline assertion. This file fills that jurisdiction gap.
//
// Properties asserted:
//   * tick 0 -> exactly 1e18 (price 1.0, the scaling anchor).
//   * strictly monotonic increasing in tick.
//   * reciprocal: rate(t) * rate(-t) ~= 1e36 (price(-t) = 1/price(t)).
//   * a realistic cbETH tick lands at ~1.13e18 (WETH per cbETH), matching the
//     header's cast-confirmed live rate — proving no decimal misscale.
// ============================================================================

contract LSTMathHarness is LSTExchangeRate {
    function tickToRate18(int24 t) external pure returns (uint256) {
        return _tickToRate18(t);
    }
    function sqrtRatioAtTick(int24 t) external pure returns (uint160) {
        return _getSqrtRatioAtTick(t);
    }
}

contract LSTExchangeRateMathTest is Test {
    LSTMathHarness h;

    function setUp() public {
        h = new LSTMathHarness();
    }

    /// The scaling anchor: price 1.0 must be exactly 1e18.
    function test_tickZero_isExactlyOne() public view {
        assertEq(h.tickToRate18(0), 1e18, "tick 0 must be exactly 1e18");
        assertEq(h.sqrtRatioAtTick(0), uint160(1) << 96, "sqrtRatio(0) must be 2^96");
    }

    /// Strictly increasing across a representative band around the peg.
    function test_monotonicIncreasing() public view {
        int24[9] memory ticks = [int24(-2000), -1000, -500, -100, 0, 100, 500, 1000, 2000];
        uint256 prev;
        for (uint256 i; i < ticks.length; ++i) {
            uint256 r = h.tickToRate18(ticks[i]);
            if (i > 0) assertGt(r, prev, "rate must strictly increase with tick");
            prev = r;
        }
    }

    /// price(-t) = 1/price(t): the product must be ~1e36 (within precision).
    function test_reciprocal() public view {
        int24[4] memory ts = [int24(250), 1000, 2500, 6000];
        for (uint256 i; i < ts.length; ++i) {
            uint256 up = h.tickToRate18(ts[i]);
            uint256 dn = h.tickToRate18(-int24(ts[i]));
            uint256 prod = (up * dn); // ~1e36
            // Allow 1e-6 relative slack for integer-tick rounding.
            assertApproxEqRel(prod, 1e36, 1e12, "rate(t)*rate(-t) must be ~1e36");
        }
    }

    /// A realistic cbETH/WETH tick (~1.1327 WETH per cbETH, per the header's
    /// cast-confirmed live feed) must land near 1.13e18 — proving the 18-dec
    /// scaling is right (no 1e9/1e18/2^96 misscale).
    function test_realisticCbEthRate_scaleIsCorrect() public view {
        // tick for price 1.1327 = ln(1.1327)/ln(1.0001) ~= 1247.
        uint256 r = h.tickToRate18(1247);
        assertApproxEqRel(r, 1.1327e18, 1e15, "realistic cbETH rate must be ~1.1327e18 (0.1%)");
        // Sanity band: strictly between 1.0 and 1.25 WETH per cbETH.
        assertGt(r, 1e18, "cbETH must be worth > 1 WETH");
        assertLt(r, 1.25e18, "cbETH rate implausibly high - scaling bug");
    }

    /// Precision floor: tick 1 (0.01% up) must be strictly above 1e18 and
    /// below 1.001e18 — the smallest step still resolves, no truncation to 1e18.
    function test_smallestStepResolves() public view {
        uint256 r1 = h.tickToRate18(1);
        assertGt(r1, 1e18, "tick 1 must exceed 1e18 (step not truncated away)");
        assertLt(r1, 1.001e18, "tick 1 must be ~1.0001e18");
    }
}
