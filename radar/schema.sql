-- possessio-radar-ledger — §5 tape schema
-- APPLIED LIVE 2026-07-06 to D1 e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde (verified via sqlite_master read-back).
-- This file is the repo mirror. Any change here must be re-applied by migration, never by drift.

-- The radar core. One row per pump.fun birth observed.
-- api_created_ms  = what the feed CLAIMS (its created timestamp)
-- pumpfun_first_seen_ms = when WE first observed it (our clock; substrate-honest distinction)
-- gap_ms = dexscreener_first_seen_ms - pumpfun_first_seen_ms  ← the product
CREATE TABLE births (
  token_address TEXT PRIMARY KEY,
  chain TEXT NOT NULL DEFAULT 'solana',
  symbol TEXT,
  name TEXT,
  creator TEXT,
  api_created_ms INTEGER,
  pumpfun_first_seen_ms INTEGER NOT NULL,
  dexscreener_first_seen_ms INTEGER,
  gap_ms INTEGER,
  status TEXT NOT NULL DEFAULT 'watching' CHECK (status IN ('watching','discovered','expired')),
  last_checked_ms INTEGER,
  mc_at_birth_usd REAL,
  mc_at_discovery_usd REAL,
  raw_birth_json TEXT
);
CREATE INDEX idx_births_status ON births(status);
CREATE INDEX idx_births_pf_seen ON births(pumpfun_first_seen_ms);

-- §0 Session Gate daily readings.
CREATE TABLE sessions (
  session_date TEXT PRIMARY KEY,          -- YYYY-MM-DD UTC
  trailing_vol REAL,
  avg_7d_vol REAL,
  ratio REAL,
  gate_pass INTEGER NOT NULL CHECK (gate_pass IN (0,1)),
  notes TEXT,
  recorded_ms INTEGER NOT NULL
);

-- §5 The Ledger — every attempt, filled or skipped. Net judges; gross flatters.
-- exit_trigger: 1=TAKE-PROFIT $20K  2=STOP-LOSS $6K  3=EDGE-LOSS (DexScreener appeared)  4=BACKSTOP 45min
CREATE TABLE trades (
  trade_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  token_address TEXT NOT NULL REFERENCES births(token_address),
  chain TEXT NOT NULL DEFAULT 'solana',
  skipped INTEGER NOT NULL DEFAULT 0 CHECK (skipped IN (0,1)),
  skip_reason TEXT,
  session_gate_ratio REAL,
  session_gate_pass INTEGER,
  rug_gate_json TEXT,                     -- per-sub-check pass/fail
  entry_mc_usd REAL,
  entry_price REAL,
  entry_ts_ms INTEGER,
  exit_trigger INTEGER CHECK (exit_trigger IN (1,2,3,4)),
  exit_mc_usd REAL,
  exit_price REAL,
  exit_ts_ms INTEGER,
  gross_return REAL,
  net_return REAL,
  daily_count_at_trade INTEGER
);
CREATE INDEX idx_trades_token ON trades(token_address);
CREATE INDEX idx_trades_ts ON trades(ts_ms);
