// P4 harness (AUDIT_PACKET_RADAR, council item 3): deterministic tests over the
// REAL screenScan — the measurement core the whole forward ledger is computed
// by. Mocks the pump.fun feed, the Solana rug RPC, and D1; asserts entry MC,
// entry_vel, the CALIBRATED strat_take matrix (incl. the NULL-rug proof of the
// 0023 fix), and outcome resolution against hand-computed expectations.
//
//   node --test --experimental-strip-types radar/test/screen.test.mjs
//
// Why hand-computed: this suite is the instrument's own ruler. It must not
// re-derive expectations from the code it tests, so every expected number below
// is computed by hand in the comments and pinned as a literal.
import { test } from "node:test";
import assert from "node:assert/strict";
import { screenScan } from "../screen.ts";

// ---- constants mirrored from screen.ts (pinned literals, not imports) --------
const ENTRY_LOW = 8_000, ENTRY_HIGH = 13_000;
const AGE_MS = 400_000;            // 6m40s — inside the §1 4–7min window
const SOL_USD = 150;               // donor coin sets this (usd_mc/mc = 15000/100)

// ---- feed-coin builder -------------------------------------------------------
// curveMcUsd = (vsol/vtok) * supply / 1e9 * solUsd. To land a target USD MC:
//   pick supply=1e15, vtok=1e15  => (vsol/1e15)*1e15/1e9 = vsol/1e9 SOL
//   => mcUsd = (vsol/1e9) * solUsd  => vsol = mcUsd/solUsd * 1e9
function coinForMc(mint, mcUsd, extra = {}) {
  const vsol = (mcUsd / SOL_USD) * 1e9;      // lamports
  return {
    mint,
    virtual_sol_reserves: vsol,
    virtual_token_reserves: 1e15,
    total_supply: 1e15,
    real_sol_reserves: vsol,                 // ~ for the volume tape (unused in asserts)
    usd_market_cap: mcUsd,
    market_cap: mcUsd / SOL_USD,             // SOL-denominated (the ratio donor)
    ...extra,
  };
}
// The solUsd donor: usd_market_cap/market_cap = 150, ratio in (1,100000).
const DONOR = coinForMc("DONOR", 15_000);

// ---- Solana getTokenLargestAccounts response ---------------------------------
// share = maxNonCurve / (sumAll - curveAmt). curve acct excluded from float.
const CURVE_ACCT = "CURVEACCT";
function rpcAccounts(list) {
  return { ok: true, status: 200, json: async () => ({ result: { value: list } }) };
}
// 10 holders of 1e9 each + curve 1e15 => float 1e10, max 1e9 => share 0.10 <= 0.20 PASS
const HOLDERS_PASS = [
  { address: CURVE_ACCT, amount: 1e15 },
  ...Array.from({ length: 10 }, (_, i) => ({ address: "h" + i, amount: 1e9 })),
];
// whale 5e9 + 5 of 1e9 + curve => float 1e10, max 5e9 => share 0.50 > 0.20 FAIL
const HOLDERS_FAIL = [
  { address: CURVE_ACCT, amount: 1e15 },
  { address: "whale", amount: 5e9 },
  ...Array.from({ length: 5 }, (_, i) => ({ address: "h" + i, amount: 1e9 })),
];

