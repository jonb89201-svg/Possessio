// MODEL B — the self-custody Solana leg.
//
// The user never hands their capital to anyone. In a Farcaster mini app the
// user HAS a Solana wallet (Wallet Standard, via @farcaster/mini-app-solana),
// so the buy is signed by them, from their own account, and the coin lands in
// their own token account.
//
// The exit is the hard part: a -10% stop is worthless if it needs the human
// awake at 3am. So the user grants a BOUNDED, REVOCABLE SPL DELEGATE over
// exactly the position they just bought. That is the same shape as an ERC-20
// approve, and every crypto user already understands it:
//
//     custody  : stays with the user, always
//     authority: the keeper may move AT MOST the delegated amount, of ONE mint
//     duration : until the user revokes, or the delegate is spent
//     blast radius: that one position. Nothing else in the wallet is reachable.
//
// Compare Model A (an agent holding a float): there the user's capital sits in
// someone else's wallet between draw and settle. Here it never leaves theirs.
//
// This module is framework-agnostic on purpose — it builds transactions and
// returns them. The mini app supplies `sendTransaction` from
// `useSolanaWallet()`; the simulator supplies a dry-run sender. Neither is
// baked in, so the exact same code path is what gets simulated and what ships.
"use strict";

const {
  PublicKey, Transaction, VersionedTransaction, TransactionMessage,
} = require("@solana/web3.js");
const {
  createApproveInstruction, createRevokeInstruction,
  getAssociatedTokenAddress, TOKEN_PROGRAM_ID,
} = require("@solana/spl-token");

const USDC_MINT = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const JUP = process.env.JUPITER_BASE || "https://lite-api.jup.ag/swap/v1";

/* ────────────────────────────── quoting ────────────────────────────── */

async function quote({ inputMint, outputMint, amount, slippageBps = 300 }) {
  const u = new URL(JUP + "/quote");
  u.searchParams.set("inputMint", inputMint);
  u.searchParams.set("outputMint", outputMint);
  u.searchParams.set("amount", String(amount));
  u.searchParams.set("slippageBps", String(slippageBps));
  const r = await fetch(u, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error(`jupiter quote ${r.status}`);
  const j = await r.json();
  // `!j.outAmount` was written to mean "no route", and it does not catch the
  // case it most needs to: "0" is a TRUTHY string, so a zero-output quote
  // sails through as a valid route. Downstream that becomes price 0, and a
  // price of 0 satisfies `price <= stop` for ANY stop — including the
  // no-stop sentinel, whose stop price is 0. A dead route would fire a
  // "stop" sale into a market with no liquidity.
  //
  // NULL MEANS UNKNOWN, NEVER PASS. An unquotable route is unknown, so it
  // refuses rather than reporting a price of zero.
  const out = Number(j.outAmount);
  if (!Number.isFinite(out) || out <= 0) throw new Error("no route (zero or unreadable output)");
  return j;
}

/// Build the BUY the USER signs. `userPublicKey` is the user's own wallet, so
/// the bought coin is delivered to the user's own associated token account.
async function buildUserBuy({ userPublicKey, mint, usdcAmount, slippageBps = 300 }) {
  const q = await quote({
    inputMint: USDC_MINT.toBase58(), outputMint: mint,
    amount: usdcAmount, slippageBps,
  });
  const r = await fetch(JUP + "/swap", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      quoteResponse: q, userPublicKey, wrapAndUnwrapSol: true,
      dynamicComputeUnitLimit: true,
    }),
  });
  if (!r.ok) throw new Error(`jupiter swap-build ${r.status}`);
  const j = await r.json();
  return { unsignedTxBase64: j.swapTransaction, quote: q, expectedOut: q.outAmount };
}

/* ─────────────────────── the bounded delegate ─────────────────────── */

