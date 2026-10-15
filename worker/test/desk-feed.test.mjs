// THE DESK'S TWO LISTS: node --no-warnings worker/test/desk-feed.test.mjs
//
// Offline. Proves worker/desk-feed.mjs and its wiring:
//   - the VERIFIED feed keeps only what the Architect asked for (Solana token
//     programs, no tokenized stocks, mint and freeze authority off, a liquidity
//     floor) and fails closed on anything unknown;
//   - /api/desk/verified caches one upstream fetch and never caches a failure;
//   - the TRENDING list is written only by a wallet on the arming allowlist,
//     with a real Ed25519 signature over the exact action, coin and time, once.
//
// The worker's gate, base58 and Ed25519 verifier are LIFTED from worker/index.ts
// and the console's message, wire encoding and trendingAction from
// public/miniapp-solana.js: the shipped text, not copies. The tables come from
// the real migration, run in SQLite (node:sqlite), which is what D1 is.
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import nacl from "tweetnacl";
import bs58pkg from "bs58";
import { filterVerified, handleVerified, handleTrending, trendingPreimage, EXCLUDED_TAGS, TRENDING_MAX, TRENDING_SIG_WINDOW_MS } from "../desk-feed.mjs";

const bs58 = bs58pkg.default || bs58pkg;
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const R = (p) => fs.readFileSync(path.join(ROOT, p), "utf8");
const WORKER = R("worker/index.ts"), MINIAPP = R("public/miniapp-solana.js"), HTML = R("public/index.html");
const MIGRATION = R("radar/migrations/0035_desk_trending.sql");

let pass = 0, fail = 0;
const tests = [];
const t = (name, fn) => tests.push([name, fn]);

/// Lift a function out of a source file by name, keeping `async`, and build it
/// with `scope` as its free variables. Same approach as rule-signature.test.js:
/// the caller supplies the parameter list (the worker side is TypeScript), and
/// the few type constructs that appear inside these bodies are stripped.
function lift(src, name, params, scope = {}) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start > -1, `${name} not found in source`);
  const isAsync = /async\s+$/.test(src.slice(Math.max(0, start - 16), start));
  const open = src.indexOf("(", start);
  let d = 0, closeParen = -1;
  for (let j = open; j < src.length; j++) {
    if (src[j] === "(") d++;
    else if (src[j] === ")") { d--; if (d === 0) { closeParen = j; break; } }
  }
  const bodyStart = src.indexOf("{", closeParen);
  d = 0;
  let end = -1;
  for (let j = bodyStart; j < src.length; j++) {
    if (src[j] === "{") d++;
    else if (src[j] === "}") { d--; if (d === 0) { end = j + 1; break; } }
  }
  assert.ok(closeParen > -1 && end > -1, `could not bound ${name}`);
  const body = src.slice(bodyStart, end)
    .replace(/\bconst\s+(\w+)\s*:\s*[\w[\]<>|\s]+?=/g, "const $1 =")
    .replace(/\blet\s+(\w+)\s*:\s*[\w[\]<>|\s]+?=/g, "let $1 =")
    .replace(/\s+as\s+[A-Za-z_$][\w$.]*(?:<[^<>]*>)?(?:\[\])*/g, "")
    .replace(/([\w$\])])!(?=\s*[.;,)\]}])/g, "$1");
  const names = Object.keys(scope);
  // eslint-disable-next-line no-new-func
  return new Function(...names, `return (${isAsync ? "async " : ""}function ${name}(${params}) ${body});`)(...names.map((k) => scope[k]));
}
const constFrom = (src, name) => {
  const m = new RegExp(`const ${name} = ("[^"]*");`).exec(src);
  assert.ok(m, `const ${name} not found`);
  return JSON.parse(m[1]);
};

// ── the worker's real gate, decoder and verifier ───────────────────────────
const B58_ALPHABET = constFrom(WORKER, "B58_ALPHABET");
const b58decode = lift(WORKER, "b58decode", "s", { B58_ALPHABET });
const isBase58Pubkey = lift(WORKER, "isBase58Pubkey", "s", { b58decode });
const DESK_OWNER_DEFAULT = constFrom(WORKER, "DESK_OWNER_DEFAULT");
const deskArmingAllowed = lift(WORKER, "deskArmingAllowed", "env, owner", { DESK_OWNER_DEFAULT });
const verifyEd25519 = lift(WORKER, "verifyEd25519", "pubkeyB58, sigB58, message", { b58decode, crypto: globalThis.crypto });
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

