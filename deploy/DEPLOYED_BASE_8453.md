# POSSESSIO constellation — Base mainnet (8453)

Deployed 2026-07-28. Four organs, four transactions, one anchor key.

**Every value below was read from Base by `eth_call` / `eth_getCode`, not from a
deploy log.** A broadcast log records what a script *intended* to send. This
records what the chain *actually holds*, and anyone can re-derive all of it from
the addresses in the first table — see [Reproducing this](#reproducing-this).

---

## 1. The four organs

| Organ | Address | Runtime | Runtime codehash |
|---|---|---|---|
| **PossessioPool** (the Heart) | `0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce` | 2,685 B | `0xd65bdb12f6202be1afaa073850deaaa20d511ccc7f6bea5694a5b70c0e3b79de` |
| **PossessioX402Core** | `0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05` | 8,942 B | `0xdeacf81179df69b0cd9952bd7d1891d5f09443d3ae10f8dc517d000c06f8f9e3` |
| **PossessioFactory** | `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd` | 2,479 B | `0x4da7983d61a320b0b8e6a06f9a014635920a89c9491eef459e061007f68ab9d5` |
| **PossessioSaltPool** | `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6` | 858 B | `0xf289e4825de5fab151e8a076a3d35cc1911f5f3df1455f16c8ffede3bde90fce` |

All four landed on **exactly** the addresses `deploy/anchor.json` predicted
before any of them existed.

**Anchor EOA** `0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC` — **nonce 4**.

That nonce is the tightest statement available here: four deploys, no fifth, no
rehearsal, nothing else ever signed by this key on this chain. The addresses are
CREATE3 (`f(deployer, guardedSalt)`, initcode-independent) and the salts are
sender-locked — the anchor's address is the first 20 bytes of each — so no other
key could have produced them.

---

## 2. The wiring, verified from chain

The constellation is a closed ring, and each link was checked from the live
contract rather than assumed from the deploy arguments.

| Read | Value | Means |
|---|---|---|
| `Pool.isInfraSink()` | `true` | The brick-guard both later constructors staticcall |
| `Pool.isAuthorizedSource(factory)` | `true` | ✅ |
| `Pool.isAuthorizedSource(x402Core)` | `true` | ✅ |
| `Pool.isAuthorizedSource(0x…dEaD)` | `false` | The gate is a gate, not an open door |
| `Factory.feeSink()` | `0xE0612f38…` | Deploy fees route **into** the Heart (wiring A) |
| `Factory.saltPool()` | `0x7181a6Da…` | ✅ |
| `SaltPool.factory()` | `0x0DD06656…` | ✅ |

### Why this ordering was forced, and why it is load-bearing

`authorizedSources` is written **once**, inside the Pool's constructor loop.
There is no `addSource` and no setter. It was sealed at `[factory, x402Core]`
from **predicted** addresses at a moment when neither contract existed.

Both later constructors then staticcall `isInfraSink()` on the Heart and revert
`FeeSinkInterfaceMismatch` if it is not live — so the Pool had to land first, and
its guess about the others had to be right, permanently, on the first try.

Both halves of that handshake now read `true` from chain. The Pool named two
addresses that did not exist; those addresses exist and are exactly who it named.

Order: **Pool → x402Core → Factory → SaltPool** (`RUNBOOK_CONSTELLATION` §2).

---

## 3. Economics as deployed

Every value immutable, no setters. Matches `DEPLOY_CALIBRATION` §22 to the unit,
and the live cold floors read identical to tests `D2` and `X2` in the
deploy-value suites.

### PossessioPool (the Heart)

| | |
|---|---|
| `OPERATIONAL_CAP` | `700000000` — $700 |
| `ABSOLUTE_FLOOR` | `60000000` — $60 |
| `FLOOR_PER_UNIT` | `20000000` — $20 |
| `VELOCITY_HALFLIFE` | `604800` — 7 days |
| `operatorDestination` | `0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9` |
| `treasuryDestination` | `0x19495180FFA00B8311c85DCF76A89CCbFB174EA0` |
| `getRunningMinimumFloor()` | `60000000` — cold floor exactly $60 |
| `poolBalance` | `0` |

The Heart keeps only the minimum; everything above `OPERATIONAL_CAP` sweeps
one-way to treasury. `operatorDestination` is both the only caller of
`settleOperationalCosts` and its recipient. `treasuryDestination` receives and
never signs.

### PossessioX402Core

| | |
|---|---|
| `heartSink` | `0xE0612f38…` — the live Heart |
| `payToken` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` — canonical Base USDC |
| `OPERATIONAL_CAP` | `150000000` — $150 |
| `ABSOLUTE_FLOOR` | `15000000` — $15 |
| `FLOOR_PER_UNIT` | `5000000` — $5 |
| `VELOCITY_HALFLIFE` | `86400` — 1 day |
| `REGISTRATION_FEE` | `5000000` — $5 |
| `DUST_FLOOR` | `1000000` — $1 |
| `HANDSHAKE_ROOT` | `bytes32(0)` |
| `getRunningMinimumFloor()` | `15000000` — cold floor exactly $15 |

`HANDSHAKE_ROOT = 0` is deliberate, not an oversight: the merkle allowlist is
retired and `registerOpen` replaces it at $5, open to anyone, no gatekeeper.
That a zero root does **not** brick the toll is proven by
`test_X8_zeroRoot_tollNotBricked` and `DoD12`.

### PossessioFactory

| | |
|---|---|
| `DEPLOYMENT_FEE()` | `50000000` — $50 |
| `feeSink()` | `0xE0612f38…` — the Heart |
| `payToken()` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `saltPool()` | `0x7181a6Da…` |
| `templateCodehash()` | `0x14357940f7396034c9139e740ca408c53ff33bf8d52f8a8a93e337bffb9ee39d` |

`templateCodehash` is **immutable per factory**. It pins
`type(PossessioPayments).creationCode` for the reshaped `(address, bytes)`
constructor. Any change to `PossessioPayments.sol` or its imports changes this
hash and bricks this factory, at a permanent address. The console's launch rail
reads this getter live and refuses to deploy on a mismatch.

### PossessioSaltPool

| | |
|---|---|
| `factory()` | `0x0DD06656…` |
| `keeper()` | `0x319E6728a3c326D7cCc8b406052E8B5dCf04e6B9` |
| `depth()` | **`0`** |

---

## 4. Open: the salt pool is empty

`depth() == 0`. Step 5 of `deploy/anchor.json`'s `deployOrder` — *"keeper refills
saltpool with hookSalts"* — has not run.

This does not affect the Account launch path, which does not draw from the salt
pool. It does mean any flow that requires a flag-mined `0x…08C8` hook salt has
nothing to draw. The eight mined salts are sitting in `deploy/anchor.json`
under `hookSalts`, unconsumed, and they are factory-keyed (first 20 bytes =
`0x0dd06656…`) so only the live Factory can spend them.

Recorded here as an open item rather than left to be discovered at the point of
use.

---

## 5. Reproducing this

Nothing above needs to be trusted. Given only the four addresses:

```bash
# every organ is live, and at its predicted address
cast code   0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce --rpc-url https://mainnet.base.org

# the ring closes
cast call 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce \
  "isAuthorizedSource(address)(bool)" 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd \
  --rpc-url https://mainnet.base.org
cast call 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd \
  "feeSink()(address)" --rpc-url https://mainnet.base.org

# four deploys from the anchor, and only four
cast nonce  0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC --rpc-url https://mainnet.base.org
```

The CREATE3 addresses themselves are recomputable from the phrase alone, with no
secret — see `deploy/anchor.json` `derivation`. Salts are public sender-locked
parameters; the anchor key is the only secret, and it is not needed to check any
claim on this page.

---

## A note on what this file is, and is not

`broadcast/` is gitignored and the Codespace that held the Factory and SaltPool
run logs went stale before they were committed. Those logs are gone.

This record is written from chain state instead, and that is the better artifact
in any case: a broadcast log is a local JSON file that anyone can edit and that
records intent, while every line here is a claim about Base that a reader can
falsify in one `cast` call. The Pool and x402Core figures reproduced above match
the values recorded independently at broadcast time (PR #69), which is a
corroboration the log alone could not provide.

Deploy transaction hashes remain recoverable from the anchor EOA's transaction
history on any Base explorer — four transactions, nonces 0–3.
