// remote.js over a real socket: the door (401 everywhere until the token is
// proven), then the Streamable HTTP surface — initialize, tools/list, one
// tools/call — carrying exactly the stdio server's tools. No outbound network:
// list_supported is pure config.
"use strict";
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");

const TOKEN = "remote-test-token-0123456789abcdefghij"; // >= 32 chars
process.env.XTRADE_MCP_TOKEN = TOKEN;                 // set BEFORE remote.js builds its gate
const remote = require("../remote");
const { buildServer } = require("../server");

const STDIO_TOOLS = ["list_supported", "session_gate", "check_method", "get_ledger_stats", "build_trade", "execute_trade"];
let base;

before(async () => {
  await new Promise((r) => remote.httpServer.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${remote.httpServer.address().port}`;
});
after(() => new Promise((r) => remote.httpServer.close(r)));

// Streamable HTTP answers a POST either as JSON or as an SSE stream; accept both.
async function rpc(path, body, headers = {}) {
  const res = await fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...headers },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let msg = null;
  if ((res.headers.get("content-type") || "").includes("text/event-stream")) {
    const datas = text.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5).trim()));
    msg = datas.find((d) => d.id === body.id) || datas[datas.length - 1] || null;
  } else if (text) {
    try { msg = JSON.parse(text); } catch { msg = null; }
  }
  return { status: res.status, headers: res.headers, msg, text };
}
const bearer = { authorization: `Bearer ${TOKEN}` };
const init = (id = 1) => ({ jsonrpc: "2.0", id, method: "initialize",
  params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "0" } } });

test("requiring server.js opens no transport and exports buildServer", () => {
  assert.equal(typeof buildServer, "function");
  const s = buildServer();
  assert.ok(s && typeof s.connect === "function");
});

test("/healthz is liveness only: {ok:true} and nothing else, no token needed", async () => {
  const res = await fetch(base + "/healthz");
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
});

test("unknown paths are 404 before the door", async () => {
  const res = await fetch(base + "/whatever");
  assert.equal(res.status, 404);
});

test("the door: no token, wrong token, raw token, query token → 401 and nothing runs", async () => {
  for (const [path, headers] of [
    ["/mcp", {}],
    ["/mcp", { authorization: "Bearer wrong-token-wrong-token-wrong-token" }],
    ["/mcp", { authorization: TOKEN }],
    ["/mcp?token=" + TOKEN, {}],
    ["/mcp/" + TOKEN.slice(0, -1), {}],
  ]) {
    const r = await rpc(path, init(), headers);
    assert.equal(r.status, 401, path + " " + JSON.stringify(headers));
    assert.equal(r.msg.error.code, -32001);
    assert.match(r.headers.get("www-authenticate") || "", /Bearer/);
  }
  const g = await fetch(base + "/mcp");
  assert.equal(g.status, 401, "GET without a token is refused too");
});

test("initialize over Streamable HTTP with a bearer token names this server", async () => {
  const r = await rpc("/mcp", init(), bearer);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.msg.result.serverInfo.name, "xtrade");
  assert.ok(r.msg.result.protocolVersion);
});

test("the capability-URL form /mcp/<token> is accepted (claude.ai web has no header field)", async () => {
  const r = await rpc("/mcp/" + TOKEN, init(2));
  assert.equal(r.status, 200, r.text);
  assert.equal(r.msg.result.serverInfo.name, "xtrade");
});

test("tools/list carries exactly the stdio server's six tools", async () => {
  const r = await rpc("/mcp", { jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }, bearer);
  assert.equal(r.status, 200, r.text);
  const names = r.msg.result.tools.map((t) => t.name).sort();
  assert.deepEqual(names, [...STDIO_TOOLS].sort());
});

test("tools/call list_supported answers from config: build always on, hot OFF pre key-ceremony", async () => {
  const r = await rpc("/mcp", { jsonrpc: "2.0", id: 4, method: "tools/call",
    params: { name: "list_supported", arguments: {} } }, bearer);
  assert.equal(r.status, 200, r.text);
  const payload = JSON.parse(r.msg.result.content[0].text);
  assert.equal(payload.scope.venue, "pump.fun");
  assert.equal(payload.modes.build, "always on");
  assert.match(payload.modes.hot, /OFF/);
});

test("a malformed body is a JSON-RPC parse error, not a stack trace", async () => {
  const res = await fetch(base + "/mcp", { method: "POST", headers: { ...bearer, "content-type": "application/json" }, body: "{not json" });
  assert.equal(res.status, 400);
  const j = await res.json();
  assert.equal(j.error.code, -32700);
});
