// Terminal-proof of the FACTS LAYER (facts.js, closes AUDIT W-2).
// FULLY OFFLINE: every test injects a mock fetch via deps - the module
// must never touch the network here. Run: node --test mcp/xtrade/test
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");

const facts = require("../facts");
const { rugGate } = require("../selection");
const { entryOk } = require("../method");
const { LAW, TUNE } = require("../config");

const MINT = "BzgukDvAsdq3JstYsus7i6jpUcQm3GTwvxBWwfJCpump";
const NOW = Date.parse("2026-07-15T12:00:00Z");

const ENV = {
  SOLANA_RPC_URL: "https://rpc.test",
  RADAR_URL: "https://radar.test",
  DEXSCREENER_BASE: "https://dex.test",
  PUMPFUN_API_BASE: "https://pump.test",
};

// ---- mock fetch: substring-keyed routes; responders may inspect the body ----
function mockFetch(routes) {
  const calls = [];
  const fn = async (url, init) => {
    const u = String(url);
    calls.push({ url: u, init });
    for (const [k, v] of Object.entries(routes)) {
      if (!u.includes(k)) continue;
      const r = typeof v === "function" ? v(u, init) : v;
      if (r instanceof Error) throw r;
      const status = r.status || 200;
      return { ok: status < 400, status, json: async () => r.body };
    }
    throw new Error("UNMOCKED fetch in test (network forbidden): " + u);
  };
  fn.calls = calls;
  return fn;
}

// Solana JSON-RPC responder; per-method result overrides.
function rpcResponder(overrides = {}) {
  return (url, init) => {
    const req = JSON.parse(init.body);
    const table = {
      getAccountInfo: { value: { data: { parsed: { type: "mint", info: {
        mintAuthority: null, freezeAuthority: null, decimals: 6,
        supply: "1000000000000000" } } } } },
      getTokenSupply: { value: { amount: "1000000000000000", decimals: 6 } },
      // 10% top holder
      getTokenLargestAccounts: { value: [
        { address: "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin", amount: "100000000000000" },
      ] },
      ...overrides,
    };
    if (!(req.method in table)) return { status: 500, body: {} };
    const r = table[req.method];
    if (r instanceof Error) return r;
    return { body: { jsonrpc: "2.0", id: 1, result: r } };
  };
}

const DEX_PREGRAD = { pairs: [{ dexId: "pumpfun", marketCap: 10500 }] }; // curve entry ONLY
const DEX_GRAD = { pairs: [
  { dexId: "pumpfun", marketCap: 69000 },
  { dexId: "raydium", marketCap: 71000, fdv: 71000 },
] };
const RADAR = {
  live: [{ token_address: MINT, qualified_ms: NOW - 60_000, entry_age_sec: 240, last_mc: 10000 }],
  early: [],
  ticks: { [MINT]: [{ ms: NOW - 30_000, mc: 9900 }, { ms: NOW - 5_000, mc: 10200 }] },
};

function routes(over = {}) {
  return {
    "rpc.test": over.rpc ?? rpcResponder(),
    "dex.test": over.dex ?? { body: DEX_PREGRAD },
    "/radar/candidates": over.candidates ?? { body: RADAR },
    "/radar/session-gate": over.sessionGate ?? { body: { error: "NO_READING_YET" } },
    "pump.test": over.pump ?? { status: 404, body: {} },
    ...(over.extra || {}),
  };
}
function deps(r, env = ENV) { return { fetchImpl: mockFetch(r), env, now: () => NOW }; }