// ---- mock D1 -----------------------------------------------------------------
// Routes .all()/.first() by SQL substring; captures every batched/run stmt.
function makeDb({ young = [], live = [], tape = [], devPrior = 0 } = {}) {
  const captured = [];
  const match = (sql) => {
    // §1 qualify: young watching births in the age window
    if (sql.includes("FROM births") && sql.includes("pumpfun_first_seen_ms <= ?1")
        && sql.includes("pumpfun_first_seen_ms >= ?2")) return { results: young };
    // live candidates to track (JOIN births)
    if (sql.includes("FROM candidates c JOIN births b") && sql.includes("c.outcome='live'"))
      return { results: live };
    // the tape set (earlies UNION live candidates)
    if (sql.includes("FROM earlies") && sql.includes("UNION")) return { results: tape };
    // everything else that .all()s (newborns, unstamped, plays, dexTrack) => empty
    return { results: [] };
  };
  const first = (sql) => {
    if (sql.includes("COUNT(*) AS n FROM births") && sql.includes("creator=?1"))
      return { n: devPrior };
    return null;
  };
  // A runnable exposes all/first/run/bind. Some screenScan queries call .all()
  // or .run() directly on prepare() (no ? params); others .bind(...) first.
  const mk = (sql, args) => ({
    sql, args,
    all: async () => match(sql),
    first: async () => first(sql),
    run: async () => { captured.push({ sql, args }); return { success: true }; },
    bind: (...a) => mk(sql, a),
  });
  const db = {
    captured,
    prepare(sql) { return mk(sql, []); },
    batch: async (stmts) => { for (const s of stmts) captured.push({ sql: s.sql, args: s.args }); },
  };
  return db;
}

// ---- fetch router ------------------------------------------------------------
// Routes by URL: pump.fun feed, DexScreener tracking, Solana RPC.
function router({ feed = [DONOR], dexPairs = [], rpc = null } = {}) {
  return async (url, init) => {
    const u = String(url);
    if (u.includes("pump.fun") || u.includes("feed"))
      return { ok: true, status: 200, json: async () => feed };
    if (u.includes("dexscreener") || u.includes("dex"))
      return { ok: true, status: 200, json: async () => ({ pairs: dexPairs }) };
    if (rpc && init?.method === "POST" && String(init.body).includes("getTokenLargestAccounts"))
      return rpc;
    // solUsd RPC etc. — benign empty
    return { ok: true, status: 200, json: async () => ({}) };
  };
}

function baseEnv(db, fetchImpl, over = {}) {
  globalThis.fetch = fetchImpl;
  return {
    RADAR_DB: db,
    PUMPFUN_FEED_URL: "https://frontend-api-v3.pump.fun/coins",
    DEXSCREENER_TOKEN_URL: "https://api.dexscreener.com/tokens/",
    STRAT_VEL_LO: "7", STRAT_VEL_HI: "20",
    STRAT_TARGET_PCT: "0.50", STRAT_STOP_PCT: "0.40",
    DEV_REP_MAX_PRIOR: "20", RUG_MAX_TOP_HOLDER_PCT: "0.20",
    ...over, // SOLANA_RPC_URL added per-test (absent => rug UNKNOWN)
  };
}

// A watching birth row shaped like the §1 qualify SELECT returns.
function birthRow(mint, { bornMsAgo = AGE_MS, mcAtBirth = 4_000, creator = "creatorX" } = {}) {
  return {
    token_address: mint, symbol: "SYM", name: "Name", creator,
    pumpfun_first_seen_ms: Date.now() - bornMsAgo,
    raw_birth_json: JSON.stringify({ associated_bonding_curve: CURVE_ACCT }),
    mc_at_birth_usd: mcAtBirth,
  };
}

function candidateInsert(db) {
  return db.captured.find((c) => c.sql.includes("INSERT INTO candidates"));
}
// INSERT arg order (screen.ts): [0]token [1]sym [2]name [3]creator [4]now
//   [5]ageSec [6]entry_mc [7]devPrior [8]gateDev [9]gateRug [10]topShare
//   [11]entry_vel [12]strat_take
const A = { ENTRY_MC: 6, DEV_PRIOR: 7, GATE_DEV: 8, GATE_RUG: 9, ENTRY_VEL: 11, STRAT_TAKE: 12 };

