-- 0017: index mc_ticks(ms) — RELIABILITY.
--
-- The tape prune runs every screenScan: DELETE FROM mc_ticks WHERE ms < ?.
-- mc_ticks' PK is (token_address, ms), so a predicate on ms ALONE cannot use
-- the composite index — it full-scans the whole table (340MB+ and growing)
-- every pass. As the table grew this got slower each tick and likely helped
-- push screenScan over its time budget, contributing to the tape stalling
-- while the lighter cron-siblings (birthScan/btcScan) kept running.
--
-- An index on ms makes the range-delete (and the freshness/window queries)
-- cheap. Applied live to possessio-radar-ledger 2026-07-13.

CREATE INDEX IF NOT EXISTS idx_mc_ticks_ms ON mc_ticks(ms);
