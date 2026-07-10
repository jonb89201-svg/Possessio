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

## Base / grants

- [ ] Finish **Builder Code** setup on dashboard.base.org — paste the locked description (below).
- [ ] Nominate POSSESSIO for a **Base Builder Grant** — grants.base.eth form (retroactive, shipped-work; you qualify on live contracts).
- [ ] Apply to the **CDP AI Builder Program** (~$15K) — best-fit angle for the AI-council build.

## Superfoods (side project)

- [ ] Play Store: **Google Play Developer account** ($25) + PWABuilder → Claude wires the `assetlinks.json`.
- [x] App live at superfoods-logan.jonb89201.workers.dev
- [x] Weekly flyer — Tuesday-night reminder set (fires into this session).

## Parked (deliberately not now)

- ⏸ **Fundstrat / Tom Lee (MAVAN) email** — drafted, held. Send only after (a) ecosystem standing (a grant) and (b) the real MAVAN staking interface. The ask *is* that interface; L1Anchor's `IMAVANEntry` is a placeholder.
- 💭 **Whisky RWA** (allocated tokenized casks via bonded warehouse) — vision stage, its own grant doors. Not started.

---

## Status board (what's real, honestly tiered)

**Live & code-verified on Base mainnet:**
- PossessioPayments `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91`
- LSTExchangeRate `0xDDb75e974d99FcF95E241adbFD376861c47a8548`
- PLATE v1 `0x726D6a7A598A4D12aDe7019Dc2598D955391E298` (dormant)

**Fork-tested, ready to deploy:** V3 treasury engine (`POSSESSIO_v2-6-3.sol`), L1Anchor (Ethereum settlement)

**Built, pre-fork/deploy:** x402Core (mock-green; fork run + deploy pending)

**Running:** the console (possessio.io), the Solana radar, the Superfoods app

**Build model:** mobile-only, one architect directing a multi-model AI council, 690 tests / 33 suites.

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
> All of it — every contract, test, and deploy — was architected and shipped from a phone, by one person directing a council of AI models under strict verification discipline.
>
> A normal person, not just a crypto native, holding and moving money on-chain from their pocket — and truly owning it. That's the on-ramp.
