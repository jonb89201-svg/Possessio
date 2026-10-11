// node --experimental-strip-types worker/test/mcp-e2e.test.mjs  -> RESULT: n/n PASS
// The REAL worker default export and its /mcp handler, with a fake env (no D1, no browser), driven by JSON-RPC
// requests the way a client sends them. Offline. This is the only test that sees index.ts's dispatcher, so it is the
// one that proves the probe_* token gate and the resources/prompts methods. Node strips the TypeScript; a resolve
// hook maps the worker's extensionless relative imports to .ts, as the Workers bundler does at deploy.
import { register } from "node:module";
import path from "node:path";
register("data:text/javascript," + encodeURIComponent(`
  import { existsSync } from "node:fs"; import { fileURLToPath } from "node:url";
  export async function resolve(spec, ctx, next) {
    if ((spec.startsWith("./") || spec.startsWith("../")) && !/\\.[cm]?[jt]s$/.test(spec)) {
      const u = new URL(spec + ".ts", ctx.parentURL);
      if (existsSync(fileURLToPath(u))) return next(u.href, ctx);
    }
    return next(spec, ctx);
  }`), import.meta.url);

const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = (await import(path.join(HERE, "..", "index.ts"))).default;
const TOKEN = "e2e-token-0123456789abcdefghijklmnopqrstuv";
const env = { COUNCIL_MCP_TOKEN: TOKEN, COUNCIL_DB: null };
const ctx = { waitUntil() {}, passThroughOnException() {} };
let id = 0;
async function call(method, params, { auth = true, path: p = "/mcp" } = {}) {
  const headers = { "content-type": "application/json", accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" };
  if (auth) headers.authorization = `Bearer ${TOKEN}`;
  const res = await W.fetch(new Request("https://possessio.io" + p, { method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) }), env, ctx);
  return { status: res.status, body: await res.json() };
}
const out = []; const ok = (name, cond, detail = "") => out.push([name, !!cond, detail]);

let r = await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "0" } });
const caps = r.body.result.capabilities;
ok("initialize: version 0.9.0, resources and prompts advertised", r.body.result.serverInfo.version === "0.9.0" && caps.resources && caps.prompts, JSON.stringify(r.body.result));
r = await call("tools/list", {});
const tools = r.body.result.tools;
ok("tools/list: 22 tools, five of them probe_*", tools.length === 22 && tools.filter((t) => t.name.startsWith("probe_")).length === 5, String(tools.length));
ok("tools/list: every probe tool is annotated read-only", tools.filter((t) => t.name.startsWith("probe_")).every((t) => t.annotations?.readOnlyHint === true));
r = await call("resources/list", {}, { auth: false });
ok("resources/list is public and returns one resource", r.body.result?.resources?.length === 1);
r = await call("resources/read", { uri: "possessio://probe/mirror" }, { auth: false });
ok("resources/read returns the mirror text", /probe_delay/.test(r.body.result?.contents?.[0]?.text || ""));
r = await call("resources/read", { uri: "possessio://nope" }, { auth: false });
ok("resources/read of an unknown uri is a JSON-RPC error", r.body.error?.code === -32002);
r = await call("prompts/list", {}, { auth: false });
ok("prompts/list returns one prompt", r.body.result?.prompts?.length === 1);
r = await call("prompts/get", { name: "probe_prompt", arguments: { topic: "walls" } }, { auth: false });
ok("prompts/get renders the prompt", /walls/.test(r.body.result?.messages?.[0]?.content?.text || ""));
for (const name of ["probe_echo", "probe_delay", "probe_payload", "probe_schema", "probe_error"]) {
  r = await call("tools/call", { name, arguments: { seconds: 0, bytes: 1, kind: "jsonrpc", mode: "read", nested: { id: 1 } } }, { auth: false });
  ok(`${name} without a token is refused as token-gated`, r.body.result?.isError === true && /token-gated/.test(r.body.result.content[0].text), JSON.stringify(r.body).slice(0, 160));
}
r = await call("tools/call", { name: "probe_echo", arguments: { note: "x" } });
ok("probe_echo with a bearer: no token anywhere in the reply", !JSON.stringify(r.body).includes(TOKEN));
ok("probe_echo reports the protocol header and the request id", r.body.result?.structuredContent?.mcp?.protocol_version_header === "2025-06-18" && r.body.result.structuredContent.mcp.request_id === id);
r = await call("tools/call", { name: "probe_echo", arguments: {} }, { auth: false, path: "/mcp/" + TOKEN });
ok("probe_echo via /mcp/<token>: authorised, token absent, path echoed as /mcp/<token>",
   !r.body.result?.isError && !JSON.stringify(r.body).includes(TOKEN) && r.body.result.structuredContent.http.path === "/mcp/<token>");
r = await call("tools/call", { name: "probe_payload", arguments: { bytes: 12345 } });
ok("probe_payload: exactly 12345 bytes through the real handler", Buffer.byteLength(r.body.result?.content?.[0]?.text || "", "utf8") === 12345);
r = await call("tools/call", { name: "probe_delay", arguments: { seconds: 0.5 } });
ok("probe_delay: waited about 0.5 s through the real handler", Math.abs((r.body.result?.structuredContent?.waited_s ?? -9) - 0.5) < 0.4);
r = await call("tools/call", { name: "probe_error", arguments: { kind: "jsonrpc" } });
ok("probe_error jsonrpc: a JSON-RPC error object, no result", r.body.error?.code === -32602 && r.body.result === undefined);
r = await call("tools/call", { name: "probe_error", arguments: { kind: "tool" } });
ok("probe_error tool: result.isError", r.body.result?.isError === true);
r = await call("tools/call", { name: "probe_error", arguments: { kind: "throw" } });
ok("probe_error throw: caught, HTTP 200 with isError, not a 500", r.status === 200 && r.body.result?.isError === true);
r = await call("tools/call", { name: "act_status", arguments: { act: "nope" } }, { auth: false });
ok("existing tools still dispatch to their own code (act_status validates its argument)", /act must be 0x/.test(r.body.result?.content?.[0]?.text || ""));

for (const [n, pass, d] of out) console.log(`  [${pass ? "PASS" : "FAIL"}] ${n}${pass ? "" : " — " + d}`);
const n = out.filter((x) => x[1]).length;
console.log(`RESULT: ${n}/${out.length} PASS`);
process.exit(n === out.length ? 0 : 1);
