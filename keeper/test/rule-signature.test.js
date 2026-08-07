// THE SIGNATURE CONTRACT between the mini-app and the worker.
//
// The console signs a rule; the worker independently rebuilds the preimage and
// verifies. If those two strings ever drift by one byte, every rule POST 401s —
// and it fails in production, on a real user's buy, after they have already
// signed two transactions and paid for the coin. Nothing else in the stack
// catches it, because each side is individually self-consistent.
//
// So this test extracts BOTH implementations from their real source files and
// runs them against each other. Not copies — the actual shipped text.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const nacl = require("tweetnacl");
const { Keypair } = require("@solana/web3.js");
const bs58 = require("bs58");
const b58 = bs58.default || bs58;

let pass = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};
const R = (p) => fs.readFileSync(path.join(__dirname, "..", "..", p), "utf8");

console.log("Desk rule — the mini-app <-> worker signature contract\n");

/// Lift a function out of a source file by name and eval it, so the test runs
/// the SHIPPED implementation rather than a copy that can drift from it.
///
/// `params` is supplied by the caller rather than parsed: the worker side is
/// TypeScript, and writing a type-annotation parser here would be a second
/// thing that can be subtly wrong. The parameter names are stable and the
/// point of the test is to compare the BODIES.
function lift(src, name, params, extra = "") {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start > -1, `${name} not found in source`);

  // Find the body's opening brace: the first '{' after the parameter list's
  // matching ')' — not the first '{' after the name, which for a TS object
  // type annotation is part of the signature.
  const open = src.indexOf("(", start);
  let d = 0, closeParen = -1;
  for (let j = open; j < src.length; j++) {
    if (src[j] === "(") d++;
    else if (src[j] === ")") { d--; if (d === 0) { closeParen = j; break; } }
  }
  assert.ok(closeParen > -1, `could not find the parameter list of ${name}`);

  const bodyStart = src.indexOf("{", closeParen);
  assert.ok(bodyStart > -1, `could not find the body of ${name}`);
  d = 0;
  let end = -1;
  for (let j = bodyStart; j < src.length; j++) {
    if (src[j] === "{") d++;
    else if (src[j] === "}") { d--; if (d === 0) { end = j + 1; break; } }
  }
  assert.ok(end > -1, `could not bound ${name}`);

  // Strip the type syntax that appears INSIDE the body. The signature is
  // replaced wholesale above, so only body-level constructs matter.
  //
  // This stripper handled `const x: T =` but not `expr as T`, so the whole
  // suite went red the day a lifted function gained an `as` assertion — and it
  // went red with a bare "SyntaxError: Unexpected identifier 'as'" pointing at
  // an <anonymous_script>, which names neither the file nor the function. A
  // permanently red suite is a broken instrument, and a broken instrument
  // invalidates every verdict taken with it.
  const body = src.slice(bodyStart, end)
    // `const bytes: number[] = []`
    .replace(/\bconst\s+(\w+)\s*:\s*[\w[\]<>|\s]+?=/g, "const $1 =")
    // `let carry: number = 0`
    .replace(/\blet\s+(\w+)\s*:\s*[\w[\]<>|\s]+?=/g, "let $1 =")
    // `expr as Uint8Array<ArrayBuffer>`, `expr as string`, `expr as number[]`
    .replace(/\s+as\s+[A-Za-z_$][\w$.]*(?:<[^<>]*>)?(?:\[\])*/g, "")
    // `value!` non-null assertions
    .replace(/([\w$\])])!(?=\s*[.;,)\]}])/g, "$1");

  const source = `(() => { ${extra}\nfunction ${name}(${params}) ${body}\nreturn ${name}; })()`;

  // Parse BEFORE eval so an unhandled TS construct fails with something a
  // human can act on. Without this the failure is an anonymous SyntaxError
  // with no file, no function, and no offending line — which is how this one
  // sat red on main instead of being fixed the day it landed.
  try { new Function(`return ${source}`); }
  catch (e) {
    const off = /Unexpected identifier '(\w+)'/.exec(e.message);
    assert.fail(
      `lift(${name}) produced unparsable JS — the TypeScript stripper above does ` +
      `not handle something in this function body.\n` +
      `  source: the ${name} body\n` +
      `  error : ${e.message}\n` +
      (off ? `  hint  : add a rule for the '${off[1]}' construct to the stripper.\n` : "") +
      `  If TS syntax keeps outgrowing this stripper, compile the file instead ` +
      `of lifting from it.`
    );
  }
  // eslint-disable-next-line no-eval
  return eval(source);
}

