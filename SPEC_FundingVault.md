# SPEC — PossessioFundingVault (the trader's hard-capped, sovereign capital source)

**Type:** Build spec (draft → Architect ratify → build → adversary + fork test)
**Date:** 2026-07-20 · **Seat:** Code Integrity (repo council seat)
**Status:** NON-PROVEN until `forge` is green. Authorizes the contract +
DoD/adversarial/fork suites.

---

## 0. Why this exists — and why the trader cannot deploy without it

A sovereign trader with access to the operator's **whole wallet** is a wallet
one bug or one bad tick away from zero. The FundingVault is the risk boundary
that makes the trader **safe to launch**: the operator funds a vault they own;
the desk draws trading capital from it **only within immutable hard caps**; and
**the operator can always withdraw.** Every dollar the trader can ever touch is
bounded, on-chain, and auditable.

> **The trader deploys as a bundle: AutoTarget desk + FundingVault.** The desk
> decides and triggers; the vault sources and bounds the capital. Neither ships
> alone — the desk without the vault has no bounded capital; the vault without
> the desk has nothing to fund. Dual-launch, same anchor derivation.

This is the on-chain expression of the operator's sovereignty: **your capital,
your caps, your withdraw key** — not a custodian, not an unbounded bot.

---

## 1. Roles (two, immutable — no admin sprawl)

| role | who | powers |
|---|---|---|
| **owner** | the operator's **passkey Base Account** (never a hot EOA) | `fund`, `withdraw` (to self only), `pause` |
| **trader** | the desk + keeper (bounded spender) | `drawForTrade`, `returnProceeds` — capped |

No third role, no upgrade, no arbitrary-recipient path. The owner is sovereign;
the trader is bounded.

---

## 2. Hard caps (immutable at construction — the safety, structural)

Three caps, each a constructor immutable. A draw must satisfy **all three**:

1. **`MAX_PER_TRADE`** — the most USDC a single `drawForTrade` can pull.
2. **`MAX_OUTSTANDING`** — the most USDC that can be *out in open trades at
   once* (`outstanding = Σdrawn − Σreturned`). Caps concurrent exposure.
3. **`DAILY_DRAW_CAP`** — rolling 24h window (reuse `PossessioPayments`' proven
   window machinery: `WINDOW_SIZE = 24h`, `dailyDrawn` reset per window).

The vault balance is itself the absolute ceiling — you cannot draw what isn't
there. The caps bound *rate* and *concurrency* on top of that.

**Cap adjustment is asymmetric (Payments C-2 pattern):** the owner may
**lower** a cap instantly (tighten risk now) but **raising** one is delayed
behind `LIMIT_DELAY = 24h` — a compromised owner key cannot instantly widen the
blast radius.

---

## 3. CAPITAL FLOW — the closed-loop sandbox (RESOLVED by the Architect)

**The trader is a sandbox, not a wallet-spender.** The Architect's ruling
supersedes the earlier A/B options with a stricter, safer model:

> The **trader is hardcoded to the FundingVault as its ONLY source of funds** —
> it can never reach the operator's main wallet. The user sends capital **to the
> vault**; `drawForTrade` releases it (within caps) to the execution rail; on
> sell, proceeds route **back to the vault**. Closed loop. The operator's main
> wallet only ever touches `fund()` (deposit) and `withdraw()` (harvest).

Why this is strictly safer than "vault → owner wallet": the trader's entire
reachable surface is the vault's balance. Worst case is bounded to *what's in
the vault* — the main wallet is **never exposed to the trader at all.** The
`trader` address is an **immutable** in the vault; there is no setter.

**Residual detail (keeper/rail, not the vault):** between buy and sell the token
is transiently held by the execution rail (the desk's bounded spend permission /
Jupiter delegate) — same custody AutoTarget already bounds. The vault only ever
meters **USDC out (draw) and USDC in (return)**; it never touches the token.
Clean separation: **desk = trigger, vault = capital+caps (closed loop), rail =
execution.**

---

## 4. Contract surface — `PossessioFundingVault`

