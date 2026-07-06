// possessio-radar Worker entry. The toll'd read-API over the live D1 ledger
// (possessio-radar-ledger). The WATCHER (pump.fun feed poller writing births/
// sessions) is a separate module, VERIFY-FIRST, not yet landed — this worker
// serves the measurements that already exist and arms the sell-side toll the
// moment the wave writes TOLL_SINK.
import { buildTolledApp, type Env } from "./x402-toll";

let app: ReturnType<typeof buildTolledApp> | null = null;
let armedFor: string | null = null;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
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
