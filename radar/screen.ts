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
// coin crosses the entry MC before 4min -> early-watch list. Gives the human
// a look BEFORE the §1 window opens, and starts the oscillation tape early.
// 4000 -> 3500 with the §0 v3 ladder ratification (entry = $3.5k crossing).
const EARLY_MC        = 3_500;
const EARLY_MAX_AGE   = AGE_MIN_MS;      // screen 0 closes where screen 1 opens
const TICKS_KEEP_MS   = 48 * 3600_000;   // tape retention (matches DEX_TRACK_WINDOW)

// §0 v3 LADDER on the FREE 15s tape (ws=0 rows). Same ratified rungs as
// pumptape.ts; single-level only (the CYCLE needs trade resolution — see the
// scorer note below). soldValue/soldFrac are pure functions of rungs_filled,
// so no accumulator columns are needed to resume across stateless ticks.
const LADDER_RUNGS  = [6_000, 8_000, 10_000, 12_000];
const LADDER_FRACS  = [0.5, 0.25, 0.125, 0.125];
const LADDER_FULL_VALUE = LADDER_RUNGS.reduce((s, mc, i) => s + LADDER_FRACS[i] * mc, 0); // 7750
const ladderSoldValue = (k: number) =>
  LADDER_RUNGS.slice(0, k).reduce((s, mc, i) => s + LADDER_FRACS[i] * mc, 0);
const ladderSoldFrac = (k: number) =>
  LADDER_FRACS.slice(0, k).reduce((s, f) => s + f, 0);
const PLAY_EXIT_AGE_MS = 2 * 60_000;

// CONVICTION forward self-check (migration 0016). The "bucket C" entry
// hypothesis, stamped at the first-8k-crossing tick and graded later against
// the realized peak. Frozen thresholds applied to coins the derivation never
// saw = genuine forward validation. Thresholds mirror feed.ts conviction()
// exactly; both read curve reserves (sol_reserves) so there is no cross-feed
// artifact. Ledger-tunable (§7) — but freezing them is the whole point here.
const CONV_BAND      = 7_500;   // the "~$8k crossing"
const CONV_DEPTH_MIN = 22;      // floor: ZERO winners below this in the backtest
const CONV_VEL_LO    = 10;      // bucket-C velocity band (deliberate ~2-tick climb)
const CONV_VEL_HI    = 16;      // above = bot-spike; below CONV_VEL_LO = slow grind
const CONV_STAMP_WINDOW_MS = 30 * 60_000; // only consider recently-born earlies

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

// MC computed from first principles off the constant-product bonding-curve
// reserves in the feed item, priced with a market-wide SOL/USD. Deterministic;
// verified to 5 decimals vs pump.fun's own market_cap field (2026-07-11).
// Returns null if reserves are absent or solUsd is unknown (caller falls back).
function curveMcUsd(it: any, solUsd: number | null): number | null {
  if (solUsd === null) return null;
  const vsol = numOrNull(it.virtual_sol_reserves);
  const vtok = numOrNull(it.virtual_token_reserves);
  const supply = numOrNull(it.total_supply);
  if (vsol === null || vtok === null || supply === null || vtok <= 0) return null;
  // order matters: vsol*supply (~3e25) would blow past JS's 2^53 safe-integer
  // range, so divide first — (vsol/vtok)≈2.8e-5, ×supply≈2.8e10, all safe.
  const mcSol = (vsol / vtok) * supply / 1e9; // → SOL
  return mcSol * solUsd;
}

// Current MC per token from DexScreener, batched 30 addresses/request (the
// pattern discoveryScan proved: R-2 batching, R-4 max-across-pairs MC, polite
// stop on 429). On-screen sets are small (<=80), so this is 1-3 requests per
// screen pass — x4 sub-ticks stays far under DexScreener's 300 req/min.
async function fetchDexMc(
  env: WatcherEnv, addrs: string[],
): Promise<{ mc: Map<string, number>; volM5: Map<string, number> }> {
  const mc = new Map<string, number>();
  const volM5 = new Map<string, number>();
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
      if (m !== null && m > (mc.get(base) ?? -1)) mc.set(base, m);
      const v = numOrNull(p?.volume?.m5);
      if (v !== null && v > (volM5.get(base) ?? -1)) volM5.set(base, v);
    }
  }
  return { mc, volM5 };
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

