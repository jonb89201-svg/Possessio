// Solana swap adapter - Jupiter aggregator.
// NON-PROVEN in the build sandbox: these two functions hit the network
// (quote-api.jup.ag), which is 403-blocked here. Structure + shapes are
// written to Jupiter's documented v6 API; the Architect proves them live
// on-device (SPEC_CrossChainTradingMCP.md Sec8). No key is used or held:
// quote + swap-tx build are unsigned; signing is the Architect's, or the
// dedicated hot wallet's under the Sec4 gates.
"use strict";

// amountAtomic: input amount in the input mint's smallest units (string).
// slippageBps: capped upstream by caps.js (server-enforced <= LAW ceiling).
async function quote(rt, { inputMint, outputMint, amountAtomic, slippageBps }) {
  const u = new URL(rt.jupiterBase + "/v6/quote");
  u.searchParams.set("inputMint", inputMint);
  u.searchParams.set("outputMint", outputMint);
  u.searchParams.set("amount", String(amountAtomic));
  u.searchParams.set("slippageBps", String(slippageBps));
  const res = await fetch(u, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error("jupiter quote " + res.status);
  return res.json(); // route plan, outAmount, priceImpactPct, ...
}

// Returns a BASE64 UNSIGNED VersionedTransaction. The caller never signs
// here - build mode returns it to the Architect; hot mode passes it to the
// dedicated-wallet signer under the three gates.
async function buildSwapTx(rt, { quoteResponse, userPublicKey }) {
  const res = await fetch(rt.jupiterBase.replace("quote-api", "quote-api") + "/v6/swap", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      quoteResponse,
      userPublicKey,
      wrapAndUnwrapSol: true,
      // no fee account, no auto-signing - unsigned tx only
    }),
  });
  if (!res.ok) throw new Error("jupiter swap-build " + res.status);
  const j = await res.json();
  return { unsignedTxBase64: j.swapTransaction, lastValidBlockHeight: j.lastValidBlockHeight };
}

module.exports = { quote, buildSwapTx, __deviceVerify: true };
