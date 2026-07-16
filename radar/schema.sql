-- possessio-radar-ledger — §5 tape schema
-- APPLIED LIVE 2026-07-06 to D1 e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde (verified via sqlite_master read-back).
-- This file is the repo mirror. Any change here must be re-applied by migration, never by drift.
--
-- REGENERATED FROM MIGRATIONS 2026-07-14 (AUDIT R-3): the mirror had drifted —
-- it reflected only base + 0003-0005 and was missing everything 0002 and
-- 0006-0017 added (spends, regime_ticks, candidates, earlies, mc_ticks,
-- early_cycles + the later ALTERs). 0018 (2026-07-15) then extended `sessions`
-- with threshold_used + basis for the §0 session-gate writer. This file is the
-- TRUE cumulative schema as of migration 0018, verified by applying base + every
-- migration in
-- order to a scratch SQLite DB and diffing table_info/index sets against this
-- file's output. Convention (unchanged from the 0003-0005 fold): ALTER-added
-- columns are inlined into their CREATE TABLE with a "migration NNNN" note, so
-- physical column order here differs from the live DB (SQLite appends ALTERed
-- columns); names/types/constraints are identical.

-- The radar core. One row per pump.fun birth observed.
-- api_created_ms  = what the feed CLAIMS (its created timestamp)
-- pumpfun_first_seen_ms = when WE first observed it (our clock; substrate-honest distinction)
-- dexscreener_first_seen_ms = first NON-pumpfun pair (R-1, 2026-07-07): the
--   GRADUATION surface ($69K MC), not the bonding-curve index entry. DexScreener
--   indexes the curve itself as dexId 'pumpfun' ~60s after birth (machine
--   latency, recorded separately as curve_pair_seen_ms - migration 0003).
-- gap_ms = dexscreener_first_seen_ms - pumpfun_first_seen_ms  ← the product
CREATE TABLE births (
  token_address TEXT PRIMARY KEY,
  chain TEXT NOT NULL DEFAULT 'solana',
  symbol TEXT,
  name TEXT,
  creator TEXT,
  api_created_ms INTEGER,
  pumpfun_first_seen_ms INTEGER NOT NULL,
  dexscreener_first_seen_ms INTEGER,
  gap_ms INTEGER,
  status TEXT NOT NULL DEFAULT 'watching' CHECK (status IN ('watching','discovered','expired')),
  last_checked_ms INTEGER,
  mc_at_birth_usd REAL,
  mc_at_discovery_usd REAL,
  curve_pair_seen_ms INTEGER,        -- migration 0003: first curve-index sighting (machine latency telemetry)
  graduation_dex TEXT,               -- migration 0004: dex that triggered discovery (true grad vs side-pool; rug-gate input)
  mc_peak_usd REAL,                  -- migration 0005: highest MC observed (R-4: the birth->pump trade window)
  mc_peak_ms INTEGER,                -- migration 0005: timestamp of that peak
  raw_birth_json TEXT                -- valid JSON only: full payload <=4KB, else the slimmed field subset (watcher.ts, AUDIT R-1)
);
CREATE INDEX idx_births_status ON births(status);
CREATE INDEX idx_births_pf_seen ON births(pumpfun_first_seen_ms);

-- §0 Session Gate daily readings. One row per UTC day (session_date PK),
-- recomputed each cadence tick (sessiongate.ts) so today's row is the freshest
-- reading. trailing_vol = the window metric (births/hour, the intrinsic
-- launch-rate volume proxy — see sessiongate.ts + SPEC §5a); avg_7d_vol = its
-- trailing baseline rate; ratio = window/baseline; gate_pass = ratio >=
-- threshold_used. threshold_used + basis added by migration 0018.
CREATE TABLE sessions (
  session_date TEXT PRIMARY KEY,          -- YYYY-MM-DD UTC
  trailing_vol REAL,                      -- window metric: births/hour over the trailing window
  avg_7d_vol REAL,                        -- baseline: births/hour over the trailing 7d
  ratio REAL,                             -- trailing_vol / avg_7d_vol
  gate_pass INTEGER NOT NULL CHECK (gate_pass IN (0,1)),
  notes TEXT,
  recorded_ms INTEGER NOT NULL,           -- our clock at the reading (measured_at)
  threshold_used REAL,                    -- migration 0018: §0 cutoff this reading was judged at (default 0.65, §7-adjustable)
  basis TEXT                              -- migration 0018: what was measured (proxy + window/baseline spans + sample counts)
);

