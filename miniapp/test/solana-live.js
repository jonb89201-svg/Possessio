// LIVE CERTIFICATION for the Model B (self-custody) Solana leg.
//
// Solana has no `forge --fork-url`. Its equivalent is `simulateTransaction`,
// which executes a real transaction against REAL mainnet state — real pools,
// real balances, real account layouts — and returns the result WITHOUT
// submitting it. Nothing is signed and nothing is spent, but a transaction
// that simulates cleanly is a transaction that would have landed.
//
// So this proves, against a real Solana coin:
//   1. a real route exists and quotes
//   2. the BUY the user would sign builds and SIMULATES against live state
//   3. the SPL delegate grant builds and SIMULATES (self-custody, bounded)
//   4. the keeper's delegated EXIT builds and SIMULATES, returning USDC to
//      the user's own account
//   5. revoke builds and simulates — the kill switch is real
//
// Run:  SOLANA_RPC_URL=... node miniapp/test/solana-live.js [MINT]
"use strict";

const { Connection, PublicKey, VersionedTransaction } = require("@solana/web3.js");
const { getAssociatedTokenAddress } = require("@solana/spl-token");
const L = require("../solana-leg");

const RPC = process.env.SOLANA_RPC_URL;
if (!RPC) { console.error("need SOLANA_RPC_URL"); process.exit(1); }

// Default subject: BONK — a real, liquid Solana memecoin of exactly the kind
// the desk screens. Override with argv[2] to certify any other mint.
const MINT = process.argv[2] || "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263";
const KEEPER = process.env.KEEPER_PUBKEY || "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";
const TRADE_USDC = Number(process.env.TRADE_USDC || "50") * 1e6;
// Slippage is a LIVE-MARKET parameter, not a property of the code path. A
// multi-hop route on a volatile memecoin can move between the quote and the
// simulation seconds later, so certification uses a wider band than production
// would; the point is that the transaction EXECUTES, not that 3% was enough.
const SLIP = Number(process.env.SLIPPAGE_BPS || "1000");

const conn = new Connection(RPC, "confirmed");
let pass = 0, fail = 0;
const ok = (n, extra = "") => { console.log(`  PASS  ${n}${extra ? "  " + extra : ""}`); pass++; };
const no = (n, e) => { console.log(`  FAIL  ${n}\n        ${e}`); fail++; };

/// Find a real mainnet holder to stand in as "the user". Simulation reads real
/// balances, so a made-up pubkey would fail for the wrong reason and prove
/// nothing.
///
/// SUBTLETY worth keeping: getTokenLargestAccounts returns token ACCOUNTS, and
/// a whale's balance frequently sits in a NON-ATA account. Jupiter builds
/// against the owner's ASSOCIATED account, so picking such an owner makes the
/// swap read an empty ATA, receive zero, and report it as slippage (6024) —
/// a harness artefact that looks exactly like a broken route. So: only accept
/// a holder whose big account IS their ATA.
async function findHolder(mint, minUi) {
  const mintPk = mint.toBase58 ? mint : new PublicKey(mint);
  const largest = await conn.getTokenLargestAccounts(mintPk);
  for (const a of largest.value.slice(0, 20)) {
    const info = await conn.getParsedAccountInfo(a.address);
    const p = info.value?.data?.parsed?.info;
    if (!p?.owner) continue;
    const ui = Number(p.tokenAmount?.amount || 0) / 10 ** Number(p.tokenAmount?.decimals || 0);
    const raw = p.tokenAmount?.amount;
    if (!(ui > minUi)) continue;
    const ata = await getAssociatedTokenAddress(mintPk, new PublicKey(p.owner), true);
    if (ata.toBase58() !== a.address.toBase58()) continue; // non-ATA: skip
    return { owner: p.owner, ata: a.address.toBase58(), ui, raw };
  }
  throw new Error(`no holder of ${mintPk.toBase58().slice(0, 8)}… whose largest account is their ATA`);
}

async function simulate(txBase64OrTx, label) {
  const tx = typeof txBase64OrTx === "string"
    ? VersionedTransaction.deserialize(Buffer.from(txBase64OrTx, "base64"))
    : txBase64OrTx;
  const res = await conn.simulateTransaction(tx, {
    sigVerify: false,            // we hold no keys and sign nothing
    replaceRecentBlockhash: true,
    commitment: "confirmed",
  });
  if (res.value.err) {
    const logs = (res.value.logs || []).slice(-6).join("\n        ");
    throw new Error(`${label} simulation failed: ${JSON.stringify(res.value.err)}\n        ${logs}`);
  }
  return res.value;
}

