# Constellation Redeploy — Checklist (staged 2026-08-26)

Fixed-source redeploy of the POSSESSIO constellation (P-1 / L-1 / G-1 fixes).
The month-old deployment is immutable and superseded — this is a fresh deploy at
new CREATE3 addresses. **Dry-run-proven end-to-end on a live Base fork:**
`test/StageRedeployDryRun.t.sol` (green).

## Staged addresses (fresh salts, sender-locked to the anchor EOA)

| Contract | New CREATE3 address | Salt (in the script) |
|---|---|---|
| Pool (Heart) | `0xD064Bb5C00798d8A523089B750a6c3350eC86797` | `…00f954711b220e94230e12f1` |
| x402Core | `0xFba54FF0260ED18e2a48884C4FE8650D4416e022` | `…00a3f42727cffd80f349d0a0` |
| Factory | `0x5509BA759ce6CdC4Fc719E38436bA33b734BF155` | `…003b32c63f7efcd69736d863` |
| SaltPool | `0xb61f5200Dd46d4D6d6399aCf12c8E9bFF549a5d9` | `…00554b55a2dc800801b2e2b0` |

Anchor deployer: `0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC` (salts are sender-locked to it). Payments is standalone (its own script), not wired into the constellation.

## Pre-flight (do these once, in order)

1. **Merge the audit PR** (P-1 / L-1 / G-1 + fork proofs).
2. **`TEMPLATE_CODEHASH` (production, solc 0.8.35) — MEASURED in CI:**
   ```
   TEMPLATE_CODEHASH=0x7dd017f4b4ba788b0002b78c0d933dde57a03c31a1a1f81ab5f51b329d337130
   ```
   `keccak256(type(PossessioPayments).creationCode)` for the FIXED (P-1) `PossessioPayments`,
   compiled with the production toolchain (solc 0.8.35, via_ir, runs=200). Measured by
   `test/TemplateCodehashProbe.t.sol` in the `forge (solidity)` CI job on run #173
   (commit `7d1d7c2`, `head_sha 7d1d7c2ceba4158725088da0475f57353d6ddd7a`), creationCode
   21865 bytes. Supply this as the `TEMPLATE_CODEHASH` env var to `DeployFactoryCreate3`
   (the scripts stay env-driven on purpose — this value is recorded here, **not** hardcoded
   into any broadcast script).
   - **Toolchain-dependence is proven, not assumed:** the local 0.8.27 control hashed to
     `0x94df70b23f7968759fa44be8d7d7515880c2905f59ea27f0194e0123012b3e50` (also 21865 bytes).
     Same byte length, different hash — reusing the dry-run's 0.8.27 value would brick the
     redeploy. Do **not** use it.
   - `script/GenTemplateArtifact.s.sol` is **not** the tool here: it is a drift-guard hardwired
     to the OLD factory pin (`0x14357940…`, factory `0x0DD0…`) and **reverts** on any change.
     The fixed Payments intentionally hashes to a new value, so that script would revert — which
     is also why the fixed template cannot be launched through the existing factory.
   - Re-measure only if `PossessioPayments.sol` (or its imports) changes again before deploy;
     re-run the probe in CI and update this value.