// ── the console's real message, wire form and signature handling ───────────
const C_ALPHA = constFrom(MINIAPP, "B58_ALPHABET");
const c_b58encode = lift(MINIAPP, "b58encode", "bytes", { B58_ALPHABET: C_ALPHA });
const c_b58decode = lift(MINIAPP, "b58decode", "s", { B58_ALPHABET: C_ALPHA });
const trendingMessage = lift(MINIAPP, "trendingMessage", "{ action, owner, mint, ts, nonce }");
const btoa = (s) => Buffer.from(s, "binary").toString("base64");
const atob = (s) => Buffer.from(s, "base64").toString("binary");
const toWireMessage = lift(MINIAPP, "toWireMessage", "text", { btoa });
const sigToBase58 = lift(MINIAPP, "sigToBase58", "raw", { b58encode: c_b58encode, b58decode: c_b58decode, atob });

/// The Farcaster host's signing transform (rule-signature.test.js, solved
/// 2026-08-07): keep url-safe base64 characters, truncate to whole groups,
/// decode, sign the RESULT, answer in standard base64.
function hostSigner(secretKey, seen) {
  return {
    async signMessage(s) {
      seen.push(s);
      let f = s.replace(/[^A-Za-z0-9\-_]/g, "").replace(/-/g, "+").replace(/_/g, "/");
      f = f.slice(0, f.length - (f.length % 4 || 0));
      const bytes = new Uint8Array(Buffer.from(f, "base64"));
      return { signature: Buffer.from(nacl.sign.detached(bytes, secretKey)).toString("base64") };
    },
  };
}

// ── fixtures ────────────────────────────────────────────────────────────────
const newKey = () => { const kp = nacl.sign.keyPair(); return { kp, pub: bs58.encode(kp.publicKey) }; };
const mintN = (n) => bs58.encode(Uint8Array.from({ length: 32 }, (_, i) => (i * 7 + n * 13 + 1) & 0xff));
const SPL = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", T22 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const DAY = 86400000, T0 = Date.parse("2026-10-15T00:00:00Z");
function row(n, over = {}) {
  return {
    id: mintN(n), symbol: `TK${n}`, name: `Token ${n}`, icon: `https://img.example/${n}.png`,
    tokenProgram: n % 2 ? SPL : T22, isVerified: true, tags: ["verified", "community"],
    usdPrice: 0.5 + n, mcap: 1_000_000 * (n + 1), liquidity: 100_000 + n, holderCount: 1000 + n,
    audit: { mintAuthorityDisabled: true, freezeAuthorityDisabled: true, topHoldersPercentage: 12.345 },
    organicScoreLabel: "high", stats24h: { priceChange: 4.26 }, firstPool: { createdAt: new Date(T0 - n * DAY).toISOString() },
    ...over,
  };
}

/// D1's surface over node:sqlite. D1 is SQLite; ?1, ?2 bind the same way.
function d1(db) {
  return {
    prepare(sql) {
      const st = {
        args: [], bind(...a) { st.args = a; return st; },
        async all() { return { results: db.prepare(sql).all(...st.args) }; },
        async first() { return db.prepare(sql).get(...st.args) ?? null; },
        async run() { const r = db.prepare(sql).run(...st.args); return { meta: { changes: Number(r.changes) } }; },
      };
      return st;
    },
  };
}
function freshDb() { const db = new DatabaseSync(":memory:"); db.exec(MIGRATION); return db; }
const opts = (now) => ({ json, isMint: isBase58Pubkey, verifyEd25519, deskArmingAllowed, now: () => now });
const post = (body) => new Request("https://possessio.io/api/desk/trending", { method: "POST", headers: { "content-type": "application/json" }, body: typeof body === "string" ? body : JSON.stringify(body) });
const get = () => new Request("https://possessio.io/api/desk/trending");
function signedBody({ kp, owner, action, mint, ts, nonce }) {
  const sig = nacl.sign.detached(trendingPreimage({ action, owner, mint, ts, nonce }), kp.secretKey);
  return { action, owner, mint, ts, nonce, signature: bs58.encode(sig) };
}
const count = (db, table) => Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);

