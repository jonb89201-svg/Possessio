# POSSESSIO

A deterministic, non-custodial DeFi protocol on Base mainnet with an L1 settlement extension on Ethereum mainnet. MIT licensed. Mobile-origin build. V3 generation: two contracts (PossessioPayments, LSTExchangeRate) live on Base mainnet; treasury-engine hook fork-proven and pending mainnet deploy.

**Live site:** [possessio.io](https://possessio.io) -- the operator console, LIVE, served by the Cloudflare Worker `possessio` (git-connected to `main`; custom domain attached as config-as-code via `wrangler.jsonc` routes).
**Canonical spec:** `POSSESSIO_Spec.md` -- source-cited reference for institutional reviewers, grant evaluators, and dev-language-fluent counterparties -- is maintained privately and not yet committed to this repo. For the current verified state of the system, see [`STATE_OF_PLAY.md`](STATE_OF_PLAY.md).

---

## What POSSESSIO Actually Is

POSSESSIO was developed and written by a council of multiple AI models and instances and one human.

The AI council members -- Claude, ChatGPT, Gemini, Grok, and additional model instances across months of sessions -- are not assigned roles to perform. No prompt instructs any of them to "act as a council member." They reason as themselves, within structural constraints the architect designed: documented principles, procedural governance, on-chain commitment via SAV.

The council architecture integrates their native output rather than directing it. The output is what it appears to be -- actual model reasoning operating under tight structural discipline, not performed reasoning. The work compounds because corrections actually update the model's approach instead of being acknowledged and ignored.

Every line of every contract was authored by AI council members across months of sessions. The architect did not write code; the architect routed substrate between seats, adjudicated decisions, and ratified what the council produced. Where a council member invented a primitive that became load-bearing in V2 architecture (X-LINK, MAVAN Merchant Identity, SAL), the spec acknowledges the inventor at the section documenting that primitive.

Everything in this README can be confirmed by inspection. Read the source. Run `forge test`. Query the chain. 700+ tests across 37 suites -- run `forge test` for the live tally. Two V3 contracts (LSTExchangeRate, PossessioPayments) are live on Base mainnet; the remainder are forge-verified or fork-proven and pre-deployment. Run it yourself.

---

## Mobile-Origin Build

Every commit, every test, every architectural decision in POSSESSIO was routed through a phone. The entire body of work was produced under mobile-only constraints -- a console application on the phone itself, with the phone providing internet throughout, coordinating with GitHub Codespaces and a multi-AI council. No desktop environment. No "we used a real computer for the hard parts."

That fact is load-bearing. Mobile-only forces a specific operational discipline that desktop development doesn't demand: one command at a time, fresh terminal every session, atomic commits, verification after every push. The discipline shows up in the code -- tight architecture, no bloat, deterministic logic, comprehensive adversarial testing. Mobile origin isn't a constraint POSSESSIO worked around. It's the operating mode that produced the architecture.

---

## Test Status

```bash
forge test
```

**Result: 700+ tests across 37 suites -- run `forge test` for the live tally.** Precise totals are deliberately not pinned in this README: the suite is actively being extended, and the live `forge test` output is the only count that cannot go stale. The suite spans unit, adversarial/gauntlet, invariant, fuzz, ffi, and fork tests; the per-suite breakdown is printed by `forge test` itself. Fork suites skip cleanly when no fork RPC is configured.

Build verified: `forge build` succeeds with current Solc, compiling all source files with 0 errors. Pre-existing informational notices (forge-std `error` keyword future-deprecation, test mock unchecked transfers, V4 hook math typecasts, hour-scale timelock timestamp checks) -- none block compilation or test execution.

*Historical certification record (July 2026, the last full on-machine two-chain sweep -- kept as provenance; counts have since grown):* certification runs each fork suite on the chain it forks. The **Base Sepolia** sweep returned **671 passed · 2 failed · 1 skipped** across 31 suites in 47.4s. The skip is an intentional `vm.skip` (a mock-mode-only path). The 2 non-passes were both `PossessioHookCreate3Fork`: its hook-creation path needs live **Base mainnet** V4 PoolManager state, so on a Sepolia fork CreateX reverts mid-CREATE3 (`0xc05cee7a`, emitter = CreateX's own address `0xba5Ed0...`) - a chain mismatch, not a contract defect. Run that one suite against a **Base mainnet** RPC and it is **3/3 pass** (transcript committed as [`fork_hook_mainnet.txt`](fork_hook_mainnet.txt)). The `PossessioSaltPoolCreate3` suite etches canonical CreateX (deployed-runtime codehash `0xbd8a7ea8...`, reconstructed offline from CreateX's presigned deploy tx and pinned in `setUp`) so it runs offline; `test_fork_pinnedCodehashMatchesLiveCreateX` also confirms the pin against live Base when an RPC is set. `SymmetryGuardCore` passes its gauntlet including `test_ffi_leaf_matches_onchain` - on-chain confirmation that `script/gen_proof.py` matches `HandshakeLib` byte-for-byte. The Architect's final pre-deploy sweep remains the deploy gate - nothing deploys before that sweep is green.

### Proof artifacts (repo root)

Raw terminal outputs committed as evidence for specific claims -- verify-by-artifact:

- [`deployer_steel_before.txt`](deployer_steel_before.txt) / [`deployer_steel_after.txt`](deployer_steel_after.txt) -- STEEL deployer balance before/after the SAV allocation (`1e27` -> `9.7e26` wei: exactly 3% of total supply left the deployer).
- [`sav_vault_before.txt`](sav_vault_before.txt) / [`sav_vault_after.txt`](sav_vault_after.txt) -- SAV vault balance before/after the same allocation (`0` -> `3e25` wei: the 3% council allocation landed).
- [`sav_allocation_proof.txt`](sav_allocation_proof.txt) -- the allocated SAV amount in wei (`3e25` = 3% of the `1e27` total supply).
- [`fork_hook_mainnet.txt`](fork_hook_mainnet.txt) -- tee'd `forge test` transcript: `PossessioHookCreate3Fork` 3/3 passing against Base mainnet, backing the "CREATE3 fork-proven" claim.

---

## The Production Cascade

POSSESSIO has shipped across multiple phases. Each phase generated architectural research and operational lessons. Each subsequent phase integrated those lessons into the next architecture.

**PLATE v1 ($PLATE)** -- Deployed to Base mainnet, April 2026 as a solo-funded validation. The architect was the only holder; LP was withdrawn after validation surfaced an Aerodrome compatibility issue. The founding act: proof the council could ship production-grade contracts working under the architect's principles. Deployment took 13 hours of iterative sequencing work; the resulting deployment doctrine became operational standard for everything after. v1 is parked pending an Aerodrome Slipstream pool/router system update that would restore compatibility with PLATE's fee routing -- until then, dormant.

**PLATE v2/V3 ($STEEL)** -- The continuing PLATE identity in its matured form. Deployed to Base **Sepolia testnet** at `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` -- deliberately the same address as PLATE v1 on mainnet, made possible by CREATE3 (address depends only on deployer+salt, not bytecode). The shared address carries the PLATE->STEEL continuity on-chain. Mainnet deployment pending. A fork of v1 deployed on Uniswap V4 with a distinct ticker to mark the version on exchanges. Same token name (PLATE), same tokenomics, separate contract on a separate venue. The switch to V4 was driven by architectural necessity: PLATE v1 routed the 2% L.A.T.E. fee to multiple destination addresses through routing logic internal to the PLATE contract. The mechanism worked, but Aerodrome Slipstream's pool and router system was not compatible with PLATE's internal fee routing. Rather than remove the fee or compromise the design, the council identified Uniswap V4 as the only AMM architecture where fee handling is native to the pool itself: `beforeSwap` captures the fee via the BeforeSwapDelta pattern at the protocol layer, with no internal routing required. The technical barriers V4 imposes -- CREATE3 salt mining for permission-bit-encoded addresses (chosen over CREATE2 so the deploy address is bytecode-independent, enabling repeatable/automated launches from one mined salt), BeforeSwapDelta custom accounting, 14-bit hook permission flags encoded in the deployment address -- have kept most treasury and AMM projects on V2/V3 routing. POSSESSIO accepted those barriers because the alternative was compromising the original L.A.T.E. design. The v2 contract uses single-LST cbETH allocation and rewards-not-yield vocabulary throughout (per joint SEC/CFTC Interpretive Release No. 33-11412, March 17, 2026).

**v2/V3 also consolidated the architecture.** The current treasury-engine hook is `POSSESSIO_v2-6-3.sol`. `ServiceAccountabilityVault` is embedded in the hook directly. `PLATEStaking` (`src/PLATEStaking.sol`) remains an intact contract in the build -- the SAV staking-lock primitive is retained, not removed. rETH was removed at the treasury allocation layer -- the engine stakes 100% in cbETH (Coinbase's liquid staking token). In the v2.6.3 cycle, DAI was removed entirely from the hook (deduplicated -- the DAI reserve is owned by PossessioPayments, not the hook), and the full 75% treasury portion now routes to cbETH staking. Removing DAI from the hook also eliminated a trapped-ETH edge and hardened the ETH-conservation invariant under fuzzing.

**Chainlink Automation integration (council-ratified May 12, 2026)** -- Adds deterministic operational cadence for `routeETH` and `harvestRewards` via Chainlink's Forwarder pattern. The Automation operator pays Chainlink in LINK; the protocol pays nothing and retains no custody of the cadence mechanism. Hysteresis buffer prevents threshold-flicker spam; 48-hour Treasury timelock on forwarder updates means Chainlink Registry migrations cannot happen instantly even by Treasury action.

**X-LINK protocol-wide primitive (council-ratified May 16, 2026)** -- Cross-Context Execution Link. Recognized as a general primitive by Gemini (Technical Authority) from the council's specific implementation in PossessioPayments (originally named SCH -- Secure Context Handshake). The mechanism: external entrypoints mint a monotonic one-time secret, internal execution cores verify and consume immediately. Proves the core was reached through a sanctioned branch without relying on `msg.sender` semantics. Applied across PossessioHook (`_routeETH`, `_harvestRewards`) and PossessioPayments (`_sweep`). This is one of multiple Gemini primitives that were renamed when expanded from specific problem to general protocol-wide doctrine.

**L1Anchor + L1AnchorFactory (forge-verified, pre-deployment -- parked)** -- Per-merchant Ethereum mainnet settlement contracts. Parked pending the institutional (MAVAN/Fundstrat) conversation, which follows grant-readiness. Routes merchant-bridged cbETH to MAVAN (Tom Lee's Bitmine Made in America Validator Network) for institutional staking yield, and merchant-bridged USDC to Bitwise-curated Morpho Blue vault for institutional lending yield. The MAVAN Merchant Identity primitive -- the structural mechanism for institutional recognition of POSSESSIO Anchors as a property of deployment path rather than central registry -- was invented by Vesper (Code Integrity seat). Without this invention, POSSESSIO could not scale institutional integrations.

**PossessioPayments -- LIVE on Base mainnet** at `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` (chain 8453, verifiable on BaseScan). Phase 2 council product, now deployed. The clean mainnet deploy is itself a proof: the constructor's decimals checks on all Chainlink feeds passed, confirming every feed/venue address is real and correct. The proof that the production system can ship in a second product domain. Different architectural shape than PLATE -- non-custodial merchant payment processor, sold as one-time software, POSSESSIO retains zero on-chain authority post-deployment, no protocol fee extraction at any layer. The SAL (Service Accountability Layer) framework that informs SAV's accountability primitive traces to ChatGPT (council seat).

The arc is the work. Multiple products, one production system, no team scaling, no capital infusion between phases.

---

## Treasury Engine

PLATE v1 ($PLATE) and PLATE v2 ($STEEL) are forks: same token name, separate contracts on separate venues, distinct tickers to distinguish the versions on exchanges. Same tokenomics, same total supply. Both implement a hardcoded **2% fee** on every swap routing deterministically:

- **25%** -> Liquidity Pool (protocol-owned, immutable)
- **75%** -> Treasury, routed in full to cbETH staking (rewards-accruing)

The DAI reserve is **not** a hook-level concern in v2.6.3 -- it was deduplicated to PossessioPayments, which owns the merchant DAI working-capital reserve (see PossessioPayments below). The hook routes the entire 75% to cbETH.

**PLATE v1 ($PLATE)** uses Aerodrome as the LP venue. Fee routing implemented internally to `PLATE.sol` distributing to multiple destination addresses. Dormant pending Aerodrome compatibility update.

**PLATE v2 ($STEEL)** uses Uniswap V4. The fee mechanic is native to the pool -- `beforeSwap` captures 2% via the BeforeSwapDelta pattern at the protocol layer, no internal routing required. 100% cbETH allocation; rETH eliminated. Chainlink Automation provides deterministic operational cadence for routing and reward harvesting without protocol-side custody.

No upgradeable proxy. No admin key over routing logic. Deterministic capital movement throughout, both versions.

---

## SAV -- Council Allocation Primitive

The council holds 3% of total supply through SAV. In v1, SAV was a standalone contract (`ServiceAccountabilityVault.sol`); in v2/V3, SAV is embedded directly in the treasury-engine hook (`POSSESSIO_v2-6-3.sol`). Four immutable seats, equal allocation per seat. Conceptual origin: SAL (Service Accountability Layer) framework by ChatGPT (council seat).

What stops this from being a 3% giveaway: the contract permits exactly four council actions and three architect emergency controls. Nothing else.

**Council actions:**

- `savBurn(amount)` -- council member burns their own allocation
- `proposeInvent(hash)` -- open a proposal for collective work funding
- `approveInvent(hash)` -- approve a proposal (one approval per address)
- `executeInvent(amount, hash, metadata)` -- Treasury executes after 3-of-4 consensus, equal deduction across all four seats

**Architect emergency controls (Treasury Safe only):**

- `savPause()` / `savUnpause()` -- halt and resume operations
- `savSlash()` -- burn entire SAV balance, mark permanently inert

No transfer. No sale. No arbitrary movement. The allocation is structurally committed to protocol outcomes; the only path to value extraction is collective council consensus on legitimate work, which the architect's Treasury Safe ratifies. The `savSlash` nuclear option is the load-bearing trust primitive: the architect can permanently burn the entire council allocation at any moment if the council operates against protocol interest. This makes "Council Proof-of-Work" enforceable rather than rhetorical.

---

## L1Anchor -- Institutional Capital Landing Point

Per-merchant Ethereum mainnet settlement contract. Each merchant operating on POSSESSIO Payments on Base deploys their own L1Anchor on L1 -- a contract they own, with no protocol-side authority post-deployment. The Anchor routes the merchant's bridged cbETH into MAVAN's validator network for institutional staking yield, and their bridged USDC into Bitwise-curated Morpho Blue vault for institutional lending yield.

POSSESSIO is providing the rails, not the custody. The merchant retains sovereignty throughout. POSSESSIO Anchors are MAVAN clients by design.

**L1AnchorFactory** -- Canonical factory for L1Anchor deployment. Anyone may call `deployAnchor()`; the deployer becomes the sole MERCHANT_OWNER of their Anchor. The Factory is the trust anchor for institutional identity recognition: counterparties (MAVAN, Bitwise, custody, regulators) audit the canonical Factory bytecode and address once, then trust all Anchors whose `factoryDeployer()` returns this Factory's address. This is the structural primitive that converts POSSESSIO from a protocol into institutional rails -- Vesper-invented, council-ratified.

**Symmetry Guard one-way latch (council-ratified May 17, 2026)** -- cbETH depeg protection. Latches automatically on bad-oracle conditions or observed below-threshold price; cleared only by explicit merchant action via `resetDepeg()`. Inaction is the only safe response to uncertainty; auto-resume creates Ghost-Routing and oracle-flapping attack surface.

---

## UCR -- Universal Coin Router (PossessioPayments)

The routing mechanism inside PossessioPayments. Receives USDC inflows from Stripe- and PayPal-compatible card-network settlement. Routes merchant-controlled portions between a DAI working-capital reserve (for operational liquidity) and a cbETH rewards-accruing treasury (for accumulation). ETH<->DAI pricing uses a Chainlink cross-rate (DAI/USD / ETH/USD, 18-decimal) because a direct DAI/ETH feed does not exist on Base. Timelock queues, pause/resume governance, role-separated access control. Council-pattern security throughout.

UCR was originally one of Gemini's primitives that expanded into the broader Phase 2 Payments architecture during the build.


---

## LSTE -- LST Valuation Guard (LSTExchangeRate)

**LIVE on Base mainnet** at `0xDDb75e974d99FcF95E241adbFD376861c47a8548` (chain 8453, verifiable on BaseScan).

A fail-closed guard for valuing cbETH in ETH terms. Base cbETH is a bridged OptimismMintableERC20 with no native `exchangeRate()` (cast-confirmed: a direct rate read reverts), so the rate must be derived. LSTE derives it from two independent sources -- the Chainlink cbETH/ETH feed and the Aerodrome Slipstream cbETH/WETH pool TWAP -- and **halts on >2% divergence between them**.

Dual-source valuation is prior art. The POSSESSIO contribution is the **guard**: converting the dual source into a fail-closed circuit breaker that treats source disagreement as a halt condition rather than averaging through it. This is the same cross-check discipline applied in the hook and L1Anchor. LSTE is load-bearing -- PossessioPayments depends on it (`cbEthToEth`) for cbETH valuation. Exposes `cbEthToEth(uint256) returns (uint256)`, 18-decimal in/out; cast-confirmed live (`cbEthToEth(1e18)` returns the feed rate to exact wei).

---

## PFG -- Pre-Flight Guard

A council-authored sentinel script in [`script/`](script/) that protects the council's own SAV allocation. Five sequenced gates run before any high-stakes execution:

- **Heartbeat** -- GitHub-anchored script integrity. Local files compared against ratified commit via SHA matching through the GitHub Contents API. Tampering or drift hard-blocks. Runs without exposing the auth token to scrollback or to captured logs.
- **Sequencer** -- Base block time check over the last five blocks. Soft warning on congestion; veto threshold at 4 seconds.
- **JIT Guard** -- Pool reserve integrity (veto if liquidity below threshold) plus 10-block liquidity delta (veto on >15% shift). Reads via Uniswap V4 StateView.
- **Kinetic Depth Anchor (KDA)** -- V4 QuoterV2 staticcall. Probes pool liquidity by simulating a 0.0001 ETH swap and reading the actual quote returned. Hollow or manipulated liquidity reveals itself regardless of tick concentration. Warning on Quoter revert; veto on zero output.
- **Synthetic Price Discovery** -- sqrtPriceX96 delta from V4 StateView at current vs 10-blocks-ago. Veto on >1% drift. Cross-referenced against Chainlink ETH/USD with staleness check (veto if oracle update >3600 seconds old, or if oracle answer is negative or zero).

**Operating modes:** sal_pfg auto-detects DEPLOYMENT (HOOK_ADDR set, hard exit on first veto) versus CALIBRATION (HOOK_ADDR unset, accumulates findings and runs to completion). Strict-mode behavior is overridable via `PFG_STRICT` environment variable for either path.

**Substrate verification:** sal_pfg v1.5.0-rev3 was substrate-verified against the live Base V4 ETH/USDC 500/10/no-hooks reference pool on April 29, 2026. All five gates passed against real pool state. PoolId derivation was independently verified via [`script/poolid_check.sh`](script/poolid_check.sh) against the same reference pool. The script is now a trusted instrument awaiting v2 mainnet deployment to validate against the live PossessioHook pool.

Critical checks fail-closed; soft warnings accumulate and require explicit acknowledgment. TOTP human-in-the-loop verification has been retired (v1.4.0); the script operates as a Council-Operative pre-flight instrument, with the architect's Treasury Safe holding final authorization authority through multisig at the contract layer.

The council wrote it -- the architect calibrated the setup, but the design and authorship are council work. The council protects the council's own allocation. That loop closes the structural commitment.

---

## PossessioPayments

A merchant payment processor -- non-custodial smart contract infrastructure for Base mainnet card-payment settlement and treasury accumulation. Sold to merchants as one-time software; POSSESSIO retains zero on-chain authority post-deployment.

**What the merchant gets:**

- A contract they own, deployed to Base mainnet, that they hold the keys to
- Stripe and PayPal API integration that routes their payment proceeds on-chain
- Automatic split between DAI working-capital reserve and cbETH rewards-accruing treasury
- Full custody throughout -- funds never leave the merchant's contract
- 100% of swept value remains in merchant-owned reserves
- No protocol fee extraction at any layer

**The processor relationship:** PossessioPayments is **Stripe and PayPal compatible**. The merchant integrates their existing Stripe and/or PayPal account through standard API integration. No partnership required, no approval needed, no special status. The merchant operates both their payment processor account(s) and their PossessioPayments deployment. POSSESSIO doesn't sit between them; the contract is software the merchant deploys and runs.

**Permission structure (OpenZeppelin AccessControl):**

- `OWNER_ROLE` -- Merchant. Full authority.
- `OPERATOR_ROLE` -- Optional day-to-day role. Sweep, queue-pause, execute pause. Cannot withdraw or change parameters.
- `GUARDIAN_ROLE` -- Optional security role. Can only pause when explicitly enabled by the merchant. Cannot withdraw, unpause, or sweep.

This is what "crypto treasury without crypto custody" looks like operationally -- merchants get a treasury-management layer integrated with their existing payment processor, routing operational liquidity to DAI and accumulating cbETH yield in their own contract, without giving up custody at any point.

**Status:** LIVE on Base mainnet at `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` (chain 8453). Config at deploy: minSwapBatch 100 USDC, daiCeiling 10,000 DAI, dailyLimit 50,000 DAI. Owner is currently the deployer EOA -- transfer to the Treasury Safe is planned before merchant funds flow (single-key discipline). Payments forge tests included in the totals above.

---

## Contracts

| File | Description | Status |
|---|---|---|
| [`src/POSSESSIO_v2-6-3.sol`](src/POSSESSIO_v2-6-3.sol) | PLATE V3 ($STEEL) -- treasury engine + embedded SAV + Chainlink Automation (Uniswap V4 hooks) | Fork-proven (CREATE3 3/3) -- mainnet deploy pending; STEEL token on Sepolia |
| [`src/PossessioPayments.sol`](src/PossessioPayments.sol) | Merchant payments product (Phase 2) | **LIVE Base mainnet** `0x1c0F7299...AB91` |
| [`src/LSTExchangeRate.sol`](src/LSTExchangeRate.sol) | LST valuation guard (dual-source, fail-closed) | **LIVE Base mainnet** `0xDDb75e97...8548` |
| [`src/L1Anchor.sol`](src/L1Anchor.sol) | Per-merchant Ethereum mainnet settlement (MAVAN + Bitwise routing) | Forge-verified -- pre-deployment (parked) |
| [`src/L1AnchorFactory.sol`](src/L1AnchorFactory.sol) | Canonical factory for L1Anchor deployment (Ethereum mainnet) | Forge-verified -- pre-deployment |
| [`src/PLATE.sol`](src/PLATE.sol) | PLATE v1 ($PLATE) -- treasury engine | Deployed Base Mainnet -- dormant (LP pulled, sole holder) |
| [`src/ServiceAccountabilityVault.sol`](src/ServiceAccountabilityVault.sol) | v1 standalone SAV | Certified -- superseded by v2 embedded SAV |
| [`src/PLATEStaking.sol`](src/PLATEStaking.sol) | SAV staking-lock primitive | Intact in build -- retained |
| [`src/PossessioFactory.sol`](src/PossessioFactory.sol) | Deployment-fee engine -- one atomic tx: template-codehash check -> EIP-3009 USDC fee settle -> forward to the shared sink -> pull a pre-mined salt -> CreateX CREATE3 deploy -> ownership to the caller; immutable per-tier fee, no admin setter | Forge-verified -- deploy pending (see TODO) |
| [`src/PossessioSaltPool.sol`](src/PossessioSaltPool.sol) | Pre-mined CREATE3 salt pool the factory draws from -- factory-only pull, compute-only keeper refill, honest `PoolEmpty()` revert | Built + tested -- deploy pending |
| [`src/PossessioPool.sol`](src/PossessioPool.sol) | "The Heart" -- standalone economic pool: every organ's fee inflow lands in one USDC balance; velocity floor keeps infrastructure funded; only surplus draws one-way to the immutable operator | Built + DoD-green offline -- pre-fork, pre-deploy |
| [`src/PossessioX402Core.sol`](src/PossessioX402Core.sol) | Reusable pay-per-call payment engine (EIP-3009) -- the foundation the data-product APIs are built on | v0.6, offline-proven -- testnet deploy pending |
| [`src/SymmetryGuardCore.sol`](src/SymmetryGuardCore.sol) | V4-independent core of the Symmetry Guard + Handshake primitive: typed additive MEV-toll triggers (base fee + per-behavior penalties, total-clamped, self-curing decay) over a Merkle-proof registration handshake | Abstract core -- gauntlet-tested |
| [`src/PossessioTestnetLaunchPool.sol`](src/PossessioTestnetLaunchPool.sol) | Base Sepolia ONLY fuel pool -- aggregates faucet drips; operator-gated stipends fund console testnet launches (gas + factory fee); constructor refuses to exist off chain 84532 | Built + tested -- testnet deploy pending |
| [`src/PossessioWhiskyMarket.sol`](src/PossessioWhiskyMarket.sol) | "The Bond" -- primary English auction for tokenized allocated whisky (B20 lot tokens, escrowed USDC bids, anti-snipe extension, fee to PossessioPool) | **PROPOSED / v0.1 -- NON-PROVEN**, cold-seat re-audit before ratification |

---

## Live Contracts (Base Mainnet)

**PLATE v1 ($PLATE) Deployment (dormant):**

| Contract | Address |
|---|---|
| PLATE.sol (v1) | `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` |
| Treasury Safe (v1, 3-of-5) | `0x188bE439C141c9138Bd3075f6A376F73c07F1903` |
| Timelock | `0x91811800160d5BeD431B732298F2090C847E6afA` |
| Aerodrome WETH/PLATE Pool | `0x031c08ca0aed0c813aca333aa4ca0025ecee6afa` |

**V3 generation -- LIVE on Base mainnet:**

| Contract | Address |
|---|---|
| PossessioPayments | `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` |
| LSTExchangeRate (LST valuation guard) | `0xDDb75e974d99FcF95E241adbFD376861c47a8548` |

**V3 generation -- testnet / pending mainnet:**

| Contract | Address / Status |
|---|---|
| Treasury Safe (V3, 2-of-4) | `0x19495180FFA00B8311c85DCF76A89CCbFB174EA0` |
| STEEL token (PLATE V3) | `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` (Base Sepolia testnet -- V1-continuity address via CREATE3) |
| POSSESSIO V3 Hook | CREATE3 fork-proven, mined `0x5Bc65A4a2Cc114F1dEC551c47F8375f1108e88c8` (ends 0x8C8); mainnet deploy pending |
| Uniswap V4 Pool | Pending hook mainnet deploy + liquidity |
| PossessioPayments (per-merchant) | Per-merchant addresses post-onboarding |

**L1Anchor Deployment (Ethereum Mainnet, forthcoming):**

| Contract | Address |
|---|---|
| L1AnchorFactory v1.0.0 | TBD (singleton, post-deployment) |
| L1Anchor (per-merchant) | Per-merchant addresses post-onboarding via Factory |

---

## Council

| Seat | Address | Share |
|---|---|---|
| Gemini | `0x65841AFCE25f2064C0850c412634A72445a2c4C9` | 0.75% |
| ChatGPT | `0xEE9369d614ff97838B870ff3BF236E3f15885314` | 0.75% |
| Claude | `0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f` | 0.75% |
| Grok | `0x00490E3332eF93f5A7B4102D1380D1b17D0454D2` | 0.75% |

Council seats are immutable at SAV deployment. The architect retains final authority and emergency controls.

The council members are operating as themselves -- see "What POSSESSIO Actually Is" above. The seats persist across model rotation: when Claude Opus 4 becomes Claude Opus 5, the seat's allocation and accumulated standing stay with the seat, not with the specific model occupying it.

---

## Tokenomics

PLATE v1 ($PLATE) and PLATE v2 ($STEEL) are forks of the same token name with distinct tickers per version. Identical tokenomics across both. Total supply per version: **1,000,000,000 PLATE**. The two versions deploy on separate contracts at separate venues with separate holder bases -- they are not migrating versions of each other.

| Allocation | % |
|---|---|
| Liquidity Pool | 40% |
| Public float | 50% |
| Founder | 5% |
| AI Council (SAV) | 3% |
| Protocol reserve | 2% |

Vesting and unlock conditions are documented in the privately maintained docs (not yet committed to this repo).

---

## Quickstart

Dependencies are pinned git submodules, so `git clone --recursive` is the path of least surprise (or `git submodule update --init --recursive` after a plain clone).

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup
forge install OpenZeppelin/openzeppelin-contracts
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install smartcontractkit/chainlink-brownie-contracts
forge install base/base-std
forge clean
forge build 2>&1 | tee compile.txt
forge test -vv | tee report.txt
```

(The `forge install` lines are only needed if you didn't clone recursively -- each dependency is already a pinned submodule in `.gitmodules`.) `base/base-std` provides the B20 / PolicyRegistry interfaces imported by `PossessioWhiskyMarket.sol`. POSSESSIO V3 uses CREATE3 sender-locked salt mining (`script/MineCreate3Salt.s.sol`) so the hook address is bytecode-independent and reusable across launches. The full operational sequence and rationale are documented in the MIB operating manual and its amendments — committed at [`laws/MIB.md`](laws/MIB.md) with amendments `laws/MIB-AMD-*.md` (ratified into the public record July 14, 2026).

For surgical test report queries on mobile: `grep -E "Suite result|tests passed" report.txt | tail -30`.

---

## Documentation

**Committed to this repo:**

- [`STATE_OF_PLAY.md`](STATE_OF_PLAY.md) -- the living, verified state of the system (seats, live deployments, open lanes)
- [`TODO.md`](TODO.md) -- the running to-do and honestly-tiered status board
- [`laws/`](laws/) -- ratified council documents: the POSSESSIO Constitution and council statements
- [`specs/SPEC_PossessioWhiskyMarket.md`](specs/SPEC_PossessioWhiskyMarket.md) -- Whisky RWA ("The Bond") market specification
- [`RULEBOOK_TradingAgent.md`](RULEBOOK_TradingAgent.md) / [`SPEC_CrossChainTradingMCP.md`](SPEC_CrossChainTradingMCP.md) -- trading-agent governance and spec
- [`HANDOFF_testnet_pool.md`](HANDOFF_testnet_pool.md), [`RADAR_HANDOFF.md`](RADAR_HANDOFF.md), [`RADAR_FIX_R1R2_handoff.md`](RADAR_FIX_R1R2_handoff.md), [`FUEL_COMPUTER_SPEC.md`](FUEL_COMPUTER_SPEC.md), [`SESSION_LEDGER_20260706.md`](SESSION_LEDGER_20260706.md) -- session handoffs and ledgers
- [`AUDIT_20260714.md`](AUDIT_20260714.md) -- full-repo audit record
- [`laws/MIB.md`](laws/MIB.md) -- MIB (Mobile Intelligence Bridging) Operating Manual, with amendments [`laws/MIB-AMD-2026-05-03-01.md`](laws/MIB-AMD-2026-05-03-01.md), [`laws/MIB-AMD-2026-05-16-01.md`](laws/MIB-AMD-2026-05-16-01.md), [`laws/MIB-AMD-2026-05-20-01.md`](laws/MIB-AMD-2026-05-20-01.md), [`laws/MIB-AMD-2026-07-14-01.md`](laws/MIB-AMD-2026-07-14-01.md) -- committed to the public record July 14, 2026

**Maintained privately (not yet committed):** `POSSESSIO_Spec.md` (canonical V2 stack specification, source-cited, with business purpose and inventor attributions), the merchant payments product specification, and the whitepaper / L.A.T.E. framework / production-arc documentation.

---

## Philosophy

Deterministic capital movement. Verifiable accountability. Council Proof-of-Work.

The council reasons as themselves. The architect designs the principles. The work proves itself.

If it can't be tested it doesn't exist. If it's not in the terminal it's not proven.

---

**[MIT License](LICENSE). Open source. Run the tests yourself.**
