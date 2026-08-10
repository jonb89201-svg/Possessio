// /radar/tape-ingest DoD. Offline: fake D1, fake recordScan, real handler.
//
// The route is the ONLY write path from the Railway tape into the ledger, so
// what these prove is the boundary: nothing unauthenticated writes, nothing
// outside the whitelist executes, and the health heartbeat lands on the same
// feed_status surface the console reads (where board row 90's diagnosis came
// from). The engine emits, this executes — the two suites meet at the `p`
// array contract pinned here.
import assert from "node:assert";
import { handleTapeIngest, TAPE_SQL } from "../../radar/tape-ingest.js";

let pass = 0;
const t = async (name, fn) => {
  try { await fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};

console.log("Tape ingest route — DoD\n");

const TOKEN = "test-token-THIS-NEVER-SHIPS";

function fakeEnv({ token = TOKEN, failBatch = false } = {}) {
  const executed = [];
  return {
    executed,
    TAPE_INGEST_TOKEN: token,
    RADAR_DB: {
      prepare(sql) { return { bind(...p) { return { sql, p }; } }; },
      async batch(stmts) {
        if (failBatch) throw new Error("D1 down");
        executed.push(...stmts);
      },
    },
  };
}
const scans = [];
const recordScan = async (_env, scan, ms, err) => { scans.push({ scan, ms, err }); };
const post = (env, body, auth) =>
  handleTapeIngest(
    new Request("https://radar/radar/tape-ingest", {
      method: "POST",
      headers: auth === undefined ? { authorization: "Bearer " + TOKEN } : auth ? { authorization: auth } : {},
      body: JSON.stringify(body),
    }),
    env, recordScan,
  );

const HIT_P = ["MintA", "TT", "TapeTest", 1, 3500, 30, 30000, 5, 1, 7.5, 4, 0.4, null, null, null];

await t("no configured token: 503, refuses rather than silently accepting", async () => {
  const env = fakeEnv({ token: "" });
  const r = await post(env, { v: 1, effects: [] });
  assert.strictEqual(r.status, 503);
});

await t("wrong bearer: 401, nothing executed", async () => {
  const env = fakeEnv();
  const r = await post(env, { v: 1, effects: [{ k: "hit", p: HIT_P }] }, "Bearer wrong");
  assert.strictEqual(r.status, 401);
  assert.strictEqual(env.executed.length, 0);
});

await t("a valid batch executes the EXACT pumptape statements, params bound 1:1", async () => {
  const env = fakeEnv();
  const effects = [
    { k: "hit", p: HIT_P },
    { k: "cycle", p: ["MintA", 1, "ladder", 3500, 7750, 4, 2] },
    { k: "level1", p: ["MintA", "target", 7750, 2, 4] },
    { k: "headline", p: ["MintA", 1, 2.214] },
  ];
  const r = await post(env, { v: 1, health: { status: "ok" }, effects });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(env.executed.length, 4);
  assert.strictEqual(env.executed[0].sql, TAPE_SQL.hit.sql);
  assert.deepStrictEqual(env.executed[0].p, HIT_P);
  // the statements are the pumptape.ts originals — pin their load-bearing shape
  assert.match(TAPE_SQL.hit.sql, /ON CONFLICT\(token_address\) DO UPDATE/);
  assert.match(TAPE_SQL.level1.sql, /play_outcome IS NULL/, "level1 must never overwrite an outcome");
  assert.match(TAPE_SQL.cycle.sql, /INSERT INTO early_cycles/);
});

await t("an unknown effect kind rejects the whole batch, 400, nothing executed", async () => {
  const env = fakeEnv();
  const r = await post(env, { v: 1, effects: [{ k: "drop_table", p: [] }] });
  assert.strictEqual(r.status, 400);
  assert.strictEqual(env.executed.length, 0);
});

await t("wrong arity or non-scalar params reject, 400", async () => {
  const env = fakeEnv();
  assert.strictEqual((await post(env, { effects: [{ k: "headline", p: ["M", 1] }] })).status, 400);
  assert.strictEqual((await post(env, { effects: [{ k: "headline", p: ["M", 1, { evil: 1 }] }] })).status, 400);
  // NaN cannot cross JSON (stringifies to null), so the transport-expressible
  // numeric violation is an overlong string, not a non-finite number
  assert.strictEqual((await post(env, { effects: [{ k: "headline", p: ["M".repeat(201), 1, 1] }] })).status, 400);
  assert.strictEqual(env.executed.length, 0);
});

await t("oversized batches reject at 500 effects", async () => {
  const env = fakeEnv();
  const effects = Array.from({ length: 501 }, () => ({ k: "headline", p: ["M", 1, 1] }));
  assert.strictEqual((await post(env, { effects })).status, 400);
});

await t("the health heartbeat lands in feed_status: ok clears, anything else records the cause", async () => {
  scans.length = 0;
  const env = fakeEnv();
  await post(env, { health: { status: "ok" }, effects: [] });
  assert.strictEqual(scans[0].scan, "pumptapeTrades");
  assert.strictEqual(scans[0].err, null);
  await post(env, { health: { status: "trade_stream_dead", detail: "key drained" }, effects: [] });
  assert.match(String(scans[1].err), /trade_stream_dead: key drained/);
});

await t("a D1 failure records the error and answers 500 — never a silent drop", async () => {
  scans.length = 0;
  const env = fakeEnv({ failBatch: true });
  const r = await post(env, { health: { status: "ok" }, effects: [{ k: "headline", p: ["M", 1, 1] }] });
  assert.strictEqual(r.status, 500);
  assert.match(String(scans[0].err), /D1 down/);
});

console.log(`\n${pass} passed${process.exitCode ? " — WITH FAILURES" : ""}`);
