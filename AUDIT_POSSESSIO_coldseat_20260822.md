# Cold-Seat Audit — 2026-08-22

**Auditor:** council seat (Claude), fresh cold-seat pass under Codebyte Law + Canon of the Terminal.
**Method:** personal whole-contract reads (no static-analysis runners), cross-contract layout + sibling diffs, dedup against the 4 prior audit files. `forge build` clean (forge 1.5.1, submodules populated). Terminal available as judge; source claims labeled **MEASURED** / **DERIVED**.
**Scope this pass:** the capital-safety subsystem + the v4 hook — `ServiceAccountabilityVault`, `PossessioRail`, `PossessioAutoTarget`, `PossessioFundingVault`, `POSSESSIO_v2-6-3` (STEEL + PossessioHook). ~4,400 LOC of the 12,169 in `src/`.
**HEAD:** `main` at clone; `forge build` exit 0.

---

## One-line verdict

The audited subsystem is **sound**, with **two MEASURED Mediums**: P-1 (Payments WETH-leg oracle floor fails open under composite-feed staleness — **FIXED in this branch** with a fail-closed guard and red→green regression) and **L-1 (`PossessioLaunchFactory` v4 pool-init front-run DoS — MEASURED, Architect-gated fix pending**; a persistent liveness DoS on the public launch product, no fund loss). Also **one sibling-diff finding** (F-1, Low/Info — governance record-integrity) and three Info items (I-1 doc-drift, I-2 counter drift, S-1 L1Anchor leakage-check parity gap — benign). **`L1Anchor` (936 LOC) was sibling-diffed against P-1 and is clean** — no swap means no fail-open oracle floor, and its Symmetry Guard is a correct fail-closed one-way latch; it is in fact the better-hardened sibling on the Morpho principal counter (see I-2). **`PossessioX402Core` (858 LOC) is sound** — the seller-substitution theft vector is closed by the nonce-commitment binding, the floored draw is un-drainable, and the surplus-routing accounting was cross-contract-verified; its 64-test suite is non-vacuous. **Both factories (`PossessioFactory` 264 + `L1AnchorFactory` 334) and `PossessioSaltPool` (195) are sound** — owner is factory-written/un-spoofable, templates are codehash-pinned, fees atomic; one documented Info (G-1: CreateX salt front-run resistance rests on off-chain keeper discipline, DoS-not-drain, sharpens the existing SaltPool Q1). **`PossessioPool` (473 LOC, the shared "Heart") is sound** — a faithful valve-checked generalization of x402Core's audited pool machinery; floored draw un-drainable, floor not externally manipulable, held==poolBalance. The two prior open contract findings (V-1, R-1) are **confirmed fixed and merged at HEAD**. No custody drain and no external-attacker door in the audited set; P-1 was conditional MEV value-leakage on a swap leg.

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
| `PossessioFactory` | 264 | sound; owner factory-written/un-spoofable, template codehash-pinned (empty-codehash guarded), atomic fee, `nonReentrant`, no admin; one documented Info (G-1 salt permissioning, DoS-not-drain) |
| `L1AnchorFactory` | 334 | sound; stronger model — no caller-controlled args (all endpoints hardcoded), `MERCHANT_OWNER=msg.sender`, plain CREATE (no salt front-run surface), no fee, no admin |
| `PossessioSaltPool` | 195 | sound; pull factory-only, refill keeper-only + compute-only (no value path), keeper-separation enforced; salt-validity trusted to keeper off-chain (G-1 / Q1 open) |
| `PossessioPool` | 473 | sound; faithful generalization of x402Core's audited pool machinery (1 source → valve-checked immutable set); floored draw un-drainable, held==poolBalance, floor not externally manipulable; 32 non-vacuous tests green |
| `PossessioLaunchFactory` | 410 | PossessioFactory pattern + v4 pairing; owner un-spoofable, atomic, codehash-pinned — **but L-1 (MEASURED Medium): pool-init front-run DoS** on the added pairing step |
| `LSTExchangeRate` | 167 | sound; two-source (Chainlink + Aerodrome TWAP) halt-on-divergence, fail-closed; tick→rate math MEASURED-correct offline; TWAP manipulation halts (never mis-prices) |
| `SymmetryGuardCore` | 304 | sound; `totalFeeBps` clamped [200,500], signal non-injectable (per-(sender,pool), deterministic on-chain only), register single-use + caller-bound; 20 tests green. Fully grounds the x402Core dependency |
| `HandshakeLib` | 62 | sound; sorted-pair sha256 merkle with double-hashed leaves (domain separation vs nodes); leaf derived from caller, not supplied; 13 tests green |
| `PossessioCouncilToken` | 129 | sound; minimal OZ ERC20+Permit, fixed supply, guarded genesis, holder-burn only, **no owner/minter/pauser/fee/hook** (clean pairing denominator); 14 tests green |

