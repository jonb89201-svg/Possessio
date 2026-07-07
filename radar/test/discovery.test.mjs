// Offline proof of the R-1 predicate + R-2 batching (RADAR_FIX_R1R2 handoff).
// Mocks fetch (DexScreener shapes) and D1; runs the REAL discoveryScan.
//   node --test --experimental-strip-types radar/test/discovery.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { discoveryScan } from "../watcher.ts";

const NOW_FRESH = Date.now() - 60_000; // one minute old - live
const NOW_STALE = Date.now() - 25 * 3600_000; // >24h - must expire

function mockDb(watchingRows) {
  const batched = [];
  const runs = [];
  const db = {
    batched, runs,
    prepare(sql) {
      return {
        bind(...args) {
          return {
            sql, args,
            all: async () => ({ results: watchingRows }),
            first: async () => null,
            run: async () => { runs.push({ sql, args }); return { success: true }; },
          };
        },
      };
    },
    batch: async (stmts) => { batched.push(...stmts); },
  };
  return db;
}

function env(db, fetchImpl) {
  globalThis.fetch = fetchImpl;
  return {
    RADAR_DB: db,
    DEXSCREENER_TOKEN_URL: "https://dex.example/tokens/",
    DISCOVERY_BATCH: "900",
    EXPIRE_HOURS: "24",
    YOUNG_WINDOW_MIN: "120",
  };
}

const ENV_BIRTH = { PUMPFUN_FEED_URL: "https://feed.example/coins", DEXSCREENER_TOKEN_URL: "https://dex.example/tokens/", DISCOVERY_BATCH: "300", EXPIRE_HOURS: "24" };

const pairsResponse = (pairs) => ({
  ok: true, status: 200, json: async () => ({ pairs }),
});

test("curve-only pair -> telemetry write-once, token STAYS watching", async () => {
  const db = mockDb([{ token_address: "AAA", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "AAA" }, marketCap: 5000 },
  ])));
  const sqls = db.batched.map((s) => s.sql);
  assert.ok(sqls.some((q) => q.includes("curve_pair_seen_ms = COALESCE")), "telemetry written");
  assert.ok(!sqls.some((q) => q.includes("status='discovered'")), "curve index is NOT graduation");
  assert.ok(sqls.some((q) => q.includes("SET last_checked_ms")), "still checked");
});

test("non-pumpfun pair -> GRADUATION: discovered with gap + grad mcap", async () => {
  const db = mockDb([{ token_address: "BBB", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "BBB" }, marketCap: 68000 },
    { dexId: "raydium", baseToken: { address: "BBB" }, marketCap: 71000 },
  ])));
  const disc = db.batched.find((s) => s.sql.includes("status='discovered'"));
  assert.ok(disc, "graduation fires discovery");
  assert.equal(disc.args[0], "BBB");
  assert.equal(disc.args[2], 71000, "mcap from the GRADUATION pair, not the curve");
  assert.equal(disc.args[3], "raydium", "graduation_dex = the triggering non-pumpfun dex (0004)");
  assert.ok(db.batched.some((s) => s.sql.includes("curve_pair_seen_ms")), "curve telemetry still recorded");
  const peak = db.batched.find((s) => s.sql.includes("mc_peak_usd"));
  assert.ok(peak, "R-4: peak MC recorded");
  assert.equal(peak.args[1], 71000, "peak = max marketCap across pairs (the graduation pair)");
});

test("R-4: curve pump WITHOUT graduation records peak, stays watching (the Binface case)", async () => {
  // Token on the curve at $25k - pumped past the buy zone, never graduated.
  // This is EXACTLY the trade that was invisible before R-4.
  const db = mockDb([{ token_address: "PUMP", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "PUMP" }, marketCap: 25000 },
  ])));
  const peak = db.batched.find((s) => s.sql.includes("mc_peak_usd"));
  assert.ok(peak, "peak recorded for a pumping-but-not-graduated token");
  assert.equal(peak.args[1], 25000, "peak = the curve MC");
  assert.ok(!db.batched.some((s) => s.sql.includes("status='discovered'")), "no graduation - stays watching");
});

