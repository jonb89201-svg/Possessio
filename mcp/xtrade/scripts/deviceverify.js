// Device-verify for the xtrade Jupiter path. Runs the REAL shipped adapter
// (../adapters/jupiter.js) against live Solana + Jupiter, so a green run
// proves the actual code - not a stand-in.
//
// MUST be run where there IS network (the Code Integrity seat's RPC tooling,
// or the Architect's terminal). It will NOT run inside Claude Code's sandbox
// (outbound is allowlist-blocked - that is the whole reason this is device-
// verify). No signing, no private key: quote + build produce an UNSIGNED tx.
//
// RUN:
//   SOLANA_RPC="<your QuickNode Solana mainnet URL>" \
//   VERIFY_PUBKEY="<any Solana wallet PUBLIC key>" \
//     node mcp/xtrade/scripts/deviceverify.js
//
// - SOLANA_RPC is a live secret (key in the path) - keep it out of the repo.
// - VERIFY_PUBKEY is a PUBLIC key (safe to share); needed only for the build
//   step. Omit it and the script still proves the live quote + RPC health.
"use strict";
const { runtimeEnv } = require("../config");
const jupiter = require("../adapters/jupiter");

const SOL_MINT  = "So11111111111111111111111111111111111111112";  // wrapped SOL
const USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";  // Solana USDC
const AMOUNT    = "100000000"; // 0.1 SOL (lamports) - read-only quote, nothing moves

async function rpc(url, method, params = []) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!r.ok) throw new Error(method + " HTTP " + r.status);
  const j = await r.json();
  if (j.error) throw new Error(method + " RPC error: " + JSON.stringify(j.error));
  return j.result;
}

(async () => {
  const rt = runtimeEnv();
  const pubkey = process.env.VERIFY_PUBKEY || "";
  let pass = true;
  const line = (ok, msg) => { console.log((ok ? "  PASS " : "  FAIL ") + msg); if (!ok) pass = false; };

  console.log("xtrade device-verify - live Solana + Jupiter\n");

  // 1) RPC reachable + healthy
  if (!rt.solanaRpc) { console.error("FAIL: SOLANA_RPC env not set"); process.exit(1); }
  try {
    const health = await rpc(rt.solanaRpc, "getHealth");
    const ver = await rpc(rt.solanaRpc, "getVersion");
    line(health === "ok", "RPC getHealth = " + JSON.stringify(health) + "  (solana-core " + (ver && ver["solana-core"]) + ")");
    const slot = await rpc(rt.solanaRpc, "getSlot");
    line(Number(slot) > 0, "RPC getSlot = " + slot + " (chain is advancing)");
  } catch (e) { line(false, "RPC unreachable: " + e.message); }

  // 2) Jupiter quote via the SHIPPED adapter (read-only, nothing signed)
  let quote = null;
  try {
    quote = await jupiter.quote(rt, { inputMint: SOL_MINT, outputMint: USDC_MINT, amountAtomic: AMOUNT, slippageBps: 50 });
    const out = Number(quote.outAmount) / 1e6;
    line(Number(quote.outAmount) > 0, "Jupiter quote 0.1 SOL -> " + out.toFixed(2) + " USDC  (priceImpact " + quote.priceImpactPct + "%)");
  } catch (e) { line(false, "Jupiter quote failed: " + e.message + "  (if 404, Jupiter base moved - set JUPITER_BASE)"); }

  // 3) Build the UNSIGNED swap tx via the shipped adapter (needs a public key; no signing)
  if (quote && pubkey) {
    try {
      const built = await jupiter.buildSwapTx(rt, { quoteResponse: quote, userPublicKey: pubkey });
      line(!!built.unsignedTxBase64 && built.unsignedTxBase64.length > 100,
        "Jupiter build -> unsigned tx (" + (built.unsignedTxBase64 ? built.unsignedTxBase64.length : 0) + " b64 chars, lastValidBlockHeight " + built.lastValidBlockHeight + ")");
    } catch (e) { line(false, "Jupiter build failed: " + e.message); }
  } else if (!pubkey) {
    console.log("  SKIP build step - set VERIFY_PUBKEY=<a public wallet key> to exercise it");
  }

  console.log("\n" + (pass ? "RESULT: PASS - live quote->build path works. Adapter is real." : "RESULT: FAIL - see lines above; paste this output to Claude Code."));
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error("FAIL (unexpected): " + (e.message || e)); process.exit(1); });
