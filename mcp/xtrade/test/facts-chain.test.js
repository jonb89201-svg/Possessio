// Terminal-proof of the CHAIN-READ ageMin/mc upgrade (facts.js) - the
// last W-2 data gap. FULLY OFFLINE: every test injects a mock fetch.
// Run: node --test mcp/xtrade/test
//
// The PDA derivation was cross-validated OUT of band against
// @solana/web3.js findProgramAddressSync / PublicKey.isOnCurve
// (200 random mints + 50 real pubkeys, exact match, 2026-07-15); the
// deterministic fixture below pins that result forever. The curve decode
// is additionally pinned against a REAL mainnet account captured live
// (see LIVE_CURVE_FIXTURE) so the layout can never silently drift.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");

const facts = require("../facts");
const { entryOk } = require("../method");
const { LAW, TUNE } = require("../config");

const MINT = "BzgukDvAsdq3JstYsus7i6jpUcQm3GTwvxBWwfJCpump";
// Pinned against @solana/web3.js: findProgramAddressSync(
//   ["bonding-curve", MINT], 6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P)
const MINT_CURVE_PDA = "Hrfm4oovs6XsbtHUF5Ux48qo43X9QyhGC85RHRGzWtFp";
const MINT_CURVE_BUMP = 253;

const WSOL = "So11111111111111111111111111111111111111112";
const NOW = Date.parse("2026-07-15T12:00:00Z");
const sec = (ms) => Math.floor(ms / 1000);

const ENV = {
  SOLANA_RPC_URL: "https://rpc.test",
  RADAR_URL: "https://radar.test",
  DEXSCREENER_BASE: "https://dex.test",
  PUMPFUN_API_BASE: "https://pump.test",
};

// ---- fixtures ----
// Build a base64 BondingCurve account (anchor layout, incl. the newer
// trailing creator pubkey - the decoder must ignore trailers).
function curveAccountB64({ vTok, vSol, rTok = 0n, rSol = 0n, supply, complete = false }) {
  const buf = Buffer.alloc(8 + 5 * 8 + 1 + 32);
  Buffer.from(facts.BONDING_CURVE_DISCRIMINATOR).copy(buf, 0);
  buf.writeBigUInt64LE(BigInt(vTok), 8);   // virtual_token_reserves FIRST
  buf.writeBigUInt64LE(BigInt(vSol), 16);  // then virtual_sol_reserves
  buf.writeBigUInt64LE(BigInt(rTok), 24);
  buf.writeBigUInt64LE(BigInt(rSol), 32);
  buf.writeBigUInt64LE(BigInt(supply), 40);
  buf[48] = complete ? 1 : 0;
  return buf.toString("base64");
}

// HAND-COMPUTED MC (documented so the arithmetic is checkable on paper):
//   vSol   = 32_000_000_000 lamports      (32 SOL virtual)
//   vTok   = 1_000_000_000_000_000        (1e15 atomic, 6dp)
//   supply = 1_000_000_000_000_000        (1e15 atomic, 6dp)
//   SOL/USD = 150
//   MC_sol = (vSol/vTok) * supply / 1e9   [radar/screen.ts curveMcUsd,
//          = (3.2e10/1e15) * 1e15 / 1e9    divide-first overflow ordering]
//          = 3.2e10 / 1e9 = 32 SOL
//   MC_usd = 32 * 150 = $4,800 exactly (every step exact in float64)
const CURVE_PREGRAD = { vTok: 1_000_000_000_000_000n, vSol: 32_000_000_000n,
  supply: 1_000_000_000_000_000n };
const EXPECTED_MC_USD = 4800;

const SOL_PAIRS = { pairs: [
  { baseToken: { address: "NotSOL111" }, priceUsd: "1.0", liquidity: { usd: 9e9 } },
  { baseToken: { address: WSOL }, priceUsd: "150", liquidity: { usd: 8e7 },
    dexId: "raydium", pairAddress: "SoLUsdcPaIr111" },
  { baseToken: { address: WSOL }, priceUsd: "149.2", liquidity: { usd: 1e6 } },
] };
const DEX_PREGRAD = { pairs: [{ dexId: "pumpfun", marketCap: 10500 }] };
const DEX_GRAD = { pairs: [
  { dexId: "pumpfun", marketCap: 69000 },
  { dexId: "raydium", marketCap: 71000, fdv: 71000 },
] };
const RADAR = {
  live: [{ token_address: MINT, qualified_ms: NOW - 60_000, entry_age_sec: 240, last_mc: 10000 }],
  early: [],
  ticks: { [MINT]: [{ ms: NOW - 5_000, mc: 10200 }] },
};
const EMPTY_TAPE = { live: [], early: [], ticks: {} };

