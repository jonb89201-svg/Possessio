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
// async-aware runner — the sync t() would count a rejected promise as a pass.
const pending = [];
const ta = (name, fn) => {
  pending.push(Promise.resolve().then(fn)
    .then(() => { console.log(`  PASS  ${name}`); pass++; })
    .catch((e) => { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }));
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
  const pos = { entryPrice: 0.0000042, targetBps: 5000, hasStop: true, stopBps: 1000 };
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 1.6).kind, "target");
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 0.85).kind, "stop");
  assert.strictEqual(K.triggerFor(pos, pos.entryPrice * 1.1).kind, null, "in-band must not fire");
});

t("NO STOP is an absence: the stop path is unreachable, and provably alive", () => {
  // Architect ratification 2026-08-01, Option B, with the clause-4 requirement
  // stated in the order: BOTH cases must be demonstrated. A test that only
  // proves no-stop positions never sell has not distinguished a working branch
  // from a dead code path — it would pass identically if the stop had been
  // deleted outright.
  const noStop   = { entryPrice: 100, targetBps: 1000, hasStop: false };
  const withStop = { entryPrice: 100, targetBps: 1000, hasStop: true, stopBps: 1000 };

  // (1) THE PATH IS ALIVE. If this fails, everything in (2) is vacuous.
  assert.strictEqual(K.triggerFor(withStop, 90).kind, "stop", "the stop path must fire when a stop exists");
  assert.strictEqual(K.triggerFor(withStop, 89).kind, "stop");
  assert.strictEqual(K.triggerFor(withStop, 95).kind, null, "between stop and target: hold");

  // (2) AND IT IS UNREACHABLE WITHOUT A STOP — over the exact inputs that
  //     reached the old threshold, since 0 satisfies `price <= stop` for any
  //     stop and was the value that made the sentinel design unsafe.
  for (const price of [90, 50, 1, 0.0001, 0, -1, NaN, Infinity, -Infinity]) {
    assert.notStrictEqual(K.triggerFor(noStop, price).kind, "stop",
      `a position with NO stop was sold by the stop path at price ${String(price)}`);
  }

  // (3) A no-stop position still TAKES PROFIT. Absence of a stop must not
  //     disable the whole rule — that would be a dead position, not an
  //     unstopped one.
  assert.strictEqual(K.triggerFor(noStop, 111).kind, "target");
  assert.strictEqual(K.triggerFor(noStop, 105).kind, null);

  // (4) No threshold is even reported. The ratification is that the code never
  //     asks the question, not that it asks and ignores the answer.
  assert.strictEqual(K.triggerFor(noStop, 105).stop, null, "a no-stop position must expose no threshold");

  // (5) The old sentinel must NOT be honoured as one. 10000 was rejected
  //     because a 100% drawdown is a semantically real value; if it is ever
  //     written it means that, and hasStop still governs.
  const sentinel = { entryPrice: 100, targetBps: 1000, hasStop: false, stopBps: 10000 };
  assert.notStrictEqual(K.triggerFor(sentinel, 0.000001).kind, "stop",
    "hasStop:false must govern even when a stopBps value is present");

  // (6) A rule that does not SAY does nothing. Absence must be stated, never
  //     inferred from a missing field — otherwise a source that forgets it
  //     silently produces an unstopped position, which is the uninitialised
  //     -value trap that disqualified zero, one level down.
  for (const unstated of [
    { entryPrice: 100, targetBps: 1000 },
    { entryPrice: 100, targetBps: 1000, stopBps: 1000 },
    { entryPrice: 100, targetBps: 1000, hasStop: "true" },
    { entryPrice: 100, targetBps: 1000, hasStop: 1 },
    { entryPrice: 100, targetBps: 1000, hasStop: null },
  ]) {
    const r = K.triggerFor(unstated, 111);
    assert.strictEqual(r.kind, null,
      `an unstated rule must do nothing, got ${r.kind} (${JSON.stringify(unstated)})`);
    assert.strictEqual(K.triggerFor(unstated, 1).kind, null,
      "an unstated rule must not be sellable by the stop path either");
  }
});

t("an unreadable price stands the keeper down — it never reads as zero", () => {
  // A price of 0 satisfies `price <= stop` for ANY stop, so a dead route would
  // fire a sale into a market with no liquidity. It fires even on a position
  // with NO stop, because the no-stop sentinel's stop price is itself 0.
  //
  // The upstream guard was `if (!j.outAmount) throw "no route"`, which reads as
  // if it catches zero and does not: "0" is a truthy string. Both layers are
  // guarded now; this asserts the keeper-side one.
  const pos = { entryPrice: 100, targetBps: 1000, hasStop: true, stopBps: 1000 };
  for (const bad of [0, -1, NaN, Infinity, undefined, null]) {
    assert.strictEqual(K.triggerFor(pos, bad).kind, null,
      `a price of ${String(bad)} must stand the keeper down, not trigger`);
  }
  // and a real price still works, so the guard is not simply refusing everything
  assert.strictEqual(K.triggerFor(pos, 111).kind, "target");
  assert.strictEqual(K.triggerFor(pos, 89).kind, "stop");
});

