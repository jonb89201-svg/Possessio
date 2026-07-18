// x402 V2 Bazaar Discovery — proof the tolled routes declare VALID discovery
// extensions (SPEC_BusinessModel.md R1: the one worker-layer build).
//
// This does NOT test payment verification (that is the official middleware's job,
// and the audit law forbids us re-implementing it). It tests the ONE thing this
// seat authored: the per-route Bazaar declaration config. It runs the SAME
// validator the middleware runs on startup (`validateBazaarRouteExtensions`, which
// console.warns on any invalid route), against the EXACT config buildTolledApp
// ships (imported, not re-typed — no drift).
//
// Regression it guards: the Bazaar spec requires output.example to be an OBJECT, so
// the array-returning /radar/tape route must use output.schema instead — a real bug
// caught during the build (an array example failed validation).
//   node --test radar/test/x402-discovery.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateBazaarRouteExtensions } from "@x402/extensions";
import { tollRoutes } from "../toll-routes.ts";

const ROUTES = tollRoutes({
  network: "eip155:8453",
  payTo: "0x000000000000000000000000000000000000dEaD",
  prices: { gapStats: "$0.005", sessionGate: "$0.01", tape: "$0.02" },
  iconUrl: "https://possessio.io/icon-1024.png",
});

const KEYS = ["GET /radar/gap-stats", "GET /radar/session-gate", "GET /radar/tape"];

test("all three tolled routes are present with a payTo + price", () => {
  for (const k of KEYS) {
    const r = ROUTES[k];
    assert.ok(r, `${k} present`);
    assert.equal(r.accepts.scheme, "exact");
    assert.equal(r.accepts.payTo, "0x000000000000000000000000000000000000dEaD");
    assert.ok(typeof r.accepts.price === "string" && r.accepts.price.startsWith("$"), `${k} priced`);
  }
});

test("every route declares a bazaar discovery extension with info + schema", () => {
  for (const k of KEYS) {
    const bazaar = ROUTES[k].extensions?.bazaar;
    assert.ok(bazaar && typeof bazaar === "object", `${k} has extensions.bazaar`);
    assert.ok("info" in bazaar && "schema" in bazaar, `${k} bazaar has info + schema (enrichable)`);
    assert.ok(Array.isArray(ROUTES[k].tags) && ROUTES[k].tags.length > 0, `${k} carries catalog tags`);
    assert.ok(typeof ROUTES[k].serviceName === "string", `${k} carries a serviceName`);
  }
});

test("the shipped config passes the middleware's own Bazaar validator (no warnings)", () => {
  // validateBazaarRouteExtensions console.warns per invalid route — this is the
  // exact check that flagged the tape array-example bug. Capture and assert zero.
  const warnings = [];
  const orig = console.warn;
  console.warn = (...a) => warnings.push(a.join(" "));
  try {
    validateBazaarRouteExtensions(ROUTES);
  } finally {
    console.warn = orig;
  }
  const bad = warnings.filter((w) => /bazaar extension/i.test(w));
  assert.deepEqual(bad, [], `no route has an invalid bazaar extension:\n${bad.join("\n")}`);
});

test("object-returning routes use output.example; the array route (tape) uses output.schema", () => {
  // object responses -> example (an object); array response -> schema (type:array).
  // This is the invariant that keeps tape valid under the object-example rule.
  const gapInfo = ROUTES["GET /radar/gap-stats"].extensions.bazaar.info;
  assert.ok(gapInfo.output?.example && typeof gapInfo.output.example === "object" && !Array.isArray(gapInfo.output.example),
    "gap-stats declares an object output example");

  const tapeSchema = ROUTES["GET /radar/tape"].extensions.bazaar.schema;
  // the tape route must NOT carry an array example (would fail validation); its
  // output shape lives in the schema as type:"array".
  const tapeInfo = ROUTES["GET /radar/tape"].extensions.bazaar.info;
  assert.ok(!Array.isArray(tapeInfo.output?.example), "tape declares no array example");
  assert.ok(tapeSchema, "tape carries a discovery schema");
});
