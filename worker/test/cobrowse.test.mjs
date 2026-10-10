// node worker/test/cobrowse.test.mjs  -> RESULT: n/n PASS
// Co-Browse against a REAL Chromium: a stand-in for the Browser Run binding (acquire / connectSession / getLiveView /
// listSessions / closeSession / devtools.newTarget) that launches local Chrome processes and speaks CDP to them, plus
// the real D1 migrations on node:sqlite, and a local HTTP server for the pages. Only Cloudflare's own plumbing is
// replaced. No internet. A missing Chrome is a failure, not a skip.
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { callTool, sweep, usage, BUDGET, typingAct, checkUrl } from "../cobrowse.mjs";
import { typedDataFor, checkSignature } from "../act-approval.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const REPO = path.resolve(HERE, "../..");

// ---------------------------------------------------------------- Chrome
function findChrome() {
  const c = [process.env.CHROME_BIN, "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium",
             "/usr/bin/chromium-browser"];
  try { for (const d of fs.readdirSync("/opt/pw-browsers")) c.push(`/opt/pw-browsers/${d}/chrome-linux/chrome`); } catch { /* none */ }
  return c.find((p) => p && fs.existsSync(p));
}
const CHROME = findChrome();

class FakeBrowserRun {
  constructor() { this.s = new Map(); this.devtools = { newTarget: (id, url) => this.#newTarget(id, url) }; }
  async acquire() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cobrowse-"));
    const proc = spawn(CHROME, ["--headless=new", "--no-sandbox", "--no-first-run", "--disable-gpu", "--remote-debugging-port=0",
                                `--user-data-dir=${dir}`, "about:blank"], { stdio: "ignore" });
    const portFile = path.join(dir, "DevToolsActivePort");
    for (let i = 0; i < 100 && !fs.existsSync(portFile); i++) await new Promise((r) => setTimeout(r, 100));
    const port = Number(fs.readFileSync(portFile, "utf8").split("\n")[0]);
    const sessionId = randomUUID();
    this.s.set(sessionId, { proc, port, dir });
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    return { sessionId, targets: targets.map((t) => ({ id: t.id, type: t.type, url: t.url })) };
  }
  async #newTarget(id, url) {
    const { port } = this.s.get(id);
    const t = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url || "about:blank")}`, { method: "PUT" })).json();
    return { id: t.id, type: t.type, url: t.url };
  }
  async connectSession(id, { targetId }) {
    const sess = this.s.get(id);
    if (!sess) throw new Error("no such session");
    return { webSocket: { fetch: async () => {
      const ws = new WebSocket(`ws://127.0.0.1:${sess.port}/devtools/page/${targetId}`);
      await new Promise((res, rej) => { ws.addEventListener("open", res, { once: true }); ws.addEventListener("error", rej, { once: true }); });
      return { webSocket: { accept() {}, send: (d) => ws.send(d), close: () => ws.close(),
                            addEventListener: (...a) => ws.addEventListener(...a), removeEventListener: (...a) => ws.removeEventListener(...a) } };
    } } };
  }
  async getLiveView(id, { targetId, guardrails } = {}) {
    return { devtoolsFrontendUrl: `https://live.example.invalid/${id}/${targetId}${guardrails?.mode === "readonly" ? "?readonly" : ""}` };
  }
  async listSessions() { return [...this.s.keys()].map((sessionId) => ({ sessionId })); }
  async closeSession(id) {
    const sess = this.s.get(id);
    if (!sess) return "closed";
    sess.proc.kill("SIGKILL");
    this.s.delete(id);
    return "closed";
  }
  async limits() { return { fake: true }; }
  killAll() { for (const id of [...this.s.keys()]) this.closeSession(id); }
}

// ---------------------------------------------------------------- D1 on node:sqlite, with the real migrations
function makeDb() {
  const sql = new DatabaseSync(":memory:");
  for (const m of ["0033_act_approvals.sql", "0034_cobrowse.sql"])
    sql.exec(fs.readFileSync(path.join(REPO, "radar/migrations", m), "utf8"));
  const db = {
    raw: sql,
    prepare(q) {
      let args = [];
      const st = sql.prepare(q.replace(/\?(\d+)/g, "?"));
      // D1 numbers its parameters; node:sqlite binds positionally, so expand ?1 ?1 into repeated positions
      const order = [...q.matchAll(/\?(\d+)/g)].map((m) => Number(m[1]) - 1);
      const api = {
        bind(...a) { args = order.map((i) => a[i]); return api; },
        async first() { return st.get(...args) ?? null; },
        async all() { return { results: st.all(...args) }; },
        async run() { const r = st.run(...args); return { meta: { changes: Number(r.changes) } }; },
      };
      return api;
    },
  };
  return db;
}

