// Co-Browse: one live browser on possessio.io (Cloudflare Browser Run), driven by coding agents over /mcp and
// watched or taken over by humans through Live View.
//
// Budget (Architect, 2026-10-10: "We have paid worker but keep the limit so we have no overages"). Workers Paid
// includes 10 browser-hours a month and 10 concurrent browsers averaged monthly; beyond that is billed. This module
// keeps every 31-day window under BUDGET.capSeconds (9 h, one hour of margin), runs at most BUDGET.maxConcurrent
// browser at a time, closes any session at BUDGET.sessionMaxSeconds, and charges each session BUDGET.slackSeconds
// on top of its recorded span. A 31-day rolling window bounds every billing period, which is at most 31 days.
//
// keepAlive is Browser Run's inactivity timeout: a session with no CDP command for that long is closed. The tools
// connect per call, so while a human reads and signs a typing act the browser gets no commands at all. keepAlive and
// the sweeper's idle limit must outlast the approval window (first live drive, 2026-10-10: at 60 s, both sessions
// were ended by Browser Run 1-2 minutes after the type request, before anyone could sign).
//
// AI typing (Architect, same day: "Allow the ai typing tool" / "It will be gated by the mcp rrc hash signs"). The AI
// may type, but each typing action must first be approved: browse_type_request files an act-approval request whose
// act id is the keccak256 of the exact action (session, page, field, text hash, Enter or not). The human reads it on
// possessio.io/approve and signs it with the approver key (the RRC key by default). browse_type recomputes the act id
// from its own arguments and the live page, and types only if that act is approved by the approver, unexpired, and
// not used before. The worker writes the summary the human signs; the agent never does.
//
// The worker holds no signing key. Browser Run is driven over CDP through the binding (no npm dependency).
import { keccak256, toBytes, getAddress } from "viem";
import { normaliseRequest } from "./act-approval.mjs";

export const BUDGET = {
  capSeconds: 9 * 3600,          // of the 10 included browser-hours per month
  windowSeconds: 31 * 86400,     // rolling, so any billing period (<= 31 days) stays under the cap
  maxConcurrent: 1,              // of the 10 included (averaged monthly)
  sessionMaxSeconds: 15 * 60,    // any one session is closed at this age
  approvalSeconds: 9 * 60,       // a typing act must be signed within this long
  keepAliveMs: 10 * 60_000,      // Browser Run's inactivity timeout (10 min: the close-reasons page's maximum; the binding allows 20)
  idleCloseSeconds: 10 * 60,     // the sweeper closes a session with no tool call for this long
  sweepSeconds: 60,              // the cron interval: how late the sweeper can notice an age or idle limit
  slackSeconds: 60,              // charged per session on top of its recorded span (billing granularity). Every close path
                                 // records closed_ms at or after the browser's real end; a close that fails silently could
                                 // leave up to keepAlive uncounted, which the one-hour margin under the cap absorbs.
};
export const DEFAULT_APPROVER = "0x6f8d2C151424707f1C2a099230aCF2d72aA9A618"; // the RRC pin
const TEXT_MAX = 200;           // one approval line holds the full text
const READ_MAX = 20_000;

// ------------------------------------------------------------------ walls
export function checkUrl(url) {
  let u;
  try { u = new URL(String(url)); } catch { throw new Error("not a URL: " + url); }
  if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("refused: scheme " + u.protocol + " (http/https only)");
  return u.href;
}

// ------------------------------------------------------------------ budget
export async function usage(db, nowMs) {
  const since = nowMs - BUDGET.windowSeconds * 1000;
  const { results } = await db.prepare(
    "SELECT opened_ms, closed_ms FROM cobrowse_sessions WHERE COALESCE(closed_ms, ?1) > ?2").bind(nowMs, since).all();
  let used = 0, open = 0;
  for (const r of results || []) {
    const start = Math.max(Number(r.opened_ms), since);
    const end = r.closed_ms == null ? nowMs : Number(r.closed_ms);
    if (r.closed_ms == null) open++;
    used += Math.max(0, end - start) / 1000 + BUDGET.slackSeconds;
  }
  const cap = BUDGET.capSeconds;
  return { used_s: Math.round(used), cap_s: cap, remaining_s: Math.max(0, Math.round(cap - used)), open_sessions: open,
           window_days: BUDGET.windowSeconds / 86400, max_concurrent: BUDGET.maxConcurrent,
           session_max_s: BUDGET.sessionMaxSeconds };
}