**Immutables:** `payToken` (USDC), `owner`, `trader`, `tradeDestination`
(= owner's Base Account under Option A), `MAX_PER_TRADE`, `MAX_OUTSTANDING`,
`DAILY_DRAW_CAP` (initial; adjustable per §2).

**Owner (sovereign):**
- `fund(uint256 amount)` — pull USDC in (owner must approve). Anyone *may* fund
  (top-ups are harmless), but only the owner withdraws.
- `withdraw(uint256 amount)` — USDC out, **to the owner only** (hardcoded
  recipient). Available even while trades are outstanding (the operator can
  always reclaim idle capital); cannot pull below `outstanding` (that USDC is
  committed to open trades).
- `setCap(...)` — lower instantly, raise behind `LIMIT_DELAY`.
- `pause()` / `unpause()` — freezes `drawForTrade` (not `withdraw` — the owner
  can always exit).

**Trader (bounded):**
- `drawForTrade(uint256 intentId, uint256 amount)` — `onlyTrader`, not paused.
  Checks: `amount ≤ MAX_PER_TRADE`; `outstanding + amount ≤ MAX_OUTSTANDING`;
  `dailyDrawn + amount ≤ DAILY_DRAW_CAP` (rolling); `amount ≤ balance −
  outstanding`. Sends USDC to `tradeDestination`; `outstanding += amount`;
  records `drawn[intentId]`. Emits `TradeFunded(intentId, amount)`.
- `returnProceeds(uint256 intentId, uint256 amount)` — `onlyTrader`. Pulls
  `amount` USDC back (from `tradeDestination`, approved); `outstanding -=
  drawn[intentId]` (the *original draw* clears the exposure); records realized
  P&L = `amount − drawn[intentId]`. Emits `TradeClosed(intentId, drawn, amount,
  pnl)`. This is the receipt row the transactions page renders.

**Views:** `outstanding()`, `available()` (= balance − outstanding),
`drawableToday()`, `getTrade(intentId)`.

**Events (the receipt skeleton, per the transactions-page spec):**
`Funded`, `Withdrawn`, `TradeFunded`, `TradeClosed`, `CapChanged`, `Paused`.

---

## 5. Invariants (structural, DoD-enforced)

1. **Owner-always-can-exit.** `withdraw` to the owner is never blocked by pause
   or by the trader; only by `outstanding` (committed capital).
2. **Trader is bounded, always.** No `drawForTrade` can breach any of the three
   caps. Enforced at the call, not the UI.
3. **Non-custodial recipients are hardcoded.** `withdraw` → owner; `drawForTrade`
   → `tradeDestination`. No arbitrary-recipient path exists anywhere.
4. **Exposure accounting is exact.** `outstanding == Σdrawn(open) − Σreturned`;
   a trade clears exactly its original draw, never more or less.
5. **Asymmetric caps.** Lower instant, raise delayed — a compromised owner key
   cannot widen risk instantly.
6. **Reentrancy-safe, CEI.** Effects (outstanding, dailyDrawn) commit before the
   USDC interaction.
7. **No fund path feeds an exit.** Same valve discipline as the Heart/x402Core:
   nothing moves funds from the owner/trade side back into the trader's draw
   allowance except the accounted `returnProceeds`.

---

## 6. Interaction with AutoTarget (the bundle)

- `openIntent` on the desk records the pick + rule (unchanged).
- On entry, the keeper runs the **trade Pre-Flight Guard (§6a)**; only if it
  passes does it call `vault.drawForTrade(intentId, entryUSDC)` — capital
  released to the execution rail, bounded by caps. If a cap is hit **or PFG
  vetoes**, **the trade simply doesn't open** (honest refusal, like `PoolEmpty()`
  — never a degraded path). No capital + no clean pool state → no position.
- On exit (`ExitAuthorized` → swap → `markExecuted`), the keeper records the
  **exit-side PFG attestation (§6a)** and calls `vault.returnProceeds(intentId,
  proceedsUSDC)` — closes the exposure and books P&L. The vault's `TradeClosed`
  + the desk's `ExitExecuted` + the PFG attestation are the on-chain receipt.

## 6a. Trade Pre-Flight Guard (PFG) — the −82%-tail fix, per trade

Modeled on `script/sal_pfg` (the SAV Pre-Flight Guard's five gates), adapted to
a memecoin trade. The council's strat verdict named this exact remedy: *"a
post-entry rug re-check to cut the −82% tails without clipping the +75%
runners."* It runs keeper-side, reading live pool state (V4 Quoter/StateView on
EVM; curve reserves / DexPaprika on Solana).

- **BEFORE A BUY — veto.** Gates: sequencer/congestion; liquidity integrity
  (reserves + delta — a rug in progress); **Kinetic Depth Anchor** (simulate a
  dust swap; hollow/manipulated liquidity reveals itself — the key gate); price
  discovery (not buying the top of a spike). **Any veto → no `drawForTrade`.**
- **BEFORE A SELL — attest (veto only on a target-sell into a manipulated
  spike).** A stop always exits; the PFG *records why the fill was what it was*
  ("stop fired at −10%, KDA showed liquidity gone hollow → filled −60%").
