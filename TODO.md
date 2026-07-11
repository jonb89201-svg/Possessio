# POSSESSIO — Running To-Do & State

_The single place the open work lives, so it doesn't have to live in anyone's head.
Updated as things get named or done. Last updated: 2026-07-10._

---

## The dependency chain (order matters)

- [ ] **Fund the Sepolia pool** — needed for the free-testnet-practice promise to actually be live. Without it, the "we provide practice funds" story isn't true yet.
- [ ] **x402Core — fork run** → set `X402_FORK_RPC=<Base Sepolia RPC>` and run `test/PossessioX402CoreTestnet.t.sol` against real chain state (default suite is mock-based; fork run is unproven).
- [ ] **x402Core — testnet deploy** → `--broadcast` the Base Sepolia deploy (`script/DeployX402Testnet.s.sol`). No deployed address exists yet.
- [ ] **x402Core — mainnet** → ratify real economics (testnet uses placeholders), then mainnet deploy.
- [ ] **V3 — mainnet deploy** → fork-proven (CREATE3 3/3), ready; deploy pending.
- [ ] **PITI** → rebuild on x402Core. **Do not start until x402 is confirmed fully deployed** (your gate). First contract; will use x402Core's pay-per-call engine, not the old fee-on-transfer draft.
- [ ] **Deploy PossessioFactory at $1 (interim price).** DECISION: the factory ships at **1 USDC** until the pool/flywheel is proven — a prove-the-rail price. `DEPLOYMENT_FEE` is immutable per-factory, so this is versioned by deploying a NEW factory at the tier price (100 USDC) once the pool is proven; existing deploys keep their terms. `script/DeployPossessioFactory.s.sol` written + forge-compiled: fee=$1, payToken (Base USDC) + feeSink (live Payments) pinned; `SALT_POOL_ADDR` + `TEMPLATE_CODEHASH` env-gated. **Blockers before it can run:** (1) deploy PossessioSaltPool (no address yet); (2) pin the template codehash. Deploying this resolves the console's "no factory configured for chain 8453."
- [ ] **Factory → Pool wiring upgrade** (the "we fix factory later" item). Today `PossessioFactory` forwards the deploy fee with a plain `payTokenERC20.safeTransfer(feeSink, DEPLOYMENT_FEE)` to the live Payments sink — correct for that destination. To route deploy fees into PossessioPool (the Heart), the factory must instead `approve` + call the pool's **accounted** `receiveInfraFunds()` (x402Core's method — a raw transfer would be stranded, uncredited, per Pool DoD #14), AND the factory address must be in the pool's immutable `isAuthorizedSource` set at construction. Downstream of the pool going live; not before.
- [x] **L1AnchorFactory — deploy-ready except integration addresses.** `script/DeployL1AnchorFactory.s.sol` written + forge-compiled (clean). The 3 public endpoints (cbETH, USDC, Chainlink cbETH/ETH) are hardcoded + source-verified; the 2 institutional endpoints (MAVAN entry, Bitwise Morpho vault) read from env and the script **refuses to deploy until both are set** — so "everything's done except those addresses" is now mechanically true. Remaining contingency is the MAVAN *interface* (placeholder `IMAVANEntry`): if BitMine's real ABI differs in shape, L1Anchor.sol needs the real interface swapped + re-tested (Factory v2) — an address alone doesn't cover an ABI-shape change.
- [ ] **L1AnchorFactory → Pool wiring (v2, fee-bearing).** v1.0.0 is deliberately **fee-free** (gas only). **The v2 deployment fee is labeled "TO BE DETERMINED BY FUNDSTRAT"** — the L1 rail's economics are a joint decision with the network operator (BitMine/MAVAN), not set unilaterally by POSSESSIO. Labeled in `src/L1AnchorFactory.sol` and the deploy script. When the fee-bearing version ships, two rules: (1) same accounting discipline — the fee must reach the pool via `receiveInfraFunds()` (accounted), never a plain transfer; (2) **cross-chain leg** — L1AnchorFactory is on **Ethereum L1**, PossessioPool is on **Base**, so it cannot call `receiveInfraFunds()` in-tx like the Base factory. The L1 fee must be **bridged to Base**, then credited through the accounted door on arrival. Real settlement path, not a one-liner. v2 concern, downstream of the pool.

