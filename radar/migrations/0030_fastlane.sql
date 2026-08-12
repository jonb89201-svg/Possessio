-- 0030: the Born Loaded fast lane (RESEARCH_RadarMethod_20260812).
--
-- (a) Persist the birth-time gold at insert (F6): raw_birth_json is pruned at
--     ~30min, which was destroying the industry's strongest-cited signals
--     (livestream-at-birth, socials, replies, real reserves, launcher tool)
--     before they could ever be studied. Columns are a few bytes/row and make
--     them backtestable after a week of accrual.
ALTER TABLE births ADD COLUMN has_twitter INTEGER;
ALTER TABLE births ADD COLUMN has_website INTEGER;
ALTER TABLE births ADD COLUMN live_at_birth INTEGER;
ALTER TABLE births ADD COLUMN reply_count INTEGER;
ALTER TABLE births ADD COLUMN real_sol_reserves REAL;
ALTER TABLE births ADD COLUMN launcher TEXT;

-- (b) The fast lane itself: picks stamped at FIRST SIGHTING (the research's
--     from-entry standard: 97% of births are sighted <60s old, so the stamp
--     price is the entry price). The stamp is immutable; momentum/peak/outcome
--     are forward fill-ins graded against births.mc_peak_usd. Real trading is
--     the test that counts (Architect); this table just keeps score.
CREATE TABLE IF NOT EXISTS fastlane (
  token_address  TEXT PRIMARY KEY,
  symbol         TEXT,
  name           TEXT,
  sighted_ms     INTEGER NOT NULL,
  age_at_sight_sec INTEGER,
  birth_mc       REAL NOT NULL,          -- USD mc at stamp = entry basis
  score          REAL NOT NULL,          -- measured-2x%% estimate (scoreBirth)
  band           TEXT NOT NULL,          -- 'core' 5-8k | 'lower' 3-5k
  regime_hot     INTEGER NOT NULL,       -- UTC 00-06 (F2)
  dev_prior      INTEGER,                -- creator launches before this one (F5)
  mc3m           REAL,                   -- ~3min tape read (F4), best-effort
  momentum       TEXT,                   -- hot|warm|flat|down|untracked
  peak_mc        REAL,
  peak_mult      REAL,
  outcome        TEXT,                   -- '2x'|'1_5x'|'flat'|'untracked' (graded >=6h)
  outcome_ms     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_fastlane_sighted ON fastlane (sighted_ms DESC);
CREATE INDEX IF NOT EXISTS idx_fastlane_outcome ON fastlane (outcome);
