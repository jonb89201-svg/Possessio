// THE SECRET-SHAPE CONTRACT.
//
// A secret arrives at a Worker in one of two shapes:
//
//   `wrangler secret put`  ->  a plain string on env
//   Secrets Store binding  ->  an OBJECT with an async get()
//
// The object shape is a trap, and it is the specific kind this protocol keeps
// getting bitten by: a binding is UNCONDITIONALLY TRUTHY. Every guard written
// as `if (!env.SOLANA_RPC) return 503` keeps compiling, keeps passing review,
// and silently stops guarding the moment the binding is introduced — with an
// empty secret behind it. The 503 that exists to say "not configured" is the
// exact thing that disappears when the worker becomes unconfigured. False Green.
//
// So this test does two jobs:
//
//   1. Runs the SHIPPED resolveSecret from BOTH workers — lifted out of their
//      real source files, not copied here — over the shapes that reach it, and
//      fails if the two implementations ever drift by a byte.
//   2. Asserts at the SOURCE level that the gates consume the RESOLVED value.
//      A behavioural test cannot catch a regression that reintroduces
//      `!env.ACCESS_KEY`, because the resolver would still be correct.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

const R = (p) => fs.readFileSync(path.join(__dirname, "..", "..", p), "utf8");
const WORKER = R("mcp/solana-mcp/worker.js");
const SCREEN = R("radar/screen.ts");

let pass = 0;
const cases = [];
const t = (name, fn) => cases.push([name, fn]);

console.log("Secret shape — string vs Secrets Store binding\n");

/// Lift a function BODY out of a source file by brace matching, so the test
/// exercises the shipped text rather than a copy that can drift from it. Body
/// only, never the signature: the radar copy is TypeScript and carries type
/// annotations that the solana-mcp copy cannot have. The bodies are what must
/// agree.
function liftBody(src, name, file) {
  const sig = src.indexOf(`async function ${name}(`);
  assert.ok(sig > -1, `${name} not found in ${file}`);
  const open = src.indexOf("{", sig);
  assert.ok(open > -1, `${name} has no body in ${file}`);
  let depth = 0, i = open;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) break;
  }
  assert.ok(depth === 0, `unbalanced braces lifting ${name} from ${file}`);
  return src.slice(open + 1, i);
}

const BODY_MCP = liftBody(WORKER, "resolveSecret", "mcp/solana-mcp/worker.js");
const BODY_RADAR = liftBody(SCREEN, "resolveSecret", "radar/screen.ts");

const compile = (body) =>
  new Function("v", `return (async function resolveSecret(v){${body}})(v);`);

const mcp = compile(BODY_MCP);
const radar = compile(BODY_RADAR);

// A binding: truthy object, async get(). This is the shape Cloudflare hands the
// worker, and the shape no truthiness check can distinguish from a good secret.
const binding = (value) => ({ get: async () => value });
const throwingBinding = () => ({ get: async () => { throw new Error("store unreachable"); } });

t("the two shipped implementations have not drifted", () => {
  assert.strictEqual(BODY_MCP, BODY_RADAR,
    "resolveSecret in radar/screen.ts and mcp/solana-mcp/worker.js differ.\n" +
    "        They are deliberate mirrors — fix both or the migration is only half done.");
});

// ---------------------------------------------------------------------------
// Behaviour, run against BOTH implementations so neither can pass alone.
// ---------------------------------------------------------------------------
const behaviours = [
  ["plain string passes through", "https://rpc.example/abc", "https://rpc.example/abc"],
  ["empty string stays empty", "", ""],
  ["undefined resolves to empty", undefined, ""],
  ["null resolves to empty", null, ""],
  ["binding yields its value", binding("https://rpc.example/xyz"), "https://rpc.example/xyz"],
  ["binding yielding empty stays empty", binding(""), ""],
  ["binding yielding non-string is refused", binding({ nope: 1 }), ""],
  ["binding yielding null is refused", binding(null), ""],
  ["object without get() is not a binding", { value: "sneaky" }, ""],
  ["number is not a secret", 12345, ""],
];

