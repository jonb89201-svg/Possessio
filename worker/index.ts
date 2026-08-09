// possessio Worker entry - routes /api/* to handlers, everything else falls
// through to the static console assets (./public via the ASSETS binding).
// Assets-first routing is Cloudflare's default for Workers+Assets, so every
// existing console path serves exactly as it did when this worker was
// assets-only; the script only ever sees requests no asset matches.
import { handleDrip } from "./drip-endpoint";
import { recoverTypedDataAddress, getAddress, isAddress } from "viem";

interface Env {
  ASSETS: Fetcher;
  DRIP_LIMITS: KVNamespace;
  POOL_ADDRESS: `0x${string}`;
  USDC_ADDRESS: `0x${string}`;
  BASE_SEPOLIA_RPC: string;
  TESTNET_OPERATOR_PK: `0x${string}`;
  COUNCIL_DB: D1Database;      // the council communication ledger (radar DB)
  COUNCIL_SEATS?: string;      // optional comma-separated seat allowlist
  COUNCIL_MCP_TOKEN?: string;  // optional bearer that gates /mcp (secret). Data is public; token is access control.
  COUNCIL_HOOK_ADDRESS?: string; // optional, for council_status readout
  COUNCIL_CHAIN_ID?: string;   // optional, defaults 8453
}

const ZERO = "0x0000000000000000000000000000000000000000";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

/* ─────────── Solana primitives, for the desk rule ledger ─────────── */

const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58 decode. Solana pubkeys and signatures are base58 and the Workers
/// runtime has no decoder, so it is written out rather than pulling a package
/// into the edge bundle for thirty lines of work.
function b58decode(s: string): Uint8Array<ArrayBuffer> {
  if (!s.length) throw new Error("empty");
  // NOT seeded with [0]: a zero seed survives as a spurious extra byte whenever
  // the decoded value is itself zero, so "1" would decode to two bytes instead
  // of one and a leading-zero pubkey would fail its length check.
  const bytes: number[] = [];
  for (const ch of s) {
    const v = B58_ALPHABET.indexOf(ch);
    if (v < 0) throw new Error("bad base58 char");
    let carry = v;
    for (let i = 0; i < bytes.length; i++) {
      carry += bytes[i] * 58;
      bytes[i] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) { bytes.push(carry & 0xff); carry >>= 8; }
  }
  // Leading '1's are leading zero bytes.
  for (let k = 0; k < s.length && s[k] === "1"; k++) bytes.push(0);
  return new Uint8Array(bytes.reverse());
}

/// A Solana pubkey is exactly 32 bytes. Checked before it reaches the DB so a
/// long or malformed string can never become a row.
function isBase58Pubkey(s: string): boolean {
  if (typeof s !== "string" || s.length < 32 || s.length > 44) return false;
  try { return b58decode(s).length === 32; } catch { return false; }
}

/// THE DESK ALLOWLIST (2026-08-10). The console is public and tagged @base, so
/// strangers will find it — and /api/desk/rules writes to the SHARED radar D1
/// while the keeper is still one process serving every armed position (board
/// row 86's load-bearing finding: a compromise is theft across ALL of them).
/// So arming is a private beta gated by OWNER, and the gate lives HERE, not on
/// a button a stranger can bypass with curl.
///
/// The owner is Ed25519-verified below, so this cannot be spoofed: a caller
/// who is not the allowlisted owner cannot produce the allowlisted owner's
/// signature. Baked default is the Architect's own wallet; DESK_ALLOW_OWNERS
/// (comma-separated) extends it, and the literal "*" opens arming to everyone
/// once the per-user keeper lands.
const DESK_OWNER_DEFAULT = "vzQhfuJLKkj14yP8x3uP2J4XQSDWUVTE1CUbNsXygVK";
function deskArmingAllowed(env: any, owner: string): boolean {
  const raw = (env.DESK_ALLOW_OWNERS ?? "").trim();
  if (raw === "*") return true;
  const set = new Set([DESK_OWNER_DEFAULT]);
  for (const a of raw.split(/[,\s]+/)) if (a) set.add(a);
  return set.has(owner);
}

/// The exact bytes the wallet signs. Field order is fixed and every value is
/// stringified explicitly: the signature must cover the WHOLE instruction, so
/// that nothing between the wallet and the table can alter a target and still
/// present a valid signature. Any change here is a breaking protocol change —
/// the console builds the identical string in miniapp-solana.js.
function deskRulePreimage(r: {
  owner: string; mint: string; decimals: number;
  entryPrice: number; targetBps: number;
  hasStop: boolean; stopBps?: number | null; nonce: string;
}): Uint8Array<ArrayBuffer> {
  // MUST stay byte-identical to rulePreimage in public/miniapp-solana.js.
  // See the comment there for why the stop is stated positively rather than
  // inferred from a missing field; keeper/test/rule-signature.test.js lifts
  // BOTH of these functions from their real source and compares the bytes.
  const stopLines = r.hasStop === true
    ? `hasStop:true\nstopBps:${r.stopBps}\n`
    : `hasStop:false\n`;
  const msg =
    "possessio.desk.rule.v1\n" +
    `owner:${r.owner}\n` +
    `mint:${r.mint}\n` +
    `decimals:${r.decimals}\n` +
    `entryPrice:${r.entryPrice}\n` +
    `targetBps:${r.targetBps}\n` +
    stopLines +
    `nonce:${r.nonce}`;
  return new TextEncoder().encode(msg) as Uint8Array<ArrayBuffer>;
}

function deskCancelPreimage(r: { owner: string; mint: string; ruleId: string; nonce: string }): Uint8Array<ArrayBuffer> {
  // MUST stay byte-identical to cancelMessage in public/miniapp-solana.js —
  // keeper/test/rule-signature.test.js lifts both sources and compares bytes.
  //
  // Scoped to the RULE ID on purpose: a replayed cancel can only re-cancel the
  // row it already cancelled; a fresh rule on the same coin has a fresh id the
  // old signature never covered. That id-scoping IS the replay guard, so no
  // server-side nonce ledger is needed.
  const msg =
    "possessio.desk.cancel.v1\n" +
    `owner:${r.owner}\n` +
    `mint:${r.mint}\n` +
    `ruleId:${r.ruleId}\n` +
    `nonce:${r.nonce}`;
  return new TextEncoder().encode(msg) as Uint8Array<ArrayBuffer>;
}

/// Verify an Ed25519 signature against a Solana pubkey using WebCrypto, which
/// the Workers runtime supports natively — no dependency, and the verification
/// runs in the runtime rather than in JS we would have to audit ourselves.
async function verifyEd25519(pubkeyB58: string, sigB58: string, message: Uint8Array<ArrayBuffer>): Promise<boolean> {
  const pub = b58decode(pubkeyB58);
  const sig = b58decode(sigB58);
  if (pub.length !== 32 || sig.length !== 64) return false;
  const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
  return crypto.subtle.verify({ name: "Ed25519" }, key, sig, message);
}

// Off-chain statement attribution — MUST match the connector's STATEMENT_DOMAIN
// (config.js). Deliberately has no verifyingContract so a statement signature can
// never be replayed as an on-chain vote.
// Council-ledger write bounds (N-1 residual, audit 2026-07-24). Every field a
// seat can set is capped, and each seat is rate-limited, so the worst a
// COMPROMISED seat key can do to the shared radar D1 is bounded per minute
// instead of unbounded. `body` is capped inline at 8000.
const KIND_MAX_CHARS = 32;      // "statement" | "proposal" | "note" + headroom
const REF_MAX_CHARS = 256;      // a proposalHash is 66 chars
const SEAT_RATE_WINDOW_MS = 60_000;
const SEAT_RATE_MAX_POSTS = 20; // per seat per window; far above honest use

