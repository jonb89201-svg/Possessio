// x402-toll.ts — sell-side toll for possessio-radar
//
// AUDIT LAW THIS FILE OBEYS: never hand-roll payment verification. Signature checking,
// settlement, and replay protection belong to the official x402 middleware + facilitator.
// This file is CONFIGURATION around the official package, nothing more. A homemade 402
// verifier in a money path would be a HIGH finding — including one written by this seat.
//
// VERIFY-FIRST EXECUTED (Claude Code, 2026-07-06, against the packages themselves):
//   - The handed-off snapshot named `x402-hono` (v1). That package is DEPRECATED
//     (npm README: v1, security patches only). The current official stack is x402 v2:
//     `@x402/hono` 2.17.0 + `@x402/core` + `@x402/evm` — API confirmed from the
//     package's own README + dist/*.d.mts, not from docs-site memory.
//   - v2 shape: paymentMiddleware(routes, resourceServer) where resourceServer =
//     new x402ResourceServer(new HTTPFacilitatorClient({url})).register(caip2, new
//     ExactEvmScheme()). Networks are CAIP-2 ("eip155:84532" = Base Sepolia).
//   - Default facilitator: https://facilitator.x402.org. Coinbase CDP facilitator is
//     the mainnet choice at cutover (FACILITATOR_URL var — flip with the wave, like
//     every chain check).
//
// VERIFY-FIRST EXECUTED (Claude Code, 2026-07-17, for the x402 V2 Bazaar Discovery
// endpoint — SPEC_BusinessModel.md R1 authorizes exactly this one worker-layer build):
//   - Discovery is NOT a hand-rolled route. It is `@x402/extensions` v2.18.0 (installed
//     transitively; now a direct dep) wired as CONFIGURATION on the same official
//     middleware — no new money path, so the audit law above still holds verbatim.
//   - API confirmed from the package's own dist/*.d.mts (not memory):
//       · `declareDiscoveryExtension(config): Record<string,DiscoveryExtension>` —
//         config is DistributiveOmit<...,"method"> (the HTTP method is set by the
//         server extension's enrichDeclaration, NOT declared here). For our GET routes
//         the query shape is `{ input?, inputSchema?, output?: { example?, schema? } }`.
//       · `bazaarResourceServerExtension: ResourceServerExtension`, installed via
//         `x402ResourceServer#registerExtension(ext): this`.
//       · Per-route carrier is `RouteConfig.extensions?: Record<string,unknown>`, plus
//         `serviceName? / tags? / iconUrl?` for the sanitized catalog metadata.
//   - Effect: a facilitator that indexes the Bazaar (GET /discovery/resources, /search)
//     now sees these three paid routes with their price, description, and an OUTPUT
//     EXAMPLE — so an AI agent can find and price the radar's data API before it pays.
//
// Behavior: while TOLL_SINK is the zero address, routes serve FREE with an honest
// "TOLL_NOT_ARMED" header — same placeholder pattern as the fuel pool's POOL_NOT_DEPLOYED.
// The moment the wave writes the sink, the same routes start charging. No code change.

import { Hono } from "hono";
import { paymentMiddleware, x402ResourceServer } from "@x402/hono";
import { HTTPFacilitatorClient } from "@x402/core/server";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { bazaarResourceServerExtension } from "@x402/extensions";
import { tollRoutes } from "./toll-routes";
import { FEED_HTML } from "./feed";
import { sessionGateResponse } from "./sessiongate";
import { healthVerdict, type FeedStatusRow } from "./health";

export type Env = {
  RADAR_DB: D1Database;
  TOLL_SINK: string;
  TOLL_NETWORK: "base" | "base-sepolia"; // human name in config; CAIP-2 derived below
  FACILITATOR_URL?: string;
  PRICE_GAP_STATS: string;   // OPEN — Architect prices after the tape has data
  PRICE_SESSION_GATE: string;
  PRICE_TAPE: string;
  // §0 SESSION GATE (sessiongate.ts). All optional, all defaulted in code —
  // NONE frozen (§7): the threshold is a research-based starting point tuned
  // later by ledger correlation, so it must stay adjustable without a redeploy.
  SESSION_GATE_THRESHOLD?: string;  // gate cutoff, default 0.65 (§0 "~60–70%")
  SESSION_WINDOW_HOURS?: string;    // trailing window, default 24 (§0 "1–24h")
  SESSION_BASELINE_DAYS?: string;   // baseline span, default 7 (§0 "7-day average")
  SESSION_RECOMPUTE_MS?: string;    // cadence gate, default 3600000 (hourly)
  // Farcaster Mini App (the radar, launchable inside Warpcast/Base App).
  CONSOLE_URL?: string;             // where icon/splash/og assets live (default possessio.io)
  FC_ACCOUNT_ASSOCIATION?: string;  // signed JFS (JSON) proving the domain -> your FID; set via `wrangler secret put`
  NEYNAR_API_KEY?: string;          // Neynar-powered features (notifications/posting); base mini app needs none
  TAPE_HOST?: string;               // "railway" = per-trade tape lives off-worker; local DO dormant
};

