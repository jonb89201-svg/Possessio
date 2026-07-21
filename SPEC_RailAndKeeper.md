# SPEC — PossessioRail (executor) + the Keeper

**Type:** Build spec (draft → Architect ratify → build → fork-verify) · **Date:** 2026-07-21
**Seat:** Code Integrity · **Status:** NON-PROVEN until `forge test` green + a live
Base fork round-trip (USDC → token → USDC → vault). Authorizes the on-chain
`PossessioRail` contract, its DoD/adversarial/fork suites, and the off-chain
Keeper's behavioural contract.

---

## 0. The one sentence

**The Rail is the hand that buys and sells; the Keeper is the reflex that times
the exit. Together they turn "capital drawn to the rail" into "position bought,
held, and auto-exited — proceeds home to the vault."**

They close the last gap in the Base trader loop:

```
 FundingVault ──drawForTrade──►  PossessioRail  ──DEX buy──►  holds token
  (capital, capped)             (trader + tradeDestination)
        ▲                              │  Keeper watches price
        │                              ▼
        └──returnProceeds──◄── DEX sell ◄── ExitAuthorized (AutoTarget rule fired)
```

---

## 1. Where it sits — the three contracts, reconciled

This is the crux, so it is stated first and explicitly. Three contracts already
exist or are speced; the Rail + Keeper are the missing execution layer, and they
must **reconcile** two capital models that were speced at different times.

| piece | role | custody? | status |
|---|---|---|---|
| **PossessioFundingVault** | hard-capped capital source. `drawForTrade(id,amt)` → rail; `returnProceeds(id,amt)` ← rail | holds USDC (the war chest) | **built** (this branch) |
| **PossessioAutoTarget** | the DISCIPLINE + FEE + TRIGGER: intent, target, un-removable −10% stop, per-tx fee → Heart, `ExitAuthorized` | **non-custodial** (balance-zero invariant) | **speced** (SPEC_AutoTarget) |
| **PossessioRail** ← THIS SPEC | the SWAP + CUSTODY engine: buys the token on draw, holds it, sells it on an authorized exit, returns USDC to the vault | **holds the position token** (deliberately) | **NEW** |
| **Keeper** ← THIS SPEC | off-chain bounded reflex: watch price → `resolveIntent` → drive the Rail's sell → `markExecuted` | moves funds ONLY within the Rail's intent-gated, capped paths | **NEW** |

### The reconciliation AutoTarget's original spec did not have

`SPEC_AutoTarget §3` deliberately kept the swap **off-contract** and
**non-custodial**, because in *its* model the capital lives in the **user's own
Base Account** and a bounded **spend permission** lets the keeper swap straight
from the user's wallet — nothing our code custodies. That model is still valid
for a "no-vault, my-own-wallet" trader.

**But the FundingVault changes the capital model.** The whole point of the vault
is a *sandbox*: a hard-capped war chest the desk can draw from but can never
drain past its caps, structurally separate from the operator's main wallet.
Capital lives in the vault, not a user wallet — so **something must receive the
drawn USDC, buy the token, hold it for the life of the position, and sell it.**
That something is the Rail, and it is **deliberately custodial** (of the position
token only). This does **not** violate AutoTarget's non-custodial invariant —
AutoTarget stays balance-zero; the Rail is a *separate* contract whose custody is
bounded by the vault caps + the exit rule.

**So the two models are siblings, not rivals:**
- **Vault model (this spec):** FundingVault → Rail (buys/holds/sells) → back to vault. Capital capped by the vault; token isolated in the Rail.
- **Spend-permission model (AutoTarget §3):** user wallet → keeper swaps via SpendPermissionManager. No Rail. For solo users trading their own wallet.

This spec builds the **vault model** — the one the console desk already drives via
`drawForTrade`.

---

## 2. The load-bearing decision — role assignment (flag for Architect)

The exits must be **fully mechanical** (AutoTarget §3, ratified: "the only way to
win these trades is by being quick"). A mechanical exit means **no per-trade human
signature**. In the vault model, `drawForTrade` AND `returnProceeds` are both
`onlyTrader`. Therefore:

> **`FundingVault.trader` == `FundingVault.tradeDestination` == the PossessioRail
> contract.** The human is the vault **owner** (funds / withdraws / pauses / caps)
> and the intent **author** (AutoTarget `openIntent` + fee). The **Keeper** drives
> the Rail; the **Rail** is the only thing that calls `drawForTrade` /
> `returnProceeds`.

Why this is the safe assignment:
- The Rail can only draw **within the vault's caps** (per-trade / outstanding /
  daily) — a rogue keeper cannot exceed them.
