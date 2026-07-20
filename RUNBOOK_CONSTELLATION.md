# RUNBOOK — Constellation Deploy (CREATE3)

**Supersedes `RUNBOOK_FOUNDATION.md §III`** (the plain-CREATE, nonce-based flow).
Under CREATE3 there is **no nonce discipline** — every organ's address is
`f(anchor EOA, salt)`, fixed regardless of how many transactions the key sends.
The old §III nonce gates (`cast nonce == N+2`, "restart the foundation") are
**retired**; the gates below are keyed on **code**, not nonce.

**Anchor:** `deploy/anchor.json`, derived from the phrase `TREGUNA_MEKOIDES_TRECORUM_SATIS_DEE`
(recompute anytime: `node script/derive_anchor.mjs`). **Base mainnet (8453) only.**

| organ | address | salt-keyed to |
|---|---|---|
| factory | `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd` | anchor EOA |
| salt pool | `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6` | anchor EOA |
| x402Core | `0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05` | anchor EOA |
| pool (Heart) | `0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce` | anchor EOA |
| hook templates | end `0x8C8` | **factory** (`0x0DD0…49Bd`) |

**Anchor EOA:** `0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC`. Wave-duration secret
— its authority ends once the organs land and the codehash gates pass (no organ
has an owner; CreateX cannot redeploy an occupied address).

---

## 0. PRE-FLIGHT — every item true before ANY `--broadcast`

- [ ] **Anchor EOA funded on Base mainnet** (`cast balance $ANCHOR --rpc-url $BASE_RPC_URL` > 0). Pays gas for all four deploys.
- [ ] **Council's line-211 A-edit is in source** (`SPEC_Factory_FeeSink_A.md`). Without it the factory *strands* fees at the permanent anchor — unfixable. The fork test's `poolBalance` assertion is the proof it's live.
- [ ] **Economic values CALIBRATED, not placeholder** — `X402_ROOT`, `X402_DUST_FLOOR`, both `*_OP_CAP` / `*_ABS_FLOOR` / `*_FLOOR_PER_UNIT` / `*_HALFLIFE`. These freeze as immutables (SPEC §22). **Do not broadcast with guesses.**
- [ ] **Owed env values in hand:** `SALT_KEEPER_ADDR` (fresh, compute-only), `OPERATOR_DEST_ADDR` + `TREASURY_DEST_ADDR` (passkey Base Account — never a hot EOA/the anchor key), `DEPLOYMENT_FEE`, `TEMPLATE_CODEHASH` (from the frozen build), `X402_FEE_SOURCE_ADDR`.
- [ ] **Source FROZEN** — no `.sol` or `foundry.toml` change from here until the wave lands. Re-pin `TEMPLATE_CODEHASH` from the frozen build; any later edit changes it.
- [ ] **`BASE_RPC_URL`** set (QuickNode endpoint).
- [ ] **Anchor recorded off-machine** — `deploy/anchor.json` *and* the phrase. The phrase regenerates everything; losing it loses nothing on-chain (sender-locked), but losing recompute-ability.

---

## 1. FORK-VERIFY — proves everything, spends zero real ETH

```
# 1a. Constellation proof (offline core + fork notarization if RPC set)
forge test --match-contract ConstellationCreate3ForkTest -vv
```
Green ⇒ all four deploy to the anchor addresses, wiring resolves, the self-funding
door credits `poolBalance` (not stranded), a non-source is rejected. This is the
architectural gate.

```
# 1b. Dry-run each deploy script against a Base fork (NO --broadcast).
#     Confirms your real env values pass every constructor + gate.
export DEPLOYER_PK=... DEPLOYMENT_FEE=... TEMPLATE_CODEHASH=0x... \
       SALT_KEEPER_ADDR=0x... OPERATOR_DEST_ADDR=0x... TREASURY_DEST_ADDR=0x... \
       X402_ROOT=0x... X402_DUST_FLOOR=... X402_FEE_SOURCE_ADDR=0x... \
       X402_OP_CAP=... X402_ABS_FLOOR=... X402_FLOOR_PER_UNIT=... X402_HALFLIFE=... \
       POOL_OP_CAP=... POOL_ABS_FLOOR=... POOL_FLOOR_PER_UNIT=... POOL_HALFLIFE=...
forge script script/DeployX402CoreCreate3.s.sol  --rpc-url $BASE_RPC_URL -vvv
forge script script/DeployPoolCreate3.s.sol      --rpc-url $BASE_RPC_URL -vvv
forge script script/DeployFactoryCreate3.s.sol   --rpc-url $BASE_RPC_URL -vvv
forge script script/DeploySaltPoolCreate3.s.sol  --rpc-url $BASE_RPC_URL -vvv
```
A fork dry-run reverting = a real env/gate problem. Fix before mainnet. Note: the
salt-pool and pool dry-runs assert their siblings are *live*, so on a fresh fork
run them after the factory/x402Core actually deploy, or fork-run the full sequence
with `--broadcast` against a *local anvil-fork* (state persists) to prove ordering.