const WORKER = R("worker/index.ts");
const MINIAPP = R("public/miniapp-solana.js");
const ALPHA = 'const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";';

const workerPreimage = lift(WORKER, "deskRulePreimage", "r");

// THE CONSOLE BUILDS TEXT, THE WORKER BUILDS BYTES, and that asymmetry is
// deliberate: the Farcaster Solana provider declares signMessage(message:
// string) and hands the argument across comlink with no encoding step, so the
// console cannot pass a Uint8Array. Everything below still compares BYTES —
// miniPreimage encodes the console's text exactly the way the worker encodes
// its own, which is the property that has to hold.
const miniMessage = lift(MINIAPP, "ruleMessage", "{ owner, mint, decimals, entryPrice, targetBps, hasStop, stopBps, nonce }");
const miniPreimage = (r) => new TextEncoder().encode(miniMessage(r));
const b58encode = lift(MINIAPP, "b58encode", "bytes", ALPHA);
const b58decode = lift(WORKER, "b58decode", "s", ALPHA);
const miniB58decode = lift(MINIAPP, "b58decode", "s", ALPHA);
const sigToBase58 = lift(MINIAPP, "sigToBase58", "raw",
  ALPHA + `\nconst b58encode = ${b58encode.toString()};\nconst b58decode = ${miniB58decode.toString()};` +
  `\nconst atob = (s) => Buffer.from(s, "base64").toString("binary");`);

const RULE = {
  owner: "ARjf4vUNiU8cW6xXfBfiL8ibc5qC4pYim5mLxbe6uog5",
  mint: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",
  decimals: 5,
  entryPrice: 0.0000028914,
  targetBps: 2500,
  hasStop: true,
  stopBps: 1000,
  nonce: "1785430000000-abc123",
};

// ── the two preimages are byte-identical ───────────────────────────────────
t("the console and the worker build the SAME bytes for the same rule", () => {
  const a = Buffer.from(workerPreimage(RULE));
  const b = Buffer.from(miniPreimage(RULE));
  assert.strictEqual(b.toString("hex"), a.toString("hex"),
    `preimages differ:\n  worker: ${JSON.stringify(a.toString())}\n  console: ${JSON.stringify(b.toString())}`);
});

// ── the console hands the host a type the host can actually carry ──────────
//
// MEASURED FAILURE 2026-08-06 23:00 UTC: the buy landed, the delegate landed
// (approve confirmed on chain, keeper as delegate), and then the Farcaster host
// died with its own full-screen "unexpected error". desk_rules stayed empty and
// the client error sink recorded NOTHING, because a host crash takes the frame
// and there is no promise left to reject. The only step between the confirmed
// delegate and the crash is this signature, and it was passing a Uint8Array to
// a method whose own declaration is signMessage(message: string)
// (@farcaster/miniapp-core@0.6.0/dist/solana.d.ts:38).
t("the console signs TEXT, because that is the only type the host accepts", () => {
  assert.strictEqual(typeof miniMessage(RULE), "string",
    "ruleMessage returned bytes again — the Farcaster provider takes a string and " +
    "passes it across comlink unencoded, so bytes kill the host instead of throwing");
});

