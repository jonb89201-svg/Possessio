-- Architect (2026-08-15, shown screenshots of DexScreener new-pairs listings):
-- a coin whose creator paid DexScreener for a token-info profile (socials/
-- image/website) or an active boost is a distinct, visible-effort signal —
-- separate from the radar's own curve-band qualify. Captured for free off the
-- SAME DexScreener response discoveryScan/dexTrackScan already fetch at
-- graduation and during the 1h post-grad enrichment window; no extra request.
ALTER TABLE births ADD COLUMN dex_paid_profile INTEGER;   -- 1 once info.socials/websites is ever seen non-empty
ALTER TABLE births ADD COLUMN dex_boost_active INTEGER;   -- boosts.active count, last read (0 if none, NULL if never checked)
