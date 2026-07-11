<!-- RESOLUTIONS LOG — 2026-07-11 (Claude Code, against base/base-std @ B20 mainnet) -->
> **BUILD STATUS:** `src/PossessioWhiskyMarket.sol` v0.1 written + **compiles against
> the real base-std IB20 + IPolicyRegistry interfaces** (solc 0.8.35). PRIMARY English
> live-event auction module only; secondary order book is the next module. NON-PROVEN —
> mock/fork tests pending `base-foundryup` (§8). The seat that wrote this does not certify it.
>
> **Decisions locked this session:**
> - **V1 (policy scopes) RESOLVED → §3 architecture (a).** B20 exposes independent slots
>   `TRANSFER_SENDER_POLICY` (checks `from`), `TRANSFER_RECEIVER_POLICY` (checks `to`),
>   `TRANSFER_EXECUTOR_POLICY`, `MINT_RECEIVER_POLICY`. Option (b) "force all transfers
>   through the market" is **impossible** — a member selling means `from`=member, so members
>   must be in the sender allowlist; you can't exclude them. So: bind the ONE membership
>   allowlist to sender+receiver scopes; members trade freely; fee at the market; record via
>   Transfer/Memo events. (a), interface-proven.
> - **V5 (memo) → `bytes32`.** `Memo(caller, bytes32 memo)` via `transferFromWithMemo`.
>   Delivery-order ref must be a 32-byte hash/compact ref, not a string.
> - **Auction form → ENGLISH, live-event ("aficionado") shape:** scheduled start, short
>   window, anti-snipe extension, reserve, min-increment. The Habanos spectacle is the app
>   layer over this mechanism.
> - **⚠️ B20 Asset is rebasing-capable** (`multiplier`/scaled balances). Whisky pins
>   multiplier at WAD, never rebases (OPERATOR-role-gated) — 1 token = 1 bottle, fixed.
> - **Contract design calls (in-code, vetoable):** D-BID escrowed binding USDC bids
>   (lot tokens stay non-custodial); D-ARCH market + token both gate on the allowlist;
>   D-BOTTLE whole-bottle multiples enforced; D-FAIL below-reserve / winner-blocked → no-sale + refund.
>
> **Toolchain (§8):** `forge install base/base-std` + `base-foundryup --install v1.1.0`
> (stock Foundry cannot simulate B20 precompiles). base-std is a dependency, not vendored.
> **Deploy remains gated on §7 legal + the pool wave (mine market salt → address → pool source set).**

---

# SPEC — POSSESSIO Whisky Market ("The Bond")

**Status:** PROPOSED — v0.1 spec. Architecture ratified in session (2026-07-11);
interfaces grounded in Base B20 docs + base-std repo as of B20 mainnet activation
(2026-07-08). NON-PROVEN. Cold-seat re-audit before ratification.

**What this is:** tokenized ALLOCATED BOTTLES held in a bonded warehouse. Bottles
never move; ownership does. Own app (NOT a console room) — paid, private,
KYC/jurisdiction-gated. Every fee feeds the one PossessioPool. Another organ,
same bloodstream.

---

## 0. THE THREE-LAYER SPLIT (ratified)

