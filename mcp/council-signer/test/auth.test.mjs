// The remote auth gate is the door to a seat key over the network, so it gets the
// same adversarial treatment as the signer: every line here is a way in the gate
// must refuse. No SDK, no network, no key needed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const auth = require("../auth.js");

const TOKEN = "0123456789abcdef0123456789abcdef"; // 32 chars, meets MIN_TOKEN_LEN

test("fail-closed: fromEnv refuses to construct without a token", () => {
  assert.throws(() => auth.fromEnv({}), /required/i);
  assert.throws(() => auth.fromEnv({ COUNCIL_MCP_TOKEN: "" }), /required/i);
});

test("fail-closed: fromEnv rejects a weak (too-short) token", () => {
  assert.throws(() => auth.fromEnv({ COUNCIL_MCP_TOKEN: "short" }), /too short/i);
});

test("fromEnv builds a working gate when the token is strong enough", () => {
  const gate = auth.fromEnv({ COUNCIL_MCP_TOKEN: TOKEN });
  assert.equal(gate.check(`Bearer ${TOKEN}`), true);
});

test("accepts only the exact bearer token", () => {
  const gate = auth.makeGate(TOKEN);
  assert.equal(gate.check(`Bearer ${TOKEN}`), true);
  assert.equal(gate.check(`bearer ${TOKEN}`), true, "scheme is case-insensitive");
  assert.equal(gate.check(`Bearer   ${TOKEN}`), true, "tolerates extra spaces after scheme");
  assert.equal(gate.check(`Bearer ${TOKEN}x`), false, "one extra byte is rejected");
  assert.equal(gate.check(`Bearer ${TOKEN.slice(0, -1)}`), false, "one missing byte is rejected");
  assert.equal(gate.check(`Bearer wrong`), false);
});

test("rejects anything that is not a Bearer header", () => {
  const gate = auth.makeGate(TOKEN);
  assert.equal(gate.check(undefined), false);
  assert.equal(gate.check(null), false);
  assert.equal(gate.check(""), false);
  assert.equal(gate.check(TOKEN), false, "raw token without the Bearer scheme is not accepted");
  assert.equal(gate.check(`Basic ${TOKEN}`), false, "Basic scheme is not accepted");
  assert.equal(gate.check(`Bearer`), false, "scheme with no token");
  assert.equal(gate.check(`Bearer `), false, "scheme with empty token");
});

test("parseBearer never returns the wrong token and check never throws", () => {
  const gate = auth.makeGate(TOKEN);
  assert.equal(gate.parseBearer(`Bearer abc`), "abc");
  assert.equal(gate.parseBearer("garbage"), null);
  // fuzz: no input shape throws
  for (const v of [undefined, null, 0, 1, {}, [], true, `Bearer ${"x".repeat(1000)}`])
    assert.doesNotThrow(() => gate.check(v));
});
