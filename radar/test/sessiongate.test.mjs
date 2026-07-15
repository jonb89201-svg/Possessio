// Offline proof of the §0 SESSION GATE writer (sessiongate.ts). Mocks D1;
// runs the REAL sessionGateScan + sessionGateResponse. No network, no fetch.
//   node --test radar/test/sessiongate.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { sessionGateScan, sessionGateResponse } from "../sessiongate.ts";

const H = 3_600_000;

// Mock D1: dispatches reads by SQL fragment, captures writes (INSERT ... ON
// CONFLICT). Handles both the no-bind cadence read (.first()) and the bound
// births read / insert (.bind().first() / .bind().run()).
function mockDb({ lastMs = null, winN = 0, baseN = 0, oldest = null, throwOn = null } = {}) {
  const writes = [];
  const firstFor = (sql) => {
    if (throwOn && sql.includes(throwOn)) throw new Error("boom");
    if (sql.includes("MAX(recorded_ms)")) return { last_ms: lastMs };
    if (sql.includes("FROM births")) return { win_n: winN, base_n: baseN, oldest_ms: oldest };
    return null;
  };
  return {
    writes,
    prepare(sql) {
      return {
        first: async () => firstFor(sql),
        bind: (...args) => ({
          sql, args,
          first: async () => firstFor(sql),
          run: async () => {
            if (throwOn && sql.includes(throwOn)) throw new Error("boom");
            writes.push({ sql, args });
            return { success: true };
          },
        }),
      };
    },
  };
}

// A full week of span so the denominators are the plain window/baseline hours:
//   windowRate = winN/24, baselineRate = baseN/168.
const NOW = Date.UTC(2026, 6, 15, 12, 0, 0); // deterministic clock
const FULL_SPAN_OLDEST = NOW - 168 * H;      // span == baseline span (168h)

// INSERT bind order (sessiongate.ts):
//  0 session_date  1 trailing_vol(windowRate)  2 avg_7d_vol(baselineRate)
//  3 ratio  4 gate_pass  5 threshold_used  6 basis  7 recorded_ms
const w = (db) => db.writes[0].args;

test("computes ratio = window_rate / baseline_rate from seeded data", async () => {
  const db = mockDb({ winN: 120, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: db }, NOW);
  assert.equal(db.writes.length, 1, "one reading written");
  const a = w(db);
  assert.equal(a[1], 5, "window rate = 120/24 = 5 births/hr");
  assert.equal(a[2], 10, "baseline rate = 1680/168 = 10 births/hr");
  assert.equal(a[3], 0.5, "ratio = 5/10");
  assert.equal(a[4], 0, "gate_pass=0: 0.5 < 0.65 default -> sit out (§0)");
  assert.equal(a[5], 0.65, "threshold_used stored per-reading (default)");
  assert.equal(a[7], NOW, "recorded_ms = measured_at clock");
  assert.equal(a[0], "2026-07-15", "session_date = YYYY-MM-DD UTC");
});

test("pass/fail flips exactly at the threshold", async () => {
  // baseline rate fixed at 10; ratio = winN/240. 0.65 boundary => winN=156.
  const atOrAbove = mockDb({ winN: 156, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: atOrAbove }, NOW);
  assert.equal(w(atOrAbove)[3], 0.65, "ratio == threshold");
  assert.equal(w(atOrAbove)[4], 1, "ratio >= threshold passes");

  const below = mockDb({ winN: 155, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: below }, NOW);
  assert.equal(w(below)[4], 0, "one birth/window below the line fails");
});

test("threshold override is respected (§7 — never frozen)", async () => {
  // ratio 0.65 (winN=156). Tighter 0.9 -> fail; looser 0.5 -> pass.
  const tight = mockDb({ winN: 156, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: tight, SESSION_GATE_THRESHOLD: "0.9" }, NOW);
  assert.equal(w(tight)[5], 0.9, "override stored");
  assert.equal(w(tight)[4], 0, "0.65 < 0.9 -> fail under the tighter gate");

  const loose = mockDb({ winN: 156, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: loose, SESSION_GATE_THRESHOLD: "0.5" }, NOW);
  assert.equal(w(loose)[5], 0.5, "override stored");
  assert.equal(w(loose)[4], 1, "0.65 >= 0.5 -> pass under the looser gate");
});

