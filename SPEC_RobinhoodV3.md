# SPEC — V3 on Robinhood Chain: the same launch, a second door

**Type:** Protocol-layer spec (draft → council review → Architect ratification → DoD → fork-proof)
**Seat:** Code seat, this session (2026-08-13), reading `src/PossessioLaunchFactory.sol`,
`src/PossessioLaunchTemplate` (unbuilt — see §1), `SPEC_LaunchTemplate.md`, and Robinhood Chain's
own published deployments against a live query this session.
**Status:** DRAFT FOR COUNCIL. Every claim below is marked VERIFIED (checked from a primary
source this session) or OPEN (a real gap — do not build against it as fact). Nothing here exists
until the terminal proves it, per the standing rule.

**Thesis note (Architect, 2026-08-13):** grants scoped per launched contract, not per protocol,
were already the plan — the infrastructure to actually execute that (a factory that deploys
independently verifiable, independently fundable artifacts one at a time) didn't exist until
recently. This spec is that infrastructure's second chain, chosen because it changes who a launch
is *for*: Robinhood Chain is purpose-built for tokenized real-world assets, reached by a
brokerage's retail audience — a materially different, higher-scrutiny surface than Base or the
Solana radar's memecoin flow.

---

## 0. Creed (the standing test, unchanged)

> **Non-extraction with full sovereignty. Immutable and deterministic at its core.
> On-chain transparency.**

Nothing in this spec asks for an exception. A second chain is a second door on the same house,
not a different house.

## 1. What actually ports (verified from source, this session)

**`PossessioLaunchFactory.sol` is template-agnostic.** `deployLaunch()` takes the launch's
`initCode` as a runtime argument; the factory's only opinion is that its hash matches an
immutable `templateCodehash` fixed at construction (`TemplateCodehashMismatch` reverts on any
other bytecode). The factory does **not** hardcode a specific launch contract.

**The actual per-launch template — the minimal STEEL-pattern coin+hook that gets CREATE3-deployed
on every `deployLaunch()` call — does not exist yet as production Solidity.** `SPEC_LaunchTemplate.md`
§5's Option A/B topology call (one contract vs. two) is still open; council-board task #8 this
session records it BLOCKED on exactly that decision. This is not a Robinhood-specific gap — it
blocks the Base launch too, today.

**What this means for scope:** "a Robinhood version of V3" is not a rewrite. Once the launch
template is built (chain-agnostic by construction if it takes `PoolManager` as a constructor
param the way the flagship `PossessioHook` already does — verified, `POSSESSIO_v2-6-3.sol:807`),
porting it to a second chain is a **second factory instance, wired to that chain's own
infrastructure** — not new template code. This spec is that wiring.

**The flagship `PossessioHook` (`POSSESSIO_v2-6-3.sol`) is NOT what ports.** Its `DeployParams`
hardwires `cbETH`, a Chainlink cbETH/ETH feed, and an Aerodrome Slipstream router (`POSSESSIO_v2-6-3.sol:804-816`)
— all Base-specific treasury plumbing that has nothing to do with the launch template's job
(fee capture + POL gate on an arbitrary paired coin). Conflating the two would smuggle
Base-only dependencies into a Robinhood deploy; the spec below only ever means the launch
template.

## 2. Robinhood Chain — verified this session, sourced

Checked against Robinhood's and Uniswap's own published material (WebFetch/WebSearch this
session; **not** independently `eth_getCode`-verified — this seat's chain-RPC tool
(`mcp__Base__chain_rpc_request`) supports a fixed chain list (arbitrum, avalanche, base,
base-sepolia, bsc, ethereum, optimism, polygon) and Robinhood Chain (4663) is not on it. Treat
every address below as **sourced, not proven** — the Architect's terminal or any RPC-reachable
seat must confirm via `eth_getCode` before any deploy, per Amendment VII, terminal > doc):

- **Chain ID 4663.** Arbitrum Orbit chain on the Nitro stack, settles to Ethereum L1. EVM-compatible
  — same execution engine, fraud-proof design as Arbitrum One.
- **Gas token: ETH.** Matches Base; the launch template's ETH-denominated 2% fee math needs no
  redenomination.
- **Mainnet live since 2026-07-01** (testnet 2026-02-10).
- **Uniswap v4 live from day one**, sourced from `developers.uniswap.org`'s deployments doc:
  - PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`
  - PositionManager `0x58daec3116aae6d93017baaea7749052e8a04fa7`
  - Quoter `0x8dc178efb8111bb0973dd9d722ebeff267c98f94`
  - StateView `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b`
  - Universal Router `0x8876789976decbfcbbbe364623c63652db8c0904`
  - Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` (matches the canonical cross-chain
    Permit2 address — consistent with a real deployment, not a fabricated one)
