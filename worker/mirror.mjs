// Mirror tools (worker 0.9.0): reflect the client back so CLIENT walls become measurable from the server side.
//
// A server cannot see what the harness around a model enforces — its tool-call timeout, its result-size ceiling,
// which schema features it renders or validates, how it shows a tool error versus a protocol error, whether it
// lists resources and prompts at all. But a server can hand the client a controlled stimulus and record what
// comes back. That is all these do. Each is read-only in both directions: no outbound request, no durable write,
// no key, and nothing that costs more than the request itself.
//
// Walls of this module (decision 2026-10-11):
//   - token-gated at the dispatcher like browse_*, so a stranger cannot burn request time;
//   - probe_delay is capped at LIMITS.delayMaxS (90 s) because Cloudflare closes a response that has sent nothing
//     for ~100 s — that is a wall of the bridge, not the client, and the result says so;
//   - probe_payload is capped at LIMITS.payloadMaxBytes;
//   - probe_echo never returns credentials: Authorization, Cookie and friends are redacted, and a token carried
//     in the URL path (the /mcp/<token> form) is replaced before the path is echoed.
//
// Cross-runtime on purpose (Workers and Node): globals only — TextEncoder, crypto.subtle, setTimeout.

export const LIMITS = { delayMaxS: 90, payloadMaxBytes: 4 * 1024 * 1024, echoHeaderMax: 48, echoValueMax: 256 };
const REDACT_HEADERS = new Set(["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token"]);

const RO = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

export const TOOLS = [
  { name: "probe_echo",
    description: "Mirror: returns the HTTP headers and MCP envelope fields this call arrived with (credentials redacted) and the arguments exactly as received. Measures what the client sends. Token-gated; writes nothing.",
    inputSchema: { type: "object", properties: { note: { type: "string", description: "any text; echoed back verbatim" } } },
    annotations: { title: "Probe: echo", ...RO } },
  { name: "probe_delay",
    description: `Mirror: waits {seconds} (0-${LIMITS.delayMaxS}) before answering, then reports how long it actually waited. Measures the client's tool-call timeout. The cap is the bridge's wall (Cloudflare closes a silent response at ~100 s), not the client's. Token-gated; writes nothing.`,
    inputSchema: { type: "object", properties: { seconds: { type: "number", minimum: 0, maximum: LIMITS.delayMaxS, description: "seconds to wait" } }, required: ["seconds"] },
    annotations: { title: "Probe: delay", ...RO } },
  { name: "probe_payload",
    description: `Mirror: returns one text block of exactly {bytes} bytes (1-${LIMITS.payloadMaxBytes}), with its sha256 in structuredContent. Measures the client's result-size ceiling and whether it truncates, errors or drops. Token-gated; writes nothing.`,
    inputSchema: { type: "object", properties: { bytes: { type: "integer", minimum: 1, maximum: LIMITS.payloadMaxBytes, description: "exact size of the text block" } }, required: ["bytes"] },
    annotations: { title: "Probe: payload", ...RO } },
  { name: "probe_schema",
    description: "Mirror: a tool whose input schema uses many JSON Schema features (enum, const, pattern, format, bounds, nested required, arrays, defaults). Returns what arrived and the JavaScript type of each field. Measures which features the client renders or enforces before sending. Token-gated; writes nothing.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["read", "list", "count"], description: "one of three" },
        tag: { type: "string", const: "fixed", description: "must be the word fixed" },
        hex: { type: "string", pattern: "^0x[0-9a-fA-F]{8}$", description: "0x + 8 hex" },
        when: { type: "string", format: "date-time", description: "RFC 3339" },
        count: { type: "integer", minimum: 1, maximum: 10, default: 3 },
        ratio: { type: "number", exclusiveMinimum: 0, exclusiveMaximum: 1 },
        flag: { type: "boolean", default: false },
        tags: { type: "array", items: { type: "string", minLength: 1 }, minItems: 1, maxItems: 3, uniqueItems: true },
        nested: { type: "object", properties: { id: { type: "integer" }, name: { type: "string" } }, required: ["id"], additionalProperties: false },
        either: { oneOf: [{ type: "string" }, { type: "integer" }] },
      },
      required: ["mode", "nested"],
      additionalProperties: false,
    },
    annotations: { title: "Probe: schema", ...RO } },
  { name: "probe_error",
    description: "Mirror: fails on purpose in the way you ask — kind=tool (result.isError), kind=jsonrpc (a JSON-RPC error object), kind=throw (an uncaught server error). Measures how the client surfaces each. Token-gated; writes nothing.",
    inputSchema: { type: "object", properties: { kind: { type: "string", enum: ["tool", "jsonrpc", "throw"] } }, required: ["kind"] },
    annotations: { title: "Probe: error", ...RO } },
];
export const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));