/** Refuses with a reason unless a new session fits the budget even if it runs to its maximum age. */
export async function canOpen(db, nowMs) {
  const u = await usage(db, nowMs);
  if (u.open_sessions >= BUDGET.maxConcurrent) throw new Error(`budget: ${u.open_sessions} session(s) already open (max ${BUDGET.maxConcurrent}); close one first`);
  const need = BUDGET.sessionMaxSeconds + BUDGET.sweepSeconds + BUDGET.slackSeconds;   // the longest a session can run
  if (u.used_s + need > u.cap_s) throw new Error(`budget: ${u.used_s}s used of ${u.cap_s}s in the last ${u.window_days} days; a session may need ${need}s — refused to stay inside the included hours`);
  return u;
}

// ------------------------------------------------------------------ CDP over the binding
async function cdpSocket(browser, sessionId, targetId) {
  const conn = await browser.connectSession(sessionId, { targetId });
  const resp = await conn.webSocket.fetch("https://browser-binding.invalid", { headers: { Upgrade: "websocket" } });
  if (!resp.webSocket) throw new Error("Browser Run did not return a WebSocket");
  const ws = resp.webSocket;
  ws.accept();
  let next = 0;
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { done(); reject(new Error(`CDP ${method} timed out`)); }, 30_000);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data)); } catch { return; }
      if (m.id !== id) return;
      done();
      m.error ? reject(new Error(m.error.message)) : resolve(m.result);
    };
    const onClose = () => { done(); reject(new Error("CDP connection closed")); };
    const done = () => { clearTimeout(timer); ws.removeEventListener("message", onMsg); ws.removeEventListener("close", onClose); };
    ws.addEventListener("message", onMsg);
    ws.addEventListener("close", onClose);
    ws.send(JSON.stringify({ id, method, params }));
  });
  return { send, close: () => { try { ws.close(); } catch { /* already closed */ } } };
}

async function evalJs(cdp, expression) {
  const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error("page script error: " + (r.exceptionDetails.text || "exception"));
  return r.result?.value;
}

async function waitLoaded(cdp, ms = 15_000) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    try { if ((await evalJs(cdp, "document.readyState")) === "complete") return true; } catch { /* navigating */ }
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

async function pageState(cdp) {
  return await evalJs(cdp, `({url: location.href, title: document.title})`);
}

const sel = (s) => JSON.stringify(String(s));

// ------------------------------------------------------------------ session ledger
async function row(db, sessionId) {
  const r = await db.prepare("SELECT * FROM cobrowse_sessions WHERE session_id = ?1").bind(String(sessionId)).first();
  if (!r) throw new Error("no such co-browse session");
  if (r.closed_ms != null) throw new Error("session is closed (" + (r.close_reason || "closed") + ")");
  return r;
}
async function logEvent(db, sessionId, who, kind, detail, nowMs) {
  await db.prepare("INSERT INTO cobrowse_events (session_id, ts_ms, who, kind, detail) VALUES (?1,?2,?3,?4,?5)")
    .bind(sessionId, nowMs, who, kind, String(detail).slice(0, 500)).run();
}
async function touch(db, sessionId, nowMs) {
  await db.prepare("UPDATE cobrowse_sessions SET last_ms = ?1 WHERE session_id = ?2").bind(nowMs, sessionId).run();
}
async function markClosed(db, sessionId, reason, nowMs) {
  await db.prepare("UPDATE cobrowse_sessions SET closed_ms = ?1, close_reason = ?2 WHERE session_id = ?3 AND closed_ms IS NULL")
    .bind(nowMs, reason, sessionId).run();
}

/** Close the session if it is past its maximum age; returns true when it did. Called before every action. */
async function enforceAge(browser, db, r, nowMs) {
  if (nowMs - Number(r.opened_ms) < BUDGET.sessionMaxSeconds * 1000) return false;
  try { await browser.closeSession(r.session_id); } catch { /* already gone */ }
  await markClosed(db, r.session_id, "max age", nowMs);
  return true;
}

async function liveViews(browser, sessionId, targetId) {
  const act = await browser.getLiveView(sessionId, { targetId, mode: "tab", expiresInMs: 300_000 });
  const view = await browser.getLiveView(sessionId, { targetId, mode: "tab", expiresInMs: 300_000, guardrails: { mode: "readonly" } });
  return { live_view_act: act?.devtoolsFrontendUrl || null, live_view_watch: view?.devtoolsFrontendUrl || null,
           note: "Live View URLs carry access tokens and expire in about five minutes; ask browse_live_view for fresh ones." };
}