---

## Findings

### L-1 (MEDIUM — MEASURED) — `PossessioLaunchFactory` v4 pool-init is front-runnable into a persistent launch DoS

- **Where:** `src/PossessioLaunchFactory.sol` `deployLaunch` step 8 (L361-370): `poolManager.initialize(key, sqrtPriceX96)` with `key.hooks = launch`, **no try/catch**.
- **Vector:** the launch address is CREATE3-deterministic and **publicly predictable** — the pre-mined salt sits in `PossessioSaltPool` storage (readable), its prefix is the factory address, so `launch = CreateX.computeCreate3Address(keccak256(factory, salt))`. The launch's hook flags are **`0x8C8`** (`BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA`) — **not** `BEFORE_INITIALIZE` — so Uniswap v4 `initialize` (permissionless) does **not** call the hook and succeeds against the still-**codeless** launch address. An attacker reads the next salt, computes the launch address + pool key `(sorted(COUNCIL_TOKEN, launch), POOL_FEE, TICK_SPACING, hooks=launch)`, and calls `poolManager.initialize` on it **first** (any price). When the victim's `deployLaunch` runs, its own `initialize` reverts `PoolAlreadyInitialized`, unwinding the whole deploy.
- **Impact:** **DoS-not-drain.** The fee is atomically refunded (no theft), but the launch never deploys, and the poisoned launch address's pool is **permanently occupied**. Because the SaltPool is **LIFO**, the same poisoned salt is re-served on the next `deployLaunch` and reverts again; an attacker can poison each fresh top-of-stack salt for one `initialize` gas cost, holding the public launch product down and permanently stranding salts/addresses. Rated **Medium** (cheap, persistent, product-level liveness DoS + permanent stranding; no fund loss).
- **The False Green (meta):** `test/PossessioLaunchFactory.t.sol`'s `MockPoolManager.initialize` does **not** model v4's per-key already-initialized revert — it re-initializes any key and only reverts when globally armed. So the DoD suite (incl. `test_atomic_poolInitReverts_unwindsAll`) is **structurally incapable** of observing this front-run. The charge "an attacker initializes the predicted pool first" was never filable against that mock.
- **MEASURED:** `test/PossessioLaunchFactory_L1PairInitFrontrun.t.sol` (new) with a **v4-faithful** PoolManager (per-key `PoolAlreadyInitialized`):
  - `test_L1_control_NoPreInit_Succeeds` → PASS (honest deploy initializes the pool once).
  - `test_L1_finding_AttackerPreInit_DoSs` → PASS: attacker pre-initializes the predicted pool (asserts `launch.code.length == 0` at that point — codeless), then the victim's `deployLaunch` reverts `PoolAlreadyInitialized`, fee refunded, salt unconsumed, launch never deployed. The sole difference between control and finding is the attacker's pre-init.
- **Fix (Architect-gated — not a self-contained in-contract one-liner, unlike P-1):** give the launch hook the **`BEFORE_INITIALIZE` flag** (mine salts to `0x8C8 | 0x2000`) and have the launch template's `beforeInitialize` reject any initialization it did not authorize. Then a pre-init against the codeless address reverts (v4 calls the absent hook), and post-deploy init is gated by the launch itself — the front-run closes. This spans the salt-mining target (keeper) + the launch template (unaudited here), so it is a design change for the Architect, not a merge I should make unilaterally. Also fix the test mock to model per-key `PoolAlreadyInitialized` so the DoD suite can see this class. Provenance: **DERIVED** fix on a **MEASURED** finding.
- **Note:** this is a NEW surface vs `PossessioFactory` (which has no pool-init step); the sibling-diff surfaced it. G-1 (salt front-run) still applies to this factory too; L-1 is the more severe, pairing-specific cousin and does **not** depend on salt mis-mining.

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

