// Desk UI, end to end in headless Chromium: node worker/test/desk-ui.e2e.cjs
// Not part of npm test (CI has no browser). Needs the playwright package
// (PLAYWRIGHT_MODULE may point at it) and Chromium (CHROMIUM, default
// /opt/pw-browsers/chromium). Proves the reopened desk (2026-10-15):
//   - the Markets sheet opens the desk;
//   - a PAUSED radar (rows older than 6 h) shows "radar paused", no stale rows,
//     no demo coins and no invented regime, at any moment;
//   - a radar that pauses mid-session clears its rows;
//   - a fresh feed still reads live; an unreachable feed shows the LABELLED demo.
// Every request off 127.0.0.1 is aborted, so the radar feed is tested alone.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const ROOT = process.env.DESK_ROOT || path.join(__dirname, "..", "..", "public");
const PAUSED = fs.readFileSync(path.join(__dirname, "fixtures", "desk-feed-paused.json"));
// The same rows, re-stamped to a minute ago: what a running radar serves.
const restamp = (x, t) => Array.isArray(x) ? x.map((i) => restamp(i, t)) : (x && typeof x === "object")
  ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, ["last_tracked_ms", "qualified_ms", "first_hit_ms", "at"].includes(k) && typeof v === "number" ? t : restamp(v, t)])) : x;
const FEED = { stale: () => PAUSED, fresh: () => Buffer.from(JSON.stringify(restamp(JSON.parse(PAUSED), Date.now() - 60000))) };
const srv = http.createServer((q, r) => { const u = new URL(q.url, "http://x"); let p = path.join(ROOT, u.pathname === "/" ? "index.html" : u.pathname);
  if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { "content-type": p.endsWith(".html") ? "text/html" : p.endsWith(".js") ? "text/javascript" : "application/octet-stream" }); fs.createReadStream(p).pipe(r); });
srv.listen(0, "127.0.0.1", async () => {
  const base = `http://127.0.0.1:${srv.address().port}`;
  const b = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });
  let pass = 0, fail = 0; const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); c ? pass++ : fail++; };
  for (const mode of (process.env.DESK_MODES || "stale,fresh,down,flip").split(",")) {
    const ctx = await b.newContext(); const page = await ctx.newPage(); const errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    let polls = 0;   // "flip": the radar is fresh on the first poll, then pauses while the desk is open
    await ctx.route("**/api/radar/candidates*", (r) => {
      if (mode === "down") return r.fulfill({ status: 503, body: "" });
      const file = mode === "flip" ? (polls++ < 1 ? "fresh" : "stale") : mode;
      return r.fulfill({ status: 200, contentType: "application/json", body: FEED[file]() });
    });
    await ctx.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());   // isolate: no GeckoTerminal/DexScreener/WS
    await page.goto(base + "/index.html", { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(800);
    await page.click("#markets-link");
    ok(await page.isVisible("#mkts-desk"), `[${mode}] Markets sheet shows "AI Assisted Trading"`);
    // record EVERY value the regime line and the list ever show, not one snapshot
    await page.evaluate(() => { window.__seen = { regime: [], demo: 0 };
      const rg = document.getElementById("dk-regime"), li = document.getElementById("dk-list");
      new MutationObserver(() => window.__seen.regime.push(rg.textContent)).observe(rg, { childList: true, characterData: true, subtree: true });
      new MutationObserver(() => { if (/demo-|Desk\.pick\('demo/.test(li.innerHTML)) window.__seen.demo++; }).observe(li, { childList: true, subtree: true }); });
    await page.click("#mkts-desk");
    await page.waitForTimeout(300);
    ok(!(await page.isHidden("#desk-view")), `[${mode}] tapping it opens the desk`);
    await page.waitForTimeout(11000);   // past the 9 s regime timer and two feed polls
    const st = await page.evaluate(() => ({ note: document.getElementById("dk-dropnote").textContent, regime: document.getElementById("dk-regime").textContent, rows: document.querySelectorAll("#dk-list > *").length, html: document.getElementById("dk-list").innerHTML }));
    if (mode === "stale") {
      ok(/^radar paused · newest coin is \d+ days old · use 🔎 Find/.test(st.note), `[stale] honest note: "${st.note}"`);
      ok(st.regime.trim() === "● radar paused", `[stale] regime line: "${st.regime.trim()}" (no invented newborns/hr)`);
      ok(st.rows === 0, `[stale] no stale or demo coins listed (rows: ${st.rows})`);
      const seen = await page.evaluate(() => window.__seen);
      ok(!seen.regime.some((t) => /newborns\/hr/.test(t)), `[stale] no invented regime at ANY moment (${seen.regime.length} changes seen)`);
      ok(seen.demo === 0, `[stale] no demo coins at ANY moment`);
    } else if (mode === "flip") {
      const seen = await page.evaluate(() => window.__seen);
      ok(/^radar paused/.test(st.note) && st.rows === 0, `[flip] when the radar pauses mid-session, its rows are cleared (rows now: ${st.rows}, note: "${st.note.slice(0, 40)}")`);
      ok(seen.demo === 0, `[flip] and nothing falls back to demo coins`);
    } else if (mode === "down") {
      ok(/^preview · demo data \(live feed unreachable\)/.test(st.note), `[down] an unreachable feed shows the LABELLED demo preview: "${st.note}"`);
      ok(st.rows > 0, `[down] demo coins appear only here, under that label (rows: ${st.rows})`);
    } else {
      ok(/^live · \d+ in the entry window/.test(st.note), `[fresh] a fresh feed still reads live: "${st.note.slice(0, 60)}"`);
      ok(st.rows > 0 && !/demo-/.test(st.html), `[fresh] real coins listed (rows: ${st.rows})`);
    }
    ok(errs.length === 0, `[${mode}] no page errors${errs.length ? ": " + errs.join(" | ") : ""}`);
    await ctx.close();
  }
  console.log(`RESULT: ${pass}/${pass + fail} PASS`); await b.close(); srv.close(); process.exit(fail ? 1 : 0);
});
