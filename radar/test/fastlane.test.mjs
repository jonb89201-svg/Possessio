// Offline proof of the BORN LOADED fast lane's pure core + the health verdict
// (RESEARCH_RadarMethod_20260812 §3/§5). No network, no D1 — these are the
// pure functions the scan paths call, tested at their edges.
//   node --test --experimental-strip-types radar/test/fastlane.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { scoreBirth, launcherOf, FAST_BAND_LO, FAST_BAND_CORE, FAST_BAND_HI } from "../watcher.ts";
import { momentumTag } from "../screen.ts";
import { healthVerdict } from "../health.ts";

// ── scoreBirth: the F1 band gate ──────────────────────────────────────────

test("scoreBirth: junk floor + 8k+ are rejected — the band is 3-8k only", () => {
  assert.equal(scoreBirth(2_100, 30, 12, null), null, "empty-curve junk");
  assert.equal(scoreBirth(FAST_BAND_LO - 1, 30, 12, null), null, "below band");
  assert.equal(scoreBirth(FAST_BAND_HI + 1, 30, 12, null), null, "8k+ is structurally late");
  assert.equal(scoreBirth(null, 30, 12, null), null, "no MC read");
});

test("scoreBirth: sighting must be first-sighting (<=90s), never a late look", () => {
  assert.equal(scoreBirth(6_000, 91, 12, null), null, "aged past the window");
  assert.equal(scoreBirth(6_000, -5, 12, null), null, "negative age = clock lie");
  assert.notEqual(scoreBirth(6_000, 90, 12, null), null, "boundary inclusive");
  assert.notEqual(scoreBirth(6_000, 0, 12, null), null, "instant sighting");
});

test("scoreBirth: core band 5-8k carries the measured 22.4 baseline", () => {
  const r = scoreBirth(6_500, 30, 12, null);
  assert.equal(r.band, "core");
  assert.equal(r.regimeHot, 0);
  assert.equal(r.score, 22.4);
  const lo = scoreBirth(4_000, 30, 12, null);
  assert.equal(lo.band, "lower");
  assert.equal(lo.score, 10.2);
  // band boundary: exactly 5k is core
  assert.equal(scoreBirth(FAST_BAND_CORE, 30, 12, null).band, "core");
});

test("scoreBirth: UTC 00-06 hot regime multiplies (F2/F3 stack)", () => {
  const hot = scoreBirth(6_500, 30, 3, null);
  assert.equal(hot.regimeHot, 1);
  assert.equal(hot.score, 26.9); // 22.4 * 1.2, rounded to 1dp
  assert.equal(scoreBirth(6_500, 30, 6, null).regimeHot, 0, "hour 6 is out");
  assert.equal(scoreBirth(6_500, 30, 0, null).regimeHot, 1, "hour 0 is in");
});

test("scoreBirth: dev freshness nudges, never gates (F5 is weak by design)", () => {
  const fresh = scoreBirth(6_500, 30, 12, 0);
  const serial = scoreBirth(6_500, 30, 12, 11);
  assert.ok(fresh.score > 22.4, "fresh dev promotes");
  assert.ok(serial.score < 22.4, "serial launcher demotes");
  assert.notEqual(serial, null, "a serial dev still stamps — rank, not gate");
});

// ── launcherOf: the F6 launcher-tool fingerprint ──────────────────────────

test("launcherOf: first URL host, lowercased, bounded", () => {
  assert.equal(launcherOf("launched via https://Bump.FUN/tool now live"), "bump.fun");
  assert.equal(launcherOf("no links here"), null);
  assert.equal(launcherOf(null), null);
  assert.equal(launcherOf(42), null);
  assert.equal(launcherOf("see http://a.b/x and https://c.d/y"), "a.b", "first wins");
  const long = launcherOf("https://" + "x".repeat(200) + ".com/");
  assert.ok(long.length <= 60, "host is bounded");
});

// ── momentumTag: the F4 from-entry 3-min read ─────────────────────────────

test("momentumTag: hot/warm/flat/down at the exact edges", () => {
  assert.equal(momentumTag(2.0), "hot");
  assert.equal(momentumTag(1.99), "warm");
  assert.equal(momentumTag(1.3), "warm");
  assert.equal(momentumTag(1.29), "flat");
  assert.equal(momentumTag(0.95), "flat");
  assert.equal(momentumTag(0.94), "down");
  assert.equal(momentumTag(0.1), "down");
});

// ── healthVerdict: the False-Green killer ─────────────────────────────────

const NOW = 1_755_000_000_000;
const row = (scan, okAgoMs, errAgoMs = null, err = null) => ({
  scan,
  last_ok_ms: okAgoMs == null ? null : NOW - okAgoMs,
  last_err_ms: errAgoMs == null ? null : NOW - errAgoMs,
  last_err: err,
});
const allFresh = () => [
  row("birthScan", 30_000), row("screenScan", 30_000), row("discoveryScan", 30_000),
  row("dexTrackScan", 30_000), row("pumptapeTrades", 60_000), row("btcScan", 30_000),
  row("sessionGateScan", 600_000), row("tapeWatchdog", 30_000), row("pumptapeEnsure", 30_000),
];

test("health: all feeds current -> green", () => {
  const v = healthVerdict(allFresh(), NOW);
  assert.equal(v.overall, "green");
  assert.equal(v.reason, "all feeds current");
  assert.ok(v.scans.every((s) => s.ok));
});

test("health: dead tape -> RED naming the feed and its age (the 50h lesson)", () => {
  const rows = allFresh().filter((r) => r.scan !== "pumptapeTrades");
  rows.push(row("pumptapeTrades", 50 * 3600_000));
  const v = healthVerdict(rows, NOW);
  assert.equal(v.overall, "red");
  assert.match(v.reason, /pumptapeTrades/);
  assert.match(v.reason, /50\.0h/, "age is named, not hidden");
});

test("health: non-critical staleness -> yellow, never red", () => {
  const rows = allFresh().filter((r) => r.scan !== "btcScan");
  rows.push(row("btcScan", 3600_000));
  const v = healthVerdict(rows, NOW);
  assert.equal(v.overall, "yellow");
  assert.match(v.reason, /btcScan/);
});

test("health: a scan that NEVER ran is not silently green", () => {
  const rows = allFresh().filter((r) => r.scan !== "birthScan");
  const v = healthVerdict(rows, NOW);
  assert.equal(v.overall, "red");
  assert.match(v.reason, /birthScan never ran/);
});

test("health: latest run errored -> not ok even with a recent OK behind it", () => {
  const rows = allFresh().filter((r) => r.scan !== "birthScan");
  rows.push(row("birthScan", 60_000, 10_000, "boom: upstream 500"));
  const v = healthVerdict(rows, NOW);
  assert.equal(v.overall, "red");
  assert.match(v.reason, /boom: upstream 500/, "the recorded cause surfaces verbatim");
});

test("health: TAPE_HOST=railway ignores the dormant DO's ensure row", () => {
  const rows = allFresh().filter((r) => r.scan !== "pumptapeEnsure");
  rows.push(row("pumptapeEnsure", 50 * 3600_000)); // stale — dormant by design
  assert.equal(healthVerdict(rows, NOW, "railway").overall, "green", "dormant DO must not color the verdict");
  assert.equal(healthVerdict(rows, NOW).overall, "yellow", "without railway it DOES count");
});
