# SPEC — PossessioAutoTarget (human-pick, rule-exit, pay-per-trade)

**Type:** Build spec (draft → Architect ratify → build → on-device verify)
**Date:** 2026-07-18 · **Seat:** Code Integrity (repo council seat)
**Status:** NON-PROVEN until `forge test` is green AND the Architect signs an
`openIntent` from the console on device. This document authorizes the on-chain
`PossessioAutoTarget` contract + its DoD/adversarial/fork suites.

---

## 0. The product in one sentence

**The AI pre-screens a live list; the human picks one and clicks a target; a
hard −10% stop is always on; the machine mechanically fires the exit — and the
user pays a per-transaction fee for that capability.**

This is the deliberate inversion of R3. Our own forward ledger proved the
*automated entry-and-exit loop* loses (n=41, avg −9.1%, no edge, the stop gaps
to −82%). So we **do not automate the trade**. We automate the *finding* (the
radar's real edge) and the *exit discipline* (a rule that can't be argued with),
and we hand the *entry decision and the risk* to the human. The losing part —
the unattended loop deciding what to buy — is removed.

---

## 1. What is sold (and what is NOT)

- **Sold:** (a) the AI's live pre-screened candidate board, (b) one-click
  rule-bounded exit execution, (c) the discipline of an un-removable stop.
  Monetized **per transaction**, on-chain, receipts in events.
- **NOT sold:** the alpha (Business Model R3 — "the alpha is never templated").
  The user makes the pick; we never publish a "buy this now" signal. What ships
  is a *screen + a rail + a rule*, not an edge.

---

## 2. The method (buttons)

Per trade the user selects exactly one **target button**, and the **stop is
implicit and always attached**:

| button | targetBps | meaning |
|---|---|---|
| +10% scalp | 1000 | take the quick pop, sell at +10% |
| +25% | 2500 | sell at +25% |
| +50% | 5000 | sell at +50% |
| **−10% stop** | **1000 (always)** | **sell at −10%, no matter which target — NOT optional** |

Structural rule: **you cannot open an intent without the −10% stop.** It is not
a button the user can turn off; it is a constructor-level constant applied to
every intent. The target is the only choice.

---

## 3. Architecture — the load-bearing decision

**The contract is the paid TRIGGER + DISCIPLINE + FEE layer. It is NOT a
custody or swap engine.** This is the decision that shapes everything; flagged
for the Architect explicitly.

```
   AI radar board (off-chain, D1)                 user's Base Account (passkey)
            │  live pre-screened list                     │  owns funds + keys
            ▼                                              ▼
   user picks ONE + a target button ───► openIntent(token, entryPrice, targetBps, feeAuth)
                                              │  per-tx fee settles (EIP-3009)
                                              │  fee → the Heart (Option A)
                                              │  Intent{stop=1000 always} recorded
                                              ▼
                                         IntentOpened event
            keeper (bounded) watches price ──► resolveIntent(id, observedPrice)
                                              │  price ≥ target  → kind=TARGET
                                              │  price ≤ stop    → kind=STOP
                                              ▼
                                         ExitAuthorized(id, kind, price)   ◄── authoritative
                                              │
             the SWAP runs on the user's rail │  (bounded Base-Account spend
             (xtrade / bounded permission) ───┘   permission, or user co-sign)
```

**Why the swap stays off-contract:**
1. **Non-custodial by construction** (Constitution §9): the contract never holds
   the traded token or the proceeds. It only ever touches the transient per-tx
   USDC fee, which it routes to the Heart in the same transaction.
2. **Chain-agnostic:** the trigger + fee is EVM (Base first, Robinhood Chain
   next); the swap rail can be Jupiter (Solana), 0x/Uniswap (EVM) — the same
   `ExitAuthorized` event drives any of them. Matches `SPEC_CrossChainTradingMCP`.
3. **MEV surface stays off our contract:** we don't route a micro-cap swap
   through protocol code; the user's wallet/aggregator does, with its own
   slippage bound.

**Exit-execution sub-decision — RESOLVED: (A) keeper-side, fully mechanical.**
Ratified 2026-07-18: *"fully mechanical, it's the only way to win these trades
is by being quick."* A human-speed exit on these tokens is a losing exit, so the
exit fires with no per-trade human signature.

- **Locus: keeper-side via Base's `SpendPermissionManager`** (NOT a DEX inside
  this contract — chosen over an on-chain executor to keep the money-path
  non-custodial and free of DEX/MEV surface, and to inherit Base's audited
  spend-permission bounds).