// ---- happy path: renounced + clean + pre-grad + on tape -> gates pass ----
test("facts: renounced+clean token passes rug and entry gates on fetched facts", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.facts.mintRenounced.status, "ok");
  assert.equal(g.facts.mintRenounced.value, true);
  assert.equal(g.facts.mintRenounced.source, "solana-rpc");
  assert.equal(g.facts.lpLockedOrBurned.value, true);         // pre-grad: curve-owned liquidity
  assert.equal(g.facts.onDexScreener.value, false);           // R-1: curve pair does not count
  assert.equal(g.facts.creatorHoldingPct.value, 10);          // top-holder proxy, 10%
  assert.match(g.facts.creatorHoldingPct.basis, /CONSERVATIVE PROXY/); // never silent
  assert.ok(Math.abs(g.facts.ageMin.value - 5) < 0.01);       // qualified_ms - entry_age_sec
  assert.equal(g.facts.mc.value, 10200);                      // freshest radar tick
  assert.equal(g.allFetched, true);
  assert.equal(rugGate(g.gateFacts, TUNE).ok, true);
  assert.equal(entryOk(g.gateFacts, LAW, TUNE).ok, true);
});

// ---- mint authority present -> rug gate refuses on the CHAIN read ----
test("facts: mint authority present on chain -> rug gate refuses", async () => {
  const rpc = rpcResponder({ getAccountInfo: { value: { data: { parsed: { type: "mint",
    info: { mintAuthority: "CrEaToRAuthKey1111111111111111111111111111", freezeAuthority: null,
      decimals: 6, supply: "1000000000000000" } } } } } });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.equal(g.facts.mintRenounced.value, false);
  const rg = rugGate(g.gateFacts, TUNE);
  assert.equal(rg.ok, false);
  assert.ok(rg.fails.some((s) => /mint authority/.test(s)));
});

// ---- R-1 semantics: pumpfun-only pair is NOT discovery; non-pumpfun IS ----
test("facts: pumpfun-only pair -> onDexScreener false (R-1, curve never counts)", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({ dex: { body: DEX_PREGRAD } })));
  assert.equal(g.facts.onDexScreener.value, false);
  assert.match(g.facts.onDexScreener.basis, /NOT discovery/);
});
test("facts: non-pumpfun pair -> onDexScreener true, edge-loss semantics", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({ dex: { body: DEX_GRAD } })));
  assert.equal(g.facts.onDexScreener.value, true);
  // graduated: external LP exists, unverified -> fail-closed UNAVAILABLE
  assert.equal(g.facts.lpLockedOrBurned.status, "UNAVAILABLE");
  const en = entryOk({ ...g.gateFacts, mc: 10000, ageMin: 5 }, LAW, TUNE);
  assert.equal(en.ok, false);
  assert.ok(en.fails.some((s) => /DexScreener/.test(s)));
});

// ---- fetch failure -> fail-closed, refusal NAMES the fact ----
test("facts: RPC down -> mintRenounced/creatorHoldingPct UNAVAILABLE, refusal names them", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc: new Error("ECONNREFUSED") })));
  assert.equal(g.facts.mintRenounced.status, "UNAVAILABLE");
  assert.equal(g.facts.creatorHoldingPct.status, "UNAVAILABLE");
  assert.equal(g.allFetched, false);
  assert.ok(g.missing.includes("mintRenounced"));
  assert.ok(g.missing.includes("creatorHoldingPct"));
  const reason = facts.refusalReason(g);
  assert.match(reason, /fail-closed/);
  assert.match(reason, /mintRenounced/);
  assert.match(reason, /Never downgrading to caller-asserted/);
});

test("facts: bounded retries - a failing endpoint is attempted at most twice per read", async () => {
  const d = deps(routes({ dex: new Error("ETIMEDOUT") }));
  const g = await facts.gatherFacts(MINT, d);
  assert.equal(g.facts.onDexScreener.status, "UNAVAILABLE");
  const dexCalls = d.fetchImpl.calls.filter((c) => c.url.includes("dex.test"));
  assert.equal(dexCalls.length, 2); // 1 try + 1 retry, never more
});

