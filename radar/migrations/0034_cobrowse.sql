-- 0034_cobrowse.sql — Co-Browse (worker/cobrowse.mjs): Browser Run sessions driven over /mcp, watched via Live View.
-- cobrowse_sessions is also the budget ledger: every session's open..close span (plus its keepAlive tail) is summed
-- over a rolling 31 days and new sessions are refused before the included browser-hours could be exceeded.
CREATE TABLE IF NOT EXISTS cobrowse_sessions (
  session_id   TEXT    PRIMARY KEY,     -- Browser Run session id
  target_id    TEXT    NOT NULL,        -- the page target the tools drive
  seat         TEXT    NOT NULL,        -- who opened it (claimed; the tools are token-gated)
  opened_ms    INTEGER NOT NULL,
  last_ms      INTEGER NOT NULL,        -- last tool call (the sweeper closes idle sessions)
  closed_ms    INTEGER,                 -- NULL while open
  close_reason TEXT,
  start_url    TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cobrowse_sessions_open ON cobrowse_sessions(closed_ms);
CREATE TABLE IF NOT EXISTS cobrowse_events (     -- who did what, in order (password text is never stored)
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT    NOT NULL,
  ts_ms      INTEGER NOT NULL,
  who        TEXT    NOT NULL,
  kind       TEXT    NOT NULL,                  -- open | goto | click | type_request | type | close
  detail     TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cobrowse_events_session ON cobrowse_events(session_id, id);
CREATE TABLE IF NOT EXISTS cobrowse_used_acts (  -- an approved typing act runs once
  act        TEXT    PRIMARY KEY,
  session_id TEXT    NOT NULL,
  used_ms    INTEGER NOT NULL
);