-- migration 0022: market-volume regime series (DEX $-volume, "time to trade vs not").
-- One row per screenScan tick: summed DexScreener m5 volume across on-screen coins.
CREATE TABLE market_vol (
  ts_ms     INTEGER PRIMARY KEY,          -- screenScan tick clock
  vol_m5    REAL NOT NULL,                -- summed DexScreener m5 $-volume across on-screen coins
  n_tracked INTEGER NOT NULL              -- coins on screen this tick (context for the sum)
);

-- §5 The Ledger — every attempt, filled or skipped. Net judges; gross flatters.
-- exit_trigger: 1=TAKE-PROFIT $20K  2=STOP-LOSS $6K  3=EDGE-LOSS (DexScreener appeared)  4=BACKSTOP 45min
CREATE TABLE trades (
  trade_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  token_address TEXT NOT NULL REFERENCES births(token_address),
  chain TEXT NOT NULL DEFAULT 'solana',
  skipped INTEGER NOT NULL DEFAULT 0 CHECK (skipped IN (0,1)),
  skip_reason TEXT,
  session_gate_ratio REAL,
  session_gate_pass INTEGER,
  rug_gate_json TEXT,                     -- per-sub-check pass/fail
  entry_mc_usd REAL,
  entry_price REAL,
  entry_ts_ms INTEGER,
  exit_trigger INTEGER CHECK (exit_trigger IN (1,2,3,4)),
  exit_mc_usd REAL,
  exit_price REAL,
  exit_ts_ms INTEGER,
  gross_return REAL,
  net_return REAL,
  daily_count_at_trade INTEGER
);
CREATE INDEX idx_trades_token ON trades(token_address);
CREATE INDEX idx_trades_ts ON trades(ts_ms);

-- migration 0002: the fuel gauge. Sell-side revenue is on-chain (Payments
-- events — never duplicate the chain); off-chain COSTS (inference credits,
-- x402 RPC/tool calls) have no chain record. This table is that record. A
-- self-funding loop that cannot see its own burn is not honest.
CREATE TABLE spends (
  spend_id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms INTEGER NOT NULL,
  leg TEXT NOT NULL CHECK (leg IN ('inference','rpc','tools','other')),
  provider TEXT,           -- 'anthropic' | 'quicknode' | seller domain | ...
  network TEXT,            -- payment network if x402 ('base','base-sepolia','solana',...)
  amount_usd REAL NOT NULL,
  tx_or_ref TEXT,          -- settlement tx hash (x402) or invoice/credit ref (fiat bridge)
  run_id TEXT,             -- agent run correlation id
  note TEXT
);
CREATE INDEX idx_spends_ts ON spends(ts_ms);
CREATE INDEX idx_spends_leg ON spends(leg);

-- migration 0006: the BTC regime tape (R-7). Memecoin risk appetite rides BTC
-- (the tide); one Chainlink BTC/USD read per cron tick gives the Session Gate
-- an objective, deterministic regime input.
CREATE TABLE regime_ticks (
  ts_ms INTEGER PRIMARY KEY,     -- our clock at sample time
  btc_usd REAL NOT NULL,         -- Chainlink answer / 1e8
  feed_updated_at INTEGER        -- the feed's own updatedAt (staleness check)
);

