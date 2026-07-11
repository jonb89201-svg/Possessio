-- 0014: the CYCLE ledger (§0 v3 continued). Architect-ratified 2026-07-11:
-- a full ladder before the bell -> wait for a dip (15% retrace, design call)
-- -> re-buy with full proceeds -> next ladder one octave up (L2 14/16/18/20k,
-- L3 22/24/26/28k, "...all the way up"), each level with its own 2:00 bell,
-- capped at the 8min tracking window.
--
-- early_cycles rows: one per level event.
--   outcome 'entry'  = dip re-buy (exit_value NULL)
--   outcome 'ladder' = all four rungs filled (exit_value = 2.21x blend)
--   outcome 'bell'   = level bell rang with rungs unfilled (blended exit)
--   outcome 'window' = 8min cap hit while holding (marked to last MC)

CREATE TABLE IF NOT EXISTS early_cycles (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  token_address TEXT    NOT NULL,
  level         INTEGER NOT NULL,
  outcome       TEXT    NOT NULL,
  entry_mc      REAL,
  exit_value    REAL,
  rungs_filled  INTEGER,
  ms            INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cycles_token ON early_cycles(token_address, level);

ALTER TABLE earlies ADD COLUMN levels INTEGER;        -- cycle depth reached
ALTER TABLE earlies ADD COLUMN compound_mult REAL;    -- Π level multiples (full reinvest)