// ════ A. THE VERIFIED FILTER ═══════════════════════════════════════════════
t("a verified Solana token with mint and freeze authority off is kept, every field mapped", () => {
  const out = filterVerified([row(1)], { isMint: isBase58Pubkey });
  assert.strictEqual(out.tokens.length, 1);
  assert.deepStrictEqual(out.tokens[0], {
    mint: mintN(1), symbol: "TK1", name: "Token 1", icon: "https://img.example/1.png", priceUsd: 1.5, mcapUsd: 2_000_000,
    liquidityUsd: 100_001, holders: 1001, top10Pct: 12.3, organic: "high", change24hPct: 4.3, firstPoolAt: T0 - DAY,
  });
});

t("each rule drops exactly the row it names, and unknown is never safe", () => {
  const cases = [
    ["not verified", { isVerified: false }],
    ["not verified", { isVerified: "true" }],
    ["not a Solana token", { tokenProgram: "11111111111111111111111111111111" }],
    ["not a Solana token", { tokenProgram: undefined }],
    ["not a Solana token", { id: "0x0000000000000000000000000000000000000001" }],
    ...[...EXCLUDED_TAGS].map((tag) => ["tokenized stock / RWA", { tags: ["verified", tag] }]),
    ["mint authority not off", { audit: { mintAuthorityDisabled: false, freezeAuthorityDisabled: true } }],
    ["mint authority not off", { audit: { freezeAuthorityDisabled: true } }],
    ["mint authority not off", { audit: undefined }],
    ["freeze authority not off", { audit: { mintAuthorityDisabled: true, freezeAuthorityDisabled: false } }],
    ["freeze authority not off", { audit: { mintAuthorityDisabled: true } }],
    ["liquidity below floor", { liquidity: 24_999 }],
    ["liquidity below floor", { liquidity: undefined }],
    ["liquidity below floor", { liquidity: "lots" }],
    ["no first-pool date", { firstPool: undefined }],
    ["no first-pool date", { firstPool: { createdAt: "soon" } }],
  ];
  for (const [why, over] of cases) {
    const out = filterVerified([row(1), row(2, over)], { isMint: isBase58Pubkey });
    assert.deepStrictEqual(out.tokens.map((x) => x.symbol), ["TK1"], `${why} ${JSON.stringify(over)}: kept ${out.tokens.map((x) => x.symbol)}`);
    assert.deepStrictEqual(out.dropped, { [why]: 1 }, `${JSON.stringify(over)} dropped as ${JSON.stringify(out.dropped)}, expected "${why}"`);
  }
});

t("newest first pool leads, and the limit applies after sorting", () => {
  const rows = [row(5), row(1), row(9), row(3)];   // row(n) is n days old
  const out = filterVerified(rows, { isMint: isBase58Pubkey, limit: 2 });
  assert.deepStrictEqual(out.tokens.map((x) => x.symbol), ["TK1", "TK3"]);
  assert.strictEqual(out.matched, 4);
});

t("an icon that is not https is dropped, never rendered", () => {
  const out = filterVerified([row(1, { icon: "javascript:alert(1)" }), row(2, { icon: "http://x/y.png" })], { isMint: isBase58Pubkey });
  assert.deepStrictEqual(out.tokens.map((x) => x.icon), [null, null]);
});

t("the liquidity floor is configurable", () => {
  const out = filterVerified([row(1, { liquidity: 500_000 }), row(2, { liquidity: 2_000_000 })], { isMint: isBase58Pubkey, minLiquidityUsd: 1_000_000 });
  assert.deepStrictEqual(out.tokens.map((x) => x.symbol), ["TK2"]);
});

t("garbage input never throws", () => {
  assert.deepStrictEqual(filterVerified(null).tokens, []);
  const out = filterVerified([null, 5, "x", {}, []], { isMint: isBase58Pubkey });
  assert.strictEqual(out.tokens.length, 0);
});

