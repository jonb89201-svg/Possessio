// possessio-radar Worker entry. The toll'd read-API over the live D1 ledger
// (possessio-radar-ledger). The WATCHER (pump.fun feed poller writing births/
// sessions) is a separate module, VERIFY-FIRST, not yet landed — this worker
// serves the measurements that already exist and arms the sell-side toll the
// moment the wave writes TOLL_SINK.
import { buildTolledApp } from "./x402-toll";
import { birthScan, discoveryScan, btcScan, type WatcherEnv } from "./watcher";
import { screenScan, dexTrackScan } from "./screen";
export { PumpTape } from "./pumptape";

let app: ReturnType<typeof buildTolledApp> | null = null;
let armedFor: string | null = null;

export default {
  // Two jobs per minute (RADAR_HANDOFF): birth scan (feed -> births) and
  // discovery scan (DexScreener -> gap_ms / expiry). Keyless, read-only.
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
