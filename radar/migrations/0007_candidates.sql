-- 0007: the screened-candidate feed.
--
-- A candidate = RULEBOOK §1 qualified pick: a 'watching' (pre-DEX) token,
-- 4-7 min old, current curve MC in the entry band (~$10k, the 8-13k the
-- codebase already uses). Paper-only: nothing is ever bought; the row records
-- what the screen selected and what happened next, so the ledger kills or
-- confirms the method (§7).
--
-- RATIFIED 2026-07-11 (Architect, Amendment IV Clause 5): this selection is
-- PUBLIC. It promotes the x402Core autonomous trader and feeds the pool, and
-- shared visibility on a $10k micro-cap is a tailwind toward the target, not a
-- leak. It shows WHICH coins clear the screen, never entry/exit prices or size.
-- This supersedes the older "no watching rows" product boundary for THIS
-- surface only; the paid API routes stay aggregates/discovered-only.
CREATE TABLE IF NOT EXISTS candidates (
  token_address   TEXT PRIMARY KEY REFERENCES births(token_address),
  symbol          TEXT,
  name            TEXT,
  creator         TEXT,
  qualified_ms    INTEGER NOT NULL,        -- cleared the §1 age+MC+pre-DEX screen
  entry_age_sec   INTEGER,                 -- age at qualification
  entry_mc        REAL,                    -- curve MC at qualification
  -- gate status: 1=pass, 0=fail, NULL=not yet evaluated (honest per §7)
  gate_age        INTEGER,
  gate_mc         INTEGER,
  gate_predex     INTEGER,
  gate_rug        INTEGER,                 -- §2 rug: NULL until on-chain data wired
  gate_session    INTEGER,                 -- §0 session: NULL until vol data wired
  -- outcome tracking (§1 exit ladder), paper-only
  peak_mc         REAL,
  peak_ms         INTEGER,
  last_mc         REAL,
  last_tracked_ms INTEGER,
  outcome         TEXT NOT NULL DEFAULT 'live'
                    CHECK (outcome IN ('live','target','stop','graduated','timestop')),
  outcome_ms      INTEGER
);
CREATE INDEX IF NOT EXISTS idx_candidates_outcome ON candidates(outcome, qualified_ms);
