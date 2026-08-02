-- ROLLBACK for 0028_stop_is_optional.sql. Restores stop_bps to INTEGER NOT NULL.
--
-- PRECONDITION, and it is not optional: no row may have a NULL stop_bps.
--
-- This migration is REVERSIBLE ONLY UNTIL THE FIRST NO-STOP RULE IS WRITTEN.
-- After that it is not, and the reason is the ratification itself: a no-stop
-- rule has no threshold, and there is no value that can stand in for one. Zero
-- is the value that was rejected. 10000 is the sentinel that was rejected. Any
-- number written here would be a threshold the user never signed, on a live
-- funds path — which is worse than being unable to roll back.
--
-- So this does NOT invent a value. The INSERT..SELECT below writes into a
-- NOT NULL column, so if any NULL row exists SQLite aborts the whole script
-- with "NOT NULL constraint failed: desk_rules_old.stop_bps" and the original
-- table is left untouched. The failure is loud, and the data survives it.
--
-- If you hit that abort, the rollback is genuinely unavailable and the correct
-- move is forward: fix the defect on the 0028 schema. Do not hand-fill stop_bps
-- to make this script pass. That would forge a signed instruction.
--
-- Verified 2026-08-01 on a real SQLite database: succeeds on an empty table and
-- on stop-carrying rows; aborts without data loss when a NULL row is present.

CREATE TABLE desk_rules_old (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms       INTEGER NOT NULL,
  owner       TEXT    NOT NULL,
  mint        TEXT    NOT NULL,
  decimals    INTEGER NOT NULL,
  entry_price REAL    NOT NULL,
  target_bps  INTEGER NOT NULL,
  stop_bps    INTEGER NOT NULL,
  status      TEXT    NOT NULL DEFAULT 'open',
  nonce       TEXT    NOT NULL,
  signature   TEXT    NOT NULL,
  exit_kind   TEXT,
  exit_price  REAL,
  exit_sig    TEXT
);

INSERT INTO desk_rules_old
  (id, ts_ms, owner, mint, decimals, entry_price, target_bps, stop_bps,
   status, nonce, signature, exit_kind, exit_price, exit_sig)
SELECT
   id, ts_ms, owner, mint, decimals, entry_price, target_bps, stop_bps,
   status, nonce, signature, exit_kind, exit_price, exit_sig
FROM desk_rules;

DROP TABLE desk_rules;
ALTER TABLE desk_rules_old RENAME TO desk_rules;

-- Same three indexes as 0027, reproduced verbatim. Two are UNIQUE and carry
-- security properties: the replay guard and one-open-rule-per-wallet+coin.
-- Recreating only the status index would silently drop replay protection with
-- no test anywhere observing it — the near-miss that this pair of migrations
-- exists to not repeat.
CREATE INDEX IF NOT EXISTS idx_desk_rules_status ON desk_rules(status, ts_ms);
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_owner_nonce ON desk_rules(owner, nonce);
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_open_position
  ON desk_rules(owner, mint) WHERE status = 'open';
