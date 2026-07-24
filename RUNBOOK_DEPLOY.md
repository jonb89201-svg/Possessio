# RUNBOOK — Deploy (single source of truth)

**This is the authoritative deploy runbook.** It consolidates the foundation
constellation, the trading desk, and the off-chain services into one ordered
sequence, and supersedes the deploy ordering in `RUNBOOK_FOUNDATION.md` and the
narrative in `RUNBOOK_CONSTELLATION.md` where they disagree. Detailed per-organ
gates still live in `RUNBOOK_CONSTELLATION.md`; this file is the map.

- **Chain:** Base mainnet (8453) for everything on-chain except the L1 anchor
  (Ethereum mainnet), which is a later phase.
- **Anchor:** `deploy/anchor.json` (recompute: `node script/derive_anchor.mjs`),
  derived from the phrase `TREGUNA_MEKOIDES_TRECORUM_SATIS_DEE`. Anchor EOA
  `0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC` — a wave-duration secret; its
  authority ends once the organs land (no organ has an owner; CreateX cannot
  redeploy an occupied address).
- **Immutability rule:** every contract here is immutable and self-custody. A
  wrong constructor value or a mis-predicted prewire is **not patchable** — it
  means redeploying that organ at a new salt/address and re-wiring everything
  that referenced it. That is why the pre-flight gates are hard gates.

Anchor addresses (from `deploy/anchor.json`):

| organ | address |
|---|---|
| pool (Heart) | `0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce` |
| x402Core | `0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05` |
| factory | `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd` |
| salt pool | `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6` |
| hook templates | end `0x8C8`, factory-keyed |

---

## Phase 0 — Pre-flight (nothing broadcasts until all true)

- [ ] **Source frozen** — no `.sol` / `foundry.toml` change from here until the wave lands (any edit changes the codehashes).
- [ ] **Economics calibrated, not placeholder** — `X402_ROOT`, `X402_DUST_FLOOR`, and every `*_OP_CAP` / `*_ABS_FLOOR` / `*_FLOOR_PER_UNIT` / `*_HALFLIFE`. These freeze as immutables.
- [ ] **`TEMPLATE_CODEHASH` regenerated from the FROZEN build:** run `bash deploy/sync_optimizer_pool.sh` and pin from its output — **not** from stale values. (`deploy/optimizer_pool.json` is now regenerated to the uniform runs=200 build; re-sync after the freeze so the pin matches the exact bytecode the factory will see.)
- [ ] **Anchor EOA funded on Base** (`cast balance $ANCHOR --rpc-url $BASE_RPC_URL` > 0).
- [ ] **Env in hand:** `SALT_KEEPER_ADDR` (fresh, compute-only), `OPERATOR_DEST_ADDR` + `TREASURY_DEST_ADDR` (passkey Base Account — never a hot EOA / the anchor key), `DEPLOYMENT_FEE`, `X402_FEE_SOURCE_ADDR`, `BASE_RPC_URL`.
- [ ] **Council line-211 A-edit in source** (`SPEC_Factory_FeeSink_A.md`) — else the factory strands fees at the anchor. The fork test's `poolBalance` assertion proves it live.
- [ ] **Anchor + phrase recorded off-machine.**

## Phase 1 — Fork-verify (spends zero ETH)

```
forge test --match-contract ConstellationCreate3ForkTest -vv    # foundation lands + wires
forge test --match-contract TradingDeskCreate3Test        -vv    # desk prewire reproduces
```
Then dry-run each deploy script against a Base fork (NO `--broadcast`) with your
real env values. A fork revert = a real env/gate/calibration problem; fix before
mainnet. The x402Core/factory/saltpool dry-runs assert their siblings are live, so
run them after the pool on a persistent local anvil-fork, or in order.

## Phase 2 — Foundation constellation (mainnet)

**ORDER (ratified council 2026-07-20): POOL → x402Core → factory → salt pool.**
The pool (Heart) lands first because x402Core and factory both brick-guard on
`pool.isInfraSink()` in their constructors. The pool bakes its two sources
(factory, x402Core) as their *predicted* CREATE3 addresses (read only at runtime),
so there is no circularity.

> ⚠️ `deploy/anchor.json` previously listed a stale `factory→saltpool→x402core→pool`
> order — corrected 2026-07-24 to match this. If any doc still shows factory-first,
> this runbook wins.

```
forge script script/DeployPoolCreate3.s.sol     --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_pool.txt
forge script script/DeployX402CoreCreate3.s.sol --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_x402core.txt
forge script script/DeployFactoryCreate3.s.sol  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_factory.txt
forge script script/DeploySaltPoolCreate3.s.sol --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast -vvv | tee deploy_saltpool.txt
```
Each script's internal gates (`deployed == predicted`, salt→address recomputed via
CreateX, siblings-must-be-live) abort on any mismatch. **After each, record the
logged `extcodehash`** (front-run gate).

## Phase 3 — Post-deploy read-backs (on-chain wiring gates)

```
cast call 0x7181a6…61B6 "factory()(address)"                         $R  # == factory
cast call 0x0DD0…49Bd "saltPool()(address)"                          $R  # == salt pool
cast call 0x0DD0…49Bd "feeSink()(address)"                           $R  # == pool
cast call 0xE061…19ce "isAuthorizedSource(address)(bool)" 0x0DD0…49Bd $R # true
cast call 0xE061…19ce "isAuthorizedSource(address)(bool)" 0x60d8…6c05 $R # true
# each organ's extcodehash == the value recorded in Phase 2
```
Any mismatch ⇒ **STOP** (see Phase 7).

