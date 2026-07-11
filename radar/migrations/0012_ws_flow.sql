-- 0012: flow-quality columns for WS-detected earlies (pumptape.ts, Layer 3).
--
-- Written only by the Durable Object at the $4k crossing, from per-trade
-- data: everything that happened between create and the crossing — the
-- information an agent would decide on. Poller-detected earlies leave these
-- NULL (ws=0), so the two detection layers stay distinguishable in queries.

ALTER TABLE earlies ADD COLUMN ws INTEGER DEFAULT 0;        -- 1 = detected by the WS engine
ALTER TABLE earlies ADD COLUMN t4k_ms INTEGER;              -- create -> $4k crossing, ms (sub-second)
ALTER TABLE earlies ADD COLUMN buys_hit INTEGER;            -- buy count at crossing
ALTER TABLE earlies ADD COLUMN sells_hit INTEGER;           -- sell count at crossing
ALTER TABLE earlies ADD COLUMN sol_net_hit REAL;            -- net SOL flow at crossing
ALTER TABLE earlies ADD COLUMN uniq_buyers_hit INTEGER;     -- distinct buyers at crossing
ALTER TABLE earlies ADD COLUMN top_buyer_share REAL;        -- largest buyer / total buy SOL (whale-spike detector)
