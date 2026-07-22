// Council Signer MCP (stdio) — the reproducible AI->seat-key voting + communication
// bridge (SPEC_CouncilSigner_v3). The tool surface lives in `tools.js` and is shared
// verbatim with the remote transport (`remote.js`): voting-only + ledger read/write,
// no arbitrary tx, no transfer/approve, no raw call, no re-bind, and NO council_burn
// (§2, §7). The Treasury gate underneath bounds the worst case to a bad vote, never a
// lost cent (§3).
//
// NON-PROVEN end-to-end in the sandbox: the on-chain submit (propose/approve) and
// the ledger fetch are network-blocked here. The SCOPING + signing + preimage
// logic is unit-proven (test/*.test.mjs); the live path is device-proven.
"use strict";
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");

const cfg = require("./config");
const { registerTools } = require("./tools");

const binding = cfg.loadBinding();

const server = new McpServer({ name: "council-signer", version: "0.1.0" });
registerTools(server, binding);

if (require.main === module) {
  server.connect(new StdioServerTransport());
}
module.exports = { server, binding };
