# Cold-Seat Audit — 2026-08-22

**Auditor:** council seat (Claude), fresh cold-seat pass under Codebyte Law + Canon of the Terminal.
**Method:** personal whole-contract reads (no static-analysis runners), cross-contract layout + sibling diffs, dedup against the 4 prior audit files. `forge build` clean (forge 1.5.1, submodules populated). Terminal available as judge; source claims labeled **MEASURED** / **DERIVED**.
**Scope this pass:** the capital-safety subsystem + the v4 hook — `ServiceAccountabilityVault`, `PossessioRail`, `PossessioAutoTarget`, `PossessioFundingVault`, `POSSESSIO_v2-6-3` (STEEL + PossessioHook). ~4,400 LOC of the 12,169 in `src/`.
**HEAD:** `main` at clone; `forge build` exit 0.

---

## One-line verdict

The audited subsystem is **sound**, with **one MEASURED Medium** on the live-product payment processor (P-1 — WETH-leg oracle floor fails open under composite-feed staleness), **now FIXED in this branch** with a fail-closed guard and a red→green regression suite. Also **one sibling-diff finding** (F-1, Low/Info — governance record-integrity) and three Info items (I-1 doc-drift, I-2 counter drift, S-1 L1Anchor leakage-check parity gap — benign). **`L1Anchor` (936 LOC) was sibling-diffed against P-1 and is clean** — no swap means no fail-open oracle floor, and its Symmetry Guard is a correct fail-closed one-way latch; it is in fact the better-hardened sibling on the Morpho principal counter (see I-2). **`PossessioX402Core` (858 LOC) is sound** — the seller-substitution theft vector is closed by the nonce-commitment binding, the floored draw is un-drainable, and the surplus-routing accounting was cross-contract-verified; its 64-test suite is non-vacuous. The two prior open contract findings (V-1, R-1) are **confirmed fixed and merged at HEAD**. No custody drain and no external-attacker door in the audited set; P-1 was conditional MEV value-leakage on a swap leg.

---

## Contracts audited (this pass)

| Contract | LOC | Verdict |
|---|---|---|
| `ServiceAccountabilityVault` | 359 | sound **except F-1** (missing F3 amount-binding) |
| `PossessioRail` | 602 | sound; V-1/R-1 fixes merged at HEAD; AutoTarget tuple layout verified |
| `PossessioAutoTarget` | 485 | sound (non-custodial, linear lifecycle, atomic fee) |
| `PossessioFundingVault` | 445 | sound (exact `outstanding`, CEI, asymmetric caps) |
| `POSSESSIO_v2-6-3` (STEEL + Hook) | 2223 | sound; all historical fixes (M-1/C-1/C-4/C-5/FIX-3) present & correct |
| `PossessioPayments` | 2118 | sound custody rails **except P-1** (WETH-leg floor fail-open, MEASURED Medium); daily-limit + guardian-freeze + 7-day emergency design solid |
| `L1Anchor` | 936 | sound; **clean of P-1** (no swap → no oracle floor; Symmetry Guard is fail-CLOSED one-way latch); one Info parity gap (S-1) |
| `PossessioX402Core` | 858 | sound; seller-substitution closed (nonce-commitment + registry cross-check), floored draw un-drainable, valve-by-omission structural, surplus routing cross-contract-verified; 64 non-vacuous tests green |

---

## Findings

### F-1 (LOW / record-integrity) — standalone SAV `invent()` lacks the F3 amount-binding its hook sibling enforces

- **Where:** `src/ServiceAccountabilityVault.sol` `invent(uint256 amount, bytes32 proposalHash, bytes metadata)` (≈L256-285).
- **Sibling that has the guard:** `src/POSSESSIO_v2-6-3.sol` `executeInvent` (L2077):
  `if (proposalHash != keccak256(abi.encode(address(this), amount, metadata))) revert ProposalHashMismatch();`
