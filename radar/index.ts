// possessio-radar Worker entry. The toll'd read-API over the live D1 ledger
// (possessio-radar-ledger). The WATCHER (pump.fun feed poller writing births/
// sessions) is a separate module, VERIFY-FIRST, not yet landed — this worker
// serves the measurements that already exist and arms the sell-side toll the
// moment the wave writes TOLL_SINK.
import { buildTolledApp } from "./x402-toll";
import { birthScan, discoveryScan, btcScan, type WatcherEnv } from "./watcher";
import { screenLoop, dexTrackScan } from "./screen";
export { PumpTape } from "./pumptape";

let app: ReturnType<typeof buildTolledApp> | null = null;
let armedFor: string | null = null;

export default {
  // Two jobs per minute (RADAR_HANDOFF): birth scan (feed -> births) and
  // discovery scan (DexScreener -> gap_ms / expiry). Keyless, read-only.
  async scheduled(_event: ScheduledEvent, env: WatcherEnv, ctx: ExecutionContext) {
    ctx.waitUntil(birthScan(env).catch((e) => console.error("birthScan", e)));
    ctx.waitUntil(discoveryScan(env).catch((e) => console.error("discoveryScan", e)));
    ctx.waitUntil(screenLoop(env).catch((e) => console.error("screenLoop", e)));
    ctx.waitUntil(dexTrackScan(env).catch((e) => console.error("dexTrackScan", e)));
    ctx.waitUntil(btcScan(env).catch((e) => console.error("btcScan", e)));
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
