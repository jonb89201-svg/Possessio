// Where the keeper learns what it is allowed to do.
//
// TWO SOURCES, deliberately pluggable, because the rule-ledger decision is the
// Architect's and this loop must not block on it:
//
//   onchain : AutoTarget intents on Base — the target and the un-removable
//             stop are read from the chain, which is the shape the product
//             claims. Requires the desk contracts deployed. The holder's Solana
//             pubkey arrives as Intent.ownerRef; before that field existed this
//             source could not resolve WHOSE account to read, and was unusable.
//   ledger  : a local/worker record — ships with no deploy, but the rule is
//             then a promise from a server rather than a fact on a chain.
//
// Either way the source yields RULES, and rules are the only work list the
// keeper has. It never enumerates the grants it holds — see the design note
// above readLiveDelegate for why that is both impossible on real RPC and the
// safer shape regardless.
"use strict";

const { PublicKey } = require("@solana/web3.js");

/// A position the keeper may act on. Every field the loop needs to decide,
/// and nothing it does not.
///   { id, user, mint, amount, entryPrice, targetBps, hasStop, stopBps, decimals }
/// `hasStop` false means the position has NO stop — the keeper never computes
/// or compares a threshold for it (Architect ratification 2026-08-01).

/* ───────────────────────── on-chain (AutoTarget) ───────────────────────── */

function onchainSource({ baseRpc, autoTarget }) {
  const AT_ABI = [
    { type: "function", name: "intentCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
    { type: "function", name: "intents", stateMutability: "view",
      inputs: [{ name: "id", type: "uint256" }],
      outputs: [
        { name: "user", type: "address" }, { name: "ownerRef", type: "bytes32" },
        { name: "tokenRef", type: "bytes32" },
        { name: "chainTag", type: "uint32" }, { name: "entryPrice", type: "uint256" },
        { name: "targetBps", type: "uint16" }, { name: "stopBps", type: "uint16" },
        { name: "status", type: "uint8" }, { name: "exitKind", type: "uint8" },
        { name: "usdcReturned", type: "uint256" },
      ] },
  ];
  const { createPublicClient, http } = require("viem");
  const { base } = require("viem/chains");
  const pub = createPublicClient({ chain: base, transport: http(baseRpc) });
  const bs58 = require("bs58");
  const enc = bs58.default ? bs58.default.encode : bs58.encode;

  return {
    name: "onchain(AutoTarget)",
    async list() {
      const n = await pub.readContract({ address: autoTarget, abi: AT_ABI, functionName: "intentCount" });
      const out = [];
      // Walk backwards: recent intents are the live ones, and an old ledger
      // should never make the keeper slow to react to a new position.
      for (let i = n; i > 0n && out.length < 200; i--) {
        const r = await pub.readContract({ address: autoTarget, abi: AT_ABI, functionName: "intents", args: [i] });
        // Destructured by name rather than index: the struct gained ownerRef,
        // and every positional read after slot 0 shifted. Indices are exactly
        // the kind of silent breakage a struct change causes.
        const [, ownerRef, tokenRef, chainTagRaw, entryPriceRaw, targetBps, stopBps, status] = r;
        if (Number(status) !== 1) continue;              // 1 = Open; anything else is done
        if (Number(chainTagRaw) !== 101) continue;       // Solana intents only
        // ownerRef IS the holder's Solana pubkey. The contract refuses to record
        // a Solana intent without one, so this is never null on a live intent —
        // which is the whole reason the field exists.
        out.push({
          id: i.toString(),
          user: enc(Buffer.from(ownerRef.slice(2), "hex")),
          mint: enc(Buffer.from(tokenRef.slice(2), "hex")),
          entryPrice: Number(entryPriceRaw) / 1e18,
          targetBps: Number(targetBps),
          // The on-chain AutoTarget intent always carries a stop, so an
          // on-chain position always has one. The desk ledger is where absence
          // can occur.
          hasStop: true,
          stopBps: Number(stopBps),
        });
      }
      return out;
    },
  };
}

/* ─────────────────────────── local ledger ─────────────────────────── */

function ledgerSource({ file }) {
  const fs = require("fs");
  return {
    name: `ledger(${file})`,
    async list() {
      try {
        const raw = JSON.parse(fs.readFileSync(file, "utf8"));
        return (raw.positions || []).filter((p) => p.status === "open");
      } catch { return []; }
    },
    async markExited(id, detail) {
      try {
        const raw = JSON.parse(fs.readFileSync(file, "utf8"));
        const p = (raw.positions || []).find((x) => String(x.id) === String(id));
        if (p) { p.status = "exited"; p.exit = detail; }
        fs.writeFileSync(file, JSON.stringify(raw, null, 2));
      } catch { /* a ledger write failure must never block an exit */ }
    },
  };
}

/* ─────────────────────────── desk (worker) ─────────────────────────── */

/// What the console's trading desk actually wrote. This is the source that
/// makes the desk work end to end: the human picks a coin and a target, the
/// mini-app signs the rule, the worker verifies that signature and stores it,
/// and the keeper reads it here.
///
/// The worker verified an Ed25519 signature from the owner before storing the
/// row, so `user` is a wallet that really did author this instruction — not a
/// claim in a request body. The keeper still checks the chain for a live
/// delegate before acting; a rule alone has never been authority.
function deskSource({ base, timeoutMs = 10000 }) {
  const url = String(base).replace(/\/+$/, "") + "/api/desk/rules";
  return {
    name: `desk(${url})`,
    async list() {
      // An unreachable desk must not look like a desk with no positions:
      // silently returning [] would stand every stop down during an outage.
      // Throw instead — cycle() logs it and retries next tick, rules intact.
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const res = await fetch(url, { signal: ctl.signal, headers: { accept: "application/json" } });
        if (!res.ok) throw new Error(`desk returned ${res.status}`);
        const body = await res.json();
        return (body.positions || []).filter((p) => p.status === "open");
      } finally { clearTimeout(t); }
    },
    async markExited(id, detail) {
      // Best-effort. A bookkeeping failure must never block or reverse an exit
      // that already landed on chain; the in-run `exited` set stops a second
      // sell regardless of whether this write succeeds.
      try {
        await fetch(url, {
          method: "PATCH", headers: { "content-type": "application/json" },
          body: JSON.stringify({ id, ...detail }),
        });
      } catch { /* the chain is the record of truth, not this */ }
    },
  };
}