### PossessioCouncilToken (129 LOC) — SOUND (DERIVED + suite MEASURED green, 14 tests)

The settlement asset every V3 launch is paired against (immutable `COUNCIL_TOKEN` in `PossessioLaunchFactory`) and the SAV-allocation token. A minimal OpenZeppelin `ERC20 + ERC20Permit`, and deliberately nothing more.

- **Fixed supply, minted once.** The constructor mints a genesis distribution with full guards: non-empty, length-matched arrays, no zero recipient, no zero amount, no duplicates (O(n²), deploy-time only — a duplicate is a drafting error that must fail the deploy). Total supply is the exact sum (checked math; overflow reverts the deploy). `testFuzz_genesis_supplyIsExactSum` confirms.
- **No privileged surface.** No owner, minter, pauser, blacklist, upgrade path, or transfer hook. After construction the only authorities are holders over their own balances (`transfer`/`approve`/`permit`/`burn`). `test_noAuthority_strangerCannotMoveFunds` confirms.
- **Clean denominator (load-bearing for the LaunchFactory pairing).** No fee-on-transfer, no rebasing, no reflection — `testFuzz_transfer_conservesSupply` + `test_transfer_noFee_exactAmounts` confirm. A fee/rebasing pairing token would corrupt the v4 pool math the LaunchFactory builds against; this token is inert exactly where it must be.
- **Supply only falls.** `burn` reduces only the caller's own balance (OZ `_burn`, reverts on insufficient); no post-construction mint. EIP-2612 permit is standard OZ (nonce + chainid-rebuilt domain separator), adds no authority beyond a holder's own signature.

No finding. This is the minimal-surface settlement asset the spec intends.

### SymmetryGuardCore (304) + HandshakeLib (62) — SOUND (DERIVED + suite MEASURED green, 33 tests)

The behavioral-fee base under `PossessioX402Core` (its `totalFeeBps` / `_observe`) — previously trusted at the interface level, now read in full. No fund custody; it computes a toll bps and a per-(sender,pool) behavioral signal.

- **The load-bearing invariant holds: `totalFeeBps ∈ [200, 500]`.** `_assess` = `BASE_FEE_BPS(200) + roundTripPenalty + dustPenalty`, each penalty individually capped at `HEADROOM(300)` and the sum clamped to `MAX_TOTAL_FEE_BPS(500)`; floor is always the base. This is exactly the bound x402Core's `expectedValue = basePrice·(1 + tollBps/1e4)` relies on — a toll shift can only move the price into `[+2%, +5%]` and only ever cause a `settleCall` **revert** (liveness), never a mis-settle.
- **Signal is non-injectable (DECISION B).** `_guard[keccak(sender,poolId)]` is written **only** by `_observe`, from on-chain facts (sender/pool/direction/size/block); no owner or human path. Keyed per (sender,pool), so an attacker cannot bump a victim's fee — `test_attacker_flood_cannot_inflate_victim` confirms. In x402Core, `_observe(caller,…)` runs only inside `settleCall`, which needs the buyer's own signature, so a victim's guard state can't be moved by anyone else.
- **Register (handshake) is caller-bound + single-use.** The leaf is reconstructed from `msg.sender` (never accepted from calldata — the comment explicitly forbids that refactor, which would reopen the copy-and-race front-run), the nullifier `consumed[leaf]` prevents replay, and the merkle proof is checked against the immutable `HANDSHAKE_ROOT` (proof length bounded [1,64]).
- **HandshakeLib** is a sorted-pair **sha256** merkle verify with **double-hashed leaves**: the leaf's outer preimage is 32 bytes vs a node's 64 bytes → domain separation closes the classic node-as-leaf second-preimage attack; and since `register` derives the leaf, an attacker can't supply a crafted one anyway. sha256 (not keccak) is a deliberate choice to moot the mempool-exposed-leaf terminal attack.
- **Punishment is bounded + self-curing** via read-time decay (`_decayedShapeHits` / `_decayedDustHits`) — every flag/penalty read decays first, so a stale-high stored counter can't over-charge.

