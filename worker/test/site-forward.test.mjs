// POSSESSIO.IO FORWARDS TO TAPROOT: node --experimental-strip-types --no-warnings worker/test/site-forward.test.mjs
//
// Offline. Proves the switch of 2026-10-29 (the end of worker/index.ts, public/.assetsignore and the Farcaster
// manifest):
//   - every page request that reaches the Worker goes to https://taproot.possessio.io/ by 301, query string kept;
//   - machine paths (/api/, /.well-known/) and every method but GET and HEAD are not forwarded;
//   - the routes that stay on possessio.io still answer from their own code: /mcp (the council connector), /api/act/
//     (act approvals) and /artifacts/payments.json;
//   - the old console's files are kept out of the upload, nothing is served at "/", and what stays (the approval
//     pages, the manifest, the images) is still uploaded;
//   - the manifest moves the mini app to taproot.possessio.io (canonicalDomain), within the spec's limits.
// Cloudflare serves an uploaded asset before the Worker runs (wrangler.jsonc), so the asset layer's part is proven
// here by the files, and was measured on wrangler dev 4.153.0 for PR #198. The REAL default export is driven, as in
// mcp-e2e.test.mjs: Node strips the TypeScript and a resolve hook maps the extensionless imports to .ts.
import { register } from "node:module";
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
register("data:text/javascript," + encodeURIComponent(`
  import { existsSync } from "node:fs"; import { fileURLToPath } from "node:url";
  export async function resolve(spec, ctx, next) {
    if ((spec.startsWith("./") || spec.startsWith("../")) && !/\\.[cm]?[jt]s$/.test(spec)) {
      const u = new URL(spec + ".ts", ctx.parentURL);
      if (existsSync(fileURLToPath(u))) return next(u.href, ctx);
    }
    return next(spec, ctx);
  }`), import.meta.url);

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..");
const R = (p) => fs.readFileSync(path.join(ROOT, p), "utf8");
const W = (await import(path.join(ROOT, "worker", "index.ts"))).default;
const TAPROOT = "https://taproot.possessio.io/";

// The asset layer as the Worker sees it: only misses reach the script, so ASSETS answers 404 here.
const env = { COUNCIL_DB: null, ASSETS: { fetch: async () => new Response("miss", { status: 404 }) } };
const ctx = { waitUntil() {}, passThroughOnException() {} };
const get = (p, method = "GET", init = {}) => W.fetch(new Request("https://possessio.io" + p, { method, ...init }), env, ctx);

const tests = [];
const t = (name, fn) => tests.push([name, fn]);

t("/ goes to Taproot's home page by 301", async () => {
  const r = await get("/");
  assert.equal(r.status, 301);
  assert.equal(r.headers.get("location"), TAPROOT);
});
t("HEAD / goes to Taproot too", async () => {
  const r = await get("/", "HEAD");
  assert.equal(r.status, 301);
  assert.equal(r.headers.get("location"), TAPROOT);
});
t("the old console's pages and any other page go to Taproot's home page", async () => {
  for (const p of ["/console", "/console.html", "/index.html", "/desk-match.js", "/miniapp-solana.js", "/some/deep/page"]) {
    const r = await get(p);
    assert.equal(r.status, 301, p);
    assert.equal(r.headers.get("location"), TAPROOT, p);
  }
});
t("the query string rides along", async () => {
  const r = await get("/?ref=farcaster&x=1");
  assert.equal(r.headers.get("location"), TAPROOT + "?ref=farcaster&x=1");
});
t("browsers keep the redirect for an hour, not forever", async () => {
  assert.equal((await get("/")).headers.get("cache-control"), "public, max-age=3600");
});
t("an unknown /api/ path is not forwarded: the asset layer's 404", async () => {
  const r = await get("/api/nope");
  assert.equal(r.status, 404);
  assert.equal(r.headers.get("location"), null);
});
t("a missing /.well-known/ file is not forwarded: the asset layer's 404", async () => {
  const r = await get("/.well-known/assetlinks.json");
  assert.equal(r.status, 404);
  assert.equal(r.headers.get("location"), null);
});
t("a POST to a page is not forwarded", async () => {
  const r = await get("/", "POST", { body: "x" });
  assert.equal(r.status, 404);
  assert.equal(r.headers.get("location"), null);
});
t("/mcp still answers: the council connector initializes", async () => {
  const r = await get("/mcp", "POST", {
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } }),
  });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.ok(body.result?.serverInfo?.name, JSON.stringify(body).slice(0, 200));
});
t("/api/act/ still answers from its own code (no database bound here: 503 COUNCIL_DB_UNBOUND)", async () => {
  const r = await get("/api/act/0x" + "ab".repeat(32));
  assert.equal(r.status, 503);
  assert.equal((await r.json()).error, "COUNCIL_DB_UNBOUND");
});
t("/artifacts/payments.json still answers from its own route", async () => {
  const r = await get("/artifacts/payments.json");
  assert.equal(r.status, 503);
  assert.equal((await r.json()).error, "template artifact unavailable");
});

