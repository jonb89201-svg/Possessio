-- 0008: continuous tracking past the DEX boundary.
--
-- A candidate's life is two phases, two sources:
--   pre-DEX  (bonding curve)  -> pump.fun feed: entry_mc, peak_mc, last_mc
--   post-DEX (graduated)      -> DexScreener:   price, MC, liquidity, volume, 5m, 1h
--
-- §1 still TRADES out at graduation (edge-loss). These columns are for the
-- DISPLAY/intelligence only — they keep updating after the paper trade closes,
-- so the feed shows what the coin did AFTER the edge was gone (did bailing at
-- graduation dodge a dump, or leave a moon on the table?).
ALTER TABLE candidates ADD COLUMN graduated_ms  INTEGER;
ALTER TABLE candidates ADD COLUMN dex_price_usd REAL;
ALTER TABLE candidates ADD COLUMN dex_mc        REAL;
ALTER TABLE candidates ADD COLUMN dex_liq_usd   REAL;
ALTER TABLE candidates ADD COLUMN dex_vol_h1    REAL;
ALTER TABLE candidates ADD COLUMN dex_chg_m5    REAL;
ALTER TABLE candidates ADD COLUMN dex_chg_h1    REAL;
ALTER TABLE candidates ADD COLUMN dex_last_ms   INTEGER;
