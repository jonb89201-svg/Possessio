// Offline tests for the Solana MCP worker: the whole MCP surface is proven
// with a mocked upstream fetch - no network, runs in the sandbox.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";

const worker = (await import("../worker.js")).default;

const KEY = "0123456789abcdef0123456789abcdef"; // 32 chars
const ENV = { ACCESS_KEY: KEY, SOLANA_RPC: "https://rpc.example/secret" };

const realFetch = globalThis.fetch;
let upstreamCalls;

before(() => {
  upstreamCalls = [];
  globalThis.fetch = async (url, opts = {}) => {
    const u = String(url);
    upstreamCalls.push({ url: u, opts });
    if (u.startsWith("https://rpc.example/")) {
      const body = JSON.parse(opts.body);
      const results = { getHealth: "ok", getSlot: 123456789 };
      return Response.json({ jsonrpc: "2.0", id: 1, result: results[body.method] ?? null });
    }
    if (u.includes("/quote")) {
      const q = new URL(u).searchParams;
      return Response.json({
        outAmount: "15000000", priceImpactPct: "0.01",
        slippageBps: q.get("slippageBps"), // echo back so the cap is checkable
      });
    }
    throw new Error("unexpected upstream: " + u);
  };
});
after(() => { globalThis.fetch = realFetch; });

function post(path, body) {
  return worker.fetch(new Request("https://w.example" + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }), ENV);
}
const mcp = (body) => post("/" + KEY + "/mcp", body);

test("wrong or missing key -> bare 404, no upstream call", async () => {
  const n = upstreamCalls.length;
  for (const p of ["/mcp", "/wrongkey/mcp", "/" + KEY.slice(0, 31) + "x/mcp"]) {
    const r = await post(p, { jsonrpc: "2.0", id: 1, method: "ping" });
    assert.equal(r.status, 404);
  }
  assert.equal(upstreamCalls.length, n);
});

test("missing secrets -> 503", async () => {
  const r = await worker.fetch(new Request("https://w.example/x/mcp", { method: "POST" }), {});
  assert.equal(r.status, 503);
});

test("ACCESS_KEY shorter than the documented 32 chars -> 503 unconfigured", async () => {
  const short = KEY.slice(0, 31); // 31 chars: one under the doc's minimum
  const r = await worker.fetch(new Request("https://w.example/" + short + "/mcp", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
  }), { ACCESS_KEY: short, SOLANA_RPC: "https://rpc.example/secret" });
  assert.equal(r.status, 503);
});

test("initialize negotiates a known protocol version", async () => {
  const r = await mcp({ jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
  const j = await r.json();
  assert.equal(j.result.protocolVersion, "2025-03-26");
  assert.equal(j.result.serverInfo.name, "possessio-solana-mcp");
  assert.ok(j.result.capabilities.tools);

  const r2 = await mcp({ jsonrpc: "2.0", id: 2, method: "initialize",
    params: { protocolVersion: "9999-01-01" } });
  assert.equal((await r2.json()).result.protocolVersion, "2025-06-18");
});

test("notifications/initialized -> 202 empty", async () => {
  const r = await mcp({ jsonrpc: "2.0", method: "notifications/initialized" });
  assert.equal(r.status, 202);
});

test("tools/list exposes exactly the two read-only tools", async () => {
  const j = await (await mcp({ jsonrpc: "2.0", id: 3, method: "tools/list" })).json();
  assert.deepEqual(j.result.tools.map((t) => t.name).sort(),
    ["jupiter_quote", "solana_rpc_request"]);
});

test("solana_rpc_request forwards an allowlisted method", async () => {
  const j = await (await mcp({ jsonrpc: "2.0", id: 4, method: "tools/call",
    params: { name: "solana_rpc_request", arguments: { method: "getSlot" } } })).json();
  assert.equal(j.result.isError, false);
  assert.equal(JSON.parse(j.result.content[0].text), 123456789);
});

test("sendTransaction is rejected as a tool error, never forwarded", async () => {
  const n = upstreamCalls.length;
  const j = await (await mcp({ jsonrpc: "2.0", id: 5, method: "tools/call",
    params: { name: "solana_rpc_request", arguments: { method: "sendTransaction", params: ["AAAA"] } } })).json();
  assert.equal(j.result.isError, true);
  assert.match(j.result.content[0].text, /not allowed/);
  assert.equal(upstreamCalls.length, n); // upstream untouched
});

test("jupiter_quote round-trips and caps slippage at 200 bps", async () => {
  const j = await (await mcp({ jsonrpc: "2.0", id: 6, method: "tools/call",
    params: { name: "jupiter_quote", arguments: {
      inputMint: "So11111111111111111111111111111111111111112",
      outputMint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      amountAtomic: "100000000", slippageBps: 5000 } } })).json();
  const out = JSON.parse(j.result.content[0].text);
  assert.equal(out.outAmount, "15000000");
  assert.equal(out.slippageBps, "200"); // capped, not the requested 5000
});

test("unknown MCP method -> -32601; malformed body -> -32700", async () => {
  const j = await (await mcp({ jsonrpc: "2.0", id: 7, method: "resources/list" })).json();
  assert.equal(j.error.code, -32601);
  const r = await worker.fetch(new Request("https://w.example/" + KEY + "/mcp",
    { method: "POST", body: "{nope" }), ENV);
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error.code, -32700);
});

test("GET /mcp -> 405; health endpoint pings upstream", async () => {
  const r = await worker.fetch(new Request("https://w.example/" + KEY + "/mcp"), ENV);
  assert.equal(r.status, 405);
  const h = await worker.fetch(new Request("https://w.example/" + KEY + "/health"), ENV);
  assert.deepEqual(await h.json(), { ok: true, upstream: "ok" });
});
