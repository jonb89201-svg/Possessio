// possessio tape — the PumpPortal subscriber, on a host that can hold a socket.
//
// Moved off the Cloudflare Durable Object per board row 90: Workers are
// request-scoped and hostile to long-lived WebSockets (pumptapeTrades sat in
// socket_down for days); the Railway host proven by the keeper's K2 soak is
// the natural home for the one subscriber. The state machine lives in
// ./engine.js, pure and tested; this file is only the host: socket, watchdog,
// solUsd, and delivery to the radar's ingest route.
//
// §4 COMPLIANCE unchanged: no keys beyond the optional PumpPortal data key,
// no orders, nothing signed. This observes and reports rows.
//
// ENV (all optional except where noted):
//   PUMPPORTAL_WS_URL    default wss://pumpportal.fun/api/data
//   PUMPPORTAL_API_KEY   optional — lets per-coin trade subs be armed (see
//                        ACTIVE_MINTS below). Births are free and keyless
//                        regardless of this key. NEVER logged.
//   ACTIVE_MINTS         optional, comma-separated mint allowlist. COST GUARD
//                        (2026-08-14, Tare §8 / Architect: "we can't afford
//                        $300/day, pure and simple"). subscribeTokenTrade is
//                        METERED (0.01 SOL / 10,000 events) and this file used
//                        to arm it for EVERY birth unconditionally — measured
//                        ~$10/hr against a $230/MONTH total infra budget, and
//                        the $5 test spend was never even ingested (401, see
//                        board). Nothing in production reads this trade-level
//                        data today: the keeper prices positions live via a
//                        Jupiter quote (keeper/index.js), and the radar's own
//                        candidate/mc_ticks grading runs on free DexScreener +
//                        pump.fun curve reads (screen.ts). So the safe default
//                        is OFF — leave ACTIVE_MINTS unset and this process
//                        never sends a single metered subscribeTokenTrade,
//                        even with PUMPPORTAL_API_KEY funded. Set it to a
//                        short list (open positions only, per Tare's
//                        recommendation) if trade-level tracking is ever
//                        actually needed again.
//   PUMPFUN_FEED_URL     default frontend-api-v3 /coins (solUsd ratio source)
//   INGEST_URL           default https://possessio-radar.jonb89201.workers.dev/radar/tape-ingest
//   TAPE_INGEST_TOKEN    bearer for the ingest route. UNSET => DRY TAPE:
//                        observe + log, post nothing. Set it on Railway AND as
//                        a radar Worker secret (same value, Architect-held).
"use strict";

const { TapeEngine } = require("./engine");

const WS_URL = process.env.PUMPPORTAL_WS_URL || "wss://pumpportal.fun/api/data";
const API_KEY = process.env.PUMPPORTAL_API_KEY || ""; // scrub-allow:named-secret-assignment — an env read by NAME; the value never touches the repo
const ACTIVE_MINTS = new Set(
  (process.env.ACTIVE_MINTS || "").split(",").map((s) => s.trim()).filter(Boolean)
);
const tradesArmed = () => !!API_KEY && ACTIVE_MINTS.size > 0;
const FEED_URL = process.env.PUMPFUN_FEED_URL ||
  "https://frontend-api-v3.pump.fun/coins?offset=0&limit=50&sort=created_timestamp&order=DESC&includeNsfw=true";
const INGEST_URL = process.env.INGEST_URL ||
  "https://possessio-radar.jonb89201.workers.dev/radar/tape-ingest";
const TOKEN = process.env.TAPE_INGEST_TOKEN || "";

const WATCHDOG_MS = 30000;      // reconnect check + sweep cadence (DO alarm parity)
const STALE_SOCKET_MS = 90000;  // no message this long -> recycle the socket
const SOLUSD_EVERY_MS = 60000;  // ratio re-read cadence (screenScan parity)
const FLUSH_MS = 2000;          // ingest batch cadence
const FLUSH_AT = 50;            // ...or when this many effects queue up
const BUFFER_CAP = 5000;        // ingest-down backstop; overflow drops OLDEST, counted

if (typeof WebSocket === "undefined") {
  console.error("FATAL: no global WebSocket (Node >= 21 required). Refusing a silent no-op start.");
  process.exit(1);
}

const engine = new TapeEngine();
let ws = null;
let lastMsgMs = 0;
let connects = 0;
let connected = false;
const pending = [];
const stats = { posted: 0, postErrors: 0, dropped: 0, lastPostOkMs: 0, lastPostErr: "" };

console.log([
  "possessio tape — PumpPortal subscriber (host: this process, engine: tape/engine.js)",
  `  mode:      ${TOKEN ? "LIVE-INGEST (posts to the radar)" : "DRY TAPE (no token — observe + log only)"}`,
  `  ws:        ${WS_URL}`,
  `  trades:    ${tradesArmed() ? `KEYED — trade subs armed for ${ACTIVE_MINTS.size} mint(s)`
    : API_KEY ? "KEYED but ACTIVE_MINTS is empty — trade subs OFF by cost policy (births only)"
    : "keyless — births only (subscribeTokenTrade needs a funded key)"}`,
  `  ingest:    ${INGEST_URL}`,
  `  solUsd:    ratio read from pump.fun feed every ${SOLUSD_EVERY_MS / 1000}s`,
].join("\n"));

