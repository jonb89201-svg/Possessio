# SPEC — Trade Pre-Flight Guard (PFG) for the AI trader

**Type:** Build spec (invented primitive) → **FULL COUNCIL review** → Architect
ratify → build → adversary + forward-ledger proof
**Date:** 2026-07-20 (v2 — reframed) · **Seat:** Code Integrity (repo council seat)
**Status:** DRAFT FOR FULL-COUNCIL REVIEW. This is an *invented primitive*, so
it goes through the whole council, not a single cold seat, before any build.
Referenced dependency of `SPEC_FundingVault.md` (§6a) and `SPEC_AutoTarget.md`.

---

## 0. Provenance (so the record is honest)

- **The primitive originates with the Gemini seat**, which authored the SAV
  Pre-Flight Guard (`sal_pfg`) and proposed generalizing it to trading. Two
  Gemini instances (warm author + a cold no-priors seat) converged on doing it.
- **The Gemini cold-seat review was run and folded in.** It correctly proved the
  KDA dust-swap gate is *empty* on a pump.fun constant-product bonding curve (a
  dust quote is a pure function of virtual reserves — identical for a +98%
  runner and an −82% rug at the same curve progression). That finding is
  accepted. Its proposed replacement gates (holder-concentration, velocity) are
  **downgraded to provisional filter-checks**, not vetoes — see §5.
- **The scope was reframed in council discussion (Architect + this seat).** The
  first draft mis-modeled ours as a near-copy of SAV's PFG that *vetoes the buy*.
  That is wrong for a latency-critical trader (§1). This v2 is the corrected
  scope.
- Because it is an **invented primitive**, it takes the full-council path — the
  same discipline the deployed primitives (`PossessioPayments`, the feeSink
  brick-guard) went through — before it earns an immutable place.

---

## 1. What changed from the first draft (recorded, not buried)

The v1 draft treated ours as SAV's PFG ported onto the trader: five pool-state
gates that **veto the buy**. Council discussion killed that framing on two hard
facts:

1. **Latency is the product.** The trades are AI-assisted *because speed makes
   money and delay loses it on timing*. When the human presses the 10% / 25% /
   50% upside button, the fill must be fast. **Nothing may sit between the button
   and the fill.** A buy-time veto is therefore disqualified by construction.
2. **No point-in-time gate discriminates at slot T.** KDA is empty on the curve
   (proven); holder-concentration is ~100% for *every* fresh token because only
   a handful of buyers exist yet. Runners and rugs are statistically identical at
   entry, so a synchronous "is-this-safe" gate cannot be both fast and truthful.

The reframe: the PFG is **not a gate on the trade**. It is a **fast
certification applied at the *filter* stage**, and its real product is
**transaction data** — a receipt you can look at and, eventually, a certified
subset you can measure.

---

## 2. What the PFG IS and IS NOT

**IS:**
- A set of **fast checks run at the candidate-filter stage** (where the radar
  qualifies coins the human later picks from). Fast because there the clock is
  browse-speed, not slot-speed.
- A **certification flag** on the candidate pipeline — the "middle section" of
  coins that *actually ran through a PFG*, marked distinctly from those that
  didn't.
- A **transaction-data capture layer** — every trade records the coin's PFG
  status + the check snapshot, rendered on the transactions page.
