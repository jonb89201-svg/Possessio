# POSSESSIO - State of Play

**Source of truth:** this repo, branch `main`. Verify claims against the
repo, never against a prose description. Verified against `main@a3146eb`.

## Seats + relay
- **Claude Code** - repo + deploy tooling. **Sole writer to the repo.**
- **Code Integrity seat** - RPC + Base tooling (Base MCP, chain calls,
  DexScreener API), live-chain verification, device-verify.
- **Architect** - the relay; holds keys + the Cloudflare dashboard.

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

## Trading agent - `mcp/xtrade/`
- **Governance:** `RULEBOOK_TradingAgent.md` v1.0 (RATIFIED);
  `SPEC_CrossChainTradingMCP.md` v0.2.
- **v1 scope:** pump.fun / Solana, Jupiter backend. **Farcaster / Bankr rail
  DEFERRED (RULEBOOK Sec7)** - not built.
- **Built:** pure constitution modules, **19/19 unit tests pass** (offline).
  `build` mode always on (unsigned tx, Architect signs); `hot` mode OFF,
  triple-gated, and locked until the wave's key ceremony makes a dedicated
  trading wallet.
- **NON-PROVEN (device-verify, Code Integrity seat / Architect device):**
  live Jupiter quote -> build -> sign -> land; server end-to-end.

## Open items, by lane
- **Code Integrity (RPC/Base):** device-verify the Jupiter path on live
  Solana; live DexScreener/Base checks.
- **Claude Code (repo/deploy):** file/commit/deploy; docs; ratified code
  changes only. Nothing outstanding on Markets (settled).
- **Architect:** Cloudflare dashboard - confirm the `a3146eb` build is
  green, attach `possessio.io` apex; keys; the wave key ceremony (gates
  hot-mode).

## Tunables (ledger-driven, RULEBOOK - not frozen)
Session-gate cutoff 0.65; rug creator-holding 15%; entry-MC band edges
(target ~$10k ratified, band edges NON-RATIFIED).