// 15s FEED (Architect call, 2026-07-12): 4 passes per cron spaced 15s gives the
// tape 15s resolution — the resolution needed to catch fast movers live and
// trade them by hand. KNOWN LIMITATION: the 45s setTimeout-in-waitUntil hold
// can stall the scan after ~4h of unattended runtime (it went blind overnight
// once). Operationally that's a non-issue: a redeploy at the start of a trading
// session gives a fresh ~4h window, which covers a session — refresh on sign-on.
// The permanent non-stalling sub-minute path is the DO-alarm (Layer 3), built
// when there's time/money to verify it. For now: 15s live, refresh per session.
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
  // VOLUME track (VERIFY-FIRST vs our own raw_birth_json, 2026-07-11):
  // real_sol_reserves = actual SOL in the bonding curve, in lamports. Its
  // tick-to-tick delta IS net buy flow — buys add, sells drain. This is the
  // "steady volume increase" signal, and it lives in the newborn window
  // (age 0-5min) where this feed demonstrably works.
  const solNow = new Map<string, number>();
  // SOL/USD is a market-wide constant, so derive it ONCE from any coin's
  // usd_market_cap / market_cap ratio. The ratio cancels the (possibly stale)
  // curve term and leaves pure SOL price — verified ~$77.08, identical across
  // coins (2026-07-11). We then re-price our OWN curve read with it.
  let solUsd: number | null = null;
  for (const it of items) {
    const mcUsd = numOrNull(it.usd_market_cap ?? it.marketCapUsd);
    const mcSol = numOrNull(it.market_cap);
    if (mcUsd !== null && mcSol !== null && mcSol > 0) {
      const p = mcUsd / mcSol;
      if (p > 1 && p < 100_000) { solUsd = p; break; }
    }
  }
  for (const it of items) {
    const addr = it.mint ?? it.address ?? it.tokenAddress;
    if (!addr) continue;
    // FIRST-PRINCIPLES MC (verified against 3 payloads to 5 decimals,
    // 2026-07-11): market cap IS a deterministic function of the constant-
    // product bonding-curve reserves —
    //   MC_sol = virtual_sol_reserves / virtual_token_reserves × total_supply / 1e9
    // We compute it ourselves from the raw reserves in the SAME payload and
    // price it with solUsd, rather than trusting their pre-computed (and
    // possibly cached/rounded) usd_market_cap field. Same snapshot freshness,
    // purest read. Falls back to their field only if reserves are missing.
    const mc = curveMcUsd(it, solUsd) ?? numOrNull(it.usd_market_cap ?? it.marketCapUsd);
    if (mc !== null) mcNow.set(addr, mc);
    const sol = numOrNull(it.real_sol_reserves);
    if (sol !== null) solNow.set(addr, sol / 1e9); // lamports -> SOL
  }
  if (solUsd !== null && env.PUMPTAPE) {
    // keep the (dormant) Layer 3 engine priced too
    const stub = env.PUMPTAPE.get(env.PUMPTAPE.idFromName("main"));
    stub.fetch("https://pumptape/solusd", {
      method: "POST", body: JSON.stringify({ solUsd }),
    }).catch((e) => console.error("pumptape solusd", e));
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
  const dex = trackAddrs.length ? await fetchDexMc(env, trackAddrs)
    : { mc: new Map<string, number>(), volM5: new Map<string, number>() };
  const mcOf = (a: string): number | null => dex.mc.get(a) ?? mcNow.get(a) ?? null;

  for (const r of tapeSet as any[]) {
    const addr = r.token_address as string;
    const mc = mcOf(addr);
    if (mc === null) continue;
    stmts.push(env.RADAR_DB.prepare(
      `INSERT INTO mc_ticks (token_address, ms, mc, sol_reserves, vol_m5)
       VALUES (?1,?2,?3,?4,?5)
       ON CONFLICT(token_address, ms) DO NOTHING`
    ).bind(addr, now, mc, solNow.get(addr) ?? null, dex.volM5.get(addr) ?? null));
  }
  stmts.push(env.RADAR_DB.prepare(
    `DELETE FROM mc_ticks WHERE ms < ?1`
  ).bind(now - TICKS_KEEP_MS));

  // (0.4) CONVICTION STAMP (forward self-check, migration 0016). The FIRST time
  //       a recently-born watched early is seen at/above the ~$8k band, record
  //       the conviction tag it earns AT THAT INSTANT — immutable, hindsight-
  //       free (depth = curve reserves now; velocity = depth / ticks-since-
  //       first-seen, tape rows INCLUDING this tick). Graded later in
  //       /radar/candidates against the coin's realized peak. This is the
  //       radar judging its own entry hypothesis on coins it hadn't seen when
  //       the thresholds were set — the honest test the in-sample backtest owed.
  const { results: unstamped } = await env.RADAR_DB.prepare(
    `SELECT e.token_address,
            (SELECT COUNT(*) FROM mc_ticks m WHERE m.token_address=e.token_address) AS nticks
       FROM earlies e
      WHERE e.conv_tag IS NULL AND e.first_hit_ms > ?1`
  ).bind(now - CONV_STAMP_WINDOW_MS).all();
  for (const e of unstamped as any[]) {
    const addr = e.token_address as string;
    const mc = mcOf(addr);
    const depth = solNow.get(addr);
    // wait until it's in-band AND we have a curve reserve read for the crossing
    if (mc === null || mc < CONV_BAND || depth === undefined) continue;
    const ticks = Number(e.nticks) + 1; // +1: this tick's tape row is in the pending batch
    const vel = depth / ticks;
    const tag = depth < CONV_DEPTH_MIN ? "thin"
      : vel >= CONV_VEL_HI ? "bot"
      : vel >= CONV_VEL_LO ? "go"
      : "slow";
    stmts.push(env.RADAR_DB.prepare(
      `UPDATE earlies SET conv_tag=?2, conv_depth=?3, conv_vel=?4, conv_ms=?5, conv_entry_mc=?6
         WHERE token_address=?1 AND conv_tag IS NULL`
    ).bind(addr, tag, depth, vel, now, mc));
  }

  // (0.5) §0 v3 LADDER scoring on the FREE 15s tape (ws=0 rows). The ratified
  //       ladder — buy $3.5k, scale out 50/25/12.5/12.5 @ 6/8/10/12k, remainder
  //       at coin-age 2:00 — scores honestly at 15s (these MC crossings are
  //       slow enough to catch). The multi-level CYCLE (dip re-buy, octave up)
  //       needs trade resolution and stays pumptape.ts-only; NOT faked here.
  //       rungs_filled is the only persisted state — soldValue/soldFrac are
  //       recomputed from it deterministically (fixed rung prices × fracs).
  const { results: plays } = await env.RADAR_DB.prepare(
    `SELECT token_address, first_hit_ms, first_hit_mc, age_sec_at_hit,
            COALESCE(rungs_filled,0) AS rungs
       FROM earlies WHERE play_outcome IS NULL AND COALESCE(ws,0)=0`
  ).all();
  for (const e of plays as any[]) {
    const addr = e.token_address as string;
    const born = Number(e.first_hit_ms) - Number(e.age_sec_at_hit) * 1000;
    const mc = mcOf(addr);

    // Detected already at/past rung 1 ($6k): no position could open below the
    // first exit — 'gap', same honest-tally rule as before.
    if (Number(e.first_hit_mc) >= LADDER_RUNGS[0]) {
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE earlies SET play_outcome='gap', play_exit_mc=?2, play_outcome_ms=?3
          WHERE token_address=?1 AND play_outcome IS NULL`
      ).bind(addr, e.first_hit_mc, now));
      continue;
    }

    // Advance rungs monotonically to how far this tick's MC has climbed.
    let rungs = Number(e.rungs);
    if (mc !== null) {
      while (rungs < LADDER_RUNGS.length && mc >= LADDER_RUNGS[rungs]) rungs++;
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE earlies
            SET rungs_filled=MAX(COALESCE(rungs_filled,0), ?2),
                peak_ms=CASE WHEN ?3 > COALESCE(peak_mc,0) THEN ?4 ELSE peak_ms END,
                peak_mc=MAX(COALESCE(peak_mc,0), ?3)
          WHERE token_address=?1`
      ).bind(addr, rungs, mc, now));
    }

    if (rungs >= LADDER_RUNGS.length) {
      // FULL LADDER — all four rungs sold at their prices. Blended exit is the
      // ladder constant ($7,750 on a $3.5k entry ≈ 2.21x).
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE earlies SET play_outcome='target', play_exit_mc=?2, play_outcome_ms=?3, rungs_filled=4
          WHERE token_address=?1 AND play_outcome IS NULL`
      ).bind(addr, LADDER_FULL_VALUE, now));
    } else if (now - born >= PLAY_EXIT_AGE_MS) {
      // THE BELL — sold rungs at their prices, remainder at market (mc, or
      // entry as the conservative floor if MC is momentarily unknown).
      const remainderMc = mc ?? Number(e.first_hit_mc);
      const exitVal = ladderSoldValue(rungs) + (1 - ladderSoldFrac(rungs)) * remainderMc;
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE earlies SET play_outcome='exit2m', play_exit_mc=?2, play_outcome_ms=?3
          WHERE token_address=?1 AND play_outcome IS NULL`
      ).bind(addr, exitVal, now));
    }
  }

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

