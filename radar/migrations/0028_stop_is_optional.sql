-- "No stop" is an ABSENCE, not a value — Architect ratification 2026-08-01.
--
-- stop_bps was INTEGER NOT NULL, which forces every row to carry a threshold and
-- makes the ratified representation unstorable. A NULL stop_bps now means the
-- rule has no stop at all; a non-NULL value is a real threshold in 1..9999.
--
-- The CHECK is the point. Zero was rejected because zero is the uninitialised
-- value of every integer on this path, so it must be unwritable at the STORAGE
-- layer too, not only at the validator — a second writer, a replayed migration,
-- or a direct insert must not be able to create the row the validator refuses.
--
-- SQLite cannot drop NOT NULL in place, so this rebuilds the table. Exact and
-- safe here: the production table holds ZERO rows (verified 2026-08-01,
-- /api/desk/rules -> {"positions":[]}). The INSERT..SELECT is kept regardless so
-- the migration stays correct if replayed against a populated database.
--
-- CAUTION, learned by nearly getting it wrong: DROP TABLE takes the indexes with
-- it. TWO of the three below are UNIQUE and are load-bearing security
-- properties, not performance hints — the replay guard and the one-open-rule
-- constraint. Recreating only the obvious status index would have silently
-- removed replay protection while every test still passed. They are reproduced
-- here verbatim from 0027, including the partial WHERE clause.

CREATE TABLE desk_rules_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms       INTEGER NOT NULL,
  owner       TEXT    NOT NULL,
  mint        TEXT    NOT NULL,
  decimals    INTEGER NOT NULL,
  entry_price REAL    NOT NULL,
  target_bps  INTEGER NOT NULL,
  stop_bps    INTEGER,                          -- NULL = NO STOP. Never 0.
  status      TEXT    NOT NULL DEFAULT 'open',
  nonce       TEXT    NOT NULL,
  signature   TEXT    NOT NULL,
  exit_kind   TEXT,
  exit_price  REAL,
  exit_sig    TEXT,
  CHECK (stop_bps IS NULL OR (stop_bps >= 1 AND stop_bps <= 9999))
);

INSERT INTO desk_rules_new
  (id, ts_ms, owner, mint, decimals, entry_price, target_bps, stop_bps,
   status, nonce, signature, exit_kind, exit_price, exit_sig)
SELECT
   id, ts_ms, owner, mint, decimals, entry_price, target_bps,
   -- A legacy 0 violates the CHECK and never meant a real threshold; it is the
   -- uninitialised value this ratification exists to abolish. Carry it across
   -- as the absence it always was.
   CASE WHEN stop_bps = 0 THEN NULL ELSE stop_bps END,
   status, nonce, signature, exit_kind, exit_price, exit_sig
FROM desk_rules;

DROP TABLE desk_rules;
ALTER TABLE desk_rules_new RENAME TO desk_rules;

-- The keeper polls for open rules; this is its hot path.
CREATE INDEX IF NOT EXISTS idx_desk_rules_status ON desk_rules(status, ts_ms);

-- Replay is dead at the DB: a wallet may commit any nonce at most once, so a
-- rule harvested from the public GET can never be re-POSTed to resurrect a
-- cancelled position or re-arm one the user closed. UNIQUE — a security
-- property, not an optimisation.
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_owner_nonce ON desk_rules(owner, nonce);

-- One open rule per wallet+coin. Two open rules over one delegate would race,
-- and the keeper would have no principled way to choose which target is the
-- human's real intent. UNIQUE, partial — both parts matter.
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_open_position
  ON desk_rules(owner, mint) WHERE status = 'open';
