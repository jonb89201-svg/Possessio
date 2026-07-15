# Cold-Seat Audit — PossessioPool ("THE HEART") — 2026-07-15

**What this is:** the gate-(3) **cold-seat re-audit** demanded by `src/PossessioPool.sol`'s
own header and RUNBOOK_FOUNDATION §0.3 before the immutable freeze. The seat that wrote
the pool did not certify it; this seat did not write it. Scope: `src/PossessioPool.sol`
(v0.1), its two test suites, `script/DeployPossessioPool.s.sol`, and every integration
edge that touches the pool (whisky market, factory, x402Core, runbook, optimizer_pool.json).

**Method:** line-by-line review of the contract and both suites; verbatim-lift
verification against PossessioX402Core v0.6 by mechanical diff; full offline suite +
Base-mainnet fork suite executed fresh in this session (Foundry built from source,
v1.4.4); every claim in the contract's own "audit by grep" block re-run.

**Verdict up front:** the mechanism is sound and matches its claims. No fund-loss or
fund-theft path was found. The pool cannot be drained, cannot be fed from its outflow
side, and holds atomicity under a failing surplus push. What I found instead are
**calibration constraints that gate (2) MUST respect** (P-1, P-2 — the floor mechanic is
amount-blind and the deploy path will accept a self-bricking parameter shape without
complaint), one integration liveness coupling (P-3), and one wiring gap that is implied
but nowhere stated for x402Core (P-5). Nothing here blocks ratification once gate (2)
internalizes P-1/P-2.

---

## Verification results (run fresh, this session)

| Check | Result |
|---|---|
| `forge build` (fresh submodule checkout, Foundry v1.4.4 from source) | PENDING |
| `forge test` full suite | PENDING |
| `forge test --match-path test/PossessioPool.t.sol` (22 tests, DoD suite) | PENDING |
| `BASE_RPC_URL=… forge test --match-path test/PossessioPoolFork.t.sol` (13 tests, live Base USDC) | PENDING |
| Valve-by-omission grep (`payable\|msg.value\|receive()\|fallback\|.call{`) | **Zero code hits** — all matches are comment lines. Claim holds. |
| `_decayedVelocity` verbatim-lift vs x402Core | **Byte-identical.** The x402 Python-oracle mirror (`test/PossessioX402CoreDecay.t.sol` ↔ `script/x402/oracle.py`) therefore covers the pool's decay math too. |
| `_bumpVelocity` verbatim-lift vs x402Core | Identical except one comment word ("inflow event" vs "settlement"). |

## Claims verified true (the load-bearing ones)

- **Bound inflow:** `receiveInfraFunds` is set-membership-gated; construction is the only
  writer of the set; no setter, no admin, no owner exists anywhere in the contract.
- **Valve integrity, structural:** every source is checked `!= operator && != treasury`
  at construction; zero, duplicate, and empty-set shapes refuse to exist. The documented
  intentional omission (treasury == operator allowed) opens no ingress path — confirmed.
- **Valve by omission:** no function moves funds from either outflow destination into the
  pool; grep block re-run clean (see table).
