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

## 3. THE LOAD-BEARING DECISION — capital-flow custody

**Where does drawn capital go, and who holds the token mid-trade?** Flagged for
the Architect; it shapes the whole contract.

- **(A) Vault → owner's wallet → trade → vault. [RECOMMENDED]**
  `drawForTrade` sends USDC to a single immutable `tradeDestination` = the
  operator's **own Base Account**. The trade executes there (via the desk's
  existing spend-permission / xtrade rail); proceeds return via `returnProceeds`.
  The vault is a **cap-enforcing allocator** — funds only ever sit in the vault
  or the operator's own wallet. Maximum sovereignty; no third party ever
  custodies. Matches *"keeps the sovereignty of the whole situation."*
- **(B) Vault → keeper → swap → vault.** The keeper receives USDC, swaps, and
  the token is transiently keeper-held. More automated, but a third party
  touches funds mid-trade — weaker sovereignty, larger trust surface.

**Recommendation: (A).** The vault caps *exposure*; the operator's wallet +
the desk's bounded rail do the *execution*. The token-custody question stays
where AutoTarget already answered it (bounded Base-Account spend permission),
and the vault never needs to know about tokens at all — it only meters USDC in
and out. Clean separation: **desk = trigger, vault = capital+caps, wallet =
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
- On entry, the keeper calls `vault.drawForTrade(intentId, entryUSDC)` — capital
  flows to the operator's wallet, bounded by caps. If a cap is hit, **the trade
  simply doesn't open** (honest refusal, like `PoolEmpty()` — never a degraded
  path). This is also the **buy pre-flight** the metered-feed council statement
  asked for: no capital, no position.
- On exit (`ExitAuthorized` → swap → `markExecuted`), the keeper calls
  `vault.returnProceeds(intentId, proceedsUSDC)` — closes the exposure and books
  P&L. The vault's `TradeClosed` + the desk's `ExitExecuted` are the two halves
  of the on-chain receipt.

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
