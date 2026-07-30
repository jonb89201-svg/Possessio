// The remote agent loop.
//
//   watch Base for a leg opened to me
//     -> read the intent the HUMAN authored (mint, target, stop)
//     -> buy that mint on Solana from the float
//     -> watch the executable price
//     -> on target or the un-removable stop: sell back to USDC
//     -> return the proceeds to the Rail, then settle (the Rail MEASURES them)
//
// It never picks a coin, never edits a target, never touches the stop.
"use strict";

const { CFG, assertRunnable, redacted } = require("./config");
const B = require("./base");
const J = require("./jupiter");

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const usd = (atomic) => (Number(atomic) / 1e6).toFixed(2);

// Legs this process is currently carrying. Persisted only in memory: on a
// restart the agent re-reads open legs from the chain rather than trusting a
// local file that could disagree with it.
const carrying = new Map();

function loadSolanaKeypair() {
  if (!CFG.solanaAgentKey) return null;
  const { Keypair } = require("@solana/web3.js");
  const raw = CFG.solanaAgentKey.trim();
  if (raw.startsWith("[")) return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(raw)));
  const bs58 = require("bs58");
  return Keypair.fromSecretKey(bs58.decode(raw));
}

/// Buy the authored mint with `usdcAtomic` of the Solana float.
async function openPosition({ intentId, mint, usdcAtomic, agentPubkey, connection, keypair }) {
  const q = await J.quote({
    inputMint: CFG.usdcSolana, outputMint: mint,
    amountAtomic: usdcAtomic.toString(), slippageBps: CFG.slippageBps,
  });
  const tokensOut = q.outAmount;
  const impact = Number(q.priceImpactPct || 0) * 100;
  log(`  [${intentId}] quote: ${usd(usdcAtomic)} USDC -> ${tokensOut} atomic of ${mint}` +
      `  impact ${impact.toFixed(3)}%  via ${(q.routePlan || []).map((r) => r.swapInfo.label).join(" -> ")}`);

  const tx = await J.buildSwapTx({ quoteResponse: q, userPublicKey: agentPubkey });
  const sent = await J.signAndSend(tx, keypair, connection);
  if (sent.dryRun) log(`  [${intentId}] DRY_RUN: built a ${sent.txBytes}-byte swap tx and STOPPED before signing`);
  else log(`  [${intentId}] BUY sent: ${sent.signature}`);

  return { tokensOut, entryQuote: q, signature: sent.signature };
}

/// Watch the executable price until the human's target or the fixed stop fires.
async function watchUntilTrigger({ intentId, mint, tokensAtomic, entryPrice, targetBps, stopBps, decimals }) {
  const target = entryPrice * (1 + targetBps / 10000);
  const stop = entryPrice * (1 - stopBps / 10000);
  log(`  [${intentId}] watching: entry ${entryPrice.toExponential(4)} | target +${targetBps / 100}% ` +
      `(${target.toExponential(4)}) | stop -${stopBps / 100}% (${stop.toExponential(4)})`);

  const deadline = Date.now() + CFG.legTimeoutMs;
  while (Date.now() < deadline) {
    try {
      const { price } = await J.priceInUsdc(mint, decimals, tokensAtomic);
      if (price >= target) return { kind: "target", price };
      if (price <= stop) return { kind: "stop", price };
    } catch (e) {
      log(`  [${intentId}] price probe failed (${e.message}) — retrying`);
    }
    await sleep(CFG.priceMs);
  }
  return { kind: "timeout", price: null };
}

async function closePosition({ intentId, mint, tokensAtomic, agentPubkey, connection, keypair }) {
  const q = await J.quote({
    inputMint: mint, outputMint: CFG.usdcSolana,
    amountAtomic: String(tokensAtomic), slippageBps: CFG.slippageBps,
  });
  const tx = await J.buildSwapTx({ quoteResponse: q, userPublicKey: agentPubkey });
  const sent = await J.signAndSend(tx, keypair, connection);
  log(`  [${intentId}] SELL ${sent.dryRun ? "(DRY_RUN, unsigned)" : sent.signature} -> ${usd(q.outAmount)} USDC`);
  return { usdcOut: BigInt(q.outAmount), signature: sent.signature };
}

