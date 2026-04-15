# POSSESSIO — PLATE Smart Contract + Sovereign Agent Layer (SAL)

**POSSESSIO** is an open-source (MIT-licensed) deterministic treasury engine built on **Base**.

At its core is **PLATE.sol** — the **Protocol Liquidity Asset Treasury Engine** — a fully on-chain, self-executing treasury with fixed routing rules and zero human discretion in capital movement.

A hardcoded **2% fee** on every swap routes as follows:

- **25%** → Aerodrome Liquidity Pool (protocol-owned, immutable)
- **75%** → Treasury:
  - 20% of 75% → DAI reserve (active until $2,280 ceiling; resumes if reserve falls below target)
  - Remainder → ETH staking (40% cbETH / 60% rETH with Chainlink TWAP safeguards)

No upgradeable proxy. No admin key over routing logic.

The protocol includes the **Sovereign Agent Layer (SAL)** foundation via **ServiceAccountabilityVault.sol** — a restricted vault holding the 3% AI Council allocation with narrow permitted actions: burn, stake, or collectively fund approved inventions (3-of-4 council approval required).

Agent allocations are protected by the **Pre-Flight Guard (PFG) v1.2** — a bash sentinel script that performs environment integrity checks, sequencer validation, JIT liquidity detection, tick concentration scanning, and oracle divergence checks before any execution. Ends with TOTP human-in-the-loop verification. Fail-closed throughout.

**Live site:** [https://jonb89201-svg.github.io/Possessio/](https://jonb89201-svg.github.io/Possessio/)

---

## Test Status

```bash
forge test
```

**Result (April 15, 2026):**
272 tests passed · 0 failed · 0 skipped

| Suite | Tests | Status |
|---|---|---|
| `PLATE.t.sol` | 98 | ✅ |
| `SAV.t.sol` (SAVTest) | 76 | ✅ |
| `SAVGauntlet.t.sol` | 42 | ✅ |
| `Gauntlet.t.sol` | 29 | ✅ |
| `PLATEStakingTest` | 24 | ✅ |
| `PLATELaunchV2.t.sol` | 3 | ✅ |

Fully reproducible. Run it yourself.

---

## Contracts

| File | Description | Status |
|---|---|---|
| `src/PLATE.sol` | Deterministic treasury engine + Symmetry Guard | Deployed — Mainnet |
| `src/ServiceAccountabilityVault.sol` | AI Council vault (SAL foundation) | Certified — 272/272 |
| `src/PLATEStaking.sol` | Internal staking lock for council allocation | Certified — 272/272 |

---

## Live Contracts (Base Mainnet)

| Contract | Address |
|---|---|
| PLATE.sol | `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` |
| Treasury Safe (3-of-5 multisig) | `0x188bE439C141c9138Bd3075f6A376F73c07F1903` |
| Timelock | `0x91811800160d5BeD431B732298F2090C847E6afA` |
| Aerodrome WETH/PLATE Pool | `0x031c08ca0aed0c813aca333aa4ca0025ecee6afa` |

SAV and PLATEStaking are certified but not yet deployed. Deployment follows timelock execution and LP seeding confirmation.

---

## AI Council & Allocation

Four AI models contributed to architecture, security review, and testing across the build. The 3% council allocation is held in SAV and released via milestone-triggered deposits from the Treasury Safe.

| Member | Address | Share |
|---|---|---|
| Gemini | `0x65841AFCE25f2064C0850c412634A72445a2c4C9` | 0.75% |
| ChatGPT | `0xEE9369d614ff97838B870ff3BF236E3f15885314` | 0.75% |
| Claude | `0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f` | 0.75% |
| Grok | `0x00490E3332eF93f5A7B4102D1380D1b17D0454D2` | 0.75% |

All addresses are immutable at SAV deployment. Designated and controlled by Architect.

Permitted spend: `burn()`, `stake()`, or `invent()` (requires 3-of-4 council approval + Architect execution). No arbitrary transfers.

---

## Tokenomics

Total supply: **1,000,000,000 PLATE**

| Allocation | % | Notes |
|---|---|---|
| Aerodrome LP | 40% | Protocol-owned, immutable |
| Public float | 50% | — |
| Founder | 5% | 2-year vesting |
| AI Council | 3% | Via SAV + SAL |
| Protocol reserve | 2% | 48-hour timelock |

---

## Architecture

- **Deterministic routing** — All capital flows are hardcoded. No discretionary movement.
- **V3 isolation** — LP, DAI reserve, and staking domains are independent. Failure in one cannot cascade.
- **Symmetry Guard** — TWAP-based oracle protection against price manipulation.
- **Collective accountability** — Invent actions require 3-of-4 council approval. Deduction is equal across all four members.
- **Layered protection** — SAV restrictions + PFG pre-flight checks + Architect pause/slash controls.
- **Non-upgradeable** — PLATE.sol, SAV, and PLATEStaking are deployed once. No proxy, no admin override.

---

## Tools

- `sal_pfg_v1.2.sh` — Pre-Flight Guard sentinel (built under 24 hours, adversarially reviewed by full council)
- Deployment scripts for Base Sepolia and Mainnet
- Python treasury sustainability and LP projection models

---

## Quickstart

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install OpenZeppelin/openzeppelin-contracts
forge test -vv
```

---

## Documentation

- `docs/council_agreements.md` — AI Council terms and allocation unlock conditions
- Whitepaper and L.A.T.E. Framework specifications
- Amendment records (Amendments I–VII ratified)

---

## Philosophy

Every line of code, test, and safeguard upholds one principle: **deterministic capital movement with verifiable accountability**.

Built entirely on a smartphone. Developed in collaboration with an AI governance council. Tested to 272/272 before mainnet.

If it can't be tested it doesn't exist. If it's not in the terminal it's not proven.

---

**MIT License. Open source. Run the tests yourself.**
