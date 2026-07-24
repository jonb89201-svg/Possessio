// Terminal-proof of RULEBOOK_TradingAgent.md logic. Pure modules only -
// no network, no keys. Run: node --test mcp/xtrade/test
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const os = require("os"), path = require("path"), fs = require("fs");

const { LAW, TUNE, runtimeEnv, tighten } = require("../config");
const { resolveMode } = require("../modes");
const { checkCaps } = require("../caps");
const { assertContractAddress, rugGate, RefusalError } = require("../selection");
const { sessionGate } = require("../sessiongate");
const { entryOk, exitTrigger } = require("../method");
const ledger = require("../ledger");

// ---- Sec4 execution model: build always on, hot triple-gated ----
test("mode: plain request is build", () => {
  assert.equal(resolveMode("build", {}, false).mode, "build");
});
test("mode: hot with all three gates -> hot", () => {
  const r = resolveMode("hot", { allowHot: true, hasSigner: true }, true);
  assert.equal(r.mode, "hot");
});
test("mode: hot missing ANY gate -> downgrades to build", () => {
  for (const miss of [
    { allowHot: false, hasSigner: true, confirm: true },
    { allowHot: true, hasSigner: false, confirm: true },
    { allowHot: true, hasSigner: true, confirm: false },
  ]) {
    const r = resolveMode("hot", { allowHot: miss.allowHot, hasSigner: miss.hasSigner }, miss.confirm);
    assert.equal(r.mode, "build", JSON.stringify(miss));
    assert.equal(r.downgraded, true);
  }
});

// ---- Sec3 caps: server-enforced ----
test("caps: $2 notional passes, $2.01 fails", () => {
  const caps = { maxNotionalUsd: 2, maxSlippageBps: 200, maxTradesPerDay: 10, maxDailyExposureUsd: 20 };
  assert.equal(checkCaps({ notionalUsd: 2, slippageBps: 100, todayCount: 0, todayExposureUsd: 0 }, caps).ok, true);
  assert.equal(checkCaps({ notionalUsd: 2.01, slippageBps: 100, todayCount: 0, todayExposureUsd: 0 }, caps).ok, false);
});
test("caps: slippage ceiling 200bps hard", () => {
  const caps = { maxNotionalUsd: 2, maxSlippageBps: 200, maxTradesPerDay: 10, maxDailyExposureUsd: 20 };
  assert.equal(checkCaps({ notionalUsd: 1, slippageBps: 201, todayCount: 0, todayExposureUsd: 0 }, caps).ok, false);
});
test("caps: 10 trades/day and $20 exposure ceilings", () => {
  const caps = { maxNotionalUsd: 2, maxSlippageBps: 200, maxTradesPerDay: 10, maxDailyExposureUsd: 20 };
  assert.equal(checkCaps({ notionalUsd: 1, slippageBps: 1, todayCount: 10, todayExposureUsd: 5 }, caps).ok, false);
  assert.equal(checkCaps({ notionalUsd: 2, slippageBps: 1, todayCount: 5, todayExposureUsd: 19 }, caps).ok, false);
});

// ---- config: env can tighten a cap but NEVER loosen LAW ----
test("config: env cannot raise a cap above LAW", () => {
  assert.equal(tighten("100", 2, "min"), 2);   // attempt to loosen -> ignored
  assert.equal(tighten("1", 2, "min"), 1);      // tighten -> honored
  const rt = runtimeEnv({ MAX_NOTIONAL_USD: "999" });
  assert.equal(rt.maxNotionalUsd, LAW.maxNotionalUsd);
});

// ---- Sec2 F-1: contract addresses only ----
test("F-1: a ticker is a refusal, not a lookup", () => {
  for (const bad of ["AERO", "$AERO", "aerodrome", "BONK", "sol", ""]) {
    assert.throws(() => assertContractAddress(bad), RefusalError, `should refuse ${bad}`);
  }
});
test("F-1: a valid Solana mint passes", () => {
  const mint = "BzgukDvAsdq3JstYsus7i6jpUcQm3GTwvxBWwfJCpump"; // the pasted token, base58 44ch
  assert.equal(assertContractAddress(mint), mint);
});

// ---- Sec2 rug gate ----
test("rug gate: all clean passes; any fail skips", () => {
  const clean = { mintRenounced: true, lpLockedOrBurned: true, creatorHoldingPct: 10 };
  assert.equal(rugGate(clean, TUNE).ok, true);
  assert.equal(rugGate({ ...clean, mintRenounced: false }, TUNE).ok, false);
  assert.equal(rugGate({ ...clean, creatorHoldingPct: 16 }, TUNE).ok, false);
});

