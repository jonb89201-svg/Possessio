// MINI-APP SOLANA LEG — browser side of Model B.
//
// Inside a Farcaster mini app the user HAS a Solana wallet. So a SOL pick is:
//
//   tap +50  ->  user signs the BUY   (their wallet, their token account)
//            ->  user signs a DELEGATE over exactly that position
//            ->  the keeper can fire the -10% stop at 3am, holding nothing
//
// Custody never leaves the user. The delegate is one mint, one amount, and
// revocable by them alone — the same shape as an ERC-20 approve.
//
// The console is a single vanilla file, so this uses the SDK's LOW-LEVEL
// provider (sdk.wallet.getSolanaProvider(), modelled on window.phantom.solana)
// rather than the React Wallet-Adapter path. Same wallet, no framework.
//
// The transaction shapes here are the ones certified against live mainnet in
// miniapp/test/solana-live.js (7/7 via simulateTransaction) — this is the
// browser twin of that module, not a second design.

import {
  Connection, PublicKey, VersionedTransaction, TransactionMessage,
} from "https://esm.sh/@solana/web3.js@1.95.3";
import {
  createApproveInstruction, createRevokeInstruction,
  getAssociatedTokenAddress, getAccount, getMint, TOKEN_PROGRAM_ID,
} from "https://esm.sh/@solana/spl-token@0.4.9";

const USDC_MINT = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const JUP = "https://lite-api.jup.ag/swap/v1";

let sdk = null, provider = null, conn = null, pubkey = null;

/// True only inside a Farcaster host. Everywhere else the desk keeps working
/// exactly as it does today — this file never breaks the plain web console.
export function isMiniApp() { return Boolean(sdk && provider); }
export function solanaAddress() { return pubkey ? pubkey.toBase58() : null; }

/// Boot the mini-app SDK. Safe to call in a normal browser: it resolves to
/// {miniApp:false} instead of throwing, so the console degrades rather than dies.
export async function initMiniApp(rpcUrl) {
  try {
    const mod = await import("https://esm.sh/@farcaster/miniapp-sdk@0.1.x");
    sdk = mod.sdk;
    const inHost = await sdk.isInMiniApp?.().catch(() => false);
    if (!inHost) { sdk = null; return { miniApp: false, reason: "not in a Farcaster host" }; }

    // Not every Farcaster client has a Solana wallet — check, never assume.
    provider = await sdk.wallet.getSolanaProvider?.().catch(() => null);
    if (!provider) {
      await sdk.actions.ready();
      return { miniApp: true, solana: false, reason: "this client has no Solana wallet" };
    }

    const res = await provider.connect();
    pubkey = new PublicKey(res?.publicKey?.toString?.() || res?.publicKey || provider.publicKey);
    conn = new Connection(rpcUrl || "https://solana-rpc.publicnode.com", "confirmed");

    await sdk.actions.ready();               // dismiss the splash
    return { miniApp: true, solana: true, address: pubkey.toBase58() };
  } catch (e) {
    sdk = null; provider = null;
    return { miniApp: false, reason: String(e?.message || e) };
  }
}

async function quote({ inputMint, outputMint, amount, slippageBps }) {
  const u = new URL(JUP + "/quote");
  u.searchParams.set("inputMint", inputMint);
  u.searchParams.set("outputMint", outputMint);
  u.searchParams.set("amount", String(amount));
  u.searchParams.set("slippageBps", String(slippageBps));
  const r = await fetch(u, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error("no route (jupiter " + r.status + ")");
  const j = await r.json();
  if (!j.outAmount) throw new Error("no route for this coin");
  return j;
}

/// What the user is about to authorize, priced from a live route — so the
/// sheet shows the real number, not an estimate the desk invented.
export async function quoteBuy({ mint, usdcAmount, slippageBps = 300 }) {
  const q = await quote({
    inputMint: USDC_MINT.toBase58(), outputMint: mint,
    amount: Math.round(usdcAmount * 1e6), slippageBps,
  });
  return {
    outAmount: q.outAmount,
    priceImpactPct: Number(q.priceImpactPct || 0) * 100,
    route: (q.routePlan || []).map((r) => r.swapInfo.label).join(" -> "),
    quote: q,
  };
}

/// STEP 1 — the buy. The user signs; the coin lands in the user's own account.
export async function signBuy({ quoteResponse }) {
  const r = await fetch(JUP + "/swap", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      quoteResponse, userPublicKey: pubkey.toBase58(),
      wrapAndUnwrapSol: true, dynamicComputeUnitLimit: true,
    }),
  });
  if (!r.ok) throw new Error("swap build failed (" + r.status + ")");
  const { swapTransaction } = await r.json();
  const tx = VersionedTransaction.deserialize(
    Uint8Array.from(atob(swapTransaction), (c) => c.charCodeAt(0))
  );
  const sent = await provider.signAndSendTransaction(tx);
  return { signature: sent?.signature || sent };
}

