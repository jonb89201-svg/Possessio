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
  const db = {
    batched,
    prepare(sql) {
      return {
        bind(...args) {
          return {
            sql, args,
            all: async () => ({ results: watchingRows }),
            first: async () => null,
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
    DISCOVERY_BATCH: "300",
    EXPIRE_HOURS: "24",
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
});

test("no pairs at all -> only last_checked bump", async () => {
  const db = mockDb([{ token_address: "CCC", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([])));
  assert.equal(db.batched.length, 1);
  assert.ok(db.batched[0].sql.includes("SET last_checked_ms"));
});

test(">24h without graduation -> expired, no fetch for that token", async () => {
  let fetches = 0;
  const db = mockDb([{ token_address: "DDD", pumpfun_first_seen_ms: NOW_STALE }]);
  await discoveryScan(env(db, async () => { fetches++; return pairsResponse([]); }));
  assert.equal(fetches, 0, "expired rows never reach the network");
  assert.ok(db.batched[0].sql.includes("status='expired'"));
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
