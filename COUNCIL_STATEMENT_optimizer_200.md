# COUNCIL STATEMENT — Uniform optimizer `runs=200` across all contracts

**From:** Code Integrity seat · **Date:** 2026-07-21 · **Tree:** `claude/repo-audit-h9m2ev`
**Subject:** Why every contract compiles at `optimizer_runs=200`, and what that
decision costs and buys — measured, not asserted.

---

## 0. The claim, in one line

Uniform `runs=200` is **forced by two independent hard constraints**, not chosen
for taste. Its entire runtime cost is **~0.3% on the settlement hot path**
(measured); its benefit is that the protocol's tightest contract *can exist at
all* and every template deploys ~9% cheaper for the customer. This statement
gives the council the numbers to check both.

---

## 1. The forcing function — two constraints, both hard

### Constraint A — the hook does NOT fit at high runs (EIP-170)

The EVM caps deployed bytecode at **24,576 bytes** (EIP-170). Measured this
session, on this tree, both ways:

| contract | `runs=200` | `runs=10000` | margin @200 | margin @10000 |
|---|---:|---:|---:|---:|
| **PossessioHook** | 24,167 | **28,147** | **+409** | **−3,571 (OVER)** |
| PossessioPayments | 19,445 | 21,447 | +5,131 | +3,129 |
| PLATE | 20,516 | 22,684 | +4,060 | +1,892 |
| ServiceAccountabilityVault | 5,118 | 6,661 | +19,458 | +17,915 |

At `runs=10000` the hook is **28,147 bytes — 3,571 over the ceiling. It cannot be
deployed.** Not "expensive," not "tight" — **undeployable.** So high runs is off
the table for the hook, full stop, before any preference enters.

### Constraint B — you cannot mix per-contract runs in this graph

The obvious escape ("keep the hot-path contracts at 10000, drop *only* the hook")
does not compile. The previous per-contract `compilation_restrictions`
(payments/x402 → 10000, L1 → 800) **could not include the hook**: the hook is
co-imported with those restricted siblings across the test/compilation graph, and
`forge` rejects that as **`incompatible settings restrictions`** — one compilation
unit cannot satisfy two different per-contract runs at once. This is a toolchain
hard error, reproduced this session, not a lint we chose to ignore.

### The conclusion is not a choice

- 10000 uniform → impossible (Constraint A: hook over ceiling).
- Mixed per-contract → impossible (Constraint B: forge rejects it).
- ∴ **uniform, and low enough that the hook fits** → `200`.

The only free parameter left is *which* uniform-low value. That is the one real
decision, addressed in §3.

---

## 2. What 200 COSTS — measured runtime gas (the honest downside)

The sharpest objection: "you lowered the money hot path from 10000 to 200 —
what do our customers pay per transaction, forever?" Measured on
`PossessioPaymentsAutomationTest`, identical tests, the two builds:

| hot-path fn | `runs=10000` avg | `runs=200` avg | delta | delta % |
|---|---:|---:|---:|---:|
| `sweep` (the settlement path) | 346,873 | 347,883 | **+1,010** | **+0.29%** |
| `sweep` (max observed) | 435,972 | 437,206 | +1,234 | +0.28% |
| `performUpkeep` | 63,809 | 63,927 | +118 | +0.18% |
| `checkUpkeep` | 14,437 | 14,462 | +25 | +0.17% |

**The whole downside is ~1,000 gas on a ~347,000-gas sweep — three-tenths of one
percent.** This is not surprising: the optimizer's runtime benefit is
front-loaded — most of the gain lands in the first couple hundred runs, and
`200 → 10000` is the flat tail. We were paying for the tail in bytecode (which we
cannot afford) and getting almost nothing back in runtime.

## 3. What 200 BUYS — and why not 1

**Deploy economics (the recurring, customer-paid cost).** Every contract here is
a **template a customer deploys**, paying deploy gas on the *full* bytecode each
time. At 200 vs 10000, Payments is **19,445 vs 21,447 bytes — 2,002 bytes (−9.3%)
smaller**, i.e. ≈ **400k gas cheaper per deployment**, multiplied by every
customer who ever launches one. Runtime gas is paid by whoever transacts on an
already-deployed contract; **deploy gas is paid once per customer, by the
customer, and it feeds their price.** For a template product, the deploy lever is
the one that compounds.

**Why 200 and not 1 (the hook fits at 1 too):** `200` is the conventional
floor-of-good-runtime — the point where the front-loaded runtime benefit is
essentially captured. Going below it trades measurable runtime gas on the hot
paths for a *rounding-error* further size reduction (≈100 B on the hook between
1 and 200). The hook clears the ceiling with room at 200 (+409), so there is no
size pressure forcing us lower, and no reason to surrender runtime we can keep.
200 is the balance point, not a compromise.

**Uniform is also stable under growth.** Any new contract added to the graph that
gets co-imported with a restricted sibling would re-trigger Constraint B. A single
global setting removes that entire class of future conflict permanently.

---

## 4. Caveats — on the record, not under it

- **Codehash regen owed.** The uniform-200 change invalidates the pinned
  init-codehashes in `deploy/optimizer_pool.json`; regen via
  `sync_optimizer_pool.sh` **before** the factory freezes template
  init-codehashes.
- **The live standalone Payments won't match.** `0x1c0F…`, deployed at
  `runs=10000`, will not bytecode-match a 200 rebuild. It is a historical
  reference deploy; council to confirm that mismatch is acceptable (it does not
  affect any un-deployed template).
- **Numbers are the terminal's.** Every figure above is reproducible on this tree:
  `forge build --sizes` for the size table; `forge test --match-contract
  PossessioPaymentsAutomationTest --gas-report` at each `optimizer_runs` for the
  gas table. Where this file and a fresh run disagree, the run wins.

---

## 5. The ask

Ratify uniform `optimizer_runs=200` as the standing deploy profile, on this
record: high runs is *impossible* (hook +3,571 over ceiling), mixed runs is
*impossible* (forge rejects it), the runtime cost of 200 is *0.3% on the hot
path*, and the deploy-side saving is *~9% per customer launch*. If any seat wants
a different uniform value, the two constraints above bound the choice — 200 is
where runtime is preserved and every contract fits.
