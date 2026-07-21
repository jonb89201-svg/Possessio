// Council Signer MCP — the reproducible AI->seat-key voting + communication
// bridge (SPEC_CouncilSigner_v3). Voting-only + ledger read/write. The tool set
// below is the ENTIRE surface: there is no arbitrary tx, no transfer/approve, no
// raw call, no re-bind, and NO council_burn (§2, §7). The Treasury gate underneath
// bounds the worst case to a bad vote, never a lost cent (§3).
//
// NON-PROVEN end-to-end in the sandbox: the on-chain submit (propose/approve) and
// the ledger fetch are network-blocked here. The SCOPING + signing + preimage
// logic is unit-proven (test/*.test.mjs); the live path is device-proven.
"use strict";
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");
const crypto = require("crypto");

const cfg = require("./config");
const signer = require("./signer");
const feed = require("./feed");
const { proposalHash } = require("./preimage");

const binding = cfg.loadBinding();

const ok = (o) => ({ content: [{ type: "text", text: cfg.redact(o) }] });
const fail = (e) => ({ content: [{ type: "text", text: cfg.redact("refused: " + ((e && e.message) || String(e))) }], isError: true });
const randNonce = () => BigInt("0x" + crypto.randomBytes(32).toString("hex")).toString();

const server = new McpServer({ name: "council-signer", version: "0.1.0" });

// read-only: the binding (NEVER the key) + optional on-chain proposal status
server.tool("council_status", "The seat binding, plus on-chain status for a proposalHash if given.",
  { proposalHash: z.string().optional() },
  async ({ proposalHash: ph }) => {
    try {
      const base = { seat: binding.seatAddress, hook: binding.hookAddress, chainId: binding.chainId };
      return ok(ph ? { ...base, status: await signer.status(binding, ph) } : base);
    } catch (e) { return fail(e); }
  });

// propose: derive the hash from (amount, metadata), PUBLISH the preimage to the
// ledger (F3 — binding AND publication, never one without the other), then submit
// proposeInvent. Proposing without publishing is theater (§4/F3), so it can't be
// done here — the two are one tool.
server.tool("council_propose", "Publish a proposal preimage to the ledger and submit proposeInvent.",
  { amount: z.string(), metadata: z.string().default("0x") },
  async ({ amount, metadata }) => {
    try {
      const ph = proposalHash(binding.hookAddress, amount, metadata);
      await feed.post(binding, JSON.stringify({ hook: binding.hookAddress, amount, metadata, proposalHash: ph }), "proposal", ph);
      const tx = await signer.proposeInvent(binding, ph);
      return ok({ proposalHash: ph, published: true, tx });
    } catch (e) { return fail(e); }
  });

server.tool("council_approve", "Submit approveInvent directly (seat pays gas).",
  { proposalHash: z.string() },
  async ({ proposalHash: ph }) => { try { return ok(await signer.approveInvent(binding, ph)); } catch (e) { return fail(e); } });

server.tool("council_approve_by_sig", "Sign an EIP-712 approval; a relayer submits it (seat pays no gas).",
  { proposalHash: z.string(), expiry: z.string() },
  async ({ proposalHash: ph, expiry }) => { try { return ok(await signer.approveBySig(binding, ph, expiry)); } catch (e) { return fail(e); } });

server.tool("council_sign_statement", "Sign a statement (EIP-712 attribution). SIGNS, NEVER submits.",
  { text: z.string() },
  async ({ text }) => { try { return ok(await signer.signStatement(binding, text, randNonce())); } catch (e) { return fail(e); } });

server.tool("council_post", "Sign a statement and commit it to the council ledger.",
  { text: z.string() },
  async ({ text }) => { try { return ok(await feed.post(binding, text, "statement", null)); } catch (e) { return fail(e); } });

server.tool("council_read_feed", "Read council ledger messages newer than {since} (ms epoch).",
  { since: z.number().default(0) },
  async ({ since }) => { try { return ok(await feed.read(binding, since)); } catch (e) { return fail(e); } });

if (require.main === module) {
  server.connect(new StdioServerTransport());
}
module.exports = { server, binding };
