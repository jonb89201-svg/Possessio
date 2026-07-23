-- 0026_feed_status.sql — surface the CAUSE of an ingest stall, not just the symptom.
-- The per-minute cron (index.ts scheduled) runs each scan as
-- `ctx.waitUntil(scan(env).catch(console.error))` — so a birthScan/screenScan
-- failure went to the logs and NOWHERE the console could see it (the 2026-07-22
-- ~10h stall was invisible beyond "births frozen"). This table records, per scan,
-- the last time it completed without throwing and the last time it threw (with the
-- message). /api/radar/health reads it so the MIB DEBUG "feed" readout can name
-- which scan is failing and why — the WHY, live, on the phone. One row per scan,
-- upserted; never grows.
CREATE TABLE IF NOT EXISTS feed_status (
  scan        TEXT PRIMARY KEY,   -- 'birthScan' | 'screenScan' | 'btcScan' | …
  last_ok_ms  INTEGER,            -- last completion without a throw
  last_err_ms INTEGER,            -- last throw (compare vs last_ok_ms: err>ok ⇒ failing now)
  last_err    TEXT                -- the throw message (truncated)
);
