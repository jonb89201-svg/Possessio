// SPDX-License-Identifier: MIT
// BUILD-PROOF: DERIVE_ANCHOR_V1 — deterministic, phrase-derived CREATE3 anchor for
// the POSSESSIO constellation. Recomputes every salt + predicted address from a
// single PHRASE, so the entire foundation regenerates from a string alone (lose
// anchor.json, the repo, or the device — the phrase reproduces it exactly).
//
// Salts are PUBLIC, sender-locked params — not secret. The anchor KEY (the EOA)
// is the only secret. byte-20 = 0x00 reserves the same addresses on every EVM
// chain at zero cost; deploying is Base-only (a later, separate decision).
//
// DERIVATION (identical in JS and Solidity — keccak of the UTF-8 string):
//   organEntropy(tag) = low 88 bits of keccak256(utf8( PHRASE + "/" + tag ))
//   salt              = [ deployer(20) ][ 0x00 ][ entropy(11) ]
//   hookEntropy(i)    = low 88 bits of keccak256(utf8( PHRASE + "/hook/" + i ))
//                       searched i=0,1,2… keeping (addr & 0x3FFF) == 0x08C8
//   guardedSalt       = keccak256( leftpad32(deployer) ++ salt )   // packed, no chainid
//   address           = CREATE( CREATE2(CreateX, guardedSalt, proxyInit), nonce=1 )
// The CREATE3 math is byte-verified against CreateX (proxyInitHash asserted below;
// cross-checked to the on-chain-mined 0x5Bc6…88c8 earlier).
//
// Usage: node script/derive_anchor.mjs [--phrase STR] [--eoa 0x..] [--hooks N]

import { keccak256, concat, pad, getContractAddress, numberToHex, toBytes, getAddress } from "viem";
import { writeFileSync } from "node:fs";

const CREATEX = "0xba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed";
const PROXY_INIT = "0x67363d3d37363d34f03d5260086018f3";
const PROXY_INITCODE_HASH = "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f";
const MASK88 = (1n << 88n) - 1n;
const FLAG_MASK = 0x3fffn, FLAG_TARGET = 0x8c8n;

const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf("--" + k); return i >= 0 ? argv[i + 1] : d; };
const PHRASE = arg("phrase", "TREGUNA_MEKOIDES_TRECORUM_SATIS_DEE");
const EOA = getAddress(arg("eoa", "0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC"));
const N_HOOKS = Number(arg("hooks", "8"));

if (keccak256(PROXY_INIT).toLowerCase() !== PROXY_INITCODE_HASH) { console.error("FATAL: proxy-init hash drift"); process.exit(1); }

const create3 = (deployer, saltHex) => {
  const gs = keccak256(concat([pad(deployer, { size: 32 }), saltHex]));
  const proxy = getContractAddress({ opcode: "CREATE2", from: CREATEX, bytecode: PROXY_INIT, salt: gs });
  return getContractAddress({ opcode: "CREATE", from: proxy, nonce: 1n });
};
const ent = (tag) => BigInt(keccak256(toBytes(PHRASE + "/" + tag))) & MASK88;
const saltFor = (deployer, entropy) => numberToHex((BigInt(deployer) << 96n) | entropy, { size: 32 });

// ---- foundation organs (EOA-keyed, no flags, no search) ----
const organs = {};
for (const tag of ["factory", "saltpool", "x402core", "pool"]) {
  const salt = saltFor(EOA, ent(tag));
  organs[tag] = { deployer: EOA, salt, address: create3(EOA, salt) };
}
const FACTORY = organs.factory.address;

// ---- hook salts (FACTORY-keyed, 0x8C8 search via /hook/i) ----
const hookSalts = [];
let i = 0, t = Date.now();
while (hookSalts.length < N_HOOKS) {
  const e = BigInt(keccak256(toBytes(PHRASE + "/hook/" + i))) & MASK88;
  const salt = saltFor(FACTORY, e);
  const address = create3(FACTORY, salt);
  if ((BigInt(address) & FLAG_MASK) === FLAG_TARGET) hookSalts.push({ i, salt, address });
  i++;
}