**Observation (non-finding, deliberate):** the DustSpam constants (`DUST_SPAM_*`) are flagged **PROVISIONAL** in-code — a false-positive on honest high-frequency small traders would charge up to 5% instead of 2% (bounded, self-curing, fee-only, no fund risk). Explicitly calibration-gated before the mainnet freeze; Architect's to tune. Not a finding.

### LSTExchangeRate (167 LOC) — SOUND (DERIVED + math MEASURED offline)

The shared cbETH→ETH valuation oracle (consumed by `PossessioPayments`: the sweep gauge L1108 and the view gauge L1235). Base cbETH is an OptimismMintable bridge token with no native `exchangeRate()`, so this values cbETH from **two independent sources and halts on disagreement**.

- **Fail-closed guards, correct discipline.** `_oracleRateWethPerCbEth` reverts on `answer<=0`, `updatedAt==0`, `answeredInRound<roundId`, or staleness (>24h). The divergence breaker reverts `RateDivergence` when |oracle−market| exceeds 2% of the oracle rate. Same "halt on uncertainty" pattern as the hook and L1Anchor.
- **TWAP manipulation can only HALT, never mis-price.** The 30-min Aerodrome TWAP (deep pool, cardinality ~1440) is compared against the Chainlink feed; moving the pool away from Chainlink trips the 2% breaker → revert. To mis-value, an attacker would have to move Chainlink too, which pool trades can't. So the worst case is a transient valuation halt, not a wrong price.
- **Decimals + tick math verified.** Both cbETH and WETH are 18-dec so the raw `1.0001^tick` is already the 18-dec WETH-per-cbETH rate (no adjustment); the feed's 18-dec is a hardcoded, cast-verified constant. `_getSqrtRatioAtTick` is canonical Uniswap v3 TickMath; `_tickToRate18` computes `(sqrtP·1e9>>96)²  = price·1e18`, algebraically exact, with ~2e-9 relative rounding — far inside the 2% band, and no overflow across the full tick range.
- **The jurisdiction gap I filled:** the repo shipped only `LSTExchangeRateFork.t.sol`, so the pure tick→rate math was exercised **only against the live fork**, never pinned offline — exactly where a decimal misscale would hide. New `test/LSTExchangeRateMath.t.sol` (5 tests, green) pins it: tick 0 → **exactly 1e18** (scaling anchor), strictly monotonic, reciprocal `rate(t)·rate(−t) ≈ 1e36`, realistic cbETH tick 1247 → **~1.1327e18** (matches the header's cast-confirmed live rate, proving no misscale), and tick 1 resolves above 1e18 (no truncation).

**Observation (non-finding, deliberate):** O-1 — the sweep's success is coupled to LST oracle health: `cbEthToEth` reverts (stale/divergence) propagate through `_sweep`'s **informational** gauge update (L1108) and revert the whole sweep. This is fail-safe and retryable (no fund risk) and consistent with halt-on-uncertainty, but since the gauge value drives no fund-moving decision, the Architect could wrap it in try/catch (as `_computeCurrentEthEquivalent` L1235 already does) so an informational-gauge hiccup doesn't block an otherwise-valid sweep. Minor robustness; intentional as-is.

### PossessioPool (473 LOC) — SOUND (DERIVED + suite MEASURED green, 32 tests)

The shared "Heart" pool. Explicitly a **relocation** of `PossessioX402Core`'s already-audited v0.6 pool machinery, with exactly one generalization: the single immutable `deploymentFeeSource` becomes an immutable **set** `isAuthorizedSource`. I diffed the lift against the x402Core original (already audited sound this pass) and re-derived the generalized surface cold.

- **Multi-source valve integrity holds.** The constructor valve-checks **every** source (`src != operatorDestination && src != treasuryDestination`), rejects zero, and rejects duplicates (`DuplicateSource`) / empty set (`EmptySourceSet`). The set is immutable — no setter, no admin, no owner. So no inflow source can also be an outflow destination; ingress-from-the-outflow-side stays structurally impossible.
- **`receiveInfraFunds` only ever adds.** An authorized organ can donate (fills to cap, exact surplus one-way to `treasuryDestination`), never withdraw — it has no path that pays the caller. CEI preserved (balance + surplus committed before the outbound push). The sole outflow is `settleOperationalCosts`, operator-only, floored (`poolBalance − getRunningMinimumFloor()`), un-drainable below `ABSOLUTE_FLOOR` — identical to the x402Core original.
- **Floor is not externally manipulable.** Velocity is bumped only inside `receiveInfraFunds`, callable only by the immutable trusted organs — an external attacker can neither inflate nor deflate it (decay is time-only). Worst case is a *compromised authorized organ* spamming inflows to raise the floor, which only **locks funds in** (never drains) and decays back down — inherent to the velocity-floor design, errs safe.
- **Held-USDC == poolBalance** across every path (donations sent raw are dead weight, not credited — asserted by `test_dod14_rawTransferNotCredited`). No `receive`/`fallback`/`payable`; USDC-only.
- **Cosmetic-only divergence in the lift:** `settleOperationalCosts` reverts the non-operator caller with `NotAuthorizedSource` (the inflow error) where x402Core used `UnauthorizedCall`. Functionally identical (both revert); no behavioural impact. Not charged.

Suite is non-vacuous: valve-integrity constructor reverts (dup/empty/source==operator/source==treasury/zero), `test_dod9_treasuryAndOperatorCannotFeedIn`, one-way surplus exactness, floored draw, `test_dod6_floorRisesWithVelocity_operatorCannotLower`, decay monotonic-to-baseline, raw-transfer-not-credited. 32 green at HEAD.

### Factories (`PossessioFactory` 264 + `L1AnchorFactory` 334 + `PossessioSaltPool` 195) — SOUND (DERIVED + suite MEASURED green, 77 tests)

Both factories mint every merchant deployment, so a factory bug multiplies. Neither has one. Key surfaces:

- **`PossessioFactory` owner is un-spoofable.** `deployTemplate` rejects `owner == 0` and `owner == address(this)`, then writes `owner` as the first constructor word of `bytes.concat(initCode, abi.encode(owner, initArgs))` — a separate ABI head word the caller's `initArgs` cannot overwrite, and the templates (e.g. `PossessioPayments`) further override any decoded owner with `_factoryOwner`. Belt-and-suspenders; verified from both sides.
- **Template is codehash-pinned.** `keccak256(initCode) == templateCodehash` gates before any fee/salt is consumed; the degenerate `EMPTY_CODEHASH` case is rejected at construction (any `initCode==""`/args-as-code attack closed).
- **Atomic fee.** EIP-3009 settle (`to==this`, front-run-closed) → `forceApprove` + `receiveInfraFunds` (pool pulls exactly `DEPLOYMENT_FEE`) → `pullSalt` → CreateX deploy. Any downstream revert (codehash, CreateX collision, template-constructor revert) unwinds the whole tx — fee and salt-pop included. The caller is never charged for a failed deploy; no salt is burned on failure.
- **Caller controls `initArgs` (their own instance's config), not the code or owner.** This is the intended generic-template model ("deployable from the launch rail by someone who never sees an ABI"). A merchant can only misconfigure their *own* sovereign instance — no cross-merchant harm, and a third party cannot inject `initArgs` into a victim's transaction. Trust for config-correctness sits with the launch rail (standard frontend-trust assumption), **not** the contract. Contrast `L1AnchorFactory`, which hardcodes every endpoint as an immutable so even self-misconfiguration is impossible — a strictly stronger guarantee, appropriate because its integration is a single fixed institutional target rather than a multi-tier template.
- **`L1AnchorFactory` uses plain `new L1Anchor(...)` (CREATE, sequential nonce)** → no deterministic-address front-run surface at all; `MERCHANT_OWNER = msg.sender`; registry append-only; no fee, no value movement, no admin.

### G-1 (INFO / DoS — sharpens SaltPool Q1) — CreateX salt front-run resistance depends on off-chain keeper discipline, not enforced on-chain

- **Mechanism:** `PossessioFactory.deployTemplate` deploys via `CREATEX.deployCreate3(salt, …)` with a salt from `PossessioSaltPool.pullSalt()`. CreateX's `_guard` makes the deployed address **sender-dependent iff the salt's leading 20 bytes equal the caller**: for the factory, `guardedSalt = keccak256(factory, salt)` — an attacker replaying the same salt gets the *permissionless* `keccak256(salt)` (a different address), so they **cannot** pre-occupy the factory's intended address. Front-run is structurally closed **as long as every pooled salt is mined with prefix == factory** (exactly what the SaltPool header intends: "each valid for the factory's fixed deployer address").
- **The gap:** `refillSalts` does **not** validate on-chain that each salt's prefix == factory (nor the 0x8C8 suffix) — validity is trusted to the keeper's off-chain mining (SaltPool open question **Q1**; duplicate-salt is the separate **Q1b**). If the keeper ever pushes a salt with a zero/random prefix, that salt is permissionless for *everyone including the factory*, and an attacker who observes it (it is emitted in `SaltPulled` / sits in the queue) could pre-deploy to the derived address and make the merchant's `deployTemplate` revert on CreateX collision.
- **Impact: DoS-not-drain.** A front-run only *blocks* a deploy (fee unwinds atomically, no charge); it cannot redirect funds or hand the merchant a substituted contract (they get a revert, never the attacker's address). Bounded to griefing of the deploy rail.
- **Recommendation (Architect's call, folds into Q1):** when Q1's on-chain salt validation is decided, have `refillSalts` require `bytes20(salt) == bytes20(uint160(factory))` (the CreateX msg.sender-permission prefix) in addition to the 0x8C8 address-suffix check — that single check is what actually closes the front-run, converting "keeper trusted to mine permissioned salts" into "contract verifies it." Provenance: **DERIVED** (CreateX `_guard` semantics + SaltPool source).

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

- **The V3 launch template is NOT in this repository (scope boundary, MEASURED):** `script/DeployLaunchFactory.s.sol` pins `templateCodehash` from the env var `TEMPLATE_CODEHASH` at deploy time, and no `src/` contract has the `constructor(address, bytes)` factory-template shape except `PossessioPayments` (the payments-tier template). The launch tests use placeholder templates (`MockLaunchTemplate` / `ForkLaunchTemplate`) that explicitly *implement no hook functions*. So the production launch template — the owner's 2% fee engine and the intended home of L-1's `beforeInitialize` gate — is supplied out-of-repo and **cannot be audited here**. **Implication for L-1:** its fix (BEFORE_INITIALIZE flag + gated `beforeInitialize`) is blocked on that template being written; and a template deployed from an unaudited, env-supplied codehash is itself a deploy-time trust dependency the Architect should pin to a reviewed contract.
- **Not yet read this pass (follow-on):** `PLATE`/`PLATEStaking`, `PossessioWhiskyMarket`, `PossessioAutoTarget` fork behavior, `PossessioTestnetLaunchPool`. ~4,750 LOC.
- **Assumptions:** STEEL/PLATE and USDC are standard ERC-20 (no fee-on-transfer / rebasing) — asserted from `STEEL` source (clean ERC20, no custom transfer). External venues (Aerodrome, Uniswap v4 PoolManager, Chainlink feeds, EIP-3009 USDC) behave to interface. The v4 hook fee-delta algebra is read-correct but is best proven by the repo's own differential/fork suites, not re-derived here.
- **MEASURED vs DERIVED:** verdicts are DERIVED (full source reads) except the `forge build` clean and the two prior fixes' presence, which are MEASURED from HEAD. F-1 is DERIVED and can be promoted to MEASURED with a red→green test on request.

---

*If it can't be tested it doesn't exist. If it's not in the terminal it's not proven. Protocol protection above all else.*
