// Desk UI, end to end in headless Chromium: node worker/test/desk-ui.e2e.cjs
// Not part of npm test (CI has no browser). Needs the playwright package
// (PLAYWRIGHT_MODULE may point at it) and Chromium (CHROMIUM, default
// /opt/pw-browsers/chromium). DESK_MODES picks scenarios (comma-separated);
// DESK_SHOT=<dir> saves a phone-width screenshot of each.
// Proves the reopened desk (2026-10-15):
//   - the Markets sheet opens the desk;
//   - a PAUSED radar (rows older than 6 h) shows "radar paused", none of its
//     rows (side lists included), no demo coins and no invented regime, at any
//     moment; a radar that pauses mid-session clears its rows;
//   - a fresh radar still reads live; when EVERY feed is down, the LABELLED demo;
//   - THE TWO LISTS: hand-picked trending first, then the verified feed, all
//     Solana, no Base screen, an unpriced entry is not buyable;
//   - the ＋ Trending / 🗑 delete buttons show only for an allowlisted wallet in
//     the mini app (including one that connects after the desk opened), and
//     call trendingAction with the right action;
//   - a feed that recovers from an outage replaces the demo for good; a feed
//     that answers with nothing is an honest empty list, never demo.
// Every request off 127.0.0.1 is aborted except the stubbed DexScreener and
// GeckoTerminal calls, so each scenario sees exactly the feeds it names.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const ROOT = process.env.DESK_ROOT || path.join(__dirname, "..", "..", "public");
const PAUSED = fs.readFileSync(path.join(__dirname, "fixtures", "desk-feed-paused.json"));
// The same rows, re-stamped to a minute ago: what a running radar serves.
const restamp = (x, t) => Array.isArray(x) ? x.map((i) => restamp(i, t)) : (x && typeof x === "object")
  ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, ["last_tracked_ms", "qualified_ms", "first_hit_ms", "at"].includes(k) && typeof v === "number" ? t : restamp(v, t)])) : x;
// A paused radar's side lists are as old as its rows; one stale listing proves none leak.
const OLD_LISTING = { token_address: "8sVRVdyb1LHHpjDp7wJx4Gx7U2yUBXXEEhTMLGm4RgDw", symbol: "OLDLIST", name: "an old listing", listed_ms: Date.now() - 51 * 86400000, mc_at_discovery_usd: 40000 };
const FEED = {
  stale: () => { const d = JSON.parse(PAUSED); d.listings = [OLD_LISTING]; return Buffer.from(JSON.stringify(d)); },
  fresh: () => Buffer.from(JSON.stringify(restamp(JSON.parse(PAUSED), Date.now() - 60000))),
};

// Synthetic coins (no real token names in a public repo). Base58, 43-44 chars.
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const mint = (n) => { let x = BigInt(n) * 0x9E3779B97F4A7C15n + 0x1234567n, s = ""; for (let i = 0; i < 44; i++) { s += B58[Number(x % 58n)]; x = x * 6364136223846793005n + 1442695040888963407n & ((1n << 128n) - 1n); } return s.slice(0, 44); };
const VER = [1, 2, 3, 4, 5].map((n) => ({ mint: mint(n), symbol: `VER${n}`, name: `Verified ${n}`, icon: null, priceUsd: 0.1 * n, mcapUsd: 1e6 * n, liquidityUsd: 200000 + n,
  holders: 1000 * n, top10Pct: 20 + n, organic: "high", change24hPct: n % 2 ? 12.5 : -8, firstPoolAt: Date.now() - n * 86400000 }));
