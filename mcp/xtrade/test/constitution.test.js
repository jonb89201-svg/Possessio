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

// ---- W-2 tripwire: the hot path must stay hard-blocked on unverified facts.
// server.js opens a stdio transport on require, so this is a source-level
// assertion: the constant exists, is false, and gates execute_trade.
test("server: FACTS_VERIFIED_ON_DEVICE is false and guards hot execution", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "server.js"), "utf8");
  assert.match(src, /const FACTS_VERIFIED_ON_DEVICE = false;/);
  assert.match(src, /if \(!FACTS_VERIFIED_ON_DEVICE\)/);
});
