// THE MODEL B KEEPER — the thing that makes the stop real.
//
// The user holds their own coin. The keeper holds one bounded, revocable
// permission per position. Its entire job is to watch the executable price and
// fire the exit the human already authorised — target, or the un-removable
// -10% stop — and to do so at 3am when the human is asleep, which is the only
// reason it exists.
//
// FIVE RULES, and the DoD proves each one:
//
//   1. NEVER sell without a LIVE delegate, re-read from the chain every cycle.
//      A user's revoke is a kill switch, and a kill switch that takes effect
//      "next restart" is not a kill switch.
//   2. NEVER sell a position whose RULE is unknown. A delegate the keeper
//      cannot match to an authored target is power without instruction — it
//      gets logged loudly and left alone, never guessed at.
//   3. NEVER exceed the delegated amount.
//   4. Proceeds go to the USER. The keeper is a fee payer and a signer, never
//      a destination.
//   5. The stop is READ, never assigned. No literal -10% appears in this file.
"use strict";

const { Connection, PublicKey, VersionedTransaction } = require("@solana/web3.js");
const L = require("../miniapp/solana-leg");
const { onchainSource, ledgerSource, deskSource, readLiveDelegate } = require("./positions");

const env = (k, d) => (process.env[k] == null || process.env[k] === "" ? d : process.env[k]);
const RPC = env("SOLANA_RPC_URL");
const KEEPER_KEY = env("SOLANA_KEEPER_KEY", "");
const DRY_RUN = env("DRY_RUN", "1") !== "0";
const POLL_MS = Number(env("POLL_MS", "5000"));
const SLIPPAGE_BPS = Number(env("SLIPPAGE_BPS", "300"));
const SOURCE_KIND = env("POSITION_SOURCE", "desk");   // "desk" | "onchain" | "ledger"
const LEDGER_FILE = env("LEDGER_FILE", "./keeper/positions.json");
const DESK_URL = env("DESK_URL", "https://possessio.io");

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const usd = (a) => (Number(a) / 1e6).toFixed(2);

const exited = new Set();   // ids SOLD this run; a second sell is never attempted
const stoodDown = new Set(); // log-once for not-authorised readings — NEVER a blacklist

function loadKeeper() {
  if (!KEEPER_KEY) return null;
  const { Keypair } = require("@solana/web3.js");
  const raw = KEEPER_KEY.trim();
  if (raw.startsWith("[")) return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(raw)));
  const bs58 = require("bs58");
  return Keypair.fromSecretKey((bs58.default || bs58).decode(raw));
}

/// The executable price of a position: what this exact size would actually
/// fetch right now, not a mid-price nobody can trade at. A stop that triggers
/// on an unobtainable number is a stop that lies.
async function executablePrice({ mint, amount, decimals }) {
  const q = await L.quote({
    inputMint: mint, outputMint: L.USDC_MINT.toBase58(),
    amount: String(amount), slippageBps: SLIPPAGE_BPS,
  });
  const usdcOut = Number(q.outAmount) / 1e6;
  const tokens = Number(amount) / 10 ** decimals;
  return { price: usdcOut / tokens, usdcOut: q.outAmount, quote: q };
}

