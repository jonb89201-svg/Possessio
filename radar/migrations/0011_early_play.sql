-- 0011: §0 EARLY PLAY — the paper ledger for the early band.
--
-- Architect-ratified (2026-07-11): "4k is right. a target of 8k by 2min...
-- this makes it tradable by an agent." Rule: entry = the $4k crossing
-- (Screen 0's existing trigger), target $8k, exit at coin age 2:00 either
-- way. Crossings after age 2min can't play — scored 'late'. Paper-only,
-- same §4 compliance as everything else: the ledger proves or kills the
-- band BEFORE any agent ever trades it.

ALTER TABLE earlies ADD COLUMN peak_mc REAL;
ALTER TABLE earlies ADD COLUMN peak_ms INTEGER;
ALTER TABLE earlies ADD COLUMN play_outcome TEXT;    -- target | exit2m | late
ALTER TABLE earlies ADD COLUMN play_exit_mc REAL;    -- MC at resolution
ALTER TABLE earlies ADD COLUMN play_outcome_ms INTEGER;
