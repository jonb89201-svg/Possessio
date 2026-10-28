// Planted breaks for the desk's two lists.
//   node worker/test/desk-feed-mutants.mjs [--e2e] [name-filter]
// Each mutant removes ONE safeguard; the suite that guards it must fail a named
// check (a crash is not a kill). Node mutants run worker/test/desk-feed.test.mjs;
// with --e2e, browser mutants also run worker/test/desk-ui.e2e.cjs (needs
// Chromium + playwright, see that file) on the scenarios that should catch them.
// Every mutant runs in a throwaway copy, never in the working tree, so a
// mutated file can never be committed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// [file, name, from, to]
const NODE = [
  ["worker/desk-feed.mjs", "the allowlist gate is removed", '  if (!deskArmingAllowed(env, owner)) return json({ error: "DESK_PRIVATE_BETA" }, 403);\n', ""],
  ["worker/desk-feed.mjs", "a failed signature is accepted", '  if (!verified) return json({ error: "SIGNER_MISMATCH" }, 401);\n', ""],
  ["worker/desk-feed.mjs", "the 10-minute window is removed", '  if (Math.abs(now() - ts) > TRENDING_SIG_WINDOW_MS) return json({ error: "STALE_SIGNATURE" }, 400);\n', ""],
  ["worker/desk-feed.mjs", "a replayed nonce is accepted", '    if (/UNIQUE|constraint/i.test(String((e && e.message) || e))) return json({ error: "NONCE_ALREADY_USED" }, 409);\n    throw e;', "    void e;"],
  ["worker/desk-feed.mjs", "the 50-coin cap is removed", '  if (count && Number(count.n) >= TRENDING_MAX) return json({ error: "TRENDING_FULL", max: TRENDING_MAX }, 409);\n', ""],
  ["worker/desk-feed.mjs", "the signed text omits the action", "    `action:${action}\\n` +\n", ""],
  ["worker/desk-feed.mjs", "spent nonces are never pruned", '  await db.prepare("DELETE FROM desk_trending_nonces WHERE ts_ms < ?1").bind(now() - 2 * TRENDING_SIG_WINDOW_MS).run();\n', ""],
  ["worker/desk-feed.mjs", "unverified tokens pass", "    if (!r || r.isVerified !== true) {", "    if (!r) {"],
  ["worker/desk-feed.mjs", "non-Solana token programs pass", '    if (!SOLANA_TOKEN_PROGRAMS.has(r.tokenProgram) || typeof r.id !== "string" || !isMint(r.id)) {', '    if (typeof r.id !== "string") {'],
  ["worker/desk-feed.mjs", "tokenized stocks pass", '    if ((r.tags || []).some((t) => EXCLUDED_TAGS.has(t))) { drop("tokenized stock / RWA"); continue; }\n', ""],
  ["worker/desk-feed.mjs", "mint authority is not checked", '    if (a.mintAuthorityDisabled !== true) { drop("mint authority not off"); continue; }\n', ""],
  ["worker/desk-feed.mjs", "an unknown freeze authority passes as safe", "if (a.freezeAuthorityDisabled !== true)", "if (a.freezeAuthorityDisabled === false)"],
  ["worker/desk-feed.mjs", "the liquidity floor is removed", '    if (!(Number(r.liquidity) >= minLiquidityUsd)) { drop("liquidity below floor"); continue; }\n', ""],
  ["worker/desk-feed.mjs", "oldest first", "  kept.sort((x, y) => y.firstPoolAt - x.firstPoolAt);", "  kept.sort((x, y) => x.firstPoolAt - y.firstPoolAt);"],
  ["worker/desk-feed.mjs", "the limit is applied before sorting", "  kept.sort((x, y) => y.firstPoolAt - x.firstPoolAt);\n  return { tokens: kept.slice(0, limit),", "  const top = kept.slice(0, limit); top.sort((x, y) => y.firstPoolAt - x.firstPoolAt);\n  return { tokens: top,"],
  ["worker/desk-feed.mjs", "a non-https icon is passed through", String.raw`typeof r.icon === "string" && /^https:\/\//.test(r.icon)`, 'typeof r.icon === "string"'],
  ["worker/desk-feed.mjs", "an upstream failure is served, and cached, as an empty list", '    if (!r.ok) return json({ error: "UPSTREAM", status: r.status }, 502);\n    rows = await r.json();', "    rows = r.ok ? await r.json() : [];"],
  ["worker/desk-feed.mjs", "the cache is never read", "    const hit = await cache.match(key);\n    if (hit) return hit;", "    const hit = null;"],
  ["public/miniapp-solana.js", "the console's message drifts by one byte", '    "possessio.desk.trending.v1\\n" +', '    "possessio.desk.trending.v1\\r\\n" +'],
  ["public/miniapp-solana.js", "the console stops padding its text", "  let text = trendingMessage({ action, owner, mint, ts, nonce });\n  while (text.length % 3 !== 0) {", "  let text = trendingMessage({ action, owner, mint, ts, nonce });\n  while (false) {"],
  ["public/miniapp-solana.js", "the console hands the host raw text", '  const res = await provider.signMessage(toWireMessage(text));\n  const signature = sigToBase58(res?.signature ?? res);\n  const r = await fetch("/api/desk/trending"', '  const res = await provider.signMessage(text);\n  const signature = sigToBase58(res?.signature ?? res);\n  const r = await fetch("/api/desk/trending"'],
  ["worker/index.ts", "the trending route skips the allowlist", "verifyEd25519, deskArmingAllowed });", "verifyEd25519, deskArmingAllowed: () => true });"],
  ["worker/index.ts", "the worker's allowlist lets everyone in", '  if (raw === "*") return true;\n  const set = new Set([DESK_OWNER_DEFAULT]);', "  return true;\n  const set = new Set([DESK_OWNER_DEFAULT]);"],
  ["public/console.html", "the console's admin gate is open", "function canCurate(){ var M=window.PossessioMiniApp; return !!(M&&M.ready&&M.address&&M.trendingAction&&deskArmingOpen(M.address)); }", "function canCurate(){ return true; }"],
];

