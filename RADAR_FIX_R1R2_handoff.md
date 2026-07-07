# HANDOFF — Radar Corrections R-1/R-2 + Rulebook §1 Exit-3 Amendment
**Origin:** Code Integrity seat, 2026-07-07, Architect-ratified ("Let's do it").
**Trigger:** First radar audit (14:26Z). Finding confirmed at source: DexScreener indexes
the pump.fun bonding curve itself as dexId `pumpfun`, so `pairs.length > 0` fires ~60s
after birth. Graduation to the real surface happens at $69K MC — 6.9x the method's entry,
3.45x its take-profit.

## Already done (live, this session)
- **Migration 0003 APPLIED:** `ALTER TABLE births ADD COLUMN curve_pair_seen_ms INTEGER;`
  Verified by pragma read-back — births now 15 columns. Mirror this file into
  `radar/migrations/` as `migration_0003_curve_pair.sql`.

## R-1 (HIGH) — Discovery predicate, exact change
In `discoveryScan`, replace the `pairs.length > 0` branch:

```ts
const pairs: any[] = data?.pairs ?? [];
const curvePair = pairs.find((p) => p?.dexId === "pumpfun");
const gradPairs = pairs.filter((p) => p?.dexId && p.dexId !== "pumpfun");

// telemetry: first sighting of the bonding-curve index entry (write once)
if (curvePair) {
  // UPDATE births SET curve_pair_seen_ms = COALESCE(curve_pair_seen_ms, ?now) WHERE token_address = ?addr
}

if (gradPairs.length > 0) {
  // THE event: graduation surface reached.
  // status='discovered', dexscreener_first_seen_ms = now,
  // gap_ms = now - pumpfun_first_seen_ms,
  // mc_at_discovery_usd from gradPairs[0].marketCap ?? fdv
}
```
`dexscreener_first_seen_ms` now MEANS "first non-pumpfun pair" (graduation surface).
Comment that in the schema mirror. Expiry branch unchanged (24h without graduation
→ 'expired' — this will now be the COMMON path; ~98% of births never graduate).

## R-2 (MED) — Throughput
Post-fix the watching set holds ~20-30 min of inflow (~500-800 rows at current birth
rate) vs 25 checks/min. Fix: batch the DexScreener call — the tokens endpoint has
historically accepted comma-joined addresses (~30 per request). **VERIFY-FIRST against
current DexScreener API docs** (rate limits too), then:
- chunk watching rows into groups of ≤30, few requests per tick, map results by
  baseToken.address. Target: full watching-set sweep every 1-3 min.
If multi-address is no longer supported: fall back to raising DISCOVERY_BATCH within
rate limits and note per-token discovery resolution honestly in gap-stats output.

## Acceptance 3 — REDEFINED
Old: median gap_ms vs ~20-min prior (invalid — measured cron latency).
New, after ≥6h of clean tape:
1. **Graduation rate:** graduated / total births (prior: ~2% from public lore — first
   real measurement).
2. **Median birth→graduation time** for graduated tokens vs the Architect's ~20-min
   prior (now correctly framed as a winners-only survivorship stat).
3. **curve_pair_seen_ms sanity:** median ≈ one cron tick (this is the machine's own
   latency, kept as telemetry, no longer confused with the market).
Gap-stats route: expose graduated count, graduation rate, median/percentile
birth→graduation. Product note: **graduation-rate-per-hour is the measured Session
Gate** — the regime signal §0 wanted, as data instead of feel. Price it later.

## Tape wipe protocol (Architect-ratified)
Order matters — wiping before the fix just re-poisons:
1. Claude Code lands R-1 + R-2 + migration mirror → Architect deploys
   (`npx wrangler deploy` from radar/, existing token).
2. Architect says "deployed" → **Code Integrity seat executes the wipe live**
   (`DELETE FROM births;`) and verifies zero + first clean tick.
3. Tape restarts clean; 6h later, first valid Acceptance-3 read.

## Rulebook §1 Amendment — DRAFT for Architect ratification
**Exit trigger 3 (was: EDGE-LOSS on DexScreener appearance — INVALID, would fire ~60s
after every entry):**
> **EXIT 3 — STALL:** If the position has printed no new high for **10 consecutive
> minutes** (OPEN default; tape-calibrated after first week), market sell.
Hierarchy unchanged: TP $20K / SL $6K / STALL / BACKSTOP 45 min. Rationale: the real
threat to a $10K→$20K move is momentum death, not indexing — graduation at $69K sits
above TP and is a *victory* condition, not a flight signal. Everything else in §1–§5
unchanged: entries, caps, rug-gates, activation sequence, tape-before-trades.

*Eight minutes of tape bought this document. Codebyte Law on everything above: the
predicate change is spec until the suite passes and clean rows prove it live.*
