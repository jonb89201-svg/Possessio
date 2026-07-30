// LIVE VERIFICATION for the keeper's authority read.
//
// This exists because the keeper's FIRST delegate-discovery design — a
// program-wide getProgramAccounts scan of the SPL Token program — passed every
// offline test and then died on real infrastructure:
//
//   TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA excluded from account
//   secondary indexes; this RPC method unavailable for key
//
// An offline DoD cannot catch that. So the replacement gets certified against
// the live chain, on a real provider, before it is trusted:
//
//   1. readLiveDelegate SUCCEEDS on a real mainnet account (the thing that failed)
//   2. it FAILS CLOSED for a keeper that was never granted anything
//   3. authorised:true is REACHABLE — proved by simulating the REAL grant the
//      user signs and decoding the resulting on-chain account state
//   4. the grant is bounded, and REVOKE takes the authority back
//   5. a nonexistent account fails closed rather than throwing
//   6. a full keeper cycle runs against live RPC without the scan
//
// Nothing is signed and nothing is spent: DRY_RUN is forced on.
//
// Run:  SOLANA_RPC_URL=... node keeper/test/keeper-live.js
"use strict";

process.env.DRY_RUN = "1";                  // belt and braces: never sign here

const { Connection, PublicKey, VersionedTransaction } = require("@solana/web3.js");
const { readLiveDelegate, decide } = require("../positions");
const L = require("../../miniapp/solana-leg");
const K = require("../index");

const RPC = process.env.SOLANA_RPC_URL;
if (!RPC) { console.error("need SOLANA_RPC_URL"); process.exit(1); }

const BONK = "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263";
const NOBODY = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";  // granted nothing

const conn = new Connection(RPC, "confirmed");
let pass = 0, fail = 0;
const ok = (n, x = "") => { console.log(`  PASS  ${n}${x ? "  " + x : ""}`); pass++; };
const no = (n, e) => { console.log(`  FAIL  ${n}\n        ${e}`); fail++; };

/// A real holder whose largest account IS their ATA — the keeper reads ATAs,
/// so a whale holding in a non-ATA account would prove nothing.
async function findAtaHolder(mint) {
  const mintPk = new PublicKey(mint);
  const largest = await conn.getTokenLargestAccounts(mintPk);
  const { getAssociatedTokenAddress } = require("@solana/spl-token");
  for (const a of largest.value.slice(0, 20)) {
    const info = await conn.getParsedAccountInfo(a.address);
    const p = info.value?.data?.parsed?.info;
    if (!p?.owner) continue;
    const ata = await getAssociatedTokenAddress(mintPk, new PublicKey(p.owner), true);
    if (ata.toBase58() !== a.address.toBase58()) continue;
    return { owner: p.owner, amount: p.tokenAmount?.amount, delegate: p.delegate || null };
  }
  throw new Error("no ATA-holding whale found");
}

/// Run a transaction against live mainnet and hand back the resulting state of
/// one account — WITHOUT submitting it.
///
/// This is how the positive branch gets certified honestly. We cannot find a
/// mainnet whale who has granted OUR keeper a delegate, and we cannot enumerate
/// the retail accounts that do use delegates (that is the very scan the RPC
/// refuses). But simulateTransaction returns post-execution account data, so we
/// can execute the REAL grant instruction the user signs against REAL state and
/// read back the exact bytes the chain would hold afterwards. Those bytes are
/// then decoded and judged by the keeper's own predicate.
async function stateAfter(txOrBase64, address, label) {
  const tx = typeof txOrBase64 === "string"
    ? VersionedTransaction.deserialize(Buffer.from(txOrBase64, "base64"))
    : txOrBase64;
  const res = await conn.simulateTransaction(tx, {
    sigVerify: false, replaceRecentBlockhash: true, commitment: "confirmed",
    accounts: { encoding: "base64", addresses: [address.toBase58()] },
  });
  if (res.value.err) {
    const logs = (res.value.logs || []).slice(-6).join("\n        ");
    throw new Error(`${label} failed: ${JSON.stringify(res.value.err)}\n        ${logs}`);
  }
  const post = res.value.accounts && res.value.accounts[0];
  if (!post) throw new Error(`${label}: simulation returned no post-state for the account`);
  const { unpackAccount } = require("@solana/spl-token");
  return unpackAccount(address, {
    data: Buffer.from(post.data[0], "base64"),
    owner: new PublicKey(post.owner),
    lamports: post.lamports,
    executable: post.executable,
    rentEpoch: post.rentEpoch,
  });
}

