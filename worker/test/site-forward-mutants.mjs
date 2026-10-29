// Planted breaks for possessio.io showing Taproot in place (fromTaproot).
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
const CALL = "      return fromTaproot(request, pathname + search);";
const FETCH = '    res = await fetch(TAPROOT_ORIGIN + path, { method: request.method, headers, redirect: "manual", signal: AbortSignal.timeout(10_000) });';

// [file, name, from, to]
const M = [
  ["worker/index.ts", "pages are not served from Taproot", CALL, "      return env.ASSETS.fetch(request);"],
  ["worker/index.ts", "possessio.io redirects instead (the PR #198 blank mini app)", CALL, '      return new Response(null, { status: 301, headers: { location: TAPROOT_ORIGIN + "/" } });'],
  ["worker/index.ts", "the query string is dropped", CALL, "      return fromTaproot(request, pathname);"],
  ["worker/index.ts", "every call goes to Taproot's home page", CALL, '      return fromTaproot(request, "/");'],
  ["worker/index.ts", "HEAD goes upstream as GET", FETCH, FETCH.replace("method: request.method", 'method: "GET"')],
  ["worker/index.ts", "redirects are followed upstream", FETCH, FETCH.replace('redirect: "manual"', 'redirect: "follow"')],
  ["worker/index.ts", "the upstream fetch has no timeout", FETCH, FETCH.replace(", signal: AbortSignal.timeout(10_000)", "")],
  ["worker/index.ts", "a cookie goes upstream", 'const TAPROOT_HEADERS = ["accept",', 'const TAPROOT_HEADERS = ["cookie", "accept",'],
  ["worker/index.ts", "an authorization goes upstream", 'const TAPROOT_HEADERS = ["accept",', 'const TAPROOT_HEADERS = ["authorization", "accept",'],
  ["worker/index.ts", "every request header goes upstream", "  for (const h of TAPROOT_HEADERS) { const v = request.headers.get(h); if (v) headers.set(h, v); }", "  for (const [k, v] of request.headers) headers.set(k, v);"],
  ["worker/index.ts", "Taproot's redirect leaves possessio.io", '  if (loc && (loc === TAPROOT_ORIGIN || loc.startsWith(TAPROOT_ORIGIN + "/"))) out.headers.set("location", loc.slice(TAPROOT_ORIGIN.length) || "/");\n', ""],
  ["worker/index.ts", "an unreachable Taproot throws", "  } catch {\n    return new Response(\"Taproot did not answer.", "  } catch (e) {\n    throw e;\n    return new Response(\"Taproot did not answer."],
  ["worker/index.ts", "Taproot's service worker is served here", '      if (pathname === "/sw.js") return new Response("Not found\\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });\n', ""],
  ["worker/index.ts", "the API goes to Taproot", ' && !pathname.startsWith("/api/") && !pathname.startsWith("/.well-known/")) {', ' && !pathname.startsWith("/.well-known/")) {'],
  ["worker/index.ts", "the manifest's folder goes to Taproot", ' && !pathname.startsWith("/.well-known/")) {\n      if (pathname === "/sw.js")', ') {\n      if (pathname === "/sw.js")'],
  ["worker/index.ts", "a POST goes to Taproot", '    if ((request.method === "GET" || request.method === "HEAD") && !pathname.startsWith("/api/")', '    if (!pathname.startsWith("/api/")'],
  ["worker/index.ts", "the council connector falls to Taproot", '    if (pathname === "/mcp" || pathname.startsWith("/mcp/")) return handleMcp(request, env);\n', ""],
  ["worker/index.ts", "act approvals fall to Taproot", '    if (pathname.startsWith("/api/act/")) return handleAct(request, env, pathname.slice("/api/act/".length));\n', ""],
  ["worker/index.ts", "Taproot's address is wrong", 'const TAPROOT_ORIGIN = "https://taproot.possessio.io";', 'const TAPROOT_ORIGIN = "https://possessio.io";'],
  ["public/.assetsignore", "the old console is served again", "\nconsole.html\n", "\n"],
  ["public/.assetsignore", "possessio.io's old launch-rail artifact answers first", "\nartifacts/payments.json\n", "\n"],
  ["public/.assetsignore", "the approval page is left out of the upload", "\nminiapp-solana.js\n", "\nminiapp-solana.js\napprove.html\n"],
  ["public/index.html", "a page answers / before the Worker", null, "<!doctype html><title>old</title>\n"],
  ["public/seal.html", "a possessio.io file shadows a Taproot page", null, "<!doctype html><title>old seal</title>\n"],
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
const control = await runOne(["worker/index.ts", "control", CALL, CALL]);
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
