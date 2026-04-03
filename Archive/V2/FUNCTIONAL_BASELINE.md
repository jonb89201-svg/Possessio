# POSSESSIO PLATE.sol — Functional Baseline
**Version:** V2 — 104/104 certified
**Contract:** `src/PLATE.sol`
**Commit:** pin at deployment
**Date:** April 2, 2026

---

## What PLATE.sol Does

PLATE.sol is the Protocol Liquidity Asset Treasury Engine for the POSSESSIO protocol. It receives ETH, routes it across three isolated domains, and manages yield harvesting back to the treasury.

---

## ETH Routing Architecture

Every ETH payment received by the protocol is routed through `routeETH()`:

```
routeETH(msg.value)
├── 25% → _addLiquidity()      [LP domain]
├── 15% → _swapETHToDAI()      [DAI reserve domain]
└── 60% → _deployToStaking()   [Staking domain]
```

All percentages are defined as immutable constants at deployment. The global split cannot be changed after deployment.

---

## V3 Isolation Model

Each domain fails independently. A failure in one domain cannot affect another.

```
LP failure:
· _addLiquidity() emits LPFailed event
· Returns without reverting
· ETH remains available for downstream
· No capital is consumed on failure

DAI failure:
· _swapETHToDAI() reverts locally
· Falls back to treasury
· Staking domain unaffected

Staking failure:
· _deployToStaking() reverts locally
· Falls back to treasury
· LP and DAI domains unaffected
```

---

## Symmetry Guard

Every ETH → PLATE swap checks TWAP deviation before executing.

```
If spot price deviates > maxDeviationBps from TWAP:
· Emit LPFailed(ethAmt, reason_code)
· Return without executing swap
· No ETH consumed
· No LP position created
```

Default threshold: `maxDeviationBps = 500` (5%)

This protects against flash loan manipulation on the LP swap path.

---

## LPFailed Event Codes

| Code | Reason |
|------|--------|
| 1 | TWAP deviation exceeded (Symmetry Guard) |
| 2 | Swap execution failed |
| 3 | Slippage tolerance breached |
| 4 | LP add failed |
| 5 | No valid price available |

---

## Core Invariants

These invariants are enforced by the test suite and hold across all 104 test cases:

```
1. Global split is immutable
   LP/DAI/Staking percentages cannot change

2. LP failure is a local no-op
   ETH does not leave the contract on LP failure

3. Zero residual balance
   No ETH stranded in contract after routing

4. TWAP deviation protection
   No swap executes above maxDeviationBps

5. Treasury receives all fallback funds
   No ETH is lost on any failure path
```

---

## Token

```
Name:         PLATE
Total supply: 1,000,000,000 (1 billion)
Standard:     ERC-20
Owner:        0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9
```

---

## Distribution

```
400,000,000 (40%) — Aerodrome LP (protocol-owned, immutable)
500,000,000 (50%) — Public float
 50,000,000  (5%) — Founder (2-year vesting)
 30,000,000  (3%) — AI Council (performance-based via SAL)
 20,000,000  (2%) — Protocol reserve (48-hour timelock)
```

---

## Deployed Addresses

| Network | Address |
|---------|---------|
| Base Sepolia | 0xa37De136d30F9bFBD79499F392f0349548Af31FF |
| Base Mainnet | Pending D Day deployment |

---

## Verification

```bash
git clone https://github.com/jonb89201-svg/Possessio
forge install OpenZeppelin/openzeppelin-contracts
forge test -vvv
```

Expected result: 104 tests passed, 0 failed.

---

*All claims in this document derive from PLATE.sol source code and the certified test suite. Nothing is invented or overstated.*
