# POSSESSIO - State of Play

**Source of truth:** this repo, branch `main`. Verify claims against the
repo, never against a prose description. Verified against `main@a3146eb`.

## Seats + relay
- **Claude Code (repo seat)** - repo + deploy tooling. **Sole writer to
  the repo.** Network-blocked sandbox; also holds QuickNode MCP
  management plane (endpoint admin/metrics - can audit RPC traffic,
  cannot query chains).
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
  changes only.
- **Architect:** (1) the SIGNATURE - Base Build > Account Association >
  possessio.io > sign > send the three fields; (2) the PUBLISH - post
  possessio.io in Base App when ready (preview-mode vs factory-live is
  the Architect's call); (3) **the WAVE** - key ceremony, Monday. The only
  big item left; it gates the factory address AND hot-mode.

## Tunables (ledger-driven, RULEBOOK - not frozen)
Session-gate cutoff 0.65; rug creator-holding 15%; entry-MC band edges
(target ~$10k ratified, band edges NON-RATIFIED).
