// xtrade MCP (remote / Streamable HTTP) — the SAME six tools as the stdio server
// (`server.js` → buildServer()), reachable as a URL so a *remote* client such as
// claude.ai on the web can add the connector. Mirrors mcp/council-signer/remote.js.
//
// ┌─ READ THIS BEFORE YOU DEPLOY ────────────────────────────────────────────────┐
// │ What this exposes: build-mode only. There is no signer here (RULEBOOK Sec4:   │
// │ the dedicated trading wallet does not exist; execute_trade refuses by         │
// │ construction). A caller who passes the door can spend this host's Solana RPC  │
// │ / Jupiter quota and append to this host's ledger file — nothing more.        │
// │   • The OPERATOR self-hosts this. Possessio never runs it.                    │
// │   • It refuses to start without XTRADE_MCP_TOKEN (auth.js, fail-closed), and │
// │     you should terminate TLS in front of it (a reverse proxy / tunnel) so the │
// │     token never crosses the wire in cleartext.                                │
// │   • If a signer is ever wired (TRADING_SIGNER_KEY), this transport becomes a   │
// │     URL to a key. That is the council-signer trade-off and needs its own      │
// │     review before ALLOW_HOT is even discussed.                                │
// └───────────────────────────────────────────────────────────────────────────────┘
"use strict";
const http = require("http");
const { StreamableHTTPServerTransport } = require("@modelcontextprotocol/sdk/server/streamableHttp.js");

const auth = require("./auth");
const { buildServer } = require("./server");

const MCP_PATH = process.env.XTRADE_MCP_PATH || "/mcp";
const PORT = Number(process.env.PORT || process.env.XTRADE_MCP_PORT || 8788);
const HOST = process.env.XTRADE_MCP_HOST || "127.0.0.1"; // loopback by default; a proxy fronts it
const MAX_BODY = 1 << 20; // 1 MiB — a tool call is tiny; anything larger is abuse

// Fail-closed at construction: no gate, no server. We never bind a port without it.
const gate = auth.fromEnv();

// Never let the token or a signer key leak through an error message.
const SECRETS = [process.env.XTRADE_MCP_TOKEN, process.env.TRADING_SIGNER_KEY].filter(Boolean);
function redact(s) {
  let out = String(s);
  for (const k of SECRETS) out = out.split(k).join("<redacted>");
  return out;
}

const send = (res, code, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json" });
  res.end(body);
};
// JSON-RPC-shaped error so an MCP client renders it, not a bare HTTP page.
const rpcError = (res, code, httpStatus, message) =>
  send(res, httpStatus, { jsonrpc: "2.0", error: { code, message }, id: null });

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error("body too large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// The token may arrive two ways: the Authorization header (preferred; any MCP
// client with a headers field), or as the path segment right after MCP_PATH —
// `/mcp/<token>` — because the claude.ai custom-connector UI offers a URL and
// nothing else (the possessio worker's /mcp and solana-mcp use the same form).
// A query string is never accepted: it lands in access logs and referers.
function authorised(req, url) {
  if (gate.check(req.headers["authorization"])) return true;
  if (url.pathname.startsWith(MCP_PATH + "/")) {
    const seg = url.pathname.slice(MCP_PATH.length + 1).split("/")[0];
    let tok = seg;
    try { tok = decodeURIComponent(seg); } catch { /* keep raw */ }
    return gate.checkRaw(tok);
  }
  return false;
}
function isMcpPath(url) {
  return url.pathname === MCP_PATH || url.pathname.startsWith(MCP_PATH + "/");
}

// One fresh (server, transport) per request — the SDK's supported stateless shape
// (sessionIdGenerator: undefined). No cross-request session state means one leaked
// request can't ride another's session.
async function handleMcp(req, res, parsedBody) {
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => { transport.close(); server.close(); });
  await server.connect(transport);
  await transport.handleRequest(req, res, parsedBody);
}

const httpServer = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    // Liveness only — says nothing about what this host is or holds.
    if (url.pathname === "/healthz") return send(res, 200, { ok: true });
    if (!isMcpPath(url)) return rpcError(res, -32601, 404, "not found");

    // THE DOOR — every method on the MCP path proves the token first, in constant
    // time. No token, wrong token, wrong place → 401, nothing else runs.
    if (!authorised(req, url)) {
      res.setHeader("www-authenticate", 'Bearer realm="xtrade"');
      return rpcError(res, -32001, 401, "unauthorized");
    }

    // Only POST carries JSON-RPC; parse it ourselves and hand the object to the SDK.
    let parsedBody;
    if (req.method === "POST") {
      const raw = await readBody(req);
      try { parsedBody = raw ? JSON.parse(raw) : undefined; }
      catch { return rpcError(res, -32700, 400, "parse error"); }
    }
    await handleMcp(req, res, parsedBody);
  } catch (e) {
    if (!res.headersSent) rpcError(res, -32603, 500, redact("internal error: " + ((e && e.message) || String(e))));
  }
});

if (require.main === module) {
  httpServer.listen(PORT, HOST, () => {
    // Never print the token — only that the door is shut.
    process.stderr.write(`xtrade (remote) listening on http://${HOST}:${PORT}${MCP_PATH} — build-mode, bearer-gated.\n`);
  });
}

module.exports = { httpServer, handleMcp, gate, authorised, MCP_PATH };