-- migration 0007: the screened-candidate feed. A candidate = RULEBOOK §1
-- qualified pick: a 'watching' (pre-DEX) token, 4-7 min old, current curve MC
-- in the entry band. Paper-only; the row records what the screen selected and
-- what happened next, so the ledger kills or confirms the method (§7).
-- RATIFIED 2026-07-11 (Architect, Amendment IV Clause 5): this selection is
-- PUBLIC — which coins clear the screen, never entry/exit prices or size.
CREATE TABLE candidates (
  token_address   TEXT PRIMARY KEY REFERENCES births(token_address),
  symbol          TEXT,
  name            TEXT,
  creator         TEXT,
  qualified_ms    INTEGER NOT NULL,        -- cleared the §1 age+MC+pre-DEX screen
  entry_age_sec   INTEGER,                 -- age at qualification
  entry_mc        REAL,                    -- curve MC at qualification
  -- gate status: 1=pass, 0=fail, NULL=not yet evaluated (honest per §7)
  gate_age        INTEGER,
  gate_mc         INTEGER,
  gate_predex     INTEGER,
  gate_rug        INTEGER,                 -- §2 rug: NULL until on-chain data wired
  gate_session    INTEGER,                 -- §0 session: NULL until vol data wired
  -- migration 0019: dev-reputation paper gate (point-in-time, no lookahead).
  dev_prior_launches INTEGER,              -- same creator's launches BEFORE this coin's birth
  gate_dev        INTEGER,                 -- 1=fresh (prior<=DEV_REP_MAX_PRIOR), 0=serial, NULL=no creator
  -- migration 0020: on-chain rug signal (forward-measured). getTokenLargestAccounts.
  top_holder_share REAL,                   -- largest non-curve holder's share of circulating float [0,1]
  -- gate_rug (above) now populated: 1=pass (top<=RUG_MAX_TOP_HOLDER_PCT), 0=whale, NULL=RPC unavailable
  -- migration 0021: validated go-to strategy.
  entry_vel       REAL,                    -- climb velocity into entry = (entry_mc - birth_mc)/age_sec
  strat_take      INTEGER,                 -- 1 = passes full entry filter (momentum band + fresh dev + rug!=fail)
  -- outcome tracking (§1 exit ladder), paper-only
  peak_mc         REAL,
  peak_ms         INTEGER,
  last_mc         REAL,
  last_tracked_ms INTEGER,
  outcome         TEXT NOT NULL DEFAULT 'live'
                    CHECK (outcome IN ('live','target','stop','graduated','timestop')),
  outcome_ms      INTEGER,
  -- migration 0008: continuous tracking past the DEX boundary. §1 still
  -- trades out at graduation (edge-loss); these keep updating for DISPLAY/
  -- intelligence, showing what the coin did after the edge was gone.
  graduated_ms    INTEGER,
  dex_price_usd   REAL,
  dex_mc          REAL,
  dex_liq_usd     REAL,
  dex_vol_h1      REAL,
  dex_chg_m5      REAL,
  dex_chg_h1      REAL,
  dex_last_ms     INTEGER,
  dex_peak_mc     REAL                     -- migration 0015: running post-graduation peak MC
);
CREATE INDEX idx_candidates_outcome ON candidates(outcome, qualified_ms);