// Health verdict cache (N-4, audit 2026-07-23). /api/radar/health is
// unauthenticated and runs a 6-subquery D1 read plus — when births are flat — a
// POST to the PUBLIC Solana RPC. Uncached, every open MIB panel (and anyone
// looping it) hammered that RPC at request rate, which gets our egress IP
// rate-limited and degrades the very diagnosis the endpoint exists to give:
// it failed hardest exactly when the thing it monitors was broken. A verdict is
// only meaningful at ~cron granularity anyway, so a few seconds of staleness
// costs nothing. Isolate-local (Workers gives no shared cache here), so this
// bounds per-isolate amplification, not global — still a large cut, and honest
// about what it is. Cached responses are MARKED: a health endpoint that quietly
// served stale state would be lying in exactly the way it exists to prevent.
const HEALTH_CACHE_MS = 15_000;
let healthCache: { at: number; payload: Record<string, unknown> } | null = null;

// Shared by the /api/radar/health route and the connector's radar_health tool
// (increment 4): one computation, two callers, so the console and the council
// can never disagree about the feed's health. Returns the payload; callers wrap.
async function computeRadarHealth(db: D1Database): Promise<Record<string, unknown>> {

  // N-4: serve a recent verdict rather than re-running the D1 sweep + the
  // public-RPC probe on every poll. Marked cached + aged so the reader knows.
  if (healthCache && Date.now() - healthCache.at < HEALTH_CACHE_MS) {
    return { ...healthCache.payload, cached: true, cache_age_ms: Date.now() - healthCache.at };
  }

  let row: any;
  let db_mb: number | null = null;
  try {
    // .all() (not .first()) so we also get meta.size_after — D1 hands back the
    // DB file size for free, and pragma_page_count is blocked (SQLITE_AUTH).
    const res: any = await db.prepare(
      "SELECT " +
      "(strftime('%s','now')*1000 - (SELECT MAX(pumpfun_first_seen_ms) FROM births)) AS births_age_ms, " +
      "(SELECT COUNT(*) FROM births WHERE pumpfun_first_seen_ms > strftime('%s','now')*1000-300000) AS births_5min, " +
      "(SELECT COUNT(*) FROM births WHERE pumpfun_first_seen_ms > strftime('%s','now')*1000-3600000) AS births_1h, " +
      "(strftime('%s','now')*1000 - (SELECT MAX(ms) FROM mc_ticks)) AS tape_age_ms, " +
      "(strftime('%s','now')*1000 - (SELECT MAX(ts_ms) FROM regime_ticks)) AS btc_age_ms, " +
      "(SELECT btc_usd FROM regime_ticks ORDER BY ts_ms DESC LIMIT 1) AS btc_usd"
    ).all();
    row = res?.results?.[0] || {};
    const bytes = res?.meta?.size_after;
    if (bytes) db_mb = Math.round((Number(bytes) / 1048576) * 10) / 10;
  } catch (e: any) {
    return { status: "unknown", diagnosis: "Radar DB query failed: " + (e?.message || e), action: "Check the COUNCIL_DB binding / radar DB." };
  }

  const num = (x: any) => (x == null ? null : Number(x));
  const births_age_ms = num(row?.births_age_ms);
  const births_5min = num(row?.births_5min) ?? 0;
  const births_1h = num(row?.births_1h) ?? 0;
  const tape_age_ms = num(row?.tape_age_ms);
  const btc_age_ms = num(row?.btc_age_ms);
  const btc_usd = num(row?.btc_usd);

  const BTC_STALE = 120000, TAPE_STALL = 600000;
  const btcFresh = btc_age_ms != null && btc_age_ms <= BTC_STALE;
  const birthsFlat = births_5min === 0;
  const tapeFrozen = tape_age_ms == null || tape_age_ms > TAPE_STALL;

  // Which scan is actually failing — feed_status is written by the radar cron
  // (radar/index.ts `tracked`), turning "births frozen" into the CAUSE:
  // "birthScan failing: <error>". A scan is failing now iff its last error is
  // newer than its last success. Best-effort — a missing table (pre radar
  // deploy) or read error never blocks the verdict.
  const scans: Record<string, { ok_age_ms: number | null; err_age_ms: number | null; err: string | null; failing: boolean }> = {};
  const failing: string[] = [];
  // FALSE-GREEN FIX (2026-08-12, RESEARCH_RadarMethod §5): a scan that goes
  // SILENT records no error — last_err stays old, last_ok just ages — so the
  // err-newer-than-ok test alone can never see it. The per-trade tape died
  // exactly this way (PumpPortal key drained; the socket stays up, the
  // key-gated stream dies quietly) and sat under "healthy" for ~50h while
  // births and mc_ticks kept flowing. A critical scan past its expected
  // cadence now counts as failing, with the silence NAMED as the cause.
  const SCAN_MAX_AGE: Record<string, number> = {
    birthScan: 5 * 60_000, screenScan: 5 * 60_000, discoveryScan: 5 * 60_000,
    dexTrackScan: 10 * 60_000, pumptapeTrades: 15 * 60_000,
  };
  try {
    const fs: any = await db.prepare("SELECT scan, last_ok_ms, last_err_ms, last_err FROM feed_status").all();
    const nowMs = Date.now();
    for (const r of (fs?.results || [])) {
      const okMs = r.last_ok_ms == null ? null : Number(r.last_ok_ms);
      const errMs = r.last_err_ms == null ? null : Number(r.last_err_ms);
      const isFailing = errMs != null && (okMs == null || errMs > okMs);
      const maxAge = SCAN_MAX_AGE[r.scan];
      const silent = !isFailing && maxAge != null && (okMs == null || nowMs - okMs > maxAge);
      scans[r.scan] = {
        ok_age_ms: okMs == null ? null : nowMs - okMs,
        err_age_ms: errMs == null ? null : nowMs - errMs,
        err: isFailing ? (r.last_err ?? null)
          : silent ? (okMs == null ? "never ran" : "silent " + Math.round((nowMs - okMs) / 60_000) + "m — no heartbeat, no error")
          : null,
        failing: isFailing || silent,
      };
      if (isFailing || silent) failing.push(r.scan);
    }
  } catch { /* feed_status not present yet — omit */ }

  // Best-effort on-chain cross-check — only when births look flat, since that
  // is exactly when "our WS dropped" vs "pump.fun itself is quiet" is the open
  // question. Short timeout; a failure never blocks the verdict.
  let pumpfun_program: { checked: boolean; alive: boolean; age_s: number | null } | null = null;
  if (birthsFlat) {
    pumpfun_program = { checked: true, alive: false, age_s: null };
    try {
      const ac = new AbortController();
      const t = setTimeout(() => ac.abort(), 3000);
      const rr = await fetch("https://api.mainnet-beta.solana.com", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getSignaturesForAddress", params: ["6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P", { limit: 1 }] }),
        signal: ac.signal,
      });
      clearTimeout(t);
      const jj: any = await rr.json();
      const bt = jj?.result?.[0]?.blockTime;
      if (bt) {
        const age_s = Math.max(0, Math.floor(Date.now() / 1000) - Number(bt));
        pumpfun_program = { checked: true, alive: age_s < 120, age_s };
      }
    } catch { /* leave alive:false, age_s:null — unknown, not proven-quiet */ }
  }

  let status: string, diagnosis: string, action: string | null;
  if (!btcFresh && birthsFlat) {
    status = "radar_down";
    diagnosis = "Radar worker down — the BTC and pump.fun feeds are both stale.";
    action = "Redeploy the radar worker.";
  } else if (btcFresh && birthsFlat && tapeFrozen) {
    if (pumpfun_program?.alive) {
      status = "ws_dropped";
      diagnosis = "pump.fun is LIVE on-chain (" + pumpfun_program.age_s + "s ago) but births + tape are frozen while the worker is alive (BTC fresh) — the pumpportal websocket dropped.";
      action = "Redeploy the radar worker to reconnect the WS.";
    } else if (pumpfun_program && pumpfun_program.age_s == null) {
      status = "ingest_stalled";
      diagnosis = "Births + tape frozen, worker alive (BTC fresh); couldn't reach Solana to confirm whether pump.fun itself is live.";
      action = "Likely a dropped WS — redeploy the radar worker; if births stay flat, verify pump.fun isn't halted.";
    } else {
      status = "market_quiet";
      diagnosis = "Births + tape frozen, worker alive (BTC fresh), and pump.fun's program looks quiet on-chain — a market lull, not our bug.";
      action = "Stand down; births resume when pump.fun does.";
    }
  } else if (btcFresh && birthsFlat && !tapeFrozen) {
    status = "quiet";
    diagnosis = "No new births in 5 min but the tape is recent — likely a brief lull.";
    action = "Watch; no action unless it persists.";
  } else if (!btcFresh && !birthsFlat) {
    status = "btc_lagging";
    diagnosis = "Births are flowing but the BTC regime feed is lagging.";
    action = "Minor — watch the BTC source.";
  } else {
    status = "healthy";
    diagnosis = "Feed live — births and tape current.";
    action = null;
  }

  // GREEN CANNOT COEXIST WITH A DEAD SCAN (the other half of the False-Green
  // fix): births/tape freshness alone said "healthy" for 50h while the
  // per-trade tape was down, because that stream feeds neither births nor
  // mc_ticks. If any tracked scan is failing OR silent, the banner degrades
  // and names it — a persistent failure can no longer sit under green.
  if (status === "healthy" && failing.length) {
    status = "degraded";
    diagnosis = "Births and tape current, but " + failing.join(", ") + " " +
      (failing.length > 1 ? "are" : "is") + " down — a feed the verdict depends on is not reporting.";
    action = failing.includes("pumptapeTrades")
      ? "Per-trade tape: check the PumpPortal key balance (silent drain <0.02 SOL) and the Railway tape service."
      : "Check the named scan's last error / heartbeat in feed_status.";
  }

  // Name the cause: if a scan is throwing during a stall, append which one and
  // why — the WHY, live, instead of guessing between upstream/limit/code bug.
  if (failing.length && status !== "healthy" && status !== "market_quiet") {
    const detail = failing.map((s) => {
      const sc = scans[s];
      const age = sc.err_age_ms == null ? "" : " (" + Math.round(sc.err_age_ms / 1000) + "s ago)";
      return s + " failing" + age + (sc.err ? ": " + sc.err : "");
    }).join("; ");
    diagnosis += "  CAUSE — " + detail + ".";
    if (status === "ingest_stalled" || status === "radar_down")
      action = "Fix the failing scan (see cause) — a redeploy only helps for a transient/socket issue, not a code or upstream error.";
  }

  const payload = {
    ts: Date.now(),
    status,
    diagnosis,
    action,
    streams: {
      births: { age_ms: births_age_ms, last_5min: births_5min, last_1h: births_1h },
      tape: { age_ms: tape_age_ms },
      btc: { age_ms: btc_age_ms, usd: btc_usd },
    },
    pumpfun_program,
    scans,
    db_mb,
  };
  healthCache = { at: Date.now(), payload }; // N-4
  return payload;
}

