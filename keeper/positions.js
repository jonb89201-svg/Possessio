// Where the keeper learns what it is allowed to do.
//
// TWO SOURCES, deliberately pluggable, because the rule-ledger decision is the
// Architect's and this loop must not block on it:
//
//   onchain : AutoTarget intents on Base — the target and the un-removable
//             stop are read from the chain, which is the shape the product
//             claims. Requires the desk contracts deployed.
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
///   { id, user, mint, amount, entryPrice, targetBps, stopBps, decimals }

/* ───────────────────────── on-chain (AutoTarget) ───────────────────────── */

function onchainSource({ baseRpc, autoTarget }) {
  const AT_ABI = [
    { type: "function", name: "intentCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
    { type: "function", name: "intents", stateMutability: "view",
      inputs: [{ name: "id", type: "uint256" }],
      outputs: [
        { name: "user", type: "address" }, { name: "tokenRef", type: "bytes32" },
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
        const status = Number(r[6]), chainTag = Number(r[2]);
        if (status !== 1) continue;            // 1 = Open; anything else is done
        if (chainTag !== 101) continue;        // Solana intents only
        out.push({
          id: i.toString(),
          user: null,                          // resolved from the delegate scan
          mint: enc(Buffer.from(r[1].slice(2), "hex")),
          entryPrice: Number(r[3]) / 1e18,
          targetBps: Number(r[4]),
          stopBps: Number(r[5]),
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
  const { getAssociatedTokenAddress, getAccount } = require("@solana/spl-token");
  try {
    const ata = await getAssociatedTokenAddress(
      new PublicKey(mint), new PublicKey(owner), false
    );
    const acc = await getAccount(connection, ata);
    return decide({ ata, owner, mint, acc, keeper });
  } catch {
    return REFUSED(owner, mint);
  }
}

module.exports = { onchainSource, ledgerSource, readLiveDelegate, decide };
