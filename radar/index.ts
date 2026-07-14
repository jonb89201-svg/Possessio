// possessio-radar Worker entry. The toll'd read-API over the live D1 ledger
// (possessio-radar-ledger) PLUS the per-minute jobs below. The watcher
// (pump.fun feed poller writing births) LANDED 2026-07-06; the screen, tape,
// and post-grad tracker followed. This worker serves the measurements and
// arms the sell-side toll the moment the wave writes TOLL_SINK.
import { buildTolledApp } from "./x402-toll";
import { birthScan, discoveryScan, btcScan, type WatcherEnv } from "./watcher";
import { screenScan, dexTrackScan } from "./screen";
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

let app: ReturnType<typeof buildTolledApp> | null = null;
let armedFor: string | null = null;

export default {
  // The per-minute jobs (RADAR_HANDOFF + later ratifications): birth scan
  // (feed -> births), discovery scan (DexScreener -> gap_ms / expiry), the
  // screen/tape, post-grad tracking, the BTC regime read, the staleness
  // watchdog, and the Layer 3 keepalive. Keyless, read-only, each isolated.
  async scheduled(_event: ScheduledEvent, env: WatcherEnv, ctx: ExecutionContext) {
    ctx.waitUntil(birthScan(env).catch((e) => console.error("birthScan", e)));
    ctx.waitUntil(discoveryScan(env).catch((e) => console.error("discoveryScan", e)));
    ctx.waitUntil(dexTrackScan(env).catch((e) => console.error("dexTrackScan", e)));
    ctx.waitUntil(btcScan(env).catch((e) => console.error("btcScan", e)));
    // Tape scan: SINGLE-PASS per cron. One screenScan per minute uses ~1/4 the
    // CPU the old 4×15s sub-tick loop did, staying well under the 30s cron CPU
    // ceiling that was killing it. No Durable Object — the DO alarm approach
    // wouldn't deploy (build/migration failure), so we ship the simple verified
    // fix: reliable 60s, never blind. (15s via DO is a future task, with the
    // real deploy error in hand.)
    ctx.waitUntil(screenScan(env).catch((e) => console.error("screenScan", e)));
    // R-7: the staleness self-check (see tapeWatchdog above).
    ctx.waitUntil(tapeWatchdog(env).catch((e) => console.error("tapeWatchdog", e)));
    // Layer 3 keepalive: poke the DO every minute so the WS engine (re)connects
    // even after eviction. The DO's own alarm is the fast watchdog in between.
    ctx.waitUntil((async () => {
      if (!env.PUMPTAPE) return;
      const stub = env.PUMPTAPE.get(env.PUMPTAPE.idFromName("main"));
      await stub.fetch("https://pumptape/ensure");
    })().catch((e) => console.error("pumptape ensure", e)));
  },

  async fetch(request: Request, env: WatcherEnv, ctx: ExecutionContext): Promise<Response> {
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
