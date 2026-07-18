// SPDX-License-Identifier: MIT
// BUILD-PROOF: PREMINE_SALTS_V1 — RPC-free local equivalent of
// MineCreate3Salt.s.sol. Mines CreateX sender-locked CREATE3 salts whose
// deployed address carries the V4 0x8C8 hook-flag suffix, and emits a
// refillSalts(bytes32[])-ready batch for PossessioSaltPool.
//
// The formula is byte-identical to PredictCreate3Addresses.s.sol:
//   guardedSalt = keccak256( leftpad32(deployer) ++ salt )     // packed, no chainid
//   proxy       = CREATE2(CREATEX, guardedSalt, PROXY_INITCODE) // low 20 bytes
//   address     = CREATE(proxy, nonce=1)                        // low 20 bytes
// cross-checked 3 ways (real deploy vs CreateX view vs this math) in
// PossessioSaltPoolCreate3.t.sol. The proxy-init hash is asserted on startup so
// any formula drift fails loudly instead of predicting garbage.
//
// SALT LAYOUT (CreateX [sender-locked, 0x00] branch):
//   [ deployer 20 bytes ][ 0x00 ][ entropy 11 bytes ]
//   deployer == the CreateX.deployCreate3 CALLER — for the salt pool that is the
//   PREDICTED FACTORY address (the factory pulls a salt, then calls CreateX).
//
// Hit rate is ~1/16384 (0x8C8 under the 14-bit ALL_HOOK_MASK), not 1/4096.
//
// Usage (run from repo root; uses node_modules/viem):
//   node script/premine_salts.mjs --factory 0xFACTORY --count 20 [--start 0xHEX]
//   node script/premine_salts.mjs --factory 0xFACTORY --predict 0xSALT   # predict one, no mining
//
// --start lets a later refill continue past a prior run's entropy so it never
// re-mines the same salts (a duplicate would revert at the factory's 2nd
// CREATE3 to an already-used address — PossessioSaltPool Q1b). Omitted → a
// random 88-bit start (printed, so it's reproducible).

import { keccak256, concat, pad, getContractAddress, numberToHex, isAddress } from "viem";
import { randomBytes } from "node:crypto";

const CREATEX = "0xba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed";
const PROXY_INIT = "0x67363d3d37363d34f03d5260086018f3";
const PROXY_INITCODE_HASH = "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f";
const FLAG_MASK = 0x3fffn; // low 14 bits (V4 ALL_HOOK_MASK)
const FLAG_TARGET = 0x8c8n; // beforeAddLiquidity + beforeSwap + afterSwap + beforeSwapReturnsDelta

// ---- args ----
const argv = process.argv.slice(2);
const args = {};
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) {
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    args[key] = next && !next.startsWith("--") ? next : true;
    if (args[key] !== true) i++;
  }
}

const factory = typeof args.factory === "string" ? args.factory : null;
if (!factory || !isAddress(factory)) {
  console.error("ERROR: --factory 0x... required (the CreateX caller the salts lock to — usually the PREDICTED factory address).");
  process.exit(1);
}

// startup guard: our formula must reproduce the pinned proxy-init hash
if (keccak256(PROXY_INIT).toLowerCase() !== PROXY_INITCODE_HASH) {
  console.error("FATAL: proxy-init hash mismatch — CREATE3 formula drift. Refusing.");
  process.exit(1);
}

const senderWord = pad(factory, { size: 32 });
const create3 = (saltHex) => {
  const gs = keccak256(concat([senderWord, saltHex]));
  const proxy = getContractAddress({ opcode: "CREATE2", from: CREATEX, bytecode: PROXY_INIT, salt: gs });
  return getContractAddress({ opcode: "CREATE", from: proxy, nonce: 1n });
};
const buildSalt = (entropy) =>
  numberToHex((BigInt(factory) << 96n) | (entropy & ((1n << 88n) - 1n)), { size: 32 });

// ---- predict-only mode ----
if (typeof args.predict === "string") {
  const s = args.predict.toLowerCase();
  const top20 = "0x" + s.slice(2, 42);
  const byte20 = s.slice(42, 44);
  if (top20 !== factory.toLowerCase() || byte20 !== "00") {
    console.error("ERROR: salt is not sender-locked to --factory. Layout must be [deployer 20][0x00][entropy 11].");
    process.exit(1);
  }
  console.log("salt      :", s);
  console.log("predicted :", create3(s), "(flags 0x" + (BigInt(create3(s)) & FLAG_MASK).toString(16) + ")");
  process.exit(0);
}

// ---- mine mode ----
const count = Number(args.count || 10);
let entropy = typeof args.start === "string" ? BigInt(args.start) : BigInt("0x" + randomBytes(11).toString("hex"));
const startEntropy = entropy;
const out = [];
let iters = 0;
const ceiling = BigInt(count) * 16384n * 8n; // generous safety bound
const t = Date.now();
while (out.length < count) {
  const salt = buildSalt(entropy);
  const addr = create3(salt);
  if ((BigInt(addr) & FLAG_MASK) === FLAG_TARGET) out.push({ salt, addr });
  entropy++;
  iters++;
  if (BigInt(iters) > ceiling) {
    console.error(`ERROR: iteration ceiling (${ceiling}) hit with only ${out.length}/${count} — check --factory.`);
    process.exit(1);
  }
}
const secs = ((Date.now() - t) / 1000).toFixed(1);

console.log(`# premined ${out.length} salts | factory ${factory}`);
console.log(`# ${iters} iters in ${secs}s (~${Math.round(iters / out.length)}/salt) | start 0x${startEntropy.toString(16)} | next --start 0x${entropy.toString(16)}`);
console.log("#");
console.log("# predicted hook addresses (record for wiring — each ends 0x8C8):");
for (const o of out) console.log(`#   ${o.salt}  ->  ${o.addr}`);
console.log("#");
console.log("# refillSalts(bytes32[]) argument:");
console.log("[\n" + out.map((o) => "    " + o.salt).join(",\n") + "\n]");
console.log("# JSON:");
console.log(JSON.stringify(out.map((o) => o.salt)));
