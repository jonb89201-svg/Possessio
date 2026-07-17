# SPEC — x402Core, Multi-Chain (the autonomous trader as one agent, many chains)

**Type:** Build spec (draft → council ratify → build → on-device verify)
**Version:** v0.1 — 2026-07-16
**Seat:** Code Integrity (Claude Code, backend session)
**Status:** DRAFT FOR COUNCIL. Nothing here is proven. No contract exists on
Solana yet; the Base x402Core is testnet-proven only. This is architecture for
ratification, not a build order.
**Aligns to:** `RULEBOOK_TradingAgent.md` (RATIFIED), `SPEC_CrossChainTradingMCP.md`
(v0.2), `laws/STATEMENT_solana_mcp_ratified.md` (the read-only-eye ratification +
the three-capability-gate separation), `laws/STATEMENT_console_markets_final.md`.

---

## 1. The idea (Architect, 2026-07-16)

x402Core is not a per-chain trader we rebuild on each chain. It is **one
autonomous-trader identity with a chain-native body on each chain it touches**,
unified by the Farcaster cross-chain rail the foundation already leans on. A
user authorizes the **agent**, once, from their own wallet; the agent executes
on whichever chain the opportunity lives — Base today, Solana next, Ethereum L1
when the anchor settles.

**"Multi-chain contract, not coin."** This is deliberately NOT the bridged-token
pattern (one asset represented across chains). It is a multi-chain *contract/agent*:
the trading logic and identity span chains; the assets stay native.

### The honest physics (must be in the spec so council isn't misled)
EVM and SVM are different virtual machines. There is **no single bytecode** that
runs on both. So "one contract" means, physically:
- **Base body** — `x402Core.sol` (Solidity). Exists; testnet-proven; freeze-gated.
- **Solana body** — an `x402Core` Anchor program (Rust). To build. Architect:
  "pretty much built" — this spec must confirm what exists vs what's left.
- **Shared identity + coordination** — the Farcaster cross-chain rail (see
  `SPEC_CrossChainTradingMCP.md`, Bankr adapter pending confirmation). This is
  what makes the two bodies read as *one agent* to the user and the console.

The council ratified (`solana_mcp_ratified.md`) that **EVM and SVM are
"architecturally severed"** at the trading layer. This spec does NOT undo that —
it proposes a **coordination layer above** two still-severed execution bodies,
not a merge of them. That distinction is the whole safety argument; state it plainly.

## 2. Goal

Let a user, from the public console, connect their own wallet + the x402Core
agent, and — on a coin the radar surfaces — authorize a trade at a chosen target
(**+50% / +25% / +10%**), non-custodially. The auto-strategy keeps running; the
human can enable selected trades on top of it.

## 3. Non-goals (carried from the ratified line — do not relax without council)

- **The console never signs and never holds a key.** It is UI + a request to a
  contract the user already authorized. (Console §4 compliance; `solana_mcp_ratified`
  gate 3: "Solana HANDS… NEVER through the console.")
- **Not custody.** The agent trades under the user's wallet authorization; POSSESSIO
  never holds customer funds or keys.
- **Not a bridged token.** No wrapped-asset issuance.
- **Not an unattended-strategy-with-real-money change** without the Rulebook's
  hot-mode triple-lock and the forward-proof gates (§8) cleared.

## 4. Architecture

### 4.1 The non-custodial connection (the Architect's model)
Console button = a **request**, not a signature. Flow:
1. User connects their wallet on the chain of the coin (Base wallet / Solana wallet).
2. User authorizes the x402Core body on that chain (the wallet↔contract connection
   the Architect describes — an on-chain approval/session, scoped + capped).
3. Tap +50/25/10 → the agent constructs the trade **under that standing
   authorization**; the user's wallet is the security boundary, the contract
   enforces the caps. Console shows status; it never holds the key.

**OPEN (council):** what exactly is the "connection"? An ERC-20/permit-style
approval + a scoped session key? A Base Account owner-op (`solana_mcp_ratified`
gate 2)? A Solana program authority delegation? Each has a different revocation
and blast-radius story. This is the security core — spec it before build.

### 4.2 The two bodies
| | Base body | Solana body |
|---|---|---|
| Language | Solidity (`x402Core.sol`) | Anchor / Rust |
| Status | testnet-proven, freeze-gated | to build ("pretty much built" — confirm) |
| Venue | Base DEX / the Base strategy (NEW — §6) | Jupiter + pump.fun bonding curve |
| Exit at +X% | Base limit/keeper (§5) | Jupiter limit order (post-grad) / keeper (pre-grad) |