- **Defect:** the standalone `invent` treats `proposalHash` as an opaque key and does **not** bind it to the executed `amount`/`metadata`. A 3-of-4 council approval of a hash therefore does **not** constrain the amount the Treasury deducts from the four `claimable` balances against it.
- **Impact:** **not a drain** — `onlyTreasury`, funds go to `TREASURY_SAFE`, bounded by `claimable`. It is a **governance accountability gap**: the council's ratification does not cryptographically bind the amount, which is precisely the property F3 (council 2026-07-20) was written to guarantee in the hook. The two SAV implementations should be consistent.
- **Fix:** mirror the hook's F3 line in the standalone `invent` — require `proposalHash == keccak256(abi.encode(address(this), amount, metadata))`.
- **Open question for the Architect (unresolvable from source):** which SAV is the operational on-chain council vault — the standalone or the hook-embedded one? If the hook's is operational, the standalone is a legacy inconsistency; if the standalone is deployed, F-1 is live. Provenance: **DERIVED** (two code sites compared; MEASURE-able with a red→green test against the standalone `invent` on request).

### P-1 (MEDIUM — MEASURED — **FIXED at HEAD**) — `PossessioPayments` sweep WETH-leg oracle floor **fails open** on composite-feed staleness

> **Status:** patched in this branch. `_sweep` now fails closed — `if (wethFloor == 0) revert OracleStale();` immediately after the WETH-floor computation (L989), symmetric with the cbETH gate. Pinned by the P-1 regression suite and by two updated Gauntlet tests that had been silently relying on the fail-open (they refreshed cbETH/DAI feeds but not the composite USDC/ETH feeds, and swept anyway — the bug in the wild). `forge test` on all Payments-touching suites: 206 + 14 green.

- **Where:** `src/PossessioPayments.sol` `_sweep`, cbETH leg sub-leg 1 (USDC→WETH), L987–988:
  ```solidity
  uint256 wethFloor = (_usdcToEth(cbEthAlloc) * SWEEP_SLIPPAGE_BPS) / SWEEP_SLIPPAGE_DENOM;
  uint256 wethMin   = minWethOut > wethFloor ? minWethOut : wethFloor;
  ```
- **Defect:** `_usdcToEth` (L1146) is the source of the WETH-leg's H-1 oracle floor, and it is **fail-open**: on a stale/invalid USDC/USD **or** ETH/USD Chainlink feed it `return 0` (L1158–1166, L1177–1185) instead of reverting. When it returns 0, `wethFloor = 0`, so `wethMin = max(minWethOut, 0)`. The Automation-supplied `minWethOut` is `sweepSlippageMinWeth`, which **defaults to 0** (public uint, never set until an operator calls `setSweepSlippageGuards`). Net: the USDC→WETH swap executes with `amountOutMinimum = 0` — no slippage protection — the exact H-1 condition the v2.4.3 fix was written to close.
- **Why it's reachable while the sweep still runs:** the only feed that *gates entry* is cbETH/ETH via `_validateOracle` (L1745), which is **fail-closed** (reverts `OracleStale`) with a **25h** window (`ORACLE_STALE_CBETH = 90_000`). The WETH-floor feeds use a **1h** window (`ORACLE_STALE = 3_600`) and **fail open**. Any moment in the 1h–25h gap where USDC/USD or ETH/USD has not refreshed but cbETH/ETH has → the sweep proceeds and the WETH floor is silently 0. Dual asymmetry: *fail-open vs fail-closed* **and** *1h vs 25h window*.
- **Impact:** MEV sandwich on the USDC→WETH acquisition leg (Uniswap V3 0.05% USDC/WETH). Bounded by one sweep's `cbEthAlloc` (default 50% of the swept batch) and pool depth; not a full custody drain, and the yield-bearing balance stays in-contract as cbETH. Rated **Medium** (conditional value leakage, MEV-extractable, requires composite-oracle staleness + default/loose `minWethOut`). Live-product contract (taproot.possessio.io), so operationally material.
- **The False Green:** `test/PossessioPayments_H1Slippage.t.sol` proves the floor's teeth **only under all-feeds-fresh** — every test re-stamps all four feeds to `block.timestamp` before sweeping (L269–272, 298–301, 318–321, 341–344). The suite's own comment notes the floor path now reads `_usdcToEth`, yet never files the charge "does the WETH floor hold when the composite feed is stale but cbETH/ETH is fresh?" Green suite = innocence of charges filed; this charge was missing.
- **MEASURED:** `test/PossessioPayments_P1CompositeOracleFailOpen.t.sol` (new, files the missing charge). Contrast pair on clean HEAD:
  - `test_P1_control_FreshComposite_SandbagReverts` → PASS (fresh floor rejects a 0.05-ETH sandbag vs ~0.15-ETH floor).
  - `test_P1_finding_StaleComposite_SandbagAccepted` → PASS (same sandbag **accepted**, sweep completes) with only USDC/USD stale.
  - Non-vacuity proven: a temporary `if (wethFloor == 0) revert OracleStale();` fail-closed patch flips the finding test to **RED** (`FAIL: OracleStale()`) while the control stays green; patch reverted, contract at true HEAD (zero git diff).
