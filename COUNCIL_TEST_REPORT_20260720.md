> ⚠️ **SUPERSEDED — DO NOT CITE AS CURRENT.** This report describes tree
> `f8fd66a`, which is **before `PossessioFundingVault` existed** (the vault was
> built later at `dce2053`). Its `889 / 0 / 7` and the per-suite list in §2 were
> correct *as of `f8fd66a`* but are **stale for HEAD** — the current tree has the
> vault and runs `936 / 0 / 8`. Authoritative report:
> **`COUNCIL_TEST_REPORT_20260721.md`**. Kept only as dated history.

# COUNCIL TEST REPORT — 2026-07-20

**Tree:** `claude/repo-audit-h9m2ev` @ `f8fd66a` (PR #42) · **Toolchain:** forge 1.7.1
(solc 0.8.35, via_ir) · **Optimizer:** uniform `runs=200` (all contracts)
**For:** full council · **From:** Code Integrity seat

---

## 0. Headline

```
forge test  =>  889 passed · 0 failed · 7 skipped   (896 total, 46 suites)
radar node  =>  35 passed · 0 failed                (screen/discovery/sessiongate/x402)
live fork   =>  constellation 3/3 on Base mainnet   (new deploy order)
EIP-170     =>  every contract fits at runs=200      (hook tightest, +409)
```

The 7 offline skips are **fork-gated** — they `vm.skip(true)` without an RPC and
**run + pass live** (FIX B discipline: skip, never vacuously pass). Full live
accounting in §4.

---

## 1. What changed this cycle (the surfaces council is reviewing)

| change | contract | new/edited tests | mutation-verified |
|---|---|---|---|
| F3 vote-amount binding | PossessioHook | `POSSESSIO_v2_InventSig` (F3 bound/mismatch-amount/mismatch-metadata/replay) | ✅ neutralizing the binding → test red |
| `approveInventBySig` (EIP-712, replay-protected) | PossessioHook | `POSSESSIO_v2_InventSig` (full-flow/wrong-domain/re-propose-replay/non-council/double-approve/mixed) | ✅ neutralizing the instance-scope → test red |
| x402Core surplus → Heart (F1) | PossessioX402Core | `PossessioX402CoreGauntlet` (+5: surplus→Heart, brick-guard EOA/wrong, valve) | ✅ construction guard proven |
| rug gate NULL→UNKNOWN | radar/screen.ts | `radar/test/screen.test.mjs` (P4 harness, 11) | ✅ reverting the fix → proof red |
| uniform runs=200 | all | full suite re-run green at 200 | — |

**Mutation verification** (guards proven load-bearing, not decorative): for each
of the F3 binding and the sig instance-scope, neutralizing the guard flips the
relevant test **red**; restoring → **green**. The radar rug-gate fix: reverting
`gateRug === 1` to the old `!== 0` flips the calibration proof red.

---

## 2. Per-suite results (production suites)

**Invent governance / SAV (the pre-freeze edit's home):**
```
POSSESSIO_v2_InventSig .............. 27 / 0 / 0   (F3 + approveInventBySig, keypair seats)
POSSESSIO_v2_Invariants_t ........... 17 / 0 / 0   (incl. F3 rounding + canonical-hash)
POSSESSIOv2Gauntlet ................. 32 / 0 / 0
SAVTest ............................. 76 / 0 / 0
SAVGauntlet ......................... 42 / 0 / 0
```

**x402Core / Heart money path:**
```
PossessioX402CoreGauntletTest ....... 23 / 0 / 0   (+5 this cycle: surplus→Heart, brick-guard, valve)
PossessioX402CoreDecayTest ..........  3 / 0 / 0
X402TestnetProofTest ................ 11 / 0 / 0
PossessioPoolTest ................... 22 / 0 / 0
PossessioFactoryTest ................  9 / 0 / 0
PossessioFactoryAdversarialTest .....  9 / 0 / 0
PossessioSaltPoolTest ............... 17 / 0 / 0
```

**AutoTarget (the desk):**
```
PossessioAutoTargetTest ............. 17 / 0 / 0
PossessioAutoTargetAdversarialTest .. 20 / 0 / 0
```

**Payments (live on Base mainnet) + PLATE + guards:**
```
PossessioPaymentsTest ............... 129 / 0 / 1   (skip = deliberate mock-mode variant)
PossessioPaymentsGauntlet ...........  33 / 0 / 0
PossessioPaymentsAutomationTest .....  28 / 0 / 0
PaymentsForkTest ....................  21 / 0 / 0
PaymentsAutomationInvariants ........   4 / 0 / 0
PossessioPaymentsH1SlippageTest .....   4 / 0 / 0
PLATETest ...........................  98 / 0 / 0
PLATEAttackTest .....................  29 / 0 / 0
PLATEStakingTest ....................  24 / 0 / 0
PLATELaunchV2Test ...................   3 / 0 / 0
HandshakeLibGauntlet ................  13 / 0 / 0
SymmetryGuardCoreGauntlet ...........  20 / 0 / 0
AutomationInvariants ................  30 / 0 / 0
```

**L1 Anchor (Ethereum set):**
```
L1AnchorFactoryTest ................. 35 / 0 / 0
L1Anchor{Emergency,Identity,Oracle,Reentrancy,SilentFailure,Sovereignty,ReentrancyBehavioral}
                                    .. 5+7+6+3+3+7+5 / 0 / 0
L1AnchorInvariantTest ...............  1 / 0 / 0
LSTExchangeRateForkTest .............  5 / 0 / 0
```

**Testnet / launch pool:**
```
PossessioTestnetLaunchPoolTest ...... 16 / 0 / 0
PossessioWhiskyMarketGauntlet ....... 22 / 0 / 0
PossessioHook_M1Overflow_Test .......  5 / 0 / 0
```

---

## 3. Off-chain (node) suites

```
radar   — 35 / 35   (discovery, sessiongate, x402-discovery, + P4 screen.test.mjs)
```
The **P4 harness** (`radar/test/screen.test.mjs`) is new this cycle: the radar's
measurement core `screenScan` — which produces every forward-ledger number the
strat/PFG decisions rest on — had **zero** tests while the contracts had 856. Now
11 deterministic tests over the real `screenScan` (synthetic feed/RPC/D1),
asserting entry MC, `entry_vel`, the calibrated `strat_take` matrix, and outcome
resolution against hand-computed values.

---

## 4. Fork suites — the 7 offline skips run + pass LIVE

Run in small batches against Base mainnet (free public RPC 429s under concurrent
load — an infra artifact, not a test failure):

```
ConstellationCreate3ForkTest ....... offline 2/2 (1 skip, CreateX etched) | LIVE 3/3  (new order POOL→x402→factory→salt)
PossessioPoolForkTest .............. offline (whole suite skip)           | LIVE 13/13 (the Heart, real USDC, real gas)
PossessioFactoryForkTest ........... offline (whole suite skip)           | LIVE 2/2  (feeSink=A, poolBalance credited)
PossessioAutoTargetForkTest ........ offline (2 skip)                     | LIVE 2/2
PossessioSaltPoolCreate3Test ....... offline 3/3 (1 skip)                 | LIVE 4/4
PossessioHookCreate3ForkTest ....... offline 3/3                         | LIVE 3/3
```

**This cycle's live proof:** the Constellation fork ran 3/3 in the **revised
deploy order** (POOL → x402Core → factory → saltPool), confirming x402Core's
construction brick-guard passes against the **real** `PossessioPool.isInfraSink()`
and the surplus→Heart wiring lands on live state.

---

## 5. Size / EIP-170 (uniform runs=200)

Every contract fits the 24,576-byte ceiling at the deploy profile:

```
PossessioHook ...... 24,167 B  (+409)   <- tightest; the full invent edit fits
PLATE .............. 20,516 B  (+4,060)
PossessioPayments .. 19,445 B  (+5,131)  (was runs=10000 → now smaller/cheaper deploy)
PossessioX402Core ..  8,132 B  (+16,444)
PossessioFactory ...  2,479 B  (+22,097)
PossessioPool ......  2,685 B  (+21,891)
ServiceAccountabilityVault  5,118 B (+19,458)
```

---

## 6. Standing caveats (on the record, not under it)

- **Nothing here is deployed.** This is a pre-freeze cycle — the anchor is
  unspent, every immutable still changeable. That is precisely why F1/F3 were
  fixable at the source.
- **Codehash regen owed:** the uniform-200 change invalidates the pinned
  codehashes in `deploy/optimizer_pool.json`; regen via `sync_optimizer_pool.sh`
  **before** the factory freezes template init-codehashes. The already-live
  standalone Payments (`0x1c0F…`, deployed at runs=10000) will not match a 200
  rebuild — historical reference deploy; confirm acceptable.
- **The count is the terminal's, not this file's** — `forge test` output is the
  authority whenever this report and the run disagree.

*This seat ran the numbers and reports them; it does not certify the money path.
The diverse council's own read remains the gate before any immutable freeze.*