-- migration 0009: Screen 0 (early radar). Architect spec (2026-07-11):
-- multi-screen method — Screen 0 = age 0-4min, coin crosses the early band ->
-- early-watch list (the human gets a look BEFORE the machine's §1 window
-- opens). Screen 1 = the existing 4-7min qualify (candidates above).
CREATE TABLE earlies (
  token_address  TEXT PRIMARY KEY,
  symbol         TEXT,
  name           TEXT,
  first_hit_ms   INTEGER NOT NULL,  -- when it crossed the early band
  first_hit_mc   REAL    NOT NULL,  -- MC at the crossing tick
  age_sec_at_hit INTEGER NOT NULL,  -- coin age when it crossed
  status         TEXT    NOT NULL DEFAULT 'watching', -- watching|qualified|missed
  status_ms      INTEGER,
  -- migration 0011: §0 EARLY PLAY — the paper ledger for the early band.
  peak_mc        REAL,
  peak_ms        INTEGER,
  play_outcome   TEXT,              -- target | exit2m | gap | late
  play_exit_mc   REAL,              -- MC at resolution (0013: the BLENDED ladder exit)
  play_outcome_ms INTEGER,
  -- migration 0012: flow-quality columns for WS-detected earlies (pumptape.ts,
  -- Layer 3). Poller-detected earlies leave these NULL (ws=0).
  ws             INTEGER DEFAULT 0, -- 1 = detected by the WS engine
  t4k_ms         INTEGER,           -- create -> crossing, ms (sub-second)
  buys_hit       INTEGER,           -- buy count at crossing
  sells_hit      INTEGER,           -- sell count at crossing
  sol_net_hit    REAL,              -- net SOL flow at crossing
  uniq_buyers_hit INTEGER,          -- distinct buyers at crossing
  top_buyer_share REAL,             -- largest buyer / total buy SOL (whale-spike detector)
  -- migration 0013: §0 v3 ladder progress (sold value/frac are pure functions of it)
  rungs_filled   INTEGER,
  -- migration 0014: the CYCLE headline (dip re-buy, next ladder one octave up)
  levels         INTEGER,           -- cycle depth reached
  compound_mult  REAL,              -- Π level multiples (full reinvest)
  -- migration 0015: post-graduation tracking (mirrors candidates 0008) so a
  -- coin that laddered/exited in §0 is still followed through its DEX life.
  graduated_ms   INTEGER,
  dex_mc         REAL,
  dex_peak_mc    REAL,
  dex_liq_usd    REAL,
  dex_vol_h1     REAL,
  dex_last_ms    INTEGER,
  -- migration 0016: CONVICTION FORWARD SELF-CHECK — the tag a coin earns at
  -- its first-band-crossing tick, immutable, graded later vs realized peak.
  conv_tag       TEXT,              -- 'go' | 'slow' | 'bot' | 'thin'
  conv_depth     REAL,              -- curve SOL reserves at the crossing
  conv_vel       REAL,              -- depth / ticks-since-first-seen
  conv_ms        INTEGER,           -- when stamped
  conv_entry_mc  REAL               -- MC at the crossing (for the 2x grade)
);
CREATE INDEX idx_earlies_status ON earlies(status, first_hit_ms);

-- migration 0009 (continued): the tape. 1-min resolution (the cron tick) is
-- the honest granularity we have; oscillators are computed at read time from
-- this, never stored.
CREATE TABLE mc_ticks (
  token_address TEXT    NOT NULL,
  ms            INTEGER NOT NULL,
  mc            REAL    NOT NULL,
  -- migration 0010: the VOLUME track. real_sol_reserves' tick-to-tick delta
  -- IS net buy flow (buys add, sells drain) — the "steady volume increase"
  -- signal; vol_m5 joins once DexScreener indexes the pair.
  sol_reserves  REAL,               -- SOL units (lamports/1e9), pump.fun window
  vol_m5        REAL,               -- DexScreener rolling 5-min volume USD, once indexed
  PRIMARY KEY (token_address, ms)
);
-- Range queries/prunes on ms alone (created 0009; 0017 re-issued it as a no-op).
CREATE INDEX idx_mc_ticks_ms ON mc_ticks(ms);

-- migration 0014: the CYCLE ledger (§0 v3). One row per level event:
--   outcome 'entry'  = dip re-buy (exit_value NULL)
--   outcome 'ladder' = all four rungs filled (exit_value = 2.21x blend)
--   outcome 'bell'   = level bell rang with rungs unfilled (blended exit)
--   outcome 'window' = 8min cap hit while holding (marked to last MC)
CREATE TABLE early_cycles (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  token_address TEXT    NOT NULL,
  level         INTEGER NOT NULL,
  outcome       TEXT    NOT NULL,
  entry_mc      REAL,
  exit_value    REAL,
  rungs_filled  INTEGER,
  ms            INTEGER NOT NULL
);
CREATE INDEX idx_cycles_token ON early_cycles(token_address, level);
