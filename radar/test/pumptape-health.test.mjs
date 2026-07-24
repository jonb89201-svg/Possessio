// THE DRAINING METER (audit 2026-07-24) — terminal proof of tapeHealth().
//
// subscribeNewToken is FREE and keyless; subscribeTokenTrade needs a PumpPortal
// key funded >=0.02 SOL. When the key drains, the SOCKET STAYS UP and births keep
// arriving — only the trade stream dies. So `connected: true` kept reading healthy
// while the tape (the full-population referee every forward claim is graded
// against) silently stopped accruing: a False Green in the monitoring surface
// itself, and one that fires hardest for an operator running the <=0.05 SOL
// hot-wallet ceiling the key's own threat model requires.
//
// The accusation must be RIGHT, not just loud — a genuinely quiet market must
// never be reported as a drained key. That is the test that matters here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PumpTape } from "../pumptape.ts";

const MIN = 60_000;
const NOW = 1_800_000_000_000; // fixed clock; tapeHealth takes `now` explicitly
const SECRET = "pk_live_THIS_MUST_NEVER_APPEAR"; // distinctive so the leak check is real

function tape({ keyed = true, connected = true, tracked = 3, birthAgo = null, tradeAgo = null } = {}) {
  const t = new PumpTape({ storage: {} }, keyed ? { PUMPPORTAL_API_KEY: SECRET } : {});
  t.ws = connected ? {} : null;
  for (let i = 0; i < tracked; i++) t.coins.set("mint" + i, {});
  t.stats.lastBirthMs = birthAgo === null ? 0 : NOW - birthAgo;
  t.stats.lastTradeMs = tradeAgo === null ? 0 : NOW - tradeAgo;
  return t.tapeHealth(NOW);
}

test("draining meter: births live + trades silent + tracking = trade_stream_dead", () => {
  const h = tape({ birthAgo: 10_000, tradeAgo: 20 * MIN });
  assert.equal(h.status, "trade_stream_dead");
  assert.equal(h.connected, true, "the socket IS up — that is the whole point");
  assert.match(h.detail, /0\.02 SOL/, "must name the actual likely cause");
  assert.match(h.detail, /do not grade any forward claim/i, "must warn the tape is not accruing");
});

test("draining meter: trades never seen at all is also dead, not 'ok'", () => {
  const h = tape({ birthAgo: 5_000, tradeAgo: null });
  assert.equal(h.status, "trade_stream_dead");
  assert.equal(h.trade_age_ms, null);
});

// ── the anti-false-positive cases: it must NOT cry wolf ──────────────────────

test("quiet market (no births either) is NOT accused of a drained key", () => {
  // births silent too => the socket is not proving liveness, so we cannot
  // attribute the trade silence to the key. Staying quiet here is the point.
  const h = tape({ birthAgo: 30 * MIN, tradeAgo: 30 * MIN });
  assert.equal(h.status, "ok");
});

test("tracking nothing is NOT accused (no coin that must be trading)", () => {
  const h = tape({ tracked: 0, birthAgo: 5_000, tradeAgo: 30 * MIN });
  assert.equal(h.status, "ok");
});

test("healthy tape: both streams live", () => {
  const h = tape({ birthAgo: 5_000, tradeAgo: 3_000 });
  assert.equal(h.status, "ok");
  assert.equal(h.detail, null);
});

// ── configuration vs failure: these are different states ─────────────────────

test("no API key = trades_unsubscribed BY CONFIG, distinct from a failure", () => {
  const h = tape({ keyed: false, birthAgo: 5_000, tradeAgo: null });
  assert.equal(h.status, "trades_unsubscribed");
  assert.equal(h.keyed, false);
  assert.match(h.detail, /BY CONFIG/);
  assert.match(h.detail, /0\.02 SOL/, "tells the operator what it would cost to fix");
});

test("socket down is reported as socket_down, not as a key problem", () => {
  const h = tape({ connected: false, birthAgo: 5_000, tradeAgo: 30 * MIN });
  assert.equal(h.status, "socket_down");
  assert.equal(h.connected, false);
});

test("key presence is checked, never its value", () => {
  const h = tape({ keyed: true, birthAgo: 5_000, tradeAgo: 3_000 });
  assert.equal(h.keyed, true);
  assert.ok(!JSON.stringify(h).includes(SECRET), "the key VALUE must never reach the readout");
});