// [file, name, from, to, scenarios]
const E2E = [
  ["public/console.html", "admin buttons for everyone", "function canCurate(){ var M=window.PossessioMiniApp; return !!(M&&M.ready&&M.address&&M.trendingAction&&deskArmingOpen(M.address)); }", "function canCurate(){ return true; }", "lists,outsider"],
  ["public/console.html", "the verified feed leads trending", "var head=take(S.pinned,3).concat(take(S.trendRows,50)).concat(take(S.verifiedRows,20));", "var head=take(S.pinned,3).concat(take(S.verifiedRows,20)).concat(take(S.trendRows,50));", "lists"],
  ["public/console.html", "the Base screen is back", "var BASE_SCREEN=false;", "var BASE_SCREEN=true;", "lists"],
  ["public/console.html", "a paused radar's side lists leak", "S.solRows=[]; S.listRows=[]; S.fastRows=[]; S.notableRows=[]; S.graduateRows=[]; S.inWindow=0;", "S.solRows=[]; S.inWindow=0;", "stale"],
  ["public/console.html", "an unpriced coin is buyable", "(c.priced===false?'<button class=\"tbtn t10\" disabled", "(false?'<button class=\"tbtn t10\" disabled", "lists"],
  ["public/console.html", "delete adds instead", 'untrend:function(a){ return trendAct("remove",a); }', 'untrend:function(a){ return trendAct("add",a); }', "admin"],
  ["public/console.html", "the list is not re-read after an edit", "      await pollTrending();\n", "", "admin"],
  ["public/console.html", "＋ Trending on every Solana card", "    if(c.pinned) return '<button class=\"cabtn trend\" onclick=\"Desk.trend(", "    if(true) return '<button class=\"cabtn trend\" onclick=\"Desk.trend(", "admin"],
  ["public/console.html", "＋ Trending on a Base find", 'if(c.ch!=="sol"||!c.addr||!canCurate())return "";', 'if(!c.addr||!canCurate())return "";', "admin"],
  ["public/console.html", "a wallet that connects late gets no buttons", 'window.addEventListener("possessio-miniapp", function(){ var v=$("#desk-view"); if(v&&!v.hidden) renderList(); });', "", "admin"],
  ["public/console.html", "a recovered feed keeps the demo flag", 'if(out.length){ S.source="live"; S.live=out.slice(0,cap); renderList(); return; }', "if(out.length){ S.live=out.slice(0,cap); renderList(); return; }", "recover"],
  ["public/console.html", "the demo shows while a feed is reachable", 'if(S.radar==="down"&&S.verified==="down"&&S.trending==="down"){', 'if(S.radar==="down"){', "empty"],
];

