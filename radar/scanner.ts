// possessio-radar — scanner.ts: the RELIABLE 15s tape scan (Layer 3 driver).
//
// WHY THIS EXISTS (2026-07-13, after three failed cron fixes): a Cron Trigger
// gets ONE 30s-CPU budget per invocation, and waitUntil does NOT extend it
// (Cloudflare docs). The old 4×15s setTimeout sub-tick loop ran screenScan four
// times inside that single budget; as the coin set + tape grew, 4× crossed 30s
// and Cloudflare KILLED the invocation mid-run — the tape went blind (21min,
// then 115min) with no error, while the single-pass cron siblings never died.
//
// THE FIX (researched, not guessed): a Durable Object alarm. Each alarm fire is
// its OWN invocation with a FRESH 30s CPU budget, so one screenScan per 15s tick
// never stacks CPU. Alarms have guaranteed at-least-once execution and auto-
// retry on throw — and we arm the NEXT alarm BEFORE the fallible work, so even a
// throwing screenScan can never stop the clock. The minute cron pokes /ensure to
// re-arm if the alarm ever falls off (belt to the alarm's suspenders).
//
// The scan LOGIC is unchanged — this only swaps the DRIVER (cron -> DO alarm).
// screenScan already runs correctly single-pass; we just fire it reliably.

import { screenScan } from "./screen";
import type { WatcherEnv } from "./watcher";

const SCAN_INTERVAL_MS = 15_000;

export class RadarScanner {
  private state: DurableObjectState;
  private env: WatcherEnv;

  constructor(state: DurableObjectState, env: any) {
    this.state = state;
    // D1-in-DO shim (known Wrangler bug): env.RADAR_DB can be undefined inside a
    // Durable Object and instead bound at env.__D1_BETA__RADAR_DB. Resolve both
    // so screenScan's env.RADAR_DB always points at the real database.
    this.env = { ...env, RADAR_DB: env.RADAR_DB ?? env.__D1_BETA__RADAR_DB } as WatcherEnv;
  }

  // Poked by the minute cron: if no alarm is armed, kick one off shortly. This
  // is the watchdog that re-arms the loop if an alarm is ever lost.
  async fetch(req: Request): Promise<Response> {
    if (new URL(req.url).pathname === "/ensure") {
      const cur = await this.state.storage.getAlarm();
      if (cur === null) await this.state.storage.setAlarm(Date.now() + 1_000);
      return new Response("armed");
    }
    return new Response("radar-scanner");
  }

  async alarm(): Promise<void> {
    // Arm the NEXT tick FIRST — a throw in screenScan can never stop the clock.
    await this.state.storage.setAlarm(Date.now() + SCAN_INTERVAL_MS);
    try {
      await screenScan(this.env);
    } catch (e) {
      console.error("RadarScanner screenScan", e); // logged; retry/next tick covers it
    }
  }
}