// The asset layer: what is uploaded decides what answers before the Worker.
const ignored = R("public/.assetsignore").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
const KEPT = ["approve.html", "rrc-sign.html", ".well-known/farcaster.json", "artifacts/payments.json", "_headers", "icon-1024.png", "splash-200.png", "og.png"];
t("wrangler.jsonc still serves public/ first and sends misses to the Worker", () => {
  const w = R("wrangler.jsonc");
  assert.match(w, /"assets":\s*\{\s*"directory":\s*"\.\/public",\s*"binding":\s*"ASSETS"\s*\}/);
  assert.ok(!/not_found_handling|run_worker_first/.test(w), "a setting that changes which requests reach the Worker");
});
t("public/.assetsignore keeps exactly the old console out of the upload", () => {
  assert.deepEqual([...ignored].sort(), ["console.html", "desk-match.js", "miniapp-solana.js"]);
  for (const f of ignored) {
    assert.ok(!/[*?![\]/\\]/.test(f), `${f}: plain file names only, so this test's exact match is the real one`);
    assert.ok(fs.existsSync(path.join(ROOT, "public", f)), `${f} is listed but not in public/`);
  }
});
t("nothing is served at /: public/ has no index page", () => {
  for (const f of ["index.html", "index.htm"]) assert.ok(!fs.existsSync(path.join(ROOT, "public", f)), `public/${f} would answer / before the Worker`);
});
t("what stays on possessio.io is still uploaded", () => {
  for (const f of KEPT) {
    assert.ok(fs.existsSync(path.join(ROOT, "public", f)), `public/${f} is missing`);
    assert.ok(!ignored.includes(f) && !ignored.includes(path.basename(f)), `public/${f} is ignored`);
  }
});
t("the landing page is kept, unserved, for a subdomain", () => {
  assert.ok(fs.existsSync(path.join(ROOT, "landing", "index.html")));
});

// The Farcaster manifest: the mini app moves to taproot.possessio.io (the spec's domain migration).
const fc = JSON.parse(R("public/.well-known/farcaster.json"));
const m = fc.miniapp;
t("the manifest names taproot.possessio.io as the canonical domain", () => {
  assert.ok(m && !fc.frame, "the miniapp key, not the old frame key");
  assert.equal(m.canonicalDomain, "taproot.possessio.io");
  assert.equal(m.version, "1");
  assert.equal(m.name, "Taproot");
  assert.equal(m.homeUrl, "https://possessio.io");
});
t("the manifest keeps possessio.io out of search, so Taproot is listed once", () => {
  assert.equal(m.noindex, true);
});
t("the manifest stays within the spec's limits", () => {
  assert.ok(m.name.length <= 32 && m.subtitle.length <= 30 && m.description.length <= 170);
  assert.ok(/^#[0-9a-fA-F]{6}$/.test(m.splashBackgroundColor));
  for (const u of [m.iconUrl, m.splashImageUrl]) assert.match(u, /^https:\/\/taproot\.possessio\.io\/assets_base\/[a-z0-9_]+\.png$/);
  assert.ok(m.tags.length <= 5 && m.tags.every((x) => /^[a-z0-9]{1,20}$/.test(x)), JSON.stringify(m.tags));
});
t("a signature added later must be for possessio.io", () => {
  if (!fc.accountAssociation) return;   // not signed yet: the Architect signs with his Farcaster account
  const b64 = (s) => JSON.parse(Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"));
  assert.equal(b64(fc.accountAssociation.payload).domain, "possessio.io");
});

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.log(`  FAIL  ${name}\n        ${String(e.message).split("\n").join("\n        ")}`); fail++; }
}
console.log(`\nRESULT: ${pass}/${pass + fail} PASS`);
process.exit(fail ? 1 : 0);
