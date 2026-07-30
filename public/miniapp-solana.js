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
  getAssociatedTokenAddress, getAccount, TOKEN_PROGRAM_ID,
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

/// The whole SOL pick, in the order the user experiences it. Each step reports
/// through `onStep` so the sheet can narrate honestly — including the case
/// where the buy lands and the delegate is declined, which leaves the user
/// holding a position with NO automated exit. That state is real and the UI
/// must say so rather than pretend the trade is armed.
export async function buyAndDelegate({ mint, usdcAmount, keeper, slippageBps = 300, onStep = () => {} }) {
  onStep({ step: "quote", text: "finding a route…" });
  const q = await quoteBuy({ mint, usdcAmount, slippageBps });

  onStep({ step: "buy", text: `buy ${usdcAmount} USDC via ${q.route}`, quote: q });
  const buy = await signBuy({ quoteResponse: q.quote });

  onStep({ step: "delegate", text: "authorize the desk to fire your stop", bought: q.outAmount });
  try {
    const del = await signDelegate({ mint, amount: q.outAmount, keeper });
    return { ok: true, armed: true, buy, delegate: del, bought: q.outAmount };
  } catch (e) {
    return {
      ok: true, armed: false, buy, bought: q.outAmount,
      warning: "You hold the coin, but the desk cannot exit it: the stop is NOT armed. " +
               "Grant the delegate, or sell it yourself.",
      error: String(e?.message || e),
    };
  }
}