// ---- divergence: asserted hints vs fetched facts ----
test("facts: divergence between asserted and fetched is reported, tolerant of small drift", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  const div = facts.divergence(
    { mintRenounced: false, mc: 50000, ageMin: 5.1, onDexScreener: false },
    g);
  const byFact = Object.fromEntries(div.map((d) => [d.fact, d]));
  assert.ok(byFact.mintRenounced, "boolean mismatch must be flagged");
  assert.deepEqual(
    { asserted: byFact.mc.asserted, fetched: byFact.mc.fetched },
    { asserted: 50000, fetched: 10200 });
  assert.equal(byFact.ageMin, undefined);        // 5.1 vs ~5: drift, not a lie
  assert.equal(byFact.onDexScreener, undefined); // agrees
  assert.deepEqual(facts.divergence({}, g), []); // no hints -> no divergence
});

// ---- Sec0 session gate: UNAVAILABLE by default, override is explicit ----
test("facts: session gate has no live source -> UNAVAILABLE, play=false (fail-closed)", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.facts.sessionGate.status, "UNAVAILABLE");
  assert.equal(g.facts.sessionGate.play, false);
  assert.match(g.facts.sessionGate.basis, /NO_READING_YET|no live data source/i);
});
test("facts: SESSION_GATE_OVERRIDE=pass is the documented ARCHITECT-ONLY path", async () => {
  const g = await facts.gatherFacts(MINT,
    deps(routes(), { ...ENV, SESSION_GATE_OVERRIDE: "pass" }));
  assert.equal(g.facts.sessionGate.status, "OVERRIDE");
  assert.equal(g.facts.sessionGate.play, true);
  assert.match(g.facts.sessionGate.basis, /ARCHITECT-ONLY/);
});
test("facts: a real /radar/session-gate reading wins over the override", async () => {
  const reading = { body: { session_date: "2026-07-15", ratio: 0.42, gate_pass: 0 } };
  const g = await facts.gatherFacts(MINT,
    deps(routes({ sessionGate: reading }), { ...ENV, SESSION_GATE_OVERRIDE: "pass" }));
  assert.equal(g.facts.sessionGate.status, "ok");
  assert.equal(g.facts.sessionGate.play, false); // the measurement, not the override
  assert.equal(g.facts.sessionGate.ratio, 0.42);
});

// ---- hot-path precondition (replaces the FACTS_VERIFIED_ON_DEVICE constant) ----
test("facts: hotFactsGuard refuses radar-sourced (class-3) facts - hot stays closed today", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.allFetched, true);
  assert.equal(g.allChainRead, false);            // ageMin/mc are radar (class 3)
  assert.deepEqual(g.nonChain.sort(), ["ageMin", "mc"]);
  const guard = facts.hotFactsGuard(g);
  assert.equal(guard.ok, false);
  assert.match(guard.reason, /not chain-read/);
  assert.match(guard.reason, /ageMin/);
});
test("facts: hotFactsGuard refuses missing facts and passes ONLY allChainRead", () => {
  assert.equal(facts.hotFactsGuard(null).ok, false);
  const broken = { allChainRead: false, missing: ["mintRenounced"], nonChain: [], facts: {} };
  const r = facts.hotFactsGuard(broken);
  assert.equal(r.ok, false);
  assert.match(r.reason, /mintRenounced/);
  // synthetic future state: every gate-critical fact chain-read -> ok
  assert.equal(facts.hotFactsGuard({ allChainRead: true }).ok, true);
});

// ---- fallbacks: pump.fun frontend when the tape misses; nowhere -> UNAVAILABLE ----
test("facts: token off the tape -> pump.fun frontend fallback (class 3, stated source)", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({
    candidates: { body: { live: [], early: [], ticks: {} } },
    pump: { body: { usd_market_cap: 9800, created_timestamp: NOW - 300_000 } },
  })));
  assert.equal(g.facts.mc.value, 9800);
  assert.equal(g.facts.mc.source, "pumpfun-frontend");
  assert.ok(Math.abs(g.facts.ageMin.value - 5) < 0.01);
  assert.equal(g.facts.ageMin.source, "pumpfun-frontend");
  assert.equal(g.allChainRead, false); // frontend API is advisory, never chain-read
});
test("facts: token nowhere -> ageMin/mc UNAVAILABLE, never fabricated", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({
    candidates: { body: { live: [], early: [], ticks: {} } },
    pump: { status: 404, body: {} },
  })));
  assert.equal(g.facts.ageMin.status, "UNAVAILABLE");
  assert.equal(g.facts.mc.status, "UNAVAILABLE");
  assert.ok(g.missing.includes("ageMin") && g.missing.includes("mc"));
  assert.match(g.facts.mc.basis, /never fabricated/);
});

