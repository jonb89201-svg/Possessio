// The remote-transport auth gate — fail CLOSED. A stdio connector is reached only
// by the process that spawned it; a REMOTE connector is a URL, so every call must
// prove who is calling before any tool runs. Same door as
// mcp/council-signer/auth.js, with this server's own token:
//
//   - refuses to even construct if XTRADE_MCP_TOKEN is unset or too short — a
//     remote server with no token never starts, so "forgot to set it" can't
//     silently expose the trading agent;
//   - compares in constant time (crypto.timingSafeEqual over fixed-width digests),
//     so the token can't be recovered a byte at a time;
//   - accepts `Authorization: Bearer <token>` or, for clients whose connector UI
//     has no header field (claude.ai web, see remote.js), the token as the path
//     segment after /mcp/. Never a query string (leaks into logs and referers),
//     never a cookie.
//
// This gate does NOT widen what the agent can do: a caller who passes it reaches
// the same six tools as stdio, still build-mode only (RULEBOOK Sec4), still
// capped by LAW. It only decides WHO may drive the agent remotely.
"use strict";
const crypto = require("crypto");

const ENV_NAME = "XTRADE_MCP_TOKEN";
const MIN_TOKEN_LEN = 32; // reject trivially guessable tokens outright

// Build a gate from env. Throws (fail-closed) if the token is missing/weak so a
// misconfigured remote server refuses to start rather than serving open.
function fromEnv(env = process.env) {
  const token = env[ENV_NAME];
  if (!token || typeof token !== "string") {
    throw new Error(`${ENV_NAME} is required for the remote transport — refusing to start an unauthenticated trading agent (fail-closed).`);
  }
  if (token.length < MIN_TOKEN_LEN) {
    throw new Error(`${ENV_NAME} too short (${token.length} < ${MIN_TOKEN_LEN}); use a high-entropy token, e.g. \`openssl rand -hex 32\`.`);
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

  // True iff `presented` is exactly the token. Never throws.
  function checkRaw(presented) {
    if (typeof presented !== "string" || presented.length === 0) return false;
    return crypto.timingSafeEqual(expectedDigest, digest(Buffer.from(presented, "utf8")));
  }

  // True iff the header carries the exact token. Never throws.
  function check(authHeader) {
    const presented = parseBearer(authHeader);
    if (presented == null) return false;
    return checkRaw(presented);
  }

  return { check, checkRaw, parseBearer };
}

module.exports = { fromEnv, makeGate, MIN_TOKEN_LEN, ENV_NAME };
