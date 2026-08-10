// possessio-radar Worker entry. The toll'd read-API over the live D1 ledger
// (possessio-radar-ledger) PLUS the per-minute jobs below. The watcher
// (pump.fun feed poller writing births) LANDED 2026-07-06; the screen, tape,
// and post-grad tracker followed. This worker serves the measurements and
// arms the sell-side toll the moment the wave writes TOLL_SINK.
import { buildTolledApp } from "./x402-toll";
import { birthScan, discoveryScan, btcScan, type WatcherEnv } from "./watcher";
import { screenScan, dexTrackScan } from "./screen";
import { sessionGateScan } from "./sessiongate";
import { handleTapeIngest } from "./tape-ingest.js";
export { PumpTape } from "./pumptape";

// R-7 (AUDIT 2026-07-14): staleness watchdog. The DO-era monitor left with the
// RadarScanner DO (b5b32ff); this is the cheap replacement — one D1 read per
// tick, one LOUD greppable line when the tape stops writing while coins are
// live on screen. Observability only: it fixes nothing, it just refuses to let
// a blind eye stay silent (the 21min and 115min stalls were both silent).
const TAPE_STALE_MS = 4 * 60_000; // 4 missed passes at the 60s cadence
async function tapeWatchdog(env: WatcherEnv): Promise<void> {
  const row = await env.RADAR_DB.prepare(
    `SELECT (SELECT MAX(ms) FROM mc_ticks) AS freshest,
            (SELECT COUNT(*) FROM earlies    WHERE status='watching')
          + (SELECT COUNT(*) FROM candidates WHERE outcome='live') AS tracked`
  ).first<any>();
  const tracked = Number(row?.tracked ?? 0);
  if (tracked === 0) return; // nothing on screen -> a quiet tape is honest
  const freshest = row?.freshest == null ? null : Number(row.freshest);
  const ageMs = freshest === null ? null : Date.now() - freshest;
  if (ageMs === null || ageMs > TAPE_STALE_MS) {
    console.error(
      `RADAR_TAPE_STALE tracked=${tracked} freshest_tick_age_ms=${ageMs ?? "none"}` +
      ` — mc_ticks not advancing while coins are live on screen`,
    );
  }
}

// feed-status (2026-07-23): the CAUSE, captured. Each cron scan ran as
// `scan(env).catch(console.error)` — a failure went to the logs and nowhere the
// console could see it, so a ~10h birthScan/screenScan stall read as an unexplained
// "births frozen". `tracked` keeps the exact same fire-and-forget + log behavior,
// but also records each scan's last-ok / last-error into feed_status (D1), which
// /api/radar/health surfaces so the MIB DEBUG "feed" readout names which scan is
// failing and why. Never throws (so ctx.waitUntil stays safe); its own write is
// best-effort.
async function recordScan(env: WatcherEnv, scan: string, ms: number, err: unknown): Promise<void> {
  try {
    if (err == null) {
      await env.RADAR_DB.prepare(
        "INSERT INTO feed_status (scan,last_ok_ms) VALUES (?1,?2) ON CONFLICT(scan) DO UPDATE SET last_ok_ms=?2",
      ).bind(scan, ms).run();
    } else {
      const msg = String((err as any)?.message || err).slice(0, 300);
      await env.RADAR_DB.prepare(
        "INSERT INTO feed_status (scan,last_err_ms,last_err) VALUES (?1,?2,?3) ON CONFLICT(scan) DO UPDATE SET last_err_ms=?2, last_err=?3",
      ).bind(scan, ms, msg).run();
    }
  } catch (e) { console.error("recordScan", scan, e); }
}
function tracked(name: string, env: WatcherEnv, p: Promise<unknown>): Promise<void> {
  const ms = Date.now();
  return p.then(
    () => recordScan(env, name, ms, null),
    (e) => { console.error(name, e); return recordScan(env, name, ms, e); },
  );
}

let app: ReturnType<typeof buildTolledApp> | null = null;
let armedFor: string | null = null;