async function handleLeg(ctx, leg) {
  const { pub, wallet, connection, keypair, agentPubkey } = ctx;
  const id = leg.intentId;
  if (carrying.has(id)) return;
  carrying.set(id, true);

  try {
    const intent = await B.readIntent(pub, id);
    if (intent.chainTag !== 101) { log(`  [${id}] not a Solana intent (chainTag ${intent.chainTag}) — ignoring`); return; }
    const mint = B.mintFromTokenRef(intent.tokenRef);

    // The agent's OWN ceiling, on top of the vault's caps.
    const capAtomic = BigInt(Math.floor(CFG.maxTradeUsdc * 1e6));
    const size = leg.usdcOut > capAtomic ? capAtomic : leg.usdcOut;
    if (size < leg.usdcOut) log(`  [${id}] NOTE: leg is ${usd(leg.usdcOut)} but MAX_TRADE_USDC caps me at ${usd(size)}`);

    log(`LEG ${id}: ${usd(leg.usdcOut)} USDC drawn on Base for mint ${mint} ` +
        `(target +${intent.targetBps / 100}%, stop -${intent.stopBps / 100}%)`);

    const opened = await openPosition({ intentId: id, mint, usdcAtomic: size, agentPubkey, connection, keypair });

    // Entry price measured from the fill we actually got, not from the quote
    // the console showed the human minutes earlier.
    const decimals = Number(opened.entryQuote.outputMintDecimals ?? 9) || 9;
    const entryPrice = (Number(size) / 1e6) / (Number(opened.tokensOut) / 10 ** decimals);

    if (CFG.dryRun) {
      log(`  [${id}] DRY_RUN: would now watch for +${intent.targetBps / 100}% / -${intent.stopBps / 100}% ` +
          `from entry ${entryPrice.toExponential(4)}, then sell, return USDC to the Rail, and settle. Stopping here.`);
      return;
    }

    const trig = await watchUntilTrigger({
      intentId: id, mint, tokensAtomic: opened.tokensOut, entryPrice,
      targetBps: intent.targetBps, stopBps: intent.stopBps, decimals,
    });
    if (trig.kind === "timeout") {
      log(`  [${id}] !! LEG TIMED OUT still holding the position. NOT abandoning it. Operator action required.`);
      return;
    }
    log(`  [${id}] ${trig.kind.toUpperCase()} fired at ${trig.price.toExponential(4)}`);

    const closed = await closePosition({ intentId: id, mint, tokensAtomic: opened.tokensOut, agentPubkey, connection, keypair });

    // Authorize the exit on the rule ledger, then deliver + settle on Base.
    const observed = BigInt(Math.floor(trig.price * 1e18));
    await B.resolveIntent(wallet, id, observed);

    const baseBal = await B.usdcBalance(pub, ctx.baseAddress);
    if (baseBal < closed.usdcOut) {
      log(`  [${id}] !! Base float ${usd(baseBal)} < proceeds ${usd(closed.usdcOut)} — REBALANCE NEEDED. ` +
          `Returning what I can hold back is not an option; skipping settle so nothing is misreported.`);
      return;
    }
    await B.returnProceedsToRail(wallet, closed.usdcOut);
    await B.settleRemoteLeg(wallet, id);
    log(`  [${id}] settled: Rail measured the delivered USDC and cleared the vault's exposure`);
  } catch (e) {
    log(`  [${id}] ERROR: ${e.message}`);
  } finally {
    carrying.delete(id);
  }
}

async function main() {
  assertRunnable();
  log("Possessio remote agent starting", JSON.stringify(redacted()));
  if (CFG.dryRun) log("DRY_RUN is ON — this process will build transactions and refuse to sign them.");

  const { pub, wallet, account } = B.makeClients();
  const keypair = loadSolanaKeypair();
  const agentPubkey = keypair ? keypair.publicKey.toBase58() : (process.env.SOLANA_AGENT_PUBKEY || "");
  if (!agentPubkey) throw new Error("need SOLANA_AGENT_KEY, or SOLANA_AGENT_PUBKEY for a dry run");

  const { Connection } = require("@solana/web3.js");
  const connection = new Connection(CFG.solanaRpc, "confirmed");
  const baseAddress = account ? account.address : (process.env.BASE_AGENT_ADDRESS || "");
  if (!baseAddress) throw new Error("need BASE_KEEPER_KEY, or BASE_AGENT_ADDRESS for a dry run");

  log(`agent solana=${agentPubkey}`);
  log(`agent base  =${baseAddress}`);

  // Float health up front — an agent that starts underfunded should say so
  // before a human taps a coin, not after.
  try {
    const baseBal = await B.usdcBalance(pub, baseAddress);
    log(`float base  : ${usd(baseBal)} USDC` +
        (Number(baseBal) / 1e6 < CFG.floatMinBaseUsdc ? "  << BELOW FLOAT_MIN_BASE_USDC — rebalance" : ""));
  } catch (e) { log(`float base  : unreadable (${e.message})`); }

  const ctx = { pub, wallet, connection, keypair, agentPubkey, baseAddress };
  let cursor = await pub.getBlockNumber();
  log(`watching Rail ${CFG.rail} for legs from block ${cursor}`);

  for (;;) {
    try {
      const { legs, nextBlock } = await B.pollOpenedLegs(pub, baseAddress, cursor);
      cursor = nextBlock;
      for (const leg of legs) handleLeg(ctx, leg);
    } catch (e) {
      log(`poll error: ${e.message}`);
    }
    await sleep(CFG.pollMs);
  }
}

if (require.main === module) {
  main().catch((e) => { console.error("fatal:", e.message); process.exit(1); });
}

module.exports = { handleLeg, watchUntilTrigger, loadSolanaKeypair };