1. **On-chain (fluid):** B20 lot tokens = beneficial ownership. Transfers gated
   by PolicyRegistry allowlist (KYC'd members only).
2. **Holding company (fixed):** WOWGR-registered legal owner-of-record of the
   bonded position. Token holders hold beneficial interest through it.
3. **Warehouse keeper (anchor):** physical custody + HMRC-mandated ownership
   record. By prior WRITTEN AGREEMENT, honors the on-chain ledger as the
   beneficial-ownership record (the automated delivery order).

---

## 1. THE ASSET — B20 LOT TOKENS

**One B20 token per bottling LOT** (identical allocated bottles of one release
are fungible within the lot; different lots are different tokens). NOT one token
per bottle — lot-level fungibility is what makes an order book possible.

- **Issuance:** via the singleton `B20Factory` precompile at
  `0xB20F000000000000000000000000000000000000`. NOT via POSSESSIO's CreateX
  factory. Deterministic address from creator + variant + salt (addresses carry
  `0xb2` prefix + variant byte). The app WRAPS factory calls; issuer = the
  holding company's address.
- **Variant:** `Asset` (the live docs ship two variants: Asset + Stablecoin —
  the "security token" third category seen in pre-launch code is NOT in the
  launched docs; the whisky token is an Asset-variant token wearing securities
  compliance via policies + roles). Decimals: minimum is 6.
  > **FLAG (Architect): decimals floor = 6 means fractional bottles are
  > possible at token level.** Either embrace it (fractional bottle ownership,
  > bigger market, messier redemption) or constrain to whole-bottle trades at
  > the market-contract layer (token stays 6-dec but market enforces 1e6
  > multiples). Whole-bottle-at-market is the conservative default.
- **Supply cap = bottle count in the lot.** Immutable cap per lot token.
- **Memos:** every settlement writes the delivery-order reference into the B20
  memo — the paper trail the warehouse keeper and HMRC want, native.
- **Roles (B20 = OZ AccessControl + fixed base roles):** holding company holds
  admin/minter/pauser at issuance. `burnBlocked` (freeze/seize) exists —
  REQUIRED for a regulated security (court orders, probate, fraud), NEVER used
  on sovereignty-rail assets. Document the role-holder policy per lot.
  `renounceLastAdmin()` is the only path to admin-less — NOT used here (a
  regulated security keeps an accountable admin).

---

## 2. COMPLIANCE LAYER — POLICYREGISTRY

- PolicyRegistry = singleton precompile; policies are uint64 IDs;
  `createPolicy(admin, PolicyType.ALLOWLIST)` then
  `updateAllowlist(policyId, true, accounts)` (batched).
- **One membership ALLOWLIST policy** shared across all lot tokens: an account
  enters at KYC/age/jurisdiction clearance (paid membership approval), exits at
  revocation. The gate is chain law, not app policy: any transfer touching a
  non-member reverts `PolicyForbids`.
- Policy admin = holding company compliance role (multisig or Base Account —
  Architect decision at entity setup).
- **CRITICAL semantics (from docs):** non-existent ALLOWLIST denies everyone;
  `isAuthorized` never reverts on a missing ID. Therefore `policyExists()` MUST
  be validated at every point a policy ID is written to a token. A typo'd ID
  silently bricks all transfers.
- **VERIFY item V1:** the exact set of B20 policy scopes (sender / recipient /
  mint-recipient / etc.) — read `IB20.sol` + `IPolicyRegistry.sol` +
  `B20Constants.sol` in `base/base-std` before binding. The spec assumes
  sender AND recipient scopes can bind the same membership allowlist.

---

## 3. OWNERSHIP-RECORD SYNC (the delivery order) — DESIGN FINDING

**Original ratified design:** V4 hook fires on transfer → updates warehouse
record + takes fee. **B20 changes the picture and the spec must be honest
about it:**

- B20 `Transfer` events fire on EVERY transfer path (market trade, P2P,
  anything). The warehouse-record relay can key off the TOKEN's events —
  covering ALL ownership movement — instead of only trades that pass through a
  V4 pool hook. **Token events are the more complete delivery-order feed.**
- The V4 hook only sees pool trades. Members transferring P2P (both allowlisted)
  would bypass a hook — desyncing the record AND skipping the fee.

> **FLAG (Architect) — the P2P question decides the architecture:**
> **(a) Fee only on market trades; P2P allowed, record-synced via Transfer
> events.** Members can gift/move between their own wallets fee-free; the
> relay keeps the warehouse record true on every path. Honest record, leaky
> fee. **(b) Force ALL transfers through the market contract** — if scope
> semantics permit an allowlist containing only {market contract, holding co}
> for the transfer scope while members remain balance-holders, every ownership
> change pays the fee and syncs in one place. Tighter fee capture; depends on
> V1 scope verification; more restrictive UX (no self-custody moves between a
> member's own wallets without a market round-trip).
> Default assumption for v0.1: **(a)** — record integrity via token events,
> fee at the market. Fee-free P2P between KYC'd members is defensible; a
> desynced warehouse record is not.

**The relay (off-chain, minimal):** watches `Transfer` + memo events on lot
tokens → posts beneficial-ownership updates to the warehouse keeper's system
per the written agreement. This is the ONE off-chain bridge; it carries record
updates, never funds. Host on already-connected infra (Cloudflare Worker).
The warehouse keeper's countersigned acceptance of this feed IS the
load-bearing legal instrument (§7).

**The V4 hook's remaining role:** IF a secondary AMM pool is wanted for lot
tokens (continuous liquidity vs. order-book-only), the existing 0x8C8 hook
pattern applies and its fee joins the same flow. OPTIONAL organ, not required
for v0.1. Auction + market-contract secondary is the v0.1 scope.

---

## 4. THE MARKET CONTRACT (what POSSESSIO actually builds)

`PossessioWhiskyMarket.sol` — the only substantial new Solidity in this project.

- **Primary: RWA auctions.** Holding company lists a lot (bottle count, reserve,
  auction window). Members bid in USDC. Settlement: winner pays, market
  transfers lot tokens winner-ward, memo carries the delivery-order ref, fee
  skims to the pool.
  > **FLAG (Architect):** auction form — English (open ascending) vs sealed-bid.
  > English is the spirits-trade norm and the spectacle; sealed is simpler
  > on-chain. Not decided here.
- **Secondary: member order book.** List/bid/settle lot tokens between members,
  same fee skim, same memo discipline.
- **Fee:** bps on every settlement (primary + secondary) → USDC →
  `PossessioPool.receiveInfraFunds(fee)`. The market contract must be in the
  pool's authorized-source set (§6). Fee bps immutable at construction
  (calibrate before freeze — same discipline as everything).
- **Membership gate:** market checks the SAME PolicyRegistry allowlist
  (`isAuthorized`) before accepting bids/listings — one membership truth,
  checked at both token and market layer (defense in depth).
- **Custody model:** non-custodial listings (escrow-on-settle via allowance),
  matching Payments discipline. The market never warehouses tokens longer than
  a settlement.
- Access/membership PAYMENTS (the paid-app fee) settle in the app via the
  existing Payments/x402 rails — access fee → pool. Not this contract's job.

---

## 5. THE APP (own app, own identity)

- Separate front-end from the console. Paid, private. Gating = the compliance
  filter (KYC, age, jurisdiction) — membership approval writes the allowlist.
- Wraps: B20Factory issuance (holding co), PolicyRegistry admin ops, auction UX,
  order book, warehouse-record status per lot (read from the relay), redemption
  request flow (bottle leaves bond = duty/VAT event — quote it honestly).
- **PolicyForbids UX (from Base's integrator guidance):** pre-send simulation on
  every transfer so a member sees WHY before signing. A transfer that passes
  ERC-20 checks can still revert at the policy gate.
- Operator-entity note: a paid venue for trading securities likely makes the app
  operator a regulated entity — same counsel workstream as §7.

---

## 6. POOL WIRING (the organism)

- Inflows to the ONE pool: membership/access fees + market settlement fees
  (+ optional future hook fees). All via bound `receiveInfraFunds`.
- **SEQUENCING CONSEQUENCE (pool v0.1 authorized-source set is immutable at
  construction):** the pool is BUILT (714 baseline) but NOT YET DEPLOYED — the
  wave hasn't happened. The whisky market address must therefore be KNOWN and
  included in the pool's source set at pool deploy, OR the whisky market joins
  a later pool deployment. Since market addresses via CreateX are
  deterministic (mine the salt first), the address CAN be known before the
  market is built. Wave runbook must sequence: mine market salt → know address
  → deploy pool with full source set.

---

## 7. LEGAL GATES — DEPLOY BLOCKERS, NOT BUILD BLOCKERS

Contracts can be built and fork-proven now. NOTHING deploys to mainnet until:

1. **Holding company** exists: WOWGR-registered (if UK/HMRC), bankruptcy-remote,
   owner-of-record structure blessed by counsel.
2. **Warehouse-keeper agreement** signed: keeper accepts the relay feed as the
   beneficial-ownership record (the delivery-order automation, per Excise
   Notice 196/197 mechanics). This is the L1Anchor of the project.
3. **Securities framing** blessed: token issuance + trading venue structure
   (CLARITY-sorting aware). Fee mechanism blessed in the same opinion.
4. **Jurisdiction decided:** UK/HMRC (Scotch, WOWGR, Notices 196/197) vs US/TTB
   (bourbon) — determines 1–3. UNDECIDED. The contracts are
   jurisdiction-agnostic; the entities are not.

---

## 8. TOOLING (real, from the Beryl docs — affects MIB)

- **Stock Foundry CANNOT simulate B20 precompiles.** Required:
  `base-foundryup --install v1.1.0` (Base's Foundry build). This is a NEW MIB
  step for whisky-project terminals.
- Unit tests without fork: `base/base-std` mocks (`MockB20Factory`,
  `MockPolicyRegistry`, `MockActivationRegistry`) + interfaces (`IB20.sol`,
  `IB20Asset.sol`, `IB20Factory.sol`, `IPolicyRegistry.sol`, `B20FactoryLib`).
  `forge install base/base-std`.
- B20-active test environments: **Base Sepolia (84532)**, Vibenet (84538453),
  local base-anvil (31337).
- ActivationRegistry gates PolicyRegistry writes — verify feature flags live on
  the target chain before any issuance run.

---

## 9. VERIFY-ON-TERMINAL (before the market contract is written)

- **V1:** B20 policy scope list + exact bind semantics (read base-std
  interfaces). Decides FLAG (a)/(b) in §3.
- **V2:** B20-in-V4-pool compatibility (only if the optional AMM organ is
  wanted).
- **V3:** B20Factory `createB20` param shape + initCalls encoding
  (`B20FactoryLib`).
- **V4:** ActivationRegistry status on Base Sepolia for B20 + PolicyRegistry
  writes.
- **V5:** memo size/format limits (delivery-order ref must fit).

---

## 10. DEFINITION OF DONE — PossessioWhiskyMarket.sol (forge, Base's build)

1. Auction lifecycle: list → bid → settle transfers lot tokens + USDC
   atomically; loser refunds exact.
2. Fee skim: every settlement routes exact bps to
   PossessioPool.receiveInfraFunds; seller nets exactly (price - fee).
3. Non-member cannot list, bid, or receive (both market-gate and token-layer
   PolicyForbids paths tested).
4. Memo written on every settlement; format matches the relay's parser.
5. Non-custodial: market balance is zero outside a settlement tx (fuzz).
6. Whole-bottle enforcement (if FLAG resolves conservative): non-1e6-multiple
   trades revert.
7. Freeze semantics: a frozen/blocked account cannot settle in either
   direction; in-flight auctions with a newly-blocked party fail safe (refund).
8. CEI + reentrancy discipline throughout; adversarial suite (griefing bids,
   settlement-front-run, allowance-yank mid-settle).
9. Fork suite green on Base Sepolia with LIVE precompiles (not just mocks).
10. Pool integration: market is an authorized source; fee lands; pool floor
    behavior unaffected (cross-suite with PossessioPool.t.sol).

---

## OUT OF SCOPE v0.1
Optional AMM/hook organ (§3), fractional-bottle market (unless FLAG flips),
redemption/duty-payment automation (app quotes it; manual process v0.1),
multi-jurisdiction entity structure (pick ONE first).

*Grounded in: docs.base.org/base-chain/specs/upgrades/beryl/b20, base/base-std
repo, Beryl launch coverage (2026-06-25 fork, 2026-07-08 activation). PROPOSED.
The seat that wrote this does not certify it.*