// ------------------------------------------------------------------ the typing act
/** The exact typing action, hashed. The approval the human signs carries this id. */
export function typingAct({ sessionId, url, selector, text, submit, nonce }) {
  const textHash = keccak256(toBytes(String(text)));
  const canonical = JSON.stringify({ kind: "cobrowse.type", session: String(sessionId), url: String(url),
                                     selector: String(selector), text_keccak256: textHash, submit: !!submit,
                                     nonce: String(nonce) });
  return { act: keccak256(toBytes(canonical)), textHash };
}

function typingLines({ url, selector, text, submit, isPassword, sessionId, textHash }) {
  const host = (() => { try { return new URL(url).host; } catch { return url; } })();
  return [
    ["Action", submit ? "Type into a field, then press Enter" : "Type into a field"],
    ["Page", String(url).length > 200 ? String(url).slice(0, 199) + "…" : String(url)],
    ["Field", String(selector).slice(0, 200)],
    ["Text", isPassword ? `••• (${String(text).length} characters, password field: not shown)` : String(text)],
    ["Text keccak256", textHash],
    ["Session", String(sessionId).slice(0, 200)],
    ["Site", host],
  ];
}

// ------------------------------------------------------------------ tools
export const TOOLS = [
  { name: "browse_open", description: "Open a live browser on possessio.io (Cloudflare Browser Run) at a URL. Returns the session id and two Live View links: one to watch and act, one to watch only. Budget-capped: one session at a time, at most 15 minutes, never beyond 9 of the included 10 browser-hours in any 31 days. Token-gated.",
    inputSchema: { type: "object", properties: { seat: { type: "string" }, url: { type: "string" } }, required: ["seat", "url"] } },
  { name: "browse_goto", description: "Navigate the session's page to a URL (http/https only). Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" }, url: { type: "string" }, seat: { type: "string" } }, required: ["session_id", "url"] } },
  { name: "browse_read", description: "Read the page as the human sees it now: URL, title and visible text (up to 20,000 characters). Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" } }, required: ["session_id"] } },
  { name: "browse_click", description: "Click the first element matching a CSS selector. Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" }, selector: { type: "string" }, seat: { type: "string" } }, required: ["session_id", "selector"] } },
  { name: "browse_type_request", description: "Ask to type text into a field (optionally then press Enter). Files an act approval whose id is the hash of this exact action on this exact page; returns the possessio.io/approve link for the approver (the RRC key) to sign. Then call browse_type with the same arguments. Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" }, selector: { type: "string" }, text: { type: "string" }, submit: { type: "boolean" }, seat: { type: "string" } }, required: ["session_id", "selector", "text", "seat"] } },
  { name: "browse_type", description: "Type the approved text. Recomputes the act id from these arguments, the nonce and the live page; types only if that act is approved by the approver key, unexpired and unused. Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" }, selector: { type: "string" }, text: { type: "string" }, submit: { type: "boolean" }, nonce: { type: "string" }, seat: { type: "string" } }, required: ["session_id", "selector", "text", "nonce"] } },
  { name: "browse_live_view", description: "Fresh Live View links (act and watch-only) for an open session. Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" } }, required: ["session_id"] } },
  { name: "browse_close", description: "Close a session now (stops its billing). Token-gated.",
    inputSchema: { type: "object", properties: { session_id: { type: "string" }, seat: { type: "string" } }, required: ["session_id"] } },
  { name: "browse_status", description: "The Co-Browse budget (used/remaining seconds in the rolling 31 days), open sessions, and recent actions. Token-gated.",
    inputSchema: { type: "object", properties: {} } },
];
export const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));

