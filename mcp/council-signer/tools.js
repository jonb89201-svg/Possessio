// The council tool surface, single-sourced. BOTH transports — stdio (`server.js`)
// and remote HTTP (`remote.js`) — register the SAME seven tools through here, so
// the sandbox (§2, §7) is identical no matter how the connector is reached. There
// is no arbitrary tx, no transfer/approve, no raw call, no re-bind, and NO
// council_burn. Extracting this changes the wiring, never the surface: the
// adversarial test still greps `server.js` for the tool names, and this file is
// the one place they are declared.
"use strict";
const { z } = require("zod");
const crypto = require("crypto");

const cfg = require("./config");
const signer = require("./signer");
const feed = require("./feed");
const { proposalHash } = require("./preimage");

const ok = (o) => ({ content: [{ type: "text", text: cfg.redact(o) }] });
const fail = (e) => ({ content: [{ type: "text", text: cfg.redact("refused: " + ((e && e.message) || String(e))) }], isError: true });
const randNonce = () => BigInt("0x" + crypto.randomBytes(32).toString("hex")).toString();

// Register the entire council surface on an McpServer, bound to one seat. The
// SAME `binding` object is closed over by every tool — one seat per server, always.
function registerTools(server, binding) {
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

  return server;
}

module.exports = { registerTools, randNonce };
