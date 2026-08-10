// Desk position matching DoD. Offline: no DOM, no chain.
//
// Board row 90: two live coins named TOAD on different mints, and the console
// lit Force Sell on both because positions matched by symbol. These tests pin
// the fix — the mint is the key, the symbol is never consulted — against the
// exact production module the page loads (public/desk-match.js), not a copy.
"use strict";

const assert = require("assert");

let pass = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};
const M = require("../../public/desk-match");

console.log("Desk position matching — DoD\n");

// The row-90 capture, as fixtures: two TOADs, different mints. The user holds
// MINT_A only. Shapes mirror the console's mapRow()/positions.unshift() exactly.
const MINT_A = "6BLEznTAkQKJv6Dk1zXHXKcMFFPNZAcYRVWy1yFVpump";
const MINT_B = "6GmhSj74YWKEXWmVSKKcMFFPNZAcYRVWy1yFVqqqpump";
const cardA = { id: MINT_A, s: "TOAD", ch: "sol", addr: MINT_A };
const cardB = { id: MINT_B, s: "TOAD", ch: "sol", addr: MINT_B };
const heldA = { id: MINT_A, s: "TOAD", ch: "sol", state: "armed", mint: MINT_A };

// ── THE PATH IS ALIVE. If this fails, every inertness proof below is vacuous.
t("the held card matches its armed position by mint", () => {
  assert.strictEqual(M.hasPos([heldA], cardA), true, "the position the user holds must light its own card");
  assert.strictEqual(M.findArmed([heldA], cardA, cardA.id), heldA);
});

// ── ROW 90, THE FINDING ITSELF: the same-symbol sibling stays INERT.
t("the same-symbol sibling card stays inert (row 90)", () => {
  assert.strictEqual(M.hasPos([heldA], cardB), false,
    "Force Sell rendered on a coin the user does not hold — the row-90 defect is back");
  assert.strictEqual(M.findArmed([heldA], cardB, cardB.id), null,
    "a tap on the sibling card resolved to the real position — money moves on the wrong coin");
});

// ── THE SYMBOL IS NEVER THE KEY, in either direction of mint presence.
t("a symbol match alone never resolves, whichever side lacks the mint", () => {
  const mintlessPos = { id: "row-77", s: "TOAD", state: "armed" };           // position without a mint
  const mintlessCard = { id: "row-99", s: "TOAD" };                          // preview card without addr
  assert.strictEqual(M.hasPos([mintlessPos], cardB), false, "mintless position matched a minted card by name");
  assert.strictEqual(M.hasPos([heldA], mintlessCard), false, "minted position matched a mintless card by name");
  assert.strictEqual(M.hasPos([mintlessPos], mintlessCard), false, "two mintless strangers matched by name");
});

// ── MINT COMPARISON IS CASE-INSENSITIVE and beats a divergent id.
t("mint decides even when ids diverge; case does not defeat it", () => {
  const posOtherId = { id: "legacy-id", s: "TOAD", state: "armed", mint: MINT_A.toUpperCase() };
  assert.strictEqual(M.hasPos([posOtherId], cardA), true, "same mint must match regardless of id or case");
  assert.strictEqual(M.hasPos([posOtherId], cardB), false);
});

// ── FALLBACKS THAT REMAIN LEGITIMATE: exact id when a mint is absent.
t("preview/demo cards still match their own position by exact id only", () => {
  const demoPos = { id: "demo-3", s: "ZORP", state: "armed" };
  const demoCard = { id: "demo-3", s: "ZORP" };
  const demoSibling = { id: "demo-4", s: "ZORP" };
  assert.strictEqual(M.hasPos([demoPos], demoCard), true);
  assert.strictEqual(M.hasPos([demoPos], demoSibling), false, "demo sibling matched by symbol");
});

t("a tap whose card already left the screen resolves by tapped id, never name", () => {
  assert.strictEqual(M.findArmed([heldA], null, MINT_A), heldA, "off-screen card: the tapped id is the position id");
  assert.strictEqual(M.findArmed([heldA], null, MINT_B), null);
  assert.strictEqual(M.findArmed([heldA], null, null), null, "no card and no id must resolve nothing");
});

// ── ONLY ARMED POSITIONS PARTICIPATE. A closed position must not light a card.
t("closed positions never match", () => {
  const closed = { id: MINT_A, s: "TOAD", state: "hit", mint: MINT_A };
  assert.strictEqual(M.hasPos([closed], cardA), false);
  assert.strictEqual(M.findArmed([closed], cardA, cardA.id), null);
});

console.log(`\n${pass} passed${process.exitCode ? " — WITH FAILURES" : ""}`);