---

## 2. MAINNET BROADCAST — ordered, verify-before-wire

**ORDER REVISED (council brick-guard, FIX A): x402Core → POOL → factory → salt pool.**
The factory constructor now staticcalls `feeSink.isInfraSink()` and reverts
`FeeSinkInterfaceMismatch` if the pool is not a live infra-sink — so **the pool
MUST land before the factory** (a `code.length` check alone would not have caught
the demonstrated brick, where feeSink was a real-but-wrong contract). The pool
bakes the *predicted* factory address as a source (read only at runtime), so no
circularity. `DeployPoolCreate3` verifies only x402Core live; `DeployFactoryCreate3`
verifies the pool live before wiring.

Run in this exact order. Each script's internal gates (`deployed == predicted`,
salt→address recomputed via CreateX, siblings-must-be-live) abort the tx on any
mismatch. **After each: copy the logged `extcodehash` into the record below** — the
siblings and the post-deploy read-backs check against it (the front-run gate).

```
forge script script/DeployX402CoreCreate3.s.sol --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_x402core.txt
forge script script/DeployPoolCreate3.s.sol     --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_pool.txt
forge script script/DeployFactoryCreate3.s.sol  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_factory.txt
forge script script/DeploySaltPoolCreate3.s.sol --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_saltpool.txt
```

**Recorded extcodehashes (front-run gate — fill on deploy):**
- factory  `0x____` · salt pool `0x____` · x402Core `0x____` · pool `0x____`

---

## 3. POST-DEPLOY READ-BACKS (on-chain wiring gates)

```
cast call 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6 "factory()(address)"      $R  # == factory
cast call 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd "saltPool()(address)"     $R  # == salt pool
cast call 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd "feeSink()(address)"      $R  # == pool (A)
cast call 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce "isAuthorizedSource(address)(bool)" 0x0DD0…49Bd $R  # true
cast call 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce "isAuthorizedSource(address)(bool)" 0x60d8…6c05 $R  # true
# each organ's extcodehash == the value recorded in §2 (front-run confirmation)
```
Any mismatch ⇒ **STOP** (§5).

---

## 4. KEEPER REFILL — stock the salt pool with 0x8C8 hook salts

```
# mine factory-keyed 0x8C8 salts (RPC-free)
node script/premine_salts.mjs --factory 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd --count N
# keeper (SALT_KEEPER_ADDR) pushes the batch:
cast send 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6 "refillSalts(bytes32[])" "[0x..,0x..]" --private-key $KEEPER_PK --rpc-url $R
cast call 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6 "depth()(uint256)" $R  # > 0
```
Anchor already carries a starter batch of 8 in `deploy/anchor.json.hookSalts`.

---

## 5. ABORT / RESTART

- **`deployed != predicted`** on any script → STOP. Means: wrong key, or the address
  is occupied (front-run via a compromised anchor key). Do not proceed. Rotate the
  anchor key, re-derive the anchor from a **new phrase**, re-run from §0.
- **extcodehash ≠ recorded** on a read-back → STOP. Wrong code at a wired address.
- **A fork dry-run reverts** → an env/calibration/gate problem. Fix before mainnet;
  costs nothing.
- There is **no partial-recovery** of a mis-wired immutable. A wrong constructor value
  (economics, destinations) means redeploying that organ at a *new* salt/address and
  re-wiring everything that referenced it. This is why §0 calibration is a hard gate.

---

## 6. WHAT REMAINS OUT OF THIS RUNBOOK

- **Hook / template deploys** go through the *live factory* (`deployTemplate`, pulling
  a salt from the salt pool) — not this runbook. This runbook stands up the foundation
  the factory then deploys onto.
- **x402Core toll → Heart re-route** is a later x402Core edit (x402Core keeps its own
  pool for now); it is subject to the same "changing an anchored contract = re-found"
  cascade, so decide it before anything wires to x402Core beyond the pool's source set.

*Deploy layer authored by the Code Integrity seat. The economic calibration (§0) and
the line-211 edit (§0) are council/Architect gates — this runbook does not certify them.*
