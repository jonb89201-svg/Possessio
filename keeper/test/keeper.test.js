// Model B keeper DoD. Offline: no keys, no chain, no Jupiter.
//
// These do not test that the keeper can trade. They test that it cannot
// exceed its remit — which is the only thing a user is trusting when they
// grant a delegate.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

let pass = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};
const SRC = (f) => fs.readFileSync(path.join(__dirname, "..", f), "utf8");
const K = require("../index");

console.log("Model B keeper — DoD\n");

// ── RULE 5: the stop is read, never authored ───────────────────────────────
t("the stop is READ from the rule, never assigned in the keeper", () => {
  const s = SRC("index.js");
  assert.ok(/pos\.stopBps/.test(s), "stop must come from the position's rule");
  assert.ok(!/stopBps\s*[:=]\s*\d/.test(s), "a literal stop is assigned somewhere");
  assert.ok(!/0\.9\b/.test(s), "a hardcoded -10% multiplier appears in the keeper");
});

t("target and stop are computed from the authored bps, in both directions", () => {
  const pos = { entryPrice: 0.0000042, targetBps: 5000, stopBps: 1000 };
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 1.6).kind, "target");
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 0.85).kind, "stop");
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 1.1).kind, null, "in-band must not fire");
});

t("the target boundary fires exactly at the authored number, not near it", () => {
  const pos = { entryPrice: 100, targetBps: 2500, stopBps: 1000 };
  assert.strictEqual(K.triggerFor(pos, 124.99).kind, null, "just below target: hold");
  assert.strictEqual(K.triggerFor(pos, 125).kind, "target", "exactly at target: fire");
  assert.strictEqual(K.triggerFor(pos, 90).kind, "stop", "exactly at stop: fire");
  assert.strictEqual(K.triggerFor(pos, 90.01).kind, null, "just above stop: hold");
});

// ── RULE 1: revocation is instant ──────────────────────────────────────────
t("a revoked or spent delegate stands the keeper down IN THE SAME CYCLE", () => {
  const s = SRC("index.js");
  const i = s.indexOf("RULE 1");
  assert.ok(i > -1, "rule 1 must be implemented where the loop can see it");
  const near = s.slice(i, i + 500);
  assert.ok(/readDelegate\(/.test(near), "the chain must be consulted inside the loop");
  assert.ok(/if \(!live\.authorised\)/.test(near), "the live on-chain delegate must gate every action");
  assert.ok(/continue/.test(near), "a stood-down position must be skipped, not traded");
});

t("authority is read from the chain every cycle, never cached across cycles", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function cycle"), s.indexOf("async function main"));
  // The read must sit INSIDE the per-position loop, not hoisted above it — a
  // single read reused across positions is a cached authority by another name.
  const loop = body.slice(body.indexOf("for (const pos of rules)"));
  assert.ok(/await readDelegate\(/.test(loop), "authority must be re-read per position, inside the loop");
  assert.ok(!/const live = .*\n[\s\S]*for \(const pos of rules\)/.test(body.slice(0, body.indexOf("for (const pos of rules)"))),
    "authority must not be resolved before the loop and reused");
});

t("the delegate reader DEFAULTS to the live chain read", () => {
  const s = SRC("index.js");
  // The seam exists so the live harness can drive the fire path with real
  // post-grant state. It must default closed: a deployment that forgets to
  // pass a reader gets the chain, never a stub that says yes.
  assert.ok(/readDelegate = readLiveDelegate/.test(s),
    "the injected reader must default to the on-chain read");
});

t("authorisation is decided by the chain, not by the keeper", () => {
  const s = SRC("positions.js");
  const P = require("../positions");

  // The rule lives in exactly ONE place, so the live harness cannot pass by
  // re-implementing it more leniently than the loop.
  const body = s.slice(s.indexOf("function decide("), s.indexOf("const REFUSED"));
  assert.ok(/authorised:\s*delegate === keeper && acc\.delegatedAmount > 0n/.test(body),
    "only the account's own delegate field may authorise the keeper");

  // And it actually behaves that way, not just reads that way.
  const pk = (v) => (v ? { toBase58: () => v } : null);
  const acc = (d, n) => ({ delegate: pk(d), delegatedAmount: n, amount: 1000n });
  const d = (a, k) => P.decide({ ata: null, owner: "u", mint: "m", acc: a, keeper: k }).authorised;
  assert.strictEqual(d(acc("KEEPER", 5n), "KEEPER"), true, "the named delegate may act");
  assert.strictEqual(d(acc("KEEPER", 5n), "OTHER"), false, "a different key must never act");
  assert.strictEqual(d(acc("KEEPER", 0n), "KEEPER"), false, "a spent grant is no grant");
  assert.strictEqual(d(acc(null, 0n), "KEEPER"), false, "no delegate, no authority");
});

t("an unreadable account fails CLOSED rather than throwing the loop over", () => {
  const s = SRC("positions.js");
  const tail = s.slice(s.indexOf("const REFUSED"));
  assert.ok(/authorised: false/.test(tail), "the refusal path must deny authority");
  assert.ok(/catch \{\s*return REFUSED\(owner, mint\);/.test(tail),
    "a failed read must stand this position down, not crash the other positions");
});

// ── RULE 2: power without instruction is never exercised ───────────────────
// This is STRUCTURAL, not a warning. The loop iterates RULES and reads the
// delegate for each one; it never enumerates grants. A delegate with no
// authored rule is therefore never looked at, so it can never be traded.
t("the loop iterates RULES, never grants — unruled authority is unreachable", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function cycle"), s.indexOf("async function main"));
  assert.ok(/const rules = await source\.list\(\)/.test(body),
    "the cycle's work list must come from the rule ledger");
  assert.ok(/for \(const pos of rules\)/.test(body),
    "the loop must be over rules, so an unruled delegate is never enumerated");
  // Strip line comments: the design note in positions.js NAMES the rejected
  // scan on purpose, so nobody rebuilds it. Naming it is the point; calling
  // it is the violation.
  const code = (f) => SRC(f).replace(/^\s*\/\/.*$/gm, "");
  assert.ok(!/getProgramAccounts/.test(code("index.js") + code("positions.js")),
    "a program-wide delegate scan would reintroduce power without instruction");
});

// ── RULE 3: never more than delegated ──────────────────────────────────────
t("the sell amount is the DELEGATED amount, not the position balance", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function fireExit"), s.indexOf("async function cycle"));
  assert.ok(/amount:\s*live\.delegatedAmount/.test(body),
    "the exit must be bounded by what was actually delegated");
  assert.ok(!/amount:\s*live\.amount/.test(body), "selling the full balance exceeds the grant");
});