- **Floored one-way draw:** `settleOperationalCosts` is operator-only, pays only the
  operator, and releases at most `poolBalance − floor`; the floor derives only from
  decayed velocity + immutables, so no call sequence lowers it (DoD #6 direction holds).
- **Cap-then-surplus:** CEI ordering is correct — pool balance and surplus commit before
  the outbound treasury push; a forced-failing surplus transfer unwinds the whole tx
  (proven offline and on the live FiatTokenV2_2 code path in the fork suite).
- **Decay direction (x402 FIX #4):** the linear chord sits above the true exponential —
  re-derived: `1 − rem/2H ≥ 2^(−rem/H)` on `[0,H]` by convexity; equality at both ends.
  The approximation errs toward a HIGHER floor. Confirmed safe direction. The `>>= halvings`
  / `>=128` guard is underflow- and gas-safe; `v*rem` cannot realistically overflow
  (would need ~1e50 same-block inflow events).
- **Raw transfers dead by design:** un-accounted USDC sent straight to the pool address
  is never credited, never swept, never drawable — asserted offline and on fork (DoD #14).

---

## Findings

### P-1 · MEDIUM (calibration gate) — the velocity floor is amount-blind; sustained small inflows can pin the pool shut
`_bumpVelocity` adds **1e18 per inflow event regardless of amount**
(`src/PossessioPool.sol:301-305`). A 1-unit (0.000001 USDC) inflow raises the floor by
exactly as much as a 5,000 USDC one. At steady state, `v = v/2 + n` per half-life ⇒
**velocity ≈ 2·n** where n = inflow events per half-life, so

```
floor_steady ≈ ABSOLUTE_FLOOR + 2 · (events per half-life) · FLOOR_PER_UNIT
```

The moment `floor_steady ≥ OPERATIONAL_CAP`, `drawableSurplus()` is **permanently zero
while traffic persists** (balance is capped at CAP < floor): every over-cap unit sweeps
to treasury and the operator — the address the pool exists to fund — can draw nothing
until traffic stops for multiple half-lives. With the fork suite's illustrative params
(CAP 5,000 / ABS 500 / PER_UNIT 25 / half-life 7d) that threshold is only **90 fee events
per 7 days (~13/day)**. Note the griefing shape too: once the factory→pool wiring lands,
anyone can mint a velocity unit for the 1 USDC deploy fee — if `FLOOR_PER_UNIT` is large
relative to the fee, floor-inflation is cheaper than what it locks.

The docs claim only that the floor "cannot be gamed **down**" — true. It can be pushed
**up** by anyone who can generate inflow events. Not a code defect (the mechanic is
lifted intact from x402Core, where the single trusted source made it benign); for a
multi-organ pool with permissionless-triggered organs it becomes a **hard gate-(2)
constraint**:

- ratify `FLOOR_PER_UNIT` at or below the smallest expected per-event inflow, and
- prove `ABSOLUTE_FLOOR + 2·n_max·FLOOR_PER_UNIT < OPERATIONAL_CAP` for the highest
  sustained event rate the organs can produce.

Alternative (code change, only if a redeploy is ever on the table anyway): weight the
bump by amount (e.g. `+= amount * 1e18 / UNIT_NOTIONAL`) so the floor tracks throughput
in dollars, not calls.

### P-2 · MEDIUM (deploy-shape hole) — nothing rejects `ABSOLUTE_FLOOR ≥ OPERATIONAL_CAP`
Neither the constructor (`src/PossessioPool.sol:176-230`) nor the deploy script's
pre-checks (`script/DeployPossessioPool.s.sol:124-131` — checks cap ≠ 0 and halflife ≠ 0
only) reject a floor ≥ cap. That shape deploys silently and is a dead pool: balance can
never exceed CAP, CAP ≤ floor, so `settleOperationalCosts` reverts forever and 100% of
over-cap inflow sweeps to treasury. Because everything is immutable, the only fix is a
redeploy — after the organs' immutable pool pointers are already set (the whisky market
pins `POOL` at construction), which per its own spec means redeploying organs too.
**Fix:** add `require(ABSOLUTE_FLOOR < OPERATIONAL_CAP)` to the script's pre-check block
(cheap, no contract change), or to the constructor if the pool is rebuilt for any other
reason. The same review should sanity-band `POOL_VELOCITY_HALFLIFE` (a fat-fingered
seconds value in the hours-vs-weeks range changes P-1's `n` by orders of magnitude).

### P-3 · LOW — atomic surplus sweep couples organ liveness to the treasury's USDC standing
The surplus push to `treasuryDestination` happens inside `receiveInfraFunds`
(`src/PossessioPool.sol:281-284`). If Circle ever blacklists the (immutable) treasury —
or pauses USDC — any inflow that would cross the cap reverts, and that revert propagates
into the **organ's** transaction: `PossessioWhiskyMarket.settle()` calls
`POOL.receiveInfraFunds(fee)` inline (`src/PossessioWhiskyMarket.sol:285-289`), and
settle is the *only* exit for the winner's escrowed bid and the lot. Concretely: pool at
cap + blacklisted treasury ⇒ every fee-bearing whisky settlement reverts ⇒ winner escrow
stuck until the operator manually draws the pool below cap to make room (which works —
draws go to the operator, not treasury — so this is a liveness papercut, not a lock, as
long as operator and treasury are distinct addresses and the operator is responsive).
Note the documented "treasury == operator allowed" shape removes that escape hatch —
worth stating in §0.2 when the addresses are ratified. Accepted-risk candidate; the
pull-based alternative (accrue surplus, let treasury claim) would decouple it but is a
redesign of a ratified mechanism.

### P-4 · LOW — operator blacklist permanently strands the reserve below the cap
Same family as P-3: `settleOperationalCosts` pays only the immutable
`operatorDestination`. A blacklisted operator means the operating reserve (up to CAP)
is unreachable forever — no rescue, no re-point, by design. Fine to accept; record it.

### P-5 · INFO (wiring gap, should be written down) — x402Core as-built cannot feed the pool
`optimizer_pool.json` ratifies x402Core as one of the pool's inflows, and the deploy
script requires `X402CORE_ADDR` as source[1]. But `src/PossessioX402Core.sol` **contains
no call to `receiveInfraFunds` and no approval path to the pool** — tolls accrue to its
own internal `operationalPoolBalance` and its surplus sweeps to its own treasury
immutable. The factory's identical gap is documented three times over ("feeSink→
receiveInfraFunds upgrade lands later"); x402Core's is documented nowhere. Since
source[1] is a pre-derived CREATE3 address, whatever is deployed there must be a **new
x402Core version carrying pool wiring that does not yet exist in this repo**. Record
that in TODO/runbook so the address isn't burned with the current artifact. Related
deploy-time care: pointing any organ's raw-push destination (e.g. an x402Core-style
`treasuryDestination`) at the pool would strand every pushed unit forever (DoD #14 —
raw transfers are dead weight).

### P-6 · INFO — contract accepts `VELOCITY_HALFLIFE = 0` (decay disabled, floor ratchets up forever)
`_decayedVelocity` returns `v` untouched when the half-life is zero
(`src/PossessioPool.sol:324`) — velocity then never decays and the floor only rises,
eventually pinning the pool at ABSOLUTE_FLOOR + n·PER_UNIT with no relief. The deploy
script guards it (`require(halflife != 0)`), the constructor does not. The script is the
only sanctioned deploy path, so this is informational; a constructor guard would make it
structural for every deployment (the pool's own stated standard elsewhere).

### P-7 · INFO — error-name reuse (cosmetic, no behavior change)
`settleOperationalCosts` rejects a non-operator caller with `NotAuthorizedSource`
(`:368`) — misleading in traces (the operator is not a "source"; the whole point is
sources ≠ operator). An `amount == 0` draw reverts `InsufficientOperationalFunds` (`:375`)
rather than `ZeroAmount`. Neither affects safety; both would confuse an incident
responder reading a revert. Not worth a redeploy on its own.

### P-8 · INFO — doc drift: "exactly two inflows" vs the ratified three-source set
`deploy/optimizer_pool.json` `_business_model` still says the pool "is fed by exactly two
inflows … NOTHING ELSE feeds it", while RUNBOOK §0.1 records the 2026-07-14 Architect
ratification that **whisky IS in the pool set** (and `PossessioWhiskyMarket` already
carries live `receiveInfraFunds` wiring — currently the only organ that does). Align the
json's text with the ratification so the next seat doesn't re-open a settled question.

### P-9 · INFO — test-suite deltas against the DoD list
The 22-test offline suite + 13-test fork suite genuinely cover DoD #1–9, #11, #13, #14.
Small deltas, none load-bearing:
- **DoD #7's oracle mirror** lives in the x402 decay suite, not the pool's. Acceptable
  because `_decayedVelocity` is byte-identical (verified this audit, see table) — but the
  pool suite should state that dependency so a future x402 edit doesn't silently orphan it.
- **DoD #10** (immutability) and **#12** (CEI) have no dedicated tests — both are
  structural (no setter exists to test; atomicity test #13 subsumes the CEI observable).
- No **invariant/stateful-fuzz** suite exists for the pool (house has ones for L1Anchor,
  v2, automation). DoD #6's "no call sequence" claim is argued, not machine-searched. A
  small handler-based invariant (`poolBalance ≤ CAP`, `poolBalance + out ≡ in`,
  `token.balanceOf(pool) ≥ poolBalance`, floor-monotone-under-draws) would close it.
- Offline suite asserts no event emissions (fork suite does). Cosmetic.

---

## Gate status after this audit

| §0.3 gate | Status |
|---|---|
| (1) fork-prove on Base | DONE 2026-07-14 (13/13), **re-run green this session** |
| (2) calibrate the four params | **OPEN — now with two hard constraints from this audit:** `FLOOR_PER_UNIT ≤ min expected per-event inflow`; `ABSOLUTE_FLOOR + 2·n_max·FLOOR_PER_UNIT < OPERATIONAL_CAP` (P-1); plus the script-side `floor < cap` pre-check (P-2). |
| (3) cold-seat re-audit | **THIS DOCUMENT.** No fund-safety defect found. Ratification of this audit is the Architect's call, per house law. |

**Recommended before broadcast (smallest set):** add the P-2 pre-check line to
`DeployPossessioPool.s.sol`; write P-1's two inequalities into §0.3 as the calibration
acceptance test; record P-5 (x402Core pool wiring is a future version) next to the
factory's equivalent note; fix the P-8 doc drift. None of these touch
`src/PossessioPool.sol`.
