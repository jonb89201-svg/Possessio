// possessio-radar — screen.ts: the §1 screened-candidate feed.
//
// §4 COMPLIANCE (rulebook, binding): holds NO keys, signs NOTHING, trades
// NOTHING. This is paper-only observation — it screens the live 'watching' set
// against RULEBOOK §1 and records what happens next, so the ledger kills or
// confirms the method (§7). No order is ever placed. "There is no state in
// which a key exists and the rulebook does not."
//
// RATIFIED SURFACE (Architect, 2026-07-11, Amendment IV Clause 5): the screened
// SELECTION is public — it promotes the x402Core autonomous trader and feeds
// the pool. It shows WHICH coins clear the screen, never entry/exit prices or
// size. Supersedes the older "no watching rows" boundary for the candidate
// feed only.
//
// §1 numbers are the ratified method. The entry band matches the 8-13k the
// codebase already uses. Band + session/rug cutoffs are ledger-tunable (§7),
// never changed at trade time.

import type { WatcherEnv } from "./watcher";

const AGE_MIN_MS  = 4 * 60_000;   // §1: past the instant-rug window
const AGE_MAX_MS  = 7 * 60_000;   // §1: before stale
const ENTRY_LOW   = 8_000;        // §1 "~$10k" entry band (8-13k, ledger-tunable §7)
const ENTRY_HIGH  = 13_000;
const TARGET_MC   = 20_000;       // §1 exit #1 — take-profit (~2x)
const STOP_MC     = 6_000;        // §1 exit #2 — stop-loss
const TIMESTOP_MS = 10 * 60_000;  // §1 exit #4 — time-stop

// Screen 0 — the EARLY radar (Architect, 2026-07-11, multi-screen method):
// age 0-4min, coin crosses $4k MC -> early-watch list. Gives the human a look
// BEFORE the §1 window opens, and starts the oscillation tape early.
const EARLY_MC        = 4_000;
const EARLY_MAX_AGE   = AGE_MIN_MS;      // screen 0 closes where screen 1 opens
const TICKS_KEEP_MS   = 48 * 3600_000;   // tape retention (matches DEX_TRACK_WINDOW)

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

// Current MC per token from DexScreener, batched 30 addresses/request (the
// pattern discoveryScan proved: R-2 batching, R-4 max-across-pairs MC, polite
// stop on 429). On-screen sets are small (<=80), so this is 1-3 requests per
// screen pass — x4 sub-ticks stays far under DexScreener's 300 req/min.
async function fetchDexMc(env: WatcherEnv, addrs: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  for (let i = 0; i < addrs.length; i += 30) {
    const chunk = addrs.slice(i, i + 30);
    const res = await fetch(env.DEXSCREENER_TOKEN_URL + chunk.join(","), {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
    });
    if (res.status === 429) break;
    if (!res.ok) continue;
    const data: any = await res.json();
    for (const p of (data?.pairs ?? []) as any[]) {
      const base = p?.baseToken?.address;
      if (!base) continue;
      const m = numOrNull(p?.marketCap ?? p?.fdv);
      if (m !== null && m > (out.get(base) ?? -1)) out.set(base, m);
    }
  }
  return out;
}

function setOutcome(env: WatcherEnv, addr: string, outcome: string, now: number, lastMc: number | null) {
  return env.RADAR_DB.prepare(
    `UPDATE candidates
        SET outcome=?2, outcome_ms=?3,
            last_mc=COALESCE(?4, last_mc), last_tracked_ms=?3,
            peak_mc=MAX(COALESCE(peak_mc,0), COALESCE(?4,0))
      WHERE token_address=?1 AND outcome='live'`
  ).bind(addr, outcome, now, lastMc);
}

// LAYER 1 latency fix (Architect, 2026-07-11): cron's floor is 1 minute, which
// left the feed up to 60s behind the curve. Each cron invocation now runs the
// screen 4x spaced 15s (t=0,15,30,45; next cron lands at t=60), so staleness
// drops to <=15s and the oscillation tape gets 15s resolution — no new infra.
// Layers 2+3 (Durable Object alarm / PumpPortal WS real-time) are the upgrade
// path, VERIFY-FIRST gated, with this loop as the permanent bedrock fallback.
const SUB_TICKS = 4;
const SUB_TICK_GAP_MS = 15_000;

