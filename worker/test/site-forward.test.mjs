// POSSESSIO.IO SHOWS TAPROOT: node --experimental-strip-types --no-warnings worker/test/site-forward.test.mjs
//
// Offline. Proves fromTaproot and the end of worker/index.ts, public/.assetsignore and the Farcaster manifest:
//   - every page and file that isn't possessio.io's own is fetched from https://taproot.possessio.io (same path,
//     query string and method) and answered on possessio.io, so a mini app host keeps hearing from its own domain;
//   - only plain request headers go upstream (no cookie, no authorization); the fetch is bounded and never follows a
//     redirect; a redirect to Taproot's domain comes back as a path here; an unreachable Taproot is a plain 502;
//   - Taproot's service worker, machine paths (/api/, /.well-known/) and every method but GET and HEAD stay off it;
//   - the routes that stay on possessio.io still answer from their own code: /mcp and /api/act/;
//   - the old console's files are kept out of the upload, nothing of possessio.io's shadows a path Taproot's pages
//     load, and what stays (the approval pages, the manifest, the images) is still uploaded;
//   - the manifest moves the mini app to taproot.possessio.io (canonicalDomain), within the spec's limits.
// Cloudflare serves an uploaded asset before the Worker runs (wrangler.jsonc), so the asset layer's part is proven
// here by the files, and was measured on wrangler dev 4.153.0. The REAL default export is driven, as in
// mcp-e2e.test.mjs: Node strips the TypeScript and a resolve hook maps the extensionless imports to .ts. Taproot is
// a stub of the global fetch.
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
const TAPROOT = "https://taproot.possessio.io";

// Taproot, as the Worker reaches it: every upstream call is recorded, and `answer` decides the reply.
const calls = [];
let answer = (url) => new Response("taproot " + new URL(url).pathname, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "x-from": "taproot" } });
globalThis.fetch = async (url, init = {}) => { calls.push({ url: String(url), init }); return answer(String(url), init); };
// The asset layer as the Worker sees it: only misses reach the script, so ASSETS answers 404 here.
const env = { COUNCIL_DB: null, ASSETS: { fetch: async () => new Response("miss", { status: 404 }) } };
const ctx = { waitUntil() {}, passThroughOnException() {} };
const get = (p, method = "GET", init = {}) => W.fetch(new Request("https://possessio.io" + p, { method, ...init }), env, ctx);
const fresh = () => { calls.length = 0; };

const tests = [];
const t = (name, fn) => tests.push([name, fn]);

t("/ is Taproot's home page, answered on possessio.io", async () => {
  fresh();
  const r = await get("/");
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "taproot /");
  assert.equal(r.headers.get("location"), null, "no redirect: the page must stay on possessio.io");
  assert.equal(r.headers.get("x-from"), "taproot", "Taproot's own headers come through");
  assert.deepEqual(calls.map((c) => c.url), [TAPROOT + "/"]);
});
t("every page and file goes to the same path on Taproot, query string kept", async () => {
  for (const p of ["/seal", "/seal.html", "/index.html", "/privacy.html", "/assets_base/icon_192.png", "/vendor/x.mjs",
                   "/abi/PossessioPayments.abi.json", "/artifacts/payments.json", "/console", "/console.html", "/?ref=fc&x=1"]) {
    fresh();
    const r = await get(p);
    assert.equal(r.status, 200, p);
    assert.deepEqual(calls.map((c) => c.url), [TAPROOT + p], p);
  }
});
t("HEAD goes upstream as HEAD", async () => {
  fresh();
  await get("/seal", "HEAD");
  assert.equal(calls[0].init.method, "HEAD");
});
t("only plain request headers go upstream: never a cookie or an authorization", async () => {
  fresh();
  await get("/", "GET", { headers: { accept: "text/html", "if-none-match": '"abc"', cookie: "session=secret", authorization: "Bearer secret", "x-other": "1" } });
  const h = calls[0].init.headers;
  assert.equal(h.get("accept"), "text/html");
  assert.equal(h.get("if-none-match"), '"abc"');
  for (const k of ["cookie", "authorization", "x-other"]) assert.equal(h.get(k), null, k);
});
t("the upstream fetch is bounded and never follows a redirect", async () => {
  fresh();
  await get("/");
  assert.equal(calls[0].init.redirect, "manual");
  assert.ok(calls[0].init.signal instanceof AbortSignal, "a timeout signal");
});
t("a redirect to Taproot's own domain comes back as a path on possessio.io", async () => {
  const keep = answer;
  answer = (url) => new Response(null, { status: 301, headers: { location: url.endsWith("/docs") ? TAPROOT + "/docs/" : "https://github.com/x" } });
  try {
    let r = await get("/docs");
    assert.equal(r.status, 301);
    assert.equal(r.headers.get("location"), "/docs/");
    r = await get("/elsewhere");
    assert.equal(r.headers.get("location"), "https://github.com/x", "a redirect to another site is left as is");
  } finally { answer = keep; }
});
t("Taproot's 404 is answered as a 404", async () => {
  const keep = answer;
  answer = () => new Response("nope", { status: 404 });
  try { assert.equal((await get("/missing")).status, 404); } finally { answer = keep; }
});
t("an unreachable Taproot is a plain 502, not cached", async () => {
  const keep = answer;
  answer = () => { throw new TypeError("network down"); };
  try {
    const r = await get("/");
    assert.equal(r.status, 502);
    assert.equal(r.headers.get("cache-control"), "no-store");
    assert.match(await r.text(), /taproot\.possessio\.io/);
  } finally { answer = keep; }
});
t("Taproot's service worker is not served here: it would control the approval pages", async () => {
  fresh();
  const r = await get("/sw.js");
  assert.equal(r.status, 404);
  assert.equal(calls.length, 0);
});
t("an unknown /api/ path stays off Taproot: the asset layer's 404", async () => {
  fresh();
  assert.equal((await get("/api/nope")).status, 404);
  assert.equal(calls.length, 0);
});
t("a missing /.well-known/ file stays off Taproot: the asset layer's 404", async () => {
  fresh();
  assert.equal((await get("/.well-known/assetlinks.json")).status, 404);
  assert.equal(calls.length, 0);
});
t("a POST stays off Taproot", async () => {
  fresh();
  assert.equal((await get("/", "POST", { body: "x" })).status, 404);
  assert.equal(calls.length, 0);
});
t("/mcp still answers from its own code: the council connector initializes", async () => {
  fresh();
  const r = await get("/mcp", "POST", {
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } }),
  });
  assert.equal(r.status, 200);
  assert.ok((await r.json()).result?.serverInfo?.name);
  assert.equal(calls.length, 0);
});
t("/api/act/ still answers from its own code (no database bound here: 503 COUNCIL_DB_UNBOUND)", async () => {
  fresh();
  const r = await get("/api/act/0x" + "ab".repeat(32));
  assert.equal(r.status, 503);
  assert.equal((await r.json()).error, "COUNCIL_DB_UNBOUND");
  assert.equal(calls.length, 0);
});