/// STEP 2 — the delegate. One mint, one amount, revocable. This is the ONLY
/// authority the keeper ever receives, and the user grants it explicitly.
export async function signDelegate({ mint, amount, keeper }) {
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, TOKEN_PROGRAM_ID);
  const ix = createApproveInstruction(ata, new PublicKey(keeper), pubkey, BigInt(amount), [], TOKEN_PROGRAM_ID);
  const { blockhash } = await conn.getLatestBlockhash();
  const tx = new VersionedTransaction(
    new TransactionMessage({ payerKey: pubkey, recentBlockhash: blockhash, instructions: [ix] })
      .compileToV0Message()
  );
  const sent = await provider.signAndSendTransaction(tx);
  return { signature: sent?.signature || sent, ata: ata.toBase58() };
}

/// The kill switch. No keeper cooperation required, ever.
export async function signRevoke({ mint }) {
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, TOKEN_PROGRAM_ID);
  const ix = createRevokeInstruction(ata, pubkey, [], TOKEN_PROGRAM_ID);
  const { blockhash } = await conn.getLatestBlockhash();
  const tx = new VersionedTransaction(
    new TransactionMessage({ payerKey: pubkey, recentBlockhash: blockhash, instructions: [ix] })
      .compileToV0Message()
  );
  const sent = await provider.signAndSendTransaction(tx);
  return { signature: sent?.signature || sent };
}

/// Read the grant back FROM THE CHAIN so the console shows what is actually
/// true, never what it remembers having asked for.
export async function readDelegate({ mint }) {
  try {
    const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, TOKEN_PROGRAM_ID);
    const acc = await getAccount(conn, ata);
    return {
      exists: true, balance: acc.amount.toString(),
      delegate: acc.delegate ? acc.delegate.toBase58() : null,
      delegatedAmount: acc.delegatedAmount.toString(),
    };
  } catch {
    return { exists: false, balance: "0", delegate: null, delegatedAmount: "0" };
  }
}

/// The mint's own decimals, read from the chain. Cached per mint: it is an
/// immutable property of the token, so re-reading it on every tap would be a
/// pointless RPC round trip in the middle of a buy.
const _decCache = new Map();
export async function mintDecimals(mint) {
  const k = String(mint);
  if (_decCache.has(k)) return _decCache.get(k);
  const info = await getMint(conn, new PublicKey(k));
  _decCache.set(k, info.decimals);
  return info.decimals;
}

/* ─────────────────────── the rule the keeper reads ─────────────────────── */

const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58-encode a signature. Written out rather than importing another CDN
/// module for fifteen lines — this mirrors the hand-rolled decoder the worker
/// uses to verify it, so both ends of the signature are auditable in one read.
function b58encode(bytes) {
  // NOT seeded with [0]: a zero seed emits a spurious extra '1' for any input
  // whose value is zero, so a leading-zero byte would encode as "11".
  const digits = [];
  for (const byte of bytes) {
    let carry = byte;
    for (let i = 0; i < digits.length; i++) {
      carry += digits[i] << 8;
      digits[i] = carry % 58;
      carry = (carry / 58) | 0;
    }
    while (carry > 0) { digits.push(carry % 58); carry = (carry / 58) | 0; }
  }
  let out = "";
  for (let k = 0; k < bytes.length && bytes[k] === 0; k++) out += "1";  // leading zeros
  for (let i = digits.length - 1; i >= 0; i--) out += B58_ALPHABET[digits[i]];
  return out;
}

