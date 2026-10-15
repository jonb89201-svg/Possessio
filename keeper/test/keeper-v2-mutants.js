// Planted breaks for keeper v2. node keeper/test/keeper-v2-mutants.js [name-filter]
// Each mutant removes one v2 safeguard; keeper-v2.test.js must go red for every
// one. A crash is NOT a kill: the suite has to fail a named check.
// Mutants run in throwaway copies of keeper/ + miniapp/, never in the working
// tree, so a mutated file can never be committed, and they run in parallel.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const MUTANTS = [
  ["lifecycle.js", "expired rules are never retired", "if (now - rule.openedAt > cfg.maxAgeMs) return RETIRE.EXPIRED;\n  return null;", "return null;"],
  ["lifecycle.js", "an RPC error counts as absence", "  if (reading.readError) return s;\n", ""],
  ["lifecycle.js", "an empty account stays armed", "if (BigInt(reading.amount) === 0n) return { ...s, retire: RETIRE.EMPTY };", ""],
  ["engine.js", "fires without re-reading the chain", "const fresh = await readDelegate({ connection, owner: e.rule.user, mint: e.rule.mint, keeper: keeperPk });\n      if (fresh.readError)", "const fresh = e.live;\n      if (fresh.readError)"],
  ["engine.js", "DRY_RUN trigger is not retired", "if (res.dryRun) { await retire(id, L.RETIRE.DRY_RUN_FIRED, `${t.kind}, nothing signed`); continue; }", "if (res.dryRun) continue;"],
  ["engine.js", "pushed revokes are ignored", "    const e = book.get(id);\n    if (!e || e.phase !== \"armed\") return;\n    let reading;", "    return;\n    let reading;"],
  ["engine.js", "pending reads ignore the budget", "      if (!budget.ok()) return;\n      if (armedCount() >= maxArmed)", "      if (armedCount() >= maxArmed)"],
  ["engine.js", "armed cap removed", "      if (armedCount() >= maxArmed) {", "      if (false) {"],
  ["engine.js", "stale rules enter the book", "      if (why) { retired.set(id, why); continue; }", "      if (why && why === \"malformed\") { retired.set(id, why); continue; }"],
  ["budget.js", "the ceiling never trips", "      if (used + n > dailyLimit) {", "      if (false) {"],
  ["budget.js", "QuickNode allowed", "  if (/quiknode|quicknode/i.test(u.hostname))", "  if (false)"],
  ["budget.js", "unmetered methods allowed", "      return () => { throw new Error(`unmetered RPC method \"${prop}\" — add it to METERED before using it`); };", "      return v.bind(target);"],
];

function runOne([file, name, from, to]) {
  return new Promise((resolve) => {
    const src = fs.readFileSync(path.join(ROOT, "keeper", file), "utf8");
    if (!src.includes(from)) return resolve({ name, killed: false, note: `anchor not found in ${file} (STALE)` });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-mut-"));
    fs.cpSync(path.join(ROOT, "keeper"), path.join(dir, "keeper"), { recursive: true });
    fs.cpSync(path.join(ROOT, "miniapp"), path.join(dir, "miniapp"), { recursive: true });
    fs.symlinkSync(path.join(ROOT, "node_modules"), path.join(dir, "node_modules"));
    fs.writeFileSync(path.join(dir, "keeper", file), src.replace(from, to));
    const child = spawn(process.execPath, [path.join(dir, "keeper", "test", "keeper-v2.test.js")], { cwd: dir });
    let out = "";
    child.stdout.on("data", (d) => (out += d)); child.stderr.on("data", (d) => (out += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 900000);
    child.on("close", (code) => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      const fails = out.match(/FAIL {2}.*/g) || [];
      resolve({ name, killed: code !== 0 && fails.length > 0, note: fails.length ? fails[0].slice(6, 100) : `exit ${code}, no failed check (crash or pass)` });
    });
  });
}

(async () => {
  const filter = process.argv[2];
  const todo = MUTANTS.filter((m) => !filter || m[1].includes(filter));
  const width = Math.max(1, Math.min(4, os.cpus().length));
  const results = [];
  let next = 0;
  await Promise.all(Array.from({ length: width }, async () => {
    while (next < todo.length) { const m = todo[next++]; const r = await runOne(m); results.push(r); console.log(`${r.killed ? "KILLED" : "ALIVE "}  ${r.name}  <- ${r.note}`); }
  }));
  const alive = results.filter((r) => !r.killed).length;
  console.log(alive ? `MUTANTS: ${alive} of ${todo.length} survived` : `MUTANTS: all ${todo.length} killed`);
  process.exit(alive ? 1 : 0);
})();
