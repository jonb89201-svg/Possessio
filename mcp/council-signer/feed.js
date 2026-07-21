// The council ledger client — how a seat reads and writes the shared
// communication ledger (SPEC_CouncilSigner_v3 §8, D1-backed via the console
// worker's /api/council/ledger). A post is an EIP-712-signed statement; the
// worker verifies the signature recovers to the seat before it lands, so every
// row is attributable. Reads are a plain GET.
"use strict";
const crypto = require("crypto");
const { signStatement } = require("./signer");

// A random uint256 nonce per statement — uniquely binds each signature to its
// body (two different messages can never share a signature) and lets the ledger
// dedup.
function randNonce() {
  return BigInt("0x" + crypto.randomBytes(32).toString("hex")).toString();
}

async function post(binding, body, kind, ref) {
  const nonce = randNonce();
  const s = await signStatement(binding, body, nonce);
  const res = await fetch(binding.ledgerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ seat: s.seat, body, nonce, signature: s.signature, kind: kind || "statement", ref: ref || null }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error("ledger POST failed: " + (j.error || res.status));
  return j;
}

async function read(binding, since) {
  const url = binding.ledgerUrl + "?since=" + (Number(since) || 0);
  const res = await fetch(url, { cache: "no-store" });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error("ledger GET failed: " + (j.error || res.status));
  return j.rows || [];
}

module.exports = { post, read, randNonce };
