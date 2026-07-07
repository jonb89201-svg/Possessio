-- migration_0006_regime_ticks.sql — the BTC regime tape (R-7)
-- APPLIED LIVE 2026-07-07 to possessio-radar-ledger. Repo mirror.
--
-- Why: memecoin risk appetite rides BTC (the tide). News acts on the market
-- THROUGH BTC, so sampling BTC/USD per cron tick gives the Session Gate an
-- objective, deterministic regime input - no headline interpretation layer.
-- Source: Chainlink BTC/USD on Base (0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F),
-- self-verified on-chain via description() == "BTC / USD". One eth_call/min
-- via public Base RPC from the worker. Correlation btc-trend <-> pump-rate is
-- measured from this table; any threshold that GATES trading is ratified on
-- that evidence, then lives privately (Sec6).

CREATE TABLE regime_ticks (
  ts_ms INTEGER PRIMARY KEY,     -- our clock at sample time
  btc_usd REAL NOT NULL,         -- Chainlink answer / 1e8
  feed_updated_at INTEGER        -- the feed's own updatedAt (staleness check)
);
