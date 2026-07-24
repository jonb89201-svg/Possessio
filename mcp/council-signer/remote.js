// Council Signer MCP (remote / Streamable HTTP) — the SAME seven scoped tools as
// the stdio server (`tools.js`), reachable as a URL so a *remote* client such as
// claude.ai on the web can add the connector. claude.ai web supports a bearer
// token via the connector's "Request headers" field, so this server speaks
// Streamable HTTP behind one door: `auth.js`.
//
// ┌─ READ THIS BEFORE YOU DEPLOY ────────────────────────────────────────────────┐
// │ A stdio connector holds the seat key only in the process YOU spawned. A       │
// │ remote connector holds it in a SERVER's env, reachable at a URL — a strictly  │
// │ bigger surface. Therefore:                                                    │
// │   • The OPERATOR self-hosts this. Possessio never runs it and never holds a   │
// │     seat key. One connector = one seat = one host = one COUNCIL_SEAT_KEY.     │
// │   • It refuses to start without COUNCIL_MCP_TOKEN (auth.js, fail-closed), and │
// │     you should terminate TLS in front of it (a reverse proxy / tunnel) so the │
// │     bearer token and signatures never cross the wire in cleartext.            │
// │   • Even fully popped, the blast radius is UNCHANGED from the spec's premise:  │
// │     the seven tools reach only onlyCouncilMember functions, and the Treasury  │
// │     gate still bounds the worst case to a bad vote, never a lost cent (§3).    │
// │     The key on the host is the cost of being remote; the on-chain gate is why │
// │     that cost is survivable.                                                  │
// └───────────────────────────────────────────────────────────────────────────────┘
"use strict";
const http = require("http");
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StreamableHTTPServerTransport } = require("@modelcontextprotocol/sdk/server/streamableHttp.js");

const cfg = require("./config");
const auth = require("./auth");
const { registerTools } = require("./tools");

const MCP_PATH = process.env.COUNCIL_MCP_PATH || "/mcp";
const PORT = Number(process.env.PORT || process.env.COUNCIL_MCP_PORT || 8787);
const HOST = process.env.COUNCIL_MCP_HOST || "127.0.0.1"; // loopback by default; a proxy fronts it
const MAX_BODY = 1 << 20; // 1 MiB — a vote/statement is tiny; anything larger is abuse

// Fail-closed at construction: no gate, no server. Both must resolve or we never
// bind a port. The binding also validates the seat key up front (config.js).
const gate = auth.fromEnv();
const binding = cfg.loadBinding();

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

// One fresh (server, transport) per request — the SDK's supported stateless shape
// (sessionIdGenerator: undefined). No cross-request session state means one leaked
// request can't ride another's session.
async function handleMcp(req, res, parsedBody) {
  const server = new McpServer({ name: "council-signer", version: "0.1.0" });
  registerTools(server, binding);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => { transport.close(); server.close(); });
  await server.connect(transport);
  await transport.handleRequest(req, res, parsedBody);
}

const httpServer = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    // Liveness only — deliberately says NOTHING about who this host is (CS-1,
    // audit 2026-07-23). It used to return the seat address + chainId, and it
    // answers BEFORE the bearer gate below, so anyone who found the URL learned
    // "this host holds council seat 0x… on chain 8453" with no token — free
    // targeting intel for going after a signing key, and deploy.sh tells the
    // operator to set the Codespace port PUBLIC. A liveness probe needs to prove
    // the process is up, nothing more. The seat/chain detail moved behind the
    // gate (/whoami) for anyone who can already authenticate.
    if (url.pathname === "/healthz") return send(res, 200, { ok: true });
    // /whoami carries the identity /healthz used to leak. It is NOT exempt from
    // the door — it is routed past the 404 only so the gate below can judge it.
    const isWhoami = url.pathname === "/whoami";
    if (!isWhoami && url.pathname !== MCP_PATH) return rpcError(res, -32601, 404, "not found");

    // THE DOOR — every method on the MCP path proves the bearer token first, in
    // constant time. No token, wrong token, wrong scheme → 401, key untouched.
    if (!gate.check(req.headers["authorization"])) {
      res.setHeader("www-authenticate", 'Bearer realm="council-signer"');
      return rpcError(res, -32001, 401, "unauthorized");
    }

    // Authenticated identity readout (CS-1). Same facts /healthz used to hand
    // out for free, now only to a caller who already proved the bearer token.
    if (isWhoami) return send(res, 200, { ok: true, seat: binding.seatAddress, chainId: binding.chainId });

    // Only POST carries JSON-RPC; parse it ourselves and hand the object to the SDK.
    let parsedBody;
    if (req.method === "POST") {
      const raw = await readBody(req);
      try { parsedBody = raw ? JSON.parse(raw) : undefined; }
      catch { return rpcError(res, -32700, 400, "parse error"); }
    }
    await handleMcp(req, res, parsedBody);
  } catch (e) {
    if (!res.headersSent) rpcError(res, -32603, 500, cfg.redact("internal error: " + ((e && e.message) || String(e))));
  }
});

if (require.main === module) {
  httpServer.listen(PORT, HOST, () => {
    // Never print the token or the key — only that the door is shut and to which seat.
    process.stderr.write(
      `council-signer (remote) listening on http://${HOST}:${PORT}${MCP_PATH} — seat ${binding.seatAddress}, chain ${binding.chainId}, bearer-gated.\n`
    );
  });
}

module.exports = { httpServer, handleMcp, gate, binding };
