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
// On-curve floor. A coin at the ~$8k band with <10 SOL of curve reserves has
// DECOUPLED — it graduated (reserves drained to the LP) and its MC is now a
// DexScreener price against ~0 curve reserves. The backtest excluded this pool
// (a different regime, not thin liquidity); the live stamper must too, or it
// mislabels graduated coins "thin" and pollutes the field. Skip, don't stamp.
const CONV_CURVE_MIN = 10;
const CONV_STAMP_WINDOW_MS = 30 * 60_000; // only consider recently-born earlies

function numOrNull(v: unknown): number | null {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

// BORN LOADED fast lane — 3-min momentum tag (RESEARCH_RadarMethod F4).
// ratio = mc-at-~3min / mc-at-stamp, the honest FROM-ENTRY read: a coin that
// 2x's by minute 3 doubles AGAIN from there 10.2% vs 3.2% for flat (3x lift).
// Ranking/confirmation signal only — the stamp (entry basis) never moves.
// Pure + exported for fastlane.test.mjs.
export function momentumTag(ratio: number): "hot" | "warm" | "flat" | "down" {
  if (ratio >= 2) return "hot";
  if (ratio >= 1.3) return "warm";
  if (ratio >= 0.95) return "flat";
  return "down";
}
// The 3-min read window: a tick 90s-270s after the stamp, nearest 180s. Ticks
// only exist while a coin is on the tape (earlies/candidates), so a row with
// no tick by the window's close will never get one — that is 'untracked'.
const FAST_MOMENTUM_AT_MS   = 180_000;
const FAST_MOMENTUM_TOL_MS  = 90_000;
const FAST_GRADE_AFTER_MS   = 6 * 3600_000; // outcome graded once peaks settle

// SELF-HEAL: bounded fetch. An un-timed await on a hung upstream (pump.fun or
// DexScreener stops responding) froze the whole scan for 21min once — every
// cron tick piled a new hung fetch, none wrote a tape row, the eye went blind
// with no error. A timeout converts "hang forever" into "throw -> caller
// retries next pass", so the worst case is a missed pass, never a freeze.
const FETCH_TIMEOUT_MS = 10_000;
function tfetch(url: string, init?: RequestInit): Promise<Response> {
  return fetch(url, { ...init, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
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
// screen pass — one pass per minute stays far under DexScreener's 300 req/min.
async function fetchDexMc(
  env: WatcherEnv, addrs: string[],
): Promise<{ mc: Map<string, number>; volM5: Map<string, number> }> {
  const mc = new Map<string, number>();
  const volM5 = new Map<string, number>();
  for (let i = 0; i < addrs.length; i += 30) {
    const chunk = addrs.slice(i, i + 30);
    let res: Response;
    try {
      res = await tfetch(env.DEXSCREENER_TOKEN_URL + chunk.join(","), {
        headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
      });
    } catch { continue; } // hung batch skips, doesn't freeze the tracking
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

// SINGLE-PASS per cron (RELIABILITY, 2026-07-13). The old 4×15s
// setTimeout-in-waitUntil sub-tick loop (for 15s resolution) STALLED THE SCAN
// TWICE — the tape went blind for 21min, then 115min — while its cron-siblings
// birthScan/btcScan (single-pass, no setTimeout) kept writing every minute. A
// setTimeout inside a cron waitUntil is not reliably kept alive, and the
// fetch-timeout self-heal could not fix it because it was never a hung fetch.
// So: ONE screenScan per cron tick, exactly like the siblings that never die
// (index.ts calls this directly; the old screenLoop wrapper is gone — R-11).
// Cadence drops to 60s but the eye NEVER goes blind. The reliable path back to
// sub-minute resolution is the Durable-Object alarm (Layer 3, pumptape.ts) —
// alarms DO survive across invocations; that's the correct 15s mechanism.
// RUG SIGNAL (migration 0020). Solana getTokenLargestAccounts(mint) → the
// largest REAL holder's share of the circulating float [0,1]. Excludes the
// bonding-curve token account (its reserve is not a holder). Returns null if the
// RPC is unset/unreachable or the payload is unusable, so the gate stays NULL
// (not evaluated) and the qualify path is never blocked. Forward-measured.
// MIRROR of resolveSecret in mcp/solana-mcp/worker.js. The BODY is kept byte
// identical and keeper/test/secret-resolve.test.js lifts both out of their real
// source files and fails if they drift — same discipline as the console/worker
// preimage pair. Duplicated rather than shared because these are two separately
// bundled wrangler projects, and a cross-root import would put a deploy-time
// bundling risk on a path that currently has none.
//
// A Secrets Store binding is an object with async get(); `wrangler secret put`
// gives a plain string. A binding is always truthy, so anything that gates on
// the raw env value stops gating the moment the binding lands.
async function resolveSecret(v: any): Promise<string> {
  if (typeof v === "string") return v;
  if (v && typeof v.get === "function") {
    try {
      const s = await v.get();
      return typeof s === "string" ? s : "";
    } catch {
      return "";
    }
  }
  return "";
}

async function topHolderShare(
  env: WatcherEnv, mint: string, curveTokenAccount: string | null,
): Promise<number | null> {
  const url = await resolveSecret(env.SOLANA_RPC_URL);
  if (!url || !mint) return null;
  let res: Response;
  try {
    res = await tfetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "getTokenLargestAccounts",
        params: [mint, { commitment: "confirmed" }],
      }),
    });
  } catch { return null; }
  if (!res.ok) return null;
  let j: any;
  try { j = await res.json(); } catch { return null; }
  const list = j?.result?.value;
  if (!Array.isArray(list) || !list.length) return null;
  const curve = (curveTokenAccount || "").toLowerCase();
  let curveAmt = 0, maxNonCurve = 0, sumAll = 0;
  for (const a of list) {
    const amt = Number(a?.amount ?? 0);
    if (!Number.isFinite(amt) || amt <= 0) continue;
    sumAll += amt;
    if ((a?.address || "").toLowerCase() === curve) { curveAmt = amt; continue; }
    if (amt > maxNonCurve) maxNonCurve = amt;
  }
  // Denominator = the non-curve float ACTUALLY on-chain (sum of holders in the
  // top set minus the curve), NOT the birth-JSON total_supply. A coin can hold
  // more than its nominal supply on-chain (mint inflation — a rug in itself),
  // which made the nominal denominator yield absurd >1 ratios. Sum-based float
  // keeps the share a clean [0,1] and flags an over-concentrated float correctly.
  const floatAmt = sumAll - curveAmt;
  if (!(floatAmt > 0)) return null;              // only the curve holds anything
  return maxNonCurve / floatAmt;                 // largest holder's share of float [0,1]
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
  let res: Response;
  try {
    res = await tfetch(env.PUMPFUN_FEED_URL, {
      headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
    });
  } catch (e) { console.warn("screen feed timeout/err", String(e)); return; } // next cron pass retries
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

  // MARKET-VOLUME REGIME (migration 0022). Sum the m5 dollar-volume we already
  // fetched for the on-screen set — a zero-extra-call proxy for market heat (the
  // "time to trade vs not" gate). Dead market -> tiny on-screen set -> near-zero;
  // it rises as coins pump into the band. n_tracked carries the context. Prune
  // keeps ~30 days. Trailing-average regime is derived from this series later.
  let mktVolM5 = 0;
  for (const v of dex.volM5.values()) if (Number.isFinite(v)) mktVolM5 += v;
  stmts.push(env.RADAR_DB.prepare(
    `INSERT INTO market_vol (ts_ms, vol_m5, n_tracked) VALUES (?1,?2,?3)
     ON CONFLICT(ts_ms) DO NOTHING`
  ).bind(now, mktVolM5, trackAddrs.length));
  stmts.push(env.RADAR_DB.prepare(
    `DELETE FROM market_vol WHERE ts_ms < ?1`
  ).bind(now - 30 * 24 * 3600_000));

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
    // wait until it's in-band AND we have a genuine on-curve reserve read.
    // depth < CONV_CURVE_MIN = decoupled/graduated (curve drained) — skip, it's
    // not a real entry and the backtest excluded it.
    if (mc === null || mc < CONV_BAND || depth === undefined || depth < CONV_CURVE_MIN) continue;
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

  // (0.6) FAST LANE momentum re-rank (RESEARCH_RadarMethod F4 / §3.3). For each
  //       ungraded stamp past the 3-min mark, read the tape tick nearest
  //       stamp+180s and tag hot/warm/flat/down from the FROM-ENTRY ratio.
  //       Fastlane coins in the 5-8k band have crossed the $3.5k early screen,
  //       so most ARE on the tape; a row with no tick by the window's close is
  //       'untracked' (terminal — ticks are only written live, none will appear
  //       later). The stamp itself is immutable; this only fills momentum/mc3m.
  //       PRODUCTION LESSON (2026-08-12, caught by the health verdict's own
  //       errLatest rule ~2h after deploy): D1's engine REJECTS outer-alias
  //       arithmetic inside a correlated subquery ("no such column:
  //       f.sighted_ms") — a dialect limit the offline mocks cannot see, and
  //       the thrown error killed the WHOLE scan (tape, tracking, everything)
  //       for two hours. Hence: (a) the tick lookup is a CTE + JOIN, the shape
  //       D1 accepts; (b) both fastlane passes are fail-soft — an experimental
  //       lane must never take the ratified tape down with it.
  try {
    const { results: fastMom } = await env.RADAR_DB.prepare(
      `WITH cand AS (
         SELECT token_address, sighted_ms, birth_mc FROM fastlane
          WHERE momentum IS NULL AND sighted_ms <= ?1
          LIMIT 200
       ), t3 AS (
         SELECT cand.token_address AS ta, MIN(m.ms) AS ms3
           FROM cand JOIN mc_ticks m
             ON m.token_address = cand.token_address
            AND m.ms BETWEEN cand.sighted_ms + ?2 AND cand.sighted_ms + ?3
          GROUP BY cand.token_address
       )
       SELECT cand.token_address, cand.sighted_ms, cand.birth_mc, mt.mc AS mc3m
         FROM cand
         LEFT JOIN t3 ON t3.ta = cand.token_address
         LEFT JOIN mc_ticks mt ON mt.token_address = cand.token_address AND mt.ms = t3.ms3`
    ).bind(
      now - FAST_MOMENTUM_AT_MS,
      FAST_MOMENTUM_AT_MS - FAST_MOMENTUM_TOL_MS,
      FAST_MOMENTUM_AT_MS + FAST_MOMENTUM_TOL_MS,
    ).all();
    for (const f of fastMom as any[]) {
      const mc3m = numOrNull(f.mc3m);
      const birthMc = Number(f.birth_mc);
      if (mc3m !== null && birthMc > 0) {
        stmts.push(env.RADAR_DB.prepare(
          `UPDATE fastlane SET mc3m=?2, momentum=?3
            WHERE token_address=?1 AND momentum IS NULL`
        ).bind(f.token_address, mc3m, momentumTag(mc3m / birthMc)));
      } else if (now - Number(f.sighted_ms) > FAST_MOMENTUM_AT_MS + FAST_MOMENTUM_TOL_MS) {
        // window closed with no tape row — never got on screen, never will tick
        stmts.push(env.RADAR_DB.prepare(
          `UPDATE fastlane SET momentum='untracked'
            WHERE token_address=?1 AND momentum IS NULL`
        ).bind(f.token_address));
      } // else: still inside the window, next pass retries
    }
  } catch (e) { console.error("fastlane momentum pass", e); }

  // (0.7) FAST LANE grading (the scorekeeper — real trading is the test that
  //       counts; this table just keeps score, per the Architect). Stamps aged
  //       >=6h grade against births.mc_peak_usd — the same peak the research
  //       measured, so forward numbers are directly comparable to F1/F3
  //       (22.4% 2x core band, 26.8% stacked with the hot regime).
  try {
    const { results: fastGrade } = await env.RADAR_DB.prepare(
      `SELECT f.token_address, f.birth_mc, b.mc_peak_usd
         FROM fastlane f JOIN births b ON b.token_address=f.token_address
        WHERE f.outcome IS NULL AND f.sighted_ms <= ?1
        LIMIT 200`
    ).bind(now - FAST_GRADE_AFTER_MS).all();
    for (const f of fastGrade as any[]) {
      const peak = numOrNull(f.mc_peak_usd);
      const birthMc = Number(f.birth_mc);
      const mult = peak !== null && birthMc > 0 ? peak / birthMc : null;
      const outcome = mult === null ? "untracked"
        : mult >= 2 ? "2x"
        : mult >= 1.5 ? "1_5x"
        : "flat";
      stmts.push(env.RADAR_DB.prepare(
        `UPDATE fastlane SET peak_mc=?2, peak_mult=?3, outcome=?4, outcome_ms=?5
          WHERE token_address=?1 AND outcome IS NULL`
      ).bind(f.token_address, peak, mult, outcome, now));
    }
  } catch (e) { console.error("fastlane grading pass", e); }

  // (1) QUALIFY: 'watching' tokens aged 4-7 min, current curve MC in-band, not
  //     already tracked. Pre-DEX is implied by status='watching'.
  const { results: young } = await env.RADAR_DB.prepare(
    `SELECT token_address, symbol, name, creator, pumpfun_first_seen_ms, raw_birth_json, mc_at_birth_usd
       FROM births
      WHERE status='watching'
        AND pumpfun_first_seen_ms <= ?1
        AND pumpfun_first_seen_ms >= ?2
        AND token_address NOT IN (SELECT token_address FROM candidates)`
  ).bind(now - AGE_MIN_MS, now - AGE_MAX_MS).all();

  // DEV-REPUTATION paper gate (migration 0019). "Fresh" threshold is tunable.
  const devRepMaxPrior = parseInt(env.DEV_REP_MAX_PRIOR || "20", 10);
  // RUG gate (migration 0020). Whale-on-the-float threshold, tunable.
  const rugMaxTop = parseFloat(env.RUG_MAX_TOP_HOLDER_PCT || "0.20");
  // GO-TO STRATEGY (migration 0021). Momentum band for the composite take flag.
  const stratVelLo = parseFloat(env.STRAT_VEL_LO || "7");
  const stratVelHi = parseFloat(env.STRAT_VEL_HI || "20");
  for (const r of young as any[]) {
    const mc = mcNow.get(r.token_address as string);
    if (mc === undefined || mc < ENTRY_LOW || mc > ENTRY_HIGH) continue;
    const ageSec = Math.round((now - Number(r.pumpfun_first_seen_ms)) / 1000);
    // Point-in-time creator history: the same wallet's launches STRICTLY BEFORE
    // this coin was born (< its own birth ms) — no lookahead. Few coins qualify
    // per tick, so one indexed count each is cheap. gate_dev: fresh(1)/serial(0),
    // NULL when the creator is unknown. Backtest 2026-07-16: fresh devs hit +20%
    // 49.5% vs 21.9% for serials. Paper signal only — it records, it skips nothing.
    let devPrior: number | null = null;
    let gateDev: number | null = null;
    if (r.creator != null) {
      const priorRow = await env.RADAR_DB.prepare(
        `SELECT COUNT(*) AS n FROM births
          WHERE creator=?1 AND pumpfun_first_seen_ms < ?2`
      ).bind(r.creator, Number(r.pumpfun_first_seen_ms)).first<any>();
      devPrior = Number(priorRow?.n ?? 0);
      gateDev = devPrior <= devRepMaxPrior ? 1 : 0;
    }
    // RUG gate (migration 0020): live top-holder concentration. Parse the curve
    // token account + total supply from the stored birth JSON, then one Solana
    // RPC read. Fail-soft: any gap leaves share/gate_rug NULL. Forward-measured.
    let topShare: number | null = null;
    let gateRug: number | null = null;
    try {
      const bj = r.raw_birth_json ? JSON.parse(r.raw_birth_json as string) : null;
      const curveAcct = (bj?.associated_bonding_curve as string) ?? null;
      topShare = await topHolderShare(env, r.token_address as string, curveAcct);
      if (topShare !== null) gateRug = topShare <= rugMaxTop ? 1 : 0;
    } catch { /* leave NULL — not evaluated */ }
    // MOMENTUM + composite take (migration 0021; RECALIBRATED migration 0023).
    // entry_vel = climb rate into the band = (entry_mc - birth_mc)/age.
    // strat_take = the full validated entry filter: momentum in band AND fresh
    // dev AND rug AFFIRMATIVELY passed.
    //
    // RATIFIED CALIBRATION (council 2026-07-20, AUDIT_PACKET_RADAR P1-c — FIX B's
    // principle applied to the radar): a NULL rug gate means UNKNOWN, never PASS.
    // The old `gateRug !== 0` counted a pending/failed-RPC read as not-failed —
    // the same False-Green species as a fork test that passes when its dependency
    // is absent. strat_take now requires an AFFIRMATIVE pass (`gateRug === 1`),
    // mirroring gate_dev which already requires `=== 1`. An unknown rug read
    // suppresses the take (recorded strat_take=0 with gate_rug NULL — distinct
    // from a hard rug fail, gate_rug=0). Provenance: the n=77 window carried ZERO
    // NULL rug gates (RPC was live; 112/279 actively failed), so no historical
    // take flips — this guards the NEW AI-assisted ledger against a silent RPC
    // outage poisoning its early samples.
    const mcAtBirth = Number(r.mc_at_birth_usd ?? 0);
    const entryVel = (mcAtBirth > 0 && ageSec > 0) ? (mc - mcAtBirth) / ageSec : null;
    const momentumOk = entryVel !== null && entryVel >= stratVelLo && entryVel <= stratVelHi;
    const stratTake = (momentumOk && gateDev === 1 && gateRug === 1) ? 1 : 0;
    // Skip LOUDLY (council): a coin that clears momentum + fresh-dev but whose rug
    // read is UNKNOWN is a would-be take suppressed only by a missing on-chain
    // read. Surface it so an RPC outage is visible in logs, never silent.
    if (stratTake === 0 && gateRug === null && gateDev === 1 && momentumOk) {
      console.warn(`rug gate UNKNOWN — take suppressed (SOLANA_RPC down?) token=${r.token_address}`);
    }
    stmts.push(env.RADAR_DB.prepare(
      `INSERT INTO candidates
         (token_address, symbol, name, creator, qualified_ms, entry_age_sec,
          entry_mc, gate_age, gate_mc, gate_predex, gate_rug, gate_session,
          dev_prior_launches, gate_dev, top_holder_share, entry_vel, strat_take,
          peak_mc, peak_ms, last_mc, last_tracked_ms, outcome)
       VALUES (?1,?2,?3,?4,?5,?6,?7,1,1,1,?10,NULL,?8,?9,?11,?12,?13,?7,?5,?7,?5,'live')
       ON CONFLICT(token_address) DO NOTHING`
    ).bind(r.token_address, r.symbol ?? null, r.name ?? null, r.creator ?? null, now, ageSec, mc, devPrior, gateDev, gateRug, topShare, entryVel, stratTake));
  }

  // (2) TRACK live candidates against the exit rule. First trigger wins.
  // GO-TO STRATEGY (migration 0021): entry-RELATIVE take/stop (let winners run)
  // replaces the old fixed $20k/$6k MC levels — expectancy rises with target
  // size, so the target is (1+STRAT_TARGET_PCT)x entry, the stop (1-STRAT_STOP_PCT)x.
  const stratTargetPct = parseFloat(env.STRAT_TARGET_PCT || "0.50");
  const stratStopPct = parseFloat(env.STRAT_STOP_PCT || "0.40");
  const { results: liveC } = await env.RADAR_DB.prepare(
    `SELECT c.token_address, c.peak_mc, c.entry_mc, c.qualified_ms, b.status AS bstatus
       FROM candidates c JOIN births b ON b.token_address=c.token_address
      WHERE c.outcome='live'`
  ).all();

  for (const c of liveC as any[]) {
    const addr = c.token_address as string;
    const mc = mcOf(addr);
    // TIME-STOP FIX (2026-08-14, Tare + Architect — mc_ticks froze at exactly
    // 10 ticks / ~9min for EVERY token, measured against D1). age used to be
    // measured from BIRTH (pumpfun_first_seen_ms), but qualifying into
    // 'candidates' already costs 4-7min (AGE_MIN_MS..AGE_MAX_MS above), so a
    // coin that qualified at minute 6 hit the birth-anchored 10min stop at
    // minute 10 regardless — only ~4min of genuine live tracking, and the
    // mc_ticks tape (screen.ts:354-358) stops the instant outcome leaves
    // 'live'. §1's "10-minute time-stop" means 10 minutes HELD as a
    // candidate, not 10 minutes since the coin was born — anchor to
    // qualified_ms, the moment it actually became a live candidate.
    const age = now - Number(c.qualified_ms);
    // Entry-relative levels; fall back to the legacy fixed MC if entry is missing.
    const entryMc = Number(c.entry_mc ?? 0);
    const targetMc = entryMc > 0 ? entryMc * (1 + stratTargetPct) : TARGET_MC;
    const stopMc = entryMc > 0 ? entryMc * (1 - stratStopPct) : STOP_MC;

    if (c.bstatus === "discovered") {               // #3 edge-loss: graduated
      stmts.push(setOutcome(env, addr, "graduated", now, mc));
    } else if (mc !== null && mc >= targetMc) {     // #1 take-profit (+STRAT_TARGET_PCT)
      stmts.push(setOutcome(env, addr, "target", now, mc));
    } else if (mc !== null && mc <= stopMc) {       // #2 stop-loss (-STRAT_STOP_PCT)
      stmts.push(setOutcome(env, addr, "stop", now, mc));
    } else if (age >= TIMESTOP_MS) {                // #4 time-stop
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
// Enrich for 1h after flagging (was 48h). Re-scanning a 48h tail of graduated
// coins every minute was the bandwidth drag behind the tape stalls; the pre-grad
// edge (birth -> peak, first ~23-56min) is captured elsewhere, so a 1h post-grad
// window is the "hour-by-hour ledger" break from previous coins (Architect
// 2026-07-15). Tunable without a code change via the DEX_TRACK_HOURS var.
export async function dexTrackScan(env: WatcherEnv): Promise<void> {
  const now = Date.now();
  const since = now - parseInt(env.DEX_TRACK_HOURS || "1", 10) * 3600_000;
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
    let res: Response;
    try {
      res = await tfetch(env.DEXSCREENER_TOKEN_URL + chunk.join(","), {
        headers: { accept: "application/json", "user-agent": "possessio-radar/0.4" },
      });
    } catch { continue; }
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
