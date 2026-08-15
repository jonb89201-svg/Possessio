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

// PAID-PROFILE SIGNAL (2026-08-15, Architect: shown live DexScreener listings
// where a huge headline MC sat on near-zero liquidity — creators paying for a
// token-info profile or an active boost). Read off the SAME pairs response
// already fetched for graduation/peak — no new request.
test("a pair with info.socials sets dex_paid_profile=1", async () => {
  const db = mockDb([{ token_address: "SOC", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "SOC" }, marketCap: 5000,
      info: { socials: [{ type: "twitter", url: "https://x.com/soc" }], websites: [] } },
  ])));
  const profile = db.batched.find((s) => s.sql.includes("dex_paid_profile"));
  assert.ok(profile, "paid-profile UPDATE emitted");
  assert.equal(profile.args[0], "SOC");
  assert.equal(profile.args[1], 1, "socials present -> paid profile flag = 1");
});

test("a pair with an active boost sets dex_boost_active to the boost count", async () => {
  const db = mockDb([{ token_address: "BST", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "BST" }, marketCap: 5000, boosts: { active: 60 } },
  ])));
  const profile = db.batched.find((s) => s.sql.includes("dex_paid_profile"));
  assert.ok(profile, "boost UPDATE emitted even with no socials/websites");
  assert.equal(profile.args[2], 60, "dex_boost_active = the boosts.active count");
});

test("a plain pair with neither info nor boosts emits no paid-profile write", async () => {
  const db = mockDb([{ token_address: "PLAIN", pumpfun_first_seen_ms: NOW_FRESH }]);
  await discoveryScan(env(db, async () => pairsResponse([
    { dexId: "pumpfun", baseToken: { address: "PLAIN" }, marketCap: 5000 },
  ])));
  assert.ok(!db.batched.some((s) => s.sql.includes("dex_paid_profile")),
    "no false-positive write when the pair carries no paid signal");
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

// ---- R-1 (AUDIT 2026-07-14): raw_birth_json is VALID JSON, never a truncation ----
// The old JSON.stringify(it).slice(0,4000) turned any >4KB payload (a
// creator-controlled long description is enough) into invalid JSON; SQLite's
// json_extract then THREW "malformed JSON" on every /radar/candidates poll —
// an externally triggerable 500 of the public feed.

test("R-1: >4000-char birth payload stores VALID slim JSON (image_uri survives)", async () => {
  const huge = {
    mint: "HUGE", symbol: "HG", created_timestamp: 1783456000000,
    usd_market_cap: 3100, image_uri: "https://ipfs.example/huge.png",
    twitter: "https://x.com/huge", reply_count: 7,
    description: "x".repeat(6000), // the attack payload: pushes the doc past the cap
  };
  const small = {
    mint: "SMOL", symbol: "SM", created_timestamp: 1783456000001,
    usd_market_cap: 2900, image_uri: "https://ipfs.example/smol.png",
  };
  const db = birthDb();
  globalThis.fetch = async () => ({ ok: true, json: async () => [huge, small] });
  await birthScan({ ...ENV_BIRTH, RADAR_DB: db });
  assert.equal(db.batched.length, 2, "both births captured");
  const rawOf = (mint) => db.batched.find((s) => s.args[0] === mint).args[7];

  // oversize -> slimmed object: PARSES (json_valid would pass), keeps the
  // fields downstream reads, and is marked slimmed — never a mid-doc cut.
  const slim = JSON.parse(rawOf("HUGE")); // the old code made this line throw
  assert.equal(slim.image_uri, "https://ipfs.example/huge.png", "the field /radar/candidates extracts survives");
  assert.equal(slim.twitter, "https://x.com/huge", "roadmap signal kept");
  assert.equal(slim.slimmed, true, "oversize payload marked slimmed");
  assert.ok(rawOf("HUGE").length <= 4000, "slim doc respects the storage cap");

  // in-cap -> the full payload, stored whole (unchanged behavior)
  assert.deepEqual(JSON.parse(rawOf("SMOL")), small, "small payload round-trips in full");
});

test("R-1: exactly-at-cap payload is kept whole, one char over is slimmed", async () => {
  const { rawBirthJson } = await import("../watcher.ts");
  const pad = (target) => { // build an item whose serialization is exactly `target` chars
    const base = { mint: "PAD", image_uri: "u", description: "" };
    const skel = JSON.stringify(base).length;
    return { ...base, description: "d".repeat(target - skel) };
  };
  const atCap = pad(4000);
  assert.equal(JSON.stringify(atCap).length, 4000, "fixture sanity");
  assert.deepEqual(JSON.parse(rawBirthJson(atCap)), atCap, "at-cap doc stored in full");
  const over = pad(4001);
  const slim = JSON.parse(rawBirthJson(over));
  assert.equal(slim.slimmed, true, "over-cap doc slimmed");
  assert.equal(slim.image_uri, "u", "extracted field intact");
});

// N-3 (audit 2026-07-23): the R-1 slimming dropped associated_bonding_curve,
// which screen.ts's rug gate reads to exclude the bonding curve from the float.
// Undefined there does not read as "unknown" — it makes the curve score as the
// top HOLDER, so gate_rug resolves to 0 (a FALSE rug fail) on every coin whose
// birth payload exceeds the cap. This test is the guard: EVERY field a
// downstream consumer reads must survive slimming. Add the field here when you
// add the reader, and this fails loudly if slimming ever drops one again.
test("N-3: slimming preserves every field a consumer reads", async () => {
  const { rawBirthJson } = await import("../watcher.ts");
  // field -> the consumer that reads it (kept in the assertion message so a
  // failure names WHO breaks, not just WHAT is missing)
  const CONSUMED = {
    image_uri: "x402-toll.ts json_extract('$.image_uri')",
    associated_bonding_curve: "screen.ts topHolderShare(curveAcct) — rug gate",
  };
  const base = { mint: "RUG", ...Object.fromEntries(Object.keys(CONSUMED).map((k) => [k, `v_${k}`])), description: "" };
  const over = { ...base, description: "d".repeat(4001 - JSON.stringify(base).length) };
  assert.ok(JSON.stringify(over).length > 4000, "fixture is over-cap");

  const slim = JSON.parse(rawBirthJson(over));
  assert.equal(slim.slimmed, true, "fixture slimmed");
  for (const [field, consumer] of Object.entries(CONSUMED)) {
    assert.equal(slim[field], `v_${field}`, `slimming dropped '${field}' — breaks ${consumer}`);
  }
  // and the curve account specifically survives as a usable value, not undefined
  assert.notEqual(slim.associated_bonding_curve, undefined, "curve account must never be undefined after slimming");
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