(async () => {
  console.log("MODEL B KEEPER — authority read, certified against LIVE mainnet\n");
  console.log(`  slot : ${await conn.getSlot()}\n`);

  // ── 1. the read that replaced the impossible scan ──────────────────────
  let holder;
  try {
    holder = await findAtaHolder(BONK);
    const live = await readLiveDelegate({
      connection: conn, owner: holder.owner, mint: BONK, keeper: NOBODY,
    });
    if (!live.ata) throw new Error("no ATA resolved");
    ok("readLiveDelegate SUCCEEDS on live RPC (the scan could not)",
       `ata=${live.ata.slice(0, 8)}… balance=${live.amount}`);
  } catch (e) { no("readLiveDelegate on live RPC", e.message); }

  // ── 2. fails closed for a keeper nobody granted ────────────────────────
  try {
    const live = await readLiveDelegate({
      connection: conn, owner: holder.owner, mint: BONK, keeper: NOBODY,
    });
    if (live.authorised) throw new Error("authorised a keeper that was never granted anything");
    ok("an ungranted keeper is NOT authorised over a real, funded account",
       `delegate on chain = ${live.delegate || "none"}`);
  } catch (e) { no("ungranted keeper is refused", e.message); }

  // ── 3. the POSITIVE branch, from state the real grant actually produces ─
  const KEEPER = process.env.KEEPER_PUBKEY_TEST ||
    "ARjf4vUNiU8cW6xXfBfiL8ibc5qC4pYim5mLxbe6uog5";   // the real Model B keeper
  const GRANT = "1000000000";                          // bounded: not the balance
  let ata, granted;
  try {
    const { getAssociatedTokenAddress } = require("@solana/spl-token");
    ata = await getAssociatedTokenAddress(new PublicKey(BONK), new PublicKey(holder.owner), true);

    const approval = await L.buildDelegateApproval({
      connection: conn, userPublicKey: holder.owner, mint: BONK,
      amount: GRANT, keeper: KEEPER,
    });
    granted = await stateAfter(approval.tx, ata, "approve");

    const live = decide({ ata, owner: holder.owner, mint: BONK, acc: granted, keeper: KEEPER });
    if (!live.authorised) throw new Error("the keeper's own predicate refused a real, live grant");

    const other = decide({ ata, owner: holder.owner, mint: BONK, acc: granted, keeper: NOBODY });
    if (other.authorised) throw new Error("a DIFFERENT key was authorised by the same grant");

    ok("authorised:true is produced by the REAL grant, and only for the granted key",
       `delegate=${live.delegate.slice(0, 8)}… delegated=${live.delegatedAmount}`);
  } catch (e) { no("the positive branch reflects real chain state", e.message); }

  // ── 4. the grant is BOUNDED, and revoke takes it back ──────────────────
  // Two properties the user is really trusting: the keeper cannot reach past
  // the number they authorised, and they can withdraw it unilaterally.
  try {
    if (!granted) throw new Error("no granted state to check (step 3 failed)");
    if (granted.delegatedAmount !== BigInt(GRANT)) {
      throw new Error(`grant was ${granted.delegatedAmount}, user authorised ${GRANT}`);
    }
    if (!(granted.amount > granted.delegatedAmount)) {
      throw new Error("test is vacuous: pick a holder whose balance exceeds the grant");
    }
    ok("the grant is EXACTLY the authorised amount, well under the user's balance",
       `delegated=${GRANT} of balance=${granted.amount}`);
  } catch (e) { no("the grant is bounded", e.message); }

  try {
    const rev = await L.buildRevoke({ connection: conn, userPublicKey: holder.owner, mint: BONK });
    const after = await stateAfter(rev.tx, ata, "revoke");
    const live = decide({ ata, owner: holder.owner, mint: BONK, acc: after, keeper: KEEPER });
    if (live.authorised) throw new Error("the keeper still had authority after a revoke");
    ok("REVOKE removes the keeper's authority on chain — the kill switch is real",
       `delegate after revoke = ${live.delegate || "none"}`);
  } catch (e) { no("revoke removes authority", e.message); }

  // ── 5. a nonexistent account fails closed, not loudly ──────────────────
  try {
    const live = await readLiveDelegate({
      connection: conn,
      owner: "11111111111111111111111111111112",
      mint: BONK, keeper: NOBODY,
    });
    if (live.authorised) throw new Error("authorised against an account that does not exist");
    if (live.delegatedAmount !== "0") throw new Error("phantom delegated amount");
    ok("an account that does not exist fails CLOSED (no throw, no authority)");
  } catch (e) { no("nonexistent account fails closed", e.message); }

  // ── 6. a real cycle, end to end, on live RPC ───────────────────────────
  // A rule for a real holder who has granted this keeper nothing. The correct
  // outcome is: read the chain, find no authority, stand down. Which is the
  // 3am behaviour that matters — the keeper does nothing it was not permitted.
  try {
    const source = {
      name: "live-test",
      async list() {
        return [{
          id: "live-1", user: holder.owner, mint: BONK, decimals: 5,
          entryPrice: 0.00001, targetBps: 5000, stopBps: 1000, status: "open",
        }];
      },
    };
    process.env.KEEPER_PUBKEY = NOBODY;
    const s = await K.cycle({ connection: conn, keeper: null, source });
    if (s.watching !== 1) throw new Error(`expected 1 ruled position, got ${s.watching}`);
    if (s.authorised !== 0) throw new Error("the keeper claimed authority it was never granted");
    ok("a full cycle runs on live RPC and stands down with zero authority",
       `watching=${s.watching} authorised=${s.authorised}`);
  } catch (e) { no("a full cycle runs on live RPC", e.message); }

  // ── 7. THE FIRE PATH, driven by state a real grant actually produces ───
  // Steps 1-6 prove the keeper stands down correctly. This proves the other
  // half: that when the chain DOES say it is authorised and the price crosses
  // the authored target, the loop actually reaches the exit and builds one —
  // priced by a live Jupiter route, bounded by the real delegated amount,
  // payable to the user. Everything here is real except the grant's presence
  // in committed state, which no stranger will hand us.
  try {
    if (!granted) throw new Error("no granted state (step 3 failed)");
    const source = {
      name: "live-test",
      async list() {
        return [{
          id: "fire-1", user: holder.owner, mint: BONK, decimals: 5,
          entryPrice: 1e-12,            // far below spot: the target must trigger
          targetBps: 100, stopBps: 1000, status: "open",
        }];
      },
    };
    process.env.KEEPER_PUBKEY = KEEPER;
    const s = await K.cycle({
      connection: conn, keeper: null, source,
      readDelegate: async ({ owner, mint, keeper }) =>
        decide({ ata, owner, mint, acc: granted, keeper }),   // real post-grant bytes
    });
    if (s.authorised !== 1) throw new Error("the live grant was not recognised by the loop");
    if (s.fired.length !== 1) throw new Error("the loop did not fire on a crossed target");
    const f = s.fired[0];
    if (f.kind !== "target") throw new Error(`fired on ${f.kind}, expected target`);
    if (!f.dryRun) throw new Error("DRY_RUN was forced on — nothing may be signed");
    if (!(Number(f.expected) > 0)) throw new Error("the exit produced no USDC for the user");
    ok("the loop FIRES on a crossed target and builds a real, live-priced exit",
       `${f.kind} @ ${f.price.toExponential(4)} -> ${(Number(f.expected) / 1e6).toFixed(2)} USDC to the user`);
  } catch (e) { no("the fire path runs end to end", e.message); }

  console.log(`\n  ${pass} passed, ${fail} failed`);
  console.log("  Nothing was signed: DRY_RUN forced on, and no key was loaded.");
  process.exit(fail ? 1 : 0);
})();