// ---------------------------------------------------------------- pages
const PAGES = {
  "/form": `<html><head><title>Form</title></head><body><h1>FORM-PAGE</h1>
    <form action="/done" method="get"><input id="q" name="q"><input id="pw" type="password" name="pw"><button type="submit">send</button></form>
    <button id="go" onclick="this.textContent='GO-CLICKED'">go</button></body></html>`,
  "/page2": `<html><head><title>Two</title></head><body><p>PAGE-TWO-TEXT</p></body></html>`,
};
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/done") { res.writeHead(200, { "content-type": "text/html" }); return res.end(`<html><head><title>Done</title></head><body>DONE q=${u.searchParams.get("q")}</body></html>`); }
  const body = PAGES[u.pathname];
  res.writeHead(body ? 200 : 404, { "content-type": "text/html" });
  res.end(body || "nope");
});
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${srv.address().port}`;

// ---------------------------------------------------------------- tests
const results = [];
async function test(name, fn) {
  try { await fn(); results.push([name, true]); } catch (e) { results.push([name, false, e?.message]); }
}
const throws = async (fn, re) => {
  try { await fn(); } catch (e) { if (re && !re.test(e.message)) throw new Error("wrong reason: " + e.message); return e; }
  throw new Error("did not throw");
};

const approver = privateKeyToAccount(generatePrivateKey());
const browser = new FakeBrowserRun();
const db = makeDb();
let clock = Date.now();
const deps = { browser, db, now: () => clock, approver: approver.address, chainId: 8453 };
const call = (name, args) => callTool(name, args, deps);

async function approve(act) {
  // the human's side, for real: sign the stored typed data with the approver key, verify it as the worker would
  const row = db.raw.prepare("SELECT * FROM act_approvals WHERE act = ?").get(act);
  const rec = { act: row.act, title: row.title, summary: row.summary, approver: row.approver,
                validUntil: Number(row.valid_until), chainId: Number(row.chain_id) };
  const sig = await approver.signTypedData(typedDataFor(rec));
  const signer = await checkSignature(rec, sig, Math.floor(clock / 1000));
  db.raw.prepare("UPDATE act_approvals SET signature = ?, signer = ?, signed_ms = ? WHERE act = ?").run(sig, signer, clock, act);
  return row;
}

await test("Chrome is present (a missing browser is a failure, not a skip)", () => { if (!CHROME) throw new Error("no Chrome found; set CHROME_BIN"); });

let S;
await test("browse_open opens a session at the URL and returns act and watch-only Live View links", async () => {
  const r = await call("browse_open", { seat: "CODE", url: BASE + "/form" });
  S = r.session_id;
  if (r.title !== "Form" || !r.url.endsWith("/form")) throw new Error(JSON.stringify(r));
  if (!r.live_view_act || !r.live_view_watch?.endsWith("?readonly")) throw new Error("live view links: " + JSON.stringify(r));
});
await test("a second session is refused while one is open (max one concurrent)", () =>
  throws(() => call("browse_open", { seat: "CODE", url: BASE + "/page2" }), /already open/));
await test("browse_read returns what is on screen", async () => {
  const r = await call("browse_read", { session_id: S });
  if (!r.text.includes("FORM-PAGE")) throw new Error(r.text);
});
await test("browse_click clicks by selector, and a missing element is an error", async () => {
  await call("browse_click", { session_id: S, selector: "#go", seat: "CODE" });
  const r = await call("browse_read", { session_id: S });
  if (!r.text.includes("GO-CLICKED")) throw new Error(r.text);
  await throws(() => call("browse_click", { session_id: S, selector: "#nope" }), /no element/);
});
await test("non-http(s) URLs are refused at the door", async () => {
  for (const u of ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "chrome://settings"])
    await throws(() => call("browse_goto", { session_id: S, url: u }), /refused|not a URL/);
  checkUrl("https://example.org/");
});

// ---- typing, gated by an RRC-style signed approval
let req;
await test("browse_type without a request or nonce is refused", async () => {
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "hello" }), /nonce is required/);
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "hello", nonce: "0".repeat(32) }), /no approval request/);
});
await test("browse_type_request files an act whose lines the worker wrote: page, field, exact text, Enter", async () => {
  req = await call("browse_type_request", { session_id: S, selector: "#q", text: "hello world", submit: true, seat: "CODE" });
  const row = db.raw.prepare("SELECT * FROM act_approvals WHERE act = ?").get(req.act);
  const lines = Object.fromEntries(JSON.parse(row.lines_json));
  if (lines.Text !== "hello world" || lines.Field !== "#q" || !lines.Action.includes("Enter") || !lines.Page.endsWith("/form"))
    throw new Error(row.lines_json);
  if (row.approver !== approver.address) throw new Error("approver " + row.approver);
  if (!req.approve_url.endsWith("#" + req.act) || !/^[0-9a-f]{32}$/.test(req.nonce)) throw new Error(JSON.stringify(req));
});
await test("the act id is the hash of exactly that action (session, page, field, text, Enter, nonce)", async () => {
  const row = db.raw.prepare("SELECT * FROM act_approvals WHERE act = ?").get(req.act);
  const { act } = typingAct({ sessionId: S, url: BASE + "/form", selector: "#q", text: "hello world", submit: true, nonce: req.nonce });
  if (act !== req.act || row.act !== act) throw new Error("act mismatch");
  const other = typingAct({ sessionId: S, url: BASE + "/form", selector: "#q", text: "hello world!", submit: true, nonce: req.nonce });
  if (other.act === act) throw new Error("one character must change the act");
});
await test("browse_type before the approver signs is refused, and nothing is typed", async () => {
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "hello world", submit: true, nonce: req.nonce }), /not approved yet/);
  const v = (await call("browse_read", { session_id: S })).url;
  if (!v.endsWith("/form")) throw new Error("page moved: " + v);
});
await test("a different text under the same nonce has no approval", async () => {
  await approve(req.act);
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "goodbye", submit: true, nonce: req.nonce }), /no approval request/);
});
await test("after the approver signs, browse_type types the exact text and presses Enter (the form submits)", async () => {
  const r = await call("browse_type", { session_id: S, selector: "#q", text: "hello world", submit: true, nonce: req.nonce, seat: "CODE" });
  if (r.typed !== "hello world") throw new Error(JSON.stringify(r));
  const page = await call("browse_read", { session_id: S });
  if (!page.text.includes("DONE q=hello world")) throw new Error(page.text);
});
await test("an approved typing act runs once (same page, field, text and nonce again: refused)", async () => {
  await call("browse_goto", { session_id: S, url: BASE + "/form" });
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "hello world", submit: true, nonce: req.nonce }), /already used/);
});
await test("an approval signed by someone other than the approver is refused", async () => {
  await call("browse_goto", { session_id: S, url: BASE + "/form" });
  const r2 = await call("browse_type_request", { session_id: S, selector: "#q", text: "x", seat: "CODE" });
  const row = db.raw.prepare("SELECT * FROM act_approvals WHERE act = ?").get(r2.act);
  const stranger = privateKeyToAccount(generatePrivateKey());
  const rec = { act: row.act, title: row.title, summary: row.summary, approver: row.approver, validUntil: Number(row.valid_until), chainId: 8453 };
  const sig = await stranger.signTypedData(typedDataFor(rec));
  db.raw.prepare("UPDATE act_approvals SET signature = ?, signer = ? WHERE act = ?").run(sig, stranger.address, r2.act);
  await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "x", nonce: r2.nonce }), /not from the configured approver/);
});
await test("an approval past its window is refused", async () => {
  const r3 = await call("browse_type_request", { session_id: S, selector: "#q", text: "late", seat: "CODE" });
  await approve(r3.act);
  const saved = clock; clock += 601_000;
  try { await throws(() => call("browse_type", { session_id: S, selector: "#q", text: "late", nonce: r3.nonce }), /window closed/); }
  finally { clock = saved; }
});
await test("password fields: the approval shows ••• with the length, the log never holds the text, the field is filled", async () => {
  const r4 = await call("browse_type_request", { session_id: S, selector: "#pw", text: "s3cret-pass", seat: "CODE" });
  const row = await approve(r4.act);
  const lines = Object.fromEntries(JSON.parse(row.lines_json));
  if (lines.Text.includes("s3cret") || !lines.Text.includes("11 characters")) throw new Error(lines.Text);
  const out = await call("browse_type", { session_id: S, selector: "#pw", text: "s3cret-pass", nonce: r4.nonce, seat: "CODE" });
  if (out.typed !== "•••") throw new Error(JSON.stringify(out));
  const all = JSON.stringify(db.raw.prepare("SELECT * FROM cobrowse_events").all());
  if (all.includes("s3cret")) throw new Error("password text reached the event log");
});

// ---- budget and lifecycle
await test("browse_status reports the budget and the open session", async () => {
  const st = await call("browse_status", {});
  if (st.budget.cap_s !== 9 * 3600 || st.open.length !== 1 || st.open[0].session_id !== S) throw new Error(JSON.stringify(st.budget));
});
await test("a session past its maximum age is closed before any further action", async () => {
  const saved = clock; clock += BUDGET.sessionMaxSeconds * 1000 + 1000;
  try { await throws(() => call("browse_read", { session_id: S }), /maximum and was closed/); }
  finally { clock = saved; }
  const row = db.raw.prepare("SELECT close_reason FROM cobrowse_sessions WHERE session_id = ?").get(S);
  if (row.close_reason !== "max age" || browser.s.has(S)) throw new Error(JSON.stringify(row));
});
await test("usage counts every session's span plus its keepAlive tail, over a rolling 31 days", async () => {
  const t = clock;
  db.raw.prepare("DELETE FROM cobrowse_sessions").run();
  db.raw.prepare("INSERT INTO cobrowse_sessions VALUES ('a','t','x',?,?,?,'closed','u')").run(t - 3600_000, t - 3600_000, t - 3000_000);   // 600 s
  db.raw.prepare("INSERT INTO cobrowse_sessions VALUES ('old','t','x',?,?,?,'closed','u')").run(t - 40 * 86400_000, 0, t - 39 * 86400_000); // outside window
  const u = await usage(db, t);
  if (u.used_s !== 600 + 60 || u.open_sessions !== 0) throw new Error(JSON.stringify(u));
});
await test("a new session is refused when it could push the window past 9 hours", async () => {
  const t = clock;
  db.raw.prepare("INSERT INTO cobrowse_sessions VALUES ('big','t','x',?,?,?,'closed','u')").run(t - 30_000_000, t - 30_000_000, t - 30_000_000 + 8.8 * 3600_000);
  await throws(() => call("browse_open", { seat: "CODE", url: BASE + "/page2" }), /budget: .* refused/);
  if (browser.s.size !== 0) throw new Error("a browser was launched despite the refusal");
});
await test("the sweeper closes idle sessions and marks ones Browser Run already ended", async () => {
  db.raw.prepare("DELETE FROM cobrowse_sessions").run();
  const r = await call("browse_open", { seat: "CODE", url: BASE + "/page2" });
  const idle = await sweep(browser, db, clock + BUDGET.idleCloseSeconds * 1000 + 1000);
  if (idle.length !== 1 || idle[0].reason !== "idle" || browser.s.has(r.session_id)) throw new Error(JSON.stringify(idle));
  const r2 = await call("browse_open", { seat: "CODE", url: BASE + "/page2" });
  await browser.closeSession(r2.session_id);                           // Browser Run ends it on its own
  const gone = await sweep(browser, db, clock);
  if (gone.length !== 1 || gone[0].reason !== "ended by Browser Run") throw new Error(JSON.stringify(gone));
});
await test("browse_close stops the session and frees the slot", async () => {
  const r = await call("browse_open", { seat: "CODE", url: BASE + "/page2" });
  await call("browse_close", { session_id: r.session_id, seat: "CODE" });
  if (browser.s.has(r.session_id)) throw new Error("browser still running");
  await throws(() => call("browse_read", { session_id: r.session_id }), /closed/);
});

browser.killAll(); srv.close();
for (const [n, ok, why] of results) console.log(`  [${ok ? "PASS" : "FAIL"}] ${n}${ok ? "" : " — " + why}`);
const n = results.filter((r) => r[1]).length;
console.log(`RESULT: ${n}/${results.length} PASS`);
process.exit(n === results.length ? 0 : 1);