// dexTrackScan: POST-GRADUATION TRACKING (RATIFIED 2026-07-12). Once a coin
// graduates (births.status='discovered' -> it's on DexScreener), keep pulling
// its live DEX metrics and record a RUNNING dex_peak_mc — for BOTH the §1
// candidate AND the §0 early, so a coin that laddered/exited early
// (DAYNA $10.6k) is followed through its whole DEX run ($26k) instead of the
// tape going blind at the bell. Display/intelligence only; the paper trade
// already closed. dex_peak_mc is the number that quantifies the post-exit run.
const DEX_TRACK_WINDOW_MS = 48 * 3600_000; // enrich for 48h after flagging

export async function dexTrackScan(env: WatcherEnv): Promise<void> {
  const now = Date.now();
  const since = now - DEX_TRACK_WINDOW_MS;
  // graduated coins we flagged, from BOTH tables (an early that later qualified
  // §1 is in both — track it in both).
  const { results: eRows } = await env.RADAR_DB.prepare(
    `SELECT c.token_address FROM earlies c JOIN births b ON b.token_address=c.token_address
      WHERE b.status='discovered' AND c.first_hit_ms >= ?1`
  ).bind(since).all();
  const { results: cRows } = await env.RADAR_DB.prepare(
    `SELECT c.token_address FROM candidates c JOIN births b ON b.token_address=c.token_address
      WHERE b.status='discovered' AND c.qualified_ms >= ?1`
  ).bind(since).all();
  const inEarly = new Set((eRows as any[]).map((r) => r.token_address as string));
  const inCand = new Set((cRows as any[]).map((r) => r.token_address as string));
  const addrs = [...new Set([...inEarly, ...inCand])];
  if (!addrs.length) return;

  const stmts: any[] = [];
  for (let i = 0; i < addrs.length && i < 120; i += 30) {
    const chunk = addrs.slice(i, i + 30);
    const res = await fetch(env.DEXSCREENER_TOKEN_URL + chunk.join(","), {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
    });
    if (res.status === 429) break;
    if (!res.ok) continue;
    const data: any = await res.json();

    // most-liquid NON-curve (real DEX) pair per token
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
      const mc = numOrNull(p?.marketCap ?? p?.fdv);
      const liq = numOrNull(p?.liquidity?.usd);
      const vol = numOrNull(p?.volume?.h1);
      if (inCand.has(addr)) {
        stmts.push(env.RADAR_DB.prepare(
          `UPDATE candidates SET
              graduated_ms = COALESCE(graduated_ms, ?2),
              dex_price_usd = ?3, dex_mc = ?4,
              dex_peak_mc = MAX(COALESCE(dex_peak_mc,0), COALESCE(?4,0)),
              dex_liq_usd = ?5, dex_vol_h1 = ?6, dex_chg_m5 = ?7, dex_chg_h1 = ?8,
              dex_last_ms = ?2
            WHERE token_address = ?1`
        ).bind(addr, now, numOrNull(p?.priceUsd), mc, liq, vol,
          numOrNull(p?.priceChange?.m5), numOrNull(p?.priceChange?.h1)));
      }
      if (inEarly.has(addr)) {
        stmts.push(env.RADAR_DB.prepare(
          `UPDATE earlies SET
              graduated_ms = COALESCE(graduated_ms, ?2),
              dex_mc = ?3, dex_peak_mc = MAX(COALESCE(dex_peak_mc,0), COALESCE(?3,0)),
              dex_liq_usd = ?4, dex_vol_h1 = ?5, dex_last_ms = ?2
            WHERE token_address = ?1`
        ).bind(addr, now, mc, liq, vol));
      }
    }
  }
  if (stmts.length) await env.RADAR_DB.batch(stmts);
}