// One resource and one prompt, so a client's support for those capabilities is measurable at all.
export const RESOURCES = [
  { uri: "possessio://probe/mirror", name: "Mirror tools — what they measure", mimeType: "text/markdown",
    description: "How the probe_* tools work and what each one measures about the client." },
];
export const PROMPTS = [
  { name: "probe_prompt", description: "Mirror: a one-argument prompt. Measures whether the client lists and renders prompts.",
    arguments: [{ name: "topic", description: "any word", required: true }] },
];
const RESOURCE_TEXT = [
  "# Mirror tools",
  "",
  "probe_echo: what the client sends (headers redacted, arguments verbatim).",
  `probe_delay: the client's tool timeout, up to ${LIMITS.delayMaxS} s (the bridge's own ceiling).`,
  `probe_payload: the client's result-size ceiling, up to ${LIMITS.payloadMaxBytes} bytes.`,
  "probe_schema: which JSON Schema features the client renders or enforces.",
  "probe_error: how the client shows a tool error, a JSON-RPC error and a thrown error.",
  "This resource exists so resources/list and resources/read are measurable too.",
  "",
].join("\n");
export function readResource(uri) {
  if (uri !== RESOURCES[0].uri) throw new Error("unknown resource: " + uri);
  return { contents: [{ uri, mimeType: "text/markdown", text: RESOURCE_TEXT }] };
}
export function getPrompt(name, args) {
  if (name !== PROMPTS[0].name) throw new Error("unknown prompt: " + name);
  const topic = String(args?.topic ?? "").slice(0, 80);
  if (!topic) throw new Error("topic is required");
  return { description: PROMPTS[0].description,
           messages: [{ role: "user", content: { type: "text", text: `Say one measured sentence about ${topic}, labelled MEASURED or HYPOTHESIS.` } }] };
}

// ---------------------------------------------------------------- helpers
const enc = new TextEncoder();
export async function sha256Hex(text) {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(text));
  return "0x" + Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
export function clampInt(v, lo, hi, dflt) {
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, Math.round(n)));
}
/** Headers → plain object with credentials removed, counts capped, values truncated. Accepts a Headers or an object. */
export function redactHeaders(headers, redact = (s) => s) {
  const out = {}; let n = 0; let dropped = 0;
  const entries = typeof headers?.forEach === "function" && !(Symbol.iterator in Object(headers))
    ? [] : Array.from(headers?.entries ? headers.entries() : Object.entries(headers || {}));
  for (const [k0, v0] of entries) {
    const k = String(k0).toLowerCase();
    if (REDACT_HEADERS.has(k)) { out[k] = "<redacted>"; continue; }
    if (n >= LIMITS.echoHeaderMax) { dropped++; continue; }
    out[k] = redact(String(v0)).slice(0, LIMITS.echoValueMax); n++;
  }
  if (dropped) out["<dropped>"] = dropped;
  return out;
}
/** The request path with a /mcp/<token> segment replaced, so the echo never carries the token. */
export function redactPath(pathname, mcpPath = "/mcp") {
  if (pathname.startsWith(mcpPath + "/")) {
    const rest = pathname.slice(mcpPath.length + 1).split("/");
    if (rest[0]) rest[0] = "<token>";
    return mcpPath + "/" + rest.join("/");
  }
  return pathname;
}
/** A text block of exactly `bytes` bytes (ASCII only, so bytes == characters), self-describing in its first line. */
export function payloadText(bytes, stamp) {
  const head = `probe_payload bytes=${bytes} ${stamp}\n`;
  if (head.length >= bytes) return head.slice(0, bytes);
  let out = head;
  const line = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/-=.,;:!?\n"; // 72 bytes
  while (out.length + line.length <= bytes) out += line;
  out += line.slice(0, bytes - out.length);
  return out;
}
const typeOf = (v) => v === null ? "null" : Array.isArray(v) ? "array" : typeof v;