- **Fix options (Architect's call):** (a) make the WETH-floor path fail-closed — `if (cbEthAlloc > 0 && wethFloor == 0) revert OracleStale();` — so a stale composite feed blocks the sweep exactly as a stale cbETH feed does; or (b) have `_usdcToEth` revert (not return 0) when consumed for the floor; or (c) enforce a non-zero `sweepSlippageMinWeth` before automation is allowed to run. Option (a) is the smallest, most symmetric change.
- **Sibling note (follow-on):** `L1Anchor.routeToMorpho` shares the dual-acquisition lineage; the header flags parity gaps "may exist in L1Anchor." Its slippage-floor oracle handling should be diffed against this same fail-open pattern.

### I-1 (INFO) — stale `rescueToken` NatSpec references the removed DAI reserve

- `src/POSSESSIO_v2-6-3.sol` `rescueToken` NatSpec (≈L2161) lists "DAI (protocol emergency reserve)" among protected tokens, but the DAI leg was removed (v3) and the code blocks only STEEL/cbETH/WETH. No security impact (DAI is never held). Comment cleanup only.

### S-1 (INFO — sibling-diff) — `L1Anchor.routeToMorpho` lacks the USDC-consumption leakage check its Payments sibling has

- **Where:** `src/L1Anchor.sol` `routeToMorpho` (L538–559) vs `src/PossessioPayments.sol` `_sweep` Morpho leg (L1069–1072).
- **Diff:** Payments reverts `LeakageDetected` unless `(usdcBefore − usdcAfter) == morphoAlloc` (v2.4.1 Plate finding). L1Anchor performs the share-delta check (`sharesAfter <= sharesBefore → revert`) but **not** the USDC-consumption equality check.
- **Not exploitable:** `USDC.forceApprove(vault, amount)` bounds the vault's `transferFrom` at exactly `amount`, and the allowance is reset to 0 immediately after the deposit — the vault cannot pull more than `amount`, and no allowance dangles. The only behaviour the missing check permits is *under*-consumption, which leaves harmless leftover USDC in the merchant's own contract (re-routable, never lost). **Info-level defense-in-depth parity gap; no fund risk.** Provenance: DERIVED (two code sites compared).
- **Verdict on the header's warning:** the Payments header flagged that Morpho-leg parity gaps "may exist in L1Anchor." Confirmed — this is the gap, and it is benign. The MAVAN leg (`routeToMavan`) is analogous and equally benign (approval-bounded, share-delta-checked).

### PossessioX402Core (858 LOC) — SOUND (DERIVED + suite MEASURED green)

The x402 settlement core is sound. Heavily pre-audited (multiple council seats + a Sonnet-5 cold seat + v0.6 fixes); this pass re-derived the security-critical surfaces cold and ran the suite as judge.

- **Seller-substitution (the SEAM 2 theft vector) is closed, two independent lines.** `settleCall` binds the EIP-3009 `nonce` to `keccak256(seller, channelId, value, salt)` (L478–479): the buyer computes that commitment at signing time, so the EIP-712 signature (which covers `nonce`) indirectly covers `seller+channelId+value`. keccak preimage-resistance means a permissionless submitter cannot substitute `seller` without breaking either the commitment (here) or the signature (inside `receiveWithAuthorization`). A registry cross-check (`seller == channelSeller[channelId]`, L468) is the defense-in-depth first line. Exact-equality value binding (L473) permits neither underpay nor overpay — a toll shift between quote and settle can only *revert* (liveness), never mis-settle.
- **Floored draw is un-drainable.** `settleOperationalCosts` (L723) releases at most `operationalPoolBalance − getRunningMinimumFloor()` to the immutable operator; the floor is `ABSOLUTE_FLOOR + (decayedVelocity/1e18)·FLOOR_PER_UNIT`, derived from settlement throughput the operator cannot move (velocity only rises on settlement, decays with time). Pool can never be drawn below `ABSOLUTE_FLOOR`. Decay linear-interpolation errs toward a *higher* floor (FIX #4; `test_decay_errs_high_vs_exponential` confirms).
- **Valve-by-omission is structural.** No function moves funds whose source is `heartSink`/`operatorDestination` back inward; the constructor reverts `ValveIntegrityViolation` if `deploymentFeeSource` equals either outbound destination (v0.6 FIX #1), and a brick-guard proves `heartSink` implements the accounted door before freeze.
- **Surplus routing cross-contract-verified (MEASURED from source).** `settleCall`/`registerOpen`/`receiveDeploymentFee` de-account surplus to the cap and `forceApprove(heartSink, surplus)` + `receiveInfraFunds(surplus)`; `PossessioPool.receiveInfraFunds` (L266–273) `safeTransferFrom`s exactly `surplus`, fully consuming the approval — no dangling allowance, no stranded funds, held-USDC == `operationalPoolBalance` invariant holds.
- **Suite is non-vacuous (unlike the H-1 false green):** `test_sellerSubstitution_reverts`, `test_nonceCommitmentMismatch_reverts` (wrong-salt), `test_operatorCannotDrainBelowFloor` (drawable+1), `test_operatorDrawSurplus_succeeds_thenFloorHolds` (draw-all → pool sits at floor → +1 reverts), `test_deploymentFee_overCap_routesToHeart` (asserts Heart holds surplus USDC). 64 tests green at HEAD.

**Observations (non-findings, deliberate tradeoffs — recorded, not charged):**
- No USDC rescue function: a direct token donation to x402Core is not counted in `operationalPoolBalance` and is not drawable (draw math is accounting-based) → permanently stranded. This is the **accepted cost of valve purity** — any rescue door would itself be an egress path violating valve-by-omission. Not a drain (stranded ≠ stealable).
- **Channel first-claim squatting** (STILL-OPEN governance, already flagged in-code): anyone can claim any unclaimed `channelId`. A squatter cannot *redirect* a payment (the buyer only signs the real seller, so a mismatch reverts `SellerMismatch`) — the worst case is **DoS of a channel namespace**, not theft. Governance decision (claim fee / registered-gate) is the Architect's, per the in-code TODO.
- Floor param calibration (`ABSOLUTE_FLOOR`, `FLOOR_PER_UNIT`, `VELOCITY_HALFLIFE`, `OPERATIONAL_CAP`) is data-gated before freeze (DoD #22) — mis-calibration errs *safe* (over-floor locks funds in, never opens a drain).

### L1Anchor sibling-diff — positive results (MEASURED-from-source)

- **P-1 has no analog in L1Anchor.** No DEX swap → no `_usdcToEth`, no `amountOutMinimum`, no oracle-derived slippage floor to fail open. The only oracle (cbETH/ETH) drives the Symmetry Guard, which is **fail-closed**: every bad-oracle condition (revert, staleness, future-timestamp, incomplete round, non-positive answer, below-threshold price) latches `depegPaused=true` (one-way; cleared only by `resetDepeg()` on verified-good data). This is the correct inverse of P-1.
- **`morphoDepositedPrincipal` is correctly decremented** in L1Anchor (`withdrawFromMorpho` L627–631, `emergencyUnwind` L717–721, Delta-Verification), **which reframes Payments I-2**: L1Anchor is the reference implementation; Payments' write-only counter is the divergent one. See I-2.
- Withdrawals ungated by the guard (merchant sovereignty), delta-verified against contract balance rather than external return values; `emergencyUnwind` best-effort per-leg with stranded-principal accounting; no admin, no upgrade, per-merchant; all state-changers `nonReentrant`.

### I-2 (INFO) — `PossessioPayments.morphoDepositedPrincipal` is a write-only counter that drifts high

- `morphoDepositedPrincipal` (L452) is incremented in `_sweep` (L1083, `+= morphoAlloc`) but **never decremented** on `redeemMorpho` and **never read** in any safety-critical path — the treasury gauge (`_computeCurrentEthEquivalent`) values the Morpho leg from live `MORPHO_VAULT.balanceOf → convertToAssets`, not from this counter. So it is purely an informational cumulative-deposit tally; after redemptions it overstates the current position. No accounting or custody impact — record it so a future consumer doesn't mistake it for the current principal.
- **Sibling-diff:** the L1 sibling `L1Anchor` has an identically-named `morphoDepositedPrincipal` that **is** correctly decremented on every unwind path (Delta-Verification). Payments diverged from that pattern. If a future version reads this counter (e.g. for a principal-vs-value yield display), mirror L1Anchor: decrement `morphoDepositedPrincipal` in `redeemMorpho` by the redeemed principal (floored at zero). Low priority while the counter stays unread.

---

## Dedup verifications (prior findings, re-checked at HEAD — MEASURED from source)

- **V-1 (was MEDIUM, Rail honeypot un-closeable → `outstanding` ratchet):** FIXED and merged — `PossessioRail.abandon()` (L380-392): owner-only, closes without a swap, zero-proceeds `returnProceeds(id, 0)`, decrements `openByToken`. The vault side supports it (`returnProceeds(id, 0)` → `outstanding -= drawn`, no transfer).
- **R-1 (was LOW, Rail `sweep` strips a live token):** FIXED and merged — `sweep` (L529-537) reverts `TokenBacksOpenPosition` when `openByToken[token] != 0`.
- **Hook historical fixes verified present & correct:** M-1 (`sqrtPriceX96²` staged through `FullMath.mulDiv`, no overflow); C-1 (value-based harvest: excess over `cbETHPrincipalETH`, dust-floor gated, leakage-checked); C-4 (caller reward carved from `total` before split, paid last); C-5 (`FeeCaptured` logs `sender`); FIX-3 (`performUpkeep` replay key on `block.number`).

## Positive controls confirmed (MEASURED from source; would be MEASURED-in-terminal with targeted tests)

- SAV/embedded-SAV accounting conserves (`Σ claimable` tracks balance; spend reduces both equally; slash zeroes all + burns balance).
- Rail `openByToken` counter balanced (+1 enter, −1 each close path; remote legs correctly untouched); measurement rule honest (pre-draw snapshot, net-zero after handoff, concurrent Base flows net to zero).
- FundingVault `outstanding` clears exactly the original draw regardless of P&L; `available() == balanceOf` correct under physical-transfer custody; asymmetric caps (decrease-instant / raise-24h).
- AutoTarget non-custodial (balance 0 after `openIntent`), linear lifecycle, EIP-3009 fee front-run-closed (`to == this`).
- Hook POL enforced (external LP denied), oracle reads fully health-guarded (round completeness + staleness + positive), X-LINK consume-immediately (invariant_XLinkAlwaysConsumed surface exposed).

---

## Non-Proven Scope (Codebyte Results Statement)

- **Not yet read this pass (follow-on):** `PossessioPool` (473 — partially read: `receiveInfraFunds`/`isInfraSink` verified for the x402 surplus-routing invariant; velocity-floor + rest not yet fully audited), `PossessioLaunchFactory` (410), `PossessioFactory` (264), `L1AnchorFactory` (334), `PLATE`/`PLATEStaking`, `PossessioWhiskyMarket`, `PossessioSaltPool`, `LSTExchangeRate`, `SymmetryGuardCore` (base of x402Core — its DustSpam/RoundTrip guard read at the interface level via `totalFeeBps`/`_observe`, not yet fully audited), `PossessioCouncilToken`, `HandshakeLib`, `PossessioAutoTarget` fork behavior, `PossessioTestnetLaunchPool`. ~6,850 LOC.
- **Assumptions:** STEEL/PLATE and USDC are standard ERC-20 (no fee-on-transfer / rebasing) — asserted from `STEEL` source (clean ERC20, no custom transfer). External venues (Aerodrome, Uniswap v4 PoolManager, Chainlink feeds, EIP-3009 USDC) behave to interface. The v4 hook fee-delta algebra is read-correct but is best proven by the repo's own differential/fork suites, not re-derived here.
- **MEASURED vs DERIVED:** verdicts are DERIVED (full source reads) except the `forge build` clean and the two prior fixes' presence, which are MEASURED from HEAD. F-1 is DERIVED and can be promoted to MEASURED with a red→green test on request.

---

*If it can't be tested it doesn't exist. If it's not in the terminal it's not proven. Protocol protection above all else.*
