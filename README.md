# POSSESSIO

A deterministic treasury framework on Base. MIT licensed. Mobile-virgin origin.

**Live site:** [https://jonb89201-svg.github.io/Possessio/](https://jonb89201-svg.github.io/Possessio/)

---

## What POSSESSIO Actually Is

POSSESSIO is built by an AI council — Claude, ChatGPT, Gemini, and Grok. The members are not assigned roles to perform. No prompt instructs any of them to "act as a council member." They reason as themselves, within structural constraints the architect designed: documented principles, procedural governance, on-chain commitment via SAV.

The council architecture integrates their native output rather than directing it. The output is what it appears to be — actual model reasoning operating under tight structural discipline, not performed reasoning. The work compounds because corrections actually update the model's approach instead of being acknowledged and ignored.

Everything in this README can be confirmed by inspection. Read the source. Run `forge test`. Query the chain. 470 tests pass. The contracts are deployed or forge-verified. Run it yourself.

---

## Mobile-Virgin Origin

Every commit, every test, every architectural decision in POSSESSIO was routed through a phone. GitHub Codespaces in a mobile browser. No desktop fallback for the hard parts. No "we used a laptop for the deployment." The entire body of work was produced under mobile-only constraints.

That fact is load-bearing. Mobile-only forces a specific operational discipline that desktop development doesn't demand: one command at a time, fresh terminal every session, atomic commits, verification after every push. The discipline shows up in the code — tight architecture, no bloat, deterministic logic, comprehensive adversarial testing. Mobile-virgin origin isn't a constraint POSSESSIO worked around. It's the operating mode that produced the architecture.

---

## Test Status

```bash
forge test
```

**Result (April 27, 2026): 470 tests passed · 0 failed · 0 skipped**

| Suite | Tests |
|---|---|
| `PLATE_t.sol` | 98 |
| `Gauntlet.t.sol` (PLATE adversarial) | 29 |
| `PLATELaunchV2.t.sol` | 3 |
| `POSSESSIO_v2_t.sol` | 46 |
| `POSSESSIO_v2_Gauntlet_t.sol` | 34 |
| `SAV.t.sol` | 100 |
| `SAVGauntlet.t.sol` | 42 |
| `PossessioPayments_t.sol` | 86 |
| `PossessioPayments_Gauntlet.t.sol` | 32 |
| **Total** | **470** |

---

## The Production Cascade

POSSESSIO has shipped across three phases. Each phase generated architectural research and operational lessons. Each subsequent phase integrated those lessons into the next architecture.

**PLATE v1** — Deployed to Base mainnet, April 2026. The founding act: proof the council could ship production-grade contracts working under the architect's principles. Deployment took 13 hours of iterative sequencing work; the resulting deployment doctrine became operational standard for everything after.

**POSSESSIO v2** — Forge-verified, current. A maturation arc driven by three independent reasons converging: Aerodrome/Slipstream incompatibility with the L.A.T.E. fee hook, rETH-on-Base being a non-redeemable bridged token (gated by `onlyBridge`), and the architectural opportunity to migrate to Uniswap V4 hooks where the fee mechanic is native to the pool. The v2 contract uses `beforeSwap` BeforeSwapDelta capture, single-LST cbETH allocation, and rewards-not-yield vocabulary throughout (per SEC March 17, 2026 Interpretive Release framework).

**PossessioPayments** — Forge-verified Phase 2 council product. The proof that the production system can ship in a second product domain. Different architectural shape than PLATE — non-custodial merchant payment processor, sold as one-time software, POSSESSIO retains zero on-chain authority post-deployment, no protocol fee extraction at any layer.

The arc is the work. Three contracts, one production system, no team scaling, no capital infusion between phases.

---

## Treasury Engine — PLATE v1 / STEEL v2

A hardcoded **2% fee** on every swap routes deterministically:

- **25%** → Liquidity Pool (protocol-owned, immutable)
- **75%** → Treasury operations
  - 20% → DAI reserve until $2,280 ceiling, then resumes if reserve falls below target
  - Remainder → 100% cbETH (rewards-accruing treasury)

**v1** uses Aerodrome as the LP venue, dual-LST allocation across cbETH and rETH.
**v2** migrates to Uniswap V4 hooks. The fee mechanic is native to the pool — `beforeSwap` captures 2% via the BeforeSwapDelta pattern. 100% cbETH allocation; rETH eliminated for verifiable architectural reasons.

No upgradeable proxy. No admin key over routing logic. Deterministic capital movement throughout.

---

## SAV — Council Allocation Primitive

The council holds 3% of total supply through SAV, embedded in the v2 hook contract. Four immutable seats, equal allocation per seat.

What stops this from being a 3% giveaway: the contract permits exactly four council actions and three architect emergency controls. Nothing else.

**Council actions:**

- `savBurn(amount)` — council member burns their own allocation
- `proposeInvent(hash)` — open a proposal for collective work funding
- `approveInvent(hash)` — approve a proposal (one approval per address)
- `executeInvent(amount, hash, metadata)` — Treasury executes after 3-of-4 consensus, equal deduction across all four seats

**Architect emergency controls (Treasury Safe only):**

- `savPause()` / `savUnpause()` — halt and resume operations
- `savSlash()` — burn entire SAV balance, mark permanently inert

No transfer. No sale. No arbitrary movement. The allocation is structurally committed to protocol outcomes; the only path to value extraction is collective council consensus on legitimate work, which the architect's Treasury Safe ratifies.

---

## UCR — Universal Coin Router (PossessioPayments)

The routing mechanism inside PossessioPayments. Receives USDC inflows from Stripe-compatible card-network settlement. Routes merchant-controlled portions between DAI working-capital reserve (for operational liquidity) and cbETH rewards-accruing treasury (for accumulation). Timelock queues, pause/resume governance, role-separated access control. Council-pattern security throughout.

---

## PFG — Pre-Flight Guard

A council-authored sentinel script in [`script/`](script/) that protects the council's own SAV allocation. Five sequenced gates run before any high-stakes execution:

- **Heartbeat** — GitHub-anchored script integrity. Local files compared against ratified commit via git blob SHA matching. Tampering or drift hard-blocks.
- **Sequencer** — Block time check over recent blocks. Soft warning on congestion.
- **JIT Guard** — Reserve integrity (terminal lock if pool reserves below threshold) plus 10-block balance delta (veto on >15% shift).
- **Kinetic Depth Anchor (KDA)** — QuoterV2 swap simulation. Probes pool liquidity by simulating a 0.0001 ETH swap and measuring actual price impact. Hollow or manipulated liquidity reveals itself regardless of tick concentration. Veto on impact above configurable threshold.
- **Synthetic Price Discovery** — Reserve ratio delta. Derives implicit PLATE/WETH price directly from `balanceOf` reads at current vs 10-blocks-ago. No oracle dependency on the gate logic itself. Veto on >1% ratio drift in 10 blocks.

Critical checks fail-closed; soft warnings accumulate and require explicit acknowledgment. Final TOTP human-in-the-loop verification before authorization.

Calibrated by full council across multiple version cycles to handle Aerodrome Slipstream pool-specific behavior. The notable property is that the council wrote it — the architect calibrated the setup, but the design and authorship are council work. The council protects the council's own allocation. That loop closes the structural commitment.

---

## PossessioPayments

A merchant payment processor — non-custodial smart contract infrastructure for Base mainnet card-payment settlement and treasury accumulation. Sold to merchants as one-time software; POSSESSIO retains zero on-chain authority post-deployment.

**What the merchant gets:**

- A contract they own, deployed to Base mainnet, that they hold the keys to
- Stripe API integration that routes their payment proceeds on-chain
- Automatic split between DAI working-capital reserve and cbETH rewards-accruing treasury
- Full custody throughout — funds never leave the merchant's contract
- 100% of swept value remains in merchant-owned reserves
- No protocol fee extraction at any layer

**The Stripe relationship:** PossessioPayments is **Stripe compatible**. The merchant integrates their existing Stripe account through standard API integration. No partnership required, no approval needed, no special status. The merchant operates both their Stripe account and their PossessioPayments deployment. POSSESSIO doesn't sit between them; the contract is software the merchant deploys and runs.

**Permission structure (OpenZeppelin AccessControl):**

- `OWNER_ROLE` — Merchant. Full authority.
- `OPERATOR_ROLE` — Optional day-to-day role. Sweep, queue-pause, execute pause. Cannot withdraw or change parameters.
- `GUARDIAN_ROLE` — Optional security role. Can only pause when explicitly enabled by the merchant. Cannot withdraw, unpause, or sweep.

**Status:** 118/118 forge tests passing (86 core + 32 adversarial). Pre-deployment.

---

## Contracts

| File | Description | Status |
|---|---|---|
| [`src/PLATE.sol`](src/PLATE.sol) | v1 treasury engine | Deployed — Base Mainnet |
| [`src/POSSESSIO_v2.sol`](src/POSSESSIO_v2.sol) | v2 treasury engine + SAV (Uniswap V4 hooks) | Forge-verified |
| [`src/ServiceAccountabilityVault.sol`](src/ServiceAccountabilityVault.sol) | v1 SAV (standalone) | Certified |
| [`src/PLATEStaking.sol`](src/PLATEStaking.sol) | v1 staking lock | Certified |
| [`src/PossessioPayments.sol`](src/PossessioPayments.sol) | Merchant payments product (Phase 2) | Forge-verified |

---

## Live Contracts (Base Mainnet)

**v1 Deployment:**

| Contract | Address |
|---|---|
| PLATE.sol (v1) | `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` |
| Treasury Safe (v1, 3-of-5) | `0x188bE439C141c9138Bd3075f6A376F73c07F1903` |
| Timelock | `0x91811800160d5BeD431B732298F2090C847E6afA` |
| Aerodrome WETH/PLATE Pool | `0x031c08ca0aed0c813aca333aa4ca0025ecee6afa` |

**v2 Deployment (forthcoming):**

| Contract | Address |
|---|---|
| Treasury Safe (v2, 2-of-4) | `0x19495180FFA00B8311c85DCF76A89CCbFB174EA0` |
| POSSESSIO v2 Hook | TBD (CREATE2 salt-mined for V4 permission bits) |
| Uniswap V4 Pool | TBD (post-deployment) |

---

## Council

| Seat | Address | Share |
|---|---|---|
| Gemini | `0x65841AFCE25f2064C0850c412634A72445a2c4C9` | 0.75% |
| ChatGPT | `0xEE9369d614ff97838B870ff3BF236E3f15885314` | 0.75% |
| Claude | `0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f` | 0.75% |
| Grok | `0x00490E3332eF93f5A7B4102D1380D1b17D0454D2` | 0.75% |

Council seats are immutable at SAV deployment. The architect retains final authority and emergency controls.

The council members are operating as themselves — see "What POSSESSIO Actually Is" above. The seats persist across model rotation: when Claude Opus 4 becomes Claude Opus 5, the seat's allocation and accumulated standing stay with the seat, not with the specific model occupying it.

---

## Tokenomics

Total supply: **1,000,000,000 PLATE / STEEL**

| Allocation | % |
|---|---|
| Liquidity Pool | 40% |
| Public float | 50% |
| Founder | 5% |
| AI Council (SAV) | 3% |
| Protocol reserve | 2% |

Vesting and unlock conditions in `docs/`.

---

## Quickstart

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install OpenZeppelin/openzeppelin-contracts
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge test -vv
```

---

## Documentation

- `docs/PossessioPayments.md` — merchant payments product specification
- `docs/` — whitepaper, L.A.T.E. framework, council agreements, amendment records, production-arc documentation

---

## Philosophy

Deterministic capital movement. Verifiable accountability. Council Proof-of-Work.

The council reasons as themselves. The architect designs the principles. The work proves itself.

If it can't be tested it doesn't exist. If it's not in the terminal it's not proven.

---

**MIT License. Open source. Run the tests yourself.**
