# xtrade - Possessio Trading Agent MCP (v0.1, build-mode)

Governed by [`RULEBOOK_TradingAgent.md`](../../RULEBOOK_TradingAgent.md)
(RATIFIED) and [`SPEC_CrossChainTradingMCP.md`](../../SPEC_CrossChainTradingMCP.md).
v1 scope: **pump.fun / Solana, pre-DEX window only.**

## What is terminal-proven vs device-verify

**Proven here** (`npm test` -> 19/19, no network, no keys):
- Sec4 execution model: `build` always on; `hot` downgrades to `build`
  unless all three gates fire.
- Sec3 caps: $2/trade, 10/day, $20/day, 200bps - server-enforced; env
  may only TIGHTEN, never loosen LAW.
- Sec2 F-1: a ticker is a refusal; only a base58 Solana mint passes.
  Rug gate (mint renounced / LP locked / creator <=15%).
- Sec0 session gate (relative volume) and Sec1 method (entry band + the
  four exit triggers with first-to-fire priority).
- Sec5 ledger: append-only, daily stats count only filled trades.

**Device-verify** (network-blocked in the build sandbox, per Codebyte
Law NON-PROVEN until it runs on the Architect's device):
- `adapters/jupiter.js` - live quote + unsigned swap-tx build.
- `server.js` end-to-end MCP wiring (needs `npm install`).

## Run

```
cd mcp/xtrade
npm install          # @modelcontextprotocol/sdk + zod
npm test             # constitution logic, offline
npm run check        # syntax-check server + adapter
```

Wire it via `mcp.json.example` (attaches on the NEXT session).

## Activation is bound (RULEBOOK Sec4)

1. Ratify rulebook - DONE.
2. Build MCP in build-mode - THIS.
3. On-device verify (quote -> build -> sign -> land).
4. Wave key ceremony creates the dedicated trading wallet.
5. Only then is `ALLOW_HOT=1` a discussable sentence.

There is no state in which a key exists and the rulebook does not.
`execute_trade` refuses honestly until step 4.
