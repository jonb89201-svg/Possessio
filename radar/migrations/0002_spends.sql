-- migration_0002_spends.sql — the fuel gauge
-- APPLIED LIVE 2026-07-06 to possessio-radar-ledger (e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde).
-- Rationale: sell-side revenue is on-chain (Payments events — never duplicate the chain);
-- off-chain COSTS (inference credits, x402 RPC/tool calls) have no chain record. This table
-- is that record. A self-funding loop that cannot see its own burn is not honest.

CREATE TABLE spends (
  spend_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  leg TEXT NOT NULL CHECK (leg IN ('inference','rpc','tools','other')),
  provider TEXT,           -- 'anthropic' | 'quicknode' | seller domain | ...
  network TEXT,            -- payment network if x402 ('base','base-sepolia','solana',...)
  amount_usd REAL NOT NULL,
  tx_or_ref TEXT,          -- settlement tx hash (x402) or invoice/credit ref (fiat bridge)
  run_id TEXT,             -- agent run correlation id
  note TEXT
);
CREATE INDEX idx_spends_ts ON spends(ts_ms);
CREATE INDEX idx_spends_leg ON spends(leg);
