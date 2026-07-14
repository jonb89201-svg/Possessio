-- 0013: §0 v3 — the ladder. Architect-ratified 2026-07-11:
-- buy the $3,500 crossing; sell 50% @ $6k, 25% @ $8k, 12.5% @ $10k,
-- 12.5% @ $12k (sums to 100%, verified); remainder exits at the age-2:00
-- bell. play_exit_mc becomes the BLENDED exit (sold rungs at rung price +
-- remainder at final MC), so play_exit_mc/first_hit_mc stays the true
-- multiple in every existing query. rungs_filled records ladder progress
-- for exit-design research (question #11).

ALTER TABLE earlies ADD COLUMN rungs_filled INTEGER;