export async function screenLoop(env: WatcherEnv): Promise<void> {
  for (let i = 0; i < SUB_TICKS; i++) {
    if (i) await new Promise((r) => setTimeout(r, SUB_TICK_GAP_MS));
    await screenScan(env).catch((e) => console.error("screenScan", e));
  }
}

export async function screenScan(env: WatcherEnv): Promise<void> {
  if (!env.PUMPFUN_FEED_URL) {
    console.warn("PUMPFUN_FEED_URL unset — screenScan idle");
    return;
  }
  const now = Date.now();

  // Live curve MC per mint, from the same pump.fun feed birthScan reads.
  //
  // EMPIRICAL LIMIT (2026-07-11, live tape): this newest-first window does NOT
  // reliably contain a coin past age ~5min REGARDLESS of the limit param —
  // limit=1000 was deployed and candidates still froze (entry==peak==last)
  // while DexScreener's curve pair showed real movement (Cumshot hit $26.9k —
  // a target hit — while this feed read absent and the ledger timestopped it).
  // The server evidently clamps the window. Therefore: this feed DETECTS
  // (newborns sit at its top — Screen 0 + §1 qualify, proven firing), and the
  // DexScreener curve pair TRACKS (mcOf below — same source discoveryScan's
  // R-4 peak already trusts).
  const res = await fetch(env.PUMPFUN_FEED_URL, {
    headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
  });
  if (!res.ok) { console.warn("screen feed", res.status); return; }
  const body: any = await res.json();
  const items: any[] = Array.isArray(body) ? body : body?.coins ?? body?.data ?? [];
  const mcNow = new Map<string, number>();
  for (const it of items) {
    const addr = it.mint ?? it.address ?? it.tokenAddress;
    const mc = numOrNull(it.usd_market_cap ?? it.marketCapUsd);
    if (addr && mc !== null) mcNow.set(addr, mc);
  }

  const stmts: any[] = [];

  // (0) EARLY SCREEN: 'watching' tokens younger than 4 min whose curve MC has
  //     crossed $4k. First crossing wins (INSERT ... DO NOTHING keeps the
  //     original hit time/MC). This list is display + tape-start only — it
  //     gates nothing; §1 qualification below is untouched.
  const { results: newborns } = await env.RADAR_DB.prepare(
    `SELECT token_address, symbol, name, pumpfun_first_seen_ms
       FROM births
      WHERE status='watching'
        AND pumpfun_first_seen_ms > ?1
        AND token_address NOT IN (SELECT token_address FROM earlies)`
  ).bind(now - EARLY_MAX_AGE).all();

  for (const r of newborns as any[]) {
    const mc = mcNow.get(r.token_address as string);
    if (mc === undefined || mc < EARLY_MC) continue;
    const ageSec = Math.round((now - Number(r.pumpfun_first_seen_ms)) / 1000);
    stmts.push(env.RADAR_DB.prepare(
      `INSERT INTO earlies
         (token_address, symbol, name, first_hit_ms, first_hit_mc, age_sec_at_hit, status)
       VALUES (?1,?2,?3,?4,?5,?6,'watching')
       ON CONFLICT(token_address) DO NOTHING`
    ).bind(r.token_address, r.symbol ?? null, r.name ?? null, now, mc, ageSec));
  }

  // Early status transitions: 'qualified' when §1 picked it up; 'missed' when
  // it aged past the §1 window without qualifying. Terminal either way.
  stmts.push(env.RADAR_DB.prepare(
    `UPDATE earlies SET status='qualified', status_ms=?1
      WHERE status='watching'
        AND token_address IN (SELECT token_address FROM candidates)`
  ).bind(now));
  stmts.push(env.RADAR_DB.prepare(
    `UPDATE earlies SET status='missed', status_ms=?1
      WHERE status='watching'
        AND token_address IN (SELECT token_address FROM births
                               WHERE pumpfun_first_seen_ms < ?2)
        AND token_address NOT IN (SELECT token_address FROM candidates)`
  ).bind(now, now - AGE_MAX_MS));

  // THE TAPE ("oscillating in-between the two screens and after the last
  // screen"): one MC sample per tick for every coin currently on either
  // screen — earlies still watching + candidates still live. Read-time
  // oscillators (sparkline, ROC) are computed from this, never stored.
  const { results: tapeSet } = await env.RADAR_DB.prepare(
    `SELECT token_address FROM earlies WHERE status='watching'
      UNION
     SELECT token_address FROM candidates WHERE outcome='live'`
  ).all();

  // TRACKING SOURCE OF RECORD: DexScreener curve pair for everything on
  // screen (small set, one batched request per ~30), pump.fun window as
  // fallback for coins DexScreener hasn't indexed yet. See EMPIRICAL LIMIT
  // note above — the pump.fun window alone froze every candidate.
  const trackAddrs = (tapeSet as any[]).map((r) => r.token_address as string);
  const mcDex = trackAddrs.length ? await fetchDexMc(env, trackAddrs) : new Map<string, number>();
  const mcOf = (a: string): number | null => mcDex.get(a) ?? mcNow.get(a) ?? null;

  for (const r of tapeSet as any[]) {
    const mc = mcOf(r.token_address as string);
    if (mc === null) continue;
    stmts.push(env.RADAR_DB.prepare(
      `INSERT INTO mc_ticks (token_address, ms, mc) VALUES (?1,?2,?3)
       ON CONFLICT(token_address, ms) DO NOTHING`
    ).bind(r.token_address, now, mc));
  }
  stmts.push(env.RADAR_DB.prepare(
    `DELETE FROM mc_ticks WHERE ms < ?1`
  ).bind(now - TICKS_KEEP_MS));

  // (1) QUALIFY: 'watching' tokens aged 4-7 min, current curve MC in-band, not
  //     already tracked. Pre-DEX is implied by status='watching'.
  const { results: young } = await env.RADAR_DB.prepare(
    `SELECT token_address, symbol, name, creator, pumpfun_first_seen_ms
       FROM births
      WHERE status='watching'
        AND pumpfun_first_seen_ms <= ?1
        AND pumpfun_first_seen_ms >= ?2
        AND token_address NOT IN (SELECT token_address FROM candidates)`
  ).bind(now - AGE_MIN_MS, now - AGE_MAX_MS).all();

  for (const r of young as any[]) {
    const mc = mcNow.get(r.token_address as string);
    if (mc === undefined || mc < ENTRY_LOW || mc > ENTRY_HIGH) continue;
    const ageSec = Math.round((now - Number(r.pumpfun_first_seen_ms)) / 1000);
    stmts.push(env.RADAR_DB.prepare(
      `INSERT INTO candidates
         (token_address, symbol, name, creator, qualified_ms, entry_age_sec,
          entry_mc, gate_age, gate_mc, gate_predex, gate_rug, gate_session,
          peak_mc, peak_ms, last_mc, last_tracked_ms, outcome)
       VALUES (?1,?2,?3,?4,?5,?6,?7,1,1,1,NULL,NULL,?7,?5,?7,?5,'live')
       ON CONFLICT(token_address) DO NOTHING`
    ).bind(r.token_address, r.symbol ?? null, r.name ?? null, r.creator ?? null, now, ageSec, mc));
  }

  // (2) TRACK live candidates against the §1 exit ladder. First trigger wins.
  const { results: liveC } = await env.RADAR_DB.prepare(
    `SELECT c.token_address, c.peak_mc, b.status AS bstatus, b.pumpfun_first_seen_ms AS born
       FROM candidates c JOIN births b ON b.token_address=c.token_address
      WHERE c.outcome='live'`
  ).all();

  for (const c of liveC as any[]) {
    const addr = c.token_address as string;
    const mc = mcOf(addr);
    const age = now - Number(c.born);

    if (c.bstatus === "discovered") {               // §1 #3 edge-loss: graduated
      stmts.push(setOutcome(env, addr, "graduated", now, mc));
    } else if (mc !== null && mc >= TARGET_MC) {    // §1 #1 take-profit
      stmts.push(setOutcome(env, addr, "target", now, mc));
    } else if (mc !== null && mc <= STOP_MC) {      // §1 #2 stop-loss
      stmts.push(setOutcome(env, addr, "stop", now, mc));
    } else if (age >= TIMESTOP_MS) {                // §1 #4 time-stop
      stmts.push(setOutcome(env, addr, "timestop", now, mc));
    } else if (mc !== null) {                       // still live — update trackers
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE candidates
            SET last_mc=?2, last_tracked_ms=?3,
                peak_ms=CASE WHEN ?2 > COALESCE(peak_mc,0) THEN ?3 ELSE peak_ms END,
                peak_mc=MAX(COALESCE(peak_mc,0), ?2)
          WHERE token_address=?1`
      ).bind(addr, mc, now));
    }
  }

  if (stmts.length) await env.RADAR_DB.batch(stmts);
}

// dexTrackScan: the SECOND half of a candidate's life. Once a candidate has
// graduated (births.status='discovered' -> it's on DexScreener), keep pulling
// its live DEX metrics — price, MC, liquidity, 1h volume, 5m/1h change — so the
// feed shows the continuous journey past the DEX boundary. This is display /
// intelligence only; the §1 paper trade already closed at graduation.
const DEX_TRACK_WINDOW_MS = 48 * 3600_000; // enrich for 48h after qualifying

export async function dexTrackScan(env: WatcherEnv): Promise<void> {
  const now = Date.now();
  const { results } = await env.RADAR_DB.prepare(
    `SELECT c.token_address
       FROM candidates c JOIN births b ON b.token_address=c.token_address
      WHERE b.status='discovered' AND c.qualified_ms >= ?1
      ORDER BY COALESCE(c.dex_last_ms, 0) ASC
      LIMIT 90`
  ).bind(now - DEX_TRACK_WINDOW_MS).all();

  const addrs = (results as any[]).map((r) => r.token_address as string);
  if (!addrs.length) return;

  const stmts: any[] = [];
  for (let i = 0; i < addrs.length; i += 30) {
    const chunk = addrs.slice(i, i + 30);
    const res = await fetch(env.DEXSCREENER_TOKEN_URL + chunk.join(","), {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
    });
    if (res.status === 429) break;
    if (!res.ok) continue;
    const data: any = await res.json();

    // pick the most-liquid NON-curve (real DEX) pair per token
    const best = new Map<string, any>();
    for (const p of (data?.pairs ?? []) as any[]) {
      const base = p?.baseToken?.address;
      if (!base || p?.dexId === "pumpfun") continue;
      const liq = numOrNull(p?.liquidity?.usd) ?? 0;
      const prev = best.get(base);
      if (!prev || liq > (numOrNull(prev?.liquidity?.usd) ?? 0)) best.set(base, p);
    }

    for (const addr of chunk) {
      const p = best.get(addr);
      if (!p) continue;
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE candidates SET
            graduated_ms = COALESCE(graduated_ms, ?2),
            dex_price_usd = ?3, dex_mc = ?4, dex_liq_usd = ?5,
            dex_vol_h1 = ?6, dex_chg_m5 = ?7, dex_chg_h1 = ?8, dex_last_ms = ?2
          WHERE token_address = ?1`
      ).bind(
        addr, now,
        numOrNull(p?.priceUsd),
        numOrNull(p?.marketCap ?? p?.fdv),
        numOrNull(p?.liquidity?.usd),
        numOrNull(p?.volume?.h1),
        numOrNull(p?.priceChange?.m5),
        numOrNull(p?.priceChange?.h1),
      ));
    }
  }
  if (stmts.length) await env.RADAR_DB.batch(stmts);
}