// The asset layer: what is uploaded decides what answers before the Worker.
const ignored = R("public/.assetsignore").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
const KEPT = ["approve.html", "rrc-sign.html", ".well-known/farcaster.json", "_headers", "icon-1024.png", "splash-200.png", "og.png"];
// What Taproot's pages load from their own origin (the Taproot repo's tree, 2026-10-29). A possessio.io file at one
// of these paths would answer instead of Taproot's.
const TAPROOT_PATHS = ["index.html", "seal.html", "seal-core.mjs", "privacy.html", "sw.js", "manifest.webmanifest", "taproot-logo.png",
                       "abi", "artifacts", "assets_base", "vendor"];
const uploaded = (rel) => fs.existsSync(path.join(ROOT, "public", rel)) && !ignored.includes(rel);
const walk = (rel) => {
  const full = path.join(ROOT, "public", rel);
  if (!fs.existsSync(full)) return [];
  if (!fs.statSync(full).isDirectory()) return [rel];
  return fs.readdirSync(full).flatMap((n) => walk(rel + "/" + n));
};
t("wrangler.jsonc still serves public/ first and sends misses to the Worker", () => {
  const w = R("wrangler.jsonc");
  assert.match(w, /"assets":\s*\{\s*"directory":\s*"\.\/public",\s*"binding":\s*"ASSETS"\s*\}/);
  assert.ok(!/not_found_handling|run_worker_first/.test(w), "a setting that changes which requests reach the Worker");
});
t("public/.assetsignore keeps exactly the old console out of the upload", () => {
  assert.deepEqual([...ignored].sort(), ["artifacts/payments.json", "console.html", "desk-match.js", "miniapp-solana.js"]);
  for (const f of ignored) {
    assert.ok(!/[*?![\]\\]/.test(f) && !f.startsWith("/"), `${f}: plain paths only, so this test's exact match is the real one`);
    assert.ok(fs.existsSync(path.join(ROOT, "public", f)), `${f} is listed but not in public/`);
  }
});
t("nothing of possessio.io's answers a path Taproot's pages load", () => {
  for (const p of TAPROOT_PATHS) {
    const live = walk(p).filter(uploaded);
    assert.deepEqual(live, [], `public/${p} would answer before Taproot's`);
  }
  assert.ok(!uploaded("index.htm"), "public/index.htm would answer / before the Worker");
});
t("what stays on possessio.io is still uploaded", () => {
  for (const f of KEPT) {
    assert.ok(fs.existsSync(path.join(ROOT, "public", f)), `public/${f} is missing`);
    assert.ok(uploaded(f), `public/${f} is ignored`);
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