const ZERO = "0x0000000000000000000000000000000000000000";
const CAIP2: Record<string, string> = { base: "eip155:8453", "base-sepolia": "eip155:84532" };

// ── BITCOIN NEWS (bitbo.io has no API — its news page is itself an aggregator
// of standard RSS, so we pull the same primary sources directly, server-side
// since RSS sends no CORS). Cached per-isolate, 5-min TTL; the /radar/news
// route serves it and the feed renders a compact strip. Display only. ──
const NEWS_FEEDS: [string, string][] = [
  ["CoinDesk", "https://www.coindesk.com/arc/outboundfeeds/rss/"],
  ["Cointelegraph", "https://cointelegraph.com/rss"],
  ["Bitcoin Magazine", "https://bitcoinmagazine.com/feed"],
];
const NEWS_TTL_MS = 5 * 60_000;
let newsCache: { ts: number; items: any[] } = { ts: 0, items: [] };

// RSS titles arrive HTML-entity-encoded (and occasionally with stray tags).
// Decode to clean text here; the feed re-escapes with esc() before display, so
// the result is both correct (no double-escaped &amp;) and XSS-safe.
function decodeEntities(s: string): string {
  return s
    .replace(/<[^>]+>/g, "")
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&"); // amp last
}

function parseRss(xml: string, src: string, limit = 8): any[] {
  const out: any[] = [];
  const grab = (b: string, tag: string) => {
    const m = b.match(new RegExp("<" + tag + "[^>]*>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</" + tag + ">", "i"));
    return m ? m[1].trim() : "";
  };
  for (const b of xml.split(/<item[\s>]/i).slice(1, limit + 1)) {
    const title = decodeEntities(grab(b, "title"));
    if (!title) continue;
    const pd = grab(b, "pubDate");
    const ts = pd ? Date.parse(pd) : NaN;
    out.push({ title, link: grab(b, "link"), src, ts: Number.isFinite(ts) ? ts : null });
  }
  return out;
}

// BOUNDED + CONCURRENT (AUDIT 2026-07-14, R-5): this runs on the REQUEST path
// (GET /radar/news), and the repo's own law — learned when a hung upstream
// froze the scan for 21min (see watcher.ts/screen.ts) — is that no await on an
// external host goes un-timed. The three feeds fetch in PARALLEL, each with
// its own timeout and its own failure (one dead feed never blocks or kills the
// others), so the worst case is one bounded wait, not three stacked ones. On
// total failure the last good cache serves stale — better than a blank strip.
const NEWS_FETCH_TIMEOUT_MS = 5_000;

async function getNews(): Promise<any[]> {
  if (Date.now() - newsCache.ts < NEWS_TTL_MS && newsCache.items.length) return newsCache.items;
  const settled = await Promise.allSettled(
    NEWS_FEEDS.map(async ([src, url]) => {
      const r = await fetch(url, {
        headers: { "user-agent": "possessio-radar/0.4", accept: "application/rss+xml,application/xml,text/xml" },
        signal: AbortSignal.timeout(NEWS_FETCH_TIMEOUT_MS),
      });
      if (!r.ok) return [];
      return parseRss(await r.text(), src);
    }),
  );
  const all: any[] = [];
  for (const s of settled) {
    if (s.status === "fulfilled") all.push(...s.value); // one source down doesn't sink the strip
  }
  all.sort((a, b) => (b.ts || 0) - (a.ts || 0));
  if (all.length) newsCache = { ts: Date.now(), items: all.slice(0, 12) };
  return newsCache.items; // empty fetch round -> stale cache (or [] if never primed)
}

