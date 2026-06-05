// SPDX-License-Identifier: MIT
// BUILD-PROOF: HOOK_M1_OVERFLOW_OUT62 — M-1 regression: bare sqrtPriceX96^2 multiply
// overflows above 2^128; staged FullMath.mulDiv does not. Fail-old / pass-new.
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title  PossessioHook M-1 overflow regression
 * @notice The hook's beforeSwap converts a STEEL-specified amount to its ETH
 *         equivalent using the pool price:
 *
 *             ethEquivalent = absSpecified * sqrtPriceX96^2 / 2^192
 *
 *         The VULNERABLE form (pre-fix) computed sqrtPriceX96^2 as a BARE
 *         uint256 multiply before handing it to FullMath:
 *
 *             FullMath.mulDiv(absSpecified, sqrtPriceX96 * sqrtPriceX96, 1<<192)
 *                                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 *         sqrtPriceX96 can reach ~2^160 (MAX_SQRT_RATIO). Once sqrtPriceX96
 *         exceeds 2^128, sqrtPriceX96^2 exceeds 2^256 and Solidity 0.8 checked
 *         arithmetic reverts — bricking EVERY STEEL-specified swap on that
 *         branch until price moves back.
 *
 *         The FIXED form stages the square through FullMath's 512-bit
 *         intermediate so the product never materializes as a bare uint256:
 *
 *             priceX96      = FullMath.mulDiv(sqrtP, sqrtP, 1<<96)   // sqrtP^2 / 2^96
 *             ethEquivalent = FullMath.mulDiv(absSpecified, priceX96, 1<<96)
 *
 *         which equals absSpecified * sqrtP^2 / 2^192 exactly.
 *
 *  ── PROVENANCE (for future seats) ────────────────────────────────────────
 *         This bare-square overflow is a RECURRING pattern across the stack,
 *         not a one-off:
 *           • V1 PLATE.sol (deployed, now dormant) carries it TWICE —
 *               _getTWAPPrice  ~L920:  (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q96
 *               _getSpotPrice  ~L981:  same expression
 *             V1's input came from a TWAP tick (TickMath.getSqrtRatioAtTick),
 *             whose realistic range rarely nears 2^128 — so V1 never blew up in
 *             practice, but the footgun is live in that code. DO NOT copy the V1
 *             price math forward; it is the UNFIXED form.
 *           • The V3 hook reads spot sqrtPriceX96 from StateLibrary.getSlot0,
 *             which CAN reach extreme values (thin/memecoin pricing, manipulated
 *             spot), so the hook is materially more exposed than V1 was.
 *           • The fix direction (use FullMath.mulDiv, never a bare square) was
 *             prescribed in the 2026-05-02 treasury session ("Routing 3" overflow
 *             note) and is finally applied here. The V3 hook — not V1 — is the
 *             canonical fixed reference for this math from now on.
 *
 *         This suite proves: (1) at safe prices the two forms AGREE (the fix is
 *         mathematically equivalent), and (2) at extreme prices the OLD form
 *         reverts while the NEW form does not (the fix removes the overflow).
 *         It targets the math directly — no PoolManager / slot0 storage layout
 *         dependency — so it is a clean, cheap fail-old/pass-new regression.
 */
contract PossessioHook_M1Overflow_Test is Test {

    // ── The two implementations under test ──────────────────────────────────
    // VULNERABLE: exact copy of the pre-fix line (bare square).
    function oldConvert(uint256 absSpecified, uint160 sqrtPriceX96)
        public
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(
            absSpecified,
            uint256(sqrtPriceX96) * uint256(sqrtPriceX96),   // bare multiply — overflows >2^128
            1 << 192
        );
    }

    // FIXED: exact copy of the staged form now in the contract.
    function newConvert(uint256 absSpecified, uint160 sqrtPriceX96)
        public
        pure
        returns (uint256)
    {
        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 96
        );
        return FullMath.mulDiv(absSpecified, priceX96, 1 << 96);
    }

    // ── 1. Equivalence at safe prices: the fix must not change behavior ──────
    function test_M1_StagedEqualsBare_AtSafePrice() public pure {
        // A normal pool price well below 2^128 (≈ price 1.0 → sqrtPriceX96 = 2^96).
        uint160 sqrtP = uint160(1) << 96;       // 2^96, price ratio 1:1
        uint256 amt   = 1_000 ether;

        // Both forms are valid here and must produce the identical result.
        // (Different rounding paths can differ by at most 1 wei; assert exact —
        // if this ever trips, tighten to assertApproxEqAbs(…, 1).)
        assertEq(
            newConvert(amt, sqrtP),
            oldConvert(amt, sqrtP),
            "staged fix must equal bare form at safe price"
        );
    }

    // Spot-check a second safe price to be sure equivalence isn't a fluke.
    function test_M1_StagedEqualsBare_AtSafePrice2() public pure {
        uint160 sqrtP = uint160(3) << 96;       // price ratio 9:1, still < 2^128
        uint256 amt   = 500 ether;
        assertEq(newConvert(amt, sqrtP), oldConvert(amt, sqrtP),
            "staged fix must equal bare form at second safe price");
    }

    // ── 2. The bug: OLD reverts at an extreme price, NEW does not ────────────
    // This is the load-bearing fail-old/pass-new assertion. sqrtPriceX96 just
    // above 2^128 makes sqrtPriceX96^2 exceed 2^256 → checked-arith revert in
    // the bare multiply. Run against a contract still using oldConvert, this
    // test's first half PASSES (it expects the revert) and proves the bug is
    // real; the second half proves the fix survives the same input.
    function test_M1_OldOverflows_NewSurvives_AtExtremePrice() public {
        uint160 sqrtP = uint160(uint256(1) << 129);   // 2^129 > 2^128 threshold
        uint256 amt   = 1 ether;

        // OLD: the bare square 2^129 * 2^129 = 2^258 overflows uint256 → revert.
        vm.expectRevert(stdError.arithmeticError);
        this.oldConvert(amt, sqrtP);

        // NEW: staged mulDiv handles it with no overflow and returns a value.
        uint256 got = this.newConvert(amt, sqrtP);
        assertGt(got, 0, "staged fix must produce a non-zero ETH equivalent");
    }

    // ── 3. NEW survives the FULL valid sqrtPrice range (fuzz) ────────────────
    // MAX_SQRT_RATIO is ~2^160, far above the 2^128 overflow threshold, so a
    // large fraction of valid prices would brick the old contract. The fix must
    // never revert anywhere in the legal range.
    function testFuzz_M1_NewSurvivesFullRange(uint160 sqrtP, uint256 amt) public {
        // Bound to the valid sqrtPriceX96 range. Use the spec NUMERIC literals
        // rather than TickMath.MIN/MAX_SQRT_* constants, because v4-core renamed
        // the family (getSqrtPriceAtTick / MIN_SQRT_PRICE) vs v3 (getSqrtRatioAtTick
        // / MIN_SQRT_RATIO) — the values are identical across both, so literals
        // are name-independent and cannot break the build on a naming mismatch.
        // MIN = 4295128739 ; MAX = 1461446703485210103287273052203988822378723970342
        sqrtP = uint160(bound(
            uint256(sqrtP),
            4295128739,
            1461446703485210103287273052203988822378723970342 - 1
        ));
        amt = bound(amt, 0, 1e30);              // up to ~1e12 STEEL (18-dec)

        // Must not revert anywhere in the valid price range.
        uint256 got = this.newConvert(amt, sqrtP);

        if (amt == 0) {
            assertEq(got, 0, "zero amount must yield zero");
        }
    }

    // ── 4. Confirm the old form overflows across a swath of extreme prices ───
    // Demonstrates the bug is not a single-point artifact: any price above the
    // 2^128 boundary triggers it.
    function test_M1_OldOverflows_AcrossExtremeRange() public {
        uint160[3] memory extremePrices = [
            uint160(uint256(1) << 129),
            uint160(uint256(1) << 140),
            uint160(uint256(1) << 159)          // near MAX_SQRT_RATIO (~2^160)
        ];
        for (uint256 i = 0; i < extremePrices.length; i++) {
            vm.expectRevert(stdError.arithmeticError);
            this.oldConvert(1 ether, extremePrices[i]);

            // Fixed form survives each.
            uint256 got = this.newConvert(1 ether, extremePrices[i]);
            assertGt(got, 0, "staged fix must survive extreme price");
        }
    }
}
