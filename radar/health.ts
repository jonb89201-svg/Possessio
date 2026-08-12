// health.ts — the LOUD verdict over feed_status (RESEARCH_RadarMethod §5).
//
// WHY THIS EXISTS: the tape died 2026-08-10 (PumpPortal key drained below
// 0.02 SOL — it degrades SILENTLY; the socket stays up) and sat under a green
// banner for ~50 hours because nothing ESCALATED feed_status staleness. That is
// a False Green — the exact heresy the laws name, predicted in board row 90
// ("a persistent failure sitting under a green banner"). This module turns
// feed_status into a verdict that names the dead feed and its age, so silent
// degradation is structurally impossible to miss.
//
// Pure function, no I/O — offline-testable (fastlane.test.mjs).

export interface FeedStatusRow {
  scan: string;
  last_ok_ms: number | null;
  last_err_ms: number | null;
  last_err: string | null;
}

export interface ScanVerdict {
  scan: string;
  ok: boolean;
  critical: boolean;
  age_s: number | null;      // seconds since last OK (null = never OK)
  err: string | null;        // the recorded cause, verbatim, when not ok
}

export interface HealthVerdict {
  overall: "green" | "yellow" | "red";
  reason: string;            // one line naming the worst offender, for the MIB panel
  scans: ScanVerdict[];
}

// Expected cadence per scan. Crons fire every 60s; 5min = 5 missed passes.
// pumptapeTrades heartbeats per ingest batch (seconds apart when alive) — 15min
// is generous; 50 HOURS is what this module exists to make impossible to miss.
const EXPECT: Record<string, { maxAgeMs: number; critical: boolean }> = {
  birthScan:       { maxAgeMs: 5 * 60_000,  critical: true  },
  screenScan:      { maxAgeMs: 5 * 60_000,  critical: true  },
  discoveryScan:   { maxAgeMs: 5 * 60_000,  critical: true  },
  dexTrackScan:    { maxAgeMs: 10 * 60_000, critical: true  },
  pumptapeTrades:  { maxAgeMs: 15 * 60_000, critical: true  },
  btcScan:         { maxAgeMs: 10 * 60_000, critical: false },
  sessionGateScan: { maxAgeMs: 2 * 3600_000, critical: false },
  tapeWatchdog:    { maxAgeMs: 10 * 60_000, critical: false },
  pumptapeEnsure:  { maxAgeMs: 10 * 60_000, critical: false },
};

export function healthVerdict(
  rows: FeedStatusRow[],
  nowMs: number,
  tapeHost?: string,
): HealthVerdict {
  const byScan = new Map(rows.map((r) => [r.scan, r]));
  const scans: ScanVerdict[] = [];

  for (const [scan, exp] of Object.entries(EXPECT)) {
    // TAPE_HOST="railway" (board row 90): the local DO is dormant by design —
    // its keepalive row is meaningless there and must not color the verdict.
    if (scan === "pumptapeEnsure" && tapeHost === "railway") continue;

    const r = byScan.get(scan);
    const okMs = r?.last_ok_ms ?? null;
    const age = okMs === null ? null : nowMs - okMs;
    // A scan whose LATEST run errored is not ok even if a recent OK exists.
    const errLatest = r != null && r.last_err_ms != null && (okMs === null || r.last_err_ms > okMs);
    const stale = age === null || age > exp.maxAgeMs;
    scans.push({
      scan,
      ok: !stale && !errLatest,
      critical: exp.critical,
      age_s: age === null ? null : Math.round(age / 1000),
      err: (stale || errLatest) ? (r?.last_err ?? (age === null ? "never ran" : null)) : null,
    });
  }

  const bad = scans.filter((s) => !s.ok);
  const badCritical = bad.filter((s) => s.critical);
  const overall = badCritical.length > 0 ? "red" : bad.length > 0 ? "yellow" : "green";
  const worst = badCritical[0] ?? bad[0];
  const reason = worst
    ? `${worst.scan} ${worst.age_s === null ? "never ran" : `silent ${fmtAge(worst.age_s)}`}${worst.err ? ` — ${worst.err.slice(0, 140)}` : ""}`
    : "all feeds current";
  return { overall, reason, scans };
}

function fmtAge(s: number): string {
  if (s < 120) return `${s}s`;
  if (s < 7200) return `${Math.round(s / 60)}m`;
  return `${(s / 3600).toFixed(1)}h`;
}