function triggerFor(pos, price) {
  // A PRICE THAT IS NOT A POSITIVE NUMBER IS NOT A PRICE.
  //
  // Defence in depth against the quote guard above: a reading of 0 satisfies
  // `price <= stop` for ANY stop, so a dead route fires a sale into a market
  // with no liquidity — and it fires even on a position with NO stop, because
  // the no-stop sentinel's stop price is itself 0. NaN happens to fail safe
  // (every comparison is false), but relying on that is luck, not a guard.
  //
  // Unknown must stand the keeper down, never act. Same rule as the rug gate
  // that counted an unset RPC as PASS.
  if (!Number.isFinite(price) || price <= 0) return { kind: null, target: null, stop: null };
  const target = pos.entryPrice * (1 + pos.targetBps / 10000);

  // NO STOP IS AN ABSENCE, NOT A VALUE — Architect ratification 2026-08-01,
  // Option B. The branch is the point.
  //
  // The rejected alternative was a sentinel: stopBps 10000 yields a stop price
  // of exactly 0, which no positive price reaches. That works today, and only
  // today. Its safety rests entirely on the price guard above holding forever —
  // a price READING of 0 reaches a threshold of 0 exactly, so any future change
  // to the price path would silently re-arm every no-stop position with nothing
  // in the arithmetic looking wrong.
  //
  // Under absence, no arithmetic can answer the question because the code never
  // asks it. That is the difference between an unreachable threshold and no
  // threshold, and it is why the comparison lives inside the branch rather than
  // being guarded by a null check outside it.
  // A rule that does not SAY is malformed, and does nothing at all.
  //
  // Treating undefined as "no stop" would be the same uninitialised-value trap
  // one level further down: a source that forgets the field would silently
  // produce an unstopped position, which is exactly what rejecting zero was
  // meant to prevent. Absence must be STATED (hasStop === false), never
  // inferred. An unstated rule is unknown, and unknown stands the keeper down —
  // it does not take profit either, because a rule this loop cannot fully read
  // is not a rule it should act on at all.
  if (typeof pos.hasStop !== "boolean") return { kind: null, target: null, stop: null };

  if (pos.hasStop === false) {
    if (price >= target) return { kind: "target", target, stop: null };
    return { kind: null, target, stop: null };
  }

  const stop = pos.entryPrice * (1 - pos.stopBps / 10000);
  if (price >= target) return { kind: "target", target, stop };
  if (price <= stop) return { kind: "stop", target, stop };
  return { kind: null, target, stop };
}

/// Fire the exit the human authorised. Sells the USER's coin under the
/// delegate and delivers USDC to the USER's own account.
/// keeperPk is passed in rather than re-derived from the keypair: a DRY_RUN
/// holds no key at all (that is the point of it), so deriving the pubkey here
/// would crash the loop at the exact moment it tried to prove it works.
async function fireExit({ connection, keeper, keeperPk, pos, live }) {
  const built = await L.buildDelegatedExit({
    keeperPublicKey: keeperPk,
    userPublicKey: pos.user,
    mint: pos.mint,
    amount: live.delegatedAmount,          // rule 3: never more than delegated
    slippageBps: SLIPPAGE_BPS,
  });
  if (DRY_RUN) {
    log(`  [${pos.id}] DRY_RUN: built the exit (${built.unsignedTxBase64.length}b) -> ` +
        `${usd(built.expectedUsdcOut)} USDC to the user. NOT signing.`);
    return { dryRun: true, expected: built.expectedUsdcOut, built };
  }
  if (!keeper) throw new Error("live exit requires the keeper keypair");
  const tx = VersionedTransaction.deserialize(Buffer.from(built.unsignedTxBase64, "base64"));
  tx.sign([keeper]);
  const sig = await connection.sendRawTransaction(tx.serialize(), { maxRetries: 3 });
  const bh = await connection.getLatestBlockhash();
  await connection.confirmTransaction(
    { signature: sig, blockhash: bh.blockhash, lastValidBlockHeight: bh.lastValidBlockHeight }, "confirmed");
  return { dryRun: false, signature: sig, expected: built.expectedUsdcOut };
}