for (const [name, input, expected] of behaviours) {
  t(name, async () => {
    assert.strictEqual(await mcp(input), expected, "solana-mcp");
    assert.strictEqual(await radar(input), expected, "radar");
  });
}

t("a Secrets Store outage fails CLOSED, it does not throw into the request", async () => {
  // If this threw, solana-mcp would 500 out of fetch() instead of returning the
  // 503 "not configured", and radar's rug gate would take down a cron tick
  // rather than leaving the gate NULL.
  assert.strictEqual(await mcp(throwingBinding()), "", "solana-mcp must swallow to empty");
  assert.strictEqual(await radar(throwingBinding()), "", "radar must swallow to empty");
});

t("THE TRAP: an empty binding is truthy but resolves to nothing", async () => {
  const empty = binding("");
  assert.ok(empty, "a binding object is always truthy — this is the whole problem");
  assert.strictEqual(await mcp(empty), "",
    "resolving it must expose the emptiness that truthiness hides");
});

// ---------------------------------------------------------------------------
// Source-level guards. The resolver being correct does not help if a caller
// goes back to testing the raw env value.
// ---------------------------------------------------------------------------
const handler = WORKER.slice(WORKER.indexOf("async fetch(request, env)"));

t("solana-mcp gates on the RESOLVED secrets, never on env directly", () => {
  assert.ok(/const accessKey = await resolveSecret\(env\.ACCESS_KEY\)/.test(handler),
    "the handler must resolve ACCESS_KEY before using it");
  assert.ok(/const rpcUrl = await resolveSecret\(env\.SOLANA_RPC\)/.test(handler),
    "the handler must resolve SOLANA_RPC before using it");
  assert.ok(/if \(!accessKey \|\| accessKey\.length < 32 \|\| !rpcUrl\)/.test(handler),
    "the 503 gate must test the resolved values");
  assert.ok(!/!env\.ACCESS_KEY|!env\.SOLANA_RPC\b/.test(handler),
    "a truthiness test on a raw env secret is the False Green this test exists to stop");
});

t("the access key compared against the URL is the resolved one", () => {
  assert.ok(/keyMatches\(parts\[0\], accessKey\)/.test(handler),
    "comparing against env.ACCESS_KEY would compare a path segment to an object");
});

t("no call site fetches a raw binding as if it were a URL", () => {
  assert.ok(!/fetch\(env\.SOLANA_RPC[,)]/.test(WORKER),
    "fetch(<binding object>) is the runtime failure this migration removes");
  assert.ok(/const rpcUrl = await resolveSecret\(env\.SOLANA_RPC\)/.test(WORKER),
    "solanaRpc must resolve before fetching");
  assert.ok(/if \(!rpcUrl\) throw new Error\("solana rpc not configured"\)/.test(WORKER),
    "an unresolved RPC must be refused explicitly, not passed to fetch");
});

t("radar's rug gate resolves before testing", () => {
  assert.ok(/const url = await resolveSecret\(env\.SOLANA_RPC_URL\)/.test(SCREEN),
    "screen.ts must resolve SOLANA_RPC_URL");
  assert.ok(!/const url = env\.SOLANA_RPC_URL\b/.test(SCREEN),
    "reading the binding directly makes the gate think it is configured");
});

t("no store_id placeholder is ever left armed in a deployable config", () => {
  // An uncommented <STORE_ID> fails the deploy; worse, a real-looking wrong one
  // deploys a worker whose secrets silently resolve to empty.
  for (const f of ["mcp/solana-mcp/wrangler.jsonc", "radar/wrangler.jsonc"]) {
    for (const line of R(f).split("\n")) {
      const code = line.trim();
      if (code.startsWith("//")) continue; // documented, not armed
      assert.ok(!code.includes("<STORE_ID>"),
        `${f} has an armed placeholder store_id`);
    }
  }
});

(async () => {
  for (const [name, fn] of cases) {
    try { await fn(); console.log(`  PASS  ${name}`); pass++; }
    catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
  }
  console.log(`\n${pass} checks passed`);
})();
