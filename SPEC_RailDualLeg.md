# SPEC — PossessioRail, dual-leg (one Rail, one trader, both chains)

**Status:** PROPOSED. Not built. Supersedes nothing — extends
[`SPEC_RailAndKeeper.md`](SPEC_RailAndKeeper.md) §3 with a second execution leg.
Architect directive 2026-07-30: *"we need both rails in one. both traders in one."*

---

## 0. The one sentence

One `PossessioRail` is the vault's single immutable `trader` for **both** chains:
it executes Base picks atomically through a DEX router exactly as it does today,
and executes Solana picks as a **draw → pending → settle** cycle measured in USDC,
so the vault's caps, its `outstanding` ledger and its one-trader wiring are
unchanged.

---

## 1. Why this is an extension and not a rewrite

Three facts established by inspection and on-chain test on 2026-07-29/30. Each
one removes work that a naive design would have to do.

**1. The rule engine is already chain-agnostic.** `PossessioAutoTarget` declares
`CHAIN_BASE = 8453` **and** `CHAIN_SOLANA = 101`, `openIntent` accepts any
non-zero `chainTag`, and the contract states it *does not interpret* `tokenRef`
(a padded EVM address or a Solana mint). A Solana pick can already be authored,
targeted, stopped and resolved. **No AutoTarget change.**

**2. The vault is already chain-agnostic.** Its only two trader doors are
USDC-denominated:

| Door | Gate | Effect |
|---|---|---|
| `drawForTrade(intentId, amount)` | `onlyTrader` | USDC out, bounded by `maxPerTrade` / `maxOutstanding` / `dailyDrawCap` |
| `returnProceeds(intentId, amount)` | `onlyTrader` | USDC in, `outstanding -= drawn` |

The vault tracks a **USDC debt against an intent id**. It holds no opinion about
what happened in between, and it never needs to hold SOL, an SPL token, or any
position asset. **No vault change.**

**3. USDC is the common denominator on both chains, and the exit to it is free.**
Measured in-wallet by the Architect, same input of 52,601 units of a Solana
memecoin, two exits, both at $0.00 wallet fee: **0.820702 USDC** ($0.82) versus
0.010474 SOL ($0.77). The USDC exit was worth *more* than the SOL exit. So a
Solana leg can begin and end in the vault's own unit of account.

**Therefore the entire Base-specificity of the desk is one line** —
`PossessioRail.sol:152`, `if (chainTag != CHAIN_BASE) revert WrongChain();`.

---

## 2. Contract surface — what is added

Existing surface is unchanged. `enter` gains a branch; three functions are new.

```
enter(intentId, token, size, minTokenOut, poolFee)      // UNCHANGED for 8453
exit(intentId, minUsdcOut, poolFee)                     // UNCHANGED for 8453
ownerExit(intentId, minUsdcOut, poolFee)                // UNCHANGED for 8453

openRemoteLeg(intentId, uint256 size)                   // NEW  — chainTag 101
settleRemoteLeg(intentId)                               // NEW  — measured, not reported
abandonRemoteLeg(intentId)                              // NEW  — owner-only stuck-leg exit
```

### `openRemoteLeg(intentId, size)` — `onlyKeeper`

1. Read the intent. Require `status == Open` and `chainTag == CHAIN_SOLANA`.
   Require `Position.status == None` for this id.
2. `vault.drawForTrade(intentId, size)` — the caps gate here, exactly as on Base.
3. Record `Position{ status: Pending, usdcIn: size, token: address(0),
   openedAt: block.timestamp }`.
4. Transfer the drawn USDC to the immutable `remoteAgent` address.
5. Emit `RemoteLegOpened(intentId, size, remoteAgent)`.

The Rail does **not** bridge, route, or choose a venue. It draws under cap and
hands off to one immutable address. Everything beyond that is off-chain and
explicitly outside the trust boundary (§5.2).

### `settleRemoteLeg(intentId)` — `onlyKeeper`

**Takes no amount.** The returned figure is *measured*, never reported:

1. Require `Position.status == Pending`.
2. `uint256 got = usdc.balanceOf(address(this)) - openBalanceSnapshot;`
3. Require `got > 0`, else revert `NothingReturned`.
4. `vault.returnProceeds(intentId, got)` — clears `outstanding -= usdcIn`.
5. Mark `Closed`, emit `RemoteLegSettled(intentId, usdcIn, got)`.

This is the load-bearing design rule of the whole spec. See §4.

### `abandonRemoteLeg(intentId)` — `onlyOwner`

For a leg that never comes home. Marks the position `Abandoned` and calls
`vault.returnProceeds(intentId, 0)` so `outstanding` is released and the desk is
not permanently throttled by one lost leg. It does **not** conjure USDC — the
loss is real and the event records it. Requires
`block.timestamp > openedAt + REMOTE_LEG_TIMEOUT` (immutable, proposed 24h) so
it cannot be used to paper over a leg still in flight.

---

## 3. What the keeper does, and does not, get to decide

| Decision | Who |
|---|---|
| Which coin, target, stop | The human, via `openIntent` |
| Whether an exit is authorized | `AutoTarget.resolveIntent` — rule, not keeper |
| Size of a draw | Keeper proposes, **vault caps decide** |
| Route / venue on Solana | Keeper (outside the trust boundary) |
| How much came back | **Nobody — it is measured** |
| Releasing a dead leg | Owner only, after timeout |

---

## 4. The one rule I would not trade away

**`settleRemoteLeg` must measure the Rail's own USDC balance delta. It must never
accept the returned amount as a parameter.**