// signature-history entries, NEWEST FIRST (like the real RPC)
function sigEntries(n, newestMs, oldestMs, { nullTail = 0 } = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const ms = newestMs - (i * (newestMs - oldestMs)) / Math.max(1, n - 1);
    const isNull = i >= n - nullTail; // the OLDEST `nullTail` entries lack blockTime
    out.push({ signature: "sig" + i + "of" + n, blockTime: isNull ? null : sec(ms) });
  }
  return out;
}

// ---- mocks (same substring-route shape facts.test.js proves) ----
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

// RPC responder that knows the MINT (jsonParsed) vs its curve PDA (base64)
// and serves paginated signature history. opts:
//   curveB64: base64 account data | null (account missing) | undefined (default pre-grad)
//   curveOwner: override owner (default: the pump.fun program)
//   sigPages: array of pages (each an array of entries) | Error
function rpcResponder(opts = {}) {
  const curveB64 = "curveB64" in opts ? opts.curveB64 : curveAccountB64(CURVE_PREGRAD);
  const sigPages = opts.sigPages ?? [sigEntries(12, NOW - 30_000, NOW - 300_000)];
  const sigCalls = [];
  const fn = (url, init) => {
    const req = JSON.parse(init.body);
    if (req.method === "getAccountInfo") {
      const addr = req.params[0];
      if (addr === MINT_CURVE_PDA) {
        if (curveB64 instanceof Error) return curveB64;
        return { body: { jsonrpc: "2.0", id: 1, result: { value: curveB64 === null ? null : {
          data: [curveB64, "base64"], owner: opts.curveOwner || facts.PUMPFUN_PROGRAM,
          lamports: 2039280 } } } };
      }
      return { body: { jsonrpc: "2.0", id: 1, result: { value: { data: { parsed: {
        type: "mint", info: { mintAuthority: null, freezeAuthority: null,
          decimals: 6, supply: "1000000000000000" } } } } } } };
    }
    if (req.method === "getSignaturesForAddress") {
      if (sigPages instanceof Error) return sigPages;
      sigCalls.push(req.params[1] || {});
      const page = sigPages[Math.min(sigCalls.length - 1, sigPages.length - 1)] || [];
      return { body: { jsonrpc: "2.0", id: 1, result: page } };
    }
    const table = {
      getTokenSupply: { value: { amount: "1000000000000000", decimals: 6 } },
      getTokenLargestAccounts: { value: [
        { address: "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin", amount: "100000000000000" } ] },
    };
    if (!(req.method in table)) return { status: 500, body: {} };
    return { body: { jsonrpc: "2.0", id: 1, result: table[req.method] } };
  };
  fn.sigCalls = sigCalls;
  return fn;
}

// DexScreener: ONE substring route ("dex.test") dispatching on path -
// wSOL (SOL/USD leg) vs the token (pairs/R-1 leg).
function dexResponder({ token = DEX_PREGRAD, sol = SOL_PAIRS } = {}) {
  return (url) => {
    if (url.includes(WSOL)) return sol instanceof Error ? sol
      : { status: sol.status || 200, body: sol.body || sol };
    return token instanceof Error ? token
      : { status: token.status || 200, body: token.body || token };
  };
}

function routes(over = {}) {
  return {
    "rpc.test": over.rpc ?? rpcResponder(),
    "dex.test": over.dex ?? dexResponder(),
    "/radar/candidates": over.candidates ?? { body: RADAR },
    "/radar/session-gate": over.sessionGate ?? { body: { error: "NO_READING_YET" } },
    "pump.test": over.pump ?? { status: 404, body: {} },
    ...(over.extra || {}),
  };
}
function deps(r, env = ENV) { return { fetchImpl: mockFetch(r), env, now: () => NOW }; }

// ============================================================
// PDA derivation + curve decode, pinned
// ============================================================
test("chain: bonding-curve PDA derivation is deterministic and pinned vs web3.js", () => {
  const pda = facts.derivePumpCurvePda(MINT);
  assert.equal(pda.address, MINT_CURVE_PDA); // exact @solana/web3.js match
  assert.equal(pda.bump, MINT_CURVE_BUMP);
  // deterministic: same input, same output, every call
  assert.deepEqual(facts.derivePumpCurvePda(MINT), pda);
  // a ticker is not derivable - F-1 stays un-bypassable through this path
  assert.throws(() => facts.derivePumpCurvePda("DOGE"), /32 bytes|base58/);
});