// ════ B. GET /api/desk/verified ═══════════════════════════════════════════
function fakeCache() {
  const store = new Map();
  return { store, async match(req) { const r = store.get(req.url); return r ? r.clone() : undefined; }, async put(req, res) { store.set(req.url, res); } };
}
function upstream(rows, status = 200) {
  const f = async (url) => { f.calls.push(url); return new Response(JSON.stringify(rows), { status }); };
  f.calls = [];
  return f;
}
const vReq = (method = "GET") => new Request("https://possessio.io/api/desk/verified", { method });

t("GET filters the list, caches it, and serves the next request from the cache", async () => {
  const cache = fakeCache(), up = upstream([row(1), row(2, { tags: ["stocks"] }), row(3)]);
  const a = await handleVerified(vReq(), {}, { json, isMint: isBase58Pubkey, cache, fetchImpl: up, now: () => T0 });
  assert.strictEqual(a.status, 200);
  const body = await a.json();
  assert.deepStrictEqual(body.tokens.map((x) => x.symbol), ["TK1", "TK3"]);
  assert.deepStrictEqual(body.dropped, { "tokenized stock / RWA": 1 });
  assert.strictEqual(body.filters.solanaOnly, true);
  assert.match(a.headers.get("cache-control"), /max-age=600/);
  const b = await handleVerified(vReq(), {}, { json, isMint: isBase58Pubkey, cache, fetchImpl: up, now: () => T0 });
  assert.deepStrictEqual((await b.json()).tokens.map((x) => x.symbol), ["TK1", "TK3"]);
  assert.strictEqual(up.calls.length, 1, `upstream fetched ${up.calls.length} times for two requests`);
  assert.strictEqual(up.calls[0], "https://lite-api.jup.ag/tokens/v2/tag?query=verified");
});

t("an upstream failure is a 502 and is never cached", async () => {
  const cache = fakeCache();
  const bad = await handleVerified(vReq(), {}, { json, isMint: isBase58Pubkey, cache, fetchImpl: upstream([], 503) });
  assert.strictEqual(bad.status, 502);
  assert.strictEqual((await bad.json()).error, "UPSTREAM");
  const boom = async () => { throw new Error("socket hang up"); };
  const bad2 = await handleVerified(vReq(), {}, { json, isMint: isBase58Pubkey, cache, fetchImpl: boom });
  assert.strictEqual(bad2.status, 502);
  assert.strictEqual(cache.store.size, 0, "a failure was cached");
  const good = await handleVerified(vReq(), {}, { json, isMint: isBase58Pubkey, cache, fetchImpl: upstream([row(1)]) });
  assert.strictEqual(good.status, 200);
  assert.strictEqual((await good.json()).tokens.length, 1);
});

t("only GET is served", async () => {
  const r = await handleVerified(vReq("POST"), {}, { json, isMint: isBase58Pubkey, cache: fakeCache(), fetchImpl: upstream([row(1)]) });
  assert.strictEqual(r.status, 405);
});

t("DESK_VERIFIED_MIN_LIQUIDITY_USD moves the floor and the cache key", async () => {
  const cache = fakeCache(), up = upstream([row(1, { liquidity: 50_000 }), row(2, { liquidity: 5_000_000 })]);
  const r = await handleVerified(vReq(), { DESK_VERIFIED_MIN_LIQUIDITY_USD: "1000000" }, { json, isMint: isBase58Pubkey, cache, fetchImpl: up });
  assert.deepStrictEqual((await r.json()).tokens.map((x) => x.symbol), ["TK2"]);
  assert.deepStrictEqual([...cache.store.keys()], ["https://possessio.io/__cache/desk-verified-v1?minliq=1000000"]);
});

// ════ C. THE TRENDING LIST: gate, signature, window, replay, cap ══════════
const ADMIN = newKey(), STRANGER = newKey();
const envFor = (db, allow = ADMIN.pub) => ({ COUNCIL_DB: d1(db), DESK_ALLOW_OWNERS: allow });
const NOW = T0 + 12 * 3600 * 1000;

