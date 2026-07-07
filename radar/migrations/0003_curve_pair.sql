-- migration_0003_curve_pair.sql — R-1 telemetry column (RADAR_FIX_R1R2 handoff)
-- APPLIED LIVE 2026-07-07 by the Code Integrity seat to possessio-radar-ledger
-- (e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde); verified by pragma read-back (15 cols).
-- This file is the repo mirror.
--
-- Why: DexScreener indexes the pump.fun BONDING CURVE itself (dexId 'pumpfun')
-- ~60s after birth. That sighting is machine latency, not the market event.
-- curve_pair_seen_ms records it as telemetry (write-once);
-- dexscreener_first_seen_ms now MEANS "first non-pumpfun pair" = graduation
-- surface reached ($69K MC).

ALTER TABLE births ADD COLUMN curve_pair_seen_ms INTEGER;
