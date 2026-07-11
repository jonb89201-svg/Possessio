-- 0010: the VOLUME track on the oscillation tape.
--
-- Architect spec (2026-07-11): entries should key off early volume flow, not
-- just MC. VERIFY-FIRST (our own raw_birth_json): the pump.fun /coins item
-- carries real_sol_reserves — actual SOL in the bonding curve. Its tick-to-
-- tick delta IS net buy flow (buys add, sells drain), i.e. "steady volume
-- increase" = reserves rising across consecutive ticks. DexScreener adds
-- volume.m5 once the curve pair is indexed. Both recorded per tick; all
-- trigger thresholds are derived from this tape later (§7 style), never
-- guessed.

ALTER TABLE mc_ticks ADD COLUMN sol_reserves REAL;  -- SOL units (lamports/1e9), pump.fun window
ALTER TABLE mc_ticks ADD COLUMN vol_m5 REAL;        -- DexScreener rolling 5-min volume USD, once indexed
