-- schema.live.sql — READ-BACK of the live possessio-radar-ledger D1
-- (e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde), pulled via sqlite_master by the
-- repo seat on 2026-07-06. This is the VERIFIED live shape (4 tables,
-- 6 indexes — matches SESSION_LEDGER_20260706), recorded because the
-- original schema.sql artifact lives in the Architect's downloads, not
-- the repo. Use for local dev (`wrangler d1 execute RADAR_DB --local
-- --file schema.live.sql`); the live DB already has all of this.

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

CREATE TABLE sessions (
  session_date TEXT PRIMARY KEY,
  trailing_vol REAL,
  avg_7d_vol REAL,
  ratio REAL,
  gate_pass INTEGER NOT NULL CHECK (gate_pass IN (0,1)),
  notes TEXT,
  recorded_ms INTEGER NOT NULL
);

CREATE TABLE spends (
  spend_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  leg TEXT NOT NULL CHECK (leg IN ('inference','rpc','tools','other')),
  provider TEXT,
  network TEXT,
  amount_usd REAL NOT NULL,
  tx_or_ref TEXT,
  run_id TEXT,
  note TEXT
);

CREATE TABLE trades (
  trade_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  token_address TEXT NOT NULL REFERENCES births(token_address),
  chain TEXT NOT NULL DEFAULT 'solana',
  skipped INTEGER NOT NULL DEFAULT 0 CHECK (skipped IN (0,1)),
  skip_reason TEXT,
  session_gate_ratio REAL,
  session_gate_pass INTEGER,
  rug_gate_json TEXT,
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

CREATE INDEX idx_births_pf_seen ON births(pumpfun_first_seen_ms);
CREATE INDEX idx_births_status ON births(status);
CREATE INDEX idx_spends_ts ON spends(ts_ms);
CREATE INDEX idx_spends_leg ON spends(leg);
CREATE INDEX idx_trades_ts ON trades(ts_ms);
CREATE INDEX idx_trades_token ON trades(token_address);
