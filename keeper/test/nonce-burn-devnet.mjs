// DEVNET MEASUREMENT — does a FAILED durable-nonce transaction still burn the
// nonce, and does that kill the user's pre-signed exit?
//
// WHY THIS EXISTS. The durable-nonce design lets a user pre-sign an exit that
// stays valid indefinitely, so the keeper holds a signature instead of a
// spending delegate. Assay found a line in Solana's documentation that, if
// true, is the mechanism's central hazard: a nonce transaction that passes
// validation but FAILS execution still advances the nonce and still pays the
// fee. If that holds, a keeper can DESTROY a user's pre-signed exit simply by
// broadcasting it early — the swap reverts on slippage, but instruction 0 has
// already rolled the nonce forward, and every signature against the old nonce
// is void.
//
// Documented is not measured. Under the Prime Directive a hazard we have only
// read about does not exist yet. This measures it.
//
// HOW IT MEASURES IT — a CONTROLLED experiment, two identical nonce accounts:
//
//   CONTROL   nonce A: pre-sign an exit, broadcast it. It must LAND.
//             This proves the payload is good on its own merits, so that a
//             later failure cannot be blamed on the payload.
//   TREATMENT nonce B: pre-sign the SAME exit, then have the "keeper" burn the
//             nonce with a failing transaction, THEN broadcast the exit.
//
// The only difference between the two arms is the burn. Anything that differs
// in the outcome is caused by the burn, and nothing else.
//
// Two instruments were rejected while writing this, both for the same reason —
// they answered a question other than the one asked:
//   - simulateTransaction() REPLACES the transaction's blockhash with a fresh
//     one, so it can never observe a stale nonce. It reports on a transaction
//     that does not exist.
//   - A transfer of 1000 lamports to a new account fails rent-exemption, so an
//     "exit that would have succeeded" would in fact have failed anyway. The
//     control arm exists precisely to make that class of mistake impossible to
//     ship: an arm that fails on its own is a broken instrument, not a finding.
//
// DEVNET ONLY. Generates throwaway keypairs, airdrops worthless SOL, and never
// reads a real key. Nothing in this file can move value.
//
// RUN:
//   node keeper/test/nonce-burn-devnet.mjs
//
// If the faucet refuses (its rate limit is per egress IP, and shared
// containers are often exhausted), fund the printed payer by hand and re-run
// with the keypair supplied:
//   PAYER_SECRET='[12,34,...]' node keeper/test/nonce-burn-devnet.mjs

import {
  Connection, Keypair, SystemProgram, Transaction,
  NONCE_ACCOUNT_LENGTH, LAMPORTS_PER_SOL, sendAndConfirmTransaction,
} from "@solana/web3.js";
import { readFileSync, writeFileSync } from "node:fs";

const RPC = process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com";
const conn = new Connection(RPC, "confirmed");

// A supplied payer is the escape hatch for a rate-limited faucet; without one
// we mint a throwaway. Either way the nonce accounts are always fresh, so this
// can never touch a nonce some other pre-signed transaction depends on.
// Reusing a payer across runs matters more than it looks: the devnet faucet
// rate-limits per egress IP, so a script that mints a fresh payer every run
// exhausts the faucet and then reports "no result" for a reason that has
// nothing to do with the question. The cached keypair is a throwaway holding
// worthless devnet SOL; it is written outside the repo and never committed.
const CACHE = process.env.PAYER_CACHE
  || `${process.env.TMPDIR || "/tmp"}/possessio-devnet-burn-payer.json`;
function loadPayer() {
  if (process.env.PAYER_SECRET) {
    return { kp: Keypair.fromSecretKey(Uint8Array.from(JSON.parse(process.env.PAYER_SECRET))), from: "supplied" };
  }
  try {
    const raw = JSON.parse(readFileSync(CACHE, "utf8"));
    return { kp: Keypair.fromSecretKey(Uint8Array.from(raw)), from: "cached" };
  } catch { /* first run, or an unreadable cache — mint a fresh one */ }
  const kp = Keypair.generate();
  try { writeFileSync(CACHE, JSON.stringify([...kp.secretKey])); } catch { /* cache is an optimisation, not a requirement */ }
  return { kp, from: "generated" };
}
const { kp: payer, from: payerFrom } = loadPayer();

