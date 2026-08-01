// DEVNET MEASUREMENT — X-LINK/N mutual exclusion, composition, and third-party broadcast.
//
// Closes the three open items in SPEC_XLINK_SOLANA_NONCE_HANDSHAKE.md §8:
//
//   (i)   Mutual exclusion between TX-EXIT and TX-REVOKE on a SHARED nonce.
//         "Derived from documented runtime semantics; never executed."
//   (ii)  Whether `revoke` and `nonceAdvance` COMPOSE in one transaction with
//         the user as authority for both.
//   (iii) Third-party broadcast of a fully-signed TX-REVOKE.
//
// Assay costed the closing experiment at "one nonce account, ~0.0015 SOL, and
// two signatures on devnet." This is that experiment, run in BOTH directions —
// because mutual exclusion is a symmetric claim and testing one ordering only
// proves one ordering.
//
// THE SHAPE UNDER TEST (spec §3): the user signs exactly two transactions
// against the SAME stored nonce hash H.
//
//   TX-EXIT    ix0 nonceAdvance(authority=user)   ix1 the exit (user-authorized)
//   TX-REVOKE  ix0 nonceAdvance(authority=user)   ix1 SPL revoke(owner=user)
//
// Whichever lands first advances H→H'. The other must then be UNBROADCASTABLE.
// Exactly one outcome, ever, enforced by the runtime rather than by trust.
//
// Both carry keeper as fee payer (signer[0]) and user as signer[1], per spec §2
// and the config-B measurement.
//
// DEVNET ONLY. Throwaway keypairs, a throwaway mint, worthless SOL. No real key
// is read and nothing here can move value.
//
// RUN:  node keeper/test/xlink-n-devnet.mjs
//       PAYER_SECRET='[...]' node keeper/test/xlink-n-devnet.mjs   (dry faucet)

import {
  Connection, Keypair, SystemProgram, Transaction, PublicKey,
  NONCE_ACCOUNT_LENGTH, LAMPORTS_PER_SOL, sendAndConfirmTransaction,
} from "@solana/web3.js";
import {
  createMint, getOrCreateAssociatedTokenAccount, mintTo, getAccount,
  createApproveInstruction, createRevokeInstruction, createTransferInstruction,
} from "@solana/spl-token";
import { readFileSync, writeFileSync } from "node:fs";

const RPC = process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com";
const conn = new Connection(RPC, "confirmed");

const CACHE = process.env.PAYER_CACHE
  || `${process.env.TMPDIR || "/tmp"}/possessio-devnet-xlink-payer.json`;
function loadUser() {
  if (process.env.PAYER_SECRET)
    return { kp: Keypair.fromSecretKey(Uint8Array.from(JSON.parse(process.env.PAYER_SECRET))), from: "supplied" };
  try {
    return { kp: Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(CACHE, "utf8")))), from: "cached" };
  } catch { /* first run */ }
  const kp = Keypair.generate();
  try { writeFileSync(CACHE, JSON.stringify([...kp.secretKey])); } catch { /* optional */ }
  return { kp, from: "generated" };
}

const { kp: user, from: userFrom } = loadUser();
const keeper = Keypair.generate();     // fee payer + delegate, per spec §2