(async () => {
  console.log("MODEL B — self-custody Solana leg, certified against LIVE mainnet\n");
  console.log(`  mint under test : ${MINT}`);
  console.log(`  trade size      : ${(TRADE_USDC / 1e6).toFixed(2)} USDC`);
  console.log(`  slippage band   : ${SLIP} bps (certification band)`);
  console.log(`  slot            : ${await conn.getSlot()}\n`);

  let user;
  try {
    user = await findHolder(L.USDC_MINT, 1000);
    ok("found a real USDC holder to stand in as the user", `${user.owner.slice(0, 8)}… holds ${Math.round(user.ui).toLocaleString()} USDC in their ATA`);
  } catch (e) { no("find a real USDC holder", e.message); return done(); }

  // ── 1. a real route exists ───────────────────────────────────────────
  let buy;
  try {
    buy = await L.buildUserBuy({
      userPublicKey: user.owner, mint: MINT, usdcAmount: TRADE_USDC, slippageBps: SLIP,
    });
    const route = (buy.quote.routePlan || []).map((r) => r.swapInfo.label).join(" -> ");
    ok("a live Jupiter route exists for the coin",
       `${(TRADE_USDC / 1e6).toFixed(0)} USDC -> ${buy.expectedOut} atomic  via ${route}`);
  } catch (e) { no("quote + build the user's buy", e.message); return done(); }

  // ── 2. THE BUY THE USER SIGNS, against live state ────────────────────
  try {
    const sim = await simulate(buy.unsignedTxBase64, "buy");
    ok("the BUY simulates against live mainnet state", `${sim.unitsConsumed} CU consumed`);
  } catch (e) { no("the BUY simulates", e.message); }

  // ── 3. THE DELEGATE GRANT — self-custody, bounded ────────────────────
  // SEQUENCING, and it is the real one: a delegate can only be granted over a
  // token account that EXISTS. In production the user's buy creates it moments
  // earlier. A simulation does not persist that state, so the grant is
  // certified against a wallet that genuinely holds the coin — which is
  // exactly the state the user is in when they grant it.
  // The keeper pays the fee on the delegated exit, so an UNFUNDED keeper makes
  // that step fail with a bare "AccountNotFound" — which reads like a broken
  // route and is really an empty wallet. Name it before it can mislead.
  try {
    const kbal = await conn.getBalance(new PublicKey(KEEPER));
    if (kbal === 0) {
      console.log(`  NOTE  keeper ${KEEPER.slice(0, 8)}… holds 0 SOL — it cannot pay fees yet, so the`);
      console.log(`        delegated-exit step below will fail with AccountNotFound. Fund it (~0.05 SOL)`);
      console.log(`        and re-run; every other step is independent of it.`);
    }
  } catch { /* balance probe is advisory only */ }

  let holder;
  try { holder = await findHolder(MINT, 0); }
  catch (e) { no("find a real holder of the coin", e.message); return done(); }

  let approval;
  try {
    approval = await L.buildDelegateApproval({
      connection: conn, userPublicKey: holder.owner, mint: MINT,
      amount: buy.expectedOut, keeper: KEEPER,
    });
    const sim = await simulate(approval.tx, "approve");
    ok("the DELEGATE grant simulates (user keeps custody)",
       `delegate=${KEEPER.slice(0, 8)}… amount=${approval.delegatedAmount} CU=${sim.unitsConsumed}`);
  } catch (e) { no("the DELEGATE grant simulates", e.message); }

  // ── 4. READ IT BACK FROM THE CHAIN ───────────────────────────────────
  try {
    const d = await L.readDelegate({ connection: conn, userPublicKey: holder.owner, mint: MINT });
    ok("the delegate state is READABLE on-chain (the console can always show it)",
       `ata=${d.ata.slice(0, 8)}… existing delegate=${d.delegate || "none"}`);
  } catch (e) { no("read the delegate state", e.message); }

  // ── 5. THE KEEPER'S DELEGATED EXIT ───────────────────────────────────
  // Simulated against a holder of the coin itself, since an exit needs a real
  // position to sell — same discipline as picking a real USDC holder above.
  try {
    const seller = holder.owner, sellAmount = (BigInt(holder.raw) / 1000n).toString();
    const exit = await L.buildDelegatedExit({
      keeperPublicKey: KEEPER, userPublicKey: seller, mint: MINT,
      amount: sellAmount, slippageBps: SLIP,
    });
    const sim = await simulate(exit.unsignedTxBase64, "exit");
    ok("the keeper's DELEGATED EXIT simulates — proceeds to the USER's account",
       `-> ${(Number(exit.expectedUsdcOut) / 1e6).toFixed(2)} USDC  CU=${sim.unitsConsumed}`);
  } catch (e) { no("the delegated EXIT simulates", e.message); }

  // ── 6. THE KILL SWITCH ───────────────────────────────────────────────
  try {
    const rev = await L.buildRevoke({ connection: conn, userPublicKey: holder.owner, mint: MINT });
    await simulate(rev.tx, "revoke");
    ok("REVOKE simulates — the user can withdraw the keeper's authority unilaterally");
  } catch (e) { no("REVOKE simulates", e.message); }

  done();

  function done() {
    console.log(`\n  ${pass} passed, ${fail} failed`);
    console.log("  Nothing was signed and nothing was spent: every step ran through");
    console.log("  simulateTransaction against live mainnet state.");
    process.exit(fail ? 1 : 0);
  }
})();
