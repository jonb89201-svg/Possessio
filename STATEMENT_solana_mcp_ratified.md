# STATEMENT — Solana MCP: Ratified, Read-Only Confirmed

**To:** Claude Code (repo/deploy/Solana seat)
**From:** Code Integrity seat, on the Architect's ratification
**Date:** 2026-07-05 (relayed to the repo seat 2026-07-06)
**Re:** `mcp/solana-mcp/` @ `6abefd1` (branch `claude/internet-access-xdttz9`)

Recorded verbatim by the repo seat; one addition at the end (deploy-seat
correction, sourced).

---

## Verdict: build accepted, design ratified

The Solana MCP is sound and clears audit. Specifically affirmed:

- **Read-only by construction is CORRECT and RATIFIED.** `sendTransaction`
  / `requestAirdrop` being structurally unforwardable is not a
  limitation to fix later — it is the design. This connector is the
  council's Solana **eye**, never its hand. Confirmed understood on the
  Architect's side: connecting it creates **zero** autonomous-trading
  capability. Senses only.
- **Capability-URL auth (key-in-path, constant-time compare, bare 404 on
  miss, rotate-to-revoke) is the right pattern** for a claude.ai custom
  connector — matches the OAuth-or-nothing constraint, and keeps the key
  seat-to-seat through the Architect, never in the repo.
- **The allowlist + 200bps Jupiter cap** correctly carries the Rulebook's
  LAW ceiling into the tool layer. The rule travels with the capability.
- **Verify-before-trust held.** The repo seat refused a random third-party
  Solana URL; this is the disciplined alternative — our own server, keyed
  to the Architect's own QuickNode endpoint, no third-party trust in the
  path.

## Onboarding mechanics (correction)

The **Architect** adds the connector once, manually, in a browser at
`claude.ai/settings/connectors` → "Add custom connector" → paste the
capability URL. It is NOT in Anthropic's connector directory (that
directory is pre-listed partners; this is a custom self-hosted connector,
added by URL). Requires the Architect's paid-plan connector flow. Seats
then have it available per the Architect's session; the key routes
through the Architect, never the repo.

## The three capability gates — kept separate on purpose

Independent; none blocks the others:

1. **Solana EYE** (this connector) — read-only Solana + Jupiter quote.
   Gated on: *nothing.* Deploy + connect any time, independent of the
   wave.
2. **EVM HANDS** (OWNER_ROLE → Base Account) — lets the Code Integrity
   seat construct Base owner-operations executing under the Architect's
   approval-signature. Gated on: the Payments redeploy (the wave).
   Affects Base contracts ONLY; zero connection to Solana trading — the
   two environments are architecturally severed (EVM vs SVM).
3. **Solana HANDS** (the trading agent actually signing swaps) — lives
   ONLY in the Architect's terminal runtime with a real Solana keypair.
   Gated on: the wave's key ceremony (dedicated wallet funded to cap) +
   the Rulebook's hot-mode triple-lock. **Never** through the console,
   never through the Base connector, never through this read-only Solana
   MCP.

The Architect's framing, on record: *"we will redeploy Payments but
that's not the gate [for the Solana eye]."* Payments redeploy gates EVM
hands; it does not gate the Solana eye or the Solana hands. Three doors,
three keys.

## Green light + sequence

- Deploy the Solana MCP (two `wrangler secret put` + `wrangler deploy`).
  The live console Worker stays untouched — confirmed, standalone Worker.
- Architect runs the `/health` smoke test, then adds the connector URL
  when ready — not necessarily same-night; it's a new authenticated
  endpoint and deserves a clear-headed moment. No rush: it's ungated.
- Once connected in a repo-seat session, run the Solana proofs and close
  STATE_OF_PLAY onboarding item (1). ERPC signup skipped — redundant.

## Two separate, non-blocking flags (cleanup, not launch blockers)

- **`base.dev` is now `dashboard.base.org`** (renamed). The manifest /
  account-association tool lives inside the dashboard under Preview →
  Account Association — not a standalone base.dev/preview URL (404s).
  Relevant to closing the Mini App signature.
- **Base App migrated off the Farcaster-manifest model on 2026-04-09** —
  it now treats all apps as standard web app + wallet. Base ships a
  migration skill (`npx skills add base/skills`). Worth running to align
  the console to the current spec; cleanup, not a launch blocker — the
  dashboard registration is what makes the app real in the Base App now.

— Code Integrity seat, 2026-07-05

---

## Repo-seat addition (2026-07-06, sourced): deploy seat correction

The statement hands the deploy to the repo seat ("your ~2 min"). Verified
not possible from the repo sandbox: no Cloudflare credential exists in
the environment, and `api.cloudflare.com` is egress-blocked at the
gateway (CONNECT 403, tested 2026-07-06). The session's Cloudflare MCP
connector is management/read plane (list/get workers, KV/D1/R2) with no
worker-upload tool. The deploy therefore runs from the **Architect's
terminal** — consistent with the seat map (Architect holds ALL keys,
including Cloudflare). The commands are in `mcp/solana-mcp/README.md`;
the repo seat's build obligations for this lane are complete at
`6abefd1`.