const line = (s = "") => console.log(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = {};

line("DEVNET — X-LINK/N HANDSHAKE MEASUREMENT");
line(`  rpc     ${RPC}`);
line(`  user    ${user.publicKey.toBase58()} (${userFrom})  — nonce authority, token owner`);
line(`  keeper  ${keeper.publicKey.toBase58()} — fee payer, delegate`);
line();

/* ───────────────────────────── funding ───────────────────────────── */

const nonceRent = await conn.getMinimumBalanceForRentExemption(NONCE_ACCOUNT_LENGTH);
line("1. funding…");
async function airdrop(pk, sol) {
  const sig = await conn.requestAirdrop(pk, sol * LAMPORTS_PER_SOL);
  await conn.confirmTransaction({ signature: sig, ...(await conn.getLatestBlockhash()) }, "confirmed");
}
// The user pays for the mint, ATAs and nonce accounts; the keeper only needs
// fees. Both must be funded or the run measures funding, not the handshake.
const NEED_USER = 0.05 * LAMPORTS_PER_SOL;
if ((await conn.getBalance(user.publicKey)) < NEED_USER) {
  let ok = false;
  for (const sol of [0.5, 0.2, 0.1]) {
    try { await airdrop(user.publicKey, sol); ok = true; break; }
    catch (e) { line(`   user ${sol} SOL refused: ${String(e.message).split("\n")[0].slice(0, 60)}`); }
  }
  if (!ok) {
    line(`\n   FAUCET REFUSED — rate-limited per egress IP. This says nothing about`);
    line(`   the claims under test. Fund the user above with ~0.05 devnet SOL and`);
    line(`   re-run:  PAYER_SECRET='[...]' node keeper/test/xlink-n-devnet.mjs`);
    process.exit(1);
  }
}
try { await airdrop(keeper.publicKey, 0.05); }
catch {
  // A dry faucet on the second call is survivable: move fee money from the
  // user, who is already funded. The keeper's ROLE (fee payer, signer 0) is
  // what is under test, not where its lamports came from.
  await sendAndConfirmTransaction(conn, new Transaction().add(SystemProgram.transfer({
    fromPubkey: user.publicKey, toPubkey: keeper.publicKey, lamports: 0.02 * LAMPORTS_PER_SOL,
  })), [user], { commitment: "confirmed" });
  line("   keeper funded from the user (faucet dry on second call)");
}
line(`   user   ${(await conn.getBalance(user.publicKey)) / LAMPORTS_PER_SOL} SOL`);
line(`   keeper ${(await conn.getBalance(keeper.publicKey)) / LAMPORTS_PER_SOL} SOL`);
line();

/* ─────────────────────── token + delegate setup ─────────────────────── */

line("2. throwaway mint, user ATA, and an SPL delegate granted to the keeper…");
const mint = await createMint(conn, user, user.publicKey, null, 6);
const userAta = await getOrCreateAssociatedTokenAccount(conn, user, mint, user.publicKey);
await mintTo(conn, user, mint, userAta.address, user, 1_000_000n);
const sink = await getOrCreateAssociatedTokenAccount(conn, user, mint, keeper.publicKey);

// The grant the desk actually makes: delegate = keeper, capped at position size.
await sendAndConfirmTransaction(conn, new Transaction().add(
  createApproveInstruction(userAta.address, keeper.publicKey, user.publicKey, 1_000_000n),
), [user], { commitment: "confirmed" });
const granted = await getAccount(conn, userAta.address);
line(`   mint      ${mint.toBase58()}`);
line(`   user ATA  ${userAta.address.toBase58()}  balance ${granted.amount}`);
line(`   delegate  ${granted.delegate?.toBase58()}  amount ${granted.delegatedAmount}`);
results.delegateGranted = granted.delegate?.toBase58() === keeper.publicKey.toBase58();
line();

/* ──────────────────────────── the handshake ──────────────────────────── */

async function newNonce() {
  const kp = Keypair.generate();
  await sendAndConfirmTransaction(conn, new Transaction().add(
    SystemProgram.createAccount({
      fromPubkey: user.publicKey, newAccountPubkey: kp.publicKey,
      lamports: nonceRent, space: NONCE_ACCOUNT_LENGTH, programId: SystemProgram.programId,
    }),
    // Invariant A (spec §2): the nonce authority is the USER, never the keeper.
    SystemProgram.nonceInitialize({ noncePubkey: kp.publicKey, authorizedPubkey: user.publicKey }),
  ), [user, kp], { commitment: "confirmed" });
  return { kp, hash: (await conn.getNonce(kp.publicKey)).nonce };
}

/// Both transactions in the pair. Signed against the SAME stored hash H, with
/// nonceAdvance at instruction 0 (spec invariant 3) and the keeper as fee payer.
function buildPair(noncePubkey, H) {
  const advance = () => SystemProgram.nonceAdvance({
    noncePubkey, authorizedPubkey: user.publicKey,     // invariant 1
  });
  const sign = (tx) => {
    tx.recentBlockhash = H;                            // invariant 4: read, not assumed
    tx.feePayer = keeper.publicKey;                    // spec §2: keeper pays
    tx.sign(keeper, user);                             // signer[0] keeper, signer[1] user
    return tx.serialize();
  };
  // TX-EXIT stands in for the Jupiter swap: a token movement the USER authorizes.
  const exit = new Transaction().add(advance(), createTransferInstruction(
    userAta.address, sink.address, user.publicKey, 250_000n,
  ));
  // TX-REVOKE is the real thing, not a stand-in — this is claim (ii).
  const revoke = new Transaction().add(advance(), createRevokeInstruction(
    userAta.address, user.publicKey,
  ));
  return { exit: sign(exit), revoke: sign(revoke) };
}

/// Broadcast raw bytes. Preflight ON so the runtime NAMES its objection instead
/// of the transaction vanishing silently.
async function send(raw, label) {
  let sig;
  try {
    sig = await conn.sendRawTransaction(raw, { preflightCommitment: "confirmed" });
  } catch (e) {
    const cause = e?.transactionMessage || String(e.message).replace(/\s+/g, " ").trim();
    return { landed: false, why: `rejected at preflight — ${cause.slice(0, 200)}` };
  }
  for (let i = 0; i < 45; i++) {
    const v = (await conn.getSignatureStatus(sig, { searchTransactionHistory: true }))?.value;
    if (v && (v.confirmationStatus === "confirmed" || v.confirmationStatus === "finalized")) {
      return v.err
        ? { landed: false, why: `executed and FAILED — ${JSON.stringify(v.err)}`, sig }
        : { landed: true, why: "landed", sig };
    }
    await sleep(1000);
  }
  return { landed: false, why: "accepted but never confirmed (dropped)", sig };
}

/* ── ROUND 1: REVOKE lands first. Tests composition (ii) and exclusion. ── */

line("3. ROUND 1 — the timer fires first. TX-REVOKE broadcast, then TX-EXIT.");
{
  const { kp, hash } = await newNonce();
  line(`   nonce ${kp.publicKey.toBase58()}  H=${hash}`);
  const pair = buildPair(kp.publicKey, hash);

  // Claim (iii): a fully-signed transaction carries no submitter identity, so
  // a third party should be able to broadcast it. Nothing about `send` uses a
  // key — these are raw bytes anyone could hold.
  const r = await send(pair.revoke, "TX-REVOKE");
  line(`   TX-REVOKE  ${r.landed ? "LANDED" : "REJECTED"} — ${r.why}`);
  results.revokeComposes = r.landed;

  const after = await getAccount(conn, userAta.address);
  line(`   delegate now: ${after.delegate ? after.delegate.toBase58() : "NONE"}  (amount ${after.delegatedAmount})`);
  results.delegateCleared = after.delegate === null;

  const e = await send(pair.exit, "TX-EXIT");
  line(`   TX-EXIT    ${e.landed ? "LANDED" : "REJECTED"} — ${e.why}`);
  results.exclusion_revokeFirst = r.landed && !e.landed;
}
line();

/* ── ROUND 2: EXIT lands first. Exclusion is symmetric or it is not proven. ── */

line("4. ROUND 2 — the exit fires first. TX-EXIT broadcast, then TX-REVOKE.");
{
  const { kp, hash } = await newNonce();
  line(`   nonce ${kp.publicKey.toBase58()}  H=${hash}`);
  // Re-grant: round 1 revoked the delegate, and the pair must be built against
  // the state the desk would actually be in — a live grant.
  await sendAndConfirmTransaction(conn, new Transaction().add(
    createApproveInstruction(userAta.address, keeper.publicKey, user.publicKey, 500_000n),
  ), [user], { commitment: "confirmed" });

  const pair = buildPair(kp.publicKey, hash);
  const e = await send(pair.exit, "TX-EXIT");
  line(`   TX-EXIT    ${e.landed ? "LANDED" : "REJECTED"} — ${e.why}`);

  const r = await send(pair.revoke, "TX-REVOKE");
  line(`   TX-REVOKE  ${r.landed ? "LANDED" : "REJECTED"} — ${r.why}`);

  const after = await getAccount(conn, userAta.address);
  line(`   delegate still: ${after.delegate ? after.delegate.toBase58() : "NONE"}  (amount ${after.delegatedAmount})`);
  results.exclusion_exitFirst = e.landed && !r.landed;
  // The honest consequence of exclusion: an exit that fires leaves the delegate
  // STANDING, because the transaction that would have revoked it is now void.
  results.delegateSurvivesExit = after.delegate !== null;
}
line();

/* ── ROUND 3: the proposed fix — revoke rides INSIDE TX-EXIT as ix2. ── */

// Rounds 1-2 showed the delegate outlives a fired exit: mutual exclusion voids
// TX-REVOKE the moment TX-EXIT advances the nonce, so the expiry is consumed by
// the very event it was meant to outlive. If the revoke travels inside TX-EXIT
// instead, a successful exit clears its own authority atomically.
line("5. ROUND 3 — proposed fix: TX-EXIT carries the revoke as instruction 2.");
{
  const { kp, hash } = await newNonce();
  await sendAndConfirmTransaction(conn, new Transaction().add(
    createApproveInstruction(userAta.address, keeper.publicKey, user.publicKey, 500_000n),
  ), [user], { commitment: "confirmed" });
  line(`   nonce ${kp.publicKey.toBase58()}  H=${hash}`);

  // Built twice, identical but for the revoke, so the byte cost is a MEASURED
  // difference rather than a subtraction against some other test's constant.
  // §6 budgets ~198 B of headroom on a two-hop with 3 ALTs, so what this costs
  // decides whether the fix is affordable on a real route.
  const build = (withRevoke) => {
    const tx = new Transaction().add(
      SystemProgram.nonceAdvance({ noncePubkey: kp.publicKey, authorizedPubkey: user.publicKey }),
      createTransferInstruction(userAta.address, sink.address, user.publicKey, 100_000n),
    );
    if (withRevoke) tx.add(createRevokeInstruction(userAta.address, user.publicKey));
    tx.recentBlockhash = hash;
    tx.feePayer = keeper.publicKey;
    tx.sign(keeper, user);
    return tx.serialize();
  };
  const plain = build(false).length;
  const raw = build(true);

  const r = await send(raw, "TX-EXIT+revoke");
  line(`   TX-EXIT+revoke  ${r.landed ? "LANDED" : "REJECTED"} — ${r.why}`);
  const after = await getAccount(conn, userAta.address);
  line(`   delegate after: ${after.delegate ? after.delegate.toBase58() : "NONE"}  (amount ${after.delegatedAmount})`);
  line(`   size ${plain} B -> ${raw.length} B; revoke costs ${raw.length - plain} B of the 198 B headroom`);
  line(`   (it reuses accounts already in the message, so it adds only an instruction header)`);
  results.exitSelfRevokes = r.landed && after.delegate === null;
}
line();

/* ──────────────────────────── VERDICT ──────────────────────────── */

line("VERDICT — SPEC_XLINK_SOLANA_NONCE_HANDSHAKE §8");
const rows = [
  ["revoke + nonceAdvance compose in one tx (§8 item 3)", results.revokeComposes],
  ["  …and the delegate is actually cleared", results.delegateCleared],
  ["mutual exclusion, REVOKE first (§8 item 1)", results.exclusion_revokeFirst],
  ["mutual exclusion, EXIT first (§8 item 1, other direction)", results.exclusion_exitFirst],
  ["third-party broadcast of a fully-signed tx (§8 item 5)", results.revokeComposes],
  ["PROPOSED FIX: exit carrying its own revoke clears the delegate", results.exitSelfRevokes],
];
for (const [k, v] of rows) line(`  ${v ? "PASS" : "FAIL"}  ${k}`);
line();
const allPass = rows.every(([, v]) => v);
line(allPass
  ? "X-LINK/N MUTUAL EXCLUSION HOLDS, MEASURED IN BOTH DIRECTIONS.\n" +
    "  Exactly one of TX-EXIT / TX-REVOKE can ever execute. The runtime enforces\n" +
    "  it — no coordination, no race resolution, no trust.\n" +
    "  A pre-signed, publishable TX-REVOKE therefore gives an SPL delegate the\n" +
    "  permissionless expiry it does not natively have."
  : "NOT FULLY ESTABLISHED — see the FAIL rows above. Do not build on the\n" +
    "  unproven claims.");
line();
if (results.delegateSurvivesExit) {
  line("NOTE, and it is not in the spec: after TX-EXIT fires, TX-REVOKE is void by");
  line("construction, so THE DELEGATE SURVIVES THE EXIT with no expiry left.");
  line("Mutual exclusion cuts both ways — the same property that makes the timer");
  line("safe means a fired exit consumes the timer too.");
}
