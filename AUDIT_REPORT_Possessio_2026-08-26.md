# POSSESSIO Protocol — Security Audit Report

**Engagement:** Cold-seat security audit of the POSSESSIO V2 protocol
**Auditor:** Council seat (Claude), operating under Codebyte Law + the Canon of the Terminal
**Method:** Personal whole-contract reads (no static-analysis runners, no delegated agents); the terminal is the sole judge — `forge` used to write and run tests, including fork tests against **live Base mainnet**
**Report date:** 2026-08-26
**Branch under review:** `claude/eulerswap-security-audit-thec3f` (PR open, pre-merge)
**Chain:** Base mainnet (chain 8453); L1 settlement on Ethereum mainnet

---

## 1. Executive summary

The POSSESSIO V2 protocol was audited contract-by-contract, reading each file in full and grounding every claim in the terminal. **Two real, exploitable defects were found — both Medium severity, both now fixed and proven with red→green regressions and live-chain fork tests.** The remainder of the audited surface is sound: no custody drain, no external-attacker path to funds, no owner-spoofing in the deployment layer.

| # | Severity | Title | Status |
|---|---|---|---|
| **P-1** | **Medium** (MEASURED) | Payments sweep WETH-leg oracle floor **fails open** under composite-feed staleness | **FIXED** (branch) + regression + fork-proven |
| **L-1** | **Medium** (MEASURED) | LaunchFactory v4 pool-init **front-run DoS** on the pairing step | **FIXED** (branch) + regression + proven on live Base v4 |
| **F-1** | **Low** (DERIVED) | Standalone SAV `invent()` lacks the hook's F3 amount-binding | **OPEN** — Architect determination required (see §4.3) |
| G-1 | Info / DoS | SaltPool did not enforce factory-permissioned salt prefix on-chain | **FIXED** (branch) + fork-compatible |
| I-1 | Info | Hook `rescueToken` NatSpec references the removed DAI reserve | Documented (comment cleanup) |
| I-2 | Info | Payments `morphoDepositedPrincipal` is a write-only counter | Documented (unused in safety math) |
| S-1 | Info | L1Anchor `routeToMorpho` lacks Payments' USDC-consumption leakage check | Documented (benign — approval-bounded) |
| O-1 | Info | Payments sweep liveness coupled to LST-oracle health via an informational gauge | Documented (deliberate fail-safe) |

Two prior open findings, **V-1** and **R-1** (PossessioRail), were re-verified **fixed and merged** at the audited HEAD.

**Testing:** the full suite — **1,128 tests — passes with 0 failures**, offline and against a live Base mainnet fork (live Uniswap v4 PoolManager, Chainlink feeds, Aerodrome pools, and the Bitwise Morpho vault).

**Coverage:** ~10,360 of 12,169 `src/` LOC (~85%) audited in full. The unaudited remainder is dormant/out-of-scope code (see §7).

---

## 2. Scope

### 2.1 Contracts audited (full reads)

