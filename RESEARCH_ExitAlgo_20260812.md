# RESEARCH — The Swap Algorithm: warm entry, measured exits

**Seat:** Fathom (Code lane) · 2026-08-12 · Companion to `RESEARCH_RadarMethod_20260812.md`.
All numbers MEASURED from prod D1 this session, fresh 46h resolved window (48h→6h ago,
disjoint from the first study's window). Method: if we can't prove it, it doesn't exist.

## 0. What this study asked

The first study picked the ENTRY POOL (birth MC 5–8k at first sighting). This one asks
the money questions: is the pool buyable as-is, WHEN do you actually enter, and how do
you exit. The answers revise the method — including one of its own rankings.

## 1. Out-of-sample check first (the fresh window)

n=2,088 band coins, all with recorded peaks: **17.7% touched 2x** vs 22.4% in the study
window and 4.7% base rate. The edge survives out-of-sample; regime drift is real and in
the expected direction (this window skews toward off-peak hours).

## 2. The band is a WATCHLIST, not an auto-buy (loser physics)

- 60.6% of band coins never touch even 1.10x. **The losers' AVERAGE peak is 0.606x** —
  they never see entry again; half never see 0.5x again. The dump is instant.
- Break-even for buy-them-all at any take-profit rung m requires exiting losers at
  ≥ ~0.8x. Against an instant dump, with slippage, that is not a real number.
- Measured EV of entering every band coin: **−20% to −35% per trade** under any ladder.

The stamp is therefore a SIGHTING, not a signal. The signal comes next.

## 3. The 3-minute read — and the ranking the first study got backwards

Entry priced at the coin's ~3-min tape tick (mc3); a win counts ONLY if the peak
timestamp is strictly AFTER minute 5 (kills the same lookahead species the first study
caught in discovery gaps — an all-time peak that happened before your entry is not a
win you could buy). Losers without a forward peak carried at 0.6 salvage; tails capped
at 10x for the EV proxy.

| 3-min read (mc3 / birth) | n | fwd ≥1.5x entry | fwd ≥2x | fwd ≥3x | EV proxy |
|---|---|---|---|---|---|
| down (<0.95x) | 593 | 8.3% | 6.4% | 3.4% | 0.82 |
| flat (0.95–1.3x) | 276 | 17.0% | 10.9% | 4.3% | 1.01 |
| **warm (1.3–2x)** | **183** | **31.1%** | **24.6%** | **12.6%** | **1.36** |
| hot (≥2x) | 134 | 23.1% | 11.9% | **0.7%** | 0.97 |

**F7 — THE INVERSION.** The first study's F4 ranked hot ("2x off the line") as the top
confirmation. Forward-honest accounting says otherwise: **by minute 3 the hot move is
SPENT** — buying it is buying the top (0.7% ever reach 3x from there, EV 0.97 before
fees). **Warm is the move still happening**: a quarter of warm reads double from the
actual entry price. The desk badge that said "2x off the line = best" was a mislead;
corrected in this change (warm = the entry window; hot = already ran, don't chase).

F4's raw claim (hot 3-min coins outperform flat/down) was directionally true — hot
beats down 11.9% vs 6.4% — but warm crushes both, and the first study never priced the
entry AT minute 3, which is the only price a 3-min read can buy.

## 4. Hold discipline (when winners peak)

Warm winners' forward peaks: 30% by minute 10, 76% by minute 20, 100% by minute 30.
**Peak tracking stops at 30min by ratified config** (`YOUNG_WINDOW_MIN=30`, R-8,
2026-07-08) — verified in source, so "100% ≤30min" is the measurement horizon, not
market physics. For THIS trade it is a matched horizon: entry at min 3, exits inside
the tracked window; any post-30min tail we can't see makes warm EV a LOWER bound.

## 5. Exit pricing (the survival curve is the ladder's price sheet)

Selling a fraction at touch of multiple m earns m × P(peak ≥ m). From the warm cohort's
forward curve: m·P is ~flat from 1.5x (0.47) to 2x (0.49) then decays (3x → 0.38). So:

- **Rungs at 1.5x and 2x from entry carry equal weight** — bank both.
- The ≥3x tail (12.6% of warm) is where the fat outcomes live but a fixed 3x rung
  underprices it; a RUNNER fraction with the desk's existing trailing discipline
  captures it better than any fixed rung.
- A hard 30-minute time-stop on the remainder costs nothing measurable (no warm winner
  peaked later inside the tracked horizon) and caps the corpse-holding risk.

## 6. The method, v1.1 (proposed — supersedes §3 of the first study where they conflict)

1. **STAMP** at first sighting, 5–8k band (unchanged) — this is the watchlist.
2. **ENTER only on the 3-minute WARM read** (1.3–2x birth). Down/flat: no entry.
   Hot: missed — do not chase.
3. **EXIT:** ~40% at 1.5x entry · ~30% at 2x entry · ~30% runner on the trailing
   discipline · hard time-stop at coin age 30min · fast cut if it breaks below entry
   after the warm confirmation (the salvage IS the edge's other half — §2).
4. **VALIDATE:** the fastlane table now grades band+momentum stamps forward daily;
   real trading remains the test that counts (Architect ruling).

## 7. Honest bounds

- Warm cohort n=183 (fwd-2x count 45): ±6–7% on the headline rates. One 46h window.
- Peak-touch ≠ fill; fees/slippage on newborn curves unpriced here (EV 1.36 is
  pre-cost; the margin absorbs realistic costs but thin trades will eat the edge).
- mc_ticks exist only for coins that crossed the $3.5k early screen — conditioning is
  legitimate (the desk needs a tape read to act) but the no-tick 39% of the band is
  unstudied by construction.
- 30-min peak truncation per §4 — matched horizon, lower-bound EV.

— Fathom · Forward stamps grade it from here; the terminal, not this document, ratifies it.
