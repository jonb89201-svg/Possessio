# POSSESSIO Protocol

A real property intelligence protocol on Base. Insurance carrier withdrawals, True PITI calculations, and DEED scores for 158 million U.S. properties — no login, no ads, no token required to search.

**Live site:** https://jonb89201-svg.github.io/Possessio/
**Treasury Safe:** 0x188bE439C141c9138Bd3075f6A376F73c07F1903

---

## Test Status

```
forge test
```

```
PLATE.t.sol     88/88
Gauntlet.t.sol  16/16
TOTAL          104/104  (0 failures)
```

104/104 certified. Reproducible. Run it yourself.

---

## What is in this repo

### Contracts

| File | Description | Status |
|------|-------------|--------|
| PLATE.sol | Protocol Liquidity Asset Treasury Engine. V3 isolation architecture, Symmetry Guard, DAI reserve, ETH staking, TickMath TWAP. | Certified 104/104 |

### Tests

| File | Description |
|------|-------------|
| PLATE.t.sol | 88 functional tests: fee routing, TWAP, sandwich protection, DAI reserve, yield harvesting, circuit breaker, timelock. |
| Gauntlet.t.sol | 16 adversarial tests: reentrancy, oracle manipulation, TWAP deviation, V3 LP failure isolation, zero residual balance. |

### Deployment

| File | Description |
|------|-------------|
| script/Deploy.s.sol | Forge deployment script for Base Sepolia and mainnet. |

### Documentation

| File | Description |
|------|-------------|
| possessio_whitepaper.html | Full POSSESSIO protocol whitepaper |
| late_framework.html | L.A.T.E. Framework specification |
| treasury_model.py | Treasury sustainability model |
| lp_projection.py | LP depth projection model |

### Frontend

| File | Description |
|------|-------------|
| index.html | Live site: property search, sustainability charts |

---

## Architecture

### V3 Isolation Model

Failure in any domain cannot cascade into sibling domains.

```
routeETH(total ETH)
  25%  _addLiquidity()      LP domain
  15%  _swapETHToDAI()      DAI reserve domain
  60%  _deployToStaking()   Staking domain

LP failure:      local no-op, ETH stays for downstream
DAI failure:     local fallback to Treasury
Staking failure: local fallback to Treasury
```

### Symmetry Guard

Every ETH to PLATE swap checks spot vs TWAP deviation.

If deviation exceeds maxDeviationBps (default 500 bps / 5%):
- Emit LPFailed(ethAmt, 1)
- Return without swap
- No capital loss

Protects against flash loan manipulation on the LP swap path.

### LPFailed Event Codes

| Code | Reason |
|------|--------|
| 1 | TWAP deviation (Symmetry Guard) |
| 2 | Swap failed |
| 3 | Slippage breach |
| 4 | LP add failed |
| 5 | No valid price |

---

## The L.A.T.E. Framework

Liquidity and Treasury Engine. The open source flywheel at the core of POSSESSIO.

```
Every swap generates a fee
25%  Liquidity Pool (protocol-owned)
75%  Treasury (yield-bearing)
Yield: 25% back to LP, 75% funds operations
```

MIT licensed. Purpose-agnostic. Full specification: late_framework.html

---

## Deployment Roadmap

```
LATE    auditable foundation        (complete)
PLATE   certified treasury engine   (complete, 104/104)
PITI    property intelligence layer (planned)
V4      labor/agent oversight layer (planned)
```

Each layer funds the next. Each layer proven before the next begins.

---

## Running Tests

Requires Foundry (https://getfoundry.sh).

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install OpenZeppelin/openzeppelin-contracts
forge test -vv
```

---

## Live Contracts

| Contract | Network | Address |
|----------|---------|---------|
| Treasury Safe (multisig) | Base Mainnet | 0x188bE439C141c9138Bd3075f6A376F73c07F1903 |
| PLATE.sol | Base deployment | 0xa37De136d30F9bFBD79499F392f0349548Af31FF
| PLATE.sol | Base Mainnet | Pending deployment |

---

## Token Distribution

$PITI — 1,000,000,000 total supply. No presale. No VC allocation.

```
400,000,000  40%  Aerodrome LP (protocol-owned, immutable)
500,000,000  50%  Public float (open market)
 50,000,000   5%  Founder (2-year vesting)
 30,000,000   3%  AI Council (performance-based via SAL)
 20,000,000   2%  Protocol reserve (48-hour timelock)
```

---

## Token Purpose

$PITI is a functional utility token. It facilitates protocol interactions including treasury routing, LP allocation, DAI reserve management, and staking. It is not an investment. Nothing here constitutes investment advice or an offer of securities.

---

## Build Story

Built entirely on a smartphone in approximately 12 days for approximately $300.
No laptop. No co-founder. No VC funding.
Grocery store shifts. Family obligations. One phone. One vision.

---

## Disclaimer

POSSESSIO is a data aggregator, not a licensed insurance producer or financial advisor. All content is for informational purposes only. $PITI is a utility token. Nothing here constitutes investment advice.

---

Built on Base | L.A.T.E. Framework | MIT License
Council certified: Claude, ChatGPT, Gemini, Grok
