-- 0029_client_errors.sql — the console reports its own failures to a place a
-- seat can read.
--
-- WHY: the Solana buy path was debugged across five rounds by the Architect
-- photographing a toast at 4am on 26% battery. Every round cost a merge, a
-- deploy and a tap, and each screenshot carried one truncated line — the error
-- text was cut at the screen edge more than once. The information existed in
-- the browser the whole time. Nothing carried it anywhere a seat could read it.
--
-- Written by POST /api/desk/error on the console worker (COUNCIL_DB binding),
-- which is PUBLIC and UNAUTHENTICATED by necessity: it must work before any
-- wallet is connected. So it is bounded rather than trusted — 2 KB request cap,
-- 20 reports per IP per minute, fixed fields only, and every column truncated
-- on the way in. There is no arbitrary blob column, deliberately.
--
-- NOT A SECRET SINK. Nothing here should ever carry key material: the client
-- sends an error message, a stack, a stage name and a PUBLIC wallet address.
-- If a credential ever appears in this table that is a defect in whatever put
-- it there, not a reason to widen the table.
--
-- Applied live 2026-08-06 before this file existed, because the console was
-- mid-debug and the table was the instrument needed to continue. Recorded here
-- so the schema is reproducible rather than remembered.

CREATE TABLE IF NOT EXISTS client_errors (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms   INTEGER NOT NULL,
  stage   TEXT    NOT NULL,   -- which path failed: solana-buy, miniapp-init, …
  message TEXT    NOT NULL,   -- the error message, 400 chars
  detail  TEXT,               -- stack or serialised result, 900 chars
  ua      TEXT,               -- user agent, to tell mini app from browser
  wallet  TEXT,               -- PUBLIC address only
  build   TEXT                -- the console build tag, so a fix can be dated
);

CREATE INDEX IF NOT EXISTS idx_client_errors_ts ON client_errors(ts_ms);
