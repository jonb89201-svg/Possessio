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
}

const ZERO = "0x0000000000000000000000000000000000000000";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

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

const STATEMENT_DOMAIN = { name: "PossessioCouncilStatement", version: "1" } as const;
const STATEMENT_TYPES = {
  Statement: [
    { name: "body", type: "string" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

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
        return json({ status: "unknown", diagnosis: "Radar DB query failed: " + (e?.message || e), action: "Check the COUNCIL_DB binding / radar DB." });
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
      try {
        const fs: any = await db.prepare("SELECT scan, last_ok_ms, last_err_ms, last_err FROM feed_status").all();
        const nowMs = Date.now();
        for (const r of (fs?.results || [])) {
          const okMs = r.last_ok_ms == null ? null : Number(r.last_ok_ms);
          const errMs = r.last_err_ms == null ? null : Number(r.last_err_ms);
          const isFailing = errMs != null && (okMs == null || errMs > okMs);
          scans[r.scan] = {
            ok_age_ms: okMs == null ? null : nowMs - okMs,
            err_age_ms: errMs == null ? null : nowMs - errMs,
            err: isFailing ? (r.last_err ?? null) : null,
            failing: isFailing,
          };
          if (isFailing) failing.push(r.scan);
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

      return json({
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
      });
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
        const since = Number(new URL(request.url).searchParams.get("since") || "0") || 0;
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