// =============================================================================
// ENTRY MEASUREMENT
// =============================================================================
test("curveMcUsd: in-band coin qualifies with entry_mc = hand-computed $10,000", async () => {
  // vsol = 10000/150*1e9; (vsol/1e15)*1e15/1e9*150 = 10000 exactly.
  const mint = "TIN";
  const db = makeDb({ young: [birthRow(mint)] });
  const env = baseEnv(db, router({ feed: [DONOR, coinForMc(mint, 10_000)] }),
    { SOLANA_RPC_URL: "https://sol.rpc" });
  globalThis.fetch = router({ feed: [DONOR, coinForMc(mint, 10_000)], rpc: rpcAccounts(HOLDERS_PASS) });
  await screenScan(env);
  const ins = candidateInsert(db);
  assert.ok(ins, "candidate inserted");
  assert.ok(Math.abs(ins.args[A.ENTRY_MC] - 10_000) < 1, `entry_mc ~10000, got ${ins.args[A.ENTRY_MC]}`);
});

test("out-of-band (too high) coin does NOT qualify", async () => {
  const mint = "THIGH";
  const db = makeDb({ young: [birthRow(mint)] });
  const env = baseEnv(db, router({ feed: [DONOR, coinForMc(mint, 30_000)], rpc: rpcAccounts(HOLDERS_PASS) }),
    { SOLANA_RPC_URL: "https://sol.rpc" });
  globalThis.fetch = router({ feed: [DONOR, coinForMc(mint, 30_000)], rpc: rpcAccounts(HOLDERS_PASS) });
  await screenScan(env);
  assert.equal(candidateInsert(db), undefined, "no candidate for a $30k coin (> ENTRY_HIGH)");
});

test("entry_vel = (entry_mc - mc_at_birth)/ageSec, hand-computed = 15", async () => {
  // entry 10000, birth 4000, age 400s => (6000)/400 = 15.
  const mint = "TVEL";
  const db = makeDb({ young: [birthRow(mint, { mcAtBirth: 4_000, bornMsAgo: 400_000 })] });
  globalThis.fetch = router({ feed: [DONOR, coinForMc(mint, 10_000)], rpc: rpcAccounts(HOLDERS_PASS) });
  const env = baseEnv(db, globalThis.fetch, { SOLANA_RPC_URL: "https://sol.rpc" });
  await screenScan(env);
  const ins = candidateInsert(db);
  assert.ok(Math.abs(ins.args[A.ENTRY_VEL] - 15) < 0.2, `entry_vel ~15, got ${ins.args[A.ENTRY_VEL]}`);
});

// =============================================================================
// strat_take — the CALIBRATED matrix (0023). gateRug === 1 required.
// =============================================================================
async function runTake({ mcAtBirth = 4_000, devPrior = 0, rpc = rpcAccounts(HOLDERS_PASS),
                          solRpc = "https://sol.rpc", entryMc = 10_000 } = {}) {
  const mint = "TAKE" + Math.round(mcAtBirth) + "_" + devPrior + (solRpc ? "R" : "N");
  const db = makeDb({ young: [birthRow(mint, { mcAtBirth })], devPrior });
  globalThis.fetch = router({ feed: [DONOR, coinForMc(mint, entryMc)], rpc });
  const over = solRpc ? { SOLANA_RPC_URL: solRpc } : {};
  await screenScan(baseEnv(db, globalThis.fetch, over));
  return candidateInsert(db);
}

test("strat_take=1: momentum in band + fresh dev + rug AFFIRMED pass", async () => {
  const ins = await runTake({});
  assert.equal(ins.args[A.GATE_DEV], 1, "fresh dev");
  assert.equal(ins.args[A.GATE_RUG], 1, "rug pass");
  assert.equal(ins.args[A.STRAT_TAKE], 1, "TAKE");
});

test("strat_take=0: rug UNKNOWN (RPC absent) — THE 0023 calibration proof", async () => {
  // No SOLANA_RPC_URL => topHolderShare returns null => gate_rug NULL.
  const ins = await runTake({ solRpc: null });
  assert.equal(ins.args[A.GATE_RUG], null, "gate_rug recorded NULL (unknown, not pass)");
  assert.equal(ins.args[A.STRAT_TAKE], 0, "NULL rug MUST suppress the take (was silently PASS pre-0023)");
});

