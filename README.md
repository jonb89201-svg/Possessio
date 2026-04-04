# POSSESSIO Protocol

PLATE.sol — a smart contract that securely manages funds. For anyone. Any business.

Built on the L.A.T.E. Framework. Deployed on Base Sepolia. Certified 104/104.

**Live site:** https://jonb89201-svg.github.io/Possessio/

---

## What's in this repo

### Contracts

| File | Description | Status |
|---|---|---|
| `PLATE.sol` | Protocol Liquidity Asset Treasury Engine — fee routing, DAI reserve, diversified ETH staking, TickMath TWAP, MEV protection, 48-hour timelock. | ✅ Deployed — Base Sepolia |
| `PITI.sol` | Full POSSESSIO property intelligence protocol — planned. | Pending |

### Tests

| File | Description |
|---|---|
| `PLATE.t.sol` | Foundry test suite — 104/104 tests. 88 functional, 16 adversarial. Zero failures. Optimizer enabled. |

### Archive

| Location | Description |
|---|---|
| `/archive/V2/` | Certified build record — FUNCTIONAL_BASELINE.md, ADVERSARIAL_SUITE.md, TEST_REPORT.txt, ENVIRONMENT.md, DEVELOPMENT_TIMELINE.md, REPRODUCE.md |

### Documentation

| File | Description |
|---|---|
| `possessio_whitepaper.html` | Protocol whitepaper |
| `late_framework.html` | L.A.T.E. Framework specification |

### Frontend

| File | Description |
|---|---|
| `index.html` | Live site |

---

## The L.A.T.E. Framework

**Liquidity and Treasury Engine** — an open source flywheel business model. MIT licensed.

```
Every swap generates a 2% fee
25% → Liquidity Pool (immutable, permanent price floor)
75% → Treasury
        20% of treasury → DAI reserve (until $2,280 target met)
        Remainder → ETH staking (20% cbETH / 40% wstETH / 40% rETH)
Yield splits: 25% back to LP · 75% stays in treasury
```

Purpose-agnostic. Any organization with token-denominated transaction volume can implement it. MIT licensed — no permission required.

---

## Security Features

| Feature | Specification |
|---|---|
| MEV protection | 24-hour delay between fee swaps |
| Sandwich protection | TickMath TWAP price oracle |
| Parameter changes | 48-hour timelock on all changes |
| Depeg monitor | cbETH auto-pauses at 3% below peg |
| Circuit breaker | Emergency pause — 48-hour timelock to resume |
| Treasury | 3-of-5 multisig Safe |
| Reentrancy | OpenZeppelin ReentrancyGuard |

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

# Run with optimizer (matches deployment)
forge test --optimizer-runs 200
```

---

## Deployed Contracts

| Contract | Network | Address |
|---|---|---|
| PLATE.sol | Base Sepolia | `0xa37De136d30F9bFBD79499F392f0349548Af31FF` |
| Treasury Safe (3-of-5) | Base | `0x188bE439C141c9138Bd3075f6A376F73c07F1903` |
| $PITI Token | Base mainnet | Pending deployment |

---

## Token Distribution — $PITI

1,000,000,000 total supply. No presale. No VC allocation.

```
400,000,000 (40%) — Aerodrome LP (protocol-owned, immutable)
500,000,000 (50%) — Public float (open market, fair launch)
 50,000,000  (5%) — Founder (vesting terms defined before mainnet)
 30,000,000  (3%) — AI Council (performance-based via SAL — planned)
 20,000,000  (2%) — Protocol reserve (48-hour timelock, 3-of-5 governance)
```

---

## Roadmap

All items below are planned. Only what is marked ✅ exists today.

```
✅ PLATE.sol — deployed Base Sepolia, 104/104 certified
✅ Treasury Safe — confirmed on Base
⏳ Mainnet deployment — pending
⏳ POSSESSIO property intelligence layer — planned
⏳ piti.sol registry — planned
⏳ ARCH labor infrastructure layer — concept only
```

---

## Reproduce the Build

See `/archive/V2/REPRODUCE.md` for exact reproduction instructions.

Built entirely on a smartphone in 13 days for approximately $300.

---

## Disclaimer

$PITI is a utility token. Nothing in this repository constitutes investment advice or a promise of financial return. All roadmap items are planned and subject to change. PLATE.sol is currently deployed on Base Sepolia testnet. Do not send funds to testnet addresses.

---

*Built on Base · L.A.T.E. Framework · MIT License*
