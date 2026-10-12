// The remote auth gate is the door to the trading agent over the network, so it
// gets adversarial treatment: every line here is a way in the gate must refuse.
// No SDK, no network needed.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const auth = require("../auth");

const TOKEN = "0123456789abcdef0123456789abcdef"; // 32 chars, meets MIN_TOKEN_LEN

test("fail-closed: fromEnv refuses to construct without a token", () => {
  assert.throws(() => auth.fromEnv({}), /required/i);
  assert.throws(() => auth.fromEnv({ XTRADE_MCP_TOKEN: "" }), /required/i);
});

test("fail-closed: fromEnv rejects a weak (too-short) token", () => {
  assert.throws(() => auth.fromEnv({ XTRADE_MCP_TOKEN: "short" }), /too short/i);
});

test("fromEnv builds a working gate when the token is strong enough", () => {
  const gate = auth.fromEnv({ XTRADE_MCP_TOKEN: TOKEN });
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
  for (const v of [undefined, null, "", TOKEN, `Basic ${TOKEN}`, "Bearer", "Bearer "])
    assert.equal(gate.check(v), false, JSON.stringify(v));
});

test("checkRaw (path-segment form) is exact and never throws", () => {
  const gate = auth.makeGate(TOKEN);
  assert.equal(gate.checkRaw(TOKEN), true);
  assert.equal(gate.checkRaw(TOKEN + "x"), false);
  assert.equal(gate.checkRaw(TOKEN.slice(1)), false);
  for (const v of [undefined, null, 0, 1, {}, [], true, "", "x".repeat(1000)])
    assert.doesNotThrow(() => gate.checkRaw(v));
  assert.equal(gate.checkRaw(""), false);
});
