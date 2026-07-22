// The remote-transport auth gate — fail CLOSED (§3, §5). A stdio connector is
// reached only by the process that spawned it; a REMOTE connector is a URL, so it
// MUST prove who is calling before it will touch the seat key. This gate is the
// single door:
//
//   - refuses to even construct if COUNCIL_MCP_TOKEN is unset or too short — a
//     remote server with no token never starts, so "forgot to set it" can't
//     silently expose the seat;
//   - compares in constant time (crypto.timingSafeEqual on equal-length buffers),
//     so the token can't be recovered a byte at a time;
//   - accepts ONLY `Authorization: Bearer <token>` — no query string (leaks into
//     logs/referers), no cookie.
//
// This gate does NOT widen the on-chain surface: a caller who passes it still only
// reaches the seven scoped tools, and the Treasury gate still bounds the worst case
// to a bad vote (§3). It only decides WHO may drive that seat remotely.
"use strict";
const crypto = require("crypto");

const MIN_TOKEN_LEN = 32; // reject trivially guessable tokens outright

// Build a gate from env. Throws (fail-closed) if the token is missing/weak so a
// misconfigured remote server refuses to start rather than serving open.
function fromEnv(env = process.env) {
  const token = env.COUNCIL_MCP_TOKEN;
  if (!token || typeof token !== "string") {
    throw new Error("COUNCIL_MCP_TOKEN is required for the remote transport — refusing to start an unauthenticated seat signer (fail-closed, §5).");
  }
  if (token.length < MIN_TOKEN_LEN) {
    throw new Error(`COUNCIL_MCP_TOKEN too short (${token.length} < ${MIN_TOKEN_LEN}); use a high-entropy token, e.g. \`openssl rand -hex 32\`.`);
  }
  return makeGate(token);
}

function makeGate(token) {
  const expected = Buffer.from(String(token), "utf8");
  // constant-time equality that also hides length: hash both sides to a fixed
  // width first, so timingSafeEqual always sees equal-length buffers.
  const digest = (b) => crypto.createHash("sha256").update(b).digest();
  const expectedDigest = digest(expected);

  // Extract a bearer token from an Authorization header value. Returns null for
  // anything that isn't exactly `Bearer <token>` (case-insensitive scheme).
  function parseBearer(authHeader) {
    if (typeof authHeader !== "string") return null;
    const m = /^Bearer[ \t]+(.+)$/i.exec(authHeader.trim());
    return m ? m[1].trim() : null;
  }

  // True iff the header carries the exact token. Never throws.
  function check(authHeader) {
    const presented = parseBearer(authHeader);
    if (presented == null) return false;
    return crypto.timingSafeEqual(expectedDigest, digest(Buffer.from(presented, "utf8")));
  }

  return { check, parseBearer };
}

module.exports = { fromEnv, makeGate, MIN_TOKEN_LEN };