// ---- graduated MC comes from DexScreener (class 2) when the tape misses ----
test("facts: graduated token off the tape -> mc from the non-pumpfun pair", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({
    dex: { body: DEX_GRAD },
    candidates: { body: { live: [], early: [], ticks: {} } },
    pump: { body: { created_timestamp: NOW - 300_000 } },
  })));
  assert.equal(g.facts.mc.value, 71000);
  assert.equal(g.facts.mc.source, "dexscreener");
});

// ---- RPC source selection: direct URL, read-only proxy, or refuse ----
test("facts: no RPC configured -> chain facts UNAVAILABLE with a config-naming basis", async () => {
  const env = { ...ENV };
  delete env.SOLANA_RPC_URL;
  const g = await facts.gatherFacts(MINT, deps(routes(), env));
  assert.equal(g.facts.mintRenounced.status, "UNAVAILABLE");
  assert.match(g.facts.mintRenounced.basis, /SOLANA_RPC_URL|SOLANA_MCP_URL/);
});
test("facts: solana-mcp proxy path (SOLANA_MCP_URL + SOLANA_MCP_KEY) is supported", async () => {
  const env = { ...ENV, SOLANA_MCP_URL: "https://mcp.test", SOLANA_MCP_KEY: "k".repeat(32) };
  delete env.SOLANA_RPC_URL;
  const rpc = rpcResponder();
  const proxy = (url, init) => {
    assert.match(url, new RegExp("^https://mcp\\.test/" + "k".repeat(32) + "/mcp$"));
    const msg = JSON.parse(init.body);
    assert.equal(msg.method, "tools/call");
    assert.equal(msg.params.name, "solana_rpc_request");
    // forward to the same table the direct responder uses, wrap MCP-style
    const inner = rpc(url, { body: JSON.stringify({
      jsonrpc: "2.0", id: 1,
      method: msg.params.arguments.method, params: msg.params.arguments.params }) });
    return { body: { jsonrpc: "2.0", id: 1, result: {
      content: [{ type: "text", text: JSON.stringify(inner.body.result) }],
      isError: false } } };
  };
  const g = await facts.gatherFacts(MINT, deps(routes({ extra: { "mcp.test": proxy } }), env));
  assert.equal(g.facts.mintRenounced.status, "ok");
  assert.equal(g.facts.mintRenounced.value, true);
  assert.equal(g.facts.creatorHoldingPct.value, 10);
});

// ---- creator address on the tape -> exact creator holding, not the proxy ----
test("facts: creator address from the radar tape -> exact holding via getTokenAccountsByOwner", async () => {
  const creator = "CrEaToRWaLLet1111111111111111111111111111";
  const rpc = rpcResponder({
    getTokenAccountsByOwner: { value: [
      { account: { data: { parsed: { info: { tokenAmount: { amount: "40000000000000" } } } } } },
      { account: { data: { parsed: { info: { tokenAmount: { amount: "10000000000000" } } } } } },
    ] },
  });
  const tape = { ...RADAR, live: [{ ...RADAR.live[0], creator }] };
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc, candidates: { body: tape } })));
  assert.equal(g.facts.creatorHoldingPct.value, 5); // 5e13 / 1e15
  assert.match(g.facts.creatorHoldingPct.basis, /creator wallet/);
  assert.doesNotMatch(g.facts.creatorHoldingPct.basis, /PROXY/);
});
