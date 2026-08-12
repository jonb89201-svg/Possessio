# RESEARCH — The Radar Method: "Born Loaded" selection

**Seat:** Fathom (Code lane) · 2026-08-12 · All numbers MEASURED from the radar's
own D1 ledger this session (windows stated per table). Web context cited where it
converges. Method proposed, NOT ratified; forward validation required before any
live routing (the house's own conviction-stamp discipline applies to this too).

## 0. Why this study exists

The Architect abandoned the radar on 2026-08-11 trading night and beat it manually
with DexScreener + pump.fun. Measured verdict on the radar's night: 11 qualified,
0 hit 2x, 55% never moved — **selection at or below the 4.7% base rate.** The tool
was adding noise, not signal. Root causes, in order of weight:

1. **Wrong thesis:** it screens age 4–7 min in an $8–13k band — i.e. it buys AFTER
   the out-of-gate move, from a pool where the doubling is largely spent.
2. **Fatal recall:** ~11/day qualified out of ~40k births — while ~600/day land in
   the band this study finds most predictive.
3. **Ops rot (separate track):** the per-trade tape has been dead ~50h (PumpPortal
   key drained silently; Railway tape not heartbeating) under a green banner —
   a False Green, again. The tape does NOT explain the low yield (qualified/day
   was 3–21 all week regardless) — but it must be fixed and made LOUD.

## 1. Methodology + the leak that was caught

- Universe: births in a RESOLVED window (3d → 1d ago; n=37,653; grad base rate
  4.7%). Outcome = `mc_peak_usd / mc_at_birth_usd` (peak multiple from first
  sighting). Peak ≠ realized PnL — stated bound, not hidden.
- **Lookahead leak caught and excluded:** `mc_at_discovery_usd` / `gap_ms` are
  populated by DexScreener indexing, which IS effectively graduation — 100%
  "predictive," purely circular. Discarded. Every retained feature is knowable at
  first sighting.
- `mc_at_birth_usd` provenance verified in source (`watcher.ts` birthScan): USD
  field captured on FIRST poll sighting, `ON CONFLICT DO NOTHING` — never
  backfilled. 97% of coins are sighted <60s after creation, so first-sighting MC
  ≈ entry price: the from-entry standard holds.

## 2. Findings (each factor, measured)

**F1 — BORN LOADED (primary). MC at first sighting, <60s old:**

| birth MC | n (2d) | grad % | hit 2x | hit 1.5x | avg peak |
|---|---|---|---|---|---|
| <3k (junk floor) | 26,096 | 1.1% | 4.5% | 7.0% | 1.23x |
| 3–5k | 3,470 | 3.0% | 10.2% | 15.2% | 1.83x |
| **5–8k** | **1,201** | 11.8% | **22.4%** | **32.5%** | 1.69x |
| 8k+ | 1,767 | 66.5% | 17.4% | 24.8% | 1.38x |

The tradeable sweet spot is **5–8k**: heavy real buying out of the gate (an empty
curve reads ~$2.1k, so 5–8k ≈ genuine SOL committed in the first minute) but the
doubling not yet spent. 8k+ graduates most yet has the LEAST room — the current
radar's $8–13k entry band is structurally late. Volume: ~600/day in 5–8k.

**F2 — HOUR REGIME.** UTC 00–06 (US evening degen hours): 9.2% 2x vs 5.1% in
UTC 12–18 — a 1.8x ambient multiplier. Converges with the arXiv "graduation
regime windows" survival study.

**F3 — STACKING (the method's core cell):** 5–8k × UTC 00–06 → **26.8% hit 2x,
37.0% hit 1.5x** (n=246). Nearly 6x the junk floor, from birth-time signals only.

**F4 — 3-MIN MOMENTUM (secondary, honest from-entry accounting):** outcome
measured from the minute-3 price, not birth (no credit for unbuyable moves).
2x-by-3min coins double AGAIN from there 10.2% vs 3.2% for flat — 3x lift. Use
as ranking/confirmation, not primary.

**F5 — DEV FRESHNESS (weak, direction confirmed):** 1st-launch devs 7.4% vs 5.9%
for 11th+ serial launchers. Keep as a minor rank term; the existing rug gate
(top-holder ≤20%) stays as the safety filter it already is.

**F6 — THE GOLD WE THROW AWAY (retention bug with strategy cost):**
`raw_birth_json` is pruned after ~30 MINUTES, destroying the industry's
strongest-cited signals before they can be studied: `twitter`/`website` presence,
`is_currently_live` (livestream at birth), `reply_count`,
`real_sol_reserves` (purer than USD MC), launcher-tool fingerprints in
`description`. External research (arXiv sniper-cohort + survival studies; holder
"first-30-seconds wallet architecture" analyses) ranks these top-tier.
**Recommendation: migration adding these as columns at insert.** One week of
accrual makes them backtestable here; cost is a few bytes/row.

## 3. The method — "Born Loaded" fast lane (proposed)

Additive lane; ratified calibration (strat_take, conviction stamps, ladder
scoring) untouched and running in parallel:

1. **Evaluate at FIRST SIGHTING** (birthScan already sees 97% <60s old). No
   4-minute wait — the signal IS the first minute.
2. **SELECT:** first-sighting MC in **5–8k** → baseline 22.4% 2x / 32.5% 1.5x.
3. **RANK:** + hot-hours regime (UTC 00–06 ×1.8) · + fresh dev (minor) · then
   3-min momentum re-rank once ticks accrue (hot climb promotes, flat demotes).
4. **SAFETY:** existing rug gate affirmative-pass; sniper-cohort screen
   (RED-COHORT-2026-v1, arXiv) as a future filter once wallet data persists.
5. **EXIT:** the desk's existing ladder discipline. With 37% reaching 1.5x in
   the core cell, ladder rungs capture far more often than a single 2x target.
6. **VALIDATE FORWARD before any live routing:** stamp fast-lane picks
   paper-first (the house's own conviction-stamp pattern), grade for a week
   against realized peaks, THEN ratify thresholds. This study is a 2-day window;
   regimes drift; the numbers above are the hypothesis, the forward stamp is
   the test.

## 4. Honest bounds

- Peak-multiple ≠ realized return: nobody sells the top; the ladder discipline is
  what converts peaks into PnL, and slippage/fees on newborn curves are real.
- 2-day resolved window; regime drift is certain; forward validation is the test
  that counts (§3.6).
- Base-rate humility: even the best cell loses 73% of the time to a 2x target —
  the edge is portfolio-shaped (many small entries, ladder exits), never a
  single-bet thesis. This is selection improvement, not a printing press.

## 5. Ops track (separate, still owed)

Tape False Green: PumpPortal key drained (silent), Railway tape not heartbeating
~50h, no health endpoint escalates feed_status staleness (the `/api/radar/health`
route referenced in comments does not exist; `/radar/ws-status` reads the dormant
DO under TAPE_HOST=railway). Fix: a real health verdict off feed_status with
loud RED on critical-feed staleness + console surfacing. Key top-up and Railway
restart are Architect-terminal actions.

— Fathom · If it can't be tested, it doesn't exist; forward stamps or it isn't
ratified.