// ---- Sec0 session gate ----
test("session gate: below cutoff sits out", () => {
  assert.equal(sessionGate({ trailingVol: 50, avg7d: 100 }, 0.65).play, false); // 0.50 < 0.65
  assert.equal(sessionGate({ trailingVol: 70, avg7d: 100 }, 0.65).play, true);  // 0.70 >= 0.65
  assert.equal(sessionGate({ trailingVol: 100, avg7d: 0 }, 0.65).play, false);  // no baseline
});

// ---- Sec1 entry ----
test("entry: pre-DEX, 4-7min, in band", () => {
  const good = { onDexScreener: false, ageMin: 5, mc: 10000 };
  assert.equal(entryOk(good, LAW, TUNE).ok, true);
  assert.equal(entryOk({ ...good, onDexScreener: true }, LAW, TUNE).ok, false);
  assert.equal(entryOk({ ...good, ageMin: 3 }, LAW, TUNE).ok, false);
  assert.equal(entryOk({ ...good, ageMin: 8 }, LAW, TUNE).ok, false);
  assert.equal(entryOk({ ...good, mc: 15000 }, LAW, TUNE).ok, false);
});

// ---- Sec1 exits: first-to-fire priority ----
test("exit: take-profit at 20k", () => {
  assert.deepEqual(pick(exitTrigger({ mc: 20000, onDexScreener: false, elapsedMin: 1 }, LAW)), [true, 1]);
});
test("exit: stop-loss at 6k", () => {
  assert.deepEqual(pick(exitTrigger({ mc: 6000, onDexScreener: false, elapsedMin: 1 }, LAW)), [true, 2]);
});
test("exit: edge-loss on DexScreener listing", () => {
  assert.deepEqual(pick(exitTrigger({ mc: 12000, onDexScreener: true, elapsedMin: 1 }, LAW)), [true, 3]);
});
test("exit: time-stop at 10min", () => {
  assert.deepEqual(pick(exitTrigger({ mc: 12000, onDexScreener: false, elapsedMin: 10 }, LAW)), [true, 4]);
});
test("exit: nothing fired mid-band, still holding", () => {
  assert.equal(exitTrigger({ mc: 12000, onDexScreener: false, elapsedMin: 3 }, LAW).sell, false);
});
test("exit: take-profit beats a simultaneous DexScreener listing", () => {
  // both true; numbered table gives take-profit priority
  assert.deepEqual(pick(exitTrigger({ mc: 21000, onDexScreener: true, elapsedMin: 1 }, LAW)), [true, 1]);
});
function pick(r) { return [r.sell, r.trigger]; }

// ---- Sec5 ledger: append + daily stats (caps vs performance truth) ----
test("ledger: todayStats caps view counts filled+built that day, never skips", () => {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "xledger-")), "l.jsonl");
  ledger.append(p, ledger.record({ ts: "2026-07-04T10:00:00Z", outcome: "filled", notionalUsd: 2 }));
  ledger.append(p, ledger.record({ ts: "2026-07-04T11:00:00Z", outcome: "built", notionalUsd: 1.5 }));
  ledger.append(p, ledger.record({ ts: "2026-07-04T12:00:00Z", outcome: "skipped", notionalUsd: 2 }));
  ledger.append(p, ledger.record({ ts: "2026-07-03T10:00:00Z", outcome: "filled", notionalUsd: 2 }));
  const s = ledger.todayStats(p, "2026-07-04");
  assert.equal(s.todayCount, 2);          // filled + built consume the budget
  assert.equal(s.todayExposureUsd, 3.5);  // skipped/other-day never do
});

test("ledger: builds are NOT fills - performance truth excludes them (W-1)", () => {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "xledger-")), "l.jsonl");
  // 10 unsigned builds at $2 exhaust the $20 daily budget (conservative)...
  for (let i = 0; i < 10; i++) {
    ledger.append(p, ledger.record({
      ts: `2026-07-04T10:0${i}:00Z`, outcome: "built",
      notionalUsd: 2, reason: "build payload issued" }));
  }
  ledger.append(p, ledger.record({
    ts: "2026-07-04T11:00:00Z", outcome: "filled", notionalUsd: 2, netReturn: -0.4 }));
  const s = ledger.todayStats(p, "2026-07-04");
  assert.equal(s.todayCount, 11);           // caps: builds still count
  assert.equal(s.todayExposureUsd, 22);
  assert.equal(s.filledCount, 1);           // truth: only the real fill
  assert.equal(s.filledExposureUsd, 2);
  assert.equal(s.netReturnUsd, -0.4);       // builds contribute NOTHING here
});