- **WETH, sourced from `docs.robinhood.com/chain/contracts`:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **USDG (stable), same source:** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- **CreateX at the canonical cross-chain address (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`)
  is claimed but NOT confirmed present on chain 4663 specifically** — search results returned
  CreateX's general documentation, not a chain-4663-specific confirmation. **OPEN, §6.1.**
- **Robinhood Chain hosts a live on-chain registry of tokenized stocks and ETFs**
  (`docs.robinhood.com/chain/contracts`, "generated live from the on-chain asset registry").
  **This registry is almost certainly permissioned** — Robinhood controls listing of regulated
  securities; nothing here assumes open access to it. See §4.

## 3. Wiring constraints (what a Robinhood factory instance actually needs)

Mirroring `PossessioLaunchFactory`'s existing constructor shape:

1. **CreateX** at the verified-present address on 4663 (§6.1 gates this — do not deploy before
   it's confirmed, or a chain-specific keyless CreateX deployment tx must be submitted first;
   that transaction is permissionless and public if needed).
2. **PoolManager** — the address in §2, pending independent `eth_getCode` confirmation.
3. **SaltPool, chain-local.** Salts are pre-mined 0x8C8 hook-flag salts, sender-locked to the
   factory's own address (`guarded salt = keccak256(abi.encodePacked(bytes32(uint160(sender)), salt))`).
   Whether Base-mined salts are reusable on Robinhood Chain depends on whether the two factory
   instances share an address — achievable if both are themselves CREATE3-deployed via CreateX
   from the same deployer EOA + salt + init code, since CreateX's whole design goal is
   chain-independent address reproduction. **Unverified for this codebase's exact salt-guard
   formula — treat portability as OPEN (§6.2), mine fresh if not proven.**
4. **The pairing asset.** The Base factory pairs every launch against `COUNCIL_TOKEN`, immutable
   at construction. `COUNCIL_TOKEN` lives on Base and has no native presence on chain 4663 — a
   Robinhood factory instance cannot pair against it directly without a bridge leg. **This is the
   load-bearing open question, §6.3** — same shape as `SPEC_LaunchTemplate.md`'s currency-ladder
   discipline (ETH never touches the AI economy directly; the ladder is deliberate, not an
   oversight) applied to a second chain.
5. **Deploy fee currency.** The Base factory settles its deploy fee in USDC via EIP-3009
   (`receiveWithAuthorization`). USDC's presence and EIP-3009 support on chain 4663 is
   **unverified — OPEN, §6.4.** USDG (verified present, §2) may be the natural chain-local
   substitute; whether it supports the same authorization pattern needs checking against its own
   source before assuming compatibility.

## 4. What this is NOT (scope discipline, stated up front)

This spec does **not** propose pairing V3 launches against Robinhood's own tokenized stock/ETF
registry. That registry is almost certainly permissioned and represents regulated securities;
treating it as an open pairing target without Robinhood's explicit terms and a securities-law
read would be exactly the kind of claim Codebyte Law forbids — asserting access to something
this seat has no evidence of holding. The realistic pairing target is a chain-local asset (WETH,
USDG, or a bridged council-token representative — §6.3) exactly as STEEL pairs against WETH on
Base today. If Robinhood ever opens permissioned listing partnerships, that is a distinct,
future, separately-ratified conversation — not assumed here.

## 5. Why this chain (the actual thesis fit)

Robinhood Chain's audience is retail brokerage users being onboarded into tokenized finance —
people already inside a regulated, KYC'd, higher-trust surface, not degen liquidity chasing a
pump.fun curve. A non-extractive, no-admin-key, POL-gated launch mechanism is a genuinely
different pitch to that audience than it is on Base or Solana: "the fee structure and the
liquidity ownership are enforced by bytecode, not a promise" lands harder with an audience a
brokerage already vetted. This is the same instinct behind the per-contract grant plan — each
launch stands as its own small, independently verifiable, independently fundable artifact; a
second chain multiplies the doors that artifact can be shown through, it doesn't change what it is.

## 6. OPEN for the council (rule these before any deploy)

1. **CreateX presence on chain 4663** — confirm via `eth_getCode` from an RPC-reachable seat or
   the Architect's terminal before anything else. If absent, the canonical keyless deployment
   transaction is public and permissionless to submit.
2. **Salt portability** — does the sender-locked guarded-salt formula in `PossessioSaltPool`
   produce chain-independent results for a given (deployer, salt) pair under CreateX's actual
   address-derivation, or must Robinhood-chain salts be freshly mined against a
   Robinhood-deployed factory address? Verify against CreateX's own source before assuming either
   answer.
3. **Pairing asset** — chain-local WETH/USDG pairing (simplest, no bridge dependency) vs. a
   bridged representation of `COUNCIL_TOKEN` (preserves the single-token thesis across chains,
   costs a bridge-trust dependency `SPEC_LaunchTemplate.md`'s ladder discipline was built to
   avoid). Seat lean: chain-local pairing first, matching how STEEL itself pairs against WETH
   rather than a cross-chain asset on Base.
4. **Deploy-fee currency** — USDC-on-4663 with EIP-3009, or USDG with an equivalent
   authorization primitive, or a differently-shaped fee settlement. Needs its own verify-first
   pass against whatever token is chosen.
5. **Sequencing** — this spec is naturally BLOCKED on the same §11.2 topology decision
   (`SPEC_LaunchTemplate.md`) that blocks the Base launch template itself (board task #8). Ruling
   §11.2 unblocks both chains at once; there is no reason to solve it twice.
6. **PoolManager / CreateX address confirmation** — every address in §2 is sourced from official
   docs, not `eth_getCode`-verified by this seat. Confirm before pinning anything as canonical,
   per Amendment VII.

## 7. DoD sketch (assertable once §6 is ruled)

1. `PossessioLaunchFactory` (or an unmodified re-deploy of the same bytecode) constructs cleanly
   on chain 4663 against confirmed CreateX + PoolManager + SaltPool + pairing-asset addresses.
2. `deployLaunch()` against the SAME `templateCodehash` as the Base factory succeeds — proving
   the launch template itself needed zero Robinhood-specific changes, only new wiring.
3. The deployed launch's v4 pool initializes against the chosen chain-local pairing asset;
   `pairKeyOf` returns the correct sorted-currency key.
4. Fork suite proves against a live chain-4663 RPC (not just an offline mock) before any real
   fee is settled — same two-mode discipline as every other constellation contract.
5. Codehash gate rejects any bytecode not matching the ratified template, identically to Base.

---

*Cold-seat review before ratification. If it can't be tested, it doesn't exist; if it's not in
the terminal, it's not proven — and for this spec, "the terminal" includes an RPC this seat could
not reach tonight. Every unverified address above is a task for the next seat that can.*