### 4.3 Coordination
The Farcaster cross-chain rail carries agent identity + (optionally) intent
routing between bodies. **OPEN (council):** is coordination just shared identity
(each body executes independently, console aggregates), or does intent actually
route cross-chain (a Base-authorized action triggering a Solana execution)? The
former is far safer and probably v1; the latter is the ambitious version.

## 5. The +X% exit — the fork that sets the architecture

- **Non-custodial limit order** (preferred where it exists): user signs a
  limit/target order at entry; it fills itself at +X%; POSSESSIO holds nothing.
  Works where the venue supports it (Jupiter limit orders, post-graduation;
  Base DEX limit).
- **Keeper** (pre-graduation bonding curve, no limit market): a watcher fires the
  sell at target. On Solana this is the **hot lane** — real keypair, terminal
  runtime only, Rulebook triple-lock (`ALLOW_HOT=1` + key + `confirm:true`),
  bounded by `MAX_NOTIONAL_USD` + `MAX_SLIPPAGE_BPS`. **Never the console.**

Council must decide the default per chain and per graduation state.

## 6. The Base strategy is NOT the Solana strategy

Architect: the Base autonomous strategy "will probably be different than what we
have." The validated momentum + fresh-dev + rug + let-winners-run stack was
derived on **Solana pump.fun** microstructure; it does not transfer to Base
assets unexamined. Spec position: **strategy is per-venue**, each earns its own
forward ledger before real money. The multi-chain part is the *agent + rails*,
not a shared strategy.

## 7. Security model (invariants — LOW/CRITICAL if relaxed)

1. Console holds no key, signs nothing (§3).
2. Every execution bounded by on-chain caps: notional + slippage (Rulebook LAW
   ceiling, 200bps Jupiter cap carried into the tool + contract layer).
3. `build`/authorized-request is the default; hot signing is triple-locked and
   terminal-only.
4. Revocation is one action (approval revoke / session expiry / rotate-to-revoke).
5. EVM and SVM bodies stay severed at execution; only identity/intent coordinate.

## 8. Honest gates before any real money (unchanged from this session's findings)

- **Slippage is unmeasured.** The first live (small, human-selected) trades ARE
  the slippage experiment. No size scaling until measured.
- **The strategy is forward-unproven** — backtest edge only (Solana: 65% win /
  +19.6% hindsight-rug ceiling). The live rug gate + this build produce the
  first real numbers.
- **The Solana body is unbuilt/unverified** and the Base body is testnet-only.

## 9. Relationship to existing work

- `x402Core.sol` (Base) — the body we extend, not replace.
- `SPEC_CrossChainTradingMCP.md` (`mcp/xtrade`, 19/19 unit-proven) — the rail/tool
  this contract-level spec sits above; reconcile the two.
- Solana read-only MCP (`solana_mcp_ratified`) — stays the EYE; this spec adds a
  separately-gated HAND, never merging the two capabilities.
- L1 Ethereum anchor — "one Fundstrat email away"; a third body later, out of v1 scope.

## 10. Phased build (proposed — council may reorder)

1. **Ratify this spec** + the §4.1 connection model + the §5 exit default.
2. Confirm the Solana x402Core body's real state ("pretty much built" → gap list).
3. `build`-mode buttons on the console → wallet signs entry (non-custodial),
   SMALL, human-selected → **measure slippage.**
4. Non-custodial limit-order exits where the venue allows.
5. Only then: the keeper/hot lane, triple-locked, for pre-grad auto-exit.
6. Base strategy derivation on its own forward ledger.

## 11. Open questions for council (the decisions this spec needs)

1. The §4.1 connection: approval + session key? Base Account owner-op? Solana
   authority delegation? (The security core.)
2. §4.3 coordination: shared identity only, or cross-chain intent routing in v1?
3. §5 exit default per chain / graduation state.
4. Does the multi-chain agent take ONE authorization or per-chain authorizations?
5. Caps: per-trade notional + slippage for the FIRST live trades (slippage-measure phase).
6. Is the Farcaster/Bankr cross-chain rail confirmed available, or still pending?

---

*Draft by the Code Integrity seat for council review. Refuse-until-supplied on
every §11 item — the build does not start until council answers them.*