## Base / grants

- [ ] Finish **Builder Code** setup on dashboard.base.org — paste the locked description (below).
- [ ] Nominate POSSESSIO for a **Base Builder Grant** — grants.base.eth form (retroactive, shipped-work; you qualify on live contracts).
- [ ] Apply to the **CDP AI Builder Program** (~$15K) — best-fit angle for the AI-council build.

## Superfoods (side project)

- [x] Google Play Developer account created (2026-07-11 — "Jon Solo," personal, possessio.io).
- [x] **Community sponsor board** built into the app (`generator/sponsors.json` + build_flyers.py) — flat logo-tile grid, no tiers ("everyone sponsors everyone"). Clark's Pest Control = founding sponsor (text tile until logo art arrives). Cache bumped v11, committed + pushed to SuperFoods-App main.
- [ ] **Launch sequence (in order):** (1) `cd superfoods-app && npx wrangler deploy` — publish the sponsor-board version live [needs Jon's CF auth]; (2) PWABuilder → Android .aab + Play App Signing → get package ID + SHA-256 fingerprint; (3) Claude wires `app/.well-known/assetlinks.json` from those, redeploy; (4) upload .aab to Play Console (privacy.html covers the policy req) → internal testing → production.
- [ ] Drop in **Clark's Pest Control logo** (→ `generator/sponsors/clarks_pest.png`) when Jon sends it; add sponsors as they sign.
- Strategy (Jon): launch a real app with correct sales + get it ON the Play Store FIRST — that's the credibility that makes local sponsors "bite hard." Sponsors fill in live afterward.
- [x] App live at superfoods-logan.jonb89201.workers.dev
- [x] Weekly flyer — Tuesday-night reminder set (fires into this session).

## Parked (deliberately not now)

- ⏸ **Fundstrat / Tom Lee (MAVAN) email** — drafted, held. Send only after (a) ecosystem standing (a grant) and (b) the real MAVAN staking interface. The ask *is* that interface; L1Anchor's `IMAVANEntry` is a placeholder.
- 💭 **Whisky RWA** (allocated tokenized casks via bonded warehouse) — vision stage, its own grant doors. Not started.

---

## Status board (what's real, honestly tiered)

**Tier 1 — Live & code-verified on Base mainnet** (deployed; verify on BaseScan):
- PossessioPayments `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` — payment engine; also the shared treasury sink the factory routes fees to
- LSTExchangeRate `0xDDb75e974d99FcF95E241adbFD376861c47a8548` — fail-closed cbETH valuation guard
- PLATE v1 `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` — treasury-engine token (dormant)

**Tier 2 — Fork-tested, ready to deploy** (fork-proven; mainnet deploy pending):
- V3 treasury engine (`src/POSSESSIO_v2-6-3.sol`) — Uniswap V4 hook, CREATE3 3/3
- L1Anchor (`src/L1Anchor.sol`) — per-merchant Ethereum settlement → MAVAN staking + Morpho lending (MAVAN interface still a placeholder)

**Tier 3 — Built & forge-verified, deploy pending** (real code + passing tests in the public repo; NOT deployed; pending final pre-deploy sweep):
- **PossessioFactory** (`src/PossessioFactory.sol`) — the deployment-fee engine. One atomic tx: EIP-3009 USDC fee settle → forward to the live Payments treasury sink → CreateX deploy → ownership to the caller. Immutable `DEPLOYMENT_FEE`, no admin setter, USDC-only; a failed deploy unwinds the whole tx, fee included. Forge-verified (17 tests). **This is the "no factory configured for chain 8453" the console shows — built, not yet deployed.**
- **PossessioSaltPool** (`src/PossessioSaltPool.sol`) — CREATE3 pre-mined salt pool the factory draws from. Built & tested (21 tests).
- **PossessioTestnetLaunchPool** (`src/PossessioTestnetLaunchPool.sol`) — Base Sepolia ONLY fuel pool: aggregates faucet drips; operator-gated stipends cover console testnet launches (gas + factory fee). Chain-locked to 84532 (structurally cannot deploy on mainnet), role-separated, `PoolEmpty()` guard. Built & tested. **DEPLOY: address to be recovered from a prior session. FUNDING: still to fill (see to-do).**

**Tier 4 — Built + DoD-green offline, pre-fork & pre-deploy**:
- **PossessioPool** (`src/PossessioPool.sol`) — "the Heart." Shared economic pool: every organ's fee inflow → one USDC balance; velocity floor keeps infrastructure funded; only surplus above the floor draws one-way to the immutable operator. Relocated from audited x402Core v0.6, generalized to the authorized-source set. **NOW COMMITTED** (was a loose file) with a green DoD suite (`test/PossessioPool.t.sol`, 22/22 incl. 2 fuzz). PENDING per its own header: (1) fork-prove on Base; (2) calibrate floor params to real throughput/cost data; (3) cold-seat re-audit before immutable freeze.
- **x402Core** (`src/PossessioX402Core.sol`) — the reusable pay-per-call payment engine (EIP-3009); the foundation the data-product APIs (and PITI) are built on. Testnet deploy lane built (`script/DeployX402Testnet.s.sol`, ratified *placeholder* economics). Tests pass OFFLINE against mocks (`test/X402TestnetMocks.sol`) + decay suite (ffi). **PENDING, in order:** (1) fork run — `X402_FORK_RPC=<Base Sepolia RPC>` against real chain state; (2) testnet `--broadcast` deploy (no address exists yet); (3) ratify real economics (placeholders now); (4) mainnet deploy. **THIS IS THE GATE for PITI.**

**Running (off-chain infra):** the console (possessio.io — operates the live contracts, real wallet-confirmed txns), the Solana radar (self-running), the Superfoods app (live).

---

## AI Live Selection feed (radar) — BUILT & LIVE (2026-07-11)

The radar's screened-candidate feed. Ratified public (Architect, Amendment IV Clause 5): shows the SELECTION to promote the x402Core autonomous trader + feed the pool; shared visibility on a $10k micro-cap is a tailwind, never entry/exit prices or size.

- **The screen** (`radar/screen.ts` `screenScan`, every-minute cron): RULEBOOK §1 — pre-DEX (`watching`) + age 4–7min + curve MC in the $8–13k band → writes to `candidates`. **Paper-only, no keys, no orders.**
- **Outcome tracker**: §1 exit ladder — $20k target / $6k stop / graduation (edge-loss) / 10-min time-stop.
- **Continuous tracking past the DEX boundary** (`dexTrackScan`): once a candidate graduates, keeps enriching it for 48h with live DexScreener data (price, MC, liquidity, vol1h, 5m, 1h). One row = the coin's whole arc: pump.fun feeds pre-DEX, DexScreener feeds post-DEX.
- **Public feed page** `/feed` (`radar/feed.ts`): dark, self-polling, honest "most fail by design — you're watching a discipline" framing + the x402Core pitch. Screener-style rows (entry→now/peak %move, chart↗ link, ON-DEX line).
- **Console button**: Markets → **AI Live Selection** (`public/index.html`).
- **LIVE at:** `https://possessio-radar.jonb89201.workers.dev/feed` (verified rendering 2026-07-11).
- **DB**: `candidates` table (migrations 0007 + 0008), applied live to `possessio-radar-ledger`.

**Deploy note:** the radar worker deploys **manually** (`cd radar && npx wrangler deploy`) — the repo→Cloudflare connection only rebuilds the console/site, NOT this separate worker. Deploy from branch `claude/internet-access-xdttz9` (the code isn't on main).

**Open follow-ups:**
- [ ] **Validate §1**: watch the `candidates` tally over days — target/stop/graduated/timestop. This is the ledger that kills or confirms the method (§7). Method still UNPROVEN.
- [ ] **Rug gate (§2)** + **Session gate (§0)** are `NULL` (not evaluated) — need on-chain creator-holdings data + Solana vol-vs-7d data wired before they're real.
- [ ] **`radar.possessio.io`** deferred: needs possessio.io as a full Cloudflare zone (nameserver migration) → risks the Resend email records. Not worth it for a feed page; workers.dev URL works. Do the domain move only deliberately, later.

**Named provable accomplishment — in-app mobile debug console ("MIB DEBUG"):** a live on-device inspector built into the console — timestamped logs, bridge status, and full raw JSON-RPC transaction payloads with exact wallet error/revert codes (e.g. `eth_sendTransaction` calldata, `to`, gas, `code: 4001 ACTION_REJECTED`, ethers version). Desktop-F12-grade inspection **on a phone**, where mobile browsers provide none — the enabling tooling that makes phone-only contract development and debugging actually possible, not a boast. **Provable:** open possessio.io and tap DBG. (Evidence: console screenshot 2026-07-09, showing the raw `eth_sendTransaction` to PossessioPayments `0x1c0F…AB91` and the live "no factory configured for chain 8453" RAIL log.)

**Build model:** mobile-only, one architect directing a multi-model AI council, 690 tests / 33 suites — adversarial, invariant, fork-proven. The mobile-only claim is backed, not asserted: mainnet deploys go out from the phone, and the on-device MIB DEBUG console (above) provides the F12-grade inspection that makes debugging on a phone real.

---

## The locked description

> **POSSESSIO** is a mobile, self-custody console for launching and running real on-chain finance — in plain English, straight from your phone.
>
> You deploy your own contract (practice on testnet, or go live on mainnet) and then run it like a banking app. Card payments pool into a stable reserve; a single slider splits the rest between savings and lending; every control is labeled for humans — "Money Waiting," "My Savings," "cash cushion" — not DeFi jargon. Because it's self-custody, POSSESSIO never touches the money: you own your contract outright.
>
> Underneath is a full, verifiable protocol. Live and code-verified on Base mainnet today: a payment engine (PossessioPayments) and a fail-closed cbETH valuation guard (LSTExchangeRate). Fork-tested and ready to deploy: a Uniswap V4 treasury engine with Chainlink automation, and an Ethereum settlement layer. 690 tests across 33 suites — adversarial, invariant, fork-proven. Check the contracts on-chain; run the tests yourself.
>
> The whole point is access — and access starts with safety. You learn by doing the real thing, not reading about it: deploy and run an actual contract on testnet, free, with practice funds provided, until it feels like second nature — then go to mainnet when you decide you're ready. The mainnet deployment fee (testnet is free) routes to a protocol-owned pool, alongside usage fees from x402Core — the reusable pay-per-call engine the protocol's data APIs are built on (the first, an autonomous-trading intelligence layer, in development). A closed flywheel: every deployment and every API call compounds the protocol's own resources.
>
> All of it — every contract, test, and deploy — was architected and shipped from a phone, by one person directing a council of AI models under strict verification discipline. That's not a slogan: the console carries its own on-device debug inspector (raw JSON-RPC payloads, exact wallet error codes — desktop-F12-grade, on a phone), because mobile browsers give you no F12, and you can't build on-chain from a phone without one. Open it yourself.
>
> A normal person, not just a crypto native, holding and moving money on-chain from their pocket — and truly owning it. That's the on-ramp.