function copyTree(dir) {
  for (const p of ["worker", "public"]) fs.cpSync(path.join(ROOT, p), path.join(dir, p), { recursive: true });
  fs.mkdirSync(path.join(dir, "radar", "migrations"), { recursive: true });
  fs.copyFileSync(path.join(ROOT, "radar/migrations/0035_desk_trending.sql"), path.join(dir, "radar/migrations/0035_desk_trending.sql"));
  fs.symlinkSync(path.join(ROOT, "node_modules"), path.join(dir, "node_modules"));
}

function runOne([file, name, from, to, scenarios], e2e) {
  return new Promise((resolve) => {
    const src = fs.readFileSync(path.join(ROOT, file), "utf8");
    const n = src.split(from).length - 1;
    if (n !== 1) return resolve({ name, killed: false, note: `anchor found ${n}x in ${file} (STALE)` });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "desk-mut-"));
    copyTree(dir);
    fs.writeFileSync(path.join(dir, file), src.replace(from, to));
    const child = e2e
      ? spawn(process.execPath, [path.join(ROOT, "worker/test/desk-ui.e2e.cjs")], { cwd: dir, env: { ...process.env, DESK_ROOT: path.join(dir, "public"), DESK_MODES: scenarios } })
      : spawn(process.execPath, ["--no-warnings", path.join(dir, "worker/test/desk-feed.test.mjs")], { cwd: dir });
    let out = "";
    child.stdout.on("data", (d) => (out += d)); child.stderr.on("data", (d) => (out += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 600000);
    child.on("close", (code) => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      const fails = out.match(/^ *FAIL .*/gm) || [];
      resolve({ name, killed: code !== 0 && fails.length > 0, note: fails.length ? fails[0].trim().slice(0, 110) : `exit ${code}, no failed check (crash or pass): ${out.trim().split("\n").pop().slice(0, 80)}` });
    });
  });
}

async function runAll(list, e2e, width) {
  const results = [];
  let next = 0;
  await Promise.all(Array.from({ length: width }, async () => {
    while (next < list.length) {
      const m = list[next++];
      const r = await runOne(m, e2e);
      results.push(r);
      console.log(`${r.killed ? "KILLED" : "ALIVE "}  ${e2e ? "[e2e] " : ""}${r.name}  <- ${r.note}`);
    }
  }));
  return results;
}

const args = process.argv.slice(2), e2e = args.includes("--e2e"), filter = args.find((a) => !a.startsWith("--"));
const pick = (list) => list.filter((m) => !filter || m[1].includes(filter));
const results = await runAll(pick(NODE), false, Math.max(1, Math.min(4, os.cpus().length)));
if (e2e) results.push(...await runAll(pick(E2E), true, 2));
const alive = results.filter((r) => !r.killed).length;
console.log(alive ? `MUTANTS: ${alive} of ${results.length} survived` : `MUTANTS: all ${results.length} killed`);
process.exit(alive ? 1 : 0);