t("the rule signature is requested with one argument and no encoding hint", () => {
  const call = /provider\.signMessage\(([^)]*)\)/.exec(MINIAPP);
  assert.ok(call, "signRule no longer calls provider.signMessage");
  assert.ok(!call[1].includes(","),
    `signMessage was called with more than one argument: (${call[1]}). The second ` +
    `"utf8" argument was Phantom's shape; this provider declares a single string ` +
    `parameter and silently drops the rest.`);
});

t("the preimage is domain-separated and version-tagged", () => {
  const s = Buffer.from(workerPreimage(RULE)).toString();
  assert.ok(s.startsWith("possessio.desk.rule.v1\n"),
    "an untagged preimage could be produced by signing for something else entirely");
});

t("every field of the instruction is covered by the signature", () => {
  const base = Buffer.from(workerPreimage(RULE)).toString("hex");
  for (const [k, v] of Object.entries({
    owner: "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM",
    mint: "So11111111111111111111111111111111111111112",
    decimals: 9, entryPrice: 0.0000029, targetBps: 5000, hasStop: false, stopBps: 500, nonce: "other",
  })) {
    const changed = Buffer.from(workerPreimage({ ...RULE, [k]: v })).toString("hex");
    assert.notStrictEqual(changed, base, `changing ${k} did not change the signed bytes`);
  }
});

// ── a real Ed25519 signature verifies, and a tampered one does not ─────────
t("a rule signed by the wallet verifies against the worker's preimage", () => {
  const kp = Keypair.generate();
  const rule = { ...RULE, owner: kp.publicKey.toBase58() };
  const msg = miniPreimage(rule);                        // console builds + signs
  const sig = nacl.sign.detached(msg, kp.secretKey);
  const sigB58 = b58encode(sig);                         // console encodes

  const pub = b58decode(rule.owner);                     // worker decodes
  const sigBack = b58decode(sigB58);
  assert.strictEqual(pub.length, 32, "pubkey must decode to 32 bytes");
  assert.strictEqual(sigBack.length, 64, "signature must decode to 64 bytes");
  assert.ok(nacl.sign.detached.verify(workerPreimage(rule), sigBack, pub),
    "the worker could not verify a signature the console just produced");
});

t("a rule whose TARGET was altered in flight fails verification", () => {
  const kp = Keypair.generate();
  const rule = { ...RULE, owner: kp.publicKey.toBase58() };
  const sig = nacl.sign.detached(miniPreimage(rule), kp.secretKey);
  // The attack this exists to stop: rewrite the target so the keeper sells now.
  const tampered = { ...rule, targetBps: 1000 };
  assert.ok(!nacl.sign.detached.verify(workerPreimage(tampered), sig, kp.publicKey.toBytes()),
    "an altered target still verified — the rule is forgeable");
});

t("a rule signed by a DIFFERENT wallet fails verification", () => {
  const victim = Keypair.generate(), attacker = Keypair.generate();
  const rule = { ...RULE, owner: victim.publicKey.toBase58() };
  const sig = nacl.sign.detached(miniPreimage(rule), attacker.secretKey);
  assert.ok(!nacl.sign.detached.verify(workerPreimage(rule), sig, victim.publicKey.toBytes()),
    "anyone could author a rule against someone else's wallet");
});

// ── the wallet's alphabet, whatever it is, reaches the worker as base58 ────
//
// MEASURED 2026-08-06 23:59 UTC (client_errors rows 28-31): the Farcaster host
// answers signMessage with BASE64 — 88 chars, "==" padding — and the worker
// decodes base58 only, so a valid signature died as BAD_SIGNATURE (400) before
// verification was attempted. Phantom answers base58. The console must accept
// both and emit exactly one.
t("a base64 answer (this host, measured) is converted and verifies end to end", () => {
  const kp = Keypair.generate();
  const rule = { ...RULE, owner: kp.publicKey.toBase58() };
  const sig = nacl.sign.detached(miniPreimage(rule), kp.secretKey);
  const b64 = Buffer.from(sig).toString("base64");     // what the host hands back
  const out = sigToBase58(b64);
  const back = b58decode(out);                          // what the worker does next
  assert.strictEqual(back.length, 64, "converted signature must decode to 64 bytes");
  assert.ok(nacl.sign.detached.verify(workerPreimage(rule), back, kp.publicKey.toBytes()),
    "the signature stopped verifying after base64→base58 conversion");
});