/** Run a browse_* tool. deps: { browser, db, now(), approver, chainId } */
export async function callTool(name, args, deps) {
  const { browser, db } = deps;
  const now = deps.now || (() => Date.now());
  if (!browser) throw new Error("Co-Browse is not configured: no BROWSER binding on this worker");
  if (typeof browser.acquire !== "function")
    throw new Error("the BROWSER binding has no typed session methods (acquire/connectSession); check the worker's compatibility_date");
  const seat = String(args?.seat ?? "agent").trim().slice(0, 64) || "agent";

  if (name === "browse_status") {
    const u = await usage(db, now());
    const { results } = await db.prepare("SELECT session_id, ts_ms, who, kind, detail FROM cobrowse_events ORDER BY id DESC LIMIT 20").all();
    const { results: open } = await db.prepare("SELECT session_id, seat, opened_ms, last_ms, start_url FROM cobrowse_sessions WHERE closed_ms IS NULL").all();
    let limits = null;
    try { limits = await browser.limits(); } catch { /* optional */ }
    return { budget: u, open: open || [], recent: results || [], browser_run_limits: limits };
  }

  if (name === "browse_open") {
    const url = checkUrl(args?.url);
    const t = now();
    const budget = await canOpen(db, t);
    const s = await browser.acquire({ keepAlive: BUDGET.keepAliveMs, recording: true, targets: true });
    const sessionId = s.sessionId;
    try {
      let target = (s.targets || []).find((x) => x.type === "page");
      if (!target) target = await browser.devtools.newTarget(sessionId, "about:blank");
      await db.prepare("INSERT INTO cobrowse_sessions (session_id, target_id, seat, opened_ms, last_ms, start_url) VALUES (?1,?2,?3,?4,?4,?5)")
        .bind(sessionId, target.id, seat, t, url).run();
      const cdp = await cdpSocket(browser, sessionId, target.id);
      try {
        await cdp.send("Page.enable");
        await cdp.send("Page.navigate", { url });
        await waitLoaded(cdp);
        const st = await pageState(cdp);
        await logEvent(db, sessionId, seat, "open", st.url, now());
        return { session_id: sessionId, ...st, ...(await liveViews(browser, sessionId, target.id)), budget };
      } finally { cdp.close(); }
    } catch (e) {
      try { await browser.closeSession(sessionId); } catch { /* best effort */ }
      await markClosed(db, sessionId, "open failed", now());
      throw e;
    }
  }

  // every other tool acts on an open session
  const r = await row(db, args?.session_id);
  if (await enforceAge(browser, db, r, now())) throw new Error(`session reached its ${BUDGET.sessionMaxSeconds / 60}-minute maximum and was closed`);

  if (name === "browse_close") {
    try { await browser.closeSession(r.session_id); } catch { /* already gone */ }
    await markClosed(db, r.session_id, "closed by " + seat, now());
    await logEvent(db, r.session_id, seat, "close", "", now());
    return { closed: r.session_id, budget: await usage(db, now()) };
  }
  if (name === "browse_live_view") {
    await touch(db, r.session_id, now());
    return await liveViews(browser, r.session_id, r.target_id);
  }

  const cdp = await cdpSocket(browser, r.session_id, r.target_id);
  try {
    await touch(db, r.session_id, now());
    if (name === "browse_goto") {
      const url = checkUrl(args?.url);
      await cdp.send("Page.enable");
      await cdp.send("Page.navigate", { url });
      await waitLoaded(cdp);
      const st = await pageState(cdp);
      await logEvent(db, r.session_id, seat, "goto", st.url, now());
      return st;
    }
    if (name === "browse_read") {
      const v = await evalJs(cdp, `({url: location.href, title: document.title, text: (document.body ? document.body.innerText : "").slice(0, ${READ_MAX})})`);
      return v;
    }
    if (name === "browse_click") {
      const out = await evalJs(cdp, `(() => { const e = document.querySelector(${sel(args?.selector)}); if (!e) return "no element matches";
        e.scrollIntoView({block: "center"}); e.click(); return "clicked"; })()`);
      if (out !== "clicked") throw new Error(out + ": " + args?.selector);
      await new Promise((res) => setTimeout(res, 300));
      await waitLoaded(cdp, 10_000);
      const st = await pageState(cdp);
      await logEvent(db, r.session_id, seat, "click", String(args?.selector), now());
      return { clicked: args?.selector, ...st };
    }
    if (name === "browse_type_request" || name === "browse_type") {
      const selector = String(args?.selector ?? "");
      const text = String(args?.text ?? "");
      if (!selector) throw new Error("selector is required");
      if (text.length > TEXT_MAX) throw new Error(`text too long (max ${TEXT_MAX} characters per approved action)`);
      const field = await evalJs(cdp, `(() => { const e = document.querySelector(${sel(selector)}); if (!e) return null;
        return {type: (e.getAttribute("type") || e.tagName).toLowerCase(), url: location.href}; })()`);
      if (!field) throw new Error("no element matches: " + selector);
      const isPassword = field.type === "password";
      let nonce = String(args?.nonce ?? "");
      if (name === "browse_type_request") nonce = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
      else if (!/^[0-9a-f]{32}$/.test(nonce)) throw new Error("nonce is required: pass the nonce browse_type_request returned");
      const { act, textHash } = typingAct({ sessionId: r.session_id, url: field.url, selector, text, submit: !!args?.submit, nonce });
      const approver = getAddress(deps.approver || DEFAULT_APPROVER);

      if (name === "browse_type_request") {
        const nowS = Math.floor(now() / 1000);
        const rec = normaliseRequest({ act, title: "Co-Browse: type on " + new URL(field.url).host,
          lines: typingLines({ url: field.url, selector, text, submit: !!args?.submit, isPassword, sessionId: r.session_id, textHash }),
          approver, valid_until: nowS + BUDGET.approvalSeconds }, nowS, deps.chainId || 8453);
        await db.prepare("INSERT INTO act_approvals (act, created_ms, seat, title, lines_json, summary, approver, valid_until, chain_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)")
          .bind(rec.act, now(), seat, rec.title, JSON.stringify(rec.lines), rec.summary, rec.approver, rec.validUntil, rec.chainId).run();
        await logEvent(db, r.session_id, seat, "type_request", `${selector} act ${act}`, now());
        return { act, nonce, approve_url: "https://possessio.io/approve#" + act, approver, valid_until: rec.validUntil,
                 next: "after the approver signs, call browse_type with the same session_id, selector, text, submit and this nonce" };
      }

      // browse_type: the approval must exist, be signed by the approver, be in its window, and be unused
      const a = await db.prepare("SELECT signer, signature, valid_until, approver FROM act_approvals WHERE act = ?1").bind(act).first();
      if (!a) throw new Error("no approval request for this exact action (page, field, text, Enter or nonce differ?) — call browse_type_request first");
      if (!a.signature) throw new Error("not approved yet: open https://possessio.io/approve#" + act);
      if (getAddress(a.approver) !== approver || getAddress(a.signer) !== approver) throw new Error("approval is not from the configured approver " + approver);
      if (Math.floor(now() / 1000) > Number(a.valid_until)) throw new Error("approval window closed");
      const used = await db.prepare("INSERT OR IGNORE INTO cobrowse_used_acts (act, session_id, used_ms) VALUES (?1,?2,?3)").bind(act, r.session_id, now()).run();
      if (!used?.meta?.changes) throw new Error("this approval was already used");

      await evalJs(cdp, `(() => { const e = document.querySelector(${sel(selector)}); e.scrollIntoView({block: "center"}); e.focus(); return true; })()`);
      await cdp.send("Input.insertText", { text });
      if (args?.submit) {
        for (const type of ["keyDown", "keyUp"])
          await cdp.send("Input.dispatchKeyEvent", { type, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: type === "keyDown" ? "\r" : undefined });
        await new Promise((res) => setTimeout(res, 300));
        await waitLoaded(cdp, 10_000);
      }
      const st = await pageState(cdp);
      await logEvent(db, r.session_id, seat, "type", `${selector} ${isPassword ? "•••" : JSON.stringify(text)}${args?.submit ? " + Enter" : ""} (act ${act})`, now());
      return { typed: isPassword ? "•••" : text, submit: !!args?.submit, act, ...st };
    }
    throw new Error("unknown tool: " + name);
  } finally { cdp.close(); }
}

/** Cron sweep: close sessions past their maximum age or idle too long, and mark sessions Browser Run already ended. */
export async function sweep(browser, db, nowMs) {
  const { results } = await db.prepare("SELECT session_id, opened_ms, last_ms FROM cobrowse_sessions WHERE closed_ms IS NULL").all();
  if (!results || results.length === 0) return [];    // nothing open: do not touch Browser Run at all
  let live = null;
  try { live = new Set((await browser.listSessions()).map((s) => s.sessionId)); } catch { /* keep going */ }
  const closed = [];
  for (const r of results || []) {
    let reason = null;
    if (live && !live.has(r.session_id)) reason = "ended by Browser Run";
    else if (nowMs - Number(r.opened_ms) >= BUDGET.sessionMaxSeconds * 1000) reason = "max age";
    else if (nowMs - Number(r.last_ms) >= BUDGET.idleCloseSeconds * 1000) reason = "idle";
    if (!reason) continue;
    if (reason !== "ended by Browser Run") { try { await browser.closeSession(r.session_id); } catch { /* gone */ } }
    await markClosed(db, r.session_id, reason, nowMs);
    closed.push({ session_id: r.session_id, reason });
  }
  return closed;
}
