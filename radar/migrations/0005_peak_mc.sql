-- migration_0005_peak_mc.sql — instrument the trade window (R-4)
-- APPLIED LIVE 2026-07-07 to possessio-radar-ledger
-- (e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde); verified by pragma read-back (18 cols).
-- This file is the repo mirror.
--
-- Why: the tape recorded only two MC snapshots - birth (~$3k) and graduation
-- ($69k, ~2% of tokens). The ENTIRE tradeable move (early curve pump through
-- the 8-13k zone to peak, then fade - all pre-graduation) happened in the
-- un-instrumented middle. discoveryScan already fetches each young token's
-- current curve MC on every poll and was discarding it; R-4 records the PEAK
-- so the birth->pump trajectory is measurable. Band analysis (e.g. 8-13k)
-- happens at READ time with a private threshold - the radar stores only the
-- generic peak (Sec6-safe: no proprietary band value in the schema).

ALTER TABLE births ADD COLUMN mc_peak_usd REAL;      -- highest MC ever observed for this token
ALTER TABLE births ADD COLUMN mc_peak_ms INTEGER;    -- timestamp of that peak observation
