# SPEC - Cross-Chain Trading MCP (Farcaster-rail)

**Type:** Build spec (draft -> council ratify -> build -> on-device verify)
**Version:** v0.1 - 2026-07-04
**Build seat:** Code Integrity (Claude). NON-PROVEN until it runs against
live endpoints on the Architect's device. The sandbox that drafts this
cannot reach trading APIs (outbound to non-allowlisted hosts is 403), so
NOTHING here is terminal-proven yet - it is architecture for ratification.

---

## 1. Goal

An MCP server that lets the agent (and, through it, the Architect) get
quotes and trade tokens ACROSS chains - the gap the Base MCP leaves
(Base/EVM only). Motivating case: a Solana pump.fun token the Base tools
can't touch. Cross-chain routing is provided by a pluggable backend
adapter; the Farcaster-native rail (Bankr, pending confirmation) is one
such adapter.

## 2. Non-goals

- Not a custody solution. Default posture: the agent NEVER holds keys.
- Not a Farcaster social client (posting casts is a separate MCP - see
  the earlier Farcaster read/write discussion).
- Not an auto-trader. No strategy loop, no unattended execution.

## 3. Execution models - BOTH optional (the ratified requirement)

Selectable per call via a `mode` argument, and gated by server config:

| mode | what it does | key posture | default |
|---|---|---|---|
| `build` | fetch quote + return the UNSIGNED transaction(s): EVM calldata / Solana serialized tx. Architect signs on device. | no key ever touches the agent | ALWAYS ON |
| `hot`   | agent signs with a configured hot key and submits | key in env, agent-held | OFF unless `ALLOW_HOT=1` AND a key is present AND per-call `confirm:true` |

Rules:
- `build` is the Codebyte-safe default and can never be disabled.
- `hot` requires THREE independent gates to fire: (1) `ALLOW_HOT=1` in
  server env, (2) a signer key configured, (3) explicit `confirm:true`
  on the specific call. Missing any one -> refuse, return the `build`
  payload instead.
- Every `hot` trade is bounded by `MAX_NOTIONAL_USD` and `MAX_SLIPPAGE_BPS`
  caps; over-cap -> refuse.
- Keys are read from env vars only, NEVER committed, NEVER logged.

## 4. Tool surface

- `list_supported()` -> chains + backends currently wired + which modes are enabled.
- `search_token(query, chain?)` -> address, symbol, decimals, price (read-only).
- `get_quote(fromChain, fromToken, toChain, toToken, amount, slippageBps?)`
  -> route, expected out, price impact, fees, backend used. Read-only, no auth beyond a data key.
- `build_trade(...same args...)` -> unsigned tx(s) + a human-readable summary. [mode=build]
- `execute_trade(...same args..., confirm)` -> signs + submits. [mode=hot, all gates required]
- `get_status(ref)` -> pending/filled/failed for a returned tx hash or request id.
- `get_portfolio(address, chains[])` -> balances across chains (read-only).

Every mutating tool returns the SAME honest failure contract as the
launch rail: it only claims "nothing moved" where that is provably true
(pre-submission). Post-submission, it returns the tx ref and the truth.

## 5. Backend adapters (pluggable)

- `solana`  -> Jupiter aggregator (quote + swap tx build).
- `evm`     -> 0x Swap API (single-chain) and/or LI.FI (cross-chain EVM).
- `xchain`  -> LI.FI or Relay for EVM<->EVM and EVM<->Solana bridging+swap.
- `farcaster` -> **Bankr (bankr.bot) - PENDING CONFIRMATION.** If this is
  the "Farcaster provides the function" rail, it becomes the intent
  front-end: natural-language trade -> Bankr resolves route across Base +
  Solana. Swappable; the tool surface above is backend-agnostic.

Adapter interface (each implements): `quote()`, `buildTx()`, and
optionally `submit()` (only used by `hot` mode).

## 6. Security model (Codebyte / keys-stay-with-Architect)

1. Default is `build`: verify-before-trust, Architect signs everything -
   consistent with every prior module this session.
2. `hot` is opt-in, triple-gated, capped, and confirm-per-trade.
3. No key material in the repo, in logs, or in tool output.
4. Slippage + max-notional caps enforced server-side, not client-trusted.
5. Read/quote paths need at most a data API key; they never sign.

## 7. Wiring (.mcp.json stub - attaches on the NEXT session, not live now)

```jsonc
{
  "mcpServers": {
    "xtrade": {
      "command": "node",
      "args": ["mcp/xtrade/server.js"],
      "env": {
        "ALLOW_HOT": "0",
        "MAX_NOTIONAL_USD": "250",
        "MAX_SLIPPAGE_BPS": "150",
        "JUPITER_BASE": "https://quote-api.jup.ag",
        "ZEROX_API_KEY": "",
        "LIFI_API_KEY": "",
        "BANKR_API_KEY": "",
        "EVM_RPC_BASE": "",
        "SOLANA_RPC": ""
        // hot-mode signer keys added by the Architect ONLY when enabling hot
      }
    }
  }
}
```

## 8. Verification plan (the Architect's, on device)

- `list_supported()` reflects only wired+enabled backends.
- `get_quote` returns a live route for a known pair on each chain.
- `build_trade` output signs cleanly in the Architect's wallet and lands.
- `hot` refuses with any gate missing; caps refuse over-notional/over-slippage.
- A Solana buy of the pump.fun test token round-trips (quote -> build -> sign -> land).

## 9. Open decisions for the council

1. **Backend confirm:** is the Farcaster rail Bankr, or something else?
   Everything else is ready to build once this is set.
2. Which chains in v1 - Solana + Base only, or add other EVMs day one?
3. Hot-mode caps - starting `MAX_NOTIONAL_USD` / `MAX_SLIPPAGE_BPS` values.
4. Runtime - Node (matches the console tooling) vs Python.
