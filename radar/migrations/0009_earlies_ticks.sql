-- 0009: Screen 0 (early radar) + the oscillation tape.
--
-- Architect spec (2026-07-11): multi-screen method. Screen 0 = age 0-4min,
-- coin crosses $4k MC -> early-watch list (the human gets a look BEFORE the
-- machine's §1 window opens). Screen 1 = the existing 4-7min / 8-13k qualify.
-- Oscillating in-between the two screens and after the last screen: one MC
-- sample per cron tick per tracked coin, so momentum ("oscillators") can be
-- computed over the coin's whole life, not snapshots.

CREATE TABLE IF NOT EXISTS earlies (
  token_address  TEXT PRIMARY KEY,
  symbol         TEXT,
  name           TEXT,
  first_hit_ms   INTEGER NOT NULL,  -- when it crossed $4k
  first_hit_mc   REAL    NOT NULL,  -- MC at the crossing tick
  age_sec_at_hit INTEGER NOT NULL,  -- coin age when it crossed
  status         TEXT    NOT NULL DEFAULT 'watching', -- watching|qualified|missed
  status_ms      INTEGER
);
CREATE INDEX IF NOT EXISTS idx_earlies_status ON earlies(status, first_hit_ms);

-- The tape. 1-min resolution (the cron tick) is the honest granularity we
-- have; oscillators are computed at read time from this, never stored.
CREATE TABLE IF NOT EXISTS mc_ticks (
  token_address TEXT    NOT NULL,
  ms            INTEGER NOT NULL,
  mc            REAL    NOT NULL,
  PRIMARY KEY (token_address, ms)
);
CREATE INDEX IF NOT EXISTS idx_mc_ticks_ms ON mc_ticks(ms);