/// The exact bytes the wallet signs. MUST match deskRulePreimage() in
/// worker/index.ts byte for byte — the worker recomputes this and verifies the
/// signature against it, so any drift here is a silent 401 rather than a bug
/// that shows up in testing. Field order is fixed; every value is stringified
/// explicitly.
function rulePreimage({ owner, mint, decimals, entryPrice, targetBps, stopBps, nonce }) {
  return new TextEncoder().encode(
    "possessio.desk.rule.v1\n" +
    `owner:${owner}\n` +
    `mint:${mint}\n` +
    `decimals:${decimals}\n` +
    `entryPrice:${entryPrice}\n` +
    `targetBps:${targetBps}\n` +
    `stopBps:${stopBps}\n` +
    `nonce:${nonce}`
  );
}

/// Record the human's instruction where the keeper can read it.
///
/// This is the signature that actually matters. The buy makes them an owner;
/// the delegate makes an exit possible; THIS is where they say what the exit
/// should be — sell at +25%, or at -10%, whichever comes first. Signing it is
/// not friction bolted onto the flow, it is the consent moment: without a
/// signature anyone could write a rule against a wallet that has granted a
/// delegate, set the target to zero, and have the keeper dump the position on
/// command.
export async function signRule({ mint, decimals, entryPrice, targetBps, stopBps = 1000 }) {
  if (!provider) throw new Error("no Solana provider");
  const owner = pubkey.toBase58();
  const nonce = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const msg = rulePreimage({ owner, mint, decimals, entryPrice, targetBps, stopBps, nonce });

  const res = await provider.signMessage(msg, "utf8");
  const raw = res?.signature || res;
  const signature = typeof raw === "string" ? raw : b58encode(raw);

  const r = await fetch("/api/desk/rules", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ owner, mint, decimals, entryPrice, targetBps, stopBps, nonce, signature }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => ({}));
    throw new Error(err.error || `rule rejected (${r.status})`);
  }
  return r.json();
}

/// The whole SOL pick, in the order the user experiences it. Each step reports
/// through `onStep` so the sheet can narrate honestly — including the case
/// where the buy lands and the delegate is declined, which leaves the user
/// holding a position with NO automated exit. That state is real and the UI
/// must say so rather than pretend the trade is armed.
export async function buyAndDelegate({
  mint, usdcAmount, keeper, slippageBps = 300, targetBps, onStep = () => {},
}) {
  onStep({ step: "quote", text: "finding a route…" });
  const q = await quoteBuy({ mint, usdcAmount, slippageBps });

  onStep({ step: "buy", text: `buy ${usdcAmount} USDC via ${q.route}`, quote: q });
  const buy = await signBuy({ quoteResponse: q.quote });

  // The price they ACTUALLY got, derived from the fill, not the screen price
  // they tapped. Target and stop are measured from this — quoting one number
  // and arming the stop off another is how a -10% stop silently becomes -14%.
  //
  // Decimals come from the MINT, never from the caller. The desk's coin rows
  // carry no decimals field, so accepting one would mean defaulting to 9 and
  // mis-scaling the entry price by orders of magnitude for every 5- or 6-dec
  // memecoin — arming a stop against a number that was never real.
  const dec = await mintDecimals(mint);
  const entryPrice = usdcAmount / (Number(q.outAmount) / 10 ** dec);

  onStep({ step: "delegate", text: "authorize the desk to fire your stop", bought: q.outAmount });
  let del;
  try {
    del = await signDelegate({ mint, amount: q.outAmount, keeper });
  } catch (e) {
    return {
      ok: true, armed: false, buy, bought: q.outAmount, entryPrice,
      warning: "You hold the coin, but the desk cannot exit it: the stop is NOT armed. " +
               "Grant the delegate, or sell it yourself.",
      error: String(e?.message || e),
    };
  }

  // The delegate is POWER; the rule is INSTRUCTION. Power without instruction
  // is inert — the keeper iterates rules, so a grant it can never match is
  // never even looked at. That is safe, but it is not armed, and the user is
  // owed the difference in plain words.
  onStep({ step: "rule", text: "sign your exit rule", bought: q.outAmount });
  try {
    const rule = await signRule({ mint, decimals: dec, entryPrice, targetBps });
    return { ok: true, armed: true, buy, delegate: del, rule, bought: q.outAmount, entryPrice };
  } catch (e) {
    return {
      ok: true, armed: false, buy, delegate: del, bought: q.outAmount, entryPrice,
      warning: "You hold the coin and the desk has permission — but your exit rule was not " +
               "recorded, so nothing will fire. Set the target again, or sell it yourself.",
      error: String(e?.message || e),
    };
  }
}
