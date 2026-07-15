# RUNBOOK — FOUNDATION (one-time Base mainnet sequence)
**Origin:** Code Integrity seat, per Architect directive (write the missing FOUNDATION deploy scripts + the one-time mainnet runbook).
**Order (RATIFIED, deploy/optimizer_pool.json steps 1–3):** PossessioSaltPool → PossessioPool → PossessioFactory. Each proven before the next. Deploy once, work forever.
**Status:** scripts forge-compiled + full-sequence REHEARSED on a local anvil faked as chain 8453 (2026-07-14: all three deploys landed, factory landed EXACTLY at the predicted address, every §IV read-back answered as expected). That is a local rehearsal, NOT live Base — Codebyte Law: the mainnet claims below become real only when the tee'd broadcast logs exist.
**Format:** MIB §III — one command per block; the Architect executes from a phone. Every `--broadcast` block is **ARCHITECT-ONLY** (holds `DEPLOYER_PK`). Everything else any seat can run.

---

## §0 — OPEN: requires Architect ratification BEFORE any broadcast

Nothing below is decided by this runbook or its scripts. The scripts REFUSE to
run until each is supplied — that refusal is the enforcement.

| # | OPEN item | What ratification is needed |
|---|---|---|
| 0.1 | **Pool source-set membership — whisky market.** ~~Conflict between optimizer_pool.json's former two-source wording and whisky spec §6.~~ **RATIFIED 2026-07-14 (Architect): whisky IS in the pool set** — "it is in the pool set. we already worked it out." (`optimizer_pool.json` `_business_model` now names the three-source set directly — P-8 doc-drift fix, 2026-07-15.) | Mine the market's CREATE3 salt (§II), export `WHISKY_MARKET_ADDR=0x…`. The XOR guard in `DeployPossessioPool.s.sol` stands as the mechanical enforcement; the exclusion path is retired by this ratification. |
| 0.2 | **`OPERATOR_DEST_ADDR` / `TREASURY_DEST_ADDR`** — the pool's immutable operator + treasury. **Architect confirms 2026-07-14 the addresses exist** (held off-repo; deliberately never committed). | Architect exports both at broadcast time. (treasury == operator is an allowed shape per the contract's documented intentional omission; every SOURCE ≠ both is enforced.) |
| 0.3 | **Pool floor params** (`POOL_OPERATIONAL_CAP`, `POOL_ABSOLUTE_FLOOR`, `POOL_FLOOR_PER_UNIT`, `POOL_VELOCITY_HALFLIFE`). Three gates before the immutable freeze: **(1) fork-prove on Base — DONE 2026-07-14**, `test/PossessioPoolFork.t.sol` 13/13 against live Base USDC via `mainnet.base.org` (real FiatTokenV2_2: valve guards, exact-unit sweep, floor holds, half-life decay to exact chord values, one-way draw, DoD #14 uncredited raw transfer); **(2) calibrate — DONE 2026-07-15 (Architect-ratified conservative set, see §0.3-detail): CAP 10,000 / ABS_FLOOR 500 / PER_UNIT 5 USDC / HALFLIFE 7d — clears both inequalities with a ~136-events/day lock margin**; **(3) cold-seat re-audit — DONE 2026-07-15** (`AUDIT_POOL_20260715.md`, verdict: no fund-loss/theft path; calibration constraints only). | All three gates cleared 2026-07-15. Export the ratified four numbers (§0.3-detail) at broadcast; §III read-back confirms them on-chain. **Signed off — clear to broadcast.** |
| 0.4 | **`FEE_SOURCE_ADDR`** (salt pool constructor's `_deploymentFeeSource`, used only for the keeper-separation check). Natural value = the predicted `FACTORY_ADDR` (the factory is what pushes deploy fees, mirroring x402Core's `deploymentFeeSource`). | Confirm the value to export. |
| 0.5 | **Template choice + `TEMPLATE_CODEHASH`** for the $1 factory. The fee (1 USDC), payToken (Base USDC) and feeSink (live Payments) are already pinned in `script/DeployPossessioFactory.s.sol`; the template is not. The chosen template must satisfy the RATIFIED template convention (`constructor(address owner, bytes initArgs)` — PossessioFactory.sol header); verify the candidate actually has that shape before pinning. | Name the template. Its `init_codehash` comes from `deploy/optimizer_pool.json` (§I-4). |
| 0.6 | **CreateX caller for the x402Core (and whisky) mainnet deploys** — factory+salt rail vs a manual EOA `deployCreate3`. The CREATE3 address is sender-locked to WHOEVER calls CreateX; a different caller = a different address = a dead pool source. | Name the caller per organ. Predictions in §II must use exactly that caller as `DEPLOYER`. |
| 0.7 | **Keeper wallet** (`SALT_KEEPER_ADDR`) — fresh, compute-only key; never a money destination anywhere in the protocol. Also the salt pool's open council questions Q1/Q1b/Q3 (on-chain salt validation / dedup / keeper==factory guard) remain flagged in the contract header — deploying v0.1 as-built means accepting them as-is. | Generate the key; acknowledge Q1/Q1b/Q3 posture. |
| 0.8 | **Deployer key + nonce plan** (§II-1). ~~Pending.~~ **RATIFIED 2026-07-14 (Architect): one deployer key, accepted with the risk stated** — "one fuck up from a human and bye bye. but sovereignty comes with a price." The key goes quiet except for this sequence; the §III nonce gates are the mechanical guard against the human fuck-up. | Done. Architect holds the key; §III-1's nonce read-back is mandatory immediately before each broadcast. |

**Standing gate (not optional): `TEMPLATE_CODEHASH` must be pinned from the CURRENT post-audit build** — contract bytecode changed 2026-07-14 (audit fixes C-1…C-7, commit `6fa6570`). Any codehash noted before that date is stale and pins a template the factory will forever reject. §I-4 recomputes; §III-3 proves no drift since.

### §0.2-detail — accepted risk on the operator/treasury addresses (P-3 / P-4, cold-seat audit 2026-07-15)

Record these when ratifying `OPERATOR_DEST_ADDR` / `TREASURY_DEST_ADDR` (both accepted-risk, no code change):

- **P-3 (liveness papercut, not a lock):** the surplus sweep to `treasuryDestination` runs INSIDE `receiveInfraFunds`, atomically with the organ's own tx. If Circle ever blacklists the (immutable) treasury — or pauses USDC — any inflow that would cross the cap reverts, and that revert propagates into the organ: a fee-bearing `PossessioWhiskyMarket.settle()` reverts and the winner's escrow is stuck until the operator manually draws the pool below the cap to make room. This is recoverable — draws go to the operator, not treasury — **as long as operator and treasury are DISTINCT addresses and the operator is responsive.** The contract's documented "treasury == operator allowed" shape removes that escape hatch, so **keep the two addresses distinct.**
- **P-4 (permanent, accept it):** `settleOperationalCosts` pays only the immutable `operatorDestination`. A blacklisted operator strands the operating reserve (up to CAP) forever — no rescue, no re-point, by design.

### §0.3-detail — gate-(2) calibration acceptance test (P-1) + the Option A batched-feed decision

**Gate-(2) acceptance test — the ratified four numbers MUST satisfy BOTH inequalities:**

1. `FLOOR_PER_UNIT ≤ (smallest expected per-event inflow)`
2. `ABSOLUTE_FLOOR + 2·n_max·FLOOR_PER_UNIT < OPERATIONAL_CAP`  — where **n_max = the highest sustained inflow EVENTS per half-life** the organs can produce.

**Why (P-1, `AUDIT_POOL_20260715.md`):** the velocity floor is **amount-blind** — `_bumpVelocity` adds a fixed 1 unit per inflow EVENT regardless of dollar amount. At steady state `velocity ≈ 2·n` (events per half-life), so the floor climbs to `ABSOLUTE_FLOOR + 2·n·FLOOR_PER_UNIT`. The moment that crosses `OPERATIONAL_CAP`, `drawableSurplus()` is permanently zero while traffic persists — the pool fills to its cap with real money, everything over-cap sweeps to treasury, and **the operator the pool exists to fund can draw NOTHING** until traffic stops for multiple half-lives. The audit's throwaway PoC confirmed it empirically: **200 dust inflows (0.0002 USDC total) pushed the floor to 5,500 USDC > the 5,000 cap and locked the operator out.** Inequality (1) keeps a single event from over-weighting the floor; (2) proves the sustained-traffic steady-state floor stays under the cap.

**Now enforced deploy-side (P-2):** `script/DeployPossessioPool.s.sol` pre-checks `require(floor < cap)` (rejects the self-bricking `floor ≥ cap` shape) and sanity-bands the half-life to `[1 hours, 90 days]` (a fat-fingered seconds value changes n by orders of magnitude). These are cheap script guards; they do NOT replace the gate-(2) calibration above — they only reject the grossest miswires.

**Option A — design decision (Architect-RATIFIED 2026-07-15):** ship `src/PossessioPool.sol` **as-is** — the amount-blind floor and the verbatim-lift of `_bumpVelocity`/`_decayedVelocity` from x402Core are PRESERVED, no contract change. The safety condition that makes this sound is a **binding constraint on how organs feed the pool**: **every organ MUST feed the pool by a BATCHED SWEEP — accrue inflows internally and sweep the surplus periodically (exactly like the factory fee and the pool's own cap-then-surplus mechanic), NEVER a per-event / per-toll push.** Batched sweeps keep the pool's inflow-EVENT rate low, which is precisely what keeps n_max small and stops P-1 from ever triggering. This constraint governs all future organ→pool wiring (see the x402Core wiring note below and TODO).

**RATIFIED gate-(2) params (Architect, 2026-07-15) — conservative set. Export these verbatim at broadcast (§II/§III):**

| Param | Value | Export (base units — USDC 6-dec / seconds) |
|---|---|---|
| `OPERATIONAL_CAP` | 10,000 USDC | `POOL_OPERATIONAL_CAP=10000000000` |
| `ABSOLUTE_FLOOR` | 500 USDC | `POOL_ABSOLUTE_FLOOR=500000000` |
| `FLOOR_PER_UNIT` | 5 USDC | `POOL_FLOOR_PER_UNIT=5000000` |
| `VELOCITY_HALFLIFE` | 7 days | `POOL_VELOCITY_HALFLIFE=604800` |

**Proof against the acceptance test (all pass):**
- **P-2 `floor < cap`:** 500 < 10,000 ✓ (also enforced by the deploy-script `require`).
- **Inequality 1 `FLOOR_PER_UNIT ≤ smallest sweep`:** 5 USDC ✓ — batched sweeps are ≥ $5 by construction (Option A).
- **Inequality 2 `ABSOLUTE_FLOOR + 2·n_max·FLOOR_PER_UNIT < OPERATIONAL_CAP`:** lock threshold `n_max = (10,000 − 500) / (2·5) = 950 events/half-life = ~136/day`. Batched feeds run a handful/day → ~10× margin even at 30/day (steady floor $2,600, headroom $7,400). The stream is self-funding: API cost is call-based and every cost-bearing event brings its own fee, so real activity can never lock the operator — only fake/grief events could inflate the floor, and only uneconomically and temporarily (they decay in a few half-lives).

**Rationale / economic meaning:** `ABSOLUTE_FLOOR` 500 = the hard baseline infra runway the operator can never draw below; `OPERATIONAL_CAP` 10,000 = the operating-reserve target the stream fills to before surplus streams one-way to treasury (~20 months at a ~$500/mo baseline); `FLOOR_PER_UNIT` 5 = dollars of held-buffer per unit of recent activity, kept small for the wide lock margin; `HALFLIFE` 7d = the held channel relaxes over a week when activity quiets (inside the [1h, 90d] sane band, P-2). These are **immutable once broadcast** — raise `ABSOLUTE_FLOOR` (and `OPERATIONAL_CAP` with it) in a *future* pool version if real monthly infrastructure cost exceeds ~$500.

---

## §I — PRE-FLIGHT (any seat; no broadcast; run the day of the wave)

**1. Clean tree, on the ratified commit.**

```
git status --short && git log -1 --oneline
```

Expect: no output from `git status --short`. Record the commit hash — it is the build the codehashes freeze from.

**2. Build.**

```
forge build 2>&1 | tail -3
```

Expect: `Compiler run successful` (lint warnings are known-standing).

**3. Full suite — must be green before anything broadcasts.**

```
forge test 2>&1 | tail -3
```

Expect the live tally (778 passed / 0 failed / 2 skipped across 38 suites as of 2026-07-15, the PossessioPool cold-seat re-audit fresh run; the 2 skips are fork suites without `BASE_RPC_URL`).

**4. Freeze the codehashes from THIS build.**

```
bash deploy/sync_optimizer_pool.sh
```

This fills `init_codehash` / `deployed_codehash` / `runtime_bytes` in `deploy/optimizer_pool.json` (done + committed for the 2026-07-14 build — this re-run proves YOUR build matches). Then pin the template (per §0.5):

```
jq -r '.contracts[] | select(.name=="<RATIFIED_TEMPLATE>") | .init_codehash' deploy/optimizer_pool.json
```

That value is `TEMPLATE_CODEHASH`. **FREEZE RULE: from this moment until the factory broadcasts (§III-4), no source file and no `foundry.toml` change lands.** §III-3 re-runs the sync and diffs to prove it.

---

## §II — ADDRESS PREDICTION (offline — no RPC, no keys, nothing signed)

**1. Nonce plan.** With `$DEPLOYER` = the ratified foundation deploy key (§0.8), read its live nonce:

```
cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL
```

Call the answer `N`. The sequence spends: salt pool = `N`, pool = `N+1`, **factory = `N+2`**. (If different keys send the three txs, the factory deployer's own next nonce is what you use.)

**2. Predict the factory address.**

```
FACTORY_DEPLOYER_ADDR=$DEPLOYER \
FACTORY_DEPLOYER_NONCE=<N+2> \
forge script script/PredictCreate3Addresses.s.sol -vv 2>&1 | tee predict_factory.txt
```

Record `PREDICTED` as **`FACTORY_ADDR`**. It feeds BOTH step-1 (salt pool's immutable pull gate) and step-2 (pool source[0]).

**3. Derive the organ addresses (per §0.1 / §0.6).** Organs with no hook-flag requirement (x402Core, whisky market) need NO mining — any sender-locked salt works: `[CreateX-caller 20 bytes][0x00][entropy 11 bytes]`. Build one per organ, then:

```
DEPLOYER=<ratified CreateX caller, §0.6> \
X402CORE_SALT=0x<caller20><00><entropy11> \
WHISKY_MARKET_SALT=0x<caller20><00><entropy11> \
forge script script/PredictCreate3Addresses.s.sol -vv 2>&1 | tee predict_organs.txt
```

Record **`X402CORE_ADDR`** (and **`WHISKY_MARKET_ADDR`** if §0.1 ratifies inclusion). The script validates the salt layout and refuses anything not sender-locked to `DEPLOYER` — a wrong layout would silently predict a wrong address otherwise. **RECORD THE SALTS with the addresses:** the organs must later deploy with exactly these salts from exactly that caller, or they land elsewhere and the pool never hears them.

**4. Write all predicted values + salts + `N` into the wave note before proceeding.**

---

## §III — DEPLOY (ratified order; every block here is ARCHITECT-ONLY)

**1. FOUNDATION 1/3 — PossessioSaltPool.** *(spends nonce `N`)*

```
FACTORY_ADDR=0x<predicted, §II-2> \
SALT_KEEPER_ADDR=0x<§0.7> \
OPERATOR_DEST_ADDR=0x<§0.2> \
TREASURY_DEST_ADDR=0x<§0.2> \
FEE_SOURCE_ADDR=0x<§0.4> \
forge script script/DeploySaltPool.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PK \
  --broadcast -vvv 2>&1 | tee deploy_saltpool.txt
```

Record the address as `SALT_POOL_ADDR`. Verify before proceeding:

```
cast call $SALT_POOL_ADDR "factory()(address)" --rpc-url $BASE_RPC_URL
```

Expect: exactly `FACTORY_ADDR` (the prediction — the factory doesn't exist yet; that's correct).

```
cast call $SALT_POOL_ADDR "keeper()(address)" --rpc-url $BASE_RPC_URL
```

Expect: `SALT_KEEPER_ADDR`.

**2. FOUNDATION 2/3 — PossessioPool ("THE HEART").** *(spends nonce `N+1`; gated on §0.3's three cleared gates)*

```
FACTORY_ADDR=0x<same prediction> \
X402CORE_ADDR=0x<§II-3> \
WHISKY_MARKET_ADDR=0x<§II-3, if ratified IN — otherwise omit and set WHISKY_MARKET_EXCLUDED=true> \
OPERATOR_DEST_ADDR=0x<§0.2> \
TREASURY_DEST_ADDR=0x<§0.2> \
POOL_OPERATIONAL_CAP=10000000000 \
POOL_ABSOLUTE_FLOOR=500000000 \
POOL_FLOOR_PER_UNIT=5000000 \
POOL_VELOCITY_HALFLIFE=604800 \
forge script script/DeployPossessioPool.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PK \
  --broadcast -vvv 2>&1 | tee deploy_possessiopool.txt
```

Record the address as `POOL_ADDR`. Quick sanity (full battery in §IV):

```
cast call $POOL_ADDR "authorizedSourceCount()(uint256)" --rpc-url $BASE_RPC_URL
```

Expect: `2` (whisky excluded) or `3` (whisky included) — nothing else.

**3. GATE before the factory — nonce + codehash drift.**

```
cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL
```

Expect: exactly `N+2` (the value predicted into `FACTORY_ADDR`). **Any other number = STOP.** The factory would land at the wrong address; the salt pool and pool are wired to the predicted one; the foundation restarts from §III-1 with fresh predictions.

```
bash deploy/sync_optimizer_pool.sh && git diff --stat deploy/optimizer_pool.json
```

Expect: no diff. A diff means the build drifted since §I-4 — the `TEMPLATE_CODEHASH` you are about to pin IMMUTABLY no longer matches what you think it is. **STOP and re-run §I.**

**4. FOUNDATION 3/3 — PossessioFactory at 1 USDC (interim, ratified).** *(spends nonce `N+2`)*
Fee (1 USDC), payToken (Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`) and feeSink (live Payments `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91`) are pinned inside the script — v1 fees route to Payments by design; the pool wiring is the later factory upgrade (TODO "Factory → Pool wiring upgrade").

```
SALT_POOL_ADDR=0x<§III-1> \
TEMPLATE_CODEHASH=0x<§I-4> \
forge script script/DeployPossessioFactory.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PK \
  --broadcast -vvv 2>&1 | tee deploy_possessiofactory.txt
```

**5. HARD GATE — the factory MUST have landed at the prediction.**

```
echo "predicted: $FACTORY_ADDR" && grep "Factory address" deploy_possessiofactory.txt
```

Expect: identical addresses. If they differ, the salt pool's immutable pull gate and the pool's immutable source[0] point at an address with no code — **the foundation is mis-wired and restarts from §III-1.** (Rehearsed 2026-07-14 on local anvil: prediction held exactly.)

---

## §IV — POST-DEPLOY VERIFICATION (any seat; read-only; every invariant proven by read-back)

Set `RPC="--rpc-url $BASE_RPC_URL"` mentally for each block. Every expected value below was rehearsed verbatim against the anvil deployment.

**1. Factory-only pull is wired (both directions).**

```
cast call $SALT_POOL_ADDR "factory()(address)" $RPC
```

Expect: the LIVE factory address (== prediction, per §III-5).

```
cast call $FACTORY_ADDR "saltPool()(address)" $RPC
```

Expect: `SALT_POOL_ADDR`.

```
cast call $SALT_POOL_ADDR "pullSalt()(bytes32)" --from 0x0000000000000000000000000000000000000001 $RPC
```

Expect: revert with custom error `0x7bf6a16f` (`UnauthorizedCall()`) — strangers cannot pull.

```
cast call $SALT_POOL_ADDR "pullSalt()(bytes32)" --from $FACTORY_ADDR $RPC
```

Expect: revert with custom error `0xb9c049a0` (`PoolEmpty()`) — the factory CAN reach the gate, and the empty pool answers honestly (correct until the keeper's first refill, §V-1).

**2. Factory economics are exactly the ratified interim posture.**

```
cast call $FACTORY_ADDR "DEPLOYMENT_FEE()(uint256)" $RPC
```

Expect: `1000000` (1 USDC, 6-dec — the prove-the-rail price).

```
cast call $FACTORY_ADDR "payToken()(address)" $RPC
```

Expect: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Circle USDC, Base).

```
cast call $FACTORY_ADDR "feeSink()(address)" $RPC
```

Expect: `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` (live PossessioPayments — NOT the pool; that upgrade is a later factory version).

```
cast call $FACTORY_ADDR "templateCodehash()(bytes32)" $RPC
```

Expect: the exact `TEMPLATE_CODEHASH` from §I-4 (= the manifest's `init_codehash` for the ratified template, current post-audit build).

**3. Pool sources are exactly the ratified set — no more, no less.**

```
cast call $POOL_ADDR "authorizedSourceCount()(uint256)" $RPC
```

Expect: `2` or `3` per §0.1.

```
cast call $POOL_ADDR "isAuthorizedSource(address)(bool)" $FACTORY_ADDR $RPC
```

Expect: `true`.

```
cast call $POOL_ADDR "isAuthorizedSource(address)(bool)" $X402CORE_ADDR $RPC
```

Expect: `true`.

```
cast call $POOL_ADDR "isAuthorizedSource(address)(bool)" $WHISKY_MARKET_ADDR $RPC
```

Expect: `true` if ratified IN; skip if excluded. And one negative probe (Payments must NOT be a source — optimizer_pool.json is explicit):

```
cast call $POOL_ADDR "isAuthorizedSource(address)(bool)" 0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91 $RPC
```

Expect: `false`.

**4. Pool destinations + immutable params match ratification.**

```
cast call $POOL_ADDR "operatorDestination()(address)" $RPC && cast call $POOL_ADDR "treasuryDestination()(address)" $RPC
```

Expect: the §0.2 addresses, in that order.

```
cast call $POOL_ADDR "payTokenERC20()(address)" $RPC
```

Expect: Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.

```
cast call $POOL_ADDR "OPERATIONAL_CAP()(uint256)" $RPC && cast call $POOL_ADDR "ABSOLUTE_FLOOR()(uint256)" $RPC && cast call $POOL_ADDR "FLOOR_PER_UNIT()(uint256)" $RPC && cast call $POOL_ADDR "VELOCITY_HALFLIFE()(uint256)" $RPC
```

Expect: the four §0.3 ratified numbers, in that order.

```
cast call $POOL_ADDR "poolBalance()(uint256)" $RPC && cast call $SALT_POOL_ADDR "depth()(uint256)" $RPC
```

Expect: `0` and `0` — a newborn heart and an unstocked rail, honestly reported.

**Codehash footnote (so nobody false-alarms):** do NOT compare on-chain `extcodehash` against the manifest's `deployed_codehash` for these three — all carry immutables, which are stamped into the runtime at deploy, so live bytecode ≠ artifact bytecode by design (confirmed in the rehearsal). Wiring is proven by the read-backs above, and template identity by `templateCodehash`, which hashes CREATION code (no immutables baked yet).

---

## §V — AFTER THE FOUNDATION (out of this runbook's scope; listed so nothing is lost)

1. **Keeper refill before the first paid deploy** — mine 0x8C8 salts sender-locked to the LIVE factory address (`DEPLOYER=$FACTORY_ADDR forge script script/MineCreate3Salt.s.sol --fork-url $BASE_RPC_URL -vv`; needs an RPC), then `refillSalts(bytes32[])` from the keeper key. Until then `depth()==0` and every `deployTemplate` reverts `PoolEmpty()` — atomically, fee refunded with the revert.
2. **Console config** — point chain 8453 at the live factory address; this retires "no factory configured for chain 8453."
3. **Organ deploys must honor §II-3's records** — x402Core (and whisky, if ratified in) deploy via CreateX from EXACTLY the ratified caller with EXACTLY the recorded salts, or they land off the pool's immutable source set.
4. **Factory → Pool wiring upgrade** (TODO item) — a later factory version that `approve`s + calls the pool's accounted `receiveInfraFunds()` (never a raw transfer — uncredited per Pool DoD #14). The factory address is already in the source set waiting for it — authorization at construction, calls when ready (the pool header's ratified posture). **When built it MUST feed the pool by a batched sweep, never per-event (Option A, §0.3-detail).**
5. **x402Core → Pool wiring upgrade** (P-5, cold-seat audit 2026-07-15 — same shape as #4, previously undocumented) — `src/PossessioX402Core.sol` as-built has **NO `receiveInfraFunds` call and NO approval path to the pool**: tolls accrue to its own internal `operationalPoolBalance` and its surplus sweeps to its OWN treasury immutable. It **cannot feed the pool.** Yet `optimizer_pool.json` ratifies x402Core as pool source[1] and the deploy script requires `X402CORE_ADDR` at that pre-derived CREATE3 address. Therefore whatever deploys at source[1] must be a **FUTURE x402Core version carrying pool wiring that does not exist in this repo yet** — do NOT burn that address on the current artifact. Authorization-at-construction / calls-when-ready, exactly like the factory (#4). When that wiring is built it **MUST be a batched sweep, never a per-toll push (Option A, §0.3-detail)** — a per-toll push would drive the pool's inflow-event rate up and trip P-1.
6. **Tier repricing** — when the pool is proven: deploy a NEW factory at 100 USDC; the $1 factory keeps its price forever (immutable, honest versioning).
