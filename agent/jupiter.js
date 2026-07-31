// Solana execution: quote -> build -> (sign) -> send, via Jupiter.
//
// The build step is deliberately separate from the sign step, so DRY_RUN can
// run the entire path and stop at the last moment with the exact transaction
// it would have sent. A dry run that skipped the build would be proving less
// than it appears to.
"use strict";

const { CFG } = require("./config");

async function quote({ inputMint, outputMint, amountAtomic, slippageBps }) {
  const u = new URL(CFG.jupiterBase + "/quote");
  u.searchParams.set("inputMint", inputMint);
  u.searchParams.set("outputMint", outputMint);
  u.searchParams.set("amount", String(amountAtomic));
  u.searchParams.set("slippageBps", String(slippageBps ?? CFG.slippageBps));
  const res = await fetch(u, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`jupiter quote ${res.status}`);
  const j = await res.json();
  if (!j || !j.outAmount) throw new Error("jupiter quote: no route");
  return j;
}

/// Price of `mint` in USDC, derived from a real quote for `probeUsdc` of size —
/// i.e. the price you could ACTUALLY get for that size, not a mid-price. The
/// stop must trigger on executable price, not on a number nobody can trade at.
async function priceInUsdc(mint, tokenDecimals, probeAtomic) {
  const q = await quote({
    inputMint: mint,
    outputMint: CFG.usdcSolana,
    amountAtomic: probeAtomic,
    slippageBps: CFG.slippageBps,
  });
  const usdcOut = Number(q.outAmount) / 1e6;
  const tokensIn = Number(probeAtomic) / 10 ** tokenDecimals;
  return { price: usdcOut / tokensIn, quote: q };
}

async function buildSwapTx({ quoteResponse, userPublicKey }) {
  const res = await fetch(CFG.jupiterBase + "/swap", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      quoteResponse,
      userPublicKey,
      wrapAndUnwrapSol: true,
      dynamicComputeUnitLimit: true,
    }),
  });
  if (!res.ok) throw new Error(`jupiter swap-build ${res.status}`);
  const j = await res.json();
  if (!j.swapTransaction) throw new Error("jupiter swap-build: no transaction");
  return j.swapTransaction; // base64, UNSIGNED
}

/// Sign and send. The ONLY place this process ever signs anything, so the
/// dry-run gate lives here as a second wall behind the caller's own check.
async function signAndSend(unsignedTxBase64, keypair, connection) {
  if (CFG.dryRun) {
    return { dryRun: true, signature: null, txBytes: unsignedTxBase64.length };
  }
  const { VersionedTransaction } = require("@solana/web3.js");
  const tx = VersionedTransaction.deserialize(Buffer.from(unsignedTxBase64, "base64"));
  tx.sign([keypair]);
  const sig = await connection.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    maxRetries: 3,
  });
  const bh = await connection.getLatestBlockhash();
  await connection.confirmTransaction(
    { signature: sig, blockhash: bh.blockhash, lastValidBlockHeight: bh.lastValidBlockHeight },
    "confirmed"
  );
  return { dryRun: false, signature: sig };
}

module.exports = { quote, priceInUsdc, buildSwapTx, signAndSend };