A reported amount is a trusted number, and today's bug was precisely a guard that
checked a *claim* rather than the *property*: V1's constructor probed
`isInfraSink()` ("is my sink a live Heart") and passed, while the load-bearing
property was `isAuthorizedSource(address(this))` ("will that Heart accept me").
Every `openIntent` then reverted at a permanent address.

Measuring is also the established pattern in this codebase: `FundingVault.available()`
reads raw `balanceOf` rather than a tracked figure, which is why it is the one
contract where mis-sent USDC is recoverable (Gauge, ledger row 64).

**Measure, don't trust.**

---

## 5. Invariants (DoD-enforced)

Inherits all seven of `SPEC_RailAndKeeper.md` §5. Adds:

8. **One trader, one vault, both chains.** There is exactly one `Rail`, it is the
   vault's immutable `trader` and `tradeDestination`, and both legs settle through
   `vault.returnProceeds`. No second vault, no second trader.
   (Mutation: add a second settlement recipient → test red.)
9. **A remote leg cannot skip the caps.** `openRemoteLeg` draws only via
   `drawForTrade`; it never moves vault USDC by any other path.
   (Mutation: transfer direct from vault → test red.)
10. **Settlement is measured.** `settleRemoteLeg` has no amount parameter and
    derives `got` from a balance delta. (Mutation: add an amount param and trust
    it → adversarial test red.)
11. **Leg mode is decided by the authored intent, never by the caller.** `enter`
    reverts on `chainTag != 8453`; `openRemoteLeg` reverts on
    `chainTag != 101`. The keeper cannot route a Base pick through the remote
    path or vice-versa.
12. **A stuck leg throttles but does not brick.** `outstanding` stays charged
    until settle or owner-abandon-after-timeout, so losses self-limit; and the
    owner can always release.

---

## 6. Honest caveats (named, not hidden)

1. **The Solana leg has a custody window; the Base leg does not.** Base `enter` is
   draw → swap → hold inside one transaction — there is no moment where value is
   unaccounted. A remote leg hands USDC to `remoteAgent` and waits. This is the
   real cost of dual-leg and it must be stated plainly wherever the desk is
   described. It is bounded three ways: `maxPerTrade` limits one leg,
   `maxOutstanding` limits total exposure, and `outstanding` starves the next
   draw while a leg is unsettled.
2. **`remoteAgent` is a trusted address.** Between draw and settle it can lose or
   steal the drawn USDC, capped at `maxOutstanding`. No on-chain construct in this
   spec prevents that; the caps bound it and the events record it. Making
   `remoteAgent` a Solana-side program with its own proofs is future work, not
   this spec.
3. **No cross-chain proof.** The Rail learns nothing about what happened on
   Solana. It observes only that USDC returned. A leg could return the drawn
   amount having never traded, and the Rail would settle it as a flat trade. The
   AutoTarget's target/stop therefore governs *authorization to exit*, not proof
   of fill, on the remote leg.
4. **Base-leg caveats all still apply** — threshold-not-fill stops, keeper
   slippage residual, MEV on the swap (`SPEC_RailAndKeeper.md` §6).

---

## 7. Open decisions (Architect ratifies; NOT frozen here)

1. **`remoteAgent`: immutable or owner-settable?** Immutable matches every other
   money path in this protocol and is my recommendation. Settable would ease
   rotation but adds an admin lever on the money path.
2. **`REMOTE_LEG_TIMEOUT`** — proposed 24h. Long enough that a slow bridge never
   trips it, short enough that a dead leg is not a permanent cap charge.
3. **Does `exit`/`resolveIntent` order matter on the remote leg?** On Base, exit
   requires `Resolved`. Proposed: the same gate applies, so `settleRemoteLeg`
   requires the intent `Resolved` too — the rule still authorizes the close.
   Alternative: allow settle at any time since the sell already happened
   off-chain. **Architect's call; it changes what the stop means remotely.**
4. **Redeploy scope.** `Rail.autoTarget` and `Vault.trader` are immutable, so
   shipping this means a new Rail, hence a new Vault, hence a fresh CREATE3 salt
   (the row-63 salt is spent). Same three-contract set as the V2 unbrick — so
   **this should land in the same redeploy, not a second one.**

---

## 8. Definition of Done

Unit + adversarial + fork, mirroring the existing desk suites.

- `openRemoteLeg` draws exactly once, under cap, and charges `outstanding`
- a draw over `maxPerTrade` / `maxOutstanding` / `dailyDrawCap` reverts, no position
- `chainTag` cross-routing reverts both directions (inv. 11)
- `settleRemoteLeg` with zero delta reverts `NothingReturned`
- settle returns the **measured** delta, not a claimed one — proven by sending a
  different amount than expected and asserting the vault credited the measurement
- `abandonRemoteLeg` before timeout reverts; after timeout releases `outstanding`
- a settled leg is terminal; double-settle reverts
- **FORK:** a real Base leg still round-trips against live state — the
  `DeskLiveVenueFork` SOL proof must stay green ($100 → 1.3487 SOL → home,
  0.35% round trip, measured 2026-07-30)
- **FORK:** a remote leg simulated with real Base USDC — draw, transfer to a mock
  agent, agent returns a differing amount, settle credits the measured figure

---

## 9. What this does not attempt

Cross-chain execution proofs, a Solana program, atomic cross-chain settlement, or
any change to `PossessioAutoTarget` or `PossessioFundingVault`. The claim of this
spec is narrow and testable: **one Rail, one trader, two legs, caps intact, and
the returned amount measured rather than believed.**
