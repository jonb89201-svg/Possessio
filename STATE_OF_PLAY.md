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
  serves **only `./public/`** via `wrangler.jsonc`. Every push to `main`
  auto-rebuilds. `possessio.jonb89201.workers.dev` live; `possessio.io`
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

## Tunables (ledger-driven, RULEBOOK - not frozen)
Session-gate cutoff 0.65; rug creator-holding 15%; entry-MC band edges
(target ~$10k ratified, band edges NON-RATIFIED).
