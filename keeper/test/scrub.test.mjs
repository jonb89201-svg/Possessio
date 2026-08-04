// THE SCRUBBER'S OWN SUITE.
//
// A secret scanner has two failure modes and they are not symmetric:
//
//   MISS   -> a credential becomes permanent. Git history, forks, caches.
//   NOISE  -> the human learns to type --no-verify, and then every future
//             finding is missed too.
//
// The second one is the reason this file spends as much effort on what must
// NOT be flagged as on what must. This repo is full of high-entropy strings
// that are published on purpose — mined CREATE3 salts, tx hashes, keccak
// digests, git SHAs, uint160 constants. Every one of those is a chance to
// train the bypass.
//
// NOTE ON FIXTURES: every fake credential here is built by CONCATENATION at
// runtime, so no literal secret shape exists anywhere in this file. That is not
// decoration — it means this test does not itself need to be exempted from the
// scanner it is testing, and a real secret pasted here would still be caught.
"use strict";

import assert from "node:assert";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { scan, redact } from "../../tools/scrub.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

let pass = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
};

console.log("Scrubber — catches credentials, does not cry wolf\n");

// --- fixtures, assembled so the literal never appears in this file ----------
const HEX40 = "a1b2c3d4e5".repeat(4);                       // 40 hex, has letters
const B58 = "abcdefghijkmnopqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const b58of = (n) => B58.repeat(Math.ceil(n / B58.length)).slice(0, n);

const QUICKNODE = "https://" + "delicate-owl" + "." + "quiknode" + ".pro/" + HEX40 + "/";
const ALCHEMY = "https://base-mainnet." + "alchemy" + ".com/v2/" + "Ab3" + HEX40.slice(0, 29);
const APIKEY_URL = "https://api.example.com/v1/x?" + "api_key=" + "Zq7" + HEX40.slice(0, 25);
const KEYPAIR = "[" + Array.from({ length: 64 }, (_, i) => (i * 3 + 7) % 256).join(",") + "]";
const SOL_SECRET = b58of(88);
const SOL_PUBKEY = b58of(44);                                // public — must NOT flag
const PEM = "-----BEGIN " + "RSA PRIVATE KEY" + "-----";
const BEARER = "Bearer " + "Ab3Xq7" + HEX40.slice(0, 24);
const EVM_KEY = "0x" + "9f3e".repeat(16);                    // 64 hex, key-shaped

const one = (text, file = "x.js") => scan(text, file, { literals: new Set() });
const blocks = (text, file) => one(text, file).filter((f) => f.severity === "block");
const rules = (text, file) => new Set(one(text, file).map((f) => f.rule));

// ---------------------------------------------------------------------------
// IT CATCHES
// ---------------------------------------------------------------------------
t("QuickNode URL — the credential that started this", () => {
  assert.ok(rules(`const RPC = "${QUICKNODE}";`).has("quicknode-url"));
  assert.strictEqual(blocks(`const RPC = "${QUICKNODE}";`).length, 1);
});

t("REGRESSION: a credential is not exempted by its HOSTNAME", () => {
  // Found by running the end-to-end hook test, not by reading the code. A probe
  // at `fake-owl.quiknode.pro/<40 hex>` was waved through, because the
  // placeholder word list matched `fake.*` against the whole matched URL —
  // hostname included. QuickNode names endpoints from an English word list, so
  // a live token was one unlucky hostname away from being silently exempt.
  for (const host of ["fake-owl", "test-feather", "example-hill", "your-waterfall", "dummy-owl"]) {
    const url = "https://" + host + "." + "quiknode" + ".pro/" + HEX40 + "/";
    assert.strictEqual(blocks(`const RPC = "${url}";`).length, 1,
      `a token at ${host}.quiknode.pro was exempted by its hostname`);
  }
});

t("templated placeholders still exempt, on every rule", () => {
  assert.strictEqual(blocks(`const RPC = "https://host.quiknode.pro/<TOKEN>/";`).length, 0);
  assert.strictEqual(blocks("const RPC = `https://host.quiknode.pro/${TOKEN}/`;").length, 0);
});

t("RPC provider key embedded in a path", () => {
  assert.ok(rules(`fetch("${ALCHEMY}")`).has("rpc-url-embedded-key"));
});

t("credential in a query string", () => {
  assert.ok(rules(`const u = "${APIKEY_URL}";`).has("url-api-key-param"));
});

t("serialised Solana keypair", () => {
  assert.ok(rules(`const kp = ${KEYPAIR};`).has("solana-keypair-json"));
});

t("PEM private key block", () => {
  assert.ok(rules(PEM).has("pem-private-key"));
});

t("literal bearer token", () => {
  assert.ok(rules(`headers: { authorization: "${BEARER}" }`).has("bearer-token"));
});

