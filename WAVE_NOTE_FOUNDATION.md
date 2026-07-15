# WAVE NOTE — FOUNDATION DEPLOY (Base mainnet, one-time)

**Companion to `RUNBOOK_FOUNDATION.md`.** This note carries the ratified inputs
and the offline-predicted addresses for the SaltPool → Pool → Factory sequence,
so they survive between the prep session and the wave. Every address below is
**pure CREATE/CREATE3 math — nothing here was signed or broadcast.** Predictions
are re-derivable: re-run `script/PredictCreate3Addresses.s.sol` with the recorded
deployer + nonce (factory) or the recorded salts (organs) and you get these
exact values back.

Prep run: 2026-07-15. Target wave: 2026-07-20.

---

## Ratified inputs

| Item | Value | Source |
|---|---|---|
| **DEPLOYER (Base)** | `0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9` | §0.8 — one deployer key, risk accepted |
| **CreateX caller (organs)** | `0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9` (SAME as deployer) | §0.6 — one key owns the whole foundation |
| **Deployer nonce `N`** | **56** (`0x38`, read 2026-07-15 via `mainnet.base.org`) | §II-1 |
| **Operator vs treasury** | **DISTINCT** (two different addresses — confirmed) | §0.2 / P-3 |
| Operator / treasury addresses | held off-repo, exported at broadcast only | §0.2 |

**Nonce plan** (all three txs from the one deployer):

| Tx | Nonce | Method |
|---|---|---|
| SaltPool | `N` = **56** | CREATE |
| Pool | `N+1` = **57** | CREATE |
| Factory | `N+2` = **58** | CREATE ← factory address predicted from this |

⚠️ **The deployer must go quiet.** It had 56 prior txs at prep time. The factory
prediction below holds ONLY while the key stays at nonce 56 until SaltPool
broadcasts. Any unrelated tx from this key bumps the nonce and moves the factory
address. §III-1 / §III-3 nonce read-backs are the mechanical catch.

---

## Predicted addresses

### Factory — `FACTORY_ADDR`
```
0x67247eB2108E7229331127DF1309D624d95467ca
```
CREATE = keccak256(rlp(`0x9ce4…a6c9`, 58)). Feeds **SaltPool** (`FEE_SOURCE_ADDR`,
§0.4, natural value = factory) AND **Pool** `source[0]`.

### x402Core — `X402CORE_ADDR`
```
0xBA5D2c36a6d0c8dBF26A49f64D5C81f4F664912B
```
CREATE3, sender-locked to `0x9ce4…a6c9`.
**SALT (deploy with EXACTLY this, from EXACTLY that caller):**
```
X402CORE_SALT=0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c900ba18264ed5710fef5a347f
```
guardedSalt `0xb47744677f9fecd63d7d2c3016ec69e9d4a8b9be3418cc6a32e64a7425c38d4e`

### Whisky market — `WHISKY_MARKET_ADDR`
```
0x2F14B795ce6999d71F660100a607CE5A52363cec
```
CREATE3, sender-locked to `0x9ce4…a6c9`. In the pool set per §0.1 (RATIFIED IN).
**SALT (deploy with EXACTLY this, from EXACTLY that caller):**
```
WHISKY_MARKET_SALT=0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c90005fc69b055da7b33575149
```
guardedSalt `0xd6b4a3ff147f6fa15781145ac4419dc436d3e43b6b05c433c1c762f37df60716`

**Pool immutable source set** = `[FACTORY_ADDR, X402CORE_ADDR, WHISKY_MARKET_ADDR]`
→ `authorizedSourceCount()` must read **3** post-deploy (§III-2, whisky included).

---

## Ratified pool params (§0.3, PR #26) — export verbatim at §III-2

```
POOL_OPERATIONAL_CAP=10000000000     # 10,000 USDC
POOL_ABSOLUTE_FLOOR=500000000        # 500 USDC
POOL_FLOOR_PER_UNIT=5000000          # 5 USDC
POOL_VELOCITY_HALFLIFE=604800        # 7 days
```

---

## Still OPEN before the wave (not predictable — Architect supplies)

| # | Item | State |
|---|---|---|
| §0.7 | **Keeper key** `SALT_KEEPER_ADDR` — fresh, compute-only, never a money dest | **TODO** — generate a new key; goes into SaltPool constructor |
| §0.5 | **Template + `TEMPLATE_CODEHASH`** for the $1 factory | **TODO** — name the template; codehash from `optimizer_pool.json` at §I-4 |
| §0.2 | Operator + treasury addresses | held off-repo; exported at §III-1/§III-2 broadcast |
| §I-1 | Ratified commit hash (the build codehashes freeze from) | recorded day-of, at pre-flight |

Everything else on the critical path is resolved. The two TODOs above are the
only inputs still missing before §III can run end-to-end.