t("the migration runs, twice, and an empty list reads as empty", async () => {
  const db = freshDb();
  db.exec(MIGRATION);   // CREATE ... IF NOT EXISTS: re-applying is harmless
  const r = await handleTrending(get(), envFor(db), opts(NOW));
  assert.deepStrictEqual(await r.json(), { trending: [] });
});

t("an allowlisted wallet adds a coin with a real signature, and the list shows it", async () => {
  const db = freshDb(), env = envFor(db);
  const r = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "n-1" })), env, opts(NOW));
  assert.strictEqual(r.status, 200, JSON.stringify(await r.clone().json()));
  assert.deepStrictEqual(await r.json(), { ok: true, added: 1 });
  const list = await (await handleTrending(get(), env, opts(NOW))).json();
  assert.deepStrictEqual(list, { trending: [{ mint: mintN(1), addedAt: NOW }] });
  assert.strictEqual(db.prepare("SELECT added_by FROM desk_trending").get().added_by, ADMIN.pub, "added_by must be the verified signer");
});

t("adding it again is a no-op, not a second row", async () => {
  const db = freshDb(), env = envFor(db);
  await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "a" })), env, opts(NOW));
  const r = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "b" })), env, opts(NOW));
  assert.deepStrictEqual(await r.json(), { ok: true, added: 0, note: "already trending" });
  assert.strictEqual(count(db, "desk_trending"), 1);
});

t("a wallet NOT on the allowlist is refused even with a valid signature, and nothing is written", async () => {
  const db = freshDb(), env = envFor(db);
  for (const action of ["add", "remove"]) {
    const r = await handleTrending(post(signedBody({ kp: STRANGER.kp, owner: STRANGER.pub, action, mint: mintN(1), ts: NOW, nonce: "s-" + action })), env, opts(NOW));
    assert.strictEqual(r.status, 403);
    assert.strictEqual((await r.json()).error, "DESK_PRIVATE_BETA");
  }
  assert.strictEqual(count(db, "desk_trending"), 0);
  assert.strictEqual(count(db, "desk_trending_nonces"), 0, "a refused request spent a nonce");
});

t("the allowlisted owner's address with someone else's signature is refused", async () => {
  const db = freshDb(), env = envFor(db);
  const forged = signedBody({ kp: STRANGER.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "f" });
  const r = await handleTrending(post(forged), env, opts(NOW));
  assert.strictEqual(r.status, 401);
  assert.strictEqual((await r.json()).error, "SIGNER_MISMATCH");
  assert.strictEqual(count(db, "desk_trending"), 0);
});

t("a signature covers its action, its coin, its time and its nonce: change any one and it fails", async () => {
  const db = freshDb(), env = envFor(db);
  const good = signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "x" });
  for (const [k, v] of [["action", "remove"], ["mint", mintN(2)], ["ts", NOW - 1], ["nonce", "y"]]) {
    const r = await handleTrending(post({ ...good, [k]: v }), env, opts(NOW));
    assert.strictEqual(r.status, 401, `changing ${k} still verified`);
  }
  assert.strictEqual(count(db, "desk_trending"), 0);
});

t("a signature older than 10 minutes, or from the future, is refused", async () => {
  const db = freshDb(), env = envFor(db);
  for (const ts of [NOW - TRENDING_SIG_WINDOW_MS - 1, NOW + TRENDING_SIG_WINDOW_MS + 1]) {
    const r = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "remove", mint: mintN(1), ts, nonce: "w" + ts })), env, opts(NOW));
    assert.strictEqual(r.status, 400);
    assert.strictEqual((await r.json()).error, "STALE_SIGNATURE");
  }
  const edge = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW - TRENDING_SIG_WINDOW_MS, nonce: "edge" })), env, opts(NOW));
  assert.strictEqual(edge.status, 200, "a signature exactly at the window edge must still verify");
});