/// The user's ONE extra signature: "the keeper may sell up to `amount` of THIS
/// coin on my behalf." Revocable at any moment by `buildRevoke`.
///
/// `amount` should be the position size, not a blanket maximum — a delegate
/// larger than the position is authority the trade never needs.
async function buildDelegateApproval({ connection, userPublicKey, mint, amount, keeper }) {
  const owner = new PublicKey(userPublicKey);
  const mintPk = new PublicKey(mint);
  const ata = await getAssociatedTokenAddress(mintPk, owner, false, TOKEN_PROGRAM_ID);
  const ix = createApproveInstruction(
    ata, new PublicKey(keeper), owner, BigInt(amount), [], TOKEN_PROGRAM_ID
  );
  const { blockhash } = await connection.getLatestBlockhash();
  const msg = new TransactionMessage({
    payerKey: owner, recentBlockhash: blockhash, instructions: [ix],
  }).compileToV0Message();
  return { tx: new VersionedTransaction(msg), ata: ata.toBase58(), delegatedAmount: String(amount) };
}

/// The user's kill switch. One instruction, no keeper cooperation required.
async function buildRevoke({ connection, userPublicKey, mint }) {
  const owner = new PublicKey(userPublicKey);
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), owner, false, TOKEN_PROGRAM_ID);
  const ix = createRevokeInstruction(ata, owner, [], TOKEN_PROGRAM_ID);
  const { blockhash } = await connection.getLatestBlockhash();
  const msg = new TransactionMessage({
    payerKey: owner, recentBlockhash: blockhash, instructions: [ix],
  }).compileToV0Message();
  return { tx: new VersionedTransaction(msg), ata: ata.toBase58() };
}

/// What the delegate actually is, read from the chain rather than remembered.
/// The console shows this so a user can always see exactly what they granted.
async function readDelegate({ connection, userPublicKey, mint }) {
  const { getAccount } = require("@solana/spl-token");
  const owner = new PublicKey(userPublicKey);
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), owner, false, TOKEN_PROGRAM_ID);
  try {
    const acc = await getAccount(connection, ata);
    return {
      exists: true,
      balance: acc.amount.toString(),
      delegate: acc.delegate ? acc.delegate.toBase58() : null,
      delegatedAmount: acc.delegatedAmount.toString(),
      ata: ata.toBase58(),
    };
  } catch {
    return { exists: false, balance: "0", delegate: null, delegatedAmount: "0", ata: ata.toBase58() };
  }
}

/* ───────────────────────── the delegated exit ───────────────────────── */

/// The keeper's exit, built to sell the USER's coin straight back to USDC in
/// the user's own account.
///
/// HONEST BOUND, stated where the code is: a delegate is an allowance, so the
/// keeper can move up to `delegatedAmount` of this one mint. It cannot touch
/// any other asset, and the user can revoke instantly. That is a strictly
/// smaller trust surface than handing the capital to an agent — but it is not
/// zero, and calling it zero would be the kind of claim this project refuses
/// to make.
async function buildDelegatedExit({ keeperPublicKey, userPublicKey, mint, amount, slippageBps = 300 }) {
  const q = await quote({
    inputMint: mint, outputMint: USDC_MINT.toBase58(),
    amount, slippageBps,
  });
  // Jupiter supports a distinct source/destination owner: the token is pulled
  // from the user's account under delegate authority and the USDC is delivered
  // BACK to the user. The keeper only signs and pays the fee — proceeds never
  // route through a keeper-owned account.
  const r = await fetch(JUP + "/swap", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      quoteResponse: q,
      userPublicKey,                 // source of funds: the user
      payer: keeperPublicKey,        // the keeper pays the fee
      destinationTokenAccount: undefined, // default: the user's USDC ATA
      wrapAndUnwrapSol: false,
      dynamicComputeUnitLimit: true,
    }),
  });
  if (!r.ok) throw new Error(`jupiter exit-build ${r.status}`);
  const j = await r.json();
  return { unsignedTxBase64: j.swapTransaction, quote: q, expectedUsdcOut: q.outAmount };
}

module.exports = {
  USDC_MINT, quote, buildUserBuy,
  buildDelegateApproval, buildRevoke, readDelegate, buildDelegatedExit,
};
