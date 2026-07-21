# COUNCIL TEST REPORT — 2026-07-21

**Tree:** `claude/repo-audit-h9m2ev` @ `edec854` · **Toolchain:** forge 1.7.1
(solc 0.8.35, via_ir) · **Optimizer:** uniform `runs=200` (all contracts)
**For:** full council · **From:** Code Integrity seat
**Supersedes:** COUNCIL_TEST_REPORT_20260720.md (this cycle adds PossessioFundingVault)

---

## 0. Headline

```
forge test  =>  936 passed · 0 failed · 8 skipped   (944 total, 49 suites)
new build   =>  PossessioFundingVault  +47 tests (21 DoD + 26 gauntlet) + 1 fork skip
fork (live) =>  FundingVault 4/4 on Base mainnet, REAL USDC round-trip
EIP-170     =>  every contract fits at runs=200 (hook tightest, +409; vault 4,261 B)
invariants  =>  both never-regress guards mutation-verified (owner-exit, trader-bound)
```

Delta from the 07-20 cycle: `889 → 936` passed (**+47** FundingVault tests),
`7 → 8` skipped (**+1**: the new FundingVault fork suite, which SKIPS offline and
**runs + passes live** — FIX B discipline, never a vacuous pass). The prior 7
fork/mock-gated skips are unchanged and enumerated in the 07-20 report §4.

---

## 1. What changed this cycle — PossessioFundingVault

The trader's hard-capped, closed-loop, sovereign capital source
(`SPEC_FundingVault.md`). Two immutable roles (owner: fund/withdraw-to-self/pause;
trader: drawForTrade/returnProceeds), three hard caps (per-trade, concurrent
outstanding, rolling-24h daily), asymmetric cap adjustment (lower instant / raise
+24h — the audited Payments C-2 pattern), closed-loop custody, reentrancy-safe CEI.

| suite | file | result |
|---|---|---|
| DoD | `PossessioFundingVault.t.sol` | **21 / 0 / 0** |
| Adversarial gauntlet | `PossessioFundingVaultAdversarial.t.sol` | **26 / 0 / 0** |
| Fork (real Base USDC) | `PossessioFundingVaultFork.t.sol` | offline **1 skip** · **LIVE 4/4** |

**Gauntlet coverage (26):** role boundaries (owner/trader/outsider each refused
the other's surface); every cap breach refused (per-trade, outstanding,
daily-window); idle-balance ceiling; asymmetric timelock (raise-not-instant,
before-delay refused, decrease-must-be-lower, queue-must-be-higher,
execute-without-queue); trade-lifecycle abuse (double-return, unknown-intent,
reuse-open-id, reuse-closed-id); reentrancy on draw AND withdraw (malicious
payToken re-enters → ReentrancyGuard trips); no-arbitrary-recipient (draws land
ONLY at tradeDestination, withdraws ONLY at owner, regardless of caller);
compromised-trader drain drill (bounded by outstanding cap regardless of balance).

---

## 2. Mutation verification (guards proven load-bearing, not decorative)

| invariant | mutation applied | result | restored |
|---|---|---|---|
| §5.2 trader-is-bounded | neutralize the `maxOutstanding` check (`if (false && …)`) | `test_outstandingCap_breachRefused` + `test_compromisedTrader_boundedByCaps` → **RED** ("did not revert") | ✅ green |
| §5.1 owner-always-can-exit | gate `withdraw` on `paused` | `test_withdraw_worksWhilePaused` → **RED** (`IsPaused()`) | ✅ green |

Both guards flip their tests red when broken and green when restored — they are
carrying real weight.

---

## 3. Spec ↔ build reconciliation (ONE finding — flagged for explicit council review)

The spec wrote `available = balance − outstanding`. That **double-counts** under
the ratified physical-transfer custody model: `drawForTrade` sends USDC OUT to
`tradeDestination`, so the vault's token balance *already* nets out at-rail
(outstanding) capital. Example: fund 10k, draw 3k → `balanceOf(vault)` is 7k and
`outstanding` is 3k; the spec's formula reports 4k idle and would **trap 3k of the
owner's idle capital**, violating §5.1 (owner-always-can-exit).

