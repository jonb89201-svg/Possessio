-- 0015: POST-GRADUATION TRACKING (RATIFIED — Architect, 2026-07-12).
--
-- The machine went blind at the 2:00 bell / graduation while coins kept
-- running (DAYNA laddered at $10.6k then ran to $26k; RUNNER; caaaa). This
-- follows ANY flagged coin — early OR §1 candidate — onto DexScreener after it
-- graduates and records its running post-grad PEAK, so the full journey is in
-- the ledger instead of only witnessed live. Feeds: the feed's "still running"
-- line, the cycle-value research (how much runs after we exit), and the honest
-- record of what the method left on the table.

-- Running post-graduation peak MC (max seen on DEX after graduation).
ALTER TABLE candidates ADD COLUMN dex_peak_mc REAL;

-- earlies gain the DEX-tracking column set (mirrors candidates 0008) so a coin
-- that laddered/exited in §0 is still followed through its whole DEX life.
ALTER TABLE earlies ADD COLUMN graduated_ms INTEGER;
ALTER TABLE earlies ADD COLUMN dex_mc      REAL;
ALTER TABLE earlies ADD COLUMN dex_peak_mc REAL;
ALTER TABLE earlies ADD COLUMN dex_liq_usd REAL;
ALTER TABLE earlies ADD COLUMN dex_vol_h1  REAL;
ALTER TABLE earlies ADD COLUMN dex_last_ms INTEGER;
