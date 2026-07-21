# RADAR FINDING — P1-b exit-resolution re-derivation (council item 4)

**For:** full council + Architect · **From:** Code Integrity seat · **Date:** 2026-07-20
**Re:** AUDIT_PACKET_RADAR P1-b — "outcomes resolve at 60s cron; booked exits gap
past thresholds." Council item 4 asked: re-derive at faster resolution, report
alongside the 60s figures, because *"AutoTarget parameters wait on this."*

---

## Data availability (honest first)

**A true 15s re-derivation cannot be done retroactively.** The `mc_ticks` tape is
**60s resolution** (measured: 1749/1761 inter-tick gaps ≈60s; 1 near-15s). The
15s mechanism (pumptape DO) is **dormant** — the metered feed is on hold, the
PumpPortal key unfunded. So the 15s number is a **forward-collection** task,
blocked on pumptape activation, not a query we can run today.

What we CAN do from existing data: bracket the exit-resolution sensitivity by
comparing the **booked** exit (last_mc at the 60s tick that detected the cross)
against **idealized** (exit exactly at the entry-relative threshold: target +50%,
stop −40%). The truth for any faster keeper sits between — but *where* between is
the whole finding.

---

## The numbers (n=77, strat_take=1, frozen forward set)

| model | avg PnL | what it assumes |
|---|---|---|
| **booked (60s)** | **−8.0%** | exit at the 60s tick that caught the cross (gapped) |
| idealized-perfect | **+3.7%** | every stop exits at exactly −40%, every target at +50% |
| **realistic fast keeper** | **−10.5%** | rugs stay booked (physics), ordinary stops → −40%, targets → +50% |

Tail (booked): worst −82.5%, best +98.3%. Every stop (31/31) gapped below −40%;
every target (16/16) gapped above +50%.

## Why the idealized +3.7% is a MIRAGE (the load-bearing decomposition)

Of the 31 stops, **30 are rug-depth (≤ −50%)** and **1 is an ordinary stop**
(−40 to −50%). The idealized +3.7% silently assumes a fast keeper exits all 31 at
−40% — but **gapping physics forbids rescuing a rug**: the pool drains faster than
any poll interval or block. A keeper at 15s, or even on-chain atomic, still eats
the −82% on a coin that rugs in one slot. Only **1 of 77 trades** sits in the
poll-latency-recoverable band.

So the realistic fast-keeper model — rugs locked at their booked depth, the one
ordinary stop recovered, targets exited at the +50% rule (a disciplined keeper
sells AT target, forgoing the lucky 60s overshoot that padded booked winners) —
lands at **−10.5%**, essentially the booked −8%.

## Conclusion (what this decides for item 4)

**P1-b is a real measurement bias, but it does NOT move the verdict.** Exit
resolution — 60s vs 15s vs on-chain — is **not the lever**, because the loss is
dominated by **rug gaps** (30/31 stops), which no exit speed can fix. The verdict's
negativity is a **rug-entry** problem, not an exit-latency problem.

**Direct consequences:**
1. **The rug-avoidance direction is confirmed as the edge lever.** The PFG / entry
   filter (separate rugs *before the buy*) is where the −82% tail is actually
   addressable — exactly because exit cannot address it. This strengthens the
   filter-stage PFG framing over any exit-speed engineering.
2. **AutoTarget keeper speed is for DISCIPLINE, not PnL rescue.** Its value is
   deterministic exits + the hard stop catching the ~1-in-77 ordinary stop — not
   turning −8% positive. Do not tune AutoTarget expecting speed to recover the
   tail; it can't.
3. **The 15s forward-collection (pumptape) is still worth doing** — to confirm this
   on live data and quantify the rare recoverable stop — but it will **not** flip
   the sign. Deprioritize it against the rug-entry filter.

---

*Item 4 delivered as the available-data bracket + the blocked-15s note. The
non-obvious result: the flattering +3.7% idealized figure is unreachable because
the tail is rugs, not latency — so faster exit is not the fix, rug avoidance is.
This is the honest number the AutoTarget parameters were waiting on.*