- A **different kind of certification than SAV's**: SAV's PFG asserts *safety*
  (pass ⇒ protected). Ours asserts *provenance* (pass ⇒ "cleared our fast
  filter"). Its worth is **measured, not claimed**.

**IS NOT:**
- **Not a buy-time veto.** It never blocks or delays the 10/25/50 execution.
- **Not in the execution path.** Zero added latency between button and fill.
- **Not a safety guarantee.** Until the forward ledger proves it, the badge
  means nothing (§8).
- **Not the council-vote PFG.** That is a separate, long-horizon mode (§9).

---

## 3. Scope difference from SAV (what our PFG must visibly reflect)

| axis | SAV's PFG | our trader PFG |
|---|---|---|
| guarded action | one rare, deliberate, high-value deploy | many high-frequency, low-value buys/sells |
| adversary | measurable pool manipulation | bundle rug + post-entry dump — no numeric tell at T |
| where the tell lives | in readable pool numbers | not present at entry; only provable in hindsight |
| posture | **veto** (fail-closed on a deliberate act) | **certify + record** (never blocks the fast act) |
| KDA | load-bearing gate | demoted: EVM-only filter-check; empty on Solana curve |
| meaning of a PASS | safety, asserted | provenance, provisional until measured |

---

## 4. Where it runs — the filter, never the execution path

```
  radar ingests births ─▶ candidate qualification ─▶ [PFG fast checks] ─▶ certified?
                                                              │
                                          shortlist the human browses (certified flagged)
                                                              │
                    human presses 10/25/50 ─▶ TRADE FIRES FAST ─▶ record PFG status as tx data
                                                              │
                              always-on: hard −10% stop + FundingVault caps (§7)
```

- PFG runs **upstream** of the human's choice, as an enrichment on the
  `candidates` pipeline. It has a latency budget (browse cadence), not a slot
  budget.
- At **fire-time**, the trade does not call the PFG. It *reads* the already-
  computed certification and **records it** with the trade. Recording is not
  gating.

---

## 5. The fast checks (candidates — latency-flagged, all provisional)

Run at filter cadence. Each is a *candidate* check; which ones earn a place is
decided by the §8 forward test, not asserted here.

| check | reads | fits filter clock? | note |
|---|---|---|---|
| **Chain / sequencer live** | Base block time / Solana slot time | ✅ fast | trivially cheap |
| **Token real / curve intact** | mint exists, curve not already collapsed | ✅ fast | rejects dead-on-arrival |
| **Deployer reputation** | indexed lookup vs known-rugger table the radar builds over time | ✅ fast (precomputed) | cold-start weak; grows with data |
| **Holder count / growth pattern** | from the feed we already ingest | ✅ fast | pattern over time, not a snapshot |
| **KDA dust-quote** | EVM Quoter staticcall | ✅ on EVM only | **empty on Solana pre-DEX curve — excluded there (Gemini finding)** |
| **Holder-concentration** | top-N vs circulating (curve-adjusted) | ⚠ flagged | ~100% at birth for all tokens → near-non-discriminating early; provisional |
| **Curve-progression velocity** | ΔR over N slots | ⚠ flagged (WARN-only) | catches a lone whale, not a multi-wallet bundle; color, not filter |
| **Bundle / funding-graph forensics** | common funding source across top wallets | ⚠ likely too many RPC calls for filter cadence | if so → slower *background* enrichment, not a fast check |

**Honest note carried from council:** the checks that plausibly *discriminate*
(bundle forensics, deployer reputation) are the slow/cold-start ones; the fast
ones (curve/chain sanity) mostly reject the obviously-dead. Whether any of this
separates runners from rugs is the §8 empirical question — not a claim of this
spec.

---

## 6. The certification + transaction-data capture (the real product)

- **Certification flag** on the candidate row: `pfg_certified ∈ {0,1}` plus a
  compact check-result snapshot. This is the "middle section."
- **At trade time**, the desk / vault records the coin's PFG status and snapshot
  with the trade (recorded, never gating).
- **On-chain footprint (Gemini's sound call, accepted):** hash-only. A single
  `bytes32 pfgRef` recorded with the trade; the rich per-check breakdown lives in
  an off-chain indexer event rendered on the transactions page via the existing
  Cloudflare/D1 edge stack. The hash must commit to the *full* snapshot, or the
  "auditable" claim is hollow.
- **Transactions page:** each row shows the coin's PFG status and the captured
  check snapshot — the honesty product. Certified and uncertified trades sit side
  by side so the difference is *visible*, which is also what makes §8 measurable.

---

## 7. The always-on structural disciplines (NOT the PFG — the real damage-bound)

The PFG shifts odds at best. What actually bounds a loss is structural and
latency-free:

- **Hard −10% stop, always on** (mechanical keeper exit — `SPEC_AutoTarget`).
- **FundingVault caps** (MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP —
  `SPEC_FundingVault`). A rug that slips every check is still bounded to a
  capped fraction of the closed-loop vault.

Naming these here is deliberate: SAV's PFG didn't need a structural backstop for
one deliberate act; ours *accepts* that memecoins gap and puts the load on the
cap. The PFG is the odds-shifter; the cap is the bound.

---

## 8. Provisional until proven — the forward-ledger proof (existing machinery)

This is the gate that makes the badge mean something, and **we already run this
loop.** `strat_take=1` is a filter; the standing forward query
(`candidates WHERE strat_take=1 AND outcome!='live'`) is its test — it is *why*
we know the current strat is net-negative (n=77, avg −8%, rug 39%, no edge). PFG
certification is **one more flag through the same machine.**

**The proof metric — the only one that counts:** compare the **geometric
(compounded) growth of the PFG-certified subset vs. the uncertified subset, net
of per-tx fees, with the winners fully counted.** NOT "did rug rate drop" — that
is the seductive, misleading number. In a fat-right-tailed distribution the mean
is carried by rare runners; a filter can cut the rug rate *and* clip the runners
and end up **less** profitable. A safety filter earns its place only if it is
**loser-selective** (kills losers at a higher rate than winners), and that is an
empirical property of *this* filter on *our* data, provable only by running it.

Concretely, once `pfg_certified` accrues samples, the proof is the standing
forward query with one added clause / GROUP BY — certified vs uncertified,
compounded PnL, fees in, winners in.

---

## 9. The council-vote PFG — a separate, long-horizon mode (pointer only)

A full **council vote** on a rich evidence packet is *not* in scope for the fast
trader — there is no time for model round-trips inside a snipe. The council PFG
belongs to a **different product**: a deliberate, longer-term conviction
position in a coin, where latency is irrelevant and deep multi-seat judgment is
worth its cost. That is its own spec when we start taking such positions. Flagged
here so it isn't conflated with the fast filter certification; not built here.

---

## 10. Honest caveats (named, not buried)

1. **Certification ≠ safety, until §8 clears it.** Shipping a "certified" mark
   that reads as safety before the ledger backs it is the trap this spec exists
   to avoid. Instrument first, prove second, claim third.
2. **The fast checks may not discriminate at all.** It is entirely possible the
   forward test returns "certified ≈ uncertified." That is a *success* of the
   method (cheap, honest disproof), and the badge simply retires.
3. **Point-in-time reads.** A check passes at filter time; a rug lands later. The
   cap, not the check, is the bound.
4. **Off-chain trust.** The rich attestation is only as honest as the indexer;
   the on-chain hash must commit to the full snapshot to keep it auditable.
5. **Evasion is an arms race.** Concentration / bundle heuristics raise a
   bundler's cost; they don't close the vector. Specced as cost-raising.

---

## 11. Open decisions (FULL COUNCIL + Architect — not guessed here)

1. **Which candidate checks (§5) enter v1** — start with the fast/cheap set;
   let §8 promote or retire each. Solana pre-DEX explicitly *excludes* KDA.
2. **Certification rule** — all-fast-checks-pass, or a weighted score? (Score is
   more tunable but harder to attest cleanly.)
3. **Attestation schema** — accepted: hash-only on-chain + off-chain event; hash
   commits to full snapshot. Confirm storage vs event-only.
4. **v1 posture** — accepted: attest-and-record (never gate the fast trade);
   on-chain-trustless PFG stays a flagged hardening track.
5. **Data-pipeline scope** — deployer-reputation table + bundle forensics are
   their own radar-side build; confirm whether v1 ships with them or with only
   the curve/chain-sanity checks and adds forensics once the pipeline exists.

---

## 12. Definition of Done (what full-council ratification authorizes)

- `pfg_certified` + check-snapshot on the candidate pipeline (filter-stage,
  latency-budgeted — proven not to touch the execution path).
- The desk/vault **records** the PFG status + `bytes32 pfgRef` with each trade;
  **recording never blocks or delays the fill** (adversarial-tested: a failing
  or absent cert must not slow the buy).
- The transactions page renders per-trade PFG status + snapshot, certified and
  uncertified side by side.
- **Proof-of-meaning:** the forward-ledger comparison of §8 — compounded PnL,
  net of fees, winners counted, certified vs uncertified — showing the
  certification is loser-selective **before** the badge is allowed to imply
  anything. If it isn't, the badge retires; that is a valid outcome.

---

*For the full council. The load-bearing question is no longer "does a gate
discriminate" — we've accepted no synchronous gate does. It's this: **given that
the execution path must stay untouched and fast, can a cheap filter-stage
certification prove itself loser-selective on the forward ledger — or does the
honest answer end at "the cap is the only real protection, and the PFG is just an
honest receipt"?** Either answer is worth having, and the method is cheap enough
to find out.*