const VERIFIED_BODY = JSON.stringify({ tokens: VER, matched: 5, dropped: {}, fetchedAt: Date.now(), source: "test", filters: {} });
const VERIFIED_EMPTY = JSON.stringify({ tokens: [], matched: 0, dropped: {}, fetchedAt: Date.now(), source: "test", filters: {} });
const TREND_PRICED = mint(11), TREND_UNPRICED = mint(12), FIND_SOL = mint(13), FIND_BASE = "0x00000000000000000000000000000000000000b5";
const ALLOWED = "vzQhfuJLKkj14yP8x3uP2J4XQSDWUVTE1CUbNsXygVK";   // the console's POSSESSIO_DESK_ALLOW default
const OUTSIDER = mint(99);
// DexScreener knows the priced trending coin and both finds; not the unpriced one.
const DEX = {
  [TREND_PRICED]: { chainId: "solana", symbol: "TRND", name: "Trend One", mc: 750000, h24: 30 },
  [FIND_SOL]: { chainId: "solana", symbol: "FINDS", name: "Found Sol", mc: 90000, h24: 5 },
  [FIND_BASE]: { chainId: "base", symbol: "FINDB", name: "Found Base", mc: 60000, h24: 1 },
};
const dexBody = (addrs) => JSON.stringify({ pairs: addrs.filter((a) => DEX[a]).map((a) => ({ chainId: DEX[a].chainId, baseToken: { address: a, symbol: DEX[a].symbol, name: DEX[a].name },
  marketCap: DEX[a].mc, liquidity: { usd: DEX[a].mc / 3 }, priceChange: { h24: DEX[a].h24 }, pairCreatedAt: Date.now() - 3 * 86400000 })) });
const GT_POOL = JSON.stringify({ data: [{ attributes: { name: "BASEMEME / WETH", market_cap_usd: "500000", price_change_percentage: { h1: "5", m5: "3" }, pool_created_at: new Date().toISOString() },
  relationships: { base_token: { data: { id: "base_0x00000000000000000000000000000000000000ba" } } } }] });

// radar: stale|fresh|flip|down · verified/trending: ok|404|503|recover · wallet: the stubbed mini app
const SCENARIOS = {
  stale:    { radar: "stale", verified: "404", trending: "404" },
  fresh:    { radar: "fresh", verified: "404", trending: "404" },
  down:     { radar: "down", verified: "503", trending: "503" },
  flip:     { radar: "flip", verified: "404", trending: "404" },
  lists:    { radar: "stale", verified: "ok", trending: "ok" },
  admin:    { radar: "stale", verified: "ok", trending: "ok", wallet: ALLOWED, lateReady: true },
  outsider: { radar: "stale", verified: "ok", trending: "ok", wallet: OUTSIDER },
  recover:  { radar: "down", verified: "recover", trending: "503" },
  empty:    { radar: "down", verified: "empty", trending: "none" },
};

const srv = http.createServer((q, r) => { const u = new URL(q.url, "http://x"); let p = path.join(ROOT, u.pathname === "/" ? "console.html" : u.pathname);
  if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { "content-type": p.endsWith(".html") ? "text/html" : p.endsWith(".js") ? "text/javascript" : "application/octet-stream" }); fs.createReadStream(p).pipe(r); });