- **Attestation format:** a compact gate-result summary (per-gate pass/warn/veto
  + the KDA quote + depth + price at that block/slot) carried into the trade
  receipt — hashed into `TradeFunded` / recorded at `markExecuted` — so the
  **transactions page renders `PFG buy ✓ 5/5` / `⚠ KDA veto` and the exit-side
  pool state per trade.** This is where *"did the keeper fire on the right tick,
  and was the fill honest"* becomes visible. Gets its own build spec
  (`SPEC_TradePreFlightGuard.md`); this section is the wiring contract.

The desk and vault are **separately deployed, jointly wired** (the desk knows
the vault; the vault's `trader` is the keeper). Dual-launch, same anchor.

---

## 7. Chain scope

- **EVM (Base) first** — this Solidity contract. Robinhood Chain later (same
  code) *iff* the desk's EVM exit rail is viable there (SpendPermissionManager —
  currently absent, tracked).
- **Solana sibling** — a separate SPL program with the identical shape (owner,
  bounded delegate, three caps, draw/return accounting). Not this contract; its
  own spec. The pump.fun edge lives on Solana, so the Solana vault is the one
  that funds the live edge — **flag: the Solana sibling is on the critical path,
  not a nice-to-have.**

---

## 7b. Console wiring (standing requirement — every contract, always)

The operator's flow is fixed: **open possessio.io in the wallet browser →
connect wallet → dual-launch → receive both addresses → the console connects
BOTH contracts at once.** Everything built must be console-wireable:

- **Multi-contract connect.** The desk + vault deploy as a bundle; the console
  connects both simultaneously (per-tab, addresses auto-registerable from the
  CREATE3 anchor). This is the console defect already logged — the top card must
  follow the selected contract, and multiple contracts hold at once.
- **The emergency breaker box.** Every owner-only safety control the vault
  exposes — `pause`/`unpause`, `setCap` (lower-instant / raise-delayed),
  `withdraw` — is surfaced in the console as a labelled control, in plain
  language ("Freeze trading", "Tighten daily cap", "Withdraw capital").
- **Changeable functions listed.** The console enumerates every mutable
  parameter (caps, pause state, pending delayed raises) with its live value and
  the control to change it — read + write, per the console's existing
  action-group pattern (Inflow Policy / Operations / Security).
- **Build with this in mind.** Each contract's ABI, its owner-only vs
  trader-only surface, and its events (the receipt skeleton) are what the
  console renders. Design the surface to be legible, not just correct.

## 8. Open decisions (Architect gates — not guessed here)

1. **§3 custody model** — A (recommended) vs B.
2. **Cap values** — `MAX_PER_TRADE`, `MAX_OUTSTANDING`, `DAILY_DRAW_CAP`. Immutable
   floors/initials; size from the strat's real position sizing (the forward
   ledger's $3.5k entries suggest small per-trade caps to start).
3. **Idle-capital yield** — does un-drawn USDC sit flat, or route to a yield
   venue (Payments' cbETH/Morpho legs)? Adds surface; recommend **flat v1**.
4. **P&L accrual** — does realized P&L stay in the vault (compounding the war
   chest) or sweep to a treasury? Recommend **stays in vault** (self-growing
   sovereign capital) with an owner `withdraw` to harvest.
5. **Guardian pause** — add the optional `GUARDIAN_ROLE` (pause-only) like
   Payments, or owner-only pause? Recommend owner-only v1 (less surface).

---

## 9. Definition of Done (suites this spec authorizes)

- **`PossessioFundingVault.t.sol`** (DoD) — fund/withdraw; drawForTrade respects
  all three caps; returnProceeds clears exact exposure + books P&L; owner can
  withdraw with trades outstanding down to `outstanding`; pause blocks draws not
  withdraws; views correct.
- **`PossessioFundingVaultAdversarial.t.sol`** (gauntlet) — non-owner withdraw;
  non-trader draw; per-trade / outstanding / daily cap breaches each refused;
  withdraw-below-outstanding refused; arbitrary-recipient impossible; instant
  cap-raise refused (delay enforced); reentrancy on draw/return; double-return /
  return-unknown-intent; drain-attempt via cap edges.
- **`PossessioFundingVaultFork.t.sol`** — real Base USDC: fund → drawForTrade →
  returnProceeds round-trip with realized P&L, exposure accounting exact against
  the live token.

**Nothing funds a live trade until the adversarial suite is green and the cap
values are calibrated (§8.2).**

---

*Draft for ratification. The two invariants that must never regress:
owner-always-can-exit (§5.1) and trader-is-bounded (§5.2). Cold-seat re-audit
before the immutable freeze.*