- The Rail can only **sell** an open position when **AutoTarget has authorized the
  exit** (`ExitAuthorized`) — the keeper cannot dump a position for no reason.
- The Rail's swap **proceeds are hardcoded to `returnProceeds`** — they can only
  go home to the vault, never to the keeper or anyone else.
- The human never signs an exit; they authorize the *intent* once (open + fee),
  and the vault caps + the −10% stop bound the whole blast radius.

The human's `drawForTrade` from the desk (built this branch) is the **solo-operator
shortcut** — valid when the operator IS the trader/keeper. The **productized**
flow is `openIntent` (human) → Keeper drives the Rail. Both are supported; the
desk copy must say which mode a given deployment is in.

---

## 3. PossessioRail — contract surface

**Immutables:**
- `usdc` (the vault's payToken, 6-dec)
- `vault` (PossessioFundingVault — the Rail is its `trader` and `tradeDestination`)
- `autoTarget` (PossessioAutoTarget — the exit-authorization authority)
- `keeper` (bounded trigger; compute-only, like the salt keeper / AutoTarget keeper)
- `dexRouter` (Base DEX — Uniswap V3 SwapRouter02 / Aerodrome; the same venue
  Payments already uses, so the slippage-floor machinery is reused)
- `SLIPPAGE_FLOOR_BPS` (oracle/quote-derived min-out floor, mirrors Payments
  `SWEEP_SLIPPAGE_BPS` — the caller may tighten, never loosen below it)

**Position record** (per intentId, single id shared with vault + AutoTarget):
`Position{ address token; uint256 usdcIn; uint256 tokenAmount; Status status }`,
`Status: None → Open → Closed`.

**Keeper-driven writes:**
- `enter(uint256 intentId, address token, uint256 minTokenOut)` — `onlyKeeper`
  1. bind to the authored intent: read AutoTarget `getIntent(intentId)`; require it
     is `Open`, its `chainTag == CHAIN_BASE (8453)`, and its `tokenRef` (bytes32)
     decodes to `token` — i.e. `address(uint160(uint256(tokenRef))) == token` (the
     human authorized *this* coin, on Base). (AutoTarget is chain-agnostic:
     `tokenRef` is a padded EVM address or a Solana mint; the Base Rail only ever
     serves `chainTag == 8453` intents, so a Solana-tagged intent is rejected here
     and handled by the Solana rail.)
  2. `amt = vault.getTrade(intentId).drawn` **must be 0** and `Position.status ==
     None` (fresh id); then `vault.drawForTrade(intentId, size)` pulls `size` USDC
     to the Rail. `size` = min(authorized size, vault caps) — see §7.1.
  3. swap `size` USDC → `token` on `dexRouter`, `minOut = max(minTokenOut,
     floor(size))`; record `Position{token, usdcIn:size, tokenAmount:received,
     Open}`; emit `Entered(intentId, token, size, received)`.
- `exit(uint256 intentId, uint256 minUsdcOut)` — `onlyKeeper`
  1. require `Position.status == Open`.
  2. **gate on the rule:** require AutoTarget intent `status == Resolved`
     (i.e. `ExitAuthorized` already emitted — target or −10% stop crossed). If not
     resolved, revert `ExitNotAuthorized`. *The keeper cannot sell on a whim.*
  3. swap `tokenAmount` `token` → USDC, `minOut = max(minUsdcOut, floor)`;
     `usdcOut = received`.
  4. `vault.returnProceeds(intentId, usdcOut)` — proceeds home to the vault
     (hardcoded; the Rail pre-approves the vault for `usdcOut`).
  5. set `Closed`; call `autoTarget.markExecuted(intentId, usdcOut)` (the on-chain
     receipt); emit `Exited(intentId, usdcOut, pnl = int(usdcOut) - int(usdcIn))`.

**Owner escape hatch (the un-removable exit, mirrors the FundingVault ethos):**
- `ownerExit(uint256 intentId, uint256 minUsdcOut)` — `onlyVaultOwner`
  - the operator can ALWAYS force-close an open position (sell → returnProceeds)
    without the keeper and without an AutoTarget resolution — the human's manual
    bail. Same swap→return path, no `ExitAuthorized` gate. (This is F2, the
    AutoTarget "forced-exit hatch" open item, realized here.)
- `sweep(address token)` — `onlyVaultOwner` — rescue a non-position token
  mistakenly sent to the Rail (never `usdc` mid-position, never an open
  position's token).

**Views:** `getPosition(intentId)`, `openTokenOf(intentId)`, `quoteExit(intentId)`
(off-chain min-out helper).

**Events:** `Entered`, `Exited`, `OwnerExited`, `Swept`.

---

## 4. The Keeper — behavioural contract (off-chain, bounded)

The Keeper is **our own infra** (like the salt keeper). It is **compute + trigger
only**; every fund movement it can cause is gated by the Rail + vault + AutoTarget.

**Lifecycle it drives, per intent:**
1. **See** `IntentOpened(id, user, token, entryPrice, targetBps)` (AutoTarget).
2. **Enter:** call `Rail.enter(id, token, minTokenOut)` with a fresh quote. (Draws
   from the vault, buys the token.) If the draw would breach a vault cap, it
   **does not enter** and surfaces the reason — the caps are hard.
3. **Watch:** poll price (radar tape / DEX quote) against `targetPrice(id)` and
   `stopPrice(id)` from AutoTarget.
4. **Resolve:** the instant price crosses, call `AutoTarget.resolveIntent(id,
   observedPrice)` — the authoritative on-chain trigger (`NotTriggered` price-gates
   a premature call). *This is "the quick."*
5. **Exit:** call `Rail.exit(id, minUsdcOut)` — sells, returns to vault, marks
   executed. `Rail.exit` re-checks the AutoTarget resolution on-chain, so even a
   buggy keeper cannot sell an unresolved position.

**Bounds (what a rogue/broken keeper can and cannot do):**
- **Cannot** over-draw: vault caps gate `drawForTrade`.
- **Cannot** sell for no reason: `Rail.exit` requires `ExitAuthorized`.
- **Cannot** redirect proceeds: `returnProceeds` is hardcoded to the vault.
- **Cannot** buy a coin the human didn't authorize: `enter` checks the intent's
  `token`.
- **Can** (residual power, §6.3 of AutoTarget) pick a bad slippage on the off-
  chain-quoted swap → bounded by `SLIPPAGE_FLOOR_BPS` on-chain and the vault caps;
  hardening (TWAP/multi-source min-out) is an open item, not v1.
- **Can** be slow / go down → the position sits Open; the **owner escape hatch**
  (`ownerExit`) means the human is never trapped by a dead keeper.

---

## 5. Invariants (structural, DoD-enforced)

1. **Proceeds only ever go home.** Every `exit` / `ownerExit` path ends in
   `vault.returnProceeds(intentId, …)`. The Rail has **no** function that sends
   USDC anywhere but the vault. (Mutation: redirect proceeds → test red.)
2. **No sell without authorization.** `exit` reverts `ExitNotAuthorized` unless the
   AutoTarget intent is `Resolved`. Only `ownerExit` (the human) bypasses it.
   (Mutation: drop the gate → adversarial test red.)
3. **Authorized coin only.** `enter` reverts unless the drawn position's `token`
   equals the human's authored intent `tokenRef` decoded on `chainTag == 8453` —
   the Rail can only buy the exact Base coin the human authored.
4. **Caps are the vault's, not the Rail's.** The Rail never re-implements a cap; it
   calls `drawForTrade`, which enforces per-trade / outstanding / daily. A draw
   over any cap reverts and no position opens.
5. **One position per intentId.** `enter` requires `Position.status == None` and a
   zero prior vault draw for that id; `Closed` is terminal. No double-buy, no
   re-enter.
6. **Slippage floor holds.** Both legs use `minOut = max(callerMin, floor)`; the
   keeper can tighten but never loosen below the oracle/quote-derived floor.
7. **Owner can always exit.** `ownerExit` works on any `Open` position regardless
   of keeper state or AutoTarget resolution — the human is never trapped.

---

## 6. Honest caveats (named, not hidden)

1. **The stop is a THRESHOLD, not a FILL** — inherited from AutoTarget §6.1, and
   here it is literally true: `exit` sells at market via the DEX, which on a real
   rug fills far worse than −10%. The Rail cuts decision lag; it cannot beat
   gapping liquidity. The desk already says so; the Rail's receipts (`Exited` pnl)
   prove the real fill.
2. **The custody window is real.** Between `enter` and `exit` the Rail *holds the
   position token*. That is unavoidable in the vault model (you buy now, sell
   later). It is bounded: the Rail can only ever sell-to-vault or be owner-exited,
   and holds nothing else. A Rail bug is the concentrated risk — hence the DoD
   fork test and the diverse-review gate before freeze.
3. **Keeper slippage residual** (AutoTarget §6.3) — the keeper chooses the off-
   chain quote/min-out within the floor. Our infra; TWAP/multi-source hardening is
   an open item.
4. **MEV on the swap.** Routing a thin micro-cap swap on-chain exposes it to
   sandwiching. Mitigations: the slippage floor caps the damage; private-mempool
   / aggregator routing for the swap leg is a keeper-config open item. (This is the
   surface AutoTarget's spend-permission model avoided by keeping the swap in the
   user's wallet — the vault model re-accepts it in exchange for the sandbox.)

---

## 7. Open decisions (Architect ratifies; NOT frozen here)

1. **Size authorization.** v1: the human's size is an off-chain instruction to the
   keeper; the on-chain hard bound is the vault caps. Hardening: add `maxSize` to
   the AutoTarget intent so the authored size is on-chain and `enter` checks it.
2. **DEX venue per chain.** Uniswap V3 vs Aerodrome for the USDC↔token legs;
   reuse Payments' venue + slippage-floor code. Config, not a freeze.
3. **Rail per-desk vs shared.** One Rail per FundingVault (isolation, recommended)
   vs a shared Rail keyed by (vault, intent). Recommend **per-desk** — the Rail is
   the trader/tradeDestination of exactly one vault, so isolation is natural and
   the blast radius is one operator.
4. **Partial exits / scale-outs** — v1 is single buy, single full sell (matches
   AutoTarget §7.6). Scale-outs later.
5. **Robinhood Chain** joins the EVM rail iff CreateX + a DEX are live there
   (same gate as AutoTarget §7.5).
6. **Fee.** The per-tx fee lives in AutoTarget (`openIntent`), not the Rail — the
   Rail moves no fee. Confirm the Rail adds no second fee (it should not).

---

## 8. Definition of Done (the suites this spec authorizes)

- **`PossessioRail.t.sol`** (DoD) — enter draws within caps + buys (mock DEX,
  `tokenAmount` recorded); exit gated on AutoTarget `Resolved` (reverts
  `ExitNotAuthorized` when Open-only); exit sells + `returnProceeds` credits the
  vault + `markExecuted` fires; pnl event correct on profit AND loss; one-position-
  per-id; `Closed` terminal; `ownerExit` closes without a resolution.
- **`PossessioRailAdversarial.t.sol`** — non-keeper enter/exit; non-owner
  ownerExit/sweep; sell an unresolved position (blocked); buy a coin ≠ the intent's
  token (blocked); double-enter / re-enter after close (blocked); proceeds cannot
  be redirected off the vault; draw over each vault cap reverts and opens no
  position; slippage floor cannot be loosened; a dead keeper leaves the owner able
  to `ownerExit`.
- **`PossessioRailFork.t.sol`** — Base fork, REAL USDC + a real DEX: fund a real
  FundingVault → `enter` (draw + real swap USDC→token) → `resolveIntent` (target &
  stop cases) → `exit` (real swap token→USDC) → `returnProceeds` credits the real
  vault → `balanceOf(rail)` returns to 0 for that position. Proves the full
  money-path against real venues, not mocks. Both never-regress invariants
  (proceeds-only-home §5.1, no-sell-without-authorization §5.2) mutation-verified.

---

*Draft for ratification. The −10% stop stays un-removable (AutoTarget), proceeds
stay hardcoded home (Rail §5.1), and the owner can always bail (Rail §5.7) — those
three, plus the vault caps, are the whole safety story. The custody window (§6.2)
is the one new risk the vault model accepts in exchange for the sandbox; the
diverse-review gate owns that call before any freeze.*