t("an EVM private key is caught by its NAME, since 0x+64hex is a tx hash shape", () => {
  const f = blocks(`const COUNCIL_SEAT_KEY = "${EVM_KEY}";`);
  assert.strictEqual(f.length, 1, "the named-assignment rule is the only thing standing here");
  assert.strictEqual(f[0].rule, "named-secret-assignment");
  // The same value with no telling name is INVISIBLE. Stated as a test so the
  // gap is a known property rather than a surprise.
  assert.strictEqual(blocks(`const txHash = "${EVM_KEY}";`).length, 0);
});

t("a Solana SECRET key in code blocks, but a tx SIGNATURE in prose only warns", () => {
  // Identical shape — 64 bytes of base58 either way. Only context separates
  // them, so code blocks and prose warns.
  const inCode = one(`const k = "${SOL_SECRET}";`, "keeper/x.js");
  assert.strictEqual(inCode.filter((f) => f.severity === "block").length, 1, "code must block");
  const inProse = one(`Devnet transaction: \`${SOL_SECRET}\``, "laws/STATEMENT.md");
  assert.strictEqual(inProse.filter((f) => f.severity === "block").length, 0, "prose must not block");
  assert.strictEqual(inProse.filter((f) => f.severity === "warn").length, 1, "prose must still warn");
});

// ---------------------------------------------------------------------------
// IT DOES NOT CRY WOLF — the half that keeps the tool usable
// ---------------------------------------------------------------------------
const PUBLISHED = [
  ["a contract address", "address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;"],
  ["the mined CREATE3 salt", "bytes32 constant MINED_SALT = 0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9000000000000000000006cb4;"],
  ["a tx hash", "// tx 0x9ab142a07105f7ba00175a97b5886eb0cad2cec061788aa6337a21c1986c9c0d"],
  ["a uint160 decimal constant", "uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;"],
  ["a git SHA in forge install", "forge install akshatmittal/hookmate@" + HEX40],
  ["a Solana PUBLIC key", `const mint = "${SOL_PUBKEY}";`],
  ["a documented placeholder", `"store_id": "<STORE_ID>"`],
  ["a named-but-unset secret", `SOLANA_RPC = "your-quicknode-url-here"`],
  ["prose describing an attack", "If it was (e.g. `privKey = keccak256(phrase)`), anyone could"],
  ["a wrangler instruction", "npx wrangler secret put SOLANA_RPC"],
];

for (const [name, text] of PUBLISHED) {
  t(`no false positive: ${name}`, () => {
    const f = blocks(text, "src/x.sol");
    assert.strictEqual(f.length, 0,
      `flagged as ${f.map((x) => x.rule).join(",")} — this is published on purpose`);
  });
}

// ---------------------------------------------------------------------------
// EXEMPTIONS, and the tool's own hygiene
// ---------------------------------------------------------------------------
t("an allowlisted literal is not reported", () => {
  const text = `const RPC = "${QUICKNODE}";`;
  assert.strictEqual(scan(text, "x.js", { literals: new Set([QUICKNODE]) }).length, 0);
});

t("a line annotated with the rule id is exempt — and only for that rule", () => {
  assert.strictEqual(blocks(`const RPC = "${QUICKNODE}"; // scrub-allow:quicknode-url`).length, 0);
  assert.strictEqual(blocks(`const RPC = "${QUICKNODE}"; // scrub-allow:bearer-token`).length, 1,
    "an exemption must name the rule it waives, not wave everything through");
});

t("the report NEVER prints the secret it found", () => {
  const f = blocks(`const RPC = "${QUICKNODE}";`)[0];
  const line = JSON.stringify(f);
  assert.ok(!line.includes(HEX40), "the finding leaked the token it was reporting");
  assert.ok(f.masked.includes("*"), "the value must be masked");
});

t("redact() rewrites the credential and leaves the published artifact alone", () => {
  const src = `const RPC = "${QUICKNODE}";\naddress c = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;`;
  const out = redact(src);
  assert.ok(!out.includes(HEX40), "the token survived redaction");
  assert.ok(out.includes("<REDACTED:quicknode-url>"));
  assert.ok(out.includes("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"), "redaction ate a public address");
  assert.strictEqual(blocks(out).length, 0, "redacted output must itself pass the scan");
});

// ---------------------------------------------------------------------------
// THE LIVE ASSERTION. Not a fixture — the actual repository, right now.
// ---------------------------------------------------------------------------
t("the repository contains ZERO blocking findings", () => {
  const r = execFileSync("node", ["tools/scrub.mjs", "--check"],
    { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  assert.ok(/0 blocking/.test(r), `scrub reported findings:\n${r}`);
});

console.log(`\n${pass} checks passed`);
