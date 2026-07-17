-- migration 0022: market-volume regime series (Architect 2026-07-16 —
-- "there's a time to trade and a time not to; measuring overall DEX volume
-- would be wise"). This is the dollar-volume upgrade the §0 session gate always
-- flagged as future work (sessiongate.ts: births/hour was the interim proxy;
-- "if a keyless stable DEX dollar-volume source is later adopted, swap it in").
--
-- v1 source (intrinsic, zero extra API calls): each screenScan tick already
-- fetches DexScreener m5 volume for every coin on screen (earlies watching +
-- live candidates). We sum it — a real dollar-volume proxy for market heat.
-- Honest scope: it aggregates OUR on-screen set, not all of Solana, so it reads
-- near-zero in a dead market (validated live 2026-07-16: 0 of 2,851 births in 2h
-- reached $8k) and rises as coins pump into the band. n_tracked carries the
-- context (how many coins produced the sum). Trailing-average "trade vs sit-out"
-- regime is computed from this series; candidates join it by qualified_ms.
CREATE TABLE market_vol (
  ts_ms     INTEGER PRIMARY KEY,   -- screenScan tick clock
  vol_m5    REAL NOT NULL,         -- summed DexScreener m5 $-volume across on-screen coins
  n_tracked INTEGER NOT NULL       -- coins on screen this tick (context for the sum)
);