t("a replayed signature is refused inside the window, so a captured delete cannot pull a re-added coin", async () => {
  const db = freshDb(), env = envFor(db);
  const add1 = signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "r1" });
  const del = signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "remove", mint: mintN(1), ts: NOW + 1000, nonce: "r2" });
  const add2 = signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW + 2000, nonce: "r3" });
  for (const b of [add1, del, add2]) assert.strictEqual((await handleTrending(post(b), env, opts(NOW + 3000))).status, 200);
  const replay = await handleTrending(post(del), env, opts(NOW + 4000));
  assert.strictEqual(replay.status, 409);
  assert.strictEqual((await replay.json()).error, "NONCE_ALREADY_USED");
  assert.strictEqual(count(db, "desk_trending"), 1, "the replayed delete pulled the coin");
});

t("delete takes it off the list; deleting what is not there removes nothing", async () => {
  const db = freshDb(), env = envFor(db);
  await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "d1" })), env, opts(NOW));
  const r = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "remove", mint: mintN(1), ts: NOW, nonce: "d2" })), env, opts(NOW));
  assert.deepStrictEqual(await r.json(), { ok: true, removed: 1 });
  assert.deepStrictEqual(await (await handleTrending(get(), env, opts(NOW))).json(), { trending: [] });
  const again = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "remove", mint: mintN(1), ts: NOW, nonce: "d3" })), env, opts(NOW));
  assert.deepStrictEqual(await again.json(), { ok: true, removed: 0 });
});

t(`the list holds at most ${TRENDING_MAX}, newest first`, async () => {
  const db = freshDb(), env = envFor(db);
  for (let i = 0; i < TRENDING_MAX; i++) {
    const r = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(100 + i), ts: NOW, nonce: "c" + i })), env, opts(NOW + i));
    assert.strictEqual(r.status, 200);
  }
  const full = await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(999), ts: NOW, nonce: "c-full" })), env, opts(NOW + 99));
  assert.strictEqual(full.status, 409);
  assert.strictEqual((await full.json()).error, "TRENDING_FULL");
  const list = (await (await handleTrending(get(), env, opts(NOW))).json()).trending;
  assert.strictEqual(list.length, TRENDING_MAX);
  assert.strictEqual(list[0].mint, mintN(100 + TRENDING_MAX - 1), "newest must lead");
});

t("malformed requests are refused before anything is written", async () => {
  const db = freshDb(), env = envFor(db);
  const good = signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "m" });
  const cases = [
    ["{not json", "BAD_JSON"],
    [{ ...good, action: "nuke" }, "BAD_ACTION"],
    [{ ...good, owner: "not-a-key" }, "BAD_OWNER"],
    [{ ...good, mint: "0x4200000000000000000000000000000000000006" }, "BAD_MINT"],
    [{ ...good, ts: "now" }, "BAD_TS"],
    [{ ...good, ts: 1.5 }, "BAD_TS"],
    [{ ...good, nonce: "" }, "BAD_NONCE"],
    [{ ...good, nonce: "n".repeat(65) }, "BAD_NONCE"],
    [{ ...good, signature: 42 }, "BAD_SIGNATURE"],
    [{ ...good, signature: "0OIl" }, "BAD_SIGNATURE"],
  ];
  for (const [body, code] of cases) {
    const r = await handleTrending(post(body), env, opts(NOW));
    assert.strictEqual(r.status, 400, `${code}: status ${r.status}`);
    assert.strictEqual((await r.json()).error, code);
  }
  assert.strictEqual(count(db, "desk_trending") + count(db, "desk_trending_nonces"), 0);
});

t("spent nonces older than twice the window are pruned on the next write", async () => {
  const db = freshDb(), env = envFor(db);
  await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "add", mint: mintN(1), ts: NOW, nonce: "old" })), env, opts(NOW));
  const later = NOW + 2 * TRENDING_SIG_WINDOW_MS + 1;
  await handleTrending(post(signedBody({ kp: ADMIN.kp, owner: ADMIN.pub, action: "remove", mint: mintN(1), ts: later, nonce: "new" })), env, opts(later));
  assert.deepStrictEqual(db.prepare("SELECT nonce FROM desk_trending_nonces").all().map((r) => r.nonce), ["new"]);
});