t("a base58 answer (Phantom's shape) passes through untouched", () => {
  const sig = new Uint8Array(64); require("crypto").randomFillSync(sig);
  const b58sig = b58encode(sig);
  assert.strictEqual(sigToBase58(b58sig), b58sig,
    "a base58 signature must not be re-encoded — Phantom's answer was already right");
});

t("raw bytes are encoded, and garbage is refused loudly", () => {
  const sig = new Uint8Array(64); require("crypto").randomFillSync(sig);
  assert.strictEqual(sigToBase58(sig), b58encode(sig), "raw bytes must encode to base58");
  assert.throws(() => sigToBase58("definitely-not-a-signature"),
    /neither base58 nor base64/,
    "an unrecognizable answer must throw, not be sent to die at the worker");
});

// ── base58 agrees with the reference implementation ────────────────────────
t("the hand-rolled base58 round-trips and matches bs58 exactly", () => {
  for (let i = 0; i < 200; i++) {
    const n = [32, 64, 1, 5][i % 4];
    const b = new Uint8Array(n);
    require("crypto").randomFillSync(b);
    if (i % 5 === 0) b[0] = 0;                 // leading-zero byte: the bug that was here
    if (i % 17 === 0) b.fill(0);
    const mine = b58encode(b);
    assert.strictEqual(mine, b58.encode(b), `encode mismatch at len ${n}`);
    assert.strictEqual(Buffer.from(b58decode(mine)).toString("hex"), Buffer.from(b).toString("hex"),
      `round-trip mismatch at len ${n}`);
  }
});

// ── the worker's field gates match the desk and the contract ───────────────
t("the desk cannot offer a target the worker will reject", () => {
  // THE PROPERTY, unchanged since this test was written: a user must never be
  // able to set a target, pay for the coin, sign the rule, and THEN get a
  // silent 400 from the ledger. Only its shape changed — the desk used to
  // offer three fixed buttons and the worker an allowlist of three values;
  // it now offers a continuous slider (Architect ruling 2026-08-01, no floor
  // and no cap) and the worker must accept exactly that continuum.
  //
  // This assertion is why the ruling did not ship broken: the slider went in
  // while the worker still allowlisted 1000/2500/5000, so 137% was signable
  // and unstorable. It was invisible until the suite itself was repaired.
  const w = WORKER.slice(WORKER.indexOf('pathname === "/api/desk/rules"'));
  const bounds = /targetBps\s*<\s*(\d+)\s*\|\|\s*targetBps\s*>\s*(\d+)/.exec(w);
  assert.ok(bounds, "the worker no longer bounds targetBps by a range");
  const [wMinBps, wMaxBps] = [Number(bounds[1]), Number(bounds[2])];

  assert.ok(/Number\.isInteger\(targetBps\)/.test(w),
    "a fractional bps truncates silently downstream (uint16); the worker must reject it");

  // The slider is the ONLY thing that authors a target now, so its range is
  // the desk's whole vocabulary. Read it from the markup rather than restating
  // it here — a test that hardcodes the number it is checking proves nothing.
  const desk = R("public/index.html");
  const sl = /id="dk-gt"[^>]*?min="(\d+)"[^>]*?max="(\d+)"/.exec(desk);
  assert.ok(sl, "the gain-target slider was not found in the desk markup");
  const [sMinBps, sMaxBps] = [Number(sl[1]) * 100, Number(sl[2]) * 100];

  assert.ok(sMinBps >= wMinBps,
    `the slider can author +${sMinBps}bps but the worker floors at ${wMinBps}`);
  assert.ok(sMaxBps <= wMaxBps,
    `the slider can author +${sMaxBps}bps but the worker caps at ${wMaxBps}`);

  // The fixed buttons are gone; any survivor is a target authored outside the
  // slider and outside this check.
  const offered = [...desk.matchAll(/Desk\.pick\([^)]*,\s*(\d+)\)/g)].map((m) => Number(m[1]));
  const outside = [...new Set(offered)].filter((b) => b < wMinBps || b > wMaxBps);
  assert.strictEqual(outside.length, 0,
    `the desk offers targets the ledger will reject: ${outside}`);
});