test("chain: anchor discriminator is computed sha256('account:BondingCurve')[0..8]", () => {
  assert.deepEqual([...facts.BONDING_CURVE_DISCRIMINATOR], [23, 183, 248, 55, 96, 216, 172, 96]);
});

// REAL MAINNET FIXTURE, captured live 2026-07-15 during the Codebyte-Law
// verify of this change (mint 9ezjKEW51hQbUTYQ8ZT4tqxWhufFKkT1VnazPGfvpump
// "Angel", a live radar-tape candidate; its curve PDA
// 4258Hr1VMS22T8FztSpFjscA7oiG12m3Ygd2TgGgFeT5, bump 254, owner = the
// pump.fun program). Pins the decoder to the byte layout the chain
// actually serves - the same role radar's btcScan hex fixture plays.
// (radar/test/discovery.test.mjs has no curve-account fixture - its only
// hex fixture is the Chainlink BTC feed - so this live capture is the pin.)
const LIVE_CURVE_B64 =
  "F7f4N2DYrGDvuq3zKsADALV8Q+QaAAAA7yKbp5nBAgACAAAAAAAAAACAxqR+jQMAAGNN0hVH" +
  "yPr85XOGntf/5rPnbjcPqVN4ePuaaE7+m1kqAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

test("chain: LIVE mainnet curve account (captured 2026-07-15) decodes to the verified reserves", () => {
  const c = facts.decodeBondingCurve(Buffer.from(LIVE_CURVE_B64, "base64"));
  assert.ok(c, "real account must decode");
  assert.equal(c.virtualTokenReserves, 1_055_715_639_540_463n);
  assert.equal(c.virtualSolReserves, 115_498_777_781n);
  assert.equal(c.realTokenReserves, 775_815_639_540_463n);
  assert.equal(c.realSolReserves, 2n);
  assert.equal(c.tokenTotalSupply, 1_000_000_000_000_000n);
  assert.equal(c.complete, false);
  // and the mirrored radar math prices it to what the tape independently
  // showed for the same token at the same moment (chain $8438.28 vs tape
  // last_mc $8444.84 at SOL/USD=77.13 - 0.08% apart, see live verify):
  //   MC_sol = (115498777781/1055715639540463) * 1e15 / 1e9 = 109.4028... SOL
  const mc = facts.curveMcUsd({
    virtual_sol_reserves: Number(c.virtualSolReserves),
    virtual_token_reserves: Number(c.virtualTokenReserves),
    total_supply: Number(c.tokenTotalSupply),
  }, 77.13);
  assert.ok(Math.abs(mc - 8438.28) < 0.01, "live-verified USD MC reproduces: got " + mc);
});

test("chain: LIVE fixture mint -> its real PDA (pinned from the same capture)", () => {
  const pda = facts.derivePumpCurvePda("9ezjKEW51hQbUTYQ8ZT4tqxWhufFKkT1VnazPGfvpump");
  assert.equal(pda.address, "4258Hr1VMS22T8FztSpFjscA7oiG12m3Ygd2TgGgFeT5");
  assert.equal(pda.bump, 254);
});

test("chain: curve decode - synthetic account round-trips the exact fields", () => {
  const buf = Buffer.from(curveAccountB64({
    vTok: 987_654_321_000_000n, vSol: 31_234_567_890n,
    rTok: 700_000_000_000_000n, rSol: 1_234_567_890n,
    supply: 1_000_000_000_000_000n, complete: false }), "base64");
  const c = facts.decodeBondingCurve(buf);
  assert.equal(c.virtualTokenReserves, 987_654_321_000_000n); // offset 8 (FIRST)
  assert.equal(c.virtualSolReserves, 31_234_567_890n);        // offset 16
  assert.equal(c.realTokenReserves, 700_000_000_000_000n);    // offset 24
  assert.equal(c.realSolReserves, 1_234_567_890n);            // offset 32
  assert.equal(c.tokenTotalSupply, 1_000_000_000_000_000n);   // offset 40
  assert.equal(c.complete, false);                            // offset 48
  // wrong discriminator / short buffer -> null, never a garbage decode
  const bad = Buffer.from(buf); bad[0] ^= 0xff;
  assert.equal(facts.decodeBondingCurve(bad), null);
  assert.equal(facts.decodeBondingCurve(buf.subarray(0, 48)), null);
});