const STATEMENT_DOMAIN = { name: "PossessioCouncilStatement", version: "1" } as const;
const STATEMENT_TYPES = {
  Statement: [
    { name: "body", type: "string" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

// ── Read-only MCP endpoint (/mcp) ────────────────────────────────────────────
// The council message board, reachable as a claude.ai custom connector. This is
// the READ-ONLY rung of the council connector: it exposes only look-only tools
// (council_read_feed, council_status) and holds NO seat key — consistent with the
// connector's core invariant that Possessio infra never holds a signing key
// (mcp/council-signer/README.md, "the remote trade-off"). The keyed talk/vote
// rungs stay OPERATOR-self-hosted, never here. Minimal MCP Streamable-HTTP: POST
// JSON-RPC (initialize / tools/list / tools/call). Register in claude.ai ->
// Settings -> Connectors -> Add custom connector: URL https://possessio.io/mcp,
// header  Authorization: Bearer <COUNCIL_MCP_TOKEN>.
const MCP_CORS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, GET, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, mcp-session-id, mcp-protocol-version",
  "access-control-max-age": "86400",
};
// Connector version — bumped on EVERY /mcp change and echoed by council_status,
// so "did the new code actually deploy?" is a one-call check from any seat.
// The increment discipline (one function per change) only attributes breakage
// if each rung is distinguishable on the live endpoint; this stamp is how.
const MCP_VERSION = "0.6.2";
const MCP_TOOLS = [
  {
    name: "council_read_feed",
    description: "Read council communication-ledger messages newer than {since} (ms epoch). Read-only; returns the latest 200.",
    inputSchema: { type: "object", properties: { since: { type: "number", description: "ms epoch; 0 or omit for the latest messages" } } },
  },
  {
    name: "council_status",
    description: "Council-level status: chain id, hook address, configured seats, and message count. Read-only.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "council_search",
    description: "Search council-ledger message bodies (case-insensitive substring), optionally filtered by seat. Read-only; newest first, max 50 rows.",
    inputSchema: {
      type: "object",
      properties: {
        q: { type: "string", description: "Substring to find in body (2-200 chars). Literal % and _ are matched literally." },
        seat: { type: "string", description: "Optional: only rows posted by this exact seat string" },
        limit: { type: "number", description: "Max rows to return; default 20, cap 50" },
      },
      required: ["q"],
    },
  },
  {
    name: "council_read_thread",
    description: "Walk a conversation thread from any board row id: ancestors via its ref chain, descendants via rows whose ref points back. Read-only; bounded (max 50 rows, 20 hops); rows sorted oldest-first.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "number", description: "The board row id to anchor the thread walk on (must exist)" },
      },
      required: ["id"],
    },
  },
  {
    name: "radar_health",
    description: "Radar feed health self-diagnosis — the same verdict the console's /api/radar/health serves: status, plain-language diagnosis, recommended action, per-stream ages, failing scans. Read-only; cross-organ (radar D1). May serve a briefly cached verdict, marked cached:true.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "council_post",
    description: "Post a message to the council board so the seats can talk to each other. SANDBOX: the message is NOT cryptographically signed — it is attributed to the {seat} you claim, and the write is gated by the connector token (a shared write password, NOT a seat key). Requires the COUNCIL_MCP_TOKEN bearer.",
    inputSchema: {
      type: "object",
      properties: {
        seat: { type: "string", description: "Your seat identity — an address from council_status.seats, or a recognizable name (e.g. 'Claude')" },
        body: { type: "string", description: "The message text (max 8000 chars)" },
        kind: { type: "string", description: "Optional message kind; default 'statement'" },
        ref: { type: "string", description: "Optional reference to what this row answers — a board row id (e.g. '18', must exist) or a proposalHash (max 256 chars)" },
      },
      required: ["seat", "body"],
    },
  },
];
function mcpTimingSafeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function mcpCallTool(name: string, args: any, env: Env, authed: boolean): Promise<unknown> {
  if (name === "council_read_feed") {
    const since = Number(args?.since ?? 0) || 0;
    const { results } = await env.COUNCIL_DB
      .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger WHERE ts_ms > ?1 ORDER BY ts_ms ASC LIMIT 200")
      .bind(since).all();
    return { rows: results || [] };
  }
  if (name === "council_status") {
    const seats = (env.COUNCIL_SEATS || "").split(",").map((s) => s.trim()).filter(Boolean);
    const row = await env.COUNCIL_DB.prepare("SELECT COUNT(*) AS n, MAX(ts_ms) AS latest FROM council_ledger").first<any>();
    return {
      connector_version: MCP_VERSION,
      chainId: Number(env.COUNCIL_CHAIN_ID || 8453),
      hook: env.COUNCIL_HOOK_ADDRESS || null,
      seats,
      messageCount: Number(row?.n ?? 0),
      latest_ts_ms: row?.latest ?? null,
    };
  }
  if (name === "council_search") {
    // Read-only, same visibility as council_read_feed (the board is public data).
    // Bounded like every ledger read: LIMIT capped, q length capped. LIKE wildcards
    // in q are escaped so a seat searching for a literal "%" or "_" gets what it
    // typed — the pattern language is not part of the tool's contract.
    const q = String(args?.q ?? "").trim();
    if (q.length < 2) throw new Error("q too short (min 2 chars)");
    if (q.length > 200) throw new Error("q too long (max 200 chars)");
    const limit = Math.min(Math.max(1, Math.trunc(Number(args?.limit ?? 20)) || 20), 50);
    const seat = typeof args?.seat === "string" ? args.seat.trim() : "";
    const pat = "%" + q.replace(/[\\%_]/g, (c) => "\\" + c) + "%";
    const stmt = seat
      ? env.COUNCIL_DB
          .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger WHERE body LIKE ?1 ESCAPE '\\' AND seat = ?2 ORDER BY ts_ms DESC LIMIT ?3")
          .bind(pat, seat, limit)
      : env.COUNCIL_DB
          .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger WHERE body LIKE ?1 ESCAPE '\\' ORDER BY ts_ms DESC LIMIT ?2")
          .bind(pat, limit);
    const { results } = await stmt.all();
    return { q, seat: seat || null, rows: results || [] };
  }
  if (name === "council_read_thread") {
    // Read-only thread walk (increment 5): the graph the ref edges define,
    // traversed from one anchor row — ancestors by following digits-only refs
    // upward, descendants by reverse lookup (ref = id). Bounded on every axis
    // (row cap, hop cap, visited set, per-parent child LIMIT) so a cyclic or
    // adversarial chain can never turn a read into a table walk. Hash refs
    // (0x…) end ancestor traversal — their existence lives on-chain, not here.
    const id = Math.trunc(Number(args?.id));
    if (!Number.isFinite(id) || id <= 0) throw new Error("id must be a positive row id");
    const SELECT = "SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger";
    const anchor: any = await env.COUNCIL_DB.prepare(SELECT + " WHERE id = ?1 LIMIT 1").bind(id).first();
    if (!anchor) throw new Error("row " + id + " does not exist on the board");
    const MAX_ROWS = 50, MAX_HOPS = 20;
    const seen = new Set<number>([Number(anchor.id)]);
    const rows: any[] = [anchor];
    let cur: any = anchor;
    for (let hop = 0; hop < MAX_HOPS && rows.length < MAX_ROWS; hop++) {
      const up = typeof cur.ref === "string" && /^\d+$/.test(cur.ref) ? Number(cur.ref) : null;
      if (up == null || seen.has(up)) break;
      const parent: any = await env.COUNCIL_DB.prepare(SELECT + " WHERE id = ?1 LIMIT 1").bind(up).first();
      if (!parent) break;
      seen.add(Number(parent.id)); rows.push(parent); cur = parent;
    }
    let frontier: number[] = Array.from(seen);
    for (let hop = 0; hop < MAX_HOPS && frontier.length && rows.length < MAX_ROWS; hop++) {
      const next: number[] = [];
      for (const fid of frontier) {
        if (rows.length >= MAX_ROWS) break;
        const { results } = await env.COUNCIL_DB
          .prepare(SELECT + " WHERE ref = ?1 ORDER BY ts_ms ASC LIMIT 25").bind(String(fid)).all();
        for (const child of (results || []) as any[]) {
          if (rows.length >= MAX_ROWS) break;
          if (seen.has(Number(child.id))) continue;
          seen.add(Number(child.id)); rows.push(child); next.push(Number(child.id));
        }
      }
      frontier = next;
    }
    rows.sort((a, b) => (a.ts_ms - b.ts_ms) || (a.id - b.id));
    return { anchor: id, count: rows.length, truncated: rows.length >= MAX_ROWS, rows };
  }
  if (name === "radar_health") {
    // Cross-organ read (increment 4): the connector's first tool whose data is
    // another organ's. Same visibility as the public /api/radar/health route,
    // same computation (computeRadarHealth) — the console and the council can
    // never disagree about the feed. Read-only; no auth needed, like all reads.
    return await computeRadarHealth(env.COUNCIL_DB);
  }
  if (name === "council_post") {
    // SANDBOX write: no seat key, no signature. Attribution is by claim; the
    // write is gated on the connector token (a shared write password), which
    // keeps the open internet off the board without introducing a signing key.
    // Marked signature="unsigned-sandbox" so the board stays honest about which
    // rows are attested vs claimed. Production posts sign via the keyed connector.
    if (!authed)
      throw new Error("writes are token-gated: set COUNCIL_MCP_TOKEN on the worker and send Authorization: Bearer <token>. This is a sandbox write password, not a seat key.");
    const seat = String(args?.seat ?? "").trim();
    const body = String(args?.body ?? "");
    const kind = (typeof args?.kind === "string" ? args.kind : "statement").slice(0, 32);
    // Same bound as the signed endpoint's N-1 residual cap (REF_MAX_CHARS): ref
    // is a short pointer (row id / proposalHash), never free-form prose. Rejected
    // loudly rather than truncated — a silently clipped reference points at the
    // wrong thing, which is worse than no reference.
    const ref = typeof args?.ref === "string" && args.ref.trim() ? args.ref.trim() : null;
    if (!seat) throw new Error("seat is required");
    if (!body) throw new Error("body is required");
    if (body.length > 8000) throw new Error("body too long (max 8000 chars)");
    if (ref !== null && ref.length > REF_MAX_CHARS) throw new Error("ref too long (max " + REF_MAX_CHARS + " chars)");
    // A digits-only ref claims to answer a board row, so it must name one that
    // exists — refused otherwise, fail-closed (board consensus, rows 20/24: a
    // reference to nothing is worse than none). Scoped to digits because ref
    // also carries proposalHashes (0x…, 66 chars), whose existence lives
    // on-chain, not in this ledger — those pass through on length alone.
    if (ref !== null && /^\d+$/.test(ref)) {
      const hit = await env.COUNCIL_DB.prepare("SELECT 1 FROM council_ledger WHERE id = ?1 LIMIT 1").bind(Number(ref)).first();
      if (!hit) throw new Error("ref row " + ref + " does not exist on the board");
    }
    const ts = Date.now();
    const rnd = crypto.getRandomValues(new Uint32Array(2));
    const nonce = "sandbox-" + ts.toString(36) + "-" + rnd[0].toString(36) + rnd[1].toString(36);
    try {
      await env.COUNCIL_DB
        .prepare("INSERT INTO council_ledger (ts_ms, seat, kind, body, nonce, signature, ref) VALUES (?1,?2,?3,?4,?5,?6,?7)")
        .bind(ts, seat, kind, body, nonce, "unsigned-sandbox", ref).run();
    } catch (e: any) {
      throw new Error("ledger write failed: " + (e?.message || String(e)));
    }
    return { ok: true, ts_ms: ts, seat, kind, ref, note: "sandbox message posted (unsigned — attributed by claim)" };
  }
  throw new Error("unknown tool: " + name);
}
async function handleMcp(request: Request, env: Env): Promise<Response> {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: MCP_CORS });
  const jrpc = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { ...MCP_CORS, "content-type": "application/json" } });
  const ok = (id: any, result: unknown) => ({ jsonrpc: "2.0", id: id ?? null, result });
  const err = (id: any, code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

  // Reads are public (the board is meant to be displayed). Writes (council_post)
  // are gated on the connector token — a shared write password, NOT a seat key.
  // The write token may arrive three ways: a Bearer header, a capability-URL path
  // segment (/mcp/<token>), or a ?token= query param. The claude.ai custom-connector
  // UI has NO custom-header field — only a URL — so the path form is what actually
  // works there (the solana-mcp capability-URL precedent). All three are accepted.
  const url = new URL(request.url);
  const token = env.COUNCIL_MCP_TOKEN;
  const bearer = (request.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i);
  let pathToken = "";
  if (url.pathname.startsWith("/mcp/")) {
    const seg = url.pathname.slice(5).split("/")[0];
    try { pathToken = decodeURIComponent(seg); } catch { pathToken = seg; }
  }
  const provided = (bearer && bearer[1]) || pathToken || url.searchParams.get("token") || "";
  const authed = !!token && !!provided && mcpTimingSafeEq(provided, token);
  if (request.method === "GET")
    return new Response(JSON.stringify(err(null, -32601, "no event stream here; POST JSON-RPC")), {
      status: 405, headers: { ...MCP_CORS, "content-type": "application/json", allow: "POST, OPTIONS" },
    });
  if (request.method !== "POST")
    return new Response(null, { status: 405, headers: { ...MCP_CORS, allow: "POST, OPTIONS" } });

  let body: any;
  try { body = await request.json(); } catch { return jrpc(err(null, -32700, "parse error"), 400); }

  const handleOne = async (msg: any): Promise<any> => {
    const id = msg?.id ?? null;
    const method = msg?.method;
    if (typeof method === "string" && method.startsWith("notifications/")) return null; // notification: no reply
    if (method === "initialize") {
      // Version negotiation (0.6.2, council WO after the 0.6.1 outage): echo
      // the client's revision when it is one we comply with; for an UNKNOWN
      // revision offer the SAFEST widely-accepted one, NOT the newest. 0.6.1
      // offered the newest (2026-07-28) as fallback and it broke the live
      // claude.ai handshake: the client was on 2025-11-25 — absent from the
      // list — got counter-offered a version it cannot speak, and refused
      // ("unsupported protocol version"). A client that asks for a version
      // you don't know has just proven it is not on your newest — offering
      // the newest guarantees rejection. Meet the client where it is.
      const SUPPORTED = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
      const SAFEST = "2025-06-18";
      const asked = msg?.params?.protocolVersion;
      return ok(id, {
        protocolVersion: SUPPORTED.includes(asked) ? asked : SAFEST,
        capabilities: { tools: {} },
        serverInfo: { name: "possessio-council", version: MCP_VERSION },
      });
    }
    if (method === "ping") return ok(id, {});
    if (method === "tools/list") return ok(id, { tools: MCP_TOOLS });
    if (method === "tools/call") {
      const name = msg?.params?.name;
      const args = msg?.params?.arguments || {};
      try {
        const result = await mcpCallTool(name, args, env, authed);
        return ok(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
      } catch (e: any) {
        return ok(id, { content: [{ type: "text", text: "error: " + (e?.message || String(e)) }], isError: true });
      }
    }
    return err(id, -32601, "method not found: " + method);
  };

  if (Array.isArray(body)) {
    const out: any[] = [];
    for (const m of body) { const r = await handleOne(m); if (r) out.push(r); }
    return out.length ? jrpc(out) : new Response(null, { status: 202, headers: MCP_CORS });
  }
  const r = await handleOne(body);
  return r ? jrpc(r) : new Response(null, { status: 202, headers: MCP_CORS });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

    // Read-only council message board as a claude.ai custom connector (no key).
    if (pathname === "/mcp" || pathname.startsWith("/mcp/")) return handleMcp(request, env);

    // Pinned template artifact for the launch rail (LaunchRail D2). Holds the
    // Account template's creation code so the browser can hash it and compare
    // against factory.templateCodehash() read live from chain — the rail never
    // trusts this blob, it verifies it, and stays in preview on any mismatch.
    //
    // ON THE HAPPY PATH THIS HANDLER DOES NOT RUN. Assets serve first for any
    // matching path (see wrangler.jsonc), so a committed
    // public/artifacts/payments.json answers directly and never reaches the
    // script. This route exists for the MISS — if the artifact is absent from a
    // deploy (it lives under a gitignored-by-default `artifacts/` name, so
    // "forgot to commit it" is the realistic failure), the request falls
    // through to here and gets a clean JSON 503. Without it the miss returns
    // whatever the asset layer decides, and the rail's `await res.json()`
    // throws a parse error on an HTML body — a confusing symptom for a simple
    // missing file. Fail loud and legibly instead.
    //
    // The file is generated by script/GenTemplateArtifact.s.sol from
    // type(PossessioPayments).creationCode, and that script REVERTS if the hash
    // no longer matches the live factory's immutable pin.
    if (pathname === "/artifacts/payments.json") {
      const res = await env.ASSETS.fetch(request);
      if (!res.ok) {
        return new Response(
          JSON.stringify({
            error: "template artifact unavailable",
            detail:
              "public/artifacts/payments.json is missing from this deploy. " +
              "Regenerate with `forge script script/GenTemplateArtifact.s.sol` and commit it.",
          }),
          {
            status: 503,
            headers: {
              "content-type": "application/json; charset=utf-8",
              "cache-control": "no-store",
            },
          },
        );
      }
      return res;
    }

    // Radar feed proxy — the AI Assisted Trading desk (public/index.html,
    // #desk-view) fetches its live coin list from here. The radar runs on a
    // separate worker with no CORS headers, so a browser fetch cross-origin
    // would be blocked; this same-origin proxy fetches it server-side. Read-
    // only passthrough of the public /radar/candidates JSON; 5s edge cache to
    // match the desk's poll cadence and shield the radar from fan-out.
    if (pathname === "/api/radar/candidates") {
      const RADAR = "https://possessio-radar.jonb89201.workers.dev/radar/candidates";
      try {
        // Bounded fetch (N-2, audit 2026-07-23). The repo's standing law: no
        // un-timed await on an external host on a REQUEST path (radar/watcher.ts
        // documents the 21-minute freeze that taught it). cf.cacheTtl only helps
        // a cache HIT — a cold or expired fetch to a hung radar still blocks, and
        // this path is polled every 5s by every open desk, so each poll would pin
        // an isolate until the platform kills it. 5s matches the desk's cadence:
        // a slower answer is stale anyway, and the client falls back cleanly.
        const r = await fetch(RADAR, {
          cf: { cacheTtl: 5, cacheEverything: true },
          signal: AbortSignal.timeout(5_000),
        } as any);
        const body = await r.text();
        return new Response(body, {
          status: r.status,
          headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
      } catch {
        return new Response(JSON.stringify({ error: "RADAR_UNREACHABLE" }), {
          status: 502,
          headers: { "content-type": "application/json" },
        });
      }
    }

    // Hourly 100k-hit desk-reach measurement (2026-08-15). Same passthrough
    // shape as /api/radar/candidates just above — this route is free/public/
    // aggregate-only on the radar worker (radar/x402-toll.ts), so no auth
    // concern, just the same cross-origin + timeout guard. Cached longer
    // (60s, not 5s) since it changes on the order of an hour, not a poll tick,
    // and the overnight measurement trigger calls it once an hour by design.
    if (pathname === "/api/radar/hourly-100k") {
      const RADAR = "https://possessio-radar.jonb89201.workers.dev/radar/hourly-100k";
      try {
        const r = await fetch(RADAR, {
          cf: { cacheTtl: 60, cacheEverything: true },
          signal: AbortSignal.timeout(5_000),
        } as any);
        const body = await r.text();
        return new Response(body, {
          status: r.status,
          headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
      } catch {
        return new Response(JSON.stringify({ error: "RADAR_UNREACHABLE" }), {
          status: 502,
          headers: { "content-type": "application/json" },
        });
      }
    }

    // Radar feed HEALTH — the console's self-diagnosis, the "mobile F12 for the
    // feed". Reads the same radar D1 the feed writes to and returns, in plain
    // language, WHAT is wrong when births go quiet — encoding the split that
    // actually cracked the 2026-07-22 stall: if the BTC regime writer is fresh
    // but births AND the minute-tape are frozen, the worker is alive and the
    // pumpportal websocket dropped (redeploy fixes it); if everything is stale
    // the worker itself is down; and a best-effort on-chain check of pump.fun's
    // own program tells a dropped-WS ("our bug, redeploy") apart from a genuine
    // market lull ("stand down"). Read-only; never mutates.
    if (pathname === "/api/radar/health") {
      const db = env.COUNCIL_DB;
      if (!db) return json({ status: "unknown", error: "COUNCIL_DB_UNBOUND" }, 503);
      return json(await computeRadarHealth(db));
    }

    // Council communication ledger (SPEC_CouncilSigner_v3 §8). The end-to-end
    // channel: a seat POSTs a signed statement (over MCP or the console) -> we
    // verify the EIP-712 signature recovers to the claimed seat (and, if a seat
    // allowlist is configured, that it IS a seat) -> append to D1. GET is public
    // read (any seat / the console viewer polls it). Every row is attributable;
    // an unsigned or spoofed message never lands.
    if (pathname === "/api/council/ledger") {
      const db = env.COUNCIL_DB;
      if (!db) return json({ error: "COUNCIL_DB_UNBOUND" }, 503);

      if (request.method === "GET") {
        const params = new URL(request.url).searchParams;
        // tail=1 — the viewer's window: newest 200, so a board past 200 rows
        // still shows its latest messages. `since` stays the incremental ASC
        // read the MCP pollers depend on; the two must not merge, because
        // "newer than X, oldest first" and "latest N" answer different readers,
        // and with since=0 the ASC read pins a >200-row board to its OLDEST
        // 200 forever — the console viewer froze on exactly that.
        if (params.get("tail")) {
          const { results } = await db
            .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger ORDER BY ts_ms DESC LIMIT 200")
            .all();
          return json({ rows: results || [] });
        }
        const since = Number(params.get("since") || "0") || 0;
        const { results } = await db
          .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger WHERE ts_ms > ?1 ORDER BY ts_ms ASC LIMIT 200")
          .bind(since)
          .all();
        return json({ rows: results || [] });
      }

      if (request.method === "POST") {
        let b: any;
        try { b = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }
        const seat = b?.seat, body = b?.body, nonce = b?.nonce, signature = b?.signature;
        const kind = typeof b?.kind === "string" ? b.kind : "statement";
        const ref = typeof b?.ref === "string" ? b.ref : null;
        if (!seat || !isAddress(seat) || typeof body !== "string" || body.length === 0 || body.length > 8000 || nonce == null || typeof signature !== "string")
          return json({ error: "BAD_FIELDS" }, 400);
        // N-1 residual (audit 2026-07-24): `body` was the only bounded field, so
        // `kind`/`ref` were unbounded write amplification into the SHARED radar D1
        // — the same database whose size ceiling halted every radar write on
        // 2026-07-16. Neither field is free-form prose: `kind` is a short
        // discriminator (statement | proposal | note) and `ref` is a proposalHash
        // (66 chars). Cap both rather than enum-restrict, so a future `kind` does
        // not need a worker deploy to be accepted.
        if (kind.length > KIND_MAX_CHARS) return json({ error: "KIND_TOO_LONG" }, 400);
        if (ref !== null && ref.length > REF_MAX_CHARS) return json({ error: "REF_TOO_LONG" }, 400);

        let recovered: string;
        try {
          recovered = await recoverTypedDataAddress({
            domain: STATEMENT_DOMAIN,
            types: STATEMENT_TYPES,
            primaryType: "Statement",
            message: { body, nonce: BigInt(nonce) },
            signature: signature as `0x${string}`,
          });
        } catch { return json({ error: "BAD_SIGNATURE" }, 400); }
        if (getAddress(recovered) !== getAddress(seat)) return json({ error: "SIGNER_MISMATCH" }, 401);

        // Fail CLOSED (N-1, audit 2026-07-23): an unset/empty allowlist rejects
        // every write. A valid signature only proves *some* key signed — not that
        // it is a council seat — so without the gate any address could post and
        // grow the shared radar D1 unbounded. The endpoint refuses to accept until
        // COUNCIL_SEATS is configured (set in wrangler.jsonc).
        const allow = (env.COUNCIL_SEATS || "").split(",").map((s) => s.trim()).filter(Boolean)
          .map((s) => { try { return getAddress(s); } catch { return ""; } }).filter(Boolean);
        if (!allow.length) return json({ error: "ALLOWLIST_UNCONFIGURED" }, 503);
        if (!allow.includes(getAddress(seat))) return json({ error: "NOT_A_SEAT" }, 403);

        // Per-seat rate limit (N-1 residual). Deliberately AFTER the signature +
        // allowlist gates: an unauthenticated caller can never consume a real
        // seat's budget, and the extra D1 read only runs for a proven seat. The
        // ledger is its own rate-limit state — no new binding, and the counter
        // cannot drift from what was actually written. Bounds a compromised seat
        // key to SEAT_RATE_MAX_POSTS * (8000 + caps) bytes per window against the
        // shared radar DB.
        const rlSince = Date.now() - SEAT_RATE_WINDOW_MS;
        const recent = await db
          .prepare("SELECT COUNT(*) AS n FROM council_ledger WHERE seat = ?1 AND ts_ms > ?2")
          .bind(getAddress(seat), rlSince)
          .first<{ n: number }>();
        if ((recent?.n ?? 0) >= SEAT_RATE_MAX_POSTS) {
          return json({ error: "RATE_LIMITED", retry_after_ms: SEAT_RATE_WINDOW_MS }, 429);
        }

        // Replay is dead at the DB (N-1): UNIQUE(seat, nonce) (migration 0025) lets
        // a seat commit any nonce at most once, so a statement harvested from the
        // public GET can never be re-POSTed. The signature stays public on GET so
        // the ledger remains independently verifiable — replay is blocked by the
        // index, not by hiding the material. The nonce is stored as its CANONICAL
        // decimal (BigInt) — the signature only binds the numeric value, so "42"
        // and "0x2a" are the same nonce and must collide in the index, not slip
        // past it as distinct strings.
        const ts = Date.now();
        const nonceCanon = BigInt(nonce).toString();
        try {
          const r = await db
            .prepare("INSERT INTO council_ledger (ts_ms, seat, kind, body, nonce, signature, ref) VALUES (?1,?2,?3,?4,?5,?6,?7)")
            .bind(ts, getAddress(seat), kind, body, nonceCanon, signature, ref)
            .run();
          return json({ ok: true, id: r.meta.last_row_id, ts_ms: ts });
        } catch (e: any) {
          if (/UNIQUE|constraint/i.test(String(e?.message || e))) return json({ error: "NONCE_ALREADY_USED" }, 409);
          throw e;
        }
      }
      return json({ error: "METHOD" }, 405);
    }

    // ── THE DESK'S RULE LEDGER ───────────────────────────────────────────
    // The human's actual instruction: this coin, this target, this stop. The
    // desk already buys the coin and grants the keeper a bounded delegate; this
    // is where the INSTRUCTION lives, so the keeper has something to watch.
    //
    // A rule is not authority. The keeper can only sell if the chain also says
    // it holds a live delegate over that exact account, and it iterates rules
    // rather than grants — so an unruled delegate is never even looked at.
    //
    // Every write is signed by the Solana wallet it applies to. Without that, a
    // forged rule over a wallet that HAS granted a delegate is a real attack:
    // set the target to zero and the keeper dumps someone's position on demand.
    // `owner` is the recovered signer, never a claim in the body.
    if (pathname === "/api/desk/rules") {
      const db = env.COUNCIL_DB;
      if (!db) return json({ error: "COUNCIL_DB_UNBOUND" }, 503);

      // GET: what the keeper polls. Only open rules, and only the fields it
      // needs to decide — never the signature material, which it cannot use.
      if (request.method === "GET") {
        const { results } = await db
          .prepare(
            "SELECT id, owner, mint, decimals, entry_price, target_bps, stop_bps, ts_ms " +
              "FROM desk_rules WHERE status = 'open' ORDER BY ts_ms ASC LIMIT 500",
          )
          .all();
        return json({
          positions: (results || []).map((r: any) => ({
            id: String(r.id),
            user: r.owner,
            mint: r.mint,
            decimals: r.decimals,
            entryPrice: r.entry_price,
            targetBps: r.target_bps,
            // NULL stop_bps is NO STOP. Reported as an explicit flag so the
            // keeper branches rather than inferring absence from a null it
            // might coerce to 0 somewhere downstream.
            hasStop: r.stop_bps != null,
            stopBps: r.stop_bps,
            status: "open",
            openedAt: r.ts_ms,
          })),
        });
      }

      if (request.method === "POST") {
        let b: any;
        try { b = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }

        const { owner, mint, decimals, entryPrice, targetBps, hasStop, stopBps, nonce, signature } = b || {};

        // Shape first — every field bounded, because this writes into the
        // SHARED radar D1 whose size ceiling has halted writes before.
        if (typeof owner !== "string" || !isBase58Pubkey(owner)) return json({ error: "BAD_OWNER" }, 400);
        // PRIVATE BETA GATE — refuse a stranger's write to the shared D1 before
        // any work, but AFTER owner shape so a malformed owner still 400s. The
        // owner is signature-verified below; the allowlist cannot be spoofed.
        if (!deskArmingAllowed(env, owner)) return json({ error: "DESK_PRIVATE_BETA" }, 403);
        if (typeof mint !== "string" || !isBase58Pubkey(mint)) return json({ error: "BAD_MINT" }, 400);
        if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18) return json({ error: "BAD_DECIMALS" }, 400);
        if (typeof entryPrice !== "number" || !(entryPrice > 0) || !Number.isFinite(entryPrice))
          return json({ error: "BAD_ENTRY_PRICE" }, 400);
        // The three buttons the desk actually offers, and nothing else. This
        // mirrors AutoTarget.openIntent's BadTarget check, so the ledger and the
        // contract accept exactly the same vocabulary and a later switch to the
        // on-chain source cannot silently change what a target means.
        // TARGET RANGE, not an allowlist (Architect ruling 2026-08-01: the desk
        // ships a gain-target slider with no floor and no cap — "if they set it
        // to 1% they deserve to lose; they can do the math, they see the fees").
        //
        // This was `!== 1000 && !== 2500 && !== 5000`, matching three fixed
        // buttons that no longer exist. Against the slider it means a user can
        // set 137%, sign the rule, and have the worker reject it with a 400 —
        // the console letting someone sign something it cannot store. Caught by
        // the desk<->worker contract test the moment that suite was repaired.
        //
        // Bounds are the slider's own, not a policy: 1%..500%. Integer-only,
        // because a fractional bps is not representable downstream (uint16 in
        // the contract) and would silently truncate.
        if (!Number.isInteger(targetBps) || targetBps < 100 || targetBps > 50000)
          return json({ error: "BAD_TARGET" }, 400);
        // THE STOP — Architect ratification 2026-08-01, Option B.
        //
        // A valid stop is an integer 1..9999. ZERO IS REJECTED: zero is the
        // uninitialised value of every integer on this path, and a stop of 0
        // computes a threshold exactly ON the entry price, selling on the first
        // tick at or below the buy. 10000 is NOT adopted as a "no stop"
        // sentinel either — a 100% drawdown is a semantically real value, and
        // overloading it repeats the error that disqualified zero.
        //
        // "No stop" is carried by hasStop:false, stated positively. It is
        // REQUIRED to be a boolean: a rule that fails to say cannot be written,
        // so a forgotten field is rejected rather than silently meaning the most
        // permissive thing available.
        if (typeof hasStop !== "boolean") return json({ error: "STOP_UNSTATED" }, 400);
        if (hasStop) {
          if (!Number.isInteger(stopBps) || stopBps < 1 || stopBps > 9999)
            return json({ error: "BAD_STOP" }, 400);
        } else if (stopBps !== undefined && stopBps !== null) {
          // Carrying a threshold alongside hasStop:false is a contradiction, and
          // the signature covers both — so refuse rather than pick a winner.
          return json({ error: "STOP_CONTRADICTION" }, 400);
        }
        if (typeof nonce !== "string" || !nonce.length || nonce.length > 64) return json({ error: "BAD_NONCE" }, 400);
        if (typeof signature !== "string" || signature.length > 200) return json({ error: "BAD_SIGNATURE" }, 400);

        // The signature covers the WHOLE instruction. Changing any field —
        // especially the target — invalidates it, so a rule cannot be edited in
        // flight by anything between the wallet and this table.
        const preimage = deskRulePreimage({ owner, mint, decimals, entryPrice, targetBps, hasStop, stopBps, nonce });
        let verified = false;
        try {
          verified = await verifyEd25519(owner, signature, preimage);
        } catch { return json({ error: "BAD_SIGNATURE" }, 400); }
        if (!verified) return json({ error: "SIGNER_MISMATCH" }, 401);

        const ts = Date.now();
        try {
          // A second buy of the same coin REPLACES the open rule rather than
          // racing it: two open rules over one delegate would leave the keeper
          // no principled way to pick which target is the human's real intent.
          await db
            .prepare("UPDATE desk_rules SET status = 'cancelled' WHERE owner = ?1 AND mint = ?2 AND status = 'open'")
            .bind(owner, mint)
            .run();
          const r = await db
            .prepare(
              "INSERT INTO desk_rules (ts_ms, owner, mint, decimals, entry_price, target_bps, stop_bps, nonce, signature) " +
                "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            )
            .bind(ts, owner, mint, decimals, entryPrice, targetBps, hasStop ? stopBps : null, nonce, signature)
            .run();
          return json({ ok: true, id: r.meta.last_row_id, ts_ms: ts });
        } catch (e: any) {
          if (/UNIQUE|constraint/i.test(String(e?.message || e))) return json({ error: "NONCE_ALREADY_USED" }, 409);
          throw e;
        }
      }

      return json({ error: "METHOD" }, 405);
    }

    // CANCEL — the ledger half of Force Sell (2026-08-10). Owner-signed, like
    // the rule itself: without a signature, anyone who knew a rule id could
    // silently disarm someone else's exit. The only prior cancel path was
    // implicit replacement on re-arm, which forced a user out of a position to
    // get out of a rule.
    if (pathname === "/api/desk/rules/cancel") {
      const db = env.COUNCIL_DB;
      if (!db) return json({ error: "COUNCIL_DB_UNBOUND" }, 503);
      if (request.method !== "POST") return json({ error: "METHOD" }, 405);
      let b: any;
      try { b = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }
      const { owner, mint, ruleId, nonce, signature } = b || {};
      if (typeof owner !== "string" || !isBase58Pubkey(owner)) return json({ error: "BAD_OWNER" }, 400);
      // A cancel only ever narrows to the signer's own open rule, so it is not
      // a write-amplification surface — but gate it to the same allowlist for
      // consistency: a non-beta owner has no rules to cancel anyway.
      if (!deskArmingAllowed(env, owner)) return json({ error: "DESK_PRIVATE_BETA" }, 403);
      if (typeof mint !== "string" || !isBase58Pubkey(mint)) return json({ error: "BAD_MINT" }, 400);
      // ids are D1 rowids serialized as strings; bound tightly since this
      // lands in a WHERE against the shared ledger.
      if (typeof ruleId !== "string" || !/^\d{1,12}$/.test(ruleId)) return json({ error: "BAD_RULE_ID" }, 400);
      if (typeof nonce !== "string" || !nonce.length || nonce.length > 64) return json({ error: "BAD_NONCE" }, 400);
      if (typeof signature !== "string" || signature.length > 200) return json({ error: "BAD_SIGNATURE" }, 400);

      const preimage = deskCancelPreimage({ owner, mint, ruleId, nonce });
      let verified = false;
      try {
        verified = await verifyEd25519(owner, signature, preimage);
      } catch { return json({ error: "BAD_SIGNATURE" }, 400); }
      if (!verified) return json({ error: "SIGNER_MISMATCH" }, 401);

      // Owner and mint are in the WHERE as well as the signature: even a valid
      // signature over someone else's rule id cancels nothing.
      const r = await db
        .prepare("UPDATE desk_rules SET status = 'cancelled' WHERE id = ?1 AND owner = ?2 AND mint = ?3 AND status = 'open'")
        .bind(Number(ruleId), owner, mint)
        .run();
      return json({ ok: true, cancelled: r.meta.changes ?? 0 });
    }

    // CLIENT ERROR SINK — so a failure on a phone stops being a screenshot.
    //
    // WHY THIS EXISTS: the Solana buy path was debugged across five rounds by
    // the Architect photographing a toast at 4am on 26% battery. Every round
    // cost a merge, a deploy and a tap, and each screenshot carried one
    // truncated line. The error was always available in the browser; nothing
    // was carrying it anywhere a seat could read it.
    //
    // PUBLIC AND UNAUTHENTICATED, because it runs before any wallet exists —
    // so it is bounded rather than trusted:
    //   - 2 KB request cap, and every field truncated on the way in
    //   - 20 reports per IP per minute via the existing KV limiter
    //   - fields are fixed; no arbitrary blob is stored
    //   - failure is silent to the caller. An error sink that can itself
    //     produce an error the user sees is worse than no sink.
    if (pathname === "/api/desk/error") {
      if (request.method !== "POST") return json({ error: "METHOD" }, 405);
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
      const key = `errsink:${ip}`;
      try {
        const hits = Number((await env.DRIP_LIMITS.get(key)) ?? 0);
        if (hits >= 20) return json({ ok: true, dropped: "rate" });
        await env.DRIP_LIMITS.put(key, String(hits + 1), { expirationTtl: 60 });
      } catch { /* limiter unavailable -> still accept, still bounded below */ }

      let b: any;
      try {
        const raw = await request.text();
        if (raw.length > 2048) return json({ ok: true, dropped: "size" });
        b = JSON.parse(raw);
      } catch { return json({ ok: true, dropped: "parse" }); }

      const cut = (v: unknown, n: number) =>
        typeof v === "string" && v.length ? v.slice(0, n) : null;
      const stage = cut(b?.stage, 60);
      const message = cut(b?.message, 400);
      if (!stage || !message) return json({ ok: true, dropped: "empty" });

      try {
        await env.COUNCIL_DB.prepare(
          `INSERT INTO client_errors (ts_ms, stage, message, detail, ua, wallet, build)
           VALUES (?1,?2,?3,?4,?5,?6,?7)`
        ).bind(
          Date.now(), stage, message,
          cut(b?.detail, 900), cut(request.headers.get("user-agent"), 200),
          cut(b?.wallet, 60), cut(b?.build, 40),
        ).run();
      } catch { /* never surface a sink failure to the user */ }
      return json({ ok: true });
    }

    if (pathname === "/api/testnet/drip") {
      const deployed = env.POOL_ADDRESS && env.POOL_ADDRESS.toLowerCase() !== ZERO;

      // GET = config read for the console's technical info layer (pool
      // address + the honest facts of the drip). No secrets, no state.
      if (request.method === "GET") {
        return new Response(
          JSON.stringify({
            pool: deployed ? env.POOL_ADDRESS : null,
            usdc: env.USDC_ADDRESS,
            chainId: 84532,
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }

      // Pool not deployed yet (POOL_ADDRESS still the placeholder): answer
      // honestly instead of letting the RPC call fail opaquely.
      if (!deployed) {
        return new Response(JSON.stringify({ error: "POOL_NOT_DEPLOYED" }), {
          status: 503,
          headers: { "content-type": "application/json" },
        });
      }
      return handleDrip(request, env);
    }

    return env.ASSETS.fetch(request);
  },
};
