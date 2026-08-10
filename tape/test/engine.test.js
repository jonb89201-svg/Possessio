// Tape engine DoD. Offline: no socket, no D1, no real clock.
//
// The engine is the pumptape.ts state machine extracted for the Railway host
// (board row 90). These tests pin the §0 v3 paper-ladder semantics with exact
// numbers — drift here would silently re-grade the research ledger every
// existing query reads from.
"use strict";

const assert = require("assert");

let pass = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};
const { TapeEngine } = require("../engine");

console.log("Tape engine — DoD\n");

const T0 = 1_800_000_000_000; // fixed clock — the engine has no clock of its own
const MINT = "TapeTestMint1111111111111111111111111111111";
const msg = (o) => JSON.stringify(o);
const birth = (e, now, mcSol, extra) =>
  e.onMessage(msg({ txType: "create", mint: MINT, symbol: "TT", name: "TapeTest",
    solAmount: 2.5, traderPublicKey: "DevWallet111", marketCapSol: mcSol, ...extra }), now);
const trade = (e, now, mcSol, type = "buy", sol = 1) =>
  e.onMessage(msg({ txType: type, mint: MINT, solAmount: sol, traderPublicKey: "Trader" + now, marketCapSol: mcSol }), now);

// ── the create event seeds the dev buy and asks for the trade sub ──────────
t("create seeds the dev as buyer #1 and emits the subscribe", () => {
  const e = new TapeEngine();
  const out = birth(e, T0, 10);
  assert.deepStrictEqual(out.subscribe, [MINT]);
  const c = e.coins.get(MINT);
  assert.strictEqual(c.buys, 1);
  assert.strictEqual(c.solNet, 2.5);
  assert.strictEqual(c.buyerSol.get("DevWallet111"), 2.5);
  assert.strictEqual(e.stats.births, 1);
});

// ── never guessed: no solUsd, no pricing, counted ──────────────────────────
t("without solUsd a trade counts noPrice and emits nothing", () => {
  const e = new TapeEngine();
  birth(e, T0, 10);
  const out = trade(e, T0 + 1000, 40);
  assert.strictEqual(out.effects.length, 0);
  assert.strictEqual(e.stats.noPrice, 1);
});

// ── lamports heuristic ─────────────────────────────────────────────────────
t("a solAmount above 100k is lamports and is divided down", () => {
  const e = new TapeEngine();
  birth(e, T0, 10);
  trade(e, T0 + 1000, 12, "buy", 5e9); // 5 SOL in lamports
  assert.strictEqual(e.coins.get(MINT).solNet, 2.5 + 5);
});

// ── the crossing: hit at $3.5k, entry set, crossing never also exits ───────
t("the $3.5k crossing emits the hit with the flow read, and only the hit", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);                       // $1,000
  const out = trade(e, T0 + 30_000, 35);  // $3,500 exactly
  assert.strictEqual(out.effects.length, 1);
  const h = out.effects[0];
  assert.strictEqual(h.k, "hit");
  assert.strictEqual(h.p[0], MINT);
  assert.strictEqual(h.p[4], 3500);       // first_hit_mc
  assert.strictEqual(h.p[5], 30);         // age_sec_at_hit
  assert.strictEqual(h.p[12], null, "at $3.5k there is no gap");
  const c = e.coins.get(MINT);
  assert.strictEqual(c.levelEntryMc, 3500);
  assert.strictEqual(e.stats.hits, 1);
});

// ── the gap rule: first seen at/past rung 1 cannot be entered ──────────────
t("detected already at $6k+ books a gap, resolved on the spot", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  const out = trade(e, T0 + 10_000, 70);  // $7,000 first sight past $3.5k
  const h = out.effects[0];
  assert.strictEqual(h.p[12], "gap");
  assert.strictEqual(h.p[13], 7000);
  assert.strictEqual(e.stats.gaps, 1);
  assert.strictEqual(e.coins.get(MINT).resolved, true);
});

// ── the full ladder: exact blended exit, then the dip hunt ─────────────────
t("a full L1 ladder books 7750 blended, target outcome, awaiting_dip", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  trade(e, T0 + 10_000, 35);              // hit at $3,500
  const out = trade(e, T0 + 20_000, 120); // $12,000 clears all four rungs
  // 0.5*6000 + 0.25*8000 + 0.125*10000 + 0.125*12000 = 7750 — the paper fill
  const cyc = out.effects.find((x) => x.k === "cycle");
  assert.deepStrictEqual(cyc.p, [MINT, 1, "ladder", 3500, 7750, 4, T0 + 20_000]);
  const l1 = out.effects.find((x) => x.k === "level1");
  assert.deepStrictEqual(l1.p, [MINT, "target", 7750, T0 + 20_000, 4]);
  const head = out.effects.find((x) => x.k === "headline");
  assert.deepStrictEqual(head.p, [MINT, 1, 2.214]); // 7750/3500 rounded to 3dp
  assert.strictEqual(e.coins.get(MINT).mode, "awaiting_dip");
  assert.strictEqual(e.stats.targets, 1);
});