srv.listen(0, "127.0.0.1", async () => {
  const base = `http://127.0.0.1:${srv.address().port}`;
  const b = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });
  let pass = 0, fail = 0; const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); c ? pass++ : fail++; };
  for (const mode of (process.env.DESK_MODES || Object.keys(SCENARIOS).join(",")).split(",")) {
    const sc = SCENARIOS[mode]; if (!sc) throw new Error(`unknown scenario ${mode}`);
    const ctx = await b.newContext(process.env.DESK_SHOT ? { viewport: { width: 390, height: 1600 }, deviceScaleFactor: 2 } : {});
    const page = await ctx.newPage(); const errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await ctx.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());   // isolate; the stubs below take precedence
    await ctx.route("https://api.dexscreener.com/**", (r) => r.fulfill({ status: 200, contentType: "application/json", body: dexBody(decodeURIComponent(new URL(r.request().url()).pathname.split("/").pop()).split(",")) }));
    await ctx.route("https://api.geckoterminal.com/**", (r) => r.fulfill({ status: 200, contentType: "application/json", body: GT_POOL }));
    let polls = 0;   // "flip": the radar is fresh on the first poll, then pauses while the desk is open
    await ctx.route("**/api/radar/candidates*", (r) => {
      if (sc.radar === "down") return r.fulfill({ status: 503, body: "" });
      const file = sc.radar === "flip" ? (polls++ < 1 ? "fresh" : "stale") : sc.radar;
      return r.fulfill({ status: 200, contentType: "application/json", body: FEED[file]() });
    });
    let vPolls = 0;
    await ctx.route("**/api/desk/verified*", (r) => {
      const st = sc.verified === "recover" ? (vPolls++ < 1 ? "503" : "ok") : sc.verified;
      if (st === "empty") return r.fulfill({ status: 200, contentType: "application/json", body: VERIFIED_EMPTY });
      return st === "ok" ? r.fulfill({ status: 200, contentType: "application/json", body: VERIFIED_BODY }) : r.fulfill({ status: Number(st), body: "" });
    });
    const trend = [{ mint: TREND_PRICED, addedAt: Date.now() - 1000 }, { mint: TREND_UNPRICED, addedAt: Date.now() - 2000 }], posts = [];
    await ctx.route("**/api/desk/trending*", async (r) => {
      if (sc.trending === "none") return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ trending: [] }) });
      if (sc.trending !== "ok") return r.fulfill({ status: Number(sc.trending), body: "" });
      if (r.request().method() === "POST") {
        const { action, mint: m } = JSON.parse(r.request().postData()); posts.push({ action, mint: m });
        const i = trend.findIndex((x) => x.mint === m);
        if (action === "add" && i < 0) trend.unshift({ mint: m, addedAt: Date.now() });
        if (action === "remove" && i >= 0) trend.splice(i, 1);
        return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(action === "add" ? { ok: true, added: i < 0 ? 1 : 0 } : { ok: true, removed: i >= 0 ? 1 : 0 }) });
      }
      return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ trending: trend }) });
    });
    if (sc.wallet) {
      // The mini app, as the Farcaster host would leave it: ready, with this
      // wallet. The page's own module assigns window.PossessioMiniApp; the
      // setter swallows that, so the desk sees only this stub.
      await page.addInitScript(([addr, late]) => {
        window.__trendCalls = [];
        const fake = { ready: !late, address: addr, keeper: "4FrJDJjw4Q9odZ1RFXceZDkUJD1JHM83R3k28pmbSBLn", reason: "",
          trendingAction: async ({ action, mint }) => { window.__trendCalls.push({ action, mint });
            const r = await fetch("/api/desk/trending", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action, mint }) });
            if (!r.ok) throw new Error("rejected " + r.status); return r.json(); } };
        Object.defineProperty(window, "PossessioMiniApp", { get: () => fake, set: () => {}, configurable: false });
      }, [sc.wallet, !!sc.lateReady]);
    }
    await page.goto(base + "/console.html", { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(800);
    await page.click("#markets-link");
    ok(await page.isVisible("#mkts-desk"), `[${mode}] Markets sheet shows "AI Assisted Trading"`);
    // record EVERY value the regime line and the list ever show, not one snapshot
    await page.evaluate(() => { window.__seen = { regime: [], demo: 0, demoBesideReal: 0 };
      const rg = document.getElementById("dk-regime"), li = document.getElementById("dk-list");
      new MutationObserver(() => window.__seen.regime.push(rg.textContent)).observe(rg, { childList: true, characterData: true, subtree: true });
      new MutationObserver(() => { const h = li.innerHTML, demo = /demo-|Desk\.pick\('demo/.test(h);
        if (demo) window.__seen.demo++;
        if (demo && /✓ verified|★ trending|🔎 your find/.test(h)) window.__seen.demoBesideReal++; }).observe(li, { childList: true, subtree: true }); });
    await page.click("#mkts-desk");
    await page.waitForTimeout(300);
    ok(!(await page.isHidden("#desk-view")), `[${mode}] tapping it opens the desk`);
    await page.waitForTimeout(sc.radar === "flip" || mode === "stale" || mode === "down" || mode === "fresh" ? 11000 : 6000);   // stale/flip: past the 9 s regime timer and two feed polls
    if (mode === "recover") { await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange"))); await page.waitForTimeout(6000); }
    const snap = () => page.evaluate(() => {
      const cards = [...document.querySelectorAll("#dk-list .coin")].map((el) => ({ text: el.textContent, html: el.innerHTML }));
      const order = [...document.querySelectorAll("#dk-list > *")].map((el) => el.classList.contains("dk-grp") ? "#" + el.textContent : ((el.querySelector(".cn .s") || {}).firstChild || {}).textContent.trim());   // the symbol, without its chain tag
      return { note: document.getElementById("dk-dropnote").textContent, regime: document.getElementById("dk-regime").textContent, rows: cards.length, cards, order, html: document.getElementById("dk-list").innerHTML };
    });
    const st = await snap();
    const seen = await page.evaluate(() => window.__seen);
    if (process.env.DESK_SHOT) await page.screenshot({ path: path.join(process.env.DESK_SHOT, `desk-${mode}.png`) });
    if (mode === "stale") {
      ok(/^verified feed unreachable · radar paused · newest coin is \d+ days old · use 🔎 Find/.test(st.note), `[stale] honest note: "${st.note}"`);
      ok(st.regime.trim() === "● radar paused", `[stale] regime line: "${st.regime.trim()}" (no invented newborns/hr)`);
      ok(st.rows === 0, `[stale] no stale or demo coins listed, side lists included (rows: ${st.rows})`);
      ok(!seen.regime.some((t) => /newborns\/hr/.test(t)), `[stale] no invented regime at ANY moment (${seen.regime.length} changes seen)`);
      ok(seen.demo === 0, `[stale] no demo coins at ANY moment`);
    } else if (mode === "flip") {
      ok(/radar paused/.test(st.note) && st.rows === 0, `[flip] when the radar pauses mid-session, its rows are cleared (rows now: ${st.rows}, note: "${st.note.slice(0, 60)}")`);
      ok(seen.demo === 0, `[flip] and nothing falls back to demo coins`);
    } else if (mode === "down") {
      ok(/^preview · demo data \(live feed unreachable\)/.test(st.note), `[down] with EVERY feed down, the LABELLED demo preview: "${st.note}"`);
      ok(st.rows > 0 && st.order[0] === "#Preview · not real coins", `[down] demo coins appear only here, under their own label (rows: ${st.rows}, first: ${st.order[0]})`);
    } else if (mode === "fresh") {
      ok(/radar live · \d+ in the entry window/.test(st.note), `[fresh] a fresh radar still reads live: "${st.note.slice(0, 70)}"`);
      ok(st.rows > 0 && !/demo-/.test(st.html) && st.order[0] === "#🛰 Radar screen", `[fresh] real radar coins listed under their label (rows: ${st.rows})`);
    } else if (mode === "empty") {
      ok(st.rows === 0 && seen.demo === 0, `[empty] feeds that answer with nothing are an honest empty list, never demo (rows: ${st.rows}, demo seen ${seen.demo}x)`);
      ok(/^0 verified · radar unreachable · use 🔎 Find/.test(st.note), `[empty] note: "${st.note}"`);
    } else if (mode === "recover") {
      ok(seen.demo > 0, `[recover] while every feed was down, the labelled demo showed`);
      ok(st.rows === VER.length && !/demo-/.test(st.html), `[recover] once the verified feed answers, its coins replace the demo (rows: ${st.rows})`);
      ok(/^5 verified · radar unreachable/.test(st.note), `[recover] the note says where the rows came from: "${st.note}"`);
      ok(seen.demoBesideReal === 0, `[recover] a demo coin never sits beside a real one (${seen.demoBesideReal} times)`);
      await page.waitForTimeout(5000);   // the demo timers keep running; they must not come back
      const later = await snap();
      ok(!/demo-/.test(later.html) && later.rows === VER.length, `[recover] and the demo stays gone (rows: ${later.rows})`);
    } else {
      // lists / admin / outsider: the production shape today (radar paused, both lists live)
      const want = ["#★ Trending · hand-picked", "TRND", TREND_UNPRICED.slice(0, 4) + "…" + TREND_UNPRICED.slice(-4), "#✓ Verified · newest Solana tokens", "VER1", "VER2", "VER3", "VER4", "VER5"];
      ok(JSON.stringify(st.order) === JSON.stringify(want), `[${mode}] trending first, then the verified feed, newest first: ${JSON.stringify(st.order)}`);
      ok(st.cards.every((c) => /SOL/.test(c.text) && !/ctag base/.test(c.html)), `[${mode}] every listed coin is on Solana (no Base screen)`);
      const unpriced = st.cards.find((c) => c.text.includes("no price yet"));
      ok(unpriced && /<button class="tbtn t10" disabled/.test(unpriced.html), `[${mode}] the unpriced trending entry says so, and its Buy is disabled`);
      ok(st.cards.find((c) => c.text.includes("TRND") && /\+30% 24h/.test(c.text)) && st.cards.find((c) => c.text.includes("VER1") && /\+13% 24h/.test(c.text)), `[${mode}] the card % is the labelled 24 h move`);
      ok(/^2 trending · 5 verified · radar paused · \d/.test(st.note), `[${mode}] note: "${st.note}"`);
      ok(st.cards.find((c) => c.text.includes("VER1") && /\+13% 24h1d old/.test(c.text)), `[${mode}] a coin's age reads as its age, not a second "24h"`);
      ok(seen.demo === 0, `[${mode}] no demo coins at ANY moment`);
      const adminBtns = (s) => s.cards.filter((c) => /Desk\.(un)?trend\(/.test(c.html)).length;
      if (mode !== "admin") {
        ok(adminBtns(st) === 0, `[${mode}] no ＋ Trending or 🗑 delete buttons ${mode === "lists" ? "without a wallet" : "for a wallet off the allowlist"} (${adminBtns(st)} cards had one)`);
        await page.fill("#dk-mintsearch", FIND_SOL); await page.click("text=🔎 Find"); await page.waitForTimeout(600);
        const f = await snap();
        ok(f.order[1] === "FINDS" && adminBtns(f) === 0, `[${mode}] and still none on a Solana find (${adminBtns(f)})`);
      } else {
        // The wallet connects AFTER the desk opened: the mini app announces
        // itself, and the buttons appear without waiting for a feed poll.
        ok(adminBtns(st) === 0, `[admin] before the mini app is ready, no buttons (${adminBtns(st)})`);
        await page.evaluate(() => { window.PossessioMiniApp.ready = true; window.dispatchEvent(new Event("possessio-miniapp")); });
        await page.waitForTimeout(150);
        Object.assign(st, await snap());
        const del = st.cards.filter((c) => /Desk\.untrend\(/.test(c.html)).length, add = st.cards.filter((c) => /Desk\.trend\(/.test(c.html)).length;
        ok(del === 2 && add === 0, `[admin] 🗑 delete on both trending cards, ＋ Trending on none of the feed (delete ${del}, add ${add})`);
        await page.fill("#dk-mintsearch", FIND_SOL); await page.click("text=🔎 Find"); await page.waitForTimeout(600);
        let f = await snap();
        ok(f.order[0] === "#🔎 Your finds" && f.order[1] === "FINDS" && /Desk\.trend\('/.test(f.cards[0].html), `[admin] a Solana find shows ＋ Trending (${f.order.slice(0, 3)})`);
        await page.click("#dk-list .coin >> nth=0 >> text=＋ Trending"); await page.waitForTimeout(800);
        f = await snap();
        let calls = await page.evaluate(() => window.__trendCalls);
        ok(JSON.stringify(calls) === JSON.stringify([{ action: "add", mint: FIND_SOL }]) && posts.length === 1, `[admin] ＋ Trending calls trendingAction add for that mint: ${JSON.stringify(calls)}`);
        ok(/Desk\.untrend\('/.test(f.cards[0].html) && !/Desk\.trend\('/.test(f.cards[0].html), `[admin] the list re-reads at once: the find now offers 🗑 delete`);
        await page.click("#dk-list .coin >> nth=0 >> text=✕ unpin"); await page.waitForTimeout(400);
        f = await snap();
        ok(f.order[0] === "#★ Trending · hand-picked" && f.order[1] === "FINDS", `[admin] unpinned, it sits at the top of trending: ${JSON.stringify(f.order.slice(0, 4))}`);
        await page.click("#dk-list .coin:has-text('TRND') >> text=🗑 delete"); await page.waitForTimeout(800);
        f = await snap();
        calls = await page.evaluate(() => window.__trendCalls);
        ok(calls.length === 2 && calls[1].action === "remove" && calls[1].mint === TREND_PRICED, `[admin] 🗑 delete calls trendingAction remove: ${JSON.stringify(calls[1])}`);
        ok(!f.order.includes("TRND") && f.order.filter((x) => x === "#★ Trending · hand-picked").length === 1, `[admin] and the coin is off the list: ${JSON.stringify(f.order.slice(0, 4))}`);
        await page.fill("#dk-mintsearch", FIND_BASE); await page.click("text=🔎 Find"); await page.waitForTimeout(600);
        f = await snap();
        ok(f.order[1] === "FINDB" && !/Desk\.(un)?trend\(/.test(f.cards[0].html), `[admin] a Base find gets no ＋ Trending (Solana only)`);
      }
    }
    ok(errs.length === 0, `[${mode}] no page errors${errs.length ? ": " + errs.join(" | ") : ""}`);
    await ctx.close();
  }
  console.log(`RESULT: ${pass}/${pass + fail} PASS`); await b.close(); srv.close(); process.exit(fail ? 1 : 0);
});
