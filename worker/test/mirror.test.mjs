// node worker/test/mirror.test.mjs  -> RESULT: n/n PASS
// Offline: the mirror module alone, with injected clock and sleep. The dispatcher's token gate is in index.ts and is
// measured on the live endpoint, not here.
import { createHash } from "node:crypto";
import { TOOLS, TOOL_NAMES, RESOURCES, PROMPTS, LIMITS, callTool, readResource, getPrompt,
         redactHeaders, redactPath, payloadText, sha256Hex, clampInt } from "../mirror.mjs";

const results = [];
async function test(name, fn) {
  try { await fn(); results.push([name, true]); }
  catch (e) { results.push([name, false, e && e.message]); }
}
const eq = (a, b, m) => { if (a !== b) throw new Error((m || "") + ` expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const throws = async (fn, re) => {
  try { await fn(); } catch (e) { if (re && !re.test(e.message)) throw new Error("wrong reason: " + e.message); return; }
  throw new Error("did not throw");
};
const fakeToken = "t".repeat(40);
const deps = (over = {}) => ({
  method: "POST", pathname: "/mcp/" + fakeToken, mcpPath: "/mcp",
  headers: new Headers({ "content-type": "application/json", accept: "application/json, text/event-stream",
                         authorization: "Bearer " + fakeToken, cookie: "a=b", "mcp-protocol-version": "2025-06-18",
                         "user-agent": "probe-test" }),
  redact: (s) => s.split(fakeToken).join("<redacted>"),
  now: () => 1_791_700_000_000, sleep: async () => {},
  envelope: { id: 7, protocolVersionHeader: "2025-06-18", sessionIdHeader: null },
  ...over,
});

await test("every mirror tool is named probe_*, read-only by annotation, and says Token-gated", () => {
  for (const t of TOOLS) {
    if (!t.name.startsWith("probe_")) throw new Error(t.name);
    eq(t.annotations.readOnlyHint, true, t.name); eq(t.annotations.destructiveHint, false, t.name);
    if (!/Token-gated/.test(t.description)) throw new Error(t.name + " description");
  }
  eq(TOOL_NAMES.size, 5);
});

await test("probe_echo: credentials redacted by header name AND by value, path token replaced, args verbatim", async () => {
  const r = await callTool("probe_echo", { note: "hi", n: 1, b: true, l: [1], o: {}, z: null }, deps());
  const s = JSON.stringify(r);
  if (s.includes(fakeToken)) throw new Error("token leaked");
  const h = r.structuredContent.http.headers;
  eq(h.authorization, "<redacted>"); eq(h.cookie, "<redacted>"); eq(h["user-agent"], "probe-test");
  eq(r.structuredContent.http.path, "/mcp/<token>");
  eq(r.structuredContent.mcp.protocol_version_header, "2025-06-18");
  eq(r.structuredContent.mcp.request_id_type, "number");
  eq(JSON.stringify(r.structuredContent.arguments_received), JSON.stringify({ note: "hi", n: 1, b: true, l: [1], o: {}, z: null }));
  eq(r.structuredContent.argument_types.l, "array"); eq(r.structuredContent.argument_types.z, "null");
});

await test("probe_echo: a token that appears in an ordinary header value is still redacted (by value)", async () => {
  const r = await callTool("probe_echo", {}, deps({ headers: new Headers({ "x-forwarded-uri": "/mcp/" + fakeToken }) }));
  if (JSON.stringify(r).includes(fakeToken)) throw new Error("token leaked via a non-credential header");
});

await test("redactHeaders caps the count and truncates long values; plain objects work too", () => {
  const many = {}; for (let i = 0; i < LIMITS.echoHeaderMax + 5; i++) many["x-h" + i] = "v".repeat(1000);
  const out = redactHeaders(many);
  eq(out["<dropped>"], 5);
  eq(out["x-h0"].length, LIMITS.echoValueMax);
});

await test("redactPath: only the first segment after /mcp/ is replaced; other paths untouched", () => {
  eq(redactPath("/mcp/abc/def"), "/mcp/<token>/def");
  eq(redactPath("/mcp"), "/mcp");
  eq(redactPath("/api/act/0x00"), "/api/act/0x00");
});

await test("probe_delay: waits the requested time with the injected sleep, caps at the bridge wall, refuses non-numbers", async () => {
  let slept = 0; const d = deps({ sleep: async (ms) => { slept += ms; } });
  let r = await callTool("probe_delay", { seconds: 2.5 }, d);
  eq(slept, 2500); eq(r.structuredContent.capped, false);
  slept = 0; r = await callTool("probe_delay", { seconds: 1000 }, d);
  eq(slept, LIMITS.delayMaxS * 1000); eq(r.structuredContent.capped, true); eq(r.structuredContent.cap_s, LIMITS.delayMaxS);
  slept = 0; r = await callTool("probe_delay", { seconds: -5 }, d);
  eq(slept, 0);
  await throws(() => callTool("probe_delay", { seconds: "soon" }, d), /number/);
});

await test("probe_payload: exactly N bytes for small, odd and large N; sha256 matches node; cap applied", async () => {
  for (const n of [1, 7, 73, 1000, 65_537]) {
    const r = await callTool("probe_payload", { bytes: n }, deps());
    const t = r.content[0].text;
    eq(Buffer.byteLength(t, "utf8"), n, "bytes for " + n);
    eq(r.structuredContent.sha256, "0x" + createHash("sha256").update(t).digest("hex"), "sha for " + n);
    eq(r.structuredContent.capped, false);
  }
  const big = await callTool("probe_payload", { bytes: LIMITS.payloadMaxBytes + 1 }, deps());
  eq(Buffer.byteLength(big.content[0].text, "utf8"), LIMITS.payloadMaxBytes);
  eq(big.structuredContent.capped, true);
  await throws(() => callTool("probe_payload", { bytes: "lots" }, deps()), /number/);
});

await test("payloadText is ASCII (bytes == chars) and self-describing", () => {
  const t = payloadText(500, "stamp");
  eq(t.length, 500); if (!/^probe_payload bytes=500 stamp\n/.test(t)) throw new Error(t.slice(0, 40));
  if (/[^\x00-\x7f]/.test(t)) throw new Error("non-ascii");
});

await test("probe_schema: the schema carries the features the tool claims; the call reports arrival types", async () => {
  const s = TOOLS.find((t) => t.name === "probe_schema").inputSchema;
  for (const k of ["enum", "const", "pattern", "format", "minimum", "exclusiveMinimum", "default", "minItems", "uniqueItems", "oneOf", "additionalProperties"]) {
    if (!JSON.stringify(s).includes(`"${k}"`)) throw new Error("schema lacks " + k);
  }
  const r = await callTool("probe_schema", { mode: "read", nested: { id: 1 }, count: "3" }, deps());
  eq(r.structuredContent.argument_types.count, "string", "a string count must be reported as a string, not coerced");
});

await test("probe_error: three kinds, three shapes", async () => {
  const t = await callTool("probe_error", { kind: "tool" }, deps());
  eq(t.isError, true);
  const j = await callTool("probe_error", { kind: "jsonrpc" }, deps());
  eq(j.jsonrpcError.code, -32602);
  await throws(() => callTool("probe_error", { kind: "throw" }, deps()), /thrown server error/);
  await throws(() => callTool("probe_error", { kind: "other" }, deps()), /one of/);
});

await test("resources and prompts: one each, readable, unknown names refused", async () => {
  eq(RESOURCES.length, 1); eq(PROMPTS.length, 1);
  const r = readResource(RESOURCES[0].uri);
  if (!/probe_delay/.test(r.contents[0].text)) throw new Error("resource text");
  await throws(async () => readResource("possessio://nope"), /unknown resource/);
  const p = getPrompt("probe_prompt", { topic: "walls" });
  if (!/walls/.test(p.messages[0].content.text)) throw new Error("prompt text");
  await throws(async () => getPrompt("probe_prompt", {}), /topic/);
  await throws(async () => getPrompt("nope", { topic: "x" }), /unknown prompt/);
});

await test("helpers: clampInt rounds and bounds; sha256Hex matches node", async () => {
  eq(clampInt("7.6", 1, 10, 0), 8); eq(clampInt(99, 1, 10, 0), 10); eq(clampInt("x", 1, 10, 5), 5);
  eq(await sha256Hex("abc"), "0x" + createHash("sha256").update("abc").digest("hex"));
});

await test("unknown tool is refused", async () => { await throws(() => callTool("probe_nope", {}, deps()), /unknown mirror tool/); });

for (const [n, ok, why] of results) console.log(`  [${ok ? "PASS" : "FAIL"}] ${n}${ok ? "" : " — " + why}`);
const n = results.filter((r) => r[1]).length;
console.log(`RESULT: ${n}/${results.length} PASS`);
process.exit(n === results.length ? 0 : 1);
