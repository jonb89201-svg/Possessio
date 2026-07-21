# AUDIT PACKET — the RADAR (off-chain measurement instrument)

**For:** full council · **From:** Code Integrity seat · **Date:** 2026-07-20
**Tree:** `claude/repo-audit-h9m2ev` @ 56ceda2 · **Scope:** `radar/*.ts` + D1 schema

> This is a **scoping + first-pass read**, not a certification. It maps the
> surface, credits what verifies, and hands the council the sharp questions.
> The radar is the instrument that produces every forward-ledger number our
> strat / AutoTarget / PFG decisions rest on — so the audit's one load-bearing
> question is: **is the forward ledger honest?** Everything below serves that.

---

## 0. What the radar is (and why it outranks the contracts as an audit target)

A Cloudflare Worker + D1 (`possessio-radar-ledger`) + a Durable Object. It holds
no keys, signs nothing, trades nothing (§4 compliance, enforced) — it **observes
pump.fun births, qualifies candidates against the ratified §1 method, and records
what happens next.** The `candidates` table it writes is the forward ledger that
told us the current strat is net-negative (n=77, avg −8%, rug 39%). We *trust
that verdict enough to have pivoted the whole product on it.* That trust is only
as good as this code. The contracts are adversarially covered (856 tests); the
radar's measurement core has **zero** tests (§P4). That inversion is the reason
for this audit.

---

## 1. What VERIFIED GOOD on this read (credit where due)

- **`strat_take` is genuinely hindsight-free.** Computed at qualify time
  (`screen.ts` §1, ~L468–515) from only point-in-time inputs: `entry_mc` (curve
  MC now), `entry_vel` (birth-MC → now over age), `gate_dev`, `gate_rug`. No
  future data touches the take decision.
