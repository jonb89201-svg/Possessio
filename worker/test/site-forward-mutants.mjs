// Planted breaks for possessio.io's forward to Taproot.
//   node worker/test/site-forward-mutants.mjs [name-filter]
// Each mutant bends ONE rule; worker/test/site-forward.test.mjs must fail a named check (a crash is not a kill).
// Every mutant runs in a throwaway copy, never in the working tree, so a mutated file can never be committed. A
// `from` of null creates the file instead of editing it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const FWD = '      return new Response(null, { status: 301, headers: { location: TAPROOT_HOME + search, "cache-control": "public, max-age=3600" } });';

// [file, name, from, to]
const M = [
  ["worker/index.ts", "pages are not forwarded", FWD, "      return env.ASSETS.fetch(request);"],
  ["worker/index.ts", "the move is temporary", "{ status: 301, headers: { location: TAPROOT_HOME", "{ status: 302, headers: { location: TAPROOT_HOME"],
  ["worker/index.ts", "the query string is dropped", "location: TAPROOT_HOME + search,", "location: TAPROOT_HOME,"],
  ["worker/index.ts", "browsers keep the redirect forever", '"cache-control": "public, max-age=3600" } });', '"cache-control": "public, max-age=31536000, immutable" } });'],
  ["worker/index.ts", "the API is forwarded", ' && !pathname.startsWith("/api/") && !pathname.startsWith("/.well-known/")) {', ' && !pathname.startsWith("/.well-known/")) {'],
  ["worker/index.ts", "the manifest's folder is forwarded", ' && !pathname.startsWith("/.well-known/")) {\n      return new Response(null', ") {\n      return new Response(null"],
  ["worker/index.ts", "a POST is forwarded", '    if ((request.method === "GET" || request.method === "HEAD") && !pathname', "    if (!pathname"],
  ["worker/index.ts", "the council connector falls to the forward", '    if (pathname === "/mcp" || pathname.startsWith("/mcp/")) return handleMcp(request, env);\n', ""],
  ["worker/index.ts", "act approvals fall to the forward", '    if (pathname.startsWith("/api/act/")) return handleAct(request, env, pathname.slice("/api/act/".length));\n', ""],
  ["worker/index.ts", "Taproot's address is wrong", 'const TAPROOT_HOME = "https://taproot.possessio.io/";', 'const TAPROOT_HOME = "https://possessio.io/console";'],
  ["public/.assetsignore", "the old console is served again", "\nconsole.html\n", "\n"],
  ["public/.assetsignore", "the approval page is left out of the upload", "\nminiapp-solana.js\n", "\nminiapp-solana.js\napprove.html\n"],
  ["public/index.html", "a page answers / before the Worker", null, "<!doctype html><title>old</title>\n"],
  ["wrangler.jsonc", "the Worker runs before the assets", '"assets": { "directory": "./public", "binding": "ASSETS" }', '"assets": { "directory": "./public", "binding": "ASSETS", "run_worker_first": true }'],
  ["public/.well-known/farcaster.json", "the manifest does not name the new domain", ',\n    "canonicalDomain": "taproot.possessio.io"', ""],
  ["public/.well-known/farcaster.json", "the old domain stays in search", '"noindex": true', '"noindex": false'],
  ["public/.well-known/farcaster.json", "the manifest keeps the old frame key", '  "miniapp": {', '  "frame": {'],
];

function copyTree(dir) {
  for (const p of ["worker", "public", "landing"]) fs.cpSync(path.join(ROOT, p), path.join(dir, p), { recursive: true });
  fs.copyFileSync(path.join(ROOT, "wrangler.jsonc"), path.join(dir, "wrangler.jsonc"));
  fs.symlinkSync(path.join(ROOT, "node_modules"), path.join(dir, "node_modules"));
}

function runOne([file, name, from, to]) {
  return new Promise((resolve) => {
    let out;
    if (from === null) {
      if (fs.existsSync(path.join(ROOT, file))) return resolve({ name, killed: false, note: `${file} already exists (STALE)` });
      out = to;
    } else {
      const src = fs.readFileSync(path.join(ROOT, file), "utf8");
      const n = src.split(from).length - 1;
      if (n !== 1) return resolve({ name, killed: false, note: `anchor found ${n}x in ${file} (STALE)` });
      out = src.replace(from, to);
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "site-mut-"));
    copyTree(dir);
    fs.writeFileSync(path.join(dir, file), out);
    const child = spawn(process.execPath, ["--experimental-strip-types", "--no-warnings", path.join(dir, "worker/test/site-forward.test.mjs")], { cwd: dir });
    let log = "";
    child.stdout.on("data", (d) => (log += d)); child.stderr.on("data", (d) => (log += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 120000);
    child.on("close", (code) => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      const fails = log.match(/^ *FAIL .*/gm) || [];
      resolve({ name, code, killed: code !== 0 && fails.length > 0, note: fails.length ? fails[0].trim().slice(0, 110) : `exit ${code}, no failed check (crash or pass): ${log.trim().split("\n").pop().slice(0, 80)}` });
    });
  });
}

// The unbroken copy must pass first, or no kill means anything.
const control = await runOne(["worker/index.ts", "control", FWD, FWD]);
if (control.code !== 0) { console.log(`HARNESS BROKEN  the unbroken copy fails: ${control.note}`); process.exit(2); }
console.log("control  the unbroken copy passes worker/test/site-forward.test.mjs");

const filter = process.argv[2];
const list = M.filter((m) => !filter || m[1].includes(filter));
const results = [];
let next = 0;
await Promise.all(Array.from({ length: Math.max(1, Math.min(4, os.cpus().length)) }, async () => {
  while (next < list.length) {
    const r = await runOne(list[next++]);
    results.push(r);
    console.log(`${r.killed ? "KILLED" : "ALIVE "}  ${r.name}  <- ${r.note}`);
  }
}));
const alive = results.filter((r) => !r.killed).length;
console.log(alive ? `MUTANTS: ${alive} of ${results.length} survived` : `MUTANTS: all ${results.length} killed`);
process.exit(alive ? 1 : 0);