3. **Confirm the four anchor addresses above are still empty on mainnet** (nobody squatted them) — the deploy scripts assert `deployed == PREDICTED` and revert on mismatch, so this is belt-and-suspenders.
4. **Re-run the dry-run against a *fresh* Base fork** (Base state drifts): `BASE_RPC_URL=<rpc> forge test --match-path test/StageRedeployDryRun.t.sol` → must be green.
5. **Cold-seat LST oracle re-audit (Moonwell-lens) — do BEFORE deploy, red-first on a fresh fork.**
   The warm-seat pass (2026-08-29) MEASURED the deployed `LSTExchangeRate` guard fails closed:
   manipulated oracle → `RateDivergence` revert, stale feed → `OracleStale`, and live
   `cbEthToEth` == the Chainlink feed to the wei (see `test/LSTExchangeRate_AuditGuards.t.sol`,
   6/6 on live fork). **Not the Moonwell fund-loss class** — the output prices only the telemetry
   gauge, and truth is unmanipulable Chainlink. Do **not** inherit that "sound" — the cold seat
   re-derives it and MEASURES the three residuals below.
   - **F-1 (Low, liveness) — sweep DoS via forced TWAP divergence.** Design rule is "works
     correctly or not at all, *without failing anything else*." The gauge read (`:1235`) obeys it
     (try/catch → cbETH leg = 0); the sweep call site (`PossessioPayments.sol:1108`) does **not** —
     a griefed >2% TWAP reverts the whole sweep. **Redeploy fix: wrap `:1108` in the same
     try/catch downgrade as `:1235`** so a griefed valuation degrades the gauge field to 0 instead
     of failing the sweep. MEASURE end-to-end (the P-1 harness scaffolds a Payments deploy; it
     currently stubs a non-reverting `cbEthToEth`). Also quantify: sweep access control
     (keeper-only vs permissionless) and the cost to hold the ~1440-cardinality pool's 30-min TWAP
     >2% for a block vs live liquidity.
     - ⚠️ **CODEHASH DEPENDENCY:** F-1's fix edits `PossessioPayments.sol` → item 2's
       `TEMPLATE_CODEHASH` **must be re-measured** (re-run `test/TemplateCodehashProbe.t.sol` in CI
       and update the pinned value) before deploy. Ship F-1 and re-pin, or defer F-1 and keep the
       current pin — do not deploy a fixed Payments against the old codehash.
   - **F-2 (Low, informational) — 24h staleness window.** MEASURED fail-closed and doubly
     backstopped by the divergence guard. Cold seat: read consecutive feed rounds' `updatedAt` for
     the real cbETH/ETH heartbeat; if ≪24h, tighten `ORACLE_STALE` in the redeploy (cosmetic).
     Note: tightening a `constant` in `LSTExchangeRate.sol` re-deploys that contract (no codehash
     link, but the staged `lstRates` address changes → update Payments' `DeployParams`).
   - **F-3 (Low, optional) — `_tickToRate18` full-range fuzz.** MEASURED clean at anchors and
     in-range (tick 0 = 1e18, monotonic, reciprocal, 1000 cbETH no overflow). Optional cold-seat
     fuzz across the full int24 range vs a reference `1.0001^tick`: assert no revert-by-overflow,
     bounded error, and all out-of-band ticks land in the divergence revert.
   - Full memo: warm-seat `AUDIT_LSTExchangeRate_live_2026-08-29.md` (Architect-gated scratchpad).

## Deploy (RUNBOOK order — POOL → x402Core → factory → saltPool)

Each script asserts chain == 8453, deployer == anchor EOA, salt sender-locked, and prediction match; any mismatch reverts before broadcast. Supply the **calibrated** economic env vars (caps/floors/halflife/root/fees) — the dry-run used placeholders.

```
# 1. POOL (Heart) — deploys first; sources baked as predicted factory + x402Core
DEPLOYER_PK=… OPERATOR_DEST_ADDR=… TREASURY_DEST_ADDR=… \
POOL_OP_CAP=… POOL_ABS_FLOOR=… POOL_FLOOR_PER_UNIT=… POOL_HALFLIFE=… \
forge script script/DeployPoolCreate3.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv

# 2. x402Core — heartSink = the pool just deployed (brick-guarded)
DEPLOYER_PK=… X402_ROOT=… X402_DUST_FLOOR=… OPERATOR_DEST_ADDR=… \
X402_FEE_SOURCE_ADDR=… X402_OP_CAP=… X402_ABS_FLOOR=… X402_FLOOR_PER_UNIT=… \
X402_HALFLIFE=… X402_REGISTRATION_FEE=… \
forge script script/DeployX402CoreCreate3.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv

# 3. Factory — feeSink = pool, saltPool = predicted, TEMPLATE_CODEHASH regenerated in step 2 above
DEPLOYER_PK=… DEPLOYMENT_FEE=… TEMPLATE_CODEHASH=0x…(solc-0.8.35) \
forge script script/DeployFactoryCreate3.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv

# 4. SaltPool — factory = the factory just deployed
DEPLOYER_PK=… SALT_KEEPER_ADDR=… OPERATOR_DEST_ADDR=… TREASURY_DEST_ADDR=… \
forge script script/DeploySaltPoolCreate3.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv

# 5. Payments (standalone, independent) — its own DeployPayments.s.sol / env
```

## Post-deploy

1. **Verify each on Basescan** (byte-for-byte). Verification is what makes them count for builder attribution — announce *after*.
2. **Seed the SaltPool** — the keeper refills factory-permissioned salts. With G-1, `refillSalts` now enforces `address(bytes20(salt)) == factory`; mine salts prefixed with the new factory address.
3. **Re-point off-chain** — console, Chainlink Automation forwarder/upkeep, taproot integration — to the new addresses.
4. **Do NOT deploy the LaunchFactory** until its launch template implements `beforeInitialize` and the keeper mines `0x8C8 | 0x2000` salts (L-1 residuals).

## Guardrails baked into the scripts

- Chain-locked (reverts if not Base 8453).
- Deployer-locked (reverts if the key isn't the anchor EOA).
- Salt sender-lock asserted (`bytes20(salt) == anchor`, `salt[20] == 0x00`).
- Prediction asserted (`CreateX.computeCreate3Address(guardedSalt) == PREDICTED`).
- `deployed == PREDICTED` asserted post-deploy.
- x402Core + factory brick-guard `heartSink`/`feeSink == pool.isInfraSink()`.