function connect() {
  let url = WS_URL;
  if (API_KEY) url += (url.includes("?") ? "&" : "?") + "api-key=" + API_KEY;
  try {
    ws = new WebSocket(url);
  } catch (e) {
    console.error("tape connect threw:", e && e.message);
    ws = null;
    return;
  }
  ws.addEventListener("open", () => {
    connected = true;
    connects++;
    lastMsgMs = Date.now();
    console.log(`tape: socket open (connect #${connects})`);
    // subscribeNewToken is FREE and keyless; it carries the dev buy on every
    // create event. Trade subs are per-coin, sent on each birth when keyed.
    ws.send(JSON.stringify({ method: "subscribeNewToken" }));
    // Migrations: the DEX-pair birth, the feed's "just listed" trigger.
    // Harmless if the upstream refuses it keyless — the discovery scan
    // remains the per-minute fallback stamp either way.
    ws.send(JSON.stringify({ method: "subscribeMigration" }));
  });
  ws.addEventListener("message", (ev) => {
    lastMsgMs = Date.now();
    const out = engine.onMessage(typeof ev.data === "string" ? ev.data : "", lastMsgMs);
    queue(out);
  });
  ws.addEventListener("close", () => { connected = false; ws = null; });
  ws.addEventListener("error", (e) => {
    connected = false;
    console.error("tape socket error:", (e && e.message) || "unknown");
  });
}

function queue(out) {
  for (const eff of out.effects) {
    if (pending.length >= BUFFER_CAP) { pending.shift(); stats.dropped++; } // loud, never silent
    pending.push(eff);
  }
  // per-coin trade subs — METERED (see ACTIVE_MINTS note above). The engine
  // suggests a subscribe on every birth; the host (here) is what decides
  // whether that suggestion actually costs money, by intersecting it against
  // the allowlist. Empty allowlist -> this filters to nothing -> zero spend.
  if (ws && connected && tradesArmed()) {
    const sub = out.subscribe.filter((m) => ACTIVE_MINTS.has(m));
    const unsub = out.unsubscribe.filter((m) => ACTIVE_MINTS.has(m));
    if (sub.length) ws.send(JSON.stringify({ method: "subscribeTokenTrade", keys: sub }));
    if (unsub.length) ws.send(JSON.stringify({ method: "unsubscribeTokenTrade", keys: unsub }));
  }
}

// SOL/USD exactly as screenScan derives it (radar/screen.ts): any coin's
// usd_market_cap / market_cap ratio cancels the curve term and leaves pure SOL
// price; sanity band (1, 100000). Never guessed — no ratio, no pricing.
async function pollSolUsd() {
  try {
    const r = await fetch(FEED_URL, { signal: AbortSignal.timeout(10000) });
    if (!r.ok) return;
    const items = await r.json();
    if (!Array.isArray(items)) return;
    for (const it of items) {
      const mcUsd = Number(it.usd_market_cap ?? it.marketCapUsd);
      const mcSol = Number(it.market_cap);
      if (Number.isFinite(mcUsd) && Number.isFinite(mcSol) && mcSol > 0) {
        const p = mcUsd / mcSol;
        if (p > 1 && p < 100000) { engine.setSolUsd(p); return; }
      }
    }
  } catch (e) {
    console.error("tape solUsd read failed:", e && e.message);
  }
}

async function flush() {
  if (!pending.length && !TOKEN) return;      // dry tape with nothing to say
  const health = engine.health(Date.now(), connected, tradesArmed());
  if (!TOKEN) { pending.length = 0; return; } // dry tape: effects observed, not posted
  // Heartbeat even with zero effects, but at watchdog cadence not flush
  // cadence — handled by the caller passing force=true from the watchdog.
  if (!pending.length && !flush.force) return;
  flush.force = false;
  const batch = pending.splice(0, 500);
  try {
    const r = await fetch(INGEST_URL, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + TOKEN },
      body: JSON.stringify({ v: 1, health, stats: { ...engine.stats, ...stats }, effects: batch }),
      signal: AbortSignal.timeout(10000),
    });
    if (!r.ok) throw new Error("ingest " + r.status);
    stats.posted += batch.length;
    stats.lastPostOkMs = Date.now();
  } catch (e) {
    stats.postErrors++;
    stats.lastPostErr = String((e && e.message) || e).slice(0, 200);
    // put the batch back at the front; the cap + dropped counter bound memory
    pending.unshift(...batch);
    if (pending.length > BUFFER_CAP) { stats.dropped += pending.length - BUFFER_CAP; pending.length = BUFFER_CAP; }
  }
}

// Layer 2, the watchdog: reconnect dead/stale sockets, sweep bells/windows,
// force a heartbeat post so the radar's feed_status row stays honest even in
// a quiet market.
function watchdog() {
  const now = Date.now();
  if (ws && now - lastMsgMs > STALE_SOCKET_MS) {
    console.error(`tape: socket stale (${Math.round((now - lastMsgMs) / 1000)}s silent) — recycling`);
    try { ws.close(); } catch {}
    ws = null;
    connected = false;
  }
  if (!ws) connect();
  queue(engine.sweep(now));
  flush.force = true;
}

// One status line a minute — greppable, key-free, the whole state.
function statusLine() {
  const h = engine.health(Date.now(), connected, tradesArmed());
  const s = engine.stats;
  console.log(
    `tape status=${h.status} tracked=${h.tracked} births=${s.births} trades=${s.trades} ` +
    `hits=${s.hits} targets=${s.targets} exits=${s.exits} gaps=${s.gaps} noPrice=${s.noPrice} ` +
    `solUsd=${engine.solUsd.toFixed(2)} pending=${pending.length} posted=${stats.posted} ` +
    `postErrs=${stats.postErrors} dropped=${stats.dropped}` +
    (stats.lastPostErr ? ` lastPostErr="${stats.lastPostErr}"` : ""),
  );
}

connect();
pollSolUsd();
setInterval(watchdog, WATCHDOG_MS);
setInterval(pollSolUsd, SOLUSD_EVERY_MS);
setInterval(flush, FLUSH_MS);
setInterval(statusLine, 60000);