const line = (s = "") => console.log(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

line("DEVNET NONCE-BURN MEASUREMENT — controlled, throwaway keys, worthless SOL");
line(`  rpc    ${RPC}`);
line(`  payer  ${payer.publicKey.toBase58()}${` (${payerFrom})`}`);
line();

/* ─────────────────────────────── helpers ─────────────────────────────── */

const nonceRent = await conn.getMinimumBalanceForRentExemption(NONCE_ACCOUNT_LENGTH);
// The exit's destination is a fresh account, so the amount must clear
// rent-exemption or the transfer fails for a reason that has nothing to do
// with nonces. This is the defect the control arm was added to catch.
const emptyRent = await conn.getMinimumBalanceForRentExemption(0);

/// A fresh, initialized nonce account, and the nonce it currently stores.
async function newNonce(tag) {
  const kp = Keypair.generate();
  await sendAndConfirmTransaction(
    conn,
    new Transaction().add(
      SystemProgram.createAccount({
        fromPubkey: payer.publicKey, newAccountPubkey: kp.publicKey,
        lamports: nonceRent, space: NONCE_ACCOUNT_LENGTH,
        programId: SystemProgram.programId,
      }),
      SystemProgram.nonceInitialize({
        noncePubkey: kp.publicKey, authorizedPubkey: payer.publicKey,
      }),
    ),
    [payer, kp],
    { commitment: "confirmed" },
  );
  const nonce = (await conn.getNonce(kp.publicKey)).nonce;
  line(`   ${tag}: ${kp.publicKey.toBase58()}  nonce ${nonce}`);
  return { kp, nonce };
}

/// The user's exit, pre-signed against a nonce: advance at index 0, then the
/// real work. A rent-exempt transfer stands in for the swap — it succeeds on
/// its own merits, which is the whole point of the control arm.
function presignExit(noncePubkey, nonce) {
  const tx = new Transaction();
  tx.add(SystemProgram.nonceAdvance({ noncePubkey, authorizedPubkey: payer.publicKey }));
  tx.add(SystemProgram.transfer({
    fromPubkey: payer.publicKey,
    toPubkey: Keypair.generate().publicKey,
    lamports: emptyRent,
  }));
  tx.recentBlockhash = nonce;            // the DURABLE NONCE, not a recent blockhash
  tx.feePayer = payer.publicKey;
  tx.sign(payer);
  return tx.serialize();                 // frozen bytes — nothing downstream can mutate them
}

/// Broadcast raw bytes and report what actually happened. Preflight is left ON
/// so the runtime NAMES its objection rather than dropping the transaction in
/// silence; a rejection reason has to be measured, not inferred from absence.
async function broadcast(raw, { label }) {
  let sig;
  try {
    sig = await conn.sendRawTransaction(raw, { preflightCommitment: "confirmed" });
  } catch (e) {
    // Keep the WHOLE message. web3.js puts the headline ("Simulation failed.")
    // on line one and the actual cause ("Blockhash not found") on a later
    // line; taking only the first line reports that something went wrong
    // while discarding what.
    const cause = e?.transactionMessage || String(e.message).replace(/\s+/g, " ").trim();
    return { landed: false, reason: `rejected at preflight — ${cause.slice(0, 220)}` };
  }
  for (let i = 0; i < 45; i++) {
    const v = (await conn.getSignatureStatus(sig, { searchTransactionHistory: true }))?.value;
    if (v && (v.confirmationStatus === "confirmed" || v.confirmationStatus === "finalized")) {
      return v.err
        ? { landed: false, reason: `executed and FAILED — ${JSON.stringify(v.err)}`, sig }
        : { landed: true, reason: "landed and succeeded", sig };
    }
    await sleep(1000);
  }
  return { landed: false, reason: "accepted but never confirmed (dropped)", sig };
}

/* ────────────────────────────── 1. fund ─────────────────────────────── */

line("1. funding the payer…");
// Two nonce accounts, two exits, and fees for ~7 transactions, with slack.
const NEEDED = 2 * nonceRent + 2 * emptyRent + 0.01 * LAMPORTS_PER_SOL;
if ((await conn.getBalance(payer.publicKey)) < NEEDED) {
  let funded = false;
  for (const sol of [0.1, 0.05, 1]) {
    try {
      const sig = await conn.requestAirdrop(payer.publicKey, sol * LAMPORTS_PER_SOL);
      await conn.confirmTransaction(
        { signature: sig, ...(await conn.getLatestBlockhash()) }, "confirmed");
      funded = true;
      break;
    } catch (e) {
      line(`   ${sol} SOL refused: ${String(e.message).split("\n")[0].slice(0, 70)}`);
    }
  }
  if (!funded) {
    line(`\n   FAUCET REFUSED — this egress IP is rate-limited, which says nothing`);
    line(`   about the question being measured. Send ~${(NEEDED / LAMPORTS_PER_SOL).toFixed(3)} devnet SOL to the`);
    line(`   payer above, then re-run with that keypair:`);
    line(`     PAYER_SECRET='[...]' node keeper/test/nonce-burn-devnet.mjs`);
    process.exit(1);
  }
}
line(`   balance ${(await conn.getBalance(payer.publicKey)) / LAMPORTS_PER_SOL} SOL`);
line(`   nonce rent ${nonceRent} lamports each; exit amount ${emptyRent} lamports (rent-exempt)`);
line();

/* ───────────────────────── 2. CONTROL ARM ───────────────────────────── */

line("2. CONTROL — pre-sign an exit against nonce A and broadcast it untouched.");
line("   If this does not land, the instrument is broken and nothing else means anything.");
const A = await newNonce("nonce A");
const exitA = presignExit(A.kp.publicKey, A.nonce);
const resA = await broadcast(exitA, { label: "control exit" });
line(`   → ${resA.landed ? "LANDED" : "FAILED"} — ${resA.reason}`);
if (!resA.landed) {
  line("\n   CONTROL ARM FAILED. The pre-signed exit does not work even without a");
  line("   burn, so the treatment arm cannot attribute anything to the burn.");
  line("   ABORTING rather than reporting a finding this cannot support.");
  process.exit(1);
}
line();

/* ──────────────────────── 3. TREATMENT ARM ──────────────────────────── */

line("3. TREATMENT — same exit against nonce B, but the keeper burns the nonce first.");
const B = await newNonce("nonce B");
const exitB = presignExit(B.kp.publicKey, B.nonce);   // byte-identical in shape to exitA
line(`   user's exit pre-signed and handed to the keeper (${exitB.length} bytes)`);
line();

line("   3a. the keeper broadcasts early; the payload fails (stands in for a slippage revert)…");
const doomed = new Transaction();
doomed.add(SystemProgram.nonceAdvance({
  noncePubkey: B.kp.publicKey, authorizedPubkey: payer.publicKey,
}));
doomed.add(SystemProgram.transfer({
  fromPubkey: payer.publicKey,
  toPubkey: Keypair.generate().publicKey,
  lamports: (await conn.getBalance(payer.publicKey)) * 100,   // guaranteed to fail
}));
doomed.recentBlockhash = B.nonce;
doomed.feePayer = payer.publicKey;
doomed.sign(payer);

const balBefore = await conn.getBalance(payer.publicKey);
// skipPreflight is essential HERE and only here: preflight would reject this
// locally, so it would never reach a validator — and never reaching a
// validator is precisely the thing not being measured.
const doomedSig = await conn.sendRawTransaction(doomed.serialize(), { skipPreflight: true });
let doomedErr = "(never confirmed)";
for (let i = 0; i < 45; i++) {
  const v = (await conn.getSignatureStatus(doomedSig, { searchTransactionHistory: true }))?.value;
  if (v && (v.confirmationStatus === "confirmed" || v.confirmationStatus === "finalized")) {
    doomedErr = JSON.stringify(v.err); break;
  }
  await sleep(1000);
}
line(`       sent ${doomedSig}`);
line(`       execution error: ${doomedErr}`);
if (doomedErr === "null") {
  line("\n       The doomed payload SUCCEEDED. The failure branch never ran and");
  line("       nothing was measured. ABORTING.");
  process.exit(1);
}
line();

line("   3b. did the nonce advance despite the failure?");
const afterB = (await conn.getNonce(B.kp.publicKey)).nonce;
const balAfter = await conn.getBalance(payer.publicKey);
line(`       BEFORE   ${B.nonce}`);
line(`       AFTER    ${afterB}`);
line(`       ADVANCED ${B.nonce !== afterB}`);
line(`       fee paid ${balBefore - balAfter} lamports on a transaction that did nothing`);
line();

line("   3c. now broadcast the user's pre-signed exit — the one the control proved works.");
const resB = await broadcast(exitB, { label: "treatment exit" });
line(`       → ${resB.landed ? "LANDED" : "REJECTED"} — ${resB.reason}`);
line();

/* ────────────────────────────── VERDICT ─────────────────────────────── */

const burned = B.nonce !== afterB;
line("VERDICT");
line(`  control  (no burn): exit ${resA.landed ? "LANDED" : "failed"}`);
line(`  treatment (burned): exit ${resB.landed ? "LANDED" : "REJECTED"}`);
line(`  nonce advanced on a FAILED transaction: ${burned}`);
line();
line(burned && !resB.landed
  ? "CONFIRMED, both halves.\n" +
    "  (a) A durable-nonce transaction that FAILS execution still advances the\n" +
    "      nonce and still collects the fee.\n" +
    "  (b) The user's pre-signed exit — proven to work by the control arm — is\n" +
    "      then dead. Not reverted, not retryable: unbroadcastable.\n" +
    "  A keeper CAN destroy a user's stop by broadcasting it early, and the user\n" +
    "  has no signature left to try again with. Any design that hands a pre-signed\n" +
    "  exit to a keeper needs a re-sign path, or the stop dies silently at exactly\n" +
    "  the moment it was meant to fire."
  : burned && resB.landed
  ? "SPLIT — the nonce advanced but the pre-signed exit STILL LANDED. The burn is\n" +
    "  real and the consequence is not. Explain this before building on either."
  : "NOT REPRODUCED — the nonce did NOT advance on execution failure. The\n" +
    "  documented reading does not hold on this cluster. Do not build on either\n" +
    "  branch until this is explained.");