- **Grant flow (console, one UX click, two authorizations at open):**
  1. the user signs the **EIP-3009 fee auth** (USDC, `to == desk`) → `openIntent`.
  2. the user signs a **Base-Account spend permission** on the *picked token*,
     bounded to the position size and expiring at the intent horizon, with the
     keeper as spender. Revocable anytime from the wallet.
- **Exit (keeper, on trigger):** the keeper watches price; the moment it crosses
  target/stop it (a) calls `resolveIntent` — the authoritative on-chain trigger
  (instant, this is the "quick") — and (b) executes the token→USDC swap in one
  tx via `SpendPermissionManager` + a DEX, proceeds hardcoded to the user's own
  wallet by the swap rail, then (c) calls `markExecuted(id, usdcReturned)` to
  record the receipt on-chain.
- **Why this stays safe without on-chain swap code:** the keeper moves funds
  only within the user's *revocable, size-capped* spend permission; the swap's
  proceeds go to the user's wallet (not the keeper); and the full lifecycle
  (`IntentOpened → ExitAuthorized → ExitExecuted`) is a public on-chain receipt,
  so any bad execution is provable. The keeper's residual power — choosing a bad
  slippage on the off-chain swap — is bounded by the permission cap + the user's
  ability to revoke, and is the §6.3 hardening item (keeper is our own infra).

---

## 4. Contract surface — `PossessioAutoTarget`

**Immutables:** `payToken` (USDC as EIP-3009 + ERC20), `feeSink` (the Heart —
must be in its `authorizedSources`, Option A), `keeper` (bounded trigger
authority, compute-only, like the salt keeper), `PER_TX_FEE` (USDC 6-dec).

