-- migration 0019: dev-reputation paper gate.
--
-- Point-in-time creator history: the count of coins the SAME creator wallet
-- launched STRICTLY BEFORE this coin was born. Knowable at birth — zero
-- lookahead. This is the first pre-entry filter with no hindsight (unlike a
-- rug filter, which needs on-chain data still un-wired: gate_rug).
--
-- Backtest 2026-07-16 (432-trade paper base, candidates.entry_mc/peak_mc/last_mc):
--   fresh devs (1-4 prior)      hit +20% 49.5%  (rug 29.5%)
--   mid       (5-20 prior)      hit +20% 35.2%  (rug 21.1%)
--   serial    (21+ prior)       hit +20% 21.9%  (rug 21.2%)
-- Dev-rep is a strong UPSIDE signal (win rate more than doubles for fresh devs);
-- it is NOT a rug filter (fresh devs run high-variance pump-and-dumps). Stacked
-- with a (hindsight) rug filter the fresh-dev subset ran +6.7%/trade at 58% win.
--
-- gate_dev: 1 = pass (prior <= DEV_REP_MAX_PRIOR, fresh), 0 = fail (serial),
-- NULL = not evaluated (creator missing) — matching the other gate_* columns.
-- PAPER SIGNAL ONLY. Recorded on each qualified candidate for strategy
-- measurement; nothing is traded and no coin is skipped by this gate.
ALTER TABLE candidates ADD COLUMN dev_prior_launches INTEGER;
ALTER TABLE candidates ADD COLUMN gate_dev INTEGER;
CREATE INDEX IF NOT EXISTS idx_births_creator_time ON births(creator, pumpfun_first_seen_ms);