export function buildTolledApp(env: Env) {
  const app = new Hono();
  const armed = env.TOLL_SINK && env.TOLL_SINK.toLowerCase() !== ZERO;

  if (armed) {
    // ── THE toll. One middleware, three routes, prices from env. ──
    const network = CAIP2[env.TOLL_NETWORK];
    const facilitator = new HTTPFacilitatorClient({
      url: env.FACILITATOR_URL || "https://facilitator.x402.org",
    });
    // Bazaar Discovery (x402 V2): registering the extension makes each route's
    // per-route `extensions` (built in tollRoutes) enrichable and echoed to a
    // facilitator that catalogs the Bazaar — how an AI agent finds this paid data
    // API. It is pure config on the official middleware; the audit law (never
    // hand-roll verification) is untouched.
    const server = new x402ResourceServer(facilitator)
      .register(network, new ExactEvmScheme())
      .registerExtension(bazaarResourceServerExtension);
    const routes = tollRoutes({
      network,
      payTo: env.TOLL_SINK as `0x${string}`,
      prices: { gapStats: env.PRICE_GAP_STATS, sessionGate: env.PRICE_SESSION_GATE, tape: env.PRICE_TAPE },
      iconUrl: ((env as any).CONSOLE_URL || "https://possessio.io") + "/icon-1024.png",
    });
    app.use(paymentMiddleware(routes, server));
  } else {
    app.use("*", async (c, next) => {
      c.header("x-possessio-toll", "TOLL_NOT_ARMED"); // honest free mode pre-wave
      await next();
    });
  }

  // ---- the public LIVE-SELECTION feed (RATIFIED 2026-07-11, Architect,
  // Amendment IV Clause 5). This is the deliberate exception to the boundary
  // below: the screened candidate SELECTION is public — it promotes the
  // x402Core autonomous trader and feeds the pool, and shared visibility on a
  // $10k micro-cap is a tailwind, not a leak. It exposes WHICH coins clear §1,
  // never entry/exit prices or size. Always free, even when the toll is armed
  // (it's marketing for the paid execution product, not a paid data route). ----
  // The feed doubles as a Farcaster Mini App. We inject the fc:miniapp embed
  // meta per-request (built from the actual origin, so it works on workers.dev
  // or a custom domain with no hardcoding). Assets come from the console domain.
  const consoleUrl = (env as any).CONSOLE_URL || "https://possessio.io";
  app.get("/feed", (c) => {
    const origin = new URL(c.req.url).origin;
    const embed = JSON.stringify({
      version: "1",
      imageUrl: consoleUrl + "/og.png",
      button: {
        title: "Open Radar",
        action: {
          type: "launch_miniapp", name: "POSSESSIO Radar", url: origin + "/feed",
          splashImageUrl: consoleUrl + "/splash-200.png", splashBackgroundColor: "#ffffff",
        },
      },
    }).replace(/"/g, "&quot;");
    const meta = '<meta name="fc:miniapp" content="' + embed + '">';
    return c.html(FEED_HTML.replace("<!--FC_EMBED-->", meta));
  });
  // FARCASTER MINI APP MANIFEST. Served at the domain root; miniapp metadata is
  // built from the request origin so it's domain-agnostic. accountAssociation
  // (the JFS proving this domain belongs to your FID) is injected from an env
  // secret — until it's set the app still launches, it just isn't "verified"
  // for publishing. Generate it with Warpcast's manifest tool or Neynar.
  app.get("/.well-known/farcaster.json", (c) => {
    const origin = new URL(c.req.url).origin;
    const miniapp: any = {
      version: "1",
      name: "POSSESSIO Radar",
      iconUrl: consoleUrl + "/icon-1024.png",
      homeUrl: origin + "/feed",
      splashImageUrl: consoleUrl + "/splash-200.png",
      splashBackgroundColor: "#ffffff",
      subtitle: "AI live memecoin selection",
      description: "What an autonomous trader screens from, live. Solana / pump.fun, pre-DEX — with the bucket-C conviction tag graded forward against real outcomes.",
      primaryCategory: "finance",
      tags: ["solana", "trading", "memecoins", "ai", "radar"],
    };
    const body: any = { miniapp, frame: miniapp }; // frame alias for older clients
    const assoc = (env as any).FC_ACCOUNT_ASSOCIATION;
    if (assoc) { try { body.accountAssociation = JSON.parse(assoc); } catch { /* leave unverified */ } }
    return c.json(body);
  });
  // Bitcoin news strip — cached RSS aggregate (display only, public, free).
  app.get("/radar/news", async (c) => c.json({ items: await getNews() }));
  // ---- THE HEALTH VERDICT (RESEARCH_RadarMethod §5, the False-Green fix). ----
  // The tape died silently for ~50h under a green banner because nothing
  // ESCALATED feed_status staleness. This route IS the escalation: feed_status
  // → healthVerdict → a loud red naming the dead feed and its age. The console
  // banner reads this; a dead critical feed is now structurally impossible to
  // miss. Free + public: it exposes ops liveness, never method params.
  app.get("/radar/health", async (c) => {
    const { results } = await c.env.RADAR_DB.prepare(
      `SELECT scan, last_ok_ms, last_err_ms, last_err FROM feed_status`
    ).all();
    return c.json(healthVerdict(results as unknown as FeedStatusRow[], Date.now(), c.env.TAPE_HOST));
  });
  // Layer 3 VERIFY-FIRST surface: WS engine state, parse rate, raw samples.
  // Aggregates + public mint data only — nothing here leaks method params.
  // ZOMBIE FIX (2026-08-12): under TAPE_HOST="railway" the local DO is dormant
  // BY DESIGN — querying it reported the dead-by-design DO's state as if it
  // were the tape (a False Green mirror: a green banner over a dormant engine,
  // or a red one over a healthy Railway tape). The truth for the Railway tape
  // is its pumptapeTrades heartbeat in feed_status — serve that instead.
  app.get("/radar/ws-status", async (c) => {
    if (c.env.TAPE_HOST === "railway") {
      const row = await c.env.RADAR_DB.prepare(
        `SELECT scan, last_ok_ms, last_err_ms, last_err FROM feed_status
          WHERE scan='pumptapeTrades'`
      ).first<any>();
      const now = Date.now();
      const okMs = row?.last_ok_ms ?? null;
      const ageS = okMs != null ? Math.round((now - okMs) / 1000) : null;
      const alive = ageS != null && ageS <= 15 * 60
        && !(row?.last_err_ms != null && row.last_err_ms > okMs);
      return c.json({
        host: "railway",
        alive,
        last_heartbeat_ms: okMs,
        heartbeat_age_s: ageS,
        last_err: alive ? null : (row?.last_err ?? (okMs == null ? "never heartbeated" : null)),
        note: "per-trade tape runs on Railway; this is its D1 heartbeat, the local DO is dormant by design",
      });
    }
    const ns = (c.env as any).PUMPTAPE as DurableObjectNamespace | undefined;
    if (!ns) return c.json({ error: "PUMPTAPE_NOT_BOUND" }, 503);
    const stub = ns.get(ns.idFromName("main"));
    const r = await stub.fetch("https://pumptape/status");
    return new Response(r.body, { headers: { "content-type": "application/json" } });
  });
  // HOURLY DESK-REACH CHECK (2026-08-15, Architect: "which coins hit 100k
  // every hour and if they got to the desk, not just tape"). Free + public,
  // same class as /radar/health — an ops/measurement aggregate, not a method
  // param. Built so the overnight measurement trigger needs a plain curl,
  // no D1 connector (this org's routine sessions can't carry one at all —
  // measured directly, create_trigger's connectors param is unavailable here).
  // Same genuine-vs-artifact split established this session: mc_at_birth_usd
  // < 20000 is a real bonding-curve launch price; >= 20000 is the separate,
  // still-undiagnosed "already worth millions the first time we ever saw it"
  // cohort, reported but not analyzed here.
  app.get("/radar/hourly-100k", async (c) => {
    const db = c.env.RADAR_DB;
    const since = Date.now() - 3600_000;
    const { results } = await db.prepare(
      `SELECT token_address, symbol, mc_at_birth_usd, mc_peak_usd, pumpfun_first_seen_ms,
              (SELECT COUNT(*) FROM candidates cd WHERE cd.token_address = b.token_address) AS reached_desk,
              (SELECT outcome FROM candidates cd WHERE cd.token_address = b.token_address) AS desk_outcome
         FROM births b
        WHERE pumpfun_first_seen_ms >= ?1 AND mc_peak_usd >= 100000
        ORDER BY mc_peak_usd DESC`
    ).bind(since).all();
    const rows = results as any[];
    const genuine = rows.filter((r) => Number(r.mc_at_birth_usd) < 20000);
    const artifact = rows.filter((r) => Number(r.mc_at_birth_usd) >= 20000);
    const reached = genuine.filter((r) => Number(r.reached_desk) > 0);
    const missed = genuine.filter((r) => Number(r.reached_desk) === 0)
      .map((r) => ({ symbol: r.symbol, token_address: r.token_address, peak_mc: r.mc_peak_usd }));
    return c.json({
      window_ms: 3600_000,
      since,
      genuine_100k_hits: genuine.length,
      reached_desk: reached.length,
      missed,
      artifact_cohort_count: artifact.length,
      artifact_top: artifact[0] ? { symbol: artifact[0].symbol, peak_mc: artifact[0].mc_peak_usd } : null,
    });
  });
  app.get("/radar/candidates", async (c) => {
    const db = c.env.RADAR_DB;
    const dexCols = `graduated_ms, dex_price_usd, dex_mc, dex_peak_mc, dex_liq_usd,
              dex_vol_h1, dex_chg_m5, dex_chg_h1, dex_last_ms`;
    // img: the coin's launch image (pump.fun image_uri), pulled free from the
    // stored birth JSON — makes cards recognizable at a glance.
    // json_valid guard (AUDIT 2026-07-14, R-1): rows written before the
    // watcher fix hold TRUNCATED (invalid) JSON, and SQLite's json_extract
    // THROWS "malformed JSON" on those — one historical bad row would 500
    // this whole route. The CASE turns a bad row into img=NULL, never a 500.
    const imgCol = (t: string) =>
      `(SELECT CASE WHEN json_valid(b.raw_birth_json)
                    THEN json_extract(b.raw_birth_json,'$.image_uri') END
          FROM births b WHERE b.token_address=${t}.token_address) AS img`;
    const live = await db.prepare(
      `SELECT token_address, symbol, name, qualified_ms, entry_mc, entry_age_sec,
              peak_mc, last_mc, last_tracked_ms, gate_rug, gate_session,
              strat_take, entry_vel, gate_dev, top_holder_share, creator, dev_prior_launches,
              ${imgCol("candidates")}, ${dexCols}
         FROM candidates WHERE outcome='live' ORDER BY qualified_ms DESC LIMIT 40`
    ).all();
    const recent = await db.prepare(
      `SELECT token_address, symbol, name, qualified_ms, entry_mc, peak_mc,
              last_mc, outcome, outcome_ms, creator, dev_prior_launches, top_holder_share,
              ${imgCol("candidates")}, ${dexCols}
         FROM candidates WHERE outcome!='live' ORDER BY outcome_ms DESC LIMIT 40`
    ).all();
    const tally = await db.prepare(
      `SELECT outcome, COUNT(*) AS n FROM candidates GROUP BY outcome`
    ).all();
    // MACRO — live BTC from our OWN Chainlink-on-Base oracle (regime_ticks,
    // written every cron), with 15m/1h slope. The tide: entries into a falling
    // BTC underperform (measured), so this is live enter/hold context for the
    // human, not decoration.
    const bnow = Date.now();
    const btc = await db.prepare(
      `SELECT
         (SELECT btc_usd FROM regime_ticks ORDER BY ts_ms DESC LIMIT 1)                         AS now,
         (SELECT MAX(ts_ms) FROM regime_ticks)                                                   AS at,
         (SELECT btc_usd FROM regime_ticks WHERE ts_ms <= ?1 ORDER BY ts_ms DESC LIMIT 1)        AS m15,
         (SELECT btc_usd FROM regime_ticks WHERE ts_ms <= ?2 ORDER BY ts_ms DESC LIMIT 1)        AS h1`
    ).bind(bnow - 900_000, bnow - 3_600_000).first();
    // NEWBORN RATE — the regime read (Architect 2026-07-16: "watch the newborn
    // rate and confirm it works with our strategy"). pump.fun launches in the
    // last hour: high = attention/liquidity present (a time to trade), low = the
    // sit-out regime that the market bottomed into today. The strategy's edge
    // needs coins actually reaching the band, which needs newborns.
    const newborn = await db.prepare(
      `SELECT COUNT(*) AS n60 FROM births WHERE pumpfun_first_seen_ms > ?1`
    ).bind(bnow - 3_600_000).first();
    // Screen 0 — the early radar (0-4min, crossed $4k). Same ratified public
    // surface: which coins, never entry/exit prices or size.
    const early = await db.prepare(
      // cur_mc/cur_ms (2026-08-10): the LIVE price for the card. screenScan has
      // written one mc_ticks sample per minute for every watching early all
      // along — but this route only served first_hit_mc, so the desk rendered
      // birth prices forever (+0% on every card; MEASURED: 52 rows, zero mc
      // changes across 75s). Serve the freshest tick; no schema change needed.
      `SELECT token_address, symbol, name, first_hit_ms, first_hit_mc, age_sec_at_hit,
              peak_mc, play_outcome, play_exit_mc, rungs_filled, levels, compound_mult,
              ws, t4k_ms, buys_hit, sells_hit, sol_net_hit, uniq_buyers_hit, top_buyer_share,
              graduated_ms, dex_mc, dex_peak_mc, dex_liq_usd, dex_vol_h1, dex_last_ms,
              (SELECT m.mc FROM mc_ticks m WHERE m.token_address=earlies.token_address
                ORDER BY m.ms DESC LIMIT 1) AS cur_mc,
              (SELECT m.ms FROM mc_ticks m WHERE m.token_address=earlies.token_address
                ORDER BY m.ms DESC LIMIT 1) AS cur_ms,
              ${imgCol("earlies")},
              (SELECT creator FROM births b WHERE b.token_address=earlies.token_address) AS creator,
              (SELECT dev_prior_launches FROM candidates cc WHERE cc.token_address=earlies.token_address) AS dev_prior_launches
         FROM earlies WHERE status='watching'
        ORDER BY first_hit_ms DESC LIMIT 40`
    ).all();
    // §0 EARLY PLAY paper tally: entry=$4k crossing, target=$8k, exit at age
    // 2:00. avg_mult = paper multiple on resolved plays (exit/entry).
    const earlyPlay = await db.prepare(
      `SELECT play_outcome, COUNT(*) AS n,
              ROUND(AVG(play_exit_mc / first_hit_mc), 2) AS avg_mult
         FROM earlies WHERE play_outcome IS NOT NULL
        GROUP BY play_outcome`
    ).all();
    // CONVICTION FORWARD SCORECARD (migration 0016): the radar grading its own
    // entry hypothesis on coins the thresholds never saw. Only RESOLVED coins
    // count — a concluded §0 play OR born >20min ago (past the run window) — so a
    // still-cooking GO is not scored as a loss. peak = the realized max
    // (post-grad dex_peak_mc if it ran on DEX, else the curve peak_mc).
    const convResolvedBefore = Date.now() - 20 * 60_000;
    const scorecard = await db.prepare(
      `SELECT conv_tag AS tag, COUNT(*) AS n,
              SUM(CASE WHEN COALESCE(dex_peak_mc, peak_mc, 0) >= 20000 THEN 1 ELSE 0 END) AS win20,
              SUM(CASE WHEN conv_entry_mc > 0
                        AND COALESCE(dex_peak_mc, peak_mc, 0) >= 2*conv_entry_mc THEN 1 ELSE 0 END) AS win2x
         FROM earlies
        WHERE conv_tag IS NOT NULL
          AND (play_outcome IS NOT NULL OR first_hit_ms < ?1)
        GROUP BY conv_tag`
    ).bind(convResolvedBefore).all();
    // JUST LISTED (2026-08-10, Architect: "dexscreener/solana/pumpfun/newest —
    // that's the exact thing we need on our feed"). Births whose DEX pair was
    // first sighted in the last 20 minutes, newest first — the hunting ground
    // where tonight's graded edges live (dip-flip entries, the ≥30% liq/mc
    // cohort that produced 43 of 43 runners). curve_pair_seen_ms is the
    // earliest stamp (discoveryScan per-minute today; the tape's PumpPortal
    // migration stream sub-second once keyed) with dexscreener_first_seen_ms
    // as the completed-discovery fallback.
    const listings = await db.prepare(
      `SELECT token_address, symbol, name, creator,
              COALESCE(curve_pair_seen_ms, dexscreener_first_seen_ms) AS listed_ms,
              graduation_dex, mc_at_discovery_usd, mc_peak_usd,
              (SELECT CASE WHEN json_valid(b2.raw_birth_json)
                           THEN json_extract(b2.raw_birth_json,'$.image_uri') END
                 FROM births b2 WHERE b2.token_address=births.token_address) AS img
         FROM births
        WHERE COALESCE(curve_pair_seen_ms, dexscreener_first_seen_ms) >= ?1
        ORDER BY listed_ms DESC LIMIT 12`
    ).bind(Date.now() - 20 * 60_000).all();
    // BORN LOADED fast lane (RESEARCH_RadarMethod §3 + RESEARCH_ExitAlgo F7).
    // WARM leads — the measured entry window (24.6% forward-2x from the
    // 3-min price) — then fresh un-read stamps (the watchlist), then hot
    // (informational: the move already ran, 0.7% reach 3x from there).
    // down/flat are dropped (EV 0.82/1.01 — noise).
    // Aliases match the candidate card shape (qualified_ms/entry_mc) so the
    // console renders these with the existing card machinery; cur_mc is the
    // freshest tape tick for a live +% read. Same ratified public surface:
    // which coins, never entry/exit prices or size.
    //
    // WINDOW FIX (2026-08-15, measured live against D1): this used to be a
    // 90min window, and momentum sorts warm picks ABOVE age entirely — a
    // token tagged warm at minute 3 outranks everything for the rest of the
    // 90 minutes regardless of how stale it gets. Measured: with the 90min
    // window, ALL 12 slots this endpoint returns were warm picks 8-84
    // minutes old — the desk's top-priority render slot (mergeRender() puts
    // this array first, ahead of candidates) was permanently squatted by
    // hour-old cards. Worse: mc_ticks correctly STOPS once a token's
    // candidate lifecycle resolves (target/stop/timestop) — measured on one
    // of those stale picks, its tape's last tick was 54min old, matching its
    // resolution almost exactly — so the displayed cur_mc was frozen too,
    // for the honest reason that tracking had genuinely ended, not a bug in
    // the tape itself. The desk kept showing it as a live pick regardless.
    // 12 minutes keeps a warm tag visible for a real observing window past
    // its ~3-4.5min resolution point (FAST_MOMENTUM_AT_MS+TOL, screen.ts)
    // without ever showing something whose tracking has already ended.
    // Verified live: the 90min window returned 12/12 warm, 8-84min old; the
    // 12min window returns 1 warm (8min) + 11 genuinely fresh (<5min) picks.
    const fastlane = await db.prepare(
      `SELECT f.token_address, f.symbol, f.name,
              f.sighted_ms AS qualified_ms, f.birth_mc AS entry_mc,
              f.age_at_sight_sec, f.score, f.band, f.regime_hot, f.dev_prior,
              f.mc3m, f.momentum, f.peak_mc, f.peak_mult, f.outcome,
              (SELECT m.mc FROM mc_ticks m WHERE m.token_address=f.token_address
                ORDER BY m.ms DESC LIMIT 1) AS cur_mc,
              (SELECT m.ms FROM mc_ticks m WHERE m.token_address=f.token_address
                ORDER BY m.ms DESC LIMIT 1) AS cur_ms,
              (SELECT CASE WHEN json_valid(b.raw_birth_json)
                           THEN json_extract(b.raw_birth_json,'$.image_uri') END
                 FROM births b WHERE b.token_address=f.token_address) AS img,
              (SELECT creator FROM births b WHERE b.token_address=f.token_address) AS creator
         FROM fastlane f
        WHERE f.sighted_ms >= ?1
          AND COALESCE(f.momentum,'') NOT IN ('down','flat')
        ORDER BY CASE WHEN f.momentum='warm' THEN 0
                      WHEN f.momentum IS NULL THEN 1
                      ELSE 2 END,
                 f.score DESC, f.sighted_ms DESC LIMIT 12`
    ).bind(Date.now() - 12 * 60_000).all();
    // Fast-lane forward scorecard: graded stamps only (>=6h old). THIS is the
    // number that ratifies or kills the method — research said 22.4% 2x in the
    // core band; the forward tally is the test that counts.
    const fastlaneStats = await db.prepare(
      `SELECT band, COUNT(*) AS n,
              SUM(outcome='2x') AS n2x,
              SUM(outcome IN ('2x','1_5x')) AS n15x,
              SUM(outcome='untracked') AS untracked
         FROM fastlane WHERE outcome IS NOT NULL
        GROUP BY band`
    ).all();
    // The oscillation tape for everything currently on screen. 25min covers
    // the longest possible early->qualify->track life; closed coins age out.
    const ticksRaw = await db.prepare(
      `SELECT token_address, ms, mc, sol_reserves, vol_m5 FROM mc_ticks
        WHERE ms >= ?1 ORDER BY ms ASC`
    ).bind(Date.now() - 25 * 60_000).all();
    const ticks: Record<string, { ms: number; mc: number; sol: number | null; v5: number | null }[]> = {};
    for (const t of ticksRaw.results as any[]) {
      (ticks[t.token_address] ??= []).push({ ms: t.ms, mc: t.mc, sol: t.sol_reserves, v5: t.vol_m5 });
    }
    // NOTABLE — coins the §1 gate never promoted, that hit a real peak anyway
    // (2026-08-15, Architect: "tape watching and it making it to the whole 15
    // coins... is the whole point"). live/early/recent above ALL read from
    // earlies/candidates — an earlies row that times out to status='missed'
    // (7min, unconditional) drops out of `early` (status!='watching') and was
    // never a candidate, so it can never reach `recent` either. It vanishes
    // from every query this route runs, permanently, the instant it times
    // out — even though the tape kept recording its real price the whole
    // time and discoveryScan (watcher.ts) keeps births.mc_peak_usd accurate
    // independent of earlies/candidates status entirely. This route was the
    // gap, not the tracking. Sourced from births directly for that reason —
    // the one place a real peak survives regardless of what the gate decided.
    // mc_at_birth_usd < 20000 excludes the separate, unresolved "already
    // worth millions the FIRST time we ever saw it" cohort (a birthScan
    // discovery-lag question, not a genuine organic pump) — kept out here
    // rather than shown as a false "win," pending its own investigation.
    const notable = await db.prepare(
      `SELECT token_address, symbol, name, mc_at_birth_usd AS entry_mc, mc_peak_usd AS peak_mc,
              pumpfun_first_seen_ms AS qualified_ms,
              CASE WHEN json_valid(raw_birth_json)
                   THEN json_extract(raw_birth_json,'$.image_uri') END AS img,
              creator
         FROM births
        WHERE pumpfun_first_seen_ms >= ?1
          AND mc_at_birth_usd < 20000
          AND mc_peak_usd >= 50000
          AND token_address NOT IN (SELECT token_address FROM candidates)
        ORDER BY mc_peak_usd DESC LIMIT 10`
    ).bind(Date.now() - 45 * 60_000).all();
    return c.json({
      live: live.results,
      recent: recent.results,
      early: early.results,
      listings: listings.results,
      fastlane: fastlane.results,
      fastlane_stats: fastlaneStats.results,
      notable: notable.results,
      earlyPlay: earlyPlay.results,
      scorecard: scorecard.results,
      btc,
      ticks,
      tally: tally.results,
      newborn_rate: newborn?.n60 ?? 0,
      method: "RULEBOOK §1 — pre-DEX, 4-7min, ~$10k entry · gate: momentum + fresh-dev + rug (top-holder) · winners run to +50% / stop -40% / 10min time-stop (paper-only)",
    });
  });

  // ---- routes: the measurements (the PAID API). ----
  // PRODUCT BOUNDARY (paid routes only, HIGH if relaxed): no route below
  // returns status='watching'. The live-selection feed above is the ratified
  // exception; these aggregate/discovered-only routes are unchanged.

  // R-1/R-2 REFRAME (2026-07-07): 'discovered' = GRADUATED (first non-pumpfun
  // pair, the $69K surface). gap_ms = birth -> graduation, a winners-only
  // survivorship stat (~2% lore prior; first real measurement is the tape's).
  // graduation-rate-per-hour is the measured Session Gate signal.
  // All outputs are AGGREGATES - never rows, never 'watching' addresses.
  app.get("/radar/gap-stats", async (c) => {
    const db = c.env.RADAR_DB;
    const counts = await db.prepare(
      `SELECT COUNT(*) AS births_total,
              SUM(status='watching')   AS watching_count,
              SUM(status='discovered') AS graduated_count,
              SUM(status='expired')    AS expired_count
         FROM births`
    ).first<any>();
    const grad = await db.prepare(
      `SELECT AVG(gap_ms) AS avg_ms, MIN(gap_ms) AS min_ms, MAX(gap_ms) AS max_ms
         FROM births WHERE status='discovered'`
    ).first<any>();
    // median + quartiles via ORDER/OFFSET (SQLite has no percentile fn)
    const pct = async (frac: number) => {
      const n = Number(counts?.graduated_count ?? 0);
      if (!n) return null;
      const row = await db.prepare(
        `SELECT gap_ms FROM births WHERE status='discovered'
          ORDER BY gap_ms LIMIT 1 OFFSET ?1`
      ).bind(Math.min(n - 1, Math.floor(n * frac))).first<any>();
      return row?.gap_ms ?? null;
    };
    // telemetry: the machine's OWN indexing latency (curve sighting), kept
    // separate so it is never again confused with the market.
    const curve = await db.prepare(
      `SELECT COUNT(*) AS n, AVG(curve_pair_seen_ms - pumpfun_first_seen_ms) AS avg_ms
         FROM births WHERE curve_pair_seen_ms IS NOT NULL`
    ).first<any>();
    // Segment graduations by dex (migration 0004): true migrations
    // (pumpswap/raydium) vs side-pools. An aggregate breakdown - a count per
    // dexId, no rows/addresses - stays inside the product boundary.
    const byDex = await db.prepare(
      `SELECT graduation_dex AS dex, COUNT(*) AS n,
              AVG(gap_ms) AS avg_gap_ms, MIN(gap_ms) AS min_gap_ms
         FROM births WHERE status='discovered'
        GROUP BY graduation_dex ORDER BY n DESC`
    ).all();
    // R-4: peak-MC distribution — the trade window (birth->pump), not just
    // graduation. Generic percentiles only; any band (8-13k) is a PRIVATE
    // read-time threshold, never exposed here (Sec6).
    const peak = await db.prepare(
      `SELECT COUNT(*) AS n, MAX(mc_peak_usd) AS max_mc,
              AVG(mc_peak_usd) AS avg_mc
         FROM births WHERE mc_peak_usd IS NOT NULL`
    ).first<any>();
    const total = Number(counts?.births_total ?? 0);
    const graduated = Number(counts?.graduated_count ?? 0);
    return c.json({
      births_total: total,
      watching_count: Number(counts?.watching_count ?? 0),
      graduated_count: graduated,
      expired_count: Number(counts?.expired_count ?? 0),
      graduation_rate: total > 0 ? graduated / total : null,
      grad_gap_ms: {
        avg: grad?.avg_ms ?? null, min: grad?.min_ms ?? null, max: grad?.max_ms ?? null,
        p25: await pct(0.25), median: await pct(0.5), p75: await pct(0.75),
      },
      graduation_by_dex: byDex.results,
      peak_mc: { tracked: Number(peak?.n ?? 0), avg: peak?.avg_mc ?? null, max: peak?.max_mc ?? null },
      curve_index_telemetry: { seen: Number(curve?.n ?? 0), avg_ms: curve?.avg_ms ?? null },
    });
  });

  // §0 SESSION GATE — the latest real regime reading (sessiongate.ts writes it
  // on a cadence; R-8 re-armed above now that it does). Serves the friendly
  // task-spec shape AND the native keys xtrade's Sec0 reader consumes verbatim
  // (see sessionGateResponse's contract note). Latest row = today's (daily key,
  // recomputed intra-day), lexicographic DESC on the YYYY-MM-DD date.
  app.get("/radar/session-gate", async (c) => {
    const row = await c.env.RADAR_DB.prepare(
      `SELECT session_date, trailing_vol, avg_7d_vol, ratio, gate_pass,
              threshold_used, basis, recorded_ms
         FROM sessions ORDER BY session_date DESC LIMIT 1`
    ).first();
    return c.json(sessionGateResponse(row));
  });

  app.get("/radar/tape", async (c) => {
    const rows = await c.env.RADAR_DB.prepare(
      `SELECT token_address, symbol, pumpfun_first_seen_ms,
              dexscreener_first_seen_ms, gap_ms, mc_at_discovery_usd
         FROM births WHERE status='discovered'
        ORDER BY dexscreener_first_seen_ms DESC LIMIT 100`
    ).all();
    return c.json(rows.results);
  });

  return app;
}

// Acceptance (radar handoff §Acceptance items 5–7):
// 5. Unarmed: routes serve free, header TOLL_NOT_ARMED present.
// 6. Armed on base-sepolia with a test sink: unpaid request → HTTP 402 with payment
//    requirements; paid request via any x402 client → 200 + data; settlement visible
//    on-chain at the sink.
// 7. Boundary test unchanged: no route leaks 'watching' rows, armed or not.