t("the gate is the arming gate: the baked-in owner is on it, DESK_ALLOW_OWNERS extends it, '*' opens it", () => {
  assert.strictEqual(deskArmingAllowed({}, DESK_OWNER_DEFAULT), true);
  assert.strictEqual(deskArmingAllowed({}, ADMIN.pub), false);
  assert.strictEqual(deskArmingAllowed({ DESK_ALLOW_OWNERS: `x, ${ADMIN.pub}` }, ADMIN.pub), true);
  assert.strictEqual(deskArmingAllowed({ DESK_ALLOW_OWNERS: "*" }, STRANGER.pub), true);
  const consoleList = /window\.POSSESSIO_DESK_ALLOW = \[([^\]]*)\]/.exec(HTML);
  assert.ok(consoleList && consoleList[1].includes(JSON.stringify(DESK_OWNER_DEFAULT)), "the console's allowlist no longer names the worker's baked-in owner");
});

t("no database is a 503; other methods are a 405", async () => {
  assert.strictEqual((await handleTrending(get(), {}, opts(NOW))).status, 503);
  const put = new Request("https://possessio.io/api/desk/trending", { method: "PUT", body: "{}" });
  assert.strictEqual((await handleTrending(put, envFor(freshDb()), opts(NOW))).status, 405);
});