/* ─────────────── live authority: what MAY I touch, right now? ─────────────── */

// DESIGN NOTE, learned the hard way against live infrastructure: the obvious
// implementation here was a program-wide scan — getProgramAccounts on the SPL
// Token program, memcmp'd on the delegate field — to enumerate everything
// granted to this keeper. It does not work. Providers exclude the Token
// program from secondary indexes ("excluded from account secondary indexes;
// this RPC method unavailable for key"), because scanning every token account
// on Solana is ruinously expensive. No amount of retrying fixes it.
//
// The replacement is better anyway. The keeper reads ONE account per position
// it already has a rule for: a targeted, always-available, cheap lookup. And
// it makes rule 2 STRUCTURAL rather than a warning — a delegate with no rule
// is never even looked at, because the loop iterates rules, not grants. The
// keeper cannot act on authority it never enumerates.

/// THE WHOLE AUTHORISATION RULE, in one place: the keeper may act only if the
/// account's own delegate field names THIS keeper, and the grant is not spent.
///
/// It is a pure function of a decoded SPL token account so that every path
/// which decides "may I sell this?" decides it the same way — the live read
/// below, and the certification harness, which proves the positive branch by
/// simulating the real grant and decoding the post-state. If the rule lived
/// inline in the reader, the harness would have to re-implement it, and a test
/// that re-implements the rule cannot test the rule.
function decide({ ata, owner, mint, acc, keeper }) {
  const delegate = acc.delegate ? acc.delegate.toBase58() : null;
  return {
    ata: ata ? ata.toString() : null,
    owner, mint,
    amount: acc.amount.toString(),
    delegate,
    delegatedAmount: acc.delegatedAmount.toString(),
    authorised: delegate === keeper && acc.delegatedAmount > 0n,
  };
}

/// Refused: no account, no authority. Every failure to READ must land here
/// rather than throwing, because an RPC hiccup must stand the keeper down, not
/// crash the loop and leave other positions unwatched.
const REFUSED = (owner, mint) =>
  ({ ata: null, owner, mint, amount: "0", delegate: null, delegatedAmount: "0", authorised: false });

/// The live, on-chain delegate state for ONE position. Re-read every cycle, so
/// a user's revoke takes effect immediately rather than at the next restart.
async function readLiveDelegate({ connection, owner, mint, keeper }) {
  const {
    getAssociatedTokenAddress, getAccount, TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID,
  } = require("@solana/spl-token");
  try {
    const mintPk = new PublicKey(mint);
    // WHICH TOKEN PROGRAM OWNS THIS MINT — measured, never assumed.
    //
    // This defaulted to the classic SPL Token program, and that was silently
    // fatal: the ATA is derived FROM the token program id, so a Token-2022
    // mint resolves to a completely different address. getAccount then throws
    // TokenAccountNotFoundError, the catch below turns it into REFUSED, and
    // the keeper stands down reporting "not authorised" for a position that is
    // perfectly well authorised. No error surfaces anywhere.
    //
    // Measured 2026-08-01 against the live radar feed: 25 of 25 picks are
    // Token-2022 (TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb), zero classic.
    // pump.fun mints Token-2022 now, so the default was wrong for EVERY
    // position the desk can currently open.
    const info = await connection.getAccountInfo(mintPk);
    if (!info) return REFUSED(owner, mint);
    const programId = info.owner;
    // Anything that is not a token program cannot hold a delegate; refusing is
    // the safe branch and keeps a malformed rule from reaching getAccount.
    if (!programId.equals(TOKEN_PROGRAM_ID) && !programId.equals(TOKEN_2022_PROGRAM_ID)) {
      return REFUSED(owner, mint);
    }
    const ata = await getAssociatedTokenAddress(
      mintPk, new PublicKey(owner), false, programId
    );
    const acc = await getAccount(connection, ata, undefined, programId);
    return decide({ ata, owner, mint, acc, keeper });
  } catch {
    return REFUSED(owner, mint);
  }
}

module.exports = { onchainSource, ledgerSource, deskSource, readLiveDelegate, decide };