- **The dev-reputation gate has no lookahead.** `gate_dev` counts the creator's
  launches **strictly before this coin's own birth ms** (`pumpfun_first_seen_ms
  < ?`, L480–483) — the correct point-in-time construction.
- **`entry_mc` is write-once** (`INSERT … ON CONFLICT DO NOTHING`, L514) — entry
  is fixed at qualify, never retroactively adjusted.
- **The conviction stamp (0016) is an honest forward self-check** — frozen
  thresholds stamped at the first-8k tick, graded later against realized peak, on
  coins the derivation never saw.
- **First-principles MC** (`curveMcUsd`) is derived from constant-product curve
  reserves, verified to 5 decimals vs the feed's own field — the purest read.
- Extensive self-heal discipline (bounded `tfetch`, single-pass cron after the
  setTimeout stalls, 429 backoff) — operational maturity is real.

The instrument was built carefully. The findings below are about *measurement
bias and coverage*, not sloppiness.

---

## 2. PRIORITIZED FINDINGS / QUESTIONS

### P1 — MEASUREMENT INTEGRITY (does the ledger measure what we think?)

**P1-a — Entry and exit are priced on DIFFERENT rulers.** `entry_mc` is set from
the **pump.fun curve** read (`mcNow`, first-principles reserves). Outcome
tracking uses `mcOf = DexScreener.marketCap ?? pump.fun` (`screen.ts` L326) —
i.e. **exit is preferentially priced on DexScreener**, a different source that
computes MC its own way and can lag. So `(last_mc − entry_mc)/entry_mc` — the PnL
in every ledger query — contains a **source-mismatch component**, not pure price
movement. *Question for the council: quantify the curve-vs-DexScreener basis on
the same coin/tick; is the −8% partly a ruler artifact?*

**P1-b — Exit price is the 60s-cron tick, not the threshold.** Outcomes resolve
on a single-pass 60s cron (L530–556). `last_mc` booked at outcome is the MC **at
the tick that detected the crossing**, gapped past target/stop — not the target
or stop price itself. This **symmetrically inflates both tails**: winners booked
above target (the +98.3 best), losers booked below stop (the −82.5 worst). The
verdict is therefore measured at *60s-poll execution resolution*. That's a
specific, honest execution model — but **AutoTarget's keeper and the PFG both
assume a faster exit.** *Question: do the load-bearing numbers need re-derivation
at the pumptape 15s (or true-keeper) resolution before they gate design?*

**P1-c — `strat_take`'s rug gate is NULL-permissive; was it even ON?** `stratTake
= … && gateRug !== 0` (L505–506) — a **NULL** rug gate (RPC unset/unreachable,
L35 says it no-ops if `SOLANA_RPC_URL` unset) counts as **PASS**. If the Solana
RPC was not configured during the n=77 window, `strat_take` reduced to *momentum
AND fresh-dev only*, and "rug not failed" was vacuous. *Question the council must
settle from deploy config: was `SOLANA_RPC_URL` live for the measured window? If
not, the verdict never included rug screening — which changes what it proves.*

**P1-d — Winners are structurally under-counted (missed-target → timestop).** The
code's own note (L204–214): the pump.fun window clamps to ~5min; if DexScreener
hasn't indexed a coin, `mcOf → null` and the candidate can't resolve, so a real
target hit gets recorded as **timestop** (the named "Cumshot $26.9k" case). This
biases the verdict **pessimistic on runners** — the +75%/+98% tail may be larger
than the ledger shows. *Question: measure the miss rate; is the true edge less
negative than −8%, or is the gap random?*

### P2 — DATA INTEGRITY (can the ledger lose or corrupt rows?)

**P2-a — Retention vs tracking-window crossings.** `births` prune deletes
`status='expired'` past 48h (`watcher.ts` L168); `raw_birth_json` is NULLed past
30min (L180). Candidates JOIN `births` for outcome tracking (L525) and the rug
gate parses `associated_bonding_curve` from `raw_birth_json` at qualify (4–7min).
Candidates resolve within ~10min (timestop), so the windows *appear* not to
cross — *but the council should confirm there is no state where a still-`live`
candidate's birth row is pruned/nulled out from under its tracking JOIN.*

**P2-b — Unbounded-table history.** Prior incidents (DB hit the size ceiling and
**halted all writes** — L172–179) show the failure mode is real. `mc_ticks`,
`market_vol`, `births` now self-prune; *confirm every growing table has a prune
and that a prune can't race a write to zero-out live data.* (Ties to the standing
radar-watch DB-size trigger.)

### P3 — ACCESS / METERING (the product boundary)

**P3-a — Product-boundary enforcement.** The pre-discovery 'watching' list is
"the agent's eyes only — no HTTP surface returns those rows" (`watcher.ts`
L11–13); the screened *selection* is public but "never entry/exit prices or size"
(`screen.ts` L9–13). *This is a HIGH-severity invariant: audit `x402-toll.ts` +
`toll-routes.ts` that no route leaks watching rows or entry/exit/size, and that
`json_valid()` guards every `json_extract` (the R-1 500-the-feed vector).*

**P3-b — x402 metering / auth.** `x402-toll.ts` (453 L) + `sessiongate.ts` — the
paid measurement API. Audit nonce/replay on settlement, and that a failed/absent
payment can't return metered rows.

### P4 — TEST COVERAGE (the headline gap)

**The measurement core is untested.** `radar/test/` covers discovery, sessiongate,
x402-discovery — **not** `screenScan`, `curveMcUsd`, `entryVel`, the `strat_take`
composition, outcome resolution, or the ladder scorer. The single most
consequential logic in the product — the numbers every decision rests on — has
**no unit test.** For a shop whose epistemics are literally "we test the results,"
the instrument that produces those results is unverified. *Recommendation: a
deterministic test harness over `screenScan` with synthetic feed payloads,
asserting entry/outcome/strat_take against hand-computed expectations. This is the
highest-value build the radar could receive, and it's a precondition for trusting
the PFG §8 proof-loop (which runs on this same table).*

---

## 3. FILE MANIFEST (read order for the deep audit)

| # | file | L | why it matters |
|---|---|---|---|
| 1 | `radar/screen.ts` | 644 | **the measurement core** — qualify, strat_take, outcome, ladder, conviction. P1 lives here. |
| 2 | `radar/watcher.ts` | 330 | ingestion, discovery→graduation, prune. P2 lives here. |
| 3 | `radar/schema.sql` + `migrations/0001–0022` | — | the ledger's shape; confirm columns the queries assume exist and are typed right. |
| 4 | `radar/x402-toll.ts` | 453 | the paid HTTP surface — P3 boundary + json_valid guards. |
| 5 | `radar/feed.ts` | 490 | the PumpPortal per-trade feed + `conviction()`; cross-check thresholds mirror screen.ts. |
| 6 | `radar/pumptape.ts` | 433 | Layer-3 DO (15s alarm); the firehose subscribe hazard (position-scoping) flagged prior. |
| 7 | `radar/sessiongate.ts` | 182 | auth/session. |

---

## 4. OPEN QUESTIONS FOR THE COUNCIL (settle before any radar change)

1. **P1-b/P1-c are the two that can move the verdict.** Confirm the exit
   resolution model and the rug-gate config-provenance for the n=77 window. If
   either shifts the numbers, the AutoTarget/PFG designs inherit the shift.
2. Is the curve-vs-DexScreener basis (P1-a) small enough to ignore, or does the
   ledger need a single-ruler PnL?
3. Does the P4 test harness get built **before** the PFG §8 loop is trusted? (This
   seat's recommendation: yes — the proof-of-meaning loop and the harness are the
   same instrument.)

---

*This seat ran the read and reports the surface; it does not certify the radar.
The forward ledger is the one number the whole operation leans on, and it
deserves the diverse council's own read before we keep betting design decisions on
it. The instrument is well-built; the question is whether it measures what we've
been assuming it measures — and P1-b/c/d say "close, but with named biases we
should quantify before they harden into doctrine."*
