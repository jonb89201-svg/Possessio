-- 0016: CONVICTION FORWARD SELF-CHECK.
--
-- The "bucket C" entry hypothesis (curve reserves >=22 SOL + fill-velocity
-- 10-16 at the ~$8k crossing) was DERIVED and TESTED on the same 5.7-day tape
-- — data-snooping risk (Wilson 95% CI on the 18.5% was [10.4%, 30.8%]). The
-- honest test is out-of-sample. This lets the radar grade itself forward:
-- stamp the conviction tag a coin EARNS at its first-8k-crossing tick —
-- immutable, computed only from data available at that instant — then compare
-- it later to the coin's realized peak. Frozen thresholds applied to coins the
-- derivation never saw = real forward validation, accumulating over time.
--
-- Stamped once, in screen.ts, when an early first reaches the band. Graded in
-- /radar/candidates (GO vs field hit-20k rate). No hindsight: the tag uses
-- reserves + tick-count up to the crossing only; the outcome uses peak after.

ALTER TABLE earlies ADD COLUMN conv_tag      TEXT;     -- 'go' | 'slow' | 'bot' | 'thin'
ALTER TABLE earlies ADD COLUMN conv_depth    REAL;     -- curve SOL reserves at the crossing
ALTER TABLE earlies ADD COLUMN conv_vel      REAL;     -- depth / ticks-since-first-seen
ALTER TABLE earlies ADD COLUMN conv_ms       INTEGER;  -- when stamped
ALTER TABLE earlies ADD COLUMN conv_entry_mc REAL;     -- MC at the crossing (for the 2x grade)