test("chain: MC math mirrors radar curveMcUsd exactly (hand-computed $4,800)", () => {
  // full arithmetic in the CURVE_PREGRAD/EXPECTED_MC_USD comment above
  const mc = facts.curveMcUsd({
    virtual_sol_reserves: 32_000_000_000,
    virtual_token_reserves: 1_000_000_000_000_000,
    total_supply: 1_000_000_000_000_000,
  }, 150);
  assert.equal(mc, EXPECTED_MC_USD);
  // the radar's clamps, mirrored: null solUsd / missing or degenerate reserves
  assert.equal(facts.curveMcUsd({ virtual_sol_reserves: 1, virtual_token_reserves: 1, total_supply: 1 }, null), null);
  assert.equal(facts.curveMcUsd({ virtual_token_reserves: 0, virtual_sol_reserves: 1, total_supply: 1 }, 150), null);
  assert.equal(facts.curveMcUsd({ virtual_sol_reserves: 1, total_supply: 1 }, 150), null);
});

// ============================================================
// gatherFacts: mc via the chain (class 1)
// ============================================================
test("chain: pre-grad curve decodes -> mc is class-1 solana-rpc, tape demoted to cross-check", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.facts.mc.status, "ok");
  assert.equal(g.facts.mc.source, "solana-rpc");
  assert.equal(g.facts.mc.value, EXPECTED_MC_USD); // chain wins, NOT the tape's 10200
  assert.match(g.facts.mc.basis, /bonding-curve PDA Hrfm4oovs6XsbtHUF5Ux48qo43X9QyhGC85RHRGzWtFp/);
  assert.match(g.facts.mc.basis, /curveMcUsd formula/);
  // tape ($10,200) vs chain ($4,800): >25% apart -> divergence LOGGED, chain wins
  assert.match(g.facts.mc.basis, /CROSS-CHECK DIVERGENCE/);
  assert.match(g.facts.mc.basis, /10200/);
});

test("chain: tape within 25% of chain -> cross-check agreement noted, no divergence flag", async () => {
  // vSol=66.6 SOL -> MC_sol=66.6, x$150 = $9,990; tape $10,200 is within 25%
  const rpc = rpcResponder({ curveB64: curveAccountB64({
    vTok: 1_000_000_000_000_000n, vSol: 66_600_000_000n, supply: 1_000_000_000_000_000n }) });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.ok(Math.abs(g.facts.mc.value - 9990) < 1e-6); // 66.6 SOL x $150 (float64 ulp)
  assert.match(g.facts.mc.basis, /cross-check agrees within 25%/);
  assert.doesNotMatch(g.facts.mc.basis, /DIVERGENCE/);
});

test("chain: graduated curve (complete=true) -> falls through to DexScreener MC (class 2)", async () => {
  const rpc = rpcResponder({ curveB64: curveAccountB64({ ...CURVE_PREGRAD, complete: true }) });
  const g = await facts.gatherFacts(MINT, deps(routes({
    rpc, dex: dexResponder({ token: DEX_GRAD }), candidates: { body: EMPTY_TAPE } })));
  assert.equal(g.facts.mc.value, 71000);
  assert.equal(g.facts.mc.source, "dexscreener");
});

test("chain: curve account missing -> falls through (class-3 tape keeps build-mode alive)", async () => {
  const rpc = rpcResponder({ curveB64: null });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.equal(g.facts.mc.value, 10200); // freshest radar tick
  assert.equal(g.facts.mc.source, "radar");
  assert.ok(g.nonChain.includes("mc")); // and the hot guard sees that honestly
});

test("chain: wrong account owner -> never decoded as a curve, falls through", async () => {
  const rpc = rpcResponder({ curveOwner: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.equal(g.facts.mc.source, "radar"); // fell through, no fake class-1
});

test("chain: SOL/USD leg fails -> mc UNAVAILABLE (fail-closed), NO class-3 fallback", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes({
    dex: dexResponder({ sol: new Error("ETIMEDOUT") }) })));
  assert.equal(g.facts.mc.status, "UNAVAILABLE");
  assert.equal(g.facts.mc.source, "solana-rpc");
  assert.match(g.facts.mc.basis, /SOL\/USD/);
  assert.match(g.facts.mc.basis, /fail-closed, never repriced from advisory/);
  assert.ok(g.missing.includes("mc")); // build_trade refuses, naming the fact
});

// ============================================================
// gatherFacts: ageMin via the signature walk (class 1)
// ============================================================
test("chain: single-page signature walk -> ageMin from the OLDEST blockTime", async () => {
  // 12 signatures, oldest at NOW-300s -> 5.00 min
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.facts.ageMin.status, "ok");
  assert.equal(g.facts.ageMin.source, "solana-rpc");
  assert.ok(Math.abs(g.facts.ageMin.value - 5) < 0.01);
  assert.match(g.facts.ageMin.basis, /walked to exhaustion/);
  assert.match(g.facts.ageMin.basis, /12 signature/);
});

