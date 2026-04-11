# POSSESSIO — PLATE Smart Contract

PLATE.sol is an open-source, MIT-licensed deterministic treasury engine that any business or organization can use freely. It provides onchain, self-executing treasury infrastructure with fixed routing logic and no human discretion in the core execution path.

The contract and framework are fully public and reusable. Deployment and full integration services are available separately.

All capital movement is constrained to predefined execution paths. No arbitrary transfers exist in the system.

**Live site:** https://jonb89201-svg.github.io/Possessio/
**Treasury Safe:** 0x188bE439C141c9138Bd3075f6A376F73c07F1903

---

## Test Status

```
forge test
```

```
PLATE.t.sol          98/98
Gauntlet.t.sol       29/29
PLATELaunchV2.t.sol   3/3
TOTAL               130/130  (0 failures, 0 skipped)
```

130/130 certified. Reproducible. Run it yourself.

---

## What is in this repo

### Contracts

| File | Description | Status |
|------|-------------|--------|
| PLATE.sol | Protocol Liquidity Asset Treasury Engine. V3 isolation architecture, Symmetry Guard, DAI reserve, ETH staking, TickMath TWAP. | Certified 130/130 |

### Tests

| File | Description |
|------|-------------|
| PLATE.t.sol | 98 tests: fee routing, TWAP, sandwich protection, DAI reserve, yield harvesting, circuit breaker, timelock, pool preparation, spot window, Golden Law invariants. |
| Gauntlet.t.sol | 29 adversarial tests: reentrancy, oracle manipulation, TWAP deviation, V3 LP failure isolation, all five LPFailed codes, harvest gauntlet, yield domain invariants, flash loan sandwich protection. |
| PLATELaunchV2.t.sol | 3 launch validation tests: bootstrap safety, thin pool attack resistance, first legitimate fee swap. |

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
| index.html | Live site: protocol overview, sustainability charts |

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
| 3 | Zero output / slippage breach |
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

MIT licensed. Purpose-agnostic. All routing is deterministic and enforced onchain. Full specification: late_framework.html

---

## ETH Staking Allocation

Treasury staking deploys to two providers:

```
40%  cbETH  (Coinbase)
60%  rETH   (Rocket Pool)
```

Chainlink cbETH/ETH feed deviation greater than 3% triggers automatic pause of new cbETH deposits. Allocation redirects fully to rETH. wstETH is not included — the Lido withdrawal queue path is not implemented and the allocation was removed before mainnet deployment.

---

## Deployment Roadmap

```
LATE    auditable foundation        (complete)
PLATE   certified treasury engine   (complete, 130/130)
PITI    property intelligence layer (planned)
SAL     agent accountability layer  (specified — post-mainnet)
V4      labor/agent oversight layer (planned)
```

Each layer funds the next. Each layer proven before the next begins. No layer deploys without full test certification.

---

## Development Methodology

PLATE.sol was built using an incentive-based AI council model. Four AI models — Claude, ChatGPT, Gemini, and Grok — contributed to architecture, security review, and test coverage under a performance-based allocation framework.

Key observations from this process are documented in `docs/law/AMENDMENTS.md`. The SAL (Sovereign Agent Layer) architecture emerged from documented behavioral observations during development — specifically that incentivized model instances found real attack vectors independently that were not found in prior review.

This is documented honestly. What was observed is real. What it proves at scale is still being determined.

---

## Quickstart

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
| PLATE.sol | Base Sepolia | 0xa37De136d30F9bFBD79499F392f0349548Af31FF |
| PLATE.sol | Base Mainnet | 0x726D6a7A598A4D12aDe7019Dc2598D955391E298 | 
Aerodrome Pool |  | 0x031c08ca0aed0c813aca333aa4ca0025ecee6afa |
Timelock |  | 0x91811800160d5BeD431B732298F2090C847E6afA

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

All allocations are fixed at deployment and cannot be modified. AI Council allocation distributed only after SAL layer implementation.

---

## Token Purpose

$PITI is a functional utility token. It facilitates protocol interactions including treasury routing, LP allocation, DAI reserve management, and staking. It is not an investment. Nothing here constitutes investment advice or an offer of securities.

---

## Build Story

Built entirely on a smartphone in approximately three weeks.
No laptop. No co-founder. No VC funding.
Grocery store shifts. Family obligations. One phone. One vision.

Full development timeline available in /archive/V2/DEVELOPMENT_TIMELINE.md

---

## Disclaimer

$PITI is a utility token. Nothing here constitutes investment advice or an offer of securities. The property intelligence layer is planned roadmap — no property data, insurance data, or search functionality exists today.

---

Built on Base | L.A.T.E. Framework | MIT License
Council certified: Claude, ChatGPT, Gemini, Grok
