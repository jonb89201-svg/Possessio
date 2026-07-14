# POSSESSIO - State of Play

**Source of truth:** this repo, branch `main`. Verify claims against the
repo, never against a prose description. Verified against `main@a3146eb`.

## Seats + relay
- **Claude Code (repo seat)** - repo + deploy tooling. **Sole writer to
  the repo.** Sandbox raw egress still allowlist-blocked (verified
  2026-07-06: Jupiter, DexScreener, Solana RPC, even quiknode.pro all
  403 at the gateway), but the seat now holds live MCP connectors:
  **Base MCP read plane** (read-only eth_call / JSON-RPC on Base +
  major EVM chains - live-chain EVM reads now work from this seat),
  QuickNode MCP management plane (endpoint admin/metrics), Cloudflare
  MCP. Solana / Jupiter paths remain unreachable from the sandbox -
  device-verify runs stay with the MCP seat or the Architect's
  terminal.
- **MCP seat (new chat)** - full internet + MCP tooling (Base, QuickNode,
  Cloudflare connectors). Live-chain queries, cast calls, device-verify
  runs, DexScreener/Jupiter access. Finds and proves; does NOT write the
  repo - fixes route to the repo seat as sourced statements.
- **Code Integrity seat** - council audit, cold-seat review,
  verify-by-artifact.
- **Architect** - the relay; holds ALL keys + the Cloudflare and Base
  Build dashboards. Every signature is the Architect's until a ratified
  key ceremony says otherwise.

New MCP seat onboarding: read this file + RULEBOOK_TradingAgent.md, then
prove your network: (1) curl a Jupiter quote (public.jupiterapi.com),
(2) cast call the live Payments 0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91
(getUSDCBalance / getTreasuryGauge / executedUpkeepCount - closes the
console-compat probe), (3) run node mcp/xtrade/scripts/deviceverify.js.
RPC URLs come from environment variables, never from the repo.

**Console-compat probe CLOSED (2026-07-06, repo seat via Base MCP):**
read-only eth_call against live Payments
0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91 on Base (block ~48,262,912):
`getUSDCBalance()` = 0, `getTreasuryGauge()` = 320587280895694 wei
(~0.00032 ETH-equiv), `executedUpkeepCount()` = 0. All three selectors
(`3cfd1ccc` / `2e23acc4` / `351dab15`) confirmed present in the deployed
runtime bytecode via eth_getCode. Onboarding items (1) Jupiter quote and
(3) deviceverify.js still cannot run from this sandbox (egress blocked);
device-verify remains CLOSED on the Architect's 2026-07-05 terminal run.

**Protocol (the codified lesson):** one writer to the repo (Claude Code).
The other seat verifies live and reports through the relay; changes land
through Claude Code. One diagnostic path at a time. This is the structural
fix for the "two seats edited the same file into two different things"
failure - see `STATEMENT_console_markets_final.md`.

## Console - LIVE
- **Deploy:** Cloudflare Worker `possessio`, **git-connected to `main`**,
  runs `worker/index.ts` via `wrangler.jsonc`: routes `/api/*` (the
  testnet drip endpoint) and serves `./public/` for everything else
  (assets-first — asset hits never reach the script). Every push to
  `main` auto-rebuilds. `possessio.jonb89201.workers.dev` live; `possessio.io`
  apex is the last dashboard step (no www).
- **`public/index.html` (v0.5.0), top to bottom:** header (brand, Pre-deploy
  tag, chain select Base/Ethereum L1, Connect Wallet / Launch / Markets,
  wallet+chain pills, v0.5.0) -> Treasury card (total, Liquid/Earning,
  USDC/cbETH/Morpho positions with send) -> dynamic contract tabs + panels
  -> Launch rail (4-step wizard, **PREVIEW**: FACTORY=null, deploy disabled,
  no address ever) -> footer + MIB DBG panel (dev tool).