test("ledger: every row carries factsSource, honest default caller-asserted (W-2)", () => {
  assert.equal(ledger.record({ ts: "2026-07-04T10:00:00Z", outcome: "built" }).factsSource,
    "caller-asserted");
  assert.equal(ledger.record({ ts: "2026-07-04T10:00:00Z", outcome: "filled",
    factsSource: "device-verified" }).factsSource, "device-verified");
});

// ---- W-2 tripwire: the hot path must refuse when facts are not chain-read.
// server.js opens a stdio transport on require, so this is a source-level
// assertion; the guard's BEHAVIOR is unit-proven in test/facts.test.js.
// Original intent preserved: hot execution on caller-asserted facts is
// forbidden. The check is now computed per call (facts.hotFactsGuard) -
// a hardcodable FACTS_VERIFIED_ON_DEVICE constant must never reappear,
// because a constant is exactly the thing someone can flip.
test("server: hot path is gated by per-call chain-read facts, no flippable constant", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "server.js"), "utf8");
  assert.doesNotMatch(src, /FACTS_VERIFIED_ON_DEVICE\s*=/);           // constant is gone
  assert.match(src, /factsLayer\.gatherFacts/);                       // facts fetched server-side
  assert.match(src, /const guard = factsLayer\.hotFactsGuard\(g\);/); // hot consults the guard
  assert.match(src, /if \(!guard\.ok\)/);                             // and refuses on failure
});

// ---- XT-1 (audit 2026-07-23): caps must bind on the size the SWAP SPENDS ----
// Sec3 caps used to check the caller's CLAIMED notionalUsd while the swap was
// built from the caller's SEPARATE amountAtomic, unreconciled — so
// `notionalUsd: 1` with a huge amountAtomic passed the $2/trade and $20/day caps
// and returned an unsigned swap worth orders of magnitude more, while the Sec5
// ledger recorded $1. These prove the derivation that closes it.
const { deriveNotionalUsd, PRICEABLE_INPUTS } = require("../facts");
const WSOL = "So11111111111111111111111111111111111111112";
const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
// deepest-liquidity wSOL pair shape, enough for fetchSolUsd
const solFetch = async () => ({
  ok: true, status: 200,
  json: async () => ({ pairs: [{ baseToken: { address: WSOL }, priceUsd: "200",
    liquidity: { usd: 1e9 }, dexId: "test", pairAddress: "p1" }] }),
});

test("XT-1: stablecoin leg is priced at par from amountAtomic", async () => {
  const f = await deriveNotionalUsd({}, solFetch, USDC, "2000000"); // 2 USDC (6dp)
  assert.equal(f.status, "ok");
  assert.equal(f.value, 2);
  assert.match(f.basis, /par ASSUMPTION/); // stated, not smuggled in as a price read
});

test("XT-1: SOL leg is priced from amountAtomic x SOL/USD", async () => {
  const f = await deriveNotionalUsd({ dexscreenerBase: "x" }, solFetch, WSOL, "1000000000"); // 1 SOL (9dp)
  assert.equal(f.status, "ok");
  assert.equal(f.value, 200);
});

test("XT-1: THE BYPASS — huge amountAtomic is sized by the server, not the claim", async () => {
  // the exploit: caller claims $1 while spending 1,000 SOL
  const claimed = 1;
  const f = await deriveNotionalUsd({ dexscreenerBase: "x" }, solFetch, WSOL, "1000000000000");
  assert.equal(f.status, "ok");
  assert.equal(f.value, 200_000, "server must price what the swap actually spends");
  // and that derived size must blow the caps the claim would have slipped past
  const rt = { maxTradesPerDay: 10, maxDailyExposureUsd: 20, maxNotionalUsd: 2, maxSlippageBps: 300 };
  assert.equal(checkCaps({ notionalUsd: claimed, slippageBps: 100,
    filledCount: 0, todayExposureUsd: 0 }, rt).ok, true, "the CLAIM passes — this was the bypass");
  assert.equal(checkCaps({ notionalUsd: f.value, slippageBps: 100,
    filledCount: 0, todayExposureUsd: 0 }, rt).ok, false, "the DERIVED size is refused");
});

test("XT-1: an unpriceable input mint is UNAVAILABLE, never a guess", async () => {
  const f = await deriveNotionalUsd({}, solFetch, "SomeRandomMint1111111111111111111111111111", "1000");
  assert.equal(f.status, "UNAVAILABLE");
  assert.match(f.basis, /not priceable server-side/);
  assert.ok(!Object.keys(PRICEABLE_INPUTS).includes("SomeRandomMint1111111111111111111111111111"));
});

test("XT-1: non-positive amountAtomic is refused", async () => {
  for (const bad of ["0", "-5", "abc", ""]) {
    assert.equal((await deriveNotionalUsd({}, solFetch, USDC, bad)).status, "UNAVAILABLE", `bad: ${bad}`);
  }
});
