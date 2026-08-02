// LIVE MAINNET — does the keeper resolve a Token-2022 position at all?
//
// WHY THIS EXISTS. readLiveDelegate derived the ATA with the default token
// program (classic SPL). The ATA is derived FROM the token program id, so for a
// Token-2022 mint it resolved to a different address entirely — getAccount
// threw, the catch turned it into REFUSED, and the keeper reported "not
// authorised" for a position that was authorised. Silent, total, and invisible:
// no error surfaces, the loop just never acts.
//
// Measured 2026-08-01: 25 of 25 live radar picks are Token-2022. pump.fun mints
// Token-2022, so the default was wrong for EVERY position the desk can open.
//
// This is a READ-ONLY test against live mainnet. It signs nothing, sends
// nothing, and needs no key. It reads real mints off the real radar feed,
// because that is the population the keeper actually faces — a synthetic mint
// created by the test would have been classic SPL and would have passed against
// the broken code, which is exactly how this survived until now.
//
// RUN:  SOLANA_RPC_URL=<mainnet rpc> node keeper/test/token2022-live.js
"use strict";

const assert = require("assert");
const { Connection, PublicKey, Keypair } = require("@solana/web3.js");
const {
  getAssociatedTokenAddress, TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID,
} = require("@solana/spl-token");
const { readLiveDelegate } = require("../positions.js");

const RPC = process.env.SOLANA_RPC_URL || "https://api.mainnet-beta.solana.com";
const FEED = process.env.DESK_URL || "https://possessio.io";

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? " — " + detail : ""}`); }
};

(async () => {
  const conn = new Connection(RPC, "confirmed");
  console.log(`TOKEN-2022 LIVE CHECK — ${RPC}`);

  const feed = await (await fetch(`${FEED}/api/radar/candidates`)).json();
  const rows = [...(feed.live || []), ...(feed.recent || []), ...(feed.early || [])]
    .filter((r) => r.token_address);
  if (!rows.length) { console.log("  SKIP — radar feed returned no rows"); process.exit(0); }

  // 1. What the keeper actually faces.
  const sample = rows.slice(0, 8);
  let t22 = 0, classic = 0;
  for (const r of sample) {
    const info = await conn.getAccountInfo(new PublicKey(r.token_address));
    if (!info) continue;
    if (info.owner.equals(TOKEN_2022_PROGRAM_ID)) t22++;
    else if (info.owner.equals(TOKEN_PROGRAM_ID)) classic++;
  }
  console.log(`\n  live picks sampled: ${sample.length} — Token-2022 ${t22}, classic ${classic}\n`);
  ok("the radar feed contains Token-2022 mints at all", t22 > 0,
     "if this fails the regression cannot be exercised and the run proves nothing");

  // 2. THE REGRESSION. The old code derived the ATA with the classic program;
  //    prove that address differs, so a passing run below is attributable to
  //    the fix and not to the two addresses happening to coincide.
  const t22Row = (await (async () => {
    for (const r of sample) {
      const i = await conn.getAccountInfo(new PublicKey(r.token_address));
      if (i && i.owner.equals(TOKEN_2022_PROGRAM_ID)) return r;
    }
    return null;
  })());
  if (!t22Row) { console.log("  SKIP — no Token-2022 mint in the sample"); process.exit(fail ? 1 : 0); }

  const holder = Keypair.generate().publicKey;      // any owner; we read, never write
  const mintPk = new PublicKey(t22Row.token_address);
  const wrong = await getAssociatedTokenAddress(mintPk, holder, false);                        // old behaviour
  const right = await getAssociatedTokenAddress(mintPk, holder, false, TOKEN_2022_PROGRAM_ID); // correct
  console.log(`  mint ${t22Row.symbol} ${t22Row.token_address}`);
  console.log(`    classic-derived ATA : ${wrong.toBase58()}`);
  console.log(`    token-2022 ATA      : ${right.toBase58()}`);
  ok("classic and Token-2022 ATAs are different addresses", !wrong.equals(right),
     "the bug would be unobservable if these matched");

  // 3. readLiveDelegate must resolve the CORRECT ata for a Token-2022 mint.
  //
  //    This needs a REAL holder. A generated pubkey owns no token account, so
  //    getAccount throws and REFUSED nulls the ata — the derived address is
  //    then unobservable and the test proves nothing either way. That is a
  //    property of the instrument, not of the fix: the first version of this
  //    test asserted against a random keypair and failed on correct code.
  //
  //    So: find an actual on-chain holder whose account is a genuine ATA.
  //    The holder must also be ON-CURVE. The biggest holders of a fresh
  //    pump.fun token are pool/bonding-curve PDAs, which are off-curve, and
  //    readLiveDelegate passes allowOwnerOffCurve:false — correctly, because a
  //    real user wallet is always on-curve. Selecting an off-curve holder makes
  //    the function throw and the test blames the fix for the instrument's
  //    choice of subject. (It did, on the previous run.)
  const largest = await conn.getTokenLargestAccounts(mintPk);
  let realOwner = null, realAta = null;
  for (const { address } of (largest.value || []).slice(0, 20)) {
    const acc = await conn.getParsedAccountInfo(address);
    const o = acc?.value?.data?.parsed?.info?.owner;
    if (!o || !PublicKey.isOnCurve(new PublicKey(o).toBytes())) continue;
    const derived = await getAssociatedTokenAddress(mintPk, new PublicKey(o), false, TOKEN_2022_PROGRAM_ID);
    if (derived.equals(address)) { realOwner = o; realAta = address; break; }   // a true user ATA
  }
  if (!realOwner) { console.log("  SKIP — no ATA-shaped holder found for this mint"); process.exit(fail ? 1 : 0); }
  console.log(`    real holder         : ${realOwner}`);
  console.log(`    their ATA           : ${realAta.toBase58()}`);

  const seen = await readLiveDelegate({
    connection: conn, owner: realOwner,
    mint: t22Row.token_address, keeper: Keypair.generate().publicKey.toBase58(),
  });
  console.log(`    readLiveDelegate ata: ${seen.ata}  amount ${seen.amount}`);
  ok("readLiveDelegate resolves a real Token-2022 holder's account",
     seen.ata === realAta.toBase58(),
     `expected ${realAta.toBase58()}, got ${seen.ata}`);
  ok("it read a real balance rather than refusing blind", seen.amount !== "0" || seen.ata !== null);
  const wrongForReal = await getAssociatedTokenAddress(mintPk, new PublicKey(realOwner), false);
  ok("and it is NOT the classic-derived address the old code used",
     seen.ata !== wrongForReal.toBase58(),
     `old code would have looked at ${wrongForReal.toBase58()}`);
  ok("an unauthorised holder is still reported unauthorised", seen.authorised === false);

  // 4. A non-token account must still refuse rather than throw.
  const notAMint = await readLiveDelegate({
    connection: conn, owner: holder.toBase58(),
    mint: "SysvarC1ock11111111111111111111111111111111",
    keeper: Keypair.generate().publicKey.toBase58(),
  });
  ok("a non-token account refuses safely", notAMint.authorised === false && notAMint.ata === null);

  console.log(`\n  ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
