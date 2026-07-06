# possessio-solana-mcp

Remote MCP server (streamable HTTP) on Cloudflare Workers giving Claude
seats a **read-only** Solana + Jupiter plane, using infrastructure we
already hold: the QuickNode Solana endpoint as a Worker secret, Cloudflare
as the host. No third-party MCP vendor in the read path.

Why it exists: the repo seat's sandbox egress is allowlist-blocked and
claude.ai's QuickNode connector is management-plane only (no chain
queries). A Worker has full egress, so it proxies the two things the
seats actually need:

| Tool                 | What it does                                          |
|----------------------|-------------------------------------------------------|
| `solana_rpc_request` | Allowlisted read-only Solana JSON-RPC via QuickNode   |
| `jupiter_quote`      | Live Jupiter `GET /quote` (read-only, nothing signed) |

Hard limits, by construction:
- **Read-only allowlist** - `sendTransaction` / `requestAirdrop` are not
  forwardable; `simulateTransaction` is the closest allowed (executes
  nothing on-chain). Slippage on quotes capped at 200 bps (LAW ceiling).
- **No keys** beyond the RPC URL, which never leaves the worker.
- **Capability URL auth** - claude.ai custom connectors support
  OAuth-or-nothing (no static bearer header), so the access key rides in
  the URL path. Wrong key = bare 404. Rotate any time by re-setting the
  secret and re-deploying the connector URL.

## Deploy (Architect - holds Cloudflare + the RPC URL)

```sh
cd mcp/solana-mcp
npx wrangler secret put SOLANA_RPC    # paste QuickNode Solana mainnet URL
npx wrangler secret put ACCESS_KEY    # paste output of: openssl rand -hex 32
npx wrangler deploy
```

Smoke test (expects `{"ok":true,"upstream":"ok"}`):

```sh
curl -s https://possessio-solana-mcp.<account>.workers.dev/<ACCESS_KEY>/health
```

## Connect a Claude seat

claude.ai -> Settings -> Connectors -> Add custom connector:

```
https://possessio-solana-mcp.<account>.workers.dev/<ACCESS_KEY>/mcp
```

No OAuth fields - auth is the key in the URL. Treat the full URL as a
secret: share it seat-to-seat through the Architect only, never commit it.

## Rotation / revocation

`npx wrangler secret put ACCESS_KEY` with a fresh value kills every old
connector URL instantly (single-key v1 - rotating logs out all seats at
once). Update the connector(s) with the new URL.

## Offline tests

```sh
node --test "mcp/solana-mcp/test/*.test.mjs"
```

Covers: key gating (404), initialize/protocol negotiation, tools/list,
allowlist rejection of `sendTransaction`, mocked `getHealth` and
`jupiter_quote` round-trips, notification 202, GET 405.
