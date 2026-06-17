// =============================================================================
// SWEEP GUARD TEETH-TESTS — paste into PossessioPayments_t.sol (PossessioPaymentsTest)
//
// Closes the cavity-search coverage gap: five revert points in _sweep that were
// present in the deployed bytecode but had ZERO test coverage:
//
//   ExchangeRateInvalid  (line ~1000) — LSTE cbEthToEth returns 0
//   MorphoDepositFailed  (line ~980)  — Morpho deposit mints no shares
//   MorphoDepositFailed  (line ~992)  — Morpho deposit call reverts
//   ZeroOutput           (line ~905)  — USDC->WETH swap returns 0
//   ZeroOutput           (line ~939)  — WETH->cbETH swap returns 0
//
// Each forces the failure with an existing mock knob and asserts the specific
// revert fires. Pattern matches test_Sweep_AllocatesCbETHWhenNoCeiling exactly.
//
// NOTE on the two ZeroOutput tests: the contract's leakage guard
// (usdcBefore - usdcAfter == alloc) and slippage floors sit on the same legs.
// A mock returning 0 must also satisfy the router's own amountOutMinimum require
// or the revert will come from the mock ("slippage"), not the contract. To force
// the *contract's* ZeroOutput, the caller-supplied min must be 0 (so the floor is
// the binding constraint, not the mock) AND the mock returns 0. Verify on the
// terminal that the revert selector is ZeroOutput and not a mock string revert
// or a slippage/leakage revert — if it is, the guard ordering needs inspecting
// (which is itself a finding). Do not assume; read the -vvvv trace.
// =============================================================================


// ── ExchangeRateInvalid: LSTE returns 0 ──────────────────────────────────────
// cbETH leg succeeds, then LST_RATES.cbEthToEth(cbEthOut) returns 0 -> revert.
function test_Sweep_RevertsExchangeRateInvalid() public {
    vm.prank(MERCHANT);
    payments.setDaiCeiling(0);

    usdc.mint(address(payments), 1000 * 1e6);
    router.setWethOut(0.31 ether);
    aeroRouter.setCbEthOut(0.31 ether);

    // Force the LSTE guard to report an invalid (zero) rate.
    lstRates.setCbEthRate(0);

    vm.expectRevert(PossessioPayments.ExchangeRateInvalid.selector);
    vm.prank(MERCHANT);
    payments.sweep(0, 0, 0.31 ether);
}

// Teeth check: with a VALID rate the same sweep must NOT revert (proves the
// test isolates the guard, not some unrelated failure).
function test_Sweep_ExchangeRateValid_NoRevert() public {
    vm.prank(MERCHANT);
    payments.setDaiCeiling(0);

    usdc.mint(address(payments), 1000 * 1e6);
    router.setWethOut(0.31 ether);
    aeroRouter.setCbEthOut(0.31 ether);
    lstRates.setCbEthRate(1.05e18); // valid

    vm.prank(MERCHANT);
    payments.sweep(0, 0, 0.31 ether); // should succeed
}


// ── MorphoDepositFailed (reverts): the deposit call itself reverts ───────────
// Requires a non-zero Morpho allocation. Set cbEthBps so some USDC routes to
// Morpho, then make the vault revert on deposit.
function test_Sweep_RevertsMorphoDepositReverts() public {
    vm.prank(MERCHANT);
    payments.setDaiCeiling(0);

    // Ensure a Morpho allocation exists (cbEthBps < 100% so remainder -> Morpho).
    // Adjust selector/name to the real setter if different.
    vm.prank(MERCHANT);
    payments.setCbEthBps(5000); // 50% cbETH / 50% Morpho

    usdc.mint(address(payments), 1000 * 1e6);
    router.setWethOut(0.31 ether);
    aeroRouter.setCbEthOut(0.31 ether);

    morphoVault.setDepositReverts(true);

    vm.expectRevert(PossessioPayments.MorphoDepositFailed.selector);
    vm.prank(MERCHANT);
    payments.sweep(0, 0, 0.31 ether);
}

// ── MorphoDepositFailed (no shares): deposit returns but mints nothing ───────
// leakageMode consumes assets-1, so shares minted < expected; if the contract's
// check is sharesAfter <= sharesBefore this needs a mock that mints ZERO shares.
// The existing leakageMode mints (assets-1) shares (>0), so it triggers the
// LeakageDetected guard, NOT MorphoDepositFailed. To hit the no-shares branch,
// the mock needs a "mint zero shares but don't revert" mode. If that mode does
// not exist, this guard branch (sharesAfter <= sharesBefore) is UNREACHABLE with
// current mocks — which is itself a finding: either add a zeroShares mock mode,
// or confirm the branch is dead given the consumption check fires first.
//
// PLACEHOLDER — verify on terminal whether a zero-shares deposit is even
// reachable before the leakage guard. Do not claim this branch tested until the
// mock can express "deposit succeeds, zero shares" without tripping leakage.
function test_Sweep_RevertsMorphoNoShares_NEEDS_MOCK_MODE() public {
    // Requires: morphoVault mode that returns from deposit() having minted 0
    // shares while consuming exactly `assets` (so leakage check passes and the
    // sharesAfter<=sharesBefore check is the binding one). Add setZeroShares(bool)
    // to MockMorphoVault if this branch must be covered.
    vm.skip(true);
}


// ── ZeroOutput on the USDC->WETH leg (line ~905) ─────────────────────────────
// V3 router returns 0 WETH. Caller min = 0 so the contract's ZeroOutput guard
// (not the caller floor) is the binding revert.
function test_Sweep_RevertsZeroOutput_WethLeg() public {
    vm.prank(MERCHANT);
    payments.setDaiCeiling(0);

    usdc.mint(address(payments), 1000 * 1e6);
    router.setWethOut(0);            // force zero WETH output
    aeroRouter.setCbEthOut(0.31 ether);

    vm.expectRevert(PossessioPayments.ZeroOutput.selector);
    vm.prank(MERCHANT);
    payments.sweep(0, 0, 0);         // caller mins 0 so ZeroOutput is the gate
}

// ── ZeroOutput on the WETH->cbETH leg (line ~939) ────────────────────────────
// WETH leg succeeds, Aerodrome returns 0 cbETH.
function test_Sweep_RevertsZeroOutput_CbEthLeg() public {
    vm.prank(MERCHANT);
    payments.setDaiCeiling(0);

    usdc.mint(address(payments), 1000 * 1e6);
    router.setWethOut(0.31 ether);   // WETH leg succeeds
    aeroRouter.setCbEthOut(0);       // force zero cbETH output

    vm.expectRevert(PossessioPayments.ZeroOutput.selector);
    vm.prank(MERCHANT);
    payments.sweep(0, 0, 0);
}