test("strat_take=0: rug HARD FAIL (whale on float)", async () => {
  const ins = await runTake({ rpc: rpcAccounts(HOLDERS_FAIL) });
  assert.equal(ins.args[A.GATE_RUG], 0, "rug fail");
  assert.equal(ins.args[A.STRAT_TAKE], 0, "hard rug fail suppresses take");
});

test("strat_take=0: serial dev (>20 prior launches)", async () => {
  const ins = await runTake({ devPrior: 25 });
  assert.equal(ins.args[A.GATE_DEV], 0, "serial dev");
  assert.equal(ins.args[A.STRAT_TAKE], 0, "serial dev suppresses take");
});

test("strat_take=0: momentum out of band (vel < 7) though in MC band", async () => {
  // birth 9500, entry 10000, age 400 => vel 1.25 < 7. In MC band => qualifies,
  // but strat_take=0. Records the rejection for taken-vs-rejected compare.
  const ins = await runTake({ mcAtBirth: 9_500 });
  assert.ok(ins, "candidate still inserted (in MC band)");
  assert.ok(ins.args[A.ENTRY_VEL] < 7, `vel ${ins.args[A.ENTRY_VEL]} < 7`);
  assert.equal(ins.args[A.STRAT_TAKE], 0, "slow momentum suppresses take");
});

// =============================================================================
// OUTCOME RESOLUTION (P1-b path — entry-relative target/stop/timestop)
// =============================================================================
function liveCandidate(mint, { entryMc = 10_000, qualifiedMsAgo = 60_000 } = {}) {
  return {
    token_address: mint, peak_mc: entryMc, entry_mc: entryMc,
    bstatus: "watching", qualified_ms: Date.now() - qualifiedMsAgo,
  };
}
const outcomeUpdate = (db) => db.captured.find((c) => c.sql.includes("SET outcome=?2, outcome_ms=?3"));
// setOutcome args: [0]addr [1]outcome [2]now [3]lastMc
const dexPair = (mint, mc) => ({ baseToken: { address: mint }, dexId: "pumpfun", marketCap: mc, volume: { m5: 0 } });

test("outcome=target: entry-relative +50% cross (15000 >= 10000*1.5)", async () => {
  const mint = "TGT";
  const db = makeDb({ live: [liveCandidate(mint)], tape: [{ token_address: mint }] });
  globalThis.fetch = router({ feed: [DONOR], dexPairs: [dexPair(mint, 15_000)] });
  await screenScan(baseEnv(db, globalThis.fetch));
  const u = outcomeUpdate(db);
  assert.ok(u, "outcome update emitted");
  assert.equal(u.args[1], "target", "target at +50%");
});

test("outcome=stop: entry-relative -40% cross (6000 <= 10000*0.6)", async () => {
  const mint = "STP";
  const db = makeDb({ live: [liveCandidate(mint)], tape: [{ token_address: mint }] });
  globalThis.fetch = router({ feed: [DONOR], dexPairs: [dexPair(mint, 6_000)] });
  await screenScan(baseEnv(db, globalThis.fetch));
  assert.equal(outcomeUpdate(db).args[1], "stop", "stop at -40%");
});

test("outcome=timestop: aged past 10min with no target/stop cross", async () => {
  const mint = "TSP";
  // qualified 11min ago, MC flat at entry => neither target nor stop => timestop.
  const db = makeDb({ live: [liveCandidate(mint, { qualifiedMsAgo: 11 * 60_000 })], tape: [{ token_address: mint }] });
  globalThis.fetch = router({ feed: [DONOR], dexPairs: [dexPair(mint, 10_000)] });
  await screenScan(baseEnv(db, globalThis.fetch));
  assert.equal(outcomeUpdate(db).args[1], "timestop", "timestop past 10min");
});