// ════ D. THE SIGNATURE CONTRACT, console <-> worker ══════════════════════
const MSG = { action: "add", owner: "ARjf4vUNiU8cW6xXfBfiL8ibc5qC4pYim5mLxbe6uog5", mint: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263", ts: 1760486400000, nonce: "1760486400000-k3x9q2ab" };

t("the console and the worker build the SAME bytes", () => {
  for (const m of [MSG, { ...MSG, action: "remove" }, { ...MSG, nonce: MSG.nonce + "00" }]) {
    const a = Buffer.from(trendingPreimage(m)).toString("hex");
    const b = Buffer.from(new TextEncoder().encode(trendingMessage(m))).toString("hex");
    assert.strictEqual(b, a, `preimages differ for ${JSON.stringify(m)}`);
  }
});

t("the message is domain-separated, version-tagged, and covers every field", () => {
  const base = Buffer.from(trendingPreimage(MSG)).toString();
  assert.ok(base.startsWith("possessio.desk.trending.v1\n"));
  for (const [k, v] of Object.entries({ action: "remove", owner: "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", mint: "So11111111111111111111111111111111111111112", ts: 1, nonce: "z" })) {
    assert.notStrictEqual(Buffer.from(trendingPreimage({ ...MSG, [k]: v })).toString(), base, `changing ${k} did not change the signed bytes`);
  }
});

/// The SHIPPED trendingAction, end to end: it builds the message, pads it,
/// hands the host its wire form, converts the host's base64 answer, and POSTs.
/// The POST lands in the real handler with the real gate and verifier.
/// Math.random is pinned so the nonce's random part is 1, 2 or 8 characters
/// long: across those, an unpadded text always lands on at least two different
/// lengths mod 3, so a missing pad fails deterministically, never by luck.
function shippedTrendingAction(key, env, now, seen, random = 0.5) {
  let clock = now;   // the console's clock moves on, so two calls never share a nonce
  const fetchToWorker = async (url, init) => {
    assert.strictEqual(url, "/api/desk/trending");
    return handleTrending(new Request("https://possessio.io" + url, init), env, opts(now));
  };
  return lift(MINIAPP, "trendingAction", "{ action, mint }", {
    provider: hostSigner(key.kp.secretKey, seen), pubkey: { toBase58: () => key.pub },
    trendingMessage, toWireMessage, sigToBase58, fetch: fetchToWorker, window: {}, Date: { now: () => clock++ },
    Math: Object.assign(Object.create(Math), { random: () => random }),
  });
}

t("END TO END: the console's own trendingAction adds and deletes through a base64 host and the real worker", async () => {
  const db = freshDb(), env = envFor(db), seen = [];
  for (const [i, random] of [0.5, 0.125, 0.123456789].entries()) {
    const act = shippedTrendingAction(ADMIN, env, NOW + i, seen, random);
    assert.deepStrictEqual(await act({ action: "add", mint: mintN(7) }), { ok: true, added: 1 }, `add (random ${random})`);
    assert.deepStrictEqual((await (await handleTrending(get(), env, opts(NOW))).json()).trending.map((x) => x.mint), [mintN(7)]);
    assert.deepStrictEqual(await act({ action: "remove", mint: mintN(7) }), { ok: true, removed: 1 }, `remove (random ${random})`);
    assert.strictEqual(count(db, "desk_trending"), 0);
  }
  assert.strictEqual(seen.length, 6);
  for (const s of seen) {
    assert.match(s, /^[A-Za-z0-9_-]+$/, "the wire form left the url-safe base64 alphabet");
    assert.strictEqual(s.length % 4, 0, "the text was not padded to a multiple of 3 bytes, so the host's decode truncates it");
  }
});

t("END TO END: the console's trendingAction from a wallet off the allowlist is refused by the worker", async () => {
  const db = freshDb();
  const act = shippedTrendingAction(STRANGER, envFor(db), NOW, []);
  await assert.rejects(act({ action: "add", mint: mintN(7) }), /DESK_PRIVATE_BETA/);
  assert.strictEqual(count(db, "desk_trending"), 0);
});

// ════ E. WIRING ═══════════════════════════════════════════════════════════
t("the worker routes both paths to these handlers, with the arming allowlist and the Ed25519 verifier", () => {
  assert.match(WORKER, /import \{ handleVerified as deskVerified, handleTrending as deskTrending \} from "\.\/desk-feed\.mjs";/);
  assert.match(WORKER, /if \(pathname === "\/api\/desk\/verified"\) \{\s*return deskVerified\(request, env, \{ json, isMint: isBase58Pubkey \}\);/);
  assert.match(WORKER, /if \(pathname === "\/api\/desk\/trending"\) \{\s*return deskTrending\(request, env, \{ json, isMint: isBase58Pubkey, verifyEd25519, deskArmingAllowed \}\);/);
});

t("the console gives the desk trendingAction, and its admin buttons use the arming gate", () => {
  assert.match(HTML, /trendingAction: M\.trendingAction/);
  assert.match(HTML, /function canCurate\(\)\{ var M=window\.PossessioMiniApp; return !!\(M&&M\.ready&&M\.address&&M\.trendingAction&&deskArmingOpen\(M\.address\)\); \}/);
  assert.match(HTML, /function curateHTML\(c\)\{\s*if\(c\.ch!=="sol"\|\|!c\.addr\|\|!canCurate\(\)\)return "";/);
  assert.match(HTML, /if\(!canCurate\(\)\)\{/, "trendAct must re-check the gate before asking for a signature");
});

t("every inline script in index.html parses", () => {
  const re = /<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi;
  let m, n = 0;
  while ((m = re.exec(HTML))) {
    const attrs = m[1] || "";
    if (/\ssrc=/.test(attrs) || /type=["']?(application\/(ld\+)?json|importmap)/i.test(attrs)) continue;
    n++;
    const line = HTML.slice(0, m.index).split("\n").length;
    if (/type=["']?module/.test(attrs)) {
      const f = path.join(os.tmpdir(), `desk-inline-${process.pid}-${n}.mjs`);
      fs.writeFileSync(f, m[2]);
      try { execFileSync(process.execPath, ["--check", f], { stdio: "pipe" }); }
      catch (e) { assert.fail(`module script at line ${line}: ${String(e.stderr).split("\n").slice(0, 5).join(" | ")}`); }
      finally { fs.rmSync(f, { force: true }); }
    } else {
      try { new vm.Script(m[2]); } catch (e) { assert.fail(`script at line ${line}: ${e.message}`); }
    }
  }
  assert.ok(n >= 10, `only ${n} inline scripts found`);
});

console.log("The desk's two lists: verified feed + trending list\n");
for (const [name, fn] of tests) {
  try { await fn(); console.log(`  PASS  ${name}`); pass++; }
  catch (e) { console.log(`  FAIL  ${name}\n        ${String(e.message).split("\n").join("\n        ")}`); fail++; }
}
console.log(`\nRESULT: ${pass}/${pass + fail} PASS`);
process.exit(fail ? 1 : 0);