export default {
  // The per-minute jobs (RADAR_HANDOFF + later ratifications): birth scan
  // (feed -> births), discovery scan (DexScreener -> gap_ms / expiry), the
  // screen/tape, post-grad tracking, the BTC regime read, the staleness
  // watchdog, and the Layer 3 keepalive. Keyless, read-only, each isolated.
  async scheduled(_event: ScheduledEvent, env: WatcherEnv, ctx: ExecutionContext) {
    ctx.waitUntil(tracked("birthScan", env, birthScan(env)));
    ctx.waitUntil(tracked("discoveryScan", env, discoveryScan(env)));
    ctx.waitUntil(tracked("dexTrackScan", env, dexTrackScan(env)));
    ctx.waitUntil(tracked("btcScan", env, btcScan(env)));
    // §0 SESSION GATE: compute the regime reading (births/hr vs its 7d avg) and
    // write it to `sessions`. Self-cadenced (hourly by default — it no-ops the
    // other ~59 ticks/hr via a cheap freshest-reading read) and fail-soft, so
    // it's cheap to fire every tick. This is what lifts xtrade's §0 refusal:
    // /radar/session-gate now serves a real reading instead of NO_READING_YET.
    ctx.waitUntil(tracked("sessionGateScan", env, sessionGateScan(env)));
    // Tape scan: SINGLE-PASS per cron. One screenScan per minute uses ~1/4 the
    // CPU the old 4×15s sub-tick loop did, staying well under the 30s cron CPU
    // ceiling that was killing it. No Durable Object — the DO alarm approach
    // wouldn't deploy (build/migration failure), so we ship the simple verified
    // fix: reliable 60s, never blind. (15s via DO is a future task, with the
    // real deploy error in hand.)
    ctx.waitUntil(tracked("screenScan", env, screenScan(env)));
    // R-7: the staleness self-check (see tapeWatchdog above).
    ctx.waitUntil(tracked("tapeWatchdog", env, tapeWatchdog(env)));
    // Layer 3 keepalive: poke the DO every minute so the WS engine (re)connects
    // even after eviction. The DO's own alarm is the fast watchdog in between.
    // TAPE_HOST="railway" (board row 90): the subscriber moved to a host that
    // can hold a socket; the DO stays in code as the fallback seam but is NOT
    // poked, so the two never double-write. The Railway tape heartbeats the
    // same feed_status row through /radar/tape-ingest instead.
    ctx.waitUntil(tracked("pumptapeEnsure", env, (async () => {
      if ((env as any).TAPE_HOST === "railway") return;
      if (!env.PUMPTAPE) return;
      const stub = env.PUMPTAPE.get(env.PUMPTAPE.idFromName("main"));
      await stub.fetch("https://pumptape/ensure");
    })()));
    // THE DRAINING METER, surfaced (audit 2026-07-24). The DO's `connected` reads
    // true when the PumpPortal key drains below 0.02 SOL — the socket stays up and
    // births keep flowing, but the KEY-GATED trade stream dies, so the tape (the
    // referee every forward claim is graded against) silently stops accruing.
    // Read the DO's own verdict on the cron and land it in feed_status, which
    // /api/radar/health already reads: the MIB panel then NAMES it, on the phone,
    // the day it happens — instead of a hole in the tape discovered weeks later.
    // Recorded here rather than fetched on the health request path, so this costs
    // the request path nothing (see N-4).
    ctx.waitUntil((async () => {
      // TAPE_HOST="railway": the remote tape reports its own health verdict on
      // every ingest heartbeat — reading the dormant DO here would overwrite
      // the live diagnosis with a stale one.
      if ((env as any).TAPE_HOST === "railway") return;
      const ms = Date.now();
      try {
        if (!env.PUMPTAPE) return;
        const stub = env.PUMPTAPE.get(env.PUMPTAPE.idFromName("main"));
        const r = await stub.fetch("https://pumptape/status");
        const j: any = await r.json();
        const t = j && j.tape;
        if (!t) return;
        // "ok" clears the row; anything else is recorded as the CAUSE, verbatim
        // from the DO, so the console shows the diagnosis and not a bare flag.
        await recordScan(env, "pumptapeTrades", ms, t.status === "ok" ? null : new Error(`${t.status}: ${t.detail || ""}`));
      } catch (e) { console.error("pumptapeTrades", e); }
    })());
  },

  async fetch(request: Request, env: WatcherEnv, ctx: ExecutionContext): Promise<Response> {
    // The Railway tape's write path (board row 90). Handled here, before the
    // toll app, because it shares recordScan — every batch heartbeats the same
    // feed_status surface the console's health readout already names.
    if (request.method === "POST" && new URL(request.url).pathname === "/radar/tape-ingest") {
      return handleTapeIngest(request, env as any, recordScan as any);
    }
    // Rebuild only if the arming state changed (vars are static per deployment,
    // so in practice this builds once per isolate).
    const sink = (env.TOLL_SINK || "").toLowerCase();
    if (!app || armedFor !== sink) {
      app = buildTolledApp(env);
      armedFor = sink;
    }
    return app.fetch(request, env, ctx);
  },
};