// ── RULE 4: the keeper is never a destination ──────────────────────────────
t("proceeds are delivered to the USER — the keeper only signs and pays", () => {
  const s = SRC("../miniapp/solana-leg.js");
  const body = s.slice(s.indexOf("async function buildDelegatedExit"));
  assert.ok(/userPublicKey,\s*\/\/ source of funds: the user/.test(body) || /userPublicKey,/.test(body),
    "the user must be the swap's owner");
  assert.ok(/payer: keeperPublicKey/.test(body), "the keeper must be the fee payer, not the recipient");
  assert.ok(!/destinationTokenAccount:\s*keeper/i.test(body), "proceeds must never route to the keeper");
});

// ── DRY RUN ────────────────────────────────────────────────────────────────
t("DRY_RUN defaults ON — live mode must be chosen deliberately", () => {
  const s = SRC("index.js");
  assert.ok(/env\("DRY_RUN", "1"\) !== "0"/.test(s), "dry run must default on");
});

t("the dry-run gate sits inside fireExit, before any signing", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function fireExit"), s.indexOf("async function cycle"));
  assert.ok(body.indexOf("if (DRY_RUN)") < body.indexOf("tx.sign("), "the gate must precede signing");
});

t("live mode without a key refuses to start", () => {
  const s = SRC("index.js");
  assert.ok(/!DRY_RUN && !keeper.*throw/s.test(s), "live mode must require a key");
});

t("a keyless live exit refuses at the point of signing, not just at startup", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function fireExit"), s.indexOf("async function cycle"));
  const guard = body.indexOf("if (!keeper)");
  assert.ok(guard > -1, "fireExit must refuse to proceed without a keypair");
  assert.ok(guard < body.indexOf("tx.sign("), "the refusal must precede signing");
});

t("the dry-run path never derives the keeper from a keypair it may not have", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function fireExit"), s.indexOf("async function cycle"));
  assert.ok(/keeperPublicKey: keeperPk/.test(body),
    "the pubkey must be passed in — a DRY_RUN holds no key to derive it from");
  assert.ok(!/keeperPublicKey: keeper\.publicKey/.test(body),
    "deriving from the keypair crashes the loop in exactly the mode meant to prove it works");
});

// ── IDEMPOTENCE ────────────────────────────────────────────────────────────
t("a position exited this run is never sold twice", () => {
  const s = SRC("index.js");
  assert.ok(/exited\.has\(String\(pos\.id\)\)/.test(s), "must check before acting");
  assert.ok(/exited\.add\(String\(pos\.id\)\)/.test(s), "must record after acting");
});

// ── PRICE HONESTY ──────────────────────────────────────────────────────────
t("the trigger price is EXECUTABLE — quoted for the real size, not a mid-price", () => {
  const s = SRC("index.js");
  const body = s.slice(s.indexOf("async function executablePrice"), s.indexOf("function triggerFor"));
  assert.ok(/amount: String\(amount\)/.test(body), "the quote must be for the actual size");
  assert.ok(/outputMint: L\.USDC_MINT/.test(body), "priced in the unit the user is paid in");
});

// ── NO KEY LEAKAGE ─────────────────────────────────────────────────────────
t("the keeper never logs or writes its key", () => {
  const s = SRC("index.js");
  assert.ok(!/SOLANA_KEEPER_KEY[^)]*log/.test(s), "key must never reach the logger");
  assert.ok(!/writeFileSync\([^)]*KEEPER_KEY/.test(s), "key must never be written");
  const startup = s.slice(s.indexOf('log("Model B keeper starting'), s.indexOf("if (DRY_RUN) log"));
  assert.ok(/publicKey\.toBase58\(\)/.test(startup), "startup should print the PUBLIC key");
  assert.ok(!/KEEPER_KEY/.test(startup), "startup must not touch the secret");
});

console.log(`\n${pass} checks passed`);