**Built as `available() = balanceOf(vault)`** (idle capital physically held); the
at-rail capital is inherently un-withdrawable until `returnProceeds` brings it
home, which *is* the "bounded only by outstanding" intent. `withdraw` and the draw
idle-ceiling both bind on `available()`. Recorded in `SPEC_FundingVault.md §4`
(BUILD NOTE). **This is the one substantive deviation; the council should vote it,
not rubber-stamp it.**

Two adjacent design confirmations also wanted (built per spec, but sharp edges):
`returnProceeds` clears the original `drawn` not the returned `amount` (a rug
returning 0 still clears exposure cleanly; no cap gates a return); and the
draw→return custody window leaves USDC at `tradeDestination`, pulled back via
`transferFrom` under the rail's own approval — caps bound the *exposure*, not the
rail's honesty.

---

## 4. Size / EIP-170 (uniform runs=200) — this tree, measured

Every contract fits the 24,576-byte ceiling at the deploy profile:

```
PossessioHook ............. 24,167 B  (+409)     <- tightest; full invent edit fits
PLATE ..................... 20,516 B  (+4,060)
PossessioPayments ......... 19,445 B  (+5,131)
PossessioFundingVault .....  4,261 B  (+20,315)  <- NEW this cycle
ServiceAccountabilityVault   5,118 B  (+19,458)
```

The uniform-200 decision is defended in full, with measured runtime-gas cost and
the two hard constraints (hook +3,571 OVER ceiling at runs=10000; forge rejects
mixed per-contract runs), in `COUNCIL_STATEMENT_optimizer_200.md`. Summary: the
runtime cost of 200 vs 10000 on the Payments settlement hot path is **+1,010 gas
on a ~347k sweep (+0.29%)**; the deploy-side saving is **~9% per customer launch**.

---

## 5. Fork suite — the FundingVault skip runs + passes LIVE

```
PossessioFundingVaultForkTest ... offline 1 skip (no RPC) | LIVE 4/4 on Base mainnet
  test_fork_fund_credits_realUSDC ............ real USDC (FiatTokenProxy) deposit
  test_fork_roundTrip_profit_exactAccounting . draw 3k → rail → return 3.6k, +600 to war chest, owner harvests all idle
  test_fork_roundTrip_loss_exactAccounting ... return 2k on a 3k draw, exposure still cleared exactly, net −1k
  test_fork_dealCompatibleWithRealUSDC ....... deal() writes the real proxy balance slot (the cheat the above rest on)
```

Ran against `https://mainnet.base.org`; 4/4 pass. This certifies the full
fund → draw → return round-trip and exact-exposure accounting hold against the
**real** live token, not a mock.

---

## 6. Standing caveats (on the record, not under it)

- **Nothing here is deployed.** Pre-freeze cycle; every immutable still changeable.
- **FundingVault cap values are NOT set.** `maxPerTrade / maxOutstanding /
  dailyDrawCap` are constructor immutables; tests use placeholder launch values
  ($3.5k / $10k / $20k). **No live funding until the council calibrates these**
  (SPEC_FundingVault §8.2) against the strat's real position sizing.
- **Codehash regen owed** (carried from 07-20): the uniform-200 change invalidates
  `deploy/optimizer_pool.json` init-codehashes; regen via `sync_optimizer_pool.sh`
  before the factory freezes template codehashes. Live standalone Payments
  (`0x1c0F…`, runs=10000) won't match a 200 rebuild — confirm acceptable.
- **The count is the terminal's.** `forge test` is the authority whenever this
  report and a fresh run disagree.

*This seat ran the numbers and reports them; it does not certify the money path.
The diverse council's own read — and the §3 reconciliation vote — remain the gate
before any immutable freeze.*