test("no pairs at all -> only last_checked bump", async () => {
  const db = mockDb([{ token_address: "CCC", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([])));
  assert.equal(db.batched.length, 1);
  assert.ok(db.batched[0].sql.includes("SET last_checked_ms"));
});

test("R-5: aged-out tokens expire via ONE bulk write, never polled", async () => {
  // young-select returns only fresh rows; the bulk expiry is a separate .run().
  let fetches = 0;
  const db = mockDb([]); // no young tokens this tick
  await discoveryScan(env(db, async () => { fetches++; return pairsResponse([]); }));
  assert.equal(fetches, 0, "nothing polled when the young set is empty");
  const exp = db.runs.find((r) => r.sql.includes("status='expired'"));
  assert.ok(exp, "bulk expiry UPDATE ran");
  assert.ok(exp.sql.includes("pumpfun_first_seen_ms < ?2"), "expires by age, in bulk");
});

test("R-2: 65 live tokens -> 3 batched requests of <=30, all swept", async () => {
  const rows = Array.from({ length: 65 }, (_, i) => ({
    token_address: "T" + i, pumpfun_first_seen_ms: NOW_FRESH,
  }));
  const urls = [];
  const db = mockDb(rows);
  await discoveryScan(env(db, async (url) => { urls.push(String(url)); return pairsResponse([]); }));
  assert.equal(urls.length, 3, "ceil(65/30) requests");
  const counts = urls.map((u) => u.split("/tokens/")[1].split(",").length);
  assert.deepEqual(counts, [30, 30, 5]);
  assert.equal(db.batched.length, 65, "every live token got its last_checked bump");
});

test("429 -> yields the tick politely, earlier writes still land", async () => {
  const rows = Array.from({ length: 60 }, (_, i) => ({
    token_address: "U" + i, pumpfun_first_seen_ms: NOW_FRESH,
  }));
  let call = 0;
  const db = mockDb(rows);
  await discoveryScan(env(db, async () => {
    call++;
    if (call === 2) return { ok: false, status: 429, json: async () => ({}) };
    return pairsResponse([]);
  }));
  assert.equal(call, 2, "stopped at the 429");
  assert.equal(db.batched.length, 30, "first chunk's writes still landed");
});

// ---- R-3: birthScan coverage (the winning-token-missed fix) ----
import { birthScan } from "../watcher.ts";

function birthDb() {
  const batched = [];
  return {
    batched,
    prepare(sql) { return { bind: (...args) => ({ sql, args }) }; },
    batch: async (stmts) => { batched.push(...stmts); },
    // birthScan does not read; only writes via batch.
  };
}

test("R-3: birthScan batches EVERY birth in a 120-item burst (no 50/100 cap)", async () => {
  const items = Array.from({ length: 120 }, (_, i) => ({
    mint: "M" + i, symbol: "S" + i, created_timestamp: 1783456000000 + i,
    usd_market_cap: 2300 + i,
  }));
  const db = birthDb();
  globalThis.fetch = async () => ({ ok: true, json: async () => items });
  await birthScan({ ...ENV_BIRTH, RADAR_DB: db });
  assert.equal(db.batched.length, 120, "all 120 births captured — no silent truncation");
  assert.ok(db.batched.every((s) => s.sql.includes("INSERT INTO births")), "all inserts");
  // usd_market_cap, never raw market_cap, in the mcap bind slot (index 6)
  assert.equal(db.batched[0].args[6], 2300, "usd_market_cap read (unit rule)");
});

test("R-3: idle gate still holds when the feed URL is empty", async () => {
  const db = birthDb();
  let fetched = false;
  globalThis.fetch = async () => { fetched = true; return { ok: true, json: async () => [] }; };
  await birthScan({ ...ENV_BIRTH, RADAR_DB: db, PUMPFUN_FEED_URL: "" });
  assert.equal(fetched, false, "no fetch when PUMPFUN_FEED_URL unset");
  assert.equal(db.batched.length, 0);
});

// ---- R-7: BTC regime tape ----
import { btcScan } from "../watcher.ts";

test("R-7: btcScan decodes latestRoundData and writes one regime tick", async () => {
  // real response shape captured live 2026-07-07 (answer=$63,369.45, 8 dec)
  const hex = "0x0000000000000000000000000000000000000000000000020000000000006657000000000000000000000000000000000000000000000000000005c36f5a1c10000000000000000000000000000000000000000000000000000000006a4d7651000000000000000000000000000000000000000000000000000000006a4d765f0000000000000000000000000000000000000000000000020000000000006657";
  const runs = [];
  const db = { prepare: (sql) => ({ bind: (...args) => ({ run: async () => { runs.push({ sql, args }); } }) }) };
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ jsonrpc: "2.0", id: 1, result: hex }) });
  await btcScan({ RADAR_DB: db });
  assert.equal(runs.length, 1, "one tick written");
  assert.ok(runs[0].sql.includes("regime_ticks"));
  assert.ok(Math.abs(runs[0].args[1] - 63369.45) < 0.01, "price decoded: $63,369.45");
});