test("chain: multi-page walk paginates with `before` and takes the last page's oldest", async () => {
  const page1 = sigEntries(1000, NOW - 10_000, NOW - 200_000);
  const page2 = sigEntries(40, NOW - 201_000, NOW - 360_000); // oldest: 6min ago
  const rpc = rpcResponder({ sigPages: [page1, page2] });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.ok(Math.abs(g.facts.ageMin.value - 6) < 0.01);
  assert.equal(g.facts.ageMin.source, "solana-rpc");
  assert.match(g.facts.ageMin.basis, /1040 signature\(s\) over 2 page\(s\)/);
  // the pagination cursor is the LAST signature of the previous page
  assert.equal(rpc.sigCalls.length, 2);
  assert.equal(rpc.sigCalls[0].before, undefined);
  assert.equal(rpc.sigCalls[1].before, page1[page1.length - 1].signature);
  assert.equal(rpc.sigCalls[1].limit, facts.SIG_PAGE_LIMIT);
});

test("chain: pagination bound exceeded -> LOWER-BOUND age that fails the entry window (fail-closed)", async () => {
  // 5 full pages and still not at the first tx; oldest blockTime seen: 45min ago
  const fullPage = sigEntries(1000, NOW - 10_000, NOW - 45 * 60_000);
  const rpc = rpcResponder({ sigPages: [fullPage, fullPage, fullPage, fullPage, fullPage, fullPage] });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.equal(rpc.sigCalls.length, facts.MAX_SIG_PAGES); // hard cap: never a 6th page
  assert.equal(g.facts.ageMin.status, "ok");
  assert.equal(g.facts.ageMin.source, "solana-rpc");
  assert.ok(Math.abs(g.facts.ageMin.value - 45) < 0.01); // the PROVEN MINIMUM age
  assert.match(g.facts.ageMin.basis, /age exceeds pagination bound, older than/);
  assert.match(g.facts.ageMin.basis, /LOWER BOUND/);
  // and that value FAILS the 4-7min entry window - the right direction
  const en = entryOk({ ...g.gateFacts, mc: 10000 }, LAW, TUNE);
  assert.equal(en.ok, false);
  assert.ok(en.fails.some((s) => /age .*outside/.test(s)));
});

test("chain: null blockTime entries are skipped, nearest non-null wins, count reported", async () => {
  // oldest 3 entries have null blockTime; oldest NON-null is at NOW-280s
  const page = sigEntries(10, NOW - 30_000, NOW - 280_000)
    .concat([{ signature: "n1", blockTime: null }, { signature: "n2", blockTime: null },
             { signature: "n3", blockTime: null }]);
  const rpc = rpcResponder({ sigPages: [page] });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.ok(Math.abs(g.facts.ageMin.value - 280 / 60) < 0.01);
  assert.match(g.facts.ageMin.basis, /3 null-blockTime/);
});

test("chain: signature walk fails -> class-3 tape fallback keeps build-mode, guard refuses hot", async () => {
  const rpc = rpcResponder({ sigPages: new Error("ECONNRESET") });
  const g = await facts.gatherFacts(MINT, deps(routes({ rpc })));
  assert.equal(g.facts.ageMin.source, "radar"); // fallback, stated
  assert.ok(g.nonChain.includes("ageMin"));
  assert.equal(facts.hotFactsGuard(g).ok, false); // honest refusal on class 3
});

// ============================================================
// the roll-up: hotFactsGuard can now pass - sessionGate is the final refuser
// ============================================================
test("chain: full chain-read call -> allChainRead=true, hotFactsGuard PASSES; sessionGate still refuses", async () => {
  const g = await facts.gatherFacts(MINT, deps(routes()));
  assert.equal(g.allFetched, true);
  assert.deepEqual(g.nonChain, []);                 // ageMin+mc now class 1
  assert.equal(g.facts.mc.source, "solana-rpc");
  assert.equal(g.facts.ageMin.source, "solana-rpc");
  assert.equal(g.allChainRead, true);
  assert.equal(facts.hotFactsGuard(g).ok, true);    // the last data gap is closed
  // ...but Sec0 still refuses: nothing writes the sessions table yet.
  // build_trade/execute_trade refuse at sessionGate - correct and intended.
  assert.equal(g.facts.sessionGate.status, "UNAVAILABLE");
  assert.equal(g.facts.sessionGate.play, false);
});