/// readDelegate is injectable ONLY so the live harness can drive the fire path
/// using genuine chain-derived state (the post-state of a simulated real
/// grant), which is otherwise unreachable — no mainnet stranger has granted
/// this keeper anything. It defaults to the live on-chain read, and the DoD
/// asserts that default, so no deployment can quietly substitute a reader that
/// says yes.
async function cycle({ connection, keeper, source, readDelegate = readLiveDelegate }) {
  const keeperPk = keeper ? keeper.publicKey.toBase58() : env("KEEPER_PUBKEY", "");
  if (!keeperPk) throw new Error("need SOLANA_KEEPER_KEY, or KEEPER_PUBKEY for a dry run");

  // What the rule ledger says the keeper should do. The loop iterates RULES,
  // never grants — so rule 2 (never act on authority without instruction) is
  // structural: a delegate with no rule is never enumerated, so it can never
  // be traded. See the design note in positions.js for why the alternative
  // (a program-wide delegate scan) is impossible on real RPC anyway.
  const rules = await source.list();
  let authorised = 0;
  const fired = [];

  for (const pos of rules) {
    if (exited.has(String(pos.id))) continue;
    // RULE 1: the chain decides, every cycle, whether the keeper still has
    // authority over this exact position. A revoke lands here immediately.
    const live = await readDelegate({ connection, owner: pos.user, mint: pos.mint, keeper: keeperPk });
    if (!live.authorised) {
      // A STAND-DOWN IS A READING, NOT A VERDICT (2026-08-10, the fluffy
      // fire). This used to feed the double-sell blacklist — one line, and it
      // made every rule mortal at birth: readLiveDelegate returns REFUSED for
      // a transient RPC failure or for the seconds after arming when this
      // node hasn't seen the approve yet, and a rule whose FIRST read hit
      // that window was ignored forever. Measured in production: rule 23
      // (+1% target) sat armed with tokens held while price crossed its
      // target by over 400% and the keeper never looked again. Standing down
      // is per-cycle; the chain is re-read next tick. Logged once per id.
      if (!stoodDown.has(String(pos.id))) {
        log(`  [${pos.id}] no live delegate for this keeper (revoked, not yet visible, or RPC failed) — standing down THIS CYCLE, will re-read`);
        stoodDown.add(String(pos.id));
      }
      continue;
    }
    stoodDown.delete(String(pos.id));
    authorised++;
    if (BigInt(live.amount) === 0n) { log(`  [${pos.id}] position is empty — nothing to sell`); continue; }

    try {
      const decimals = pos.decimals ?? 9;
      const { price } = await executablePrice({ mint: pos.mint, amount: live.delegatedAmount, decimals });
      const t = triggerFor(pos, price);
      if (!t.kind) continue;

      log(`  [${pos.id}] ${t.kind.toUpperCase()} at ${price.toExponential(4)} ` +
          `(entry ${pos.entryPrice.toExponential(4)}, target ${t.target.toExponential(4)}, stop ${t.stop.toExponential(4)})`);
      const res = await fireExit({ connection, keeper, keeperPk, pos, live });
      fired.push({ id: pos.id, kind: t.kind, price, expected: res.expected, dryRun: res.dryRun });
      if (!res.dryRun) {
        exited.add(String(pos.id));
        log(`  [${pos.id}] EXIT SENT ${res.signature} -> ~${usd(res.expected)} USDC to the user`);
        if (source.markExited) await source.markExited(pos.id, { kind: t.kind, price, signature: res.signature });
      }
    } catch (e) {
      log(`  [${pos.id}] cycle error: ${e.message}`);
    }
  }
  return { watching: rules.length, authorised, fired };
}

async function main() {
  if (!RPC) throw new Error("need SOLANA_RPC_URL");
  const connection = new Connection(RPC, "confirmed");
  const keeper = loadKeeper();
  if (!DRY_RUN && !keeper) throw new Error("live mode needs SOLANA_KEEPER_KEY");

  const source =
    SOURCE_KIND === "onchain" ? onchainSource({ baseRpc: env("BASE_RPC_URL"), autoTarget: env("AUTOTARGET_ADDRESS") })
    : SOURCE_KIND === "ledger" ? ledgerSource({ file: LEDGER_FILE })
    : deskSource({ base: DESK_URL });

  log("Model B keeper starting", JSON.stringify({
    mode: DRY_RUN ? "DRY_RUN (signs nothing)" : "LIVE",
    source: source.name,
    keeper: keeper ? keeper.publicKey.toBase58() : env("KEEPER_PUBKEY", "(none)"),
    slippageBps: SLIPPAGE_BPS,
  }));
  if (DRY_RUN) log("DRY_RUN is ON — exits are built and printed, never signed.");

  for (;;) {
    try {
      const s = await cycle({ connection, keeper, source });
      if (s.watching) log(`  watching ${s.watching} ruled position(s); ${s.authorised} with live authority on chain`);
    } catch (e) { log(`cycle failed: ${e.message}`); }
    await sleep(POLL_MS);
  }
}

if (require.main === module) main().catch((e) => { console.error("fatal:", e.message); process.exit(1); });

module.exports = { cycle, triggerFor, executablePrice, fireExit };