// ── the cycle: 15% dip re-enters one octave up ─────────────────────────────
t("a 15% dip re-buys at level 2 with the 14-20k rungs armed", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  trade(e, T0 + 10_000, 35);
  trade(e, T0 + 20_000, 120);              // ladder done, dipPeak 12000
  trade(e, T0 + 30_000, 126);              // peak rises to 12600
  const out = trade(e, T0 + 40_000, 107.1); // 12600*0.85 = 10710 — THE DIP
  const cyc = out.effects.find((x) => x.k === "cycle");
  assert.deepStrictEqual(cyc.p, [MINT, 2, "entry", 10710, null, 0, T0 + 40_000]);
  const c = e.coins.get(MINT);
  assert.strictEqual(c.level, 2);
  assert.strictEqual(c.mode, "holding");
});

// ── the bell: 2:00 after a level entry, remainder exits at market ──────────
t("the 2:00 bell books the blended exit and compounds the headline", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  trade(e, T0 + 10_000, 35);
  trade(e, T0 + 20_000, 120);
  trade(e, T0 + 30_000, 126);
  trade(e, T0 + 40_000, 107.1);            // level 2 entry at 10710
  const bellAt = T0 + 40_000 + 2 * 60_000;
  const out = trade(e, bellAt, 110);       // $11,000 at the bell, no rungs filled
  const cyc = out.effects.find((x) => x.k === "cycle");
  assert.deepStrictEqual(cyc.p, [MINT, 2, "bell", 10710, 11000, 0, bellAt]);
  assert.ok(!out.effects.some((x) => x.k === "level1"), "level1 outcome is L1-only");
  const head = out.effects.find((x) => x.k === "headline");
  // 7750/3500 * 11000/10710 = 2.27435... -> 2.274
  assert.deepStrictEqual(head.p, [MINT, 2, 2.274]);
  assert.strictEqual(e.coins.get(MINT).resolved, true);
});

// ── the sweep: an overdue bell rings first; then the coin is pruned ────────
t("the sweep rings an overdue bell and prunes past the 8:00 window", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  trade(e, T0 + 10_000, 35);               // holding, one rung short of anything
  const out = e.sweep(T0 + 8 * 60_000 + 1);
  // past both the bell and the window: the bell books (DO alarm parity) and
  // the window prune then finds the coin already resolved
  const cyc = out.effects.find((x) => x.k === "cycle");
  assert.strictEqual(cyc.p[2], "bell");
  assert.deepStrictEqual(out.unsubscribe, [MINT]);
  assert.strictEqual(e.coins.size, 0);
});

// ── the window outcome: reachable only via a late re-entry ─────────────────
t("a late dip re-entry marks-to-window when its bell falls past 8:00", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  trade(e, T0 + 10_000, 35);               // hit at $3,500
  trade(e, T0 + 20_000, 120);              // full L1 ladder — awaiting_dip
  trade(e, T0 + 30_000, 126);              // peak 12600
  trade(e, T0 + 450_000, 107.1);           // 7:30 — THE DIP, level 2 entry; bell due 9:30
  const out = e.sweep(T0 + 8 * 60_000 + 1); // window closes before that bell
  const cyc = out.effects.find((x) => x.k === "cycle");
  assert.deepStrictEqual(cyc.p.slice(0, 6), [MINT, 2, "window", 10710, 10710, 0]);
  assert.deepStrictEqual(out.unsubscribe, [MINT]);
  assert.strictEqual(e.coins.size, 0);
});

// ── the draining meter, ported: same fingerprints as the DO ────────────────
t("health: births live + trades silent + keyed = trade_stream_dead", () => {
  const e = new TapeEngine();
  e.setSolUsd(100);
  birth(e, T0, 10);
  e.stats.lastBirthMs = T0 + 20 * 60_000 - 10_000;
  e.stats.lastTradeMs = 0;
  const h = e.health(T0 + 20 * 60_000, true, true);
  assert.strictEqual(h.status, "trade_stream_dead");
  assert.match(h.detail, /0\.02 SOL/);
});

t("health: no key is trades_unsubscribed BY CONFIG; no socket is socket_down", () => {
  const e = new TapeEngine();
  birth(e, T0, 10);
  assert.strictEqual(e.health(T0, true, false).status, "trades_unsubscribed");
  assert.strictEqual(e.health(T0, false, true).status, "socket_down");
});

t("health: a quiet market is ok, never accused", () => {
  const e = new TapeEngine();
  birth(e, T0, 10);
  e.stats.lastBirthMs = T0;
  e.stats.lastTradeMs = T0;
  const h = e.health(T0 + 30 * 60_000, true, true); // births silent too
  assert.strictEqual(h.status, "ok");
});

console.log(`\n${pass} passed${process.exitCode ? " — WITH FAILURES" : ""}`);