- **Markets = SETTLED CANONICAL (`main@a3146eb`):** the Markets button opens
  a chooser -> **Base / Solana** -> DexScreener in a new tab. No bubblemap,
  no in-console swap. `public/markets.html` retired. No further Markets
  patches without a new explicit ratification.
- **Preview-safe:** the site cannot deploy or charge anything until the wave
  sets the factory address.
- **LIVE on possessio.io (2026-07-05):** custom domain attached via
  `wrangler.jsonc` routes (config-as-code); Base Build **registered +
  domain-verified** (`base:app_id` meta found on the live homepage;
  "Welcome, possessio.io"). Mini-app scaffold shipped: `.well-known/
  farcaster.json` (accountAssociation awaiting the Architect's signature),
  production art (icon-1024/splash-200/og), guarded `sdk.actions.ready()`
  splash dismiss, `fc:miniapp` embed meta.

## Trading agent - `mcp/xtrade/`
- **Governance:** `RULEBOOK_TradingAgent.md` v1.0 (RATIFIED);
  `SPEC_CrossChainTradingMCP.md` v0.2.
- **v1 scope:** pump.fun / Solana, Jupiter backend. **Farcaster / Bankr rail
  DEFERRED (RULEBOOK Sec7)** - not built.
- **Built:** pure constitution modules, **19/19 unit tests pass** (offline).
  `build` mode always on (unsigned tx, Architect signs); `hot` mode OFF,
  triple-gated, and locked until the wave's key ceremony makes a dedicated
  trading wallet.
- **DEVICE-VERIFIED (2026-07-05, ~20:55, Architect's terminal):**
  `scripts/deviceverify.js` full run against live Solana (QuickNode RPC)
  + Jupiter via `public.jupiterapi.com` - `RESULT: PASS - live
  quote->build path works. Adapter is real.` Verified-by-artifact by the
  Code Integrity seat (terminal screenshot), relayed by the Architect.
  Still open beyond this: nothing until the wave; hot-mode stays locked
  behind the key ceremony. Note: the public Jupiter mirror injects ~20bps
  platform fee - account for it in net returns (RULEBOOK Sec5) before
  live trading.

## Open items, by lane
- **Code Integrity (RPC/Base):** none blocking - device-verify CLOSED.
  Ad-hoc live-chain checks as needed.
- **Claude Code (repo/deploy):** paste the account-association fields into
  `farcaster.json` when the Architect signs; final push. Otherwise ratified
  changes only. `mcp/solana-mcp/` (2026-07-06): own remote read-only
  Solana+Jupiter MCP worker (capability-URL auth, read-method allowlist,
  10/10 offline tests) - **RATIFIED, read-only-by-design affirmed as the
  design** (`STATEMENT_solana_mcp_ratified.md`; the "Solana EYE" - gate 1
  of 3, ungated). Deploy is the Architect's terminal, not this sandbox
  (no CF credential here; api.cloudflare.com egress-blocked - verified).
  Once connected: run the Solana proofs, close onboarding item (1).
  Cleanup (non-blocking): run the Base App migration skill
  (`npx skills add base/skills`) - Base App dropped the Farcaster-manifest
  model 2026-04-09 (now standard web app + wallet).
- **Architect:** (1) the SIGNATURE - now at **dashboard.base.org**
  (base.dev renamed; the old preview URL 404s) > Preview > Account
  Association > possessio.io > sign > send the three fields; (2) the
  PUBLISH - post
  possessio.io in Base App when ready (preview-mode vs factory-live is
  the Architect's call); (3) **the WAVE** - key ceremony, Monday. The only
  big item left; it gates the factory address AND hot-mode (and per the
  ratification: the wave gates EVM HANDS only - not the Solana eye, not
  Solana hands; three doors, three keys). (4) deploy `mcp/solana-mcp`
  from the Architect's terminal (two `wrangler secret put` + one
  `wrangler deploy`, ~2 min - see `mcp/solana-mcp/README.md`), smoke-test
  `/health`, then add the custom connector ONCE at
  claude.ai/settings/connectors when clear-headed - ungated, no rush.

## x402Core - testnet deploy lane (WO 2026-07-06, ratified placeholders)
- **Ratified TESTNET placeholder constructor values** (behavior-visible,
  NOT production economics - DoD #22 stays open as its own pre-freeze
  gate): `OPERATIONAL_CAP=100e6`, `VELOCITY_HALFLIFE=3600`,
  `ABSOLUTE_FLOOR=10e6`, `FLOOR_PER_UNIT=1e6`, `dustFloor=1e6`.
  DEPLOYMENT_FEE is a FACTORY concern - deliberately not wired on core.
- **Built:** `script/DeployX402Testnet.s.sol` (Base Sepolia; USDC
  0x036CbD53842c5426634e7929541eC2318f3dCF7e verified live via eth_call:
  symbol/decimals/version "2"/authorizationState - EIP-3009 present;
  3-distinct-address pre-check mirroring the line-345 valve guard;
  declared TWO-LEAF test merkle root computed in-script from env leaves -
  single-leaf is structurally unusable, register() rejects empty proofs)
  + `test/PossessioX402CoreTestnet.t.sol` (dual-mode: offline mock
  EIP-3009 / Base Sepolia fork via X402_FORK_RPC) +
  `test/X402TestnetMocks.sol`.
- **Proven offline in-sandbox (npm forge 1.7.1 + WASM solc 0.8.35 shim):
  10/10 PASS** covering WO items DoD #1, #9, #13, #14 (+fuzz), #17, #18,
  #19 (+fuzz), #23. Remaining for the Architect's terminal: the actual
  `--broadcast` deploy + the same suite with X402_FORK_RPC set (fork
  proof against real USDC), tee'd per the WO.
- **Explicitly deferred (held, per WO):** #22 real calibration;
  channel-registry governance; reprice cooldown. Testnet proves the
  machine, not the numbers.

## Testnet launch pool + drip (HANDOFF_testnet_pool.md, landed 2026-07-06)
- **Compiled + green in-sandbox (Codebyte Law satisfied): 16/16** -
  `src/PossessioTestnetLaunchPool.sol` + tests + deploy script landed.
  Two repo-side fixes, contract byte-identical to the handoff: EIP-55
  casing on the Base Account constant (same bytes) and a setUp
  `vm.warp(1_000_000)` (Foundry's ts=1 default made FRESH addresses hit
  CooldownActive - test-env artifact only, impossible on real chains).
- **Worker wired:** `worker/index.ts` (router; assets-first, console
  paths untouched) + `worker/drip-endpoint.ts` (as handed off) +
  `wrangler.jsonc` (main, ASSETS binding, DRIP_LIMITS KV
  49f2f2c858424605a9e90efc11e5e5f7, vars incl. POOL_ADDRESS placeholder
  -> endpoint answers POOL_NOT_DEPLOYED until filled). GET on the drip
  route returns pool config for the console info layer. Bundle
  dry-run-verified (viem in, 694KiB->143KiB gz).
- **Console:** TestnetFuel v1.0 injected module - on the Testnet rail's
  Deploy step (84532, wallet connected via eth_accounts, never prompts):
  low balance (<0.005 ETH gas / <100 USDC fee) -> "Fuel from pool" ->
  POST drip eth-then-usdc -> poll -> LaunchRailLive.init() re-check.
  Bilingual info (plain face + tech layer naming pool/stipend/cooldown);
  honest error passthrough (POOL_EMPTY / COOLDOWN_ACTIVE / ...).
- **Remaining (Architect):** throwaway operator key; `wrangler secret
  put TESTNET_OPERATOR_PK`; deploy pool (any funded testnet key - holds
  no role after); fill POOL_ADDRESS var; owner enable
  `setTokenStipend(USDC, 100e6)` from the Base Account; point faucets
  at the pool. Open for ratification: stipend/cooldown defaults
  (0.02 ETH / 100 USDC / 12 h). Full-suite certification run stays on
  the Architect terminal per GATE 5.

## Radar sell-side + fuel computer (SESSION_LEDGER_20260706, landed 2026-07-06)
- **Live D1 VERIFIED by read-back** (`possessio-radar-ledger`
  e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde): exactly 4 tables (births,
  sessions, spends, trades) + 6 indexes; `spends` DDL matches
  migration_0002 byte-for-byte. Recorded as `radar/schema.sql` (the
  authored mirror later replaced the original `schema.live.sql`
  read-back copy) + `radar/migrations/0002_spends.sql`.
- **VERIFY-FIRST catch:** the handed-off toll snapshot named `x402-hono`
  (v1) - that package is DEPRECATED (security patches only). Current
  official stack is x402 v2: `@x402/hono` 2.17.0 + `@x402/core` +
  `@x402/evm`; API verified from the package's own README/types
  (CAIP-2 networks, x402ResourceServer + HTTPFacilitatorClient, default
  facilitator https://facilitator.x402.org).
- **`radar/` worker COMPILED + acceptance 5 and 7 PROVEN in-sandbox:**
  own worker (possessio-radar), real @x402 middleware wired
  (nodejs_compat), D1-bound, bundle dry-run green. Local run: all three
  routes 200 + `x-possessio-toll: TOLL_NOT_ARMED` while sink is zero
  (acceptance 5); planted `watching` row leaked NOWHERE (acceptance 7 -
  the product boundary held). Acceptance 6 (armed 402 -> paid 200 ->
  on-chain settlement) needs the facilitator + a funded x402 client:
  Architect terminal.
- **Landed:** SESSION_LEDGER_20260706.md, FUEL_COMPUTER_SPEC.md,
  `fuel.config.json` (spec schema verbatim; ceilings/prices remain OPEN
  proposals - ledger OPEN item 5).
- **WATCHER landed + locally proven (2026-07-06, RADAR_HANDOFF):**
  `radar/watcher.ts` (jobs verbatim from the handoff) + cron trigger +
  vars; `radar/schema.sql` (authored mirror) replaces the read-back
  copy. Sandbox proofs: bundle green; local cron tick via
  `--test-scheduled` ran both jobs zero-crash; birthScan idle gate held
  (PUMPFUN_FEED_URL empty); discoveryScan's EXPIRY branch executed for
  real (planted >24h watching row flipped to 'expired', last_checked_ms
  stamped, discovered row untouched); gap-stats gained the
  watching_count aggregate (a count, inside the boundary).
- **Feed VERIFY-FIRST CLEARED (2026-07-06, Architect terminal):**
  frontend-api-v3 /coins route answers 200 ANONYMOUSLY, newest-first,
  shape matches the normalizer (mint / created_timestamp /
  usd_market_cap). PUMPFUN_FEED_URL set in radar/wrangler.jsonc
  (limit=1000 lookback — originally 50, raised via R-3 then R-9 so
  the screen's 10-min tracking window stays covered at burst birth
  rates; includeNsfw=true); normalizer pinned with the
  unit-corruption rule (usd_market_cap only, never SOL-denominated
  market_cap).
- **graduation_dex (migration 0004, 2026-07-07) - the anomaly was
  inventory:** the R-1 predicate fires on the first non-pumpfun pair,
  but some are SIDE-POOLS / LP-at-birth, not true graduations. One-line
  patch records gradPairs[0].dexId at detection so the read segments
  true grads (pumpswap/raydium) from side-pools. Payoff: an LP at birth
  is a strong BAIT marker -> side-pool flag becomes a rug-gate input
  (Rulebook Sec2). Column verified live (births = 16 cols); 6/6 tests
  pass with the graduation_dex assertion; gap-stats gains
  graduation_by_dex. NOTE: running worker is the 15:04Z build - writes
  NULL until redeployed; the 21:21Z read segments non-NULL rows and
  reports the NULL bucket honestly.
- **COLD-SEAT REVIEW: PASS (Code Integrity, from the production
  bundle):** predicate faithful, telemetry write-once, batch writes
  present, 429 yields in, product boundary holding (aggregates only).
  Wipe deviation ACCEPTED as recorded (Architect redirecting his own
  protocol, logged = system working). Token burn CLOSED: a chat-pasted
  credential hit a 30-day two-scope disposable key, rolled within the
  hour - zero blast radius; least-privilege proven by live fire.
- **Sec6 REPO POSTURE - RATIFIED 2026-07-07 (Architect: split, reds
  private): the SENSITIVE method material (`RULEBOOK_TradingAgent.md` +
  every calibration constant) goes PRIVATE; the machine stays public.
  Mechanism DELEGATED to council (Architect: "council has a better
  idea than me"). Options for the council memo: (A) whole repo private
  - owner toggle, simplest, loses the public-machine asset; (B) repo
  public, RULEBOOK + constants relocated to private repo/env config -
  keeps the asset, needs a history removal (collides w/ the new
  force-push guard on main); (C) born-private - new tape-calibrated
  numbers land only in private storage going forward. CAVEAT ON
  RECORD: repo public for hours = today's snapshot assumed crawled;
  going private is forward-looking, not a scrub. NOT YET EXECUTED -
  visibility flip is owner-only + council picks the mechanism first.
  (audit-seat rec:
  SPLIT):** repo is PUBLIC. The machine being public is an asset
  (grants, trust, verifiability); the method's tape-calibrated NUMBERS
  are the one proprietary sliver, and the real risk is BAIT (public
  deterministic entry band + rug-gates hand adversarial creators the
  profile to farm). Repo already public for hours = assume snapshot
  crawled, so a panic-toggle is theater. Recommendation: repo stays
  public (structure only); `RULEBOOK_TradingAgent.md` + every
  calibration constant (stall N, session-gate cutoffs, refined bands)
  born/moved PRIVATE (private repo or env-injected config). Architect's
  signature; the ask is that it is a booked decision, not a default.
- **Sec6 SUPERSEDED - RATIFIED 2026-07-14 (Architect: "d-2 can be
  public"):** the calibration posture is PUBLIC. The 2026-07-07
  go-private split is retired without ever being executed; RULEBOOK,
  the calibration constants in `radar/SPEC_BACKEND.md`/`radar/screen.ts`,
  and the deploy presets stay in the public repo as the booked
  decision. The BAIT caveat above remains on record as an accepted
  risk, not a mitigation debt. Closes AUDIT_20260714 finding D-2. 1,336 poisoned rows deleted
  (DELETE FROM births), zero verified, trades untouched (was empty).
  Executed by the REPO seat on the Architect's direct order - a
  recorded deviation from the wipe protocol's letter (step 3 assigned
  Code Integrity); the Architect may redirect their own protocol.
  Clean-tick verification + the 6h Acceptance-3 read are scheduled
  (15:15Z and ~21:21Z wake-ups). PR #9 (branch -> main) open, merge
  pending at the Architect's hand.
- **REGIME-PAIR READ (2026-07-08 00:45Z):** the Architect's session
  rhythm DIRECTIONALLY CONFIRMED - birth rate rose ~14% (21->24/min)
  right at the stated ~6:30pm CDT pickup. Launch-quality comparison
  deliberately WITHHELD: the pickup cohort is right-censored (young
  tokens haven't matured); re-read after ~1h. BTC regime tape's first
  evening: 138 ticks, quiet risk-on drift to the session high - matches
  the "pickup is news-conditional, news quiet" claim. The window ratio
  = the first measured Session Gate reading (band numbers private,
  Sec6). R-5 discovery kept pace at pickup volume.
- **MATURATION RE-READ (2026-07-08 ~01:52Z):** once the pickup cohort
  fully matured, the earlier lean reversed - launch-QUALITY did NOT
  track the rhythm. The matured pickup window converted at a LOWER
  rate than the lull, coinciding with BTC pulling back off its session
  high. Key generalizable finding for the Session Gate design: **volume
  increase != quality increase.** A gate keyed on activity alone would
  have opened on a worse cohort tonight. BTC context (regime_ticks) is
  necessary alongside birth-rate, not optional. Band numbers private
  per Sec6.
- **SWEET-SPOT READ #1 (2026-07-07 ~22:50Z, lull window) + R-7 LIVE:**
  peak tracking operational - 1,877 births in the ~1h window, 1,636
  peak-tracked (87% coverage), full percentile distribution measured;
  time-to-peak measured for the high-peak cohort (FAST - single-digit
  minutes at the median, strengthening the R-6 WebSocket case). Band
  analysis delivered to the Architect privately (Sec6 - no thresholds
  in this repo). R-7 BTC regime tape flowing (first tick 22:27Z via
  QuickNode Base RPC as a Worker SECRET - read-only key, blast radius =
  RPC quota only; public RPC rejected Worker IPs). Bulk expiry correct
  (0 expired; oldest clean row < 24h). Young-set 1,834 vs 900/tick
  sweep = ~2min sampling cadence. Regime-pair read (pickup window)
  fires ~00:45Z.
- **ACCEPTANCE-3 READ (2026-07-07 ~21:25Z, ~6.2h clean tape) - the
  tape's first honest verdict:**
  - **(1) Graduation rate 1.59%** (126 / 7,926) vs the ~2% lore prior -
    CONSISTENT, and it's a LOWER BOUND (see R-5 below), so true rate
    likely sits right at ~2%. Acceptance 1 PASS.
  - **(2) Segmentation LIVE (graduation_dex working):** TRUE graduations
    = **pumpswap 31** (avg MC ~$25.6k); **meteora 1** = a SIDE-POOL
    ($5k MC, not a $69k migration - the bait population the rug-gate
    wants); **94 NULL** = pre-0004-redeploy, unsegmentable (honest
    bucket). Acceptance 2 PASS.
  - **(3) True-graduation (pumpswap) birth->graduation gap: p25 23min /
    median 41min / p75 56min** vs the ~20-min prior. MEASURED ~2x the
    prior BUT polling-latency-inflated (R-5) - real median sits between
    20 and 41 min; the prior is not refuted, the bias is now understood.
    Winners-only survivorship stat. Acceptance 3 INFORMATIVE (pin after
    R-5).
  - **(4) Curve telemetry median ~15 min** (NOT ~1 cron tick as the
    handoff expected) - this is the R-5 tell: it measures OUR poll
    cadence, not DexScreener indexing.
  - **(5) Expiry 0** (correct at 6h; 24h threshold). **Births/hr 1,277**
    - far above expectations.
- **R-5 FINDING (from the Acceptance read) - discovery throughput
  can't keep up:** at 1,277 births/hr with 24h expiry, the watching set
  heads toward ~30k; at DISCOVERY_BATCH=300/tick x 60 = 18k checks/hr,
  each token is polled only ~0.6x/hr (~once per 1.7h) - but graduation
  happens in the first ~23-56 min. So we UNDER-SAMPLE the graduation
  window: grad rate is a lower bound, gap timing inflated. FIX =
  age-prioritized discovery (poll young tokens where graduation actually
  happens, let old ones age out) - prerequisite for R-4 peak-tracking to
  be meaningful. Not yet built.
- **Session Gate signal:** graduation-rate-per-hour is the measured §0
  regime reading (as data, not feel) - flagged for the council.
- **Repo state at read time:** PR #9 OPEN (mergeable_state clean, not
  merged); `main` protected:true (JohnRules holding); R-3 + graduation_dex
  builds deployed (20:21Z / 15:04Z).
- **R-1/R-2 DEPLOYED (2026-07-07 15:04:44Z, verified):** new predicate confirmed executing in
  production (116 rows carry curve_pair_seen_ms within minutes; only
  R-1 writes it). Pre-wipe tape shows the poison plainly: 1113/1245
  births "graduated" (89% vs the ~2% real prior) - old-predicate false
  discoveries. Production-touch record: 14:54:25Z console re-upload =
  Architect terminal, ACCIDENTAL (deploy chained from repo root again;
  repo seat's chained commands at fault - chains retired), byte-
  identical to production, harmless. OPSEC: the Workers-edit API token
  was pasted into the relay chat 2026-07-07 - treat as BURNED; the
  Architect rolls it after today's terminal work.
- **R-1/R-2 spec record (RADAR_FIX_R1R2 handoff):** first audit found the discovery predicate
  measured DexScreener's ~60s bonding-curve indexing (dexId 'pumpfun'),
  not the market. Fixed: 'discovered' now = GRADUATION (first
  non-pumpfun pair, $69K surface); curve sighting kept as write-once
  telemetry (curve_pair_seen_ms, migration 0003 - applied live by Code
  Integrity, mirrored in radar/migrations/). R-2: batched discovery,
  30 addresses/request (VERIFY-FIRST confirmed vs DexScreener docs;
  300 req/min), DISCOVERY_BATCH=300/tick. gap-stats reframed:
  graduation_rate + median/quartiles birth->graduation + curve
  telemetry. PROVEN offline: 6/6 predicate/batching/429 unit tests
  (radar/test/), bundle green, gap-stats checked against local D1.
  Acceptance 3 REDEFINED (>=6h clean tape): graduation rate vs ~2%
  lore prior; median birth->graduation vs ~20-min prior (winners-only
  survivorship stat); curve telemetry ~= one cron tick. WIPE PROTOCOL:
  (1) Architect deploys from radar/ -> (2) says "deployed" -> (3) Code
  Integrity wipes births live + verifies clean tick -> (4) 6h clean
  tape -> valid Acceptance-3 read. Rulebook Sec1 EXIT-3 amendment
  (STALL 10min, replacing invalid DexScreener-appearance edge-loss)
  drafted in the handoff - Architect ratification pending.
- **RADAR DEPLOYED + TAPE FILLING (2026-07-07 14:17:52Z):**
  `possessio-radar` live (Architect terminal, token auth). First cron
  tick 14:18:33Z captured 50 births, all 'watching', USD mcaps in the
  sane $1.7k-$6.5k birth range (unit rule held). Verified by the repo
  seat reading production D1 directly. Acceptance clock running; 1h
  read = births accumulation + zero errors + first gap_ms median vs
  the ~20-min prior.
- **Production-touch record (2026-07-07):** 14:13:59Z `possessio`
  console worker re-upload = the Architect's terminal, ACCIDENTAL
  (deploy run from repo root instead of radar/ - repo seat's
  instructions at fault). Byte-identical to the PR #7 production code;
  the only failure was the possessio.io route re-attach (token lacks
  zone perms) which the existing route never needed. No drift, no
  leak - recorded so the guard never reads it as unexplained.
- **Radar remaining:** (1) DONE - Architect deployed `possessio-radar`
  (cd radar && npm install && npx wrangler deploy - keyless, no
  secrets). (2) Acceptance 1-3: cron zero-errors 1h, births
  accumulating, first gap_ms median vs the ~20-min prior - the audit
  seat reads the live D1 directly ~1h post-deploy. (3) Acceptance 4
  re-test on live (locally proven). (4) Acceptance 6 armed-toll
  round-trip: Architect terminal. NOTE (ledger item 6): the 23:44:17Z
  production redeploy stands UNCONFIRMED - runbook 0.10 dashboard
  verification is BLOCKING at GATE 0 until the Architect claims or
  disowns it.

## Tunables (ledger-driven, RULEBOOK - not frozen)
Session-gate cutoff 0.65; rug creator-holding 15%; entry-MC band edges
(target ~$10k ratified, band edges NON-RATIFIED).
