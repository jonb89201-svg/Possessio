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
  getAssociatedTokenAddress, getAccount, getMint, TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID,
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
  let provErr = null;
  try {
    // UNPINNED, to match the import in index.html. This file pinned 0.1.x while
    // the page loaded latest, so the console ran TWO Farcaster SDK versions at
    // once (measured 2026-08-05: 0.1.10 here, 0.3.0 there). Both expose
    // getSolanaProvider, so the pin was not the Solana failure — but two
    // versions of the same SDK in one page is a defect waiting for its turn.
    const mod = await import("https://esm.sh/@farcaster/miniapp-sdk");
    sdk = mod.sdk;
    const inHost = await sdk.isInMiniApp?.().catch(() => false);
    if (!inHost) { sdk = null; return { miniApp: false, reason: "not in a Farcaster host" }; }

    // ASK the host what it supports instead of calling and interpreting the
    // silence. getSolanaProvider is proxied to the Farcaster client; a client
    // that does not offer it answers with nothing, which is byte-identical to a
    // bug on our side. Without this question the app blamed the user's setup
    // for what might be the client's limitation or our own defect — one message
    // for three different causes.
    let caps = null;
    try { caps = await sdk.getCapabilities?.(); } catch (e) { caps = null; }
    const hasSolCap = Array.isArray(caps) ? caps.includes("wallet.getSolanaProvider") : null;

    if (hasSolCap === false) {
      await sdk.actions.ready();
      return {
        miniApp: true, solana: false, caps,
        reason: "this Farcaster client does not offer a Solana wallet to mini apps",
      };
    }

    provider = await sdk.wallet.getSolanaProvider?.().catch((e) => { provErr = e; return null; });
    if (!provider) {
      await sdk.actions.ready();
      return {
        miniApp: true, solana: false, caps,
        reason: provErr
          ? "getSolanaProvider failed: " + String(provErr.message || provErr)
          : (hasSolCap === null
              ? "getSolanaProvider returned nothing, and this client did not answer a capability query"
              : "the client lists Solana support but returned no provider"),
      };
    }

    // TWO PROVIDER SHAPES, because the SDK changed under us.
    //
    // MEASURED 2026-08-05 inside Farcaster: `provider.connect is not a
    // function`. The older SDK returned a phantom-style object with .connect();
    // the current one returns a Wallet Standard wallet, where connecting is
    // features["standard:connect"].connect() and the account comes back in an
    // accounts array. The code assumed the first shape and threw on the second.
    //
    // Both are supported rather than picking one, because the host decides
    // which it hands over and that is not ours to pin. If it is neither, the
    // provider's own keys are reported instead of a guess — the shape is the
    // one fact needed to adapt, and it is free to print.
    let acct = null;
    if (typeof provider.connect === "function") {
      const res = await provider.connect();
      acct = res?.publicKey?.toString?.() || res?.publicKey || provider.publicKey;
    } else if (typeof provider.features?.["standard:connect"]?.connect === "function") {
      const res = await provider.features["standard:connect"].connect();
      const a = res?.accounts?.[0] || provider.accounts?.[0];
      acct = a?.address || a?.publicKey?.toString?.() || a?.publicKey;
    } else if (typeof provider.request === "function") {
      // THE SHAPE FARCASTER ACTUALLY HANDS OVER, measured 2026-08-05 by printing
      // the provider's own keys inside the mini app:
      //
      //   ["request","signMessage","signTransaction","signAndSendTransaction",…]
      //
      // Phantom-like in every method EXCEPT connect, which is reachable only
      // through the JSON-RPC surface. Neither of the two shapes guessed at
      // before this was measured. Worth remembering the next time a provider
      // shape looks obvious: two rounds were spent on shapes that were not
      // there, and one Object.keys() ended it.
      const res = await provider.request({ method: "connect" });
      acct = res?.publicKey?.toString?.() || res?.publicKey
          || provider.publicKey?.toString?.() || provider.publicKey;
    } else {
      await sdk.actions.ready();
      return {
        miniApp: true, solana: false, caps,
        providerKeys: Object.keys(provider || {}),
        providerFeatures: provider?.features ? Object.keys(provider.features) : null,
        reason: "the Solana provider is a shape this app does not know how to connect to",
      };
    }
    if (!acct) {
      await sdk.actions.ready();
      return { miniApp: true, solana: false, caps, reason: "the wallet connected but returned no account" };
    }

    pubkey = new PublicKey(String(acct));
    conn = new Connection(rpcUrl || "https://solana-rpc.publicnode.com", "confirmed");

    await sdk.actions.ready();               // dismiss the splash
    return { miniApp: true, solana: true, caps, address: pubkey.toBase58() };
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

/// SEND A TRANSACTION. ONE SHAPE, ONE ATTEMPT, NO FALLBACK CHAIN.
///
/// THIS FUNCTION USED TO TRY FOUR SHAPES IN SEQUENCE. That was wrong and it is
/// worth recording why, because it looked reasonable and it was the same
/// pattern that had just succeeded on connect().
///
/// connect() is idempotent — calling it four times costs nothing. THIS IS NOT.
/// If a shape opens the wallet prompt, the user approves, and the promise then
/// hangs or returns something unrecognised, moving to the next shape opens a
/// SECOND prompt for a transaction that may already be in flight. A retry loop
/// around a signing call is a double-spend generator. The rule that a failed
/// send must never be silently retried is older than this codebase.
///
/// MEASURED 2026-08-06, inside Farcaster, with the four-shape version: the
/// wallet's "Confirm transaction" sheet DID open — so the provider was reached
/// — but every detail row rendered as an empty skeleton and never filled, and
/// Confirm returned to the buy screen with no signature and no error. The
/// wallet received something it could not decode.
///
/// That points at one thing: a VersionedTransaction is a class instance, and it
/// is being handed across a comlink boundary to the host. Methods and prototype
/// do not survive that trip. What arrives is a shapeless object — which is
/// exactly what an undecodable transaction looks like, and exactly why the
/// preview stayed empty.
///
/// So: serialize HERE, send bytes. base58 over the JSON-RPC surface is the
/// phantom-family convention and this provider is phantom-shaped everywhere
/// else it has been measured.
async function sendTx(tx) {
  let sent;
  try {
    // READ OUT OF THE SDK BUNDLE, 2026-08-06, not inferred:
    //
    //   signAndSendTransaction: t => e({ method:"signAndSendTransaction", params: t })
    //   ...
    //   if (o.method === "signAndSendTransaction") {
    //     let { transaction: c } = o.params;
    //     let l = { transaction: I(c) };            // I(c) = c.serialize(...) -> base64
    //
    // So params.transaction must be the transaction OBJECT and the SDK
    // serializes it itself. Both prior failures are one bug seen twice:
    //   provider.signAndSendTransaction(tx)      -> params = tx, params.transaction undefined
    //   request({params:{ message: b58 }})       -> params.transaction undefined
    // and `I(undefined)` is precisely "Cannot read properties of undefined
    // (reading 'serialize')" — the error text was naming the missing KEY the
    // whole time, and three rounds were spent guessing at encodings instead of
    // reading the twenty lines that define the contract.
    sent = await provider.signAndSendTransaction({ transaction: tx });
  } catch (e) {
    // Surfaced verbatim. A user rejection and a shape mismatch are different
    // events and the caller must be able to tell them apart.
    throw new Error("wallet refused the send: " + String(e?.message || e));
  }
  const sig = sent?.signature || sent?.result?.signature || sent;
  if (typeof sig !== "string" || sig.length < 40) {
    // NOT retried with another shape, deliberately. The transaction may already
    // be on chain; the honest move is to say what came back and stop.
    throw new Error(
      "the wallet returned no signature — it may or may not have sent. " +
      "Check your wallet before retrying. Got: " + JSON.stringify(sent)
    );
  }
  return { signature: sig };
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
  const bytes = Uint8Array.from(atob(swapTransaction), (c) => c.charCodeAt(0));

  // SOLANA'S PACKET LIMIT IS 1232 BYTES, and Jupiter routinely returns more
  // than that for newborn coins.
  //
  // MEASURED 2026-08-06 against live Jupiter, same mint, same parameters,
  // four calls each: 1223, 1356, 1325, 1524 bytes. The route changes call to
  // call as liquidity moves, and for these coins it sits right at the limit and
  // crosses it often — 3 of 4 attempts on one mint, 4 of 4 on another minutes
  // later, then all six under the limit ten minutes after that.
  //
  // An oversized transaction cannot land. web3.js does not say that: its
  // serialize() writes into a fixed PACKET_DATA_SIZE buffer and throws
  // "encoding overruns Uint8Array", which is what reached the Architect's
  // screen and named nothing useful. Worse, when a slightly-oversized one got
  // through to the wallet, the confirm sheet rendered empty skeletons forever —
  // the wallet could not decode it either, and said so by saying nothing.
  //
  // So the size is checked HERE, before web3.js is asked to do the impossible,
  // and the caller is told the one thing that is actionable: try again.
  if (bytes.length > 1232) {
    const e = new Error(
      "no route for this coin fits in one transaction right now (" +
      bytes.length + " bytes, limit 1232)"
    );
    e.code = "TX_TOO_LARGE";
    throw e;
  }

  const tx = VersionedTransaction.deserialize(bytes);
  const sent = await sendTx(tx);
  return { signature: sent.signature };
}

/// WHAT THE SWAP ACTUALLY DELIVERED, from the confirmed transaction.
///
/// Reads the balance deltas the runtime recorded: tokens in, USDC out, both for
/// THIS wallet. That is the receipt — not the quote, not the requested size.
///
/// If the transaction cannot be read back, this THROWS rather than falling back
/// to the quote. A silent fallback would put the user back on estimated numbers
/// at exactly the moment the exact ones were unavailable, and they would have no
/// way to tell which they got. The caller already handles "bought but not
/// armed"; an honest failure there is worth more than a confident wrong price.
async function fillFor({ signature, mint, dec, quotedOut }) {
  const me = pubkey.toBase58();
  const usdc = USDC_MINT.toBase58();
  for (let i = 0; i < 40; i++) {
    const tx = await conn.getParsedTransaction(signature, {
      maxSupportedTransactionVersion: 0, commitment: "confirmed",
    }).catch(() => null);
    if (tx?.meta) {
      if (tx.meta.err) throw new Error("the buy failed on chain: " + JSON.stringify(tx.meta.err));
      const amt = (arr, m) => {
        const row = (arr || []).find((b) => b.mint === m && b.owner === me);
        return BigInt(row?.uiTokenAmount?.amount ?? "0");
      };
      const tokens = amt(tx.meta.postTokenBalances, String(mint)) - amt(tx.meta.preTokenBalances, String(mint));
      const usdcDelta = amt(tx.meta.preTokenBalances, usdc) - amt(tx.meta.postTokenBalances, usdc);
      if (tokens <= 0n) throw new Error("the buy landed but delivered no tokens to this wallet");
      if (usdcDelta <= 0n) throw new Error("the buy landed but spent no USDC from this wallet");
      return {
        tokens: tokens.toString(),
        usdcSpent: Number(usdcDelta) / 1e6,
        // How far the receipt landed from the estimate. Surfaced so the sheet
        // can show it rather than quietly absorbing it.
        slippagePct: quotedOut ? (Number(tokens) - Number(quotedOut)) / Number(quotedOut) * 100 : null,
      };
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("bought, but the fill could not be read back — refusing to arm off an estimated price");
}

/* ───────────────── WHICH TOKEN PROGRAM — read, never assumed ───────────────── */

/// Every token call below needs the mint's owning program, because the ATA is
/// derived FROM it and the instructions are addressed TO it.
///
/// This file hardcoded the classic SPL program in six places. Measured against
/// the live radar feed on 2026-08-01: 25 of 25 picks are Token-2022. pump.fun
/// mints Token-2022 now, so every one of those six was wrong for every coin the
/// desk can currently offer — the delegate grant, the revoke, the read-back and
/// the decimals lookup all addressed a program that does not own the mint.
///
/// The decimals lookup was the dangerous one. getMint() defaults to the classic
/// program and THROWS for a Token-2022 mint, and buyAndDelegate calls it AFTER
/// the buy has executed — so the user paid for the coin and the function
/// exploded before reaching the try/catch blocks written to handle exactly the
/// "bought but not armed" state. Money spent, nothing armed, no handler run.
///
/// Cached per mint: the owning program is immutable, so this costs one RPC read
/// per coin rather than one per call.
const _progCache = new Map();
async function tokenProgramFor(mint) {
  const k = String(mint);
  if (_progCache.has(k)) return _progCache.get(k);
  const info = await conn.getAccountInfo(new PublicKey(k));
  if (!info) throw new Error("mint not found on chain: " + k);
  if (!info.owner.equals(TOKEN_PROGRAM_ID) && !info.owner.equals(TOKEN_2022_PROGRAM_ID))
    throw new Error("not a token mint: " + k);
  _progCache.set(k, info.owner);
  return info.owner;
}

/// STEP 2 — the delegate. One mint, one amount, revocable. This is the ONLY
/// authority the keeper ever receives, and the user grants it explicitly.
export async function signDelegate({ mint, amount, keeper }) {
  const prog = await tokenProgramFor(mint);
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, prog);
  const ix = createApproveInstruction(ata, new PublicKey(keeper), pubkey, BigInt(amount), [], prog);
  const { blockhash } = await conn.getLatestBlockhash();
  const tx = new VersionedTransaction(
    new TransactionMessage({ payerKey: pubkey, recentBlockhash: blockhash, instructions: [ix] })
      .compileToV0Message()
  );
  const sent = await sendTx(tx);
  return { signature: sent.signature, ata: ata.toBase58() };
}

/// The kill switch. No keeper cooperation required, ever.
export async function signRevoke({ mint }) {
  const prog = await tokenProgramFor(mint);
  const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, prog);
  const ix = createRevokeInstruction(ata, pubkey, [], prog);
  const { blockhash } = await conn.getLatestBlockhash();
  const tx = new VersionedTransaction(
    new TransactionMessage({ payerKey: pubkey, recentBlockhash: blockhash, instructions: [ix] })
      .compileToV0Message()
  );
  const sent = await sendTx(tx);
  return { signature: sent.signature };
}

/// Read the grant back FROM THE CHAIN so the console shows what is actually
/// true, never what it remembers having asked for.
export async function readDelegate({ mint }) {
  try {
    const prog = await tokenProgramFor(mint);
    const ata = await getAssociatedTokenAddress(new PublicKey(mint), pubkey, false, prog);
    const acc = await getAccount(conn, ata, undefined, prog);
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
  const prog = await tokenProgramFor(k);
  const info = await getMint(conn, new PublicKey(k), undefined, prog);
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
function rulePreimage({ owner, mint, decimals, entryPrice, targetBps, hasStop, stopBps, nonce }) {
  // THE STOP IS STATED POSITIVELY, NEVER INFERRED FROM A MISSING FIELD.
  //
  // Architect ratification 2026-08-01: "no stop" is an absence, not a value.
  // Zero was rejected because zero is the uninitialised value of every integer
  // on this path, so zero-meaning-anything is fail-open. The same reasoning
  // applies one level up: MISSING is the uninitialised state of an object
  // field. If the preimage simply omitted the line, a forgotten stopBps would
  // produce a valid signature over a rule with no stop — the identical trap,
  // moved from the value to the key.
  //
  // So hasStop is always present and always explicit. A rule that fails to say
  // cannot be signed at all, because `undefined` is not a boolean and the
  // worker rejects it before verification.
  const stopLines = hasStop === true
    ? `hasStop:true\nstopBps:${stopBps}\n`
    : `hasStop:false\n`;
  return new TextEncoder().encode(
    "possessio.desk.rule.v1\n" +
    `owner:${owner}\n` +
    `mint:${mint}\n` +
    `decimals:${decimals}\n` +
    `entryPrice:${entryPrice}\n` +
    `targetBps:${targetBps}\n` +
    stopLines +
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
export async function signRule({ mint, decimals, entryPrice, targetBps, hasStop = false, stopBps = null }) {
  // DEFAULTS TO NO STOP, and that is the product, not a shortcut: the Architect
  // abolished the automatic stop on 2026-08-01 because the mechanism never
  // supported the claim. Downside is a manual Force Sell. This used to default
  // to 1000, which would now sign a stop the console tells the user does not
  // exist.
  if (!provider) throw new Error("no Solana provider");
  const owner = pubkey.toBase58();
  const nonce = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const msg = rulePreimage({ owner, mint, decimals, entryPrice, targetBps, hasStop, stopBps, nonce });

  const res = await provider.signMessage(msg, "utf8");
  const raw = res?.signature || res;
  const signature = typeof raw === "string" ? raw : b58encode(raw);

  const r = await fetch("/api/desk/rules", {
    method: "POST",
    headers: { "content-type": "application/json" },
    // hasStop is sent explicitly and stopBps only when there IS one — a
    // contradiction between the two is refused by the worker rather than
    // resolved in its favour.
    body: JSON.stringify({ owner, mint, decimals, entryPrice, targetBps, hasStop,
                           ...(hasStop ? { stopBps } : {}), nonce, signature }),
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
  // RE-QUOTE ON AN OVERSIZED ROUTE, up to three times.
  //
  // This is a retry around QUOTING, not around sending. Nothing has been signed
  // at this point and no transaction exists, so re-running it cannot double
  // anything — the opposite of the send-retry removed earlier today, and the
  // distinction is the whole reason this is safe to do here and was not there.
  //
  // Three attempts because the route is re-chosen each call and the measured
  // hit rate was between 1-in-4 and 4-in-4 depending on the minute. Three is
  // enough to clear a transient bad route and few enough that a coin with no
  // viable route fails quickly instead of hanging on the sheet.
  let q = null, buy = null, lastTooLarge = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    onStep({ step: "quote", text: attempt === 1 ? "finding a route…" : "route too large, retrying…" });
    q = await quoteBuy({ mint, usdcAmount, slippageBps });
    onStep({ step: "buy", text: `buy ${usdcAmount} USDC via ${q.route}`, quote: q });
    try {
      buy = await signBuy({ quoteResponse: q.quote });
      break;
    } catch (e) {
      if (e && e.code === "TX_TOO_LARGE" && attempt < 3) { lastTooLarge = e; continue; }
      throw e;
    }
  }
  if (!buy) throw (lastTooLarge || new Error("could not build a sendable route for this coin"));

  // THE SIGNING BASIS IS THE FILL — Architect-ratified 2026-08-01.
  //
  // This read `q.outAmount`, the QUOTE. A quote is an estimate: the swap is
  // sent with slippageBps tolerance (300 by default), so the receipt can be 3%
  // below it and the entry price — and therefore the target the user signs —
  // was wrong by that much. Quoting one number and arming off another is the
  // same class of error as arming a stop off a different price than the fill.
  //
  // The fill is on-chain, exact, and already denominated in the units
  // minimumAmountOut enforces. No feed, no oracle, no assumed supply, and
  // nothing that can drift between what the user saw and what they signed.
  // (The feed cannot serve this: only 3 of 66 radar rows carry a price at all,
  // and its market cap is computed from an assumed supply that disagrees with
  // the chain — measured 2026-08-01.)
  //
  // Decimals come from the MINT, never from the caller. The desk's coin rows
  // carry no decimals field, so accepting one would mean defaulting to 9 and
  // mis-scaling the entry price by orders of magnitude for every 5- or 6-dec
  // memecoin — arming against a number that was never real.
  const dec = await mintDecimals(mint);
  const fill = await fillFor({ signature: buy.signature, mint, dec, quotedOut: q.outAmount });
  const entryPrice = fill.usdcSpent / (Number(fill.tokens) / 10 ** dec);

  // The delegate covers what the user ACTUALLY holds. Granting the quoted
  // amount over-grants on negative slippage and, worse, UNDER-grants on
  // positive slippage — leaving a tail the keeper cannot sell.
  onStep({ step: "delegate", text: "authorize the desk to fire your exit", bought: fill.tokens });
  let del;
  try {
    del = await signDelegate({ mint, amount: fill.tokens, keeper });
  } catch (e) {
    return {
      ok: true, armed: false, buy, bought: fill.tokens, entryPrice, fill,
      warning: "You hold the coin, but the desk cannot exit it: the stop is NOT armed. " +
               "Grant the delegate, or sell it yourself.",
      error: String(e?.message || e),
    };
  }

  // The delegate is POWER; the rule is INSTRUCTION. Power without instruction
  // is inert — the keeper iterates rules, so a grant it can never match is
  // never even looked at. That is safe, but it is not armed, and the user is
  // owed the difference in plain words.
  onStep({ step: "rule", text: "sign your exit rule", bought: fill.tokens });
  try {
    const rule = await signRule({ mint, decimals: dec, entryPrice, targetBps });
    return { ok: true, armed: true, buy, delegate: del, rule, bought: fill.tokens, entryPrice, fill };
  } catch (e) {
    return {
      ok: true, armed: false, buy, delegate: del, bought: fill.tokens, entryPrice, fill,
      warning: "You hold the coin and the desk has permission — but your exit rule was not " +
               "recorded, so nothing will fire. Set the target again, or sell it yourself.",
      error: String(e?.message || e),
    };
  }
}