t("the target boundary fires at the authored number, within float tolerance", () => {
  // NAMED HONESTLY 2026-08-01. This used to claim the boundary fires "exactly
  // at the authored number, not near it" and tested ONLY entryPrice 100 /
  // targetBps 2500, where 100 * 1.25 is exactly 125 in binary floating point.
  // It passed by luck of the constant. The claim is false in general:
  //
  //   100 * (1 + 1000/10000) === 110.00000000000001
  //
  // so a fill at exactly 110 does NOT fire. Measured across 54 entry/target
  // combinations, 7 behave this way.
  //
  // The arithmetic was left alone deliberately. Rewriting the comparison in
  // scaled form (price*10000 >= entry*(10000+bps)) cuts the target-side cases
  // from 7 to 2 but introduces 2 on the STOP side, which had none — a net
  // regression on a live-funds path for an error of ~1e-16 relative. On a coin
  // priced at 2.5e-6 that is a trigger off by 2.5e-22 dollars, which no market
  // can express. The defect was the CLAIM, not the code.
  const pos = { entryPrice: 100, targetBps: 2500, hasStop: true, stopBps: 1000 };
  assert.strictEqual(K.triggerFor(pos, 124.99).kind, null, "just below target: hold");
  assert.strictEqual(K.triggerFor(pos, 125).kind, "target", "at target: fire");
  assert.strictEqual(K.triggerFor(pos, 90).kind, "stop", "at stop: fire");
  assert.strictEqual(K.triggerFor(pos, 90.01).kind, null, "just above stop: hold");

  // The property that actually holds, stated over values that do NOT divide
  // cleanly in binary — so this cannot pass by luck of a constant the way the
  // old version did.
  const EPS = 1e-12;
  for (const [entryPrice, targetBps] of [[100, 1000], [0.0025, 1000], [10, 13700], [3.7, 5000]]) {
    const p = { entryPrice, targetBps, hasStop: true, stopBps: 1000 };
    const authored = entryPrice * (1 + targetBps / 10000);
    assert.strictEqual(K.triggerFor(p, authored * (1 + EPS)).kind, "target",
      `a fill a hair ABOVE the authored target must fire (entry ${entryPrice}, bps ${targetBps})`);
    assert.strictEqual(K.triggerFor(p, authored * (1 - 1e-6)).kind, null,
      `a fill measurably below the authored target must hold (entry ${entryPrice}, bps ${targetBps})`);
  }
});

// ── RULE 1: revocation is instant ──────────────────────────────────────────
t("a revoked or spent delegate stands the keeper down IN THE SAME CYCLE", () => {
  const s = SRC("index.js");
  const i = s.indexOf("RULE 1");
  assert.ok(i > -1, "rule 1 must be implemented where the loop can see it");
  const near = s.slice(i, i + 1800); // widened 2026-08-10: the stand-down carries the fluffy-fire comment now
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

// ── NO BORN-DEAD RULES (2026-08-10, the fluffy fire) ───────────────────────
//
// One transient "not authorised" reading — RPC lag right after arming, or a
// plain RPC failure (readLiveDelegate turns ANY error into REFUSED) — used to
// blacklist the rule id forever via the exited set. Measured in production:
// rule 23 sat armed with tokens held while price crossed its +1% target by
// over 400%, and the keeper never re-read it. The blacklist belongs to SOLD
// positions only; a stand-down is a per-cycle reading.
ta("a transient not-authorised reading must NOT kill the rule — it recovers next cycle", async () => {
  process.env.KEEPER_PUBKEY = "TestKeeperPk11111111111111111111111111111111";
  const pos = { id: "77", user: "OwnerPk", mint: "MintPk", decimals: 6,
    entryPrice: 0.00001, targetBps: 100, hasStop: false, stopBps: null };
  const source = { list: async () => [pos] };
  const REFUSED = { authorised: false, amount: "0", delegatedAmount: "0" };
  // cycle 1: the birth-window reading — delegate not visible yet
  let r1 = await K.cycle({ connection: {}, keeper: null, source, readDelegate: async () => REFUSED });
  assert.strictEqual(r1.authorised, 0, "cycle 1 correctly stands down");
  // cycle 2: the chain now shows the grant (empty balance stops it before any
  // network pricing) — the rule MUST be re-evaluated, not skipped
  let r2 = await K.cycle({ connection: {}, keeper: null, source,
    readDelegate: async () => ({ authorised: true, amount: "0", delegatedAmount: "500" }) });
  assert.strictEqual(r2.authorised, 1,
    "a rule that stood down once was never re-read — born-dead rules are back (the fluffy bug)");
});

t("the exited blacklist is reserved for SOLD positions — source-level", () => {
  const s = SRC("index.js");
  const standDown = s.slice(s.indexOf("if (!live.authorised)"), s.indexOf("authorised++"));
  assert.ok(!/exited\.add/.test(standDown), "stand-down must never feed the double-sell blacklist");
  const sold = s.slice(s.indexOf("if (!res.dryRun)"), s.indexOf("} catch (e) {"));
  assert.ok(/exited\.add/.test(sold), "a REAL exit must still be blacklisted against a second sell");
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

Promise.all(pending).then(() => console.log(`\n${pass} checks passed`));