## Phase 4 — Salt pool refill + hook/template deploys

```
node script/premine_salts.mjs --factory 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd --count N
cast send 0x7181a6…61B6 "refillSalts(bytes32[])" "[0x..,0x..]" --private-key $KEEPER_PK --rpc-url $R
cast call 0x7181a6…61B6 "depth()(uint256)" $R   # > 0
```
Hook/customer templates then deploy **through the live factory** (`deployTemplate`,
pulling a salt) — `script/DeployHookCreate3.s.sol`. A starter batch of 8 hook salts
is in `deploy/anchor.json.hookSalts`.

## Phase 5 — Trading desk (after the pool is live)

`script/DeployTradingDeskCreate3.s.sol` stands up **AutoTarget → FundingVault →
Rail** in one ordered script. The vault↔Rail prewire is immutable, so the script
predicts the Rail's CREATE3 address, deploys the vault pointed at it, deploys the
Rail into that slot, and verifies `vault.trader()==rail` post-deploy — reverting
rather than shipping a bricked pair. Proven offline by `TradingDeskCreate3Test`.

**Before running:** mine a msg.sender-locked salt for the desk EOA
(`MineCreate3Salt`), set `RAIL_SALT` + `RAIL_PREDICTED`. Env:
```
DEPLOYER_PK=<desk EOA>  USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
HEART_POOL=0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce   # the live pool from Phase 2
KEEPER=0x..  DEX_ROUTER=<Base SwapRouter02>  VAULT_OWNER=<passkey Base Account>
AT_PER_TX_FEE=..  MAX_PER_TRADE=..  MAX_OUTSTANDING=..  DAILY_DRAW_CAP=..
RAIL_SALT=0x..  RAIL_PREDICTED=0x..
forge script script/DeployTradingDeskCreate3.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv
```
The script refuses to run if `RAIL_PREDICTED` ≠ the CreateX-computed address, if the
salt is not sender-locked, or if `HEART_POOL` is not a live infra-sink.

## Phase 6 — Off-chain services (independent of the chain deploys)

- **Console worker** (`worker/`) + **radar worker** (`radar/`) → Cloudflare, auto-deployed by `.github/workflows/console-deploy.yml` and `radar-refresh.yml` on push to `main` (both run `npm ci` against committed lockfiles and `wrangler deploy`).
- **Mailer** (`mailer/`), **MCP servers** (`mcp/solana-mcp`, `mcp/council-signer`) → `wrangler` / their own deploy paths. Secrets via `wrangler secret put` (never committed): `TESTNET_OPERATOR_PK`, `RESEND_API_KEY`, `STATUS_KEY`, `SOLANA_RPC`, `ACCESS_KEY`, `COUNCIL_MCP_TOKEN`, `COUNCIL_SEAT_KEY`.

## Already live (Base mainnet, V3)

`LSTExchangeRate` and `PossessioPayments` are deployed (`script/DeployLSTRates.s.sol`,
`script/DeployPayments.s.sol`). Not part of the constellation wave.

---

## Phase 7 — Abort / restart

- **`deployed != predicted`** on any script → STOP. Wrong key, or the address is
  occupied (front-run via a compromised anchor key). Rotate the anchor key,
  re-derive from a **new phrase**, re-run from Phase 0.
- **extcodehash ≠ recorded** on a read-back → STOP. Wrong code at a wired address.
- **A fork dry-run reverts** → env/calibration/gate problem. Costs nothing; fix first.
- **No partial recovery of a mis-wired immutable.** A wrong constructor value means
  redeploying that organ at a new salt/address and re-wiring its references. This is
  why Phase 0 calibration is a hard gate.

---

## Open items that touch deploy (from AUDIT_20260724)

- **FIXED 2026-07-24:** the deploy-order drift (`anchor.json` now matches the ratified
  POOL-first order) and the stale codehashes (`optimizer_pool.json` regenerated from
  the uniform runs=200 build). Always re-run `deploy/sync_optimizer_pool.sh` after the
  Phase-0 source freeze so the pin matches the exact frozen bytecode.
- **DOC-6 (checked 2026-07-24 — PASS, with a caveat):** verified the anchor EOA private
  key is NOT reproduced by any common phrase-derivation scheme. Tested ~25 schemes against
  the anchor address `0xed5c1F…61eC` — `keccak256(phrase)`, `keccak256(phrase + "/"+tag)`
  for many tags (the repo's own salt-derivation style), lowercase/whitespace/prefix
  variants, double-keccak, `sha256(phrase)` brain-wallet forms, and `sha256→keccak` — with
  a positive control (anvil key #0) confirming the matcher works. **No match.** The phrase
  IS confirmed to derive the *salts* (`keccak256(phrase+"/factory")` and `.../pool` low-88
  bits reproduce the committed salts exactly) — those are public and sender-locked, useless
  without the key. BIP39 is not applicable (the phrase words are not in the wordlist). This
  rules out the dangerous brain-wallet mistake. **Caveat:** this is strong evidence, not
  proof — a bespoke/obscure KDF can't be brute-forced away. The key should have come from a
  CSPRNG independent of the phrase (`cast wallet new`, hardware wallet, or `os.urandom`);
  the Architect who generated it should confirm that origin. Reproduce this check:
  `cast wallet address --private-key $(cast keccak 'TREGUNA_MEKOIDES_TRECORUM_SATIS_DEE')`
  ≠ the anchor address.
