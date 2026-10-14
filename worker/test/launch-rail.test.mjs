// The console's launch rail must never point at a factory that pins a
// pre-fix PossessioPayments template. node worker/test/launch-rail.test.mjs
import fs from "fs";
import assert from "assert";
import { fileURLToPath } from "url";
import path from "path";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "../..");
const html = fs.readFileSync(path.join(root, "public/index.html"), "utf8");

// Factories whose templateCodehash pins a template the audits have since fixed.
// 0x0DD0…49Bd: templateCodehash 0x14357940…e39d (MEASURED 2026-10-14), no P-H1/P-H2.
const PRE_FIX_FACTORIES = ["0x0dd06656cb9a38730a7177792c357e48cedb49bd"];

const start = html.indexOf("(function LaunchRailLive()");
assert.ok(start > 0, "LaunchRailLive module not found");
const m = html.slice(start).match(/FACTORY:\s*\{([\s\S]*?)\n\s*\},/);
assert.ok(m, "rail FACTORY config not found");
const entry = m[1].match(/^\s*8453:\s*(null|"0x[0-9a-fA-F]{40}")/m);
assert.ok(entry, "FACTORY[8453] entry not found");
const v = entry[1] === "null" ? null : entry[1].slice(1, -1).toLowerCase();
assert.ok(!PRE_FIX_FACTORIES.includes(v), "FACTORY[8453] is a pre-fix factory: " + v);
console.log("launch-rail: PASS (FACTORY[8453] = " + (v || "null, preview") + ")");