- `openIntent(address token, uint256 entryPrice, uint16 targetBps, FeeAuth feeAuth)`
  → `uint256 id`
  - validate `targetBps ∈ {1000, 2500, 5000}` else revert `BadTarget`
  - validate `token != 0`, `entryPrice != 0`
  - settle fee: `payToken.receiveWithAuthorization(msg.sender, this, PER_TX_FEE, …)`
    (front-run-closed: `to == address(this)`)
  - route fee INTO the Heart: `forceApprove(feeSink, PER_TX_FEE);
    IPossessioPool(feeSink).receiveInfraFunds(PER_TX_FEE)` (Option A; a raw push
    would strand it, Pool DoD #14)
  - store `Intent{user: msg.sender, token, entryPrice, targetBps, stopBps: 1000,
    status: Open}`; emit `IntentOpened(id, user, token, entryPrice, targetBps)`
- `resolveIntent(uint256 id, uint256 observedPrice)` — `onlyKeeper`
  - require `status == Open`; require `observedPrice != 0`
  - `targetPrice = entryPrice * (10000 + targetBps) / 10000`
  - `stopPrice   = entryPrice * (10000 - 1000)      / 10000`
  - if `observedPrice >= targetPrice` → `kind = TARGET`
    elif `observedPrice <= stopPrice` → `kind = STOP`
    else revert `NotTriggered` (keeper called too early)
  - set `status = Resolved`; emit `ExitAuthorized(id, kind, observedPrice)`
- `markExecuted(uint256 id, uint256 usdcReturnedToUser)` — `onlyKeeper`
  - require `status == Resolved` (its exit already authorized)
  - set `status = Executed`; record `usdcReturned`; emit
    `ExitExecuted(id, kind, usdcReturnedToUser)` — the on-chain receipt closing
    the off-chain swap. Moves no funds (non-custodial).
- `cancelIntent(uint256 id)` — `onlyIntentOwner`, only if `Open`
  - the human can always bail manually; emit `IntentCancelled(id)`
- views: `getIntent(id)`, `targetPrice(id)`, `stopPrice(id)`

**Lifecycle:** `Open → Resolved → Executed`, or `Open → Cancelled`.
Executed/Cancelled are terminal.

**Events (the on-chain receipts — the business model's proof):**
`IntentOpened`, `FeeRouted`, `ExitAuthorized`, `ExitExecuted`, `IntentCancelled`.

---

## 5. Invariants (structural, DoD-enforced)

1. **Stop is un-removable.** Every `Intent` has `stopBps == 1000`. No parameter,
   no setter, no code path sets it otherwise. `resolveIntent` enforces the stop
   even for a +50% target intent.
2. **Non-custodial.** The contract's traded-token balance is *always zero*; it
   never calls `transfer`/`transferFrom` on `token`. The only asset it touches
   is the per-tx USDC fee, and `balanceOf(this) == 0` after every `openIntent`
   (fee routed to the Heart same-tx).
3. **Fee atomicity (Invariant 2, inherited).** If the Heart route reverts
   (factory/this not an authorized source, or Heart bug), the whole `openIntent`
   unwinds — the user is **never charged for a failed open**. Same law as the
   factory line-211 edit.
4. **Front-run-closed fee.** `to == address(this)` in the EIP-3009 auth; no third
   party can settle the user's authorization elsewhere.
5. **Keeper is trigger-only.** The keeper can `resolveIntent` (emit an authorized
   exit) but has **no authority over funds** in this contract — it cannot move
   the user's token or USDC. Worst a rogue keeper does is emit a premature/late
   trigger, which `NotTriggered` price-gates; the swap rail applies its own
   slippage bound.
6. **One resolution.** An intent resolves once; `Resolved`/`Cancelled` are
   terminal. No re-fire, no double-exit.

---

## 6. Honest caveats (named, not hidden)

1. **The stop is a THRESHOLD, not a FILL.** `resolveIntent` authorizes an exit
   at −10%; on a real rug the swap rail fills far worse (the −82% tails our
   ledger measured). This product **cuts the decision lag and enforces
   discipline; it cannot beat gapping liquidity.** The UI must say so. This is
   the single most important honesty line in the product.
2. **List front-running risk (the R3 §137 problem).** If N users get the same
   board and pile into the same thin pump.fun name, they front-run each other
   into the same crater. Mitigations: the board is a *regime-filtered screen*,
   not a single "ape this" call; users pick different names; the −10% stop caps
   each user's damage. But on genuinely thin liquidity, concentration is
   self-defeating — do not market the board as a signal-to-copy.
3. **Oracle for `observedPrice`.** The keeper supplies the price. v1 trusts the
   keeper's read (radar/dexscreener) and price-gates it with `NotTriggered`
   (target/stop math on-chain). A manipulated feed can only trigger a *real*
   target/stop crossing — it cannot invent one — but a lying keeper could pick a
   bad tick within a legitimate crossing. Hardening (TWAP attestation,
   multi-source) is a §7 open item, not v1.
4. **Regulatory surface.** Selling "AI trading capability" edges toward
   regulated territory. Mitigation posture (same as the business model):
   non-custodial by construction, the user decides and signs, we provide a
   tool + a screen. Not legal advice; Architect's call before it goes public.

---

## 7. Open decisions (Architect ratifies; NOT frozen here)

1. ~~Exit-execution model A vs B~~ — **RESOLVED (§3): A, keeper-side, fully
   mechanical.** Remaining sub-item: which `SpendPermissionManager` deployment +
   DEX the keeper uses per chain (deploy/keeper config, not a contract freeze).
2. **`PER_TX_FEE`** — flat USDC per open? (interim: mirror the R1 toll scale,
   e.g. $0.02–0.10) or a bps of notional? Immutable per deploy either way.
3. **Fee destination** — the Heart (Option A, self-funding, recommended) vs an
   operator `TOLL_SINK` batched sweep (R1's pattern). Spec builds Option A;
   swappable at deploy.
4. **Keeper price hardening** (§6.3) — v1 trusts + price-gates; TWAP later.
5. **Chain scope** — Base first; Robinhood Chain (EVM, memecoin-heavy) as the
   second target *iff* CreateX is live there; Solana via a sibling program
   (not this contract).
6. **Multi-target / partial exits** — v1 is single target + single stop, full
   position. Scale-outs (sell half at +25%, ride the rest) are a later version.

---

## 8. Definition of Done (the suites this spec authorizes)

- **`PossessioAutoTarget.t.sol`** (14 DoD) — open at each target button; stop
  always 1000; fee settles + routes to a Heart mock (`received == PER_TX_FEE`);
  `balanceOf(this)==0` post-open; resolve fires TARGET above / STOP below /
  `NotTriggered` between; **markExecuted closes Resolved→Executed and records
  proceeds; markExecuted before resolve reverts**; cancel by owner only;
  terminal-state re-entry reverts.
- **`PossessioAutoTargetAdversarial.t.sol`** (19) — non-owner cancel; non-keeper
  resolve/**markExecuted**; resolve/**mark** after resolve/cancel/execute; a
  +50% intent still stops at −10%; fee-route revert unwinds the open (user not
  charged); front-run of the EIP-3009 auth fails (`to` mismatch); nonce replay
  burns; rogue keeper cannot touch funds; **Executed/Cancelled are terminal**.
- **`PossessioAutoTargetFork.t.sol`** — Base fork: real USDC (EIP-3009 EIP-712
  signed with a `deal`-funded key) → `openIntent` → fee lands in a real-code
  Heart (deployed on the fork) → `poolBalance` credited, `balanceOf(this)==0`.
  Proves the money-path against the real USDC contract, not a mock.

---

*Draft for ratification. On-chain freeze stays governed by the runbook + the
diverse-review gate. The −10% stop and non-custodial balance-zero are the two
invariants that must never regress.*