t("the worker rejects a stop the ratification made invalid", () => {
  // Architect ratification 2026-08-01, Option B. This replaces two tests:
  // "the worker refuses to store any stop but the un-removable one" (the
  // un-removable stop no longer exists) and "stopBps 0 means NO STOP" (0 is now
  // rejected outright rather than reinterpreted).
  const w = WORKER.slice(WORKER.indexOf('pathname === "/api/desk/rules"'));

  assert.ok(/typeof hasStop !== "boolean"/.test(w) && /STOP_UNSTATED/.test(w),
    "a rule that fails to state whether it has a stop must be rejected, not defaulted");
  const bounds = /stopBps\s*<\s*1\s*\|\|\s*stopBps\s*>\s*9999/.test(w);
  assert.ok(bounds, "a stop must be bounded 1..9999 — zero rejected, 10000 not adopted as a sentinel");
  assert.ok(/Number\.isInteger\(stopBps\)/.test(w), "a fractional stop must be rejected");
  assert.ok(/STOP_CONTRADICTION/.test(w),
    "hasStop:false carrying a stopBps is a contradiction the signature covers; it must be refused, not resolved");
  assert.ok(!/stopBps !== 1000/.test(w), "the un-removable-stop check must be gone");
});

t("the signed bytes state the stop positively — absence is never inferred", () => {
  // If the preimage omitted the line instead, a forgotten stopBps would produce
  // a VALID signature over a rule with no stop: the uninitialised-value trap
  // that disqualified zero, moved from the value to the key.
  const withStop = Buffer.from(workerPreimage(RULE)).toString();
  const noStop = Buffer.from(workerPreimage({ ...RULE, hasStop: false, stopBps: undefined })).toString();

  assert.ok(withStop.includes("hasStop:true\nstopBps:1000\n"), "a stopped rule must sign both lines");
  assert.ok(noStop.includes("hasStop:false\n"), "an unstopped rule must sign the absence explicitly");
  assert.ok(!noStop.includes("stopBps:"), "an unstopped rule must not sign a threshold at all");
  assert.notStrictEqual(withStop, noStop, "the two must not produce identical bytes");

  // And the console agrees, byte for byte, on BOTH shapes.
  for (const r of [RULE, { ...RULE, hasStop: false, stopBps: undefined }]) {
    assert.strictEqual(
      Buffer.from(miniPreimage(r)).toString("hex"),
      Buffer.from(workerPreimage(r)).toString("hex"),
      `console and worker disagree for hasStop:${r.hasStop}`);
  }
});

t("owner is the VERIFIED signer, never a field copied from the request", () => {
  const w = WORKER.slice(WORKER.indexOf('pathname === "/api/desk/rules"'));
  const verify = w.indexOf("verifyEd25519(");
  const insert = w.indexOf("INSERT INTO desk_rules");
  assert.ok(verify > -1 && insert > verify, "the signature must be checked before the write");
  assert.ok(/if \(!verified\) return json\(\{ error: "SIGNER_MISMATCH" \}, 401\)/.test(w),
    "a failed verification must refuse the write");
});

console.log(`\n${pass} checks passed`);
