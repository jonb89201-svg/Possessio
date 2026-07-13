# POSSESSIO Radar — Backend Design Spec

*A real-time detect → screen → track → score → serve pipeline over a
high-volume launch firehose. Currently pointed at Solana / pump.fun memecoins;
the architecture is domain-agnostic (see §11).*

---

## 1. What it is, in one paragraph

Every minute, the radar ingests the newest coins launching on pump.fun, screens
each one against a ratified trading method in stages, tracks every survivor
through its whole life (birth → curve → graduation → DEX run), scores what a
disciplined paper-trader would have made, and serves the live result as a public
web feed. It holds no keys, signs nothing, and trades nothing — it is an
observation-and-scoring machine. The edge it surfaces is *which* coins clear the
screen and *how the money flows into them*, in real time, before a browser on
DexScreener can even see them.

---

## 2. Infrastructure

| Piece | Detail |
|---|---|
| Runtime | Cloudflare Worker `possessio-radar` (dir `radar/`), separate from the console worker `possessio` |
| Database | Cloudflare D1 `possessio-radar-ledger` (`e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde`) |
| Schedule | Cron `* * * * *` — every minute; all jobs run per tick via `ctx.waitUntil` |
| Real-time | Durable Object `PumpTape` (Layer 3) holding a PumpPortal WebSocket — currently observes births only (trade stream gated behind a funded key we deliberately don't pay for) |
| Deploy | `cd radar && npx wrangler deploy`. The repo→Cloudflare connection deploys the **console**, NOT this worker — the radar is always a manual/CI deploy. GitHub Action `radar-refresh` redeploys every 3h to reset the 15s-feed stall (see §10). |
| Secrets | None required for the core. `CLOUDFLARE_API_TOKEN` for deploy is session-local (never persisted). Optional `PUMPPORTAL_API_KEY` unlocks the trade stream. |

---

## 3. Data sources (all free, all keyless)

1. **pump.fun `frontend-api-v3/coins`** (`PUMPFUN_FEED_URL`, `limit=1000`,
   `sort=created_timestamp&order=DESC`) — the birth firehose + live bonding-curve
   state (reserves). The single most important source; it's the origin API, not
   an aggregator.
2. **DexScreener `/latest/dex/tokens/`** — post-graduation MC / liquidity /
   volume, batched 30 addresses/request.
3. **Chainlink BTC/USD on Base** (`eth_call latestRoundData`) — the macro regime
   tape.
4. **PumpPortal WS** (`wss://pumpportal.fun/api/data`) — per-trade data. Dormant
   (needs a funded key); the free `subscribeNewToken` births flow works and
   carries the dev-buy.

**Market cap is computed from first principles**, not trusted from the feed's
convenience field: `MC_sol = virtual_sol_reserves / virtual_token_reserves ×
total_supply / 1e9`, priced by a market-wide `solUsd` derived from
`usd_market_cap / market_cap`. Verified to 14 sig figs against the source.

---

## 4. The per-minute pipeline (`index.ts` → `scheduled()`)

Six independent jobs fire each tick; each is wrapped so one failing never stops
the others:

1. **`birthScan`** (`watcher.ts`) — pull the feed, upsert new coins into
   `births` (newest 500, `ON CONFLICT DO NOTHING`). The bedrock; it never stalls.
2. **`discoveryScan`** (`watcher.ts`) — poll young `watching` tokens on
   DexScreener; flip to `status='discovered'` on graduation, record `gap_ms`
   (birth→graduation) and running `mc_peak_usd`. Expires >24h stale watchers.
3. **`screenLoop` → `screenScan`** (`screen.ts`) — the core screen (detailed §5).
   Runs 4× per tick spaced 15s for 15-second tape resolution.
4. **`dexTrackScan`** (`screen.ts`) — POST-GRADUATION TRACKING: follow every
   flagged coin (early **and** candidate) onto DexScreener after graduation,
   recording a running `dex_peak_mc` — so post-exit runners (DAYNA $10.6k→$26k)
   are captured, not just witnessed.
5. **`btcScan`** (`watcher.ts`) — one Chainlink read → `regime_ticks`.
6. **`pumptape /ensure`** — poke the Durable Object so the WS engine (re)connects.

---

## 5. The screen (`screenScan`, per pass)

1. **Fetch + normalize.** One pump.fun pull → `mcNow` (reserve-derived MC per
   mint), `solNow` (curve SOL reserves per mint), `solUsd` (market SOL price).
   Pushes `solUsd` to the Durable Object.
2. **Screen 0 — early detection.** `watching` coins younger than 4min whose curve
   MC has crossed **$3,500** → inserted into `earlies` (first crossing wins).
   This is the entry the ladder plays.
3. **Early status transitions.** `qualified` when §1 later picks it up; `missed`
   when it ages past 7min without qualifying.
4. **The tape.** One `mc_ticks` row per on-screen coin per pass: `mc`,
   `sol_reserves`, `vol_m5`. The raw series every oscillator is computed from.
   Pruned to 48h.
5. **§0 ladder scoring** (on `ws=0` earlies — see the ratified method §6). Rungs
   at 6/8/10/12k, blended exit, 2:00 bell, `gap` guard. `rungs_filled` is the
   only persisted state; sold value/fraction are pure functions of it.
6. **Screen 1 — §1 qualify.** `watching` coins aged 4–7min with curve MC in the
   **8–13k** band → inserted into `candidates`.
7. **§1 tracking.** Live candidates scored against the exit ladder: `target`
   (≥$20k), `stop` (≤$6k), `timestop` (age ≥10min), `graduated`
   (status flipped). Peak/last tracked each pass.

MC source of record for tracking is **DexScreener** (`fetchDexMc`, the same
pattern discoveryScan proved), with the pump.fun window as fallback — because
the pump.fun newest-N window does not reliably contain a coin past ~5min of age
regardless of `limit` (empirically the server clamps it).

---

## 6. The method (RULEBOOK)

**§0 — the early ladder (the profitable core).** Buy the **$3,500** crossing;
scale out **50% @ $6k · 25% @ $8k · 12.5% @ $10k · 12.5% @ $12k** (sums to 100%;
full ladder ≈ **2.21×**); remainder sells at coin **age 2:00**. Full ladder
before the bell → wait for a **15% dip**, re-buy with full proceeds, run the next
ladder one octave up (14/16/18/20k …) — the *cycle*, compounding, capped at the
8-min tracking window. `gap` = detected already at/past the first rung (no honest
entry existed).

**§1 — the mid-band trade.** Enter 8–13k at age 4–7min; target $20k, stop $6k,
10-min time-stop; edge-loss on graduation.

**The flow gate (the proven entry filter).** Net SOL/min into the curve
(reserves delta). The screen that turns the method from losing to winning.

**Regime layers** (fast → slow): social/name-cluster → birth-rate burst
(attention oscillator) → BTC/SOL beta → scheduled events (e.g. a UFC main event).

---

## 7. Proven results (from the live ledger, this session)

- **Play-everything §0: 0.877× — a net loser.** 78% of crossings are duds
  (0.74× avg, 35% green). Movers (reached the first rung) run **1.37× / 84%
  green**.
- **Flow-screened:** net-flow `>0` → **1.136×**; net-flow `>2` → **1.364×** —
  matching the mover population *before the fact*. The flow gate is the edge.
- The ladder exit alone recovered bell-exits from **0.60× → 0.93×** vs the old
  fixed target. Exit is solved; entry selection (flow) is the remaining lever.

---

## 8. Data model (D1 tables, key columns)

- **`births`** — every coin: `token_address`, `symbol/name/creator`,
  `pumpfun_first_seen_ms`, `api_created_ms`, reserves, `mc_at_birth_usd`,
  `mc_peak_usd/mc_peak_ms`, `status` (watching|discovered|expired), `gap_ms`,
  `graduation_dex`, `curve_pair_seen_ms`, `raw_birth_json` (full payload —
  carries `image_uri`, `twitter`, `reply_count`, `last_trade_timestamp`, …).
- **`earlies`** (§0) — `first_hit_mc`, `age_sec_at_hit`, `peak_mc/peak_ms`,
  `status`, ladder: `play_outcome` (target|exit2m|gap|late), `play_exit_mc`
  (blended), `rungs_filled`, `levels`, `compound_mult`; WS flow-quality:
  `ws`, `t4k_ms`, `buys_hit/sells_hit`, `sol_net_hit`, `uniq_buyers_hit`,
  `top_buyer_share`; post-grad: `graduated_ms`, `dex_mc`, `dex_peak_mc`,
  `dex_liq_usd`, `dex_vol_h1`, `dex_last_ms`; `img`.
- **`candidates`** (§1) — `entry_mc`, `entry_age_sec`, `peak_mc/peak_ms`,
  `last_mc/last_tracked_ms`, `outcome` (live|target|stop|timestop|graduated),
  gate flags, and the full DEX column set incl. `dex_peak_mc`.
- **`mc_ticks`** — the tape: `(token_address, ms)` PK, `mc`, `sol_reserves`,
  `vol_m5`. 48h retention.
- **`early_cycles`** — cycle ledger: one row per level event
  (entry|ladder|bell|window), `entry_mc`, `exit_value`, `rungs_filled`.
- **`regime_ticks`** — `ts_ms`, `btc_usd`, `feed_updated_at`.
- **`sessions`** — daily session-gate readings (`session_date`, `ratio`,
  `gate_pass`).

Migrations `0007`–`0015` (candidates, DEX cols, earlies, ticks, early-play,
WS flow, ladder, cycles, post-grad) — all applied live.

---

## 9. HTTP surface (`x402-toll.ts`)

Built on the official `@x402/hono` middleware — payment verification is never
hand-rolled. While `TOLL_SINK` is the zero address, everything serves free with
an honest `TOLL_NOT_ARMED` header.

- **Public, always free** (marketing for the x402Core execution product):
  - `GET /feed` — the live web page.
  - `GET /radar/candidates` — the feed's data: `early[]`, `live[]`, `recent[]`,
    `earlyPlay[]` tally, `ticks{}`, `tally[]`. Exposes *which* coins clear the
    screen, never entry/exit prices or size.
  - `GET /radar/ws-status` — the Durable Object's connection/parse state +
    raw samples (the VERIFY-FIRST surface).
- **Paid (when armed)** — aggregate/discovered-only, never live `watching` rows:
  `/radar/gap-stats`, `/radar/session-gate`, `/radar/tape`.

**Product boundary:** the paid routes never leak the pre-graduation `watching`
set. The public candidate feed is the one ratified exception (Amendment IV,
Clause 5) — the selection promotes the trader and feeds the pool.

---

## 10. Compliance, limitations, roadmap

**Law.** §4 binding: no keys, no signing, no trading — paper observation only.
Codebyte "if it can't be tested it doesn't exist": every method number is scored
against the ledger, which kills or confirms it.

**Known limitations.**
- The 15-second tape uses a 4× `setTimeout` sub-tick loop that **stalls
  screenScan after ~4h** of runtime (birthScan is unaffected). Mitigated by the
  3-hourly `radar-refresh` redeploy; the permanent fix is a Durable-Object-alarm
  sub-minute driver, not a `setTimeout` loop.
- Flow can only be read ~45s after a crossing at 15s resolution — the fastest
  rockets outrun the gate. True per-second flow needs the PumpPortal trade
  stream (the one paid upgrade with a proven ROI: it makes the winning screen
  near-instant).

**Roadmap.** Trade-resolution flow (buyer-count / whale-share entry filter) ·
score the *cycle* against `dex_peak_mc` · unused free signals in `raw_birth_json`
(trade recency, `reply_count` hype, ATH pump-dump guard) · Twitter/CT narrative
detection · the Session-Gate regime score (is-the-game-on).

---

## 11. What this actually is (the generalization)

Strip the memecoins away and the machine is a **generic real-time opportunity
pipeline**: *ingest a firehose of new entities → screen them against staged
rules → track each through its lifecycle → score outcomes against a paper
strategy → serve a live, decision-shaped view* — all on free-tier serverless
(one Worker, one D1, one cron), holding no credentials.

That shape fits any domain with a high-volume "new thing" stream and a
time-sensitive act-fast decision:

- **Other launch venues** — other chains/launchpads, NFT mints, token listings.
- **Supply-chain / security** — new npm/PyPI packages, new domains, new GitHub
  repos: screen for typosquats/malware markers, track, alert.
- **Marketplaces** — new listings (real estate, autos, tickets, auctions):
  screen for mispriced/underpriced, track to sale, score the "would-have" edge.
- **Jobs / deals / grants** — new postings screened against a fit rule, tracked
  to outcome.
- **News / social** — trending-topic detection via the same birth-rate-burst +
  name-cluster "attention oscillator."

The reusable parts are the **staged screen**, the **outcome ledger** (paper-score
first, prove the edge before risking anything — the Codebyte discipline), the
**flow/volume-as-truth** insight (net accumulation beats gross activity), and the
**decision-shaped display** (live → holding → closed). The domain is a
configuration; the engine is the asset.
