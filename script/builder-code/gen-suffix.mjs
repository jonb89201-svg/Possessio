#!/usr/bin/env node
// Regenerate + verify the ERC-8021 Builder Code data suffix wired into
// public/index.html (const BUILDER.SUFFIX).  Run:
//     node script/builder-code/gen-suffix.mjs
//
// Canonical source is ox/erc8021 (the library the Base docs point to) when it is
// installed; a dependency-free encoder cross-checks it and is what the repo
// verifies against by default. Exits non-zero on any mismatch so this can gate CI.
//
// Builder Code: bc_p422ohhb  (payout address = treasury Safe 0x188bE439…, set on base.dev)
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const CODE = "bc_p422ohhb";

// Dependency-free ERC-8021 single-code encoder:
//   [utf8(code)] [len : 1 byte] [0x00] [0x8021 × 8 = 16 bytes]
// (verified byte-for-byte equal to ox/erc8021 Attribution.toDataSuffix).
function encodeSuffix(code) {
  const codeHex = Buffer.from(code, "utf8").toString("hex");
  const len = (code.length & 0xff).toString(16).padStart(2, "0");
  const marker = "8021".repeat(8);
  return ("0x" + codeHex + len + "00" + marker).toLowerCase();
}

const pure = encodeSuffix(CODE);

let ox = null;
try {
  const { Attribution } = await import("ox/erc8021");
  ox = Attribution.toDataSuffix({ codes: [CODE] }).toLowerCase();
} catch { /* ox is optional; `npm i ox` to cross-check against the reference lib */ }

// Extract the constant actually wired into the frontend and confirm they agree.
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(resolve(here, "../../public/index.html"), "utf8");
const m = html.match(/SUFFIX:\s*"(0x[0-9a-fA-F]+)"/);
const wired = m ? m[1].toLowerCase() : null;

console.log("code   :", CODE);
console.log("pure   :", pure);
if (ox) console.log("ox     :", ox);
console.log("wired  :", wired, "(public/index.html BUILDER.SUFFIX)");

let ok = true;
if (ox && ox !== pure) { console.error("MISMATCH: ox/erc8021 != pure encoder"); ok = false; }
if (wired !== pure)    { console.error("MISMATCH: public/index.html BUILDER.SUFFIX != computed suffix"); ok = false; }
console.log(ok
  ? "\nOK — suffix verified" + (ox ? " against ox/erc8021" : " (pure encoder; run `npm i ox` to also cross-check the reference lib)")
  : "\nFAILED");
process.exit(ok ? 0 : 1);
