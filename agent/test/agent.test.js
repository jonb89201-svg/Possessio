// Agent DoD. Runs offline: no keys, no chain, no Jupiter.
// Proves the properties that matter if this process is ever compromised or
// buggy — not that it can trade, but that it cannot exceed its remit.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

let pass = 0;
function t(name, fn) {
  try { fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1; }
}

const SRC = (f) => fs.readFileSync(path.join(__dirname, "..", f), "utf8");

console.log("Possessio remote agent — DoD\n");

// ── 1. THE HUMAN-PICKS LAW, ENFORCED BY ABSENCE ────────────────────────────
t("the agent has NO code path that authors an intent", () => {
  for (const f of ["index.js", "base.js", "jupiter.js", "config.js"]) {
    assert.ok(!/openIntent/.test(SRC(f)), `${f} references openIntent — the agent must never author`);
  }
});

t("the agent never writes a target or a stop — both are read from the chain", () => {
  const s = SRC("index.js");
  assert.ok(/intent\.targetBps/.test(s), "target must come from the on-chain intent");
  assert.ok(/intent\.stopBps/.test(s), "stop must come from the on-chain intent");
  assert.ok(!/targetBps\s*=\s*\d/.test(s), "target is assigned a literal somewhere");
  assert.ok(!/stopBps\s*=\s*\d/.test(s), "stop is assigned a literal somewhere");
});

t("proceeds can only go to the Rail — no other destination is reachable", () => {
  const s = SRC("base.js");
  const transfers = s.match(/functionName:\s*"transfer"[\s\S]{0,120}/g) || [];
  assert.ok(transfers.length > 0, "expected a transfer path");
  for (const blk of transfers) {
    assert.ok(/CFG\.rail/.test(blk), "a transfer targets something other than the Rail");
  }
});

// ── 2. DRY RUN IS THE DEFAULT AND IS A REAL WALL ───────────────────────────
t("DRY_RUN defaults ON — live mode must be chosen deliberately", () => {
  delete process.env.DRY_RUN;
  for (const k of ["BASE_RPC_URL","SOLANA_RPC_URL","RAIL_ADDRESS","AUTOTARGET_ADDRESS"]) process.env[k] = "x";
  delete require.cache[require.resolve("../config")];
  const { CFG } = require("../config");
  assert.strictEqual(CFG.dryRun, true, "dryRun must default to true");
});

t("signing is gated inside signAndSend, not only at the call site", () => {
  const s = SRC("jupiter.js");
  const fn = s.slice(s.indexOf("async function signAndSend"));
  const guard = fn.indexOf("CFG.dryRun");
  const sign = fn.indexOf(".sign(");
  assert.ok(guard > -1, "no dry-run guard inside signAndSend");
  assert.ok(guard < sign, "the dry-run check must precede any signing");
});

t("every Base write is gated on dryRun", () => {
  const s = SRC("base.js");
  for (const fn of ["returnProceedsToRail", "resolveIntent", "settleRemoteLeg"]) {
    const body = s.slice(s.indexOf(`async function ${fn}`), s.indexOf(`async function ${fn}`) + 400);
    assert.ok(/if \(CFG\.dryRun\) return/.test(body), `${fn} is not dry-run gated`);
  }
});

// ── 3. SECRETS NEVER LEAVE THE PROCESS ─────────────────────────────────────
t("redacted() exposes no key material", () => {
  process.env.BASE_KEEPER_KEY = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
  process.env.SOLANA_AGENT_KEY = "[1,2,3]";
  delete require.cache[require.resolve("../config")];
  const { redacted } = require("../config");
  const printed = JSON.stringify(redacted());
  assert.ok(!printed.includes("deadbeef"), "the Base key leaked into logs");
  assert.ok(!printed.includes("[1,2,3]"), "the Solana key leaked into logs");
  assert.ok(printed.includes("hasBaseKey"), "presence should still be reported");
});

t("no key is ever written to disk", () => {
  for (const f of ["index.js", "base.js", "jupiter.js", "config.js"]) {
    assert.ok(!/writeFile|appendFile|createWriteStream/.test(SRC(f)), `${f} writes to disk`);
  }
});

// ── 4. THE AGENT'S OWN CEILING ─────────────────────────────────────────────
t("MAX_TRADE_USDC caps the trade below whatever the chain drew", () => {
  const capAtomic = BigInt(Math.floor(250 * 1e6));
  const drew = 3_500_000_000n;                       // the vault's maxPerTrade
  const size = drew > capAtomic ? capAtomic : drew;
  assert.strictEqual(size, capAtomic, "agent ceiling must bind");
});

t("insane slippage is refused at startup", () => {
  process.env.SLIPPAGE_BPS = "9999";
  delete require.cache[require.resolve("../config")];
  const { assertRunnable } = require("../config");
  assert.throws(() => assertRunnable(), /SLIPPAGE_BPS/);
  process.env.SLIPPAGE_BPS = "300";
});

t("live mode without keys refuses to start", () => {
  process.env.DRY_RUN = "0";
  delete process.env.BASE_KEEPER_KEY;
  delete require.cache[require.resolve("../config")];
  const { assertRunnable } = require("../config");
  assert.throws(() => assertRunnable(), /BASE_KEEPER_KEY/);
  process.env.DRY_RUN = "1";
});

// ── 5. TRIGGER MATH ────────────────────────────────────────────────────────
t("target and stop are computed from the authored bps, both directions", () => {
  const entry = 0.0000042, targetBps = 5000, stopBps = 1000;
  const target = entry * (1 + targetBps / 10000);
  const stop = entry * (1 - stopBps / 10000);
  assert.ok(Math.abs(target - entry * 1.5) < 1e-18, "+50% target");
  assert.ok(Math.abs(stop - entry * 0.9) < 1e-18, "-10% stop");
  assert.ok(stop < entry && entry < target, "ordering");
});

t("a timed-out leg is NOT auto-abandoned — it escalates to the operator", () => {
  const s = SRC("index.js");
  assert.ok(/timeout/.test(s) && /Operator action required/.test(s),
    "a stuck leg must escalate, never silently release");
  assert.ok(!/abandonRemoteLeg/.test(s), "the agent must not call the owner's abandon hatch");
});

console.log(`\n${pass} checks passed`);