// ---------------------------------------------------------------- the tools
/**
 * Run a probe_* tool. Returns an MCP tools/call RESULT ({content, isError?, structuredContent?}) ready to send,
 * or { jsonrpcError: {code, message} } when the client asked to see a protocol-level error.
 * deps: { headers, pathname, method, mcpPath, redact(s), now(), sleep(ms), envelope: {id, protocolVersionHeader, sessionIdHeader} }
 */
export async function callTool(name, args, deps = {}) {
  const now = deps.now || (() => Date.now());
  const sleep = deps.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  const redact = deps.redact || ((s) => s);
  const text = (o) => ({ content: [{ type: "text", text: JSON.stringify(o, null, 2) }], structuredContent: o });

  if (name === "probe_echo") {
    return text({
      measured_at: new Date(now()).toISOString(),
      http: { method: deps.method || null, path: redactPath(String(deps.pathname || ""), deps.mcpPath || "/mcp"),
              headers: redactHeaders(deps.headers, redact) },
      mcp: { protocol_version_header: deps.envelope?.protocolVersionHeader ?? null,
             session_id_header_present: !!deps.envelope?.sessionIdHeader,
             request_id: deps.envelope?.id ?? null, request_id_type: typeOf(deps.envelope?.id) },
      arguments_received: args ?? null,
      argument_types: Object.fromEntries(Object.entries(args || {}).map(([k, v]) => [k, typeOf(v)])),
      note: "credentials are redacted; a /mcp/<token> path is shown as /mcp/<token>",
    });
  }
  if (name === "probe_delay") {
    const requested = Number(args?.seconds);
    if (!Number.isFinite(requested)) throw new Error("seconds must be a number");
    const seconds = Math.min(LIMITS.delayMaxS, Math.max(0, requested));
    const t0 = now(); await sleep(seconds * 1000); const t1 = now();
    return text({ requested_s: requested, waited_s: Math.round((t1 - t0) / 100) / 10, cap_s: LIMITS.delayMaxS,
                  capped: seconds !== requested, started_at: new Date(t0).toISOString(), finished_at: new Date(t1).toISOString(),
                  note: `the cap is the bridge's wall: Cloudflare closes a response silent for ~100 s. A client timeout beyond ${LIMITS.delayMaxS} s needs a host-side mirror.` });
  }
  if (name === "probe_payload") {
    const bytes = clampInt(args?.bytes, 1, LIMITS.payloadMaxBytes, NaN);
    if (!Number.isFinite(bytes)) throw new Error("bytes must be a number");
    const stamp = new Date(now()).toISOString();
    const body = payloadText(bytes, stamp);
    const sha = await sha256Hex(body);
    return { content: [{ type: "text", text: body }],
             structuredContent: { bytes, requested: Number(args?.bytes), capped: bytes !== Number(args?.bytes), sha256: sha, cap_bytes: LIMITS.payloadMaxBytes } };
  }
  if (name === "probe_schema") {
    return text({ arguments_received: args ?? null,
                  argument_types: Object.fromEntries(Object.entries(args || {}).map(([k, v]) => [k, typeOf(v)])),
                  note: "compare with the inputSchema: a field that arrives out of bounds was not validated by the client; a missing default was not filled by it" });
  }
  if (name === "probe_error") {
    const kind = String(args?.kind ?? "");
    if (kind === "tool") return { content: [{ type: "text", text: "probe_error: this is a TOOL error (result.isError = true), on purpose" }], isError: true };
    if (kind === "jsonrpc") return { jsonrpcError: { code: -32602, message: "probe_error: this is a JSON-RPC error object, on purpose" } };
    if (kind === "throw") throw new Error("probe_error: this is a thrown server error, on purpose");
    throw new Error("kind must be one of tool, jsonrpc, throw");
  }
  throw new Error("unknown mirror tool: " + name);
}
