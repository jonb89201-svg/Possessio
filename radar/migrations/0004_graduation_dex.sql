-- migration_0004_graduation_dex.sql — segment true graduations from side-pools
-- APPLIED LIVE 2026-07-07 to possessio-radar-ledger
-- (e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde); verified by pragma read-back (16 cols).
-- This file is the repo mirror.
--
-- Why: the R-1 predicate fires on the first NON-pumpfun pair. Most are true
-- graduations (pumpswap/raydium migration at curve completion, ~$69K MC), but
-- some are SIDE-POOLS / LP-at-birth - a token with liquidity that exists at or
-- near birth. graduation_dex records which dex triggered so the read can
-- separate them. Operationally important: an LP at birth is one of the
-- strongest BAIT markers, so this flag becomes a rug-gate input (Rulebook §2).

ALTER TABLE births ADD COLUMN graduation_dex TEXT;