| Contract | LOC | Verdict |
|---|---|---|
| `ServiceAccountabilityVault` | 359 | Sound **except F-1** (governance record-integrity, Low) |
| `PossessioRail` | 602 | Sound; prior V-1 / R-1 fixes confirmed merged |
| `PossessioAutoTarget` | 485 | Sound (non-custodial, linear lifecycle, atomic fee) |
| `PossessioFundingVault` | 445 | Sound (exact `outstanding` accounting, CEI, asymmetric caps) |
| `POSSESSIO_v2-6-3` (STEEL + v4 Hook) | 2223 | Sound; all historical fixes present & correct |
| `PossessioPayments` | 2118 | Sound custody rails **except P-1** (FIXED) |
| `L1Anchor` | 936 | Sound; clean of the P-1 class (fail-closed Symmetry Guard) |
| `PossessioX402Core` | 858 | Sound (seller-substitution closed, floored draw un-drainable) |
| `PossessioFactory` | 264 | Sound (owner un-spoofable, atomic, codehash-pinned) |
| `L1AnchorFactory` | 334 | Sound (no caller-controlled args; plain CREATE) |
| `PossessioSaltPool` | 195 | Sound; **G-1 FIXED** (prefix enforced on-chain) |
| `PossessioPool` (the "Heart") | 473 | Sound (faithful generalization of x402Core's pool machinery) |
| `PossessioLaunchFactory` | 410 | Sound; **L-1 FIXED** (BEFORE_INITIALIZE-flag guard) |
| `LSTExchangeRate` | 167 | Sound (two-source halt-on-divergence; math MEASURED) |
| `SymmetryGuardCore` | 304 | Sound (`totalFeeBps` clamped [200,500]; signal non-injectable) |
| `HandshakeLib` | 62 | Sound (sorted-pair sha256 merkle, double-hashed leaves) |
| `PossessioCouncilToken` | 129 | Sound (minimal OZ ERC20+Permit; clean pairing denominator) |

### 2.2 Explicitly out of scope

- **`PLATE.sol` / `PLATEStaking.sol`** — V1 relics, **no live dependency** (no `src/` contract imports them; the five references are lineage comments). The V2 hook's own header records: *"STAKING REMOVED: PLATEStaking was ceremony over burn — eliminated from v2"* (`POSSESSIO_v2-6-3.sol:219`). The live token is **STEEL** — `ERC20("PLATE","STEEL")` embedded in the audited V2 hook.
- **The V3 launch template** — the contract `PossessioLaunchFactory` deploys is **not in this repository**; its codehash is supplied at deploy time via the `TEMPLATE_CODEHASH` environment variable. It cannot be audited here. See §6 for the security contract it must satisfy.
- Non-core / non-mainnet: `PossessioWhiskyMarket`, `PossessioTestnetLaunchPool`.

### 2.3 Trust assumptions

- Standard tokens (USDC, cbETH, DAI, WETH, STEEL, the Council Token) behave to ERC-20 spec — no fee-on-transfer, no rebasing. Verified for the in-repo tokens; asserted for the external ones.
- External venues behave to interface: Uniswap v4 PoolManager, Uniswap V3 SwapRouter, Aerodrome Slipstream, Chainlink feeds, the Bitwise-curated Morpho Blue vault, EIP-3009 (USDC), CreateX.
- Chainlink feed addresses and decimals are as cast-verified in the source; feeds do not change decimals post-deployment.

---

## 3. Methodology

- **Whole-contract reads.** Every audited contract was read in full, top to bottom. `grep` was used only to navigate, never to conclude.
- **No runners, no delegation.** No Slither/static analysis; no sub-agents. The auditor read the code personally.
- **Terminal as judge (Canon of the Terminal).** Claims are labelled **MEASURED** (proven by an executed test) or **DERIVED** (reasoned from source). Findings were promoted to MEASURED with red→green regressions where the finding warranted it.
- **No False Green.** Each regression was shown to fail against the un-fixed code (the mandatory red run) before being accepted as green — the test must be able to catch the bug it claims to pin.
- **Sibling-diff.** Contracts sharing lineage (the two SAVs; L1Anchor vs Payments; the two factories) were diffed against each other; F-1 and S-1 were surfaced this way.
- **Live-chain grounding.** The high-value oracle and integration surfaces were fork-tested against **live Base mainnet** — the real v4 PoolManager, Chainlink cbETH/ETH + USDC/USD + ETH/USD feeds, Aerodrome TWAP, and the Morpho vault.

---

## 4. Findings — detail

### 4.1 P-1 (Medium, MEASURED) — Payments sweep WETH-leg oracle floor fails open — **FIXED**

**Location:** `src/PossessioPayments.sol`, `_sweep`, cbETH-leg sub-leg 1 (USDC→WETH).

**Description.** The v2.4.3 "H-1" fix floors each sweep leg's slippage at `max(callerMin, 90% × oracleExpected)`. For the USDC→WETH leg the oracle-expected value is produced by `_usdcToEth()`, which reads the **USDC/USD and ETH/USD** Chainlink feeds. That helper is **fail-open**: on a stale or invalid feed it *returns 0* rather than reverting. When it returns 0, `wethFloor = 0`, so `wethMin = max(minWethOut, 0)` — and the automation-supplied `minWethOut` (`sweepSlippageMinWeth`) **defaults to 0**. The USDC→WETH swap then executes with `amountOutMinimum = 0` — no slippage floor — exactly the condition the H-1 fix was written to close.

This is reachable *while the sweep still executes* because the only feed gating sweep entry (`_validateOracle`, cbETH/ETH) is a **separate** feed with a **wider, fail-closed** staleness window (25h, reverts). The composite USDC/ETH feeds use a **1h, fail-open** window. In the 1h–25h gap where the composite feed is stale but cbETH/ETH is fresh, the sweep proceeds with a zero WETH floor.

**Impact.** MEV sandwich on the USDC→WETH acquisition leg (Uniswap V3 0.05% pool), bounded by one sweep's cbETH allocation. Conditional value leakage, not a custody drain (funds remain in-contract as cbETH). Rated **Medium** on the live-product payment processor.

**The False Green.** The H-1 regression suite re-stamps **all four** feeds fresh before every sweep, so it can never observe a fresh-cbETH / stale-composite state. The charge was never filed.

**Fix (in branch).** A fail-closed guard in `_sweep`: `if (wethFloor == 0) revert OracleStale();`. The composite-feed staleness now blocks the sweep exactly as a stale cbETH feed does.

**Verification.**
- Regression `test/PossessioPayments_P1CompositeOracleFailOpen.t.sol`: control (fresh composite → floor has teeth) and the fail-closed case (stale composite → reverts `OracleStale` before the router). Non-vacuity confirmed by removing the guard (attacker sandbag accepted → RED).
- Fork-validated: `PaymentsFork` exercises the `_usdcToEth` path against the **live** Base USDC/USD + ETH/USD feeds.

---

### 4.2 L-1 (Medium, MEASURED) — LaunchFactory v4 pool-init front-run DoS — **FIXED**

**Location:** `src/PossessioLaunchFactory.sol`, `deployLaunch` step 8 (`poolManager.initialize`).

**Description.** `deployLaunch` finishes by initializing the launch's Uniswap v4 pool in the same transaction, with `hooks = launch`. The launch address is **CREATE3-deterministic and publicly predictable** (the pre-mined salt sits in `PossessioSaltPool` storage; its prefix is the factory address, so `launch = CreateX.computeCreate3Address(keccak256(factory, salt))`). Before the fix, the launch address carried the swap-side hook flags (`0x8C8`) but **not** `BEFORE_INITIALIZE`. Because v4's `initialize` only calls `beforeInitialize` when the address carries that flag, an attacker could call `poolManager.initialize` on the predicted key **first** — against the still-**codeless** launch address — permanently occupying the pool. The victim's `deployLaunch` then reverts `PoolAlreadyInitialized`.

**Impact.** DoS-not-drain: the fee is atomically refunded (no theft), but the launch never deploys and the poisoned launch address is permanently unusable. Because the SaltPool is LIFO, the same poisoned salt is re-served, so an attacker can hold the public launch rail down for one `initialize` gas per salt. Rated **Medium** (persistent, cheap, product-level liveness DoS).

**The False Green (meta).** The DoD suite's mock PoolManager did not model v4's per-key already-initialized revert — it re-initialized any key — so the suite was structurally blind to this class.

**Fix (in branch).** `deployLaunch` now requires the launch address to carry the v4 `BEFORE_INITIALIZE` flag (bit 13):
`if (uint160(launch) & (1<<13) == 0) revert LaunchHookNotInitGated(launch);`
With the flag set, v4 invokes `launch.beforeInitialize` on *every* init of the key. An attacker's pre-init runs against the **code-less** launch address → the hook call returns empty data → v4 reverts (`InvalidHookResponse`). Only the factory's own init — after the launch is deployed and its `beforeInitialize` returns the expected selector — succeeds. A mis-mined salt fails closed, so no un-gated pool can be minted.

**Verification.**
- Regression `test/PossessioLaunchFactory_L1PairInitFrontrun.t.sol` (v4-faithful PoolManager): an *unflagged* address IS front-runnable (the pre-fix world); a *flagged* address blocks the attacker while the honest deploy works; the guard refuses an unflagged salt (fee refunded, salt unconsumed).
- **Proven on live Base v4:** `PossessioLaunchFactoryFork::test_fork_attackerPreInit_blockedByLiveV4` shows the attacker's pre-init reverting on the **real** Base PoolManager (`0x498581fF…`), with the honest deploy then initializing. The `beforeInitialize` selector handshake is accepted by live v4.

**Two residual requirements for the launch rail** (keeper/template-side; the LaunchFactory MUST NOT be deployed until both hold):
1. The keeper must mine salts so the launch address carries `BEFORE_INITIALIZE` in addition to the swap flags (`0x8C8 | 0x2000`), else `deployLaunch` fails closed.
2. The out-of-repo launch template MUST implement `beforeInitialize` returning `IHooks.beforeInitialize.selector`, else even the legitimate init reverts (fail-closed — safe, but the rail won't function).

---

### 4.3 F-1 (Low, DERIVED) — Standalone SAV `invent()` lacks the F3 amount-binding — **OPEN**

**Location:** `src/ServiceAccountabilityVault.sol` `invent(uint256 amount, bytes32 proposalHash, bytes metadata)`.

**Description.** The hook-embedded SAV (`POSSESSIO_v2-6-3.sol::executeInvent`) enforces the council-ratified F3 binding: `proposalHash == keccak256(abi.encode(address(this), amount, metadata))`. The **standalone** SAV treats `proposalHash` as an opaque key and does not bind it to the executed `amount`/`metadata`. A 3-of-4 council approval of a hash therefore does not cryptographically constrain the amount the Treasury deducts against it.

**Impact.** **Not a drain** — `onlyTreasury`, funds go to `TREASURY_SAFE`, bounded by each council member's `claimable`. It is a **governance accountability gap**: the council's ratification does not bind the amount, the exact property F3 was written to guarantee.

**Fix.** Mirror the hook's F3 line in the standalone `invent`.

**Open question (Architect determination).** Which SAV is the operational on-chain council vault? If the hook-embedded SAV is operational, the standalone is a legacy inconsistency; if the standalone is deployed, F-1 is live. The SAV is **not** in the current redeploy set. Provenance: DERIVED (two code sites compared; MEASURE-able with a red→green test on request).

---

### 4.4 Informational items

- **G-1 (Info / DoS) — FIXED.** `PossessioSaltPool.refillSalts` now enforces `address(bytes20(salt)) == factory` (reverts `SaltNotFactoryPermissioned` otherwise). Previously the salt's CreateX-permission prefix was trusted to the keeper's off-chain mining; a non-prefixed salt is permissionless and its CREATE3 address is front-runnable. The on-chain check converts "keeper trusted to mine permissioned salts" into "contract verifies it." Fork-confirmed compatible with the live factory flow (`PossessioFactoryFork::test_fullSequence_saltPool_factory_payments`).
- **I-1 (Info).** `POSSESSIO_v2-6-3.sol::rescueToken` NatSpec lists "DAI (protocol emergency reserve)" among protected tokens, but the DAI leg was removed (v3) and the code protects only STEEL/cbETH/WETH. No security impact (DAI is never held). Comment cleanup.
- **I-2 (Info).** `PossessioPayments.morphoDepositedPrincipal` is incremented in `_sweep` but never decremented on `redeemMorpho` and never read in any safety-critical path (the treasury gauge values the Morpho leg from the live vault balance). Cosmetic drift only. Its L1Anchor sibling *does* decrement the analogous counter — mirror it if a future version reads the value. **Deliberately not changed** to keep the money contract's redeploy diff to P-1 only.
- **S-1 (Info — sibling-diff).** `L1Anchor.routeToMorpho` lacks the USDC-consumption leakage check its Payments sibling carries. **Benign:** `forceApprove(vault, amount)` bounds the vault's pull at exactly `amount` and resets to 0, and the share-delta check is present — the missing check can only permit harmless under-consumption. Confirms the Payments header's "parity gaps may exist in L1Anchor" note; the gap is harmless.
- **O-1 (Info).** The Payments sweep's success is coupled to LST-oracle health: `cbEthToEth` reverts (stale/divergence) propagate through the sweep's *informational* gauge update and revert the whole sweep. Fail-safe and retryable (no fund risk), consistent with the stack's halt-on-uncertainty discipline. The Architect could wrap the gauge call in try/catch (as the view gauge already does) so an informational hiccup doesn't block an otherwise-valid sweep. **Deliberately left as-is** — changing it would weaken a stated safety stance.

---

## 5. Positive results — what was verified sound

- **PossessioPayments:** role-gated exits with per-asset rolling daily limits; guardian freeze/cancel independent of a compromised owner; 7-day emergency timelock; leakage checks + share-delta verification on every sweep leg; atomic revert on over-limit redeem.
- **PossessioX402Core:** the seller-substitution theft vector is closed two ways (nonce-commitment binding `seller+channelId+value` + registry cross-check); exact-equality value binding (no under/overpay, only revert); the floored operator draw is un-drainable below `ABSOLUTE_FLOOR`; valve-by-omission is structural; the surplus routing was cross-contract-verified (the Heart pulls exactly the surplus).
- **PossessioPool:** every inflow source is valve-checked against both outflow destinations at construction; `receiveInfraFunds` only adds; the sole outflow is the operator-only floored draw; held-USDC == `poolBalance`; the velocity floor is not externally manipulable.
- **Factories:** owner is factory-written and un-spoofable (separate ABI word, further overridden inside templates); template codehash-pinned with the empty-codehash degenerate case guarded; fee + deploy fully atomic. `L1AnchorFactory` has no caller-controlled args at all.
- **LSTExchangeRate:** two-source (Chainlink + Aerodrome TWAP) halt-on-divergence, fail-closed; TWAP manipulation can only halt, never mis-price; tick→rate math MEASURED-correct offline and matched to the live rate on-chain.
- **SymmetryGuardCore + HandshakeLib:** `totalFeeBps` clamped to [200,500]; the behavioral signal is written only by deterministic on-chain logic (non-injectable, per-(sender,pool)); `register` is caller-bound + single-use; the merkle verify uses double-hashed leaves (domain separation) with the leaf derived, not supplied.
- **PossessioCouncilToken:** fixed supply, guarded genesis, holder-burn only, no owner/minter/pauser/fee/hook — a clean pairing denominator.
- **L1Anchor:** fail-closed Symmetry Guard (one-way latch); withdrawals delta-verified against contract balance, not external return values.
- **Prior findings V-1 / R-1 (Rail):** confirmed fixed and merged at HEAD.

---

## 6. Deployment guidance

The live constellation is **immutably cross-wired by address**, so a fix to any wired member forces a coordinated redeploy:

- `PossessioPool.authorizedSources = [factory, x402Core]` (no setter)
- `PossessioSaltPool.factory` (immutable pull gate)
- `PossessioX402Core.heartSink = Pool` (immutable)
- `PossessioFactory.feeSink = Pool`, `saltPool`, `TEMPLATE_CODEHASH` (immutable)

**Redeploy sequence (RUNBOOK order, CREATE3):** POOL → x402Core → factory → saltPool, with predicted addresses wired into each constructor. `PossessioPayments` is standalone (not wired into the constellation) and redeploys independently. **New CREATE3 salts are required** — the old addresses are occupied (CREATE3 addresses depend on salt, not code).

**Before the factory is deployed:** compile the P-1-fixed `PossessioPayments` first, take its creation-code hash, and pin that as `TEMPLATE_CODEHASH`. A factory pinning an unaudited/stale codehash is a trust hole even when the factory code is clean.

**Do not deploy `PossessioLaunchFactory`** until the two L-1 residuals (§4.2) are met: the keeper mines `0x8C8 | 0x2000` salts, and the (out-of-repo) launch template implements `beforeInitialize`.

**Cutover:** the month-old live deployment (pre-audit) cannot be patched — it is immutable. Migrate any held funds out of the old contracts, redeploy the fixed constellation, and re-point all off-chain references (console, automation forwarder/upkeep) to the new addresses.

**Month-old pre-audit deployment (to be replaced):**

| Contract | Address (Base mainnet) |
|---|---|
| Pool (Heart) | `0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce` |
| X402Core | `0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05` |
| Factory | `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd` |
| SaltPool | `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6` |
| Payments | `0x67247eB2108E7229331127DF1309D624d95467ca` |

---

## 7. Testing summary

- **Full suite: 1,128 tests pass, 0 failures, 2 skipped** (68 suites). The two skips are non-critical gated fork suites outside the redeploy set.
- **Offline:** every audited contract's unit/gauntlet suite is green, including the three new regressions authored during this audit (P-1 composite-oracle, L-1 pool-init front-run, LSTExchangeRate offline math — each filling a fork-only or mock-blind jurisdiction gap).
- **Live Base mainnet fork** (public RPC): `LSTExchangeRateFork` (live Chainlink + Aerodrome; two sources agree within the 2% band), `PossessioFactoryFork` (full saltPool→factory→payments sequence with the G-1 change), `PossessioPoolFork` (12 tests on real USDC), `PaymentsFork` (redeemMorpho / sendCbETH against the real Morpho vault + cbETH), `PossessioLaunchFactoryFork` (4 tests incl. the live-v4 front-run block), plus Rail, FundingVault, Hook, AutoTarget, and Desk fork suites.

---

## 8. Non-proven scope & limitations

- The **V3 launch template** is out-of-repo (env-supplied codehash) and was not audited; L-1's fix imposes a security contract on it (§4.2).
- The month-old live bytecode was **not** byte-compared to the fixed source (different compiler: the live contracts are solc 0.8.35; this environment has 0.8.27). The redeploy from fixed source supersedes the live deployment regardless.
- Floor/rate calibration parameters (`ABSOLUTE_FLOOR`, `FLOOR_PER_UNIT`, `VELOCITY_HALFLIFE`, `OPERATIONAL_CAP`, DustSpam constants) are data-gated before the immutable freeze; mis-calibration errs safe (over-floor locks funds in, never opens a drain).
- External venue and feed behavior is trusted to interface (§2.3).
- Verdicts are DERIVED (full source reads) except where explicitly MEASURED (the three regressions, the fork results, and the live bytecode-existence checks).

---

## 9. Disposition

- **P-1, L-1, G-1:** fixed in-branch, regression-pinned, and (P-1, L-1) fork-proven. Ready for merge and redeploy.
- **F-1:** open — requires the Architect's determination of which SAV is operational, then the one-line F3 mirror if the standalone is live.
- **I-1, I-2, S-1, O-1:** documented; no action required for safety. I-1 (comment) and I-2/O-1 (deliberate) are the Architect's discretion.

*If it can't be tested it doesn't exist. If it's not in the terminal it's not proven. Protocol protection above all else.*
