# POSSESSIO Protocol

A free public property intelligence index on Base. Insurance carrier withdrawals, True PITI calculations, and DEED scores for 158 million U.S. properties — no login, no ads, no token required to search.

**Live site:** https://jonb89201-svg.github.io/Possessio/

---

## What's in this repo

### Contracts

| File | Description | Status |
|------|-------------|--------|
| `LATE.sol` | L.A.T.E. Framework — base flywheel contract. Open source, any purpose, MIT license. | Ready for testnet |
| `PLATE.sol` | Protocol Liquidity Asset Treasury Engine — POSSESSIO treasury mechanics. DAI reserve, diversified ETH staking, TickMath TWAP. | Ready for testnet |
| `PITI.sol` | Full POSSESSIO protocol — agents, SBT reputation, USD rewards, full L.A.T.E. architecture. | Pending PLATE audit |

### Tests

| File | Description |
|------|-------------|
| `PLATE.t.sol` | Foundry test suite — 49 tests covering fee routing, TWAP fallback, sandwich protection, DAI reserve, yield harvesting, circuit breaker, and timelock flows. |

### Documentation

| File | Description |
|------|-------------|
| `possessio_whitepaper.html` | Full POSSESSIO protocol whitepaper |
| `late_framework.html` | L.A.T.E. Framework specification — open standard for any organization |
| `treasury_model.py` | Treasury sustainability model at $20K/day volume |
| `lp_projection.py` | LP depth projection — four sources modeled |

### Frontend

| File | Description |
|------|-------------|
| `index.html` | Live site — property search, Humanity Gate, sustainability charts |

---

## The L.A.T.E. Framework

**Liquidity and Treasury Engine** — an open source flywheel business model.

```
Every swap generates a fee
25% → Liquidity Pool (immutable)
75% → Treasury (yield-bearing)
Yield splits: 25% back to LP · 75% funds operations
```

The framework is purpose-agnostic. POSSESSIO uses it to fund a free property intelligence index. What you use it for is your decision. MIT licensed — no permission required.

Full specification: `late_framework.html`

---

## Deployment Sequence

Three contracts deploy in order. Each launch funds the next audit.

```
Launch 1 — LATE.sol
Pure flywheel foundation
2% fee · 25/75 split · open source

Launch 2 — PLATE.sol  
POSSESSIO treasury mechanics
DAI reserve · ETH staking · TickMath TWAP

Launch 3 — PITI.sol
Full POSSESSIO protocol
Agents · SBT reputation · 1% fee
```

---

## Running Tests

Requires [Foundry](https://getfoundry.sh/).

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Run tests
forge test -vvv

# Run with gas report
forge test --gas-report

# Fuzz testing
forge test --fuzz-runs 10000
```

---

## Live Contracts on Base

| Contract | Address |
|----------|---------|
| Treasury Safe (3-of-5) | `0x188bE439C141c9138Bd3075f6A376F73c07F1903` |
| L.A.T.E. Split Contract | `0xB20B4f672CF7b27e03991346Fd324d24C1d3e572` |
| $PITI Token | Pending deployment |

---

## Token Distribution — $PITI

1,000,000,000 total supply. No presale. No VC allocation.

```
400,000,000 (40%) — Aerodrome LP (protocol-owned, immutable)
500,000,000 (50%) — Public float (open market)
 50,000,000  (5%) — Founder (2-year vesting)
 30,000,000  (3%) — Technical Co-Founder (4-year vesting, 1-year cliff)
 20,000,000  (2%) — Protocol reserve (48-hour timelock)
```

---

## Disclaimer

POSSESSIO is a data aggregator, not a licensed insurance producer or financial advisor. All content is for informational purposes only. $PITI is a utility token. Nothing here constitutes investment advice.

---

*Built on Base · L.A.T.E. Framework · MIT License*