const anchor = {
  $comment: "POSSESSIO constellation anchor. Recomputable from `phrase` alone via `derivation`. Salts are PUBLIC sender-locked params (NOT secret); the anchor EOA key is the only secret. Base mainnet only. byte-20=0x00 reserves the same addresses on every EVM chain at zero cost.",
  network: "base-mainnet-8453",
  anchorEOA: EOA,
  phrase: PHRASE,
  derivation: {
    createX: getAddress(CREATEX),
    proxyInitcodeHash: PROXY_INITCODE_HASH,
    organEntropy: "low 88 bits of keccak256(utf8(phrase + '/' + tag))",
    hookEntropy: "low 88 bits of keccak256(utf8(phrase + '/hook/' + i)), i=0,1,2… kept where (addr & 0x3FFF)==0x08C8",
    saltLayout: "[deployer 20 bytes][0x00][entropy 11 bytes]",
    guardedSalt: "keccak256(leftpad32(deployer) ++ salt) — CreateX MsgSender/RedeployProtection.False, packed, no chainid",
    create3: "CREATE(CREATE2(createX, guardedSalt, proxyInitcode), nonce=1)",
    hookFlags: "0x08C8 = beforeAddLiquidity + beforeSwap + afterSwap + beforeSwapReturnsDelta (low 14 bits)",
  },
  organs,
  hookSalts,
  deployOrder: [
    "1. factory  (CREATE3, EOA-keyed)  -> extcodehash gate == expected(factory)",
    "2. saltpool (CREATE3, EOA-keyed)  -> extcodehash gate",
    "3. x402core (CREATE3, EOA-keyed)  -> extcodehash gate",
    "4. pool     (CREATE3, EOA-keyed; authorizedSources=[factory,x402core]) -> extcodehash gate",
    "5. keeper refills saltpool with hookSalts (0x8C8, factory-keyed)",
    "NOTE: extcodehash 'expected' values are recorded at fork-test time from the compiled runtime code.",
  ],
  wiring_feeSink_A: {
    decision: "A — factory routes deployment fees INTO the pool (self-funding day one)",
    "Factory._feeSink": organs.pool.address + "  (the pool)",
    "Factory._saltPool": organs.saltpool.address,
    "Factory.line211_EDIT": "safeTransfer(feeSink) -> forceApprove(pool) + pool.receiveInfraFunds(DEPLOYMENT_FEE)",
    "SaltPool._factory": organs.factory.address,
    "SaltPool._deploymentFeeSource": organs.factory.address + "  (keeper-separation CHECK ONLY — not a money route)",
    "Pool.authorizedSources": [organs.factory.address, organs.x402core.address],
  },
  owed: [
    "keeper wallet (fresh, compute-only, != any money destination)",
    "TEMPLATE_CODEHASH (pin from post-audit build, then freeze source)",
    "operator/treasury destinations — recommended Base Account 0x6cfe30ce…9203 (passkey-bound)",
    "DEPLOYMENT_FEE (Architect's price)",
    "BASE_RPC_URL (QuickNode) — gates the constellation fork test",
    "CONFIRM anchor EOA is funded on Base mainnet (council saw balance 0)",
  ],
};

writeFileSync("deploy/anchor.json", JSON.stringify(anchor, null, 2) + "\n");
console.log("phrase   :", PHRASE);
console.log("EOA      :", EOA);
console.log("FACTORY  :", organs.factory.address, "(salt", organs.factory.salt + ")");
console.log("SALTPOOL :", organs.saltpool.address);
console.log("X402CORE :", organs.x402core.address);
console.log("POOL     :", organs.pool.address);
console.log(`HOOKS    : ${hookSalts.length} mined (${i} iters, ${((Date.now() - t) / 1000).toFixed(1)}s), all end 8c8`);
for (const h of hookSalts) console.log("   hook/" + h.i, h.salt, "->", h.address);
console.log("-> wrote deploy/anchor.json");
