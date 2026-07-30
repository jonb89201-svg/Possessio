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

  // Strip the type annotations that appear INSIDE the body (e.g. `const
  // bytes: number[] = []`). The signature is replaced wholesale above.
  const body = src.slice(bodyStart, end)
    .replace(/\bconst\s+(\w+)\s*:\s*[\w[\]<>|\s]+?=/g, "const $1 =");

  // eslint-disable-next-line no-eval
  return eval(`(() => { ${extra}\nfunction ${name}(${params}) ${body}\nreturn ${name}; })()`);
}

const WORKER = R("worker/index.ts");
const MINIAPP = R("public/miniapp-solana.js");
const ALPHA = 'const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";';

const workerPreimage = lift(WORKER, "deskRulePreimage", "r");
const miniPreimage = lift(MINIAPP, "rulePreimage", "{ owner, mint, decimals, entryPrice, targetBps, stopBps, nonce }");
const b58encode = lift(MINIAPP, "b58encode", "bytes", ALPHA);
const b58decode = lift(WORKER, "b58decode", "s", ALPHA);

const RULE = {
  owner: "ARjf4vUNiU8cW6xXfBfiL8ibc5qC4pYim5mLxbe6uog5",
  mint: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",
  decimals: 5,
  entryPrice: 0.0000028914,
  targetBps: 2500,
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
    decimals: 9, entryPrice: 0.0000029, targetBps: 5000, stopBps: 500, nonce: "other",
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
t("the worker accepts exactly the three targets the desk offers", () => {
  const w = WORKER.slice(WORKER.indexOf('pathname === "/api/desk/rules"'));
  assert.ok(/targetBps !== 1000 && targetBps !== 2500 && targetBps !== 5000/.test(w),
    "the ledger must accept the same vocabulary as AutoTarget.openIntent");
  // The desk builds these buttons inside a JS string, so the quotes are
  // backslash-escaped in the file: Desk.pick(\''+qid+'\',1000).
  const desk = R("public/index.html");
  for (const bps of [1000, 2500, 5000]) {
    assert.ok(new RegExp(`Desk\\.pick\\([^)]*,\\s*${bps}\\)`).test(desk),
      `the desk offers no +${bps}bps button`);
  }
  // And nothing else — a fourth button would be a target the ledger rejects,
  // i.e. a user tapping it and getting a silent 400 after paying for the coin.
  const offered = [...desk.matchAll(/Desk\.pick\([^)]*,\s*(\d+)\)/g)].map((m) => Number(m[1]));
  const extra = [...new Set(offered)].filter((b) => ![1000, 2500, 5000].includes(b));
  assert.strictEqual(extra.length, 0, `the desk offers targets the ledger will reject: ${extra}`);
});

t("the worker refuses to store any stop but the un-removable one", () => {
  const w = WORKER.slice(WORKER.indexOf('pathname === "/api/desk/rules"'));
  assert.ok(/stopBps !== 1000/.test(w) && /STOP_IS_FIXED/.test(w),
    "a client must not be able to widen or remove its own stop");
  const sol = R("src/PossessioAutoTarget.sol");
  assert.ok(/uint16 public constant STOP_BPS = 1000;/.test(sol),
    "the contract's stop and the ledger's stop must be the same number");
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