test("window/baseline hour overrides feed the rate math", async () => {
  // window=12h, baseline=1d(24h). windowRate=winN/12, baselineRate=baseN/24.
  const db = mockDb({ winN: 120, baseN: 240, oldest: NOW - 24 * H });
  await sessionGateScan(
    { RADAR_DB: db, SESSION_WINDOW_HOURS: "12", SESSION_BASELINE_DAYS: "1" }, NOW);
  assert.equal(w(db)[1], 10, "window rate = 120/12");
  assert.equal(w(db)[2], 10, "baseline rate = 240/24");
  assert.equal(w(db)[3], 1, "ratio = 1");
});

test("fail-soft: a compute error throws NOTHING and writes NOTHING", async () => {
  const db = mockDb({ throwOn: "FROM births", lastMs: null });
  await assert.doesNotReject(
    () => sessionGateScan({ RADAR_DB: db }, NOW), "never throws into the cron");
  assert.equal(db.writes.length, 0, "last reading preserved — no clobber on error");
});

test("cadence gate: fresh reading -> NO recompute; stale -> recompute", async () => {
  // Fresh: last reading 1 min ago, default 1h interval -> skip.
  const fresh = mockDb({ lastMs: NOW - 60_000, winN: 120, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: fresh }, NOW);
  assert.equal(fresh.writes.length, 0, "not due yet -> no write (no per-60s recompute)");

  // Stale: last reading 2h ago -> due -> writes.
  const stale = mockDb({ lastMs: NOW - 2 * H, winN: 120, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: stale }, NOW);
  assert.equal(stale.writes.length, 1, "past the interval -> recomputes");

  // Override the cadence: 30-min interval, last reading 45 min ago -> due.
  const cfg = mockDb({ lastMs: NOW - 45 * 60_000, winN: 120, baseN: 1680, oldest: FULL_SPAN_OLDEST });
  await sessionGateScan({ RADAR_DB: cfg, SESSION_RECOMPUTE_MS: "1800000" }, NOW);
  assert.equal(cfg.writes.length, 1, "cadence override respected");
});

test("insufficient history is refused, not fabricated", async () => {
  const empty = mockDb({ baseN: 0, oldest: null }); // no births at all
  await sessionGateScan({ RADAR_DB: empty }, NOW);
  assert.equal(empty.writes.length, 0, "no baseline -> leave last reading");

  const young = mockDb({ winN: 3, baseN: 3, oldest: NOW - 30 * 60_000 }); // 30-min tape
  await sessionGateScan({ RADAR_DB: young }, NOW);
  assert.equal(young.writes.length, 0, "span < 1h -> refuse (no honest baseline yet)");
});

test("route shape lines up with xtrade facts.js sessionGate reader", async () => {
  // NO_READING_YET when nothing stored (the reader treats this as null -> refuse).
  assert.deepEqual(sessionGateResponse(null), { error: "NO_READING_YET" });

  const row = {
    session_date: "2026-07-15", trailing_vol: 5, avg_7d_vol: 10, ratio: 0.5,
    gate_pass: 0, threshold_used: 0.65, basis: "births/hour ...", recorded_ms: 1783,
  };
  const j = sessionGateResponse(row);

  // THE facts.js contract (fetchSessionGateReading): accepts iff ratio is a
  // number AND gate_pass is present; then reads gate_pass, ratio, session_date.
  assert.equal(typeof j.ratio === "number" && "gate_pass" in j, true, "facts.js accepts it");
  assert.equal(j.gate_pass, 0, "native gate_pass consumed verbatim");
  assert.equal(j.ratio, 0.5, "native ratio consumed verbatim");
  assert.equal(j.session_date, "2026-07-15", "native session_date consumed verbatim");

  // friendly task-spec aliases
  assert.equal(j.pass, false, "pass mirrors !!gate_pass");
  assert.equal(j.window_metric, 5);
  assert.equal(j.baseline_7d, 10);
  assert.equal(j.threshold, 0.65);
  assert.equal(j.measured_at, 1783);
  assert.equal(j.basis, "births/hour ...");

  // a passing reading flips pass true
  assert.equal(sessionGateResponse({ ...row, gate_pass: 1 }).pass, true);
});
