// THE V2 KEEPER ENGINE — push, not poll; retire, not repeat; meter every call.
//
// v1 re-read every rule from the chain every tick, forever (see lifecycle.js for
// the measured cost). v2 changes how the keeper LEARNS, never what it may DO:
// the five rules in index.js hold unchanged, and the exit is still the v1
// fireExit.
//
//   - Rules come from the desk (HTTP to our worker, no RPC). An expired or
//     malformed rule is retired before any chain read.
//   - A young rule is read from the chain until it is ARMED (live delegate over
//     a non-empty account) or retired. At most a handful of reads, ever.
//   - An ARMED rule gets ONE account subscription. Revokes, transfers and fills
//     are pushed to the keeper; nothing polls.
//   - Prices come from Jupiter (HTTP, no RPC), for armed rules only.
//   - RULE 1 at the moment it matters: immediately before an exit, the keeper
//     re-reads the delegate from the chain. A push can only make the keeper MORE
//     cautious (retire), never authorise a sale on its own.
//   - Every RPC request is charged to a daily budget (budget.js). An exhausted
//     budget stops RPC work until the next UTC day.
"use strict";

const L = require("./lifecycle");

function createEngine({
  connection,          // a metered Connection (budget.js)
  budget,              // createBudget(...)
  source,              // { name, list(), markExited?() }
  keeperPk,            // base58 public key of the keeper
  readDelegate,        // ({connection, owner, mint, keeper}) -> reading
  decodeAccount,       // (accountInfo, programId) -> decoded SPL account (pure)
  decide,              // positions.decide
  priceOf,             // async (pos, live) -> { price }      (Jupiter, no RPC)
  triggerFor,          // index.triggerFor
  fire,                // async ({pos, live, kind}) -> { dryRun, signature?, expected }
  dryRun = true,
  clock = Date.now,
  log = () => {},
  cfg = L.DEFAULTS,
  maxArmed = 25,
}) {
  const book = new Map();     // id -> { rule, phase, absent, nextCheckAt, subId, ata, programId, live }
  const retired = new Map();  // id -> reason. Never re-admitted while the desk still lists it.
  let overCapLogged = false;

  const armedCount = () => [...book.values()].filter((e) => e.phase === "armed").length;

  async function retire(id, reason, detail = "") {
    const e = book.get(id);
    if (e && e.subId != null) {
      try { await connection.removeAccountChangeListener(e.subId); } catch { /* best effort */ }
    }
    book.delete(id);
    retired.set(id, reason);
    log(`  [${id}] retired: ${reason}${detail ? " — " + detail : ""}`);
  }

  async function arm(id, e, reading) {
    e.phase = "armed"; e.live = reading; e.ata = reading.ata; e.programId = reading.programId;
    if (e.subId != null) return;
    const { PublicKey } = require("@solana/web3.js");
    e.subId = connection.onAccountChange(new PublicKey(e.ata), (info) => onPush(id, info), "confirmed");
    log(`  [${id}] armed: subscribed to ${e.ata}`);
  }

  /// A pushed account update. Pure decode, no RPC. It can retire a rule (revoked,
  /// emptied) but never fires one: firing always re-reads the chain first.
  function onPush(id, accountInfo) {
    const e = book.get(id);
    if (!e || e.phase !== "armed") return;
    let reading;
    try {
      const { PublicKey } = require("@solana/web3.js");
      const acc = decodeAccount(new PublicKey(e.ata), accountInfo, new PublicKey(e.programId));
      reading = { ...decide({ ata: e.ata, owner: e.rule.user, mint: e.rule.mint, acc, keeper: keeperPk }), readError: false };
    } catch { return; } // an undecodable push is not a reading
    const v = L.onReading(e.rule, e, reading, clock(), cfg);
    if (v.retire) return void retire(id, v.retire, "pushed by the chain");
    e.live = reading;
  }

  /// Pull the rule list from the desk and reconcile the book with it.
  async function syncRules() {
    const rules = await source.list();          // throws on an unreachable desk: rules kept intact
    const listed = new Set();
    for (const r of rules) {
      const id = String(r && r.id);
      listed.add(id);
      if (book.has(id) || retired.has(id)) continue;
      const why = L.admit(r, clock(), cfg);
      if (why) { retired.set(id, why); continue; } // never entered the book: zero RPC
      book.set(id, { rule: r, phase: "pending", absent: 0, nextCheckAt: 0, subId: null });
    }
    for (const id of [...book.keys()]) if (!listed.has(id)) await retire(id, L.RETIRE.CANCELLED);
    for (const id of [...retired.keys()]) if (!listed.has(id)) retired.delete(id); // forget what the desk forgot
    return { listed: rules.length, pending: [...book.values()].filter((e) => e.phase === "pending").length, armed: armedCount(), retired: retired.size };
  }

  /// Read pending rules whose next check is due. Bounded by the cap and the budget.
  async function checkPending() {
    const now = clock();
    for (const [id, e] of book) {
      if (e.phase !== "pending" || e.nextCheckAt > now) continue;
      if (!budget.ok()) return;
      if (armedCount() >= maxArmed) {
        if (!overCapLogged) { log(`  armed cap ${maxArmed} reached — new rules wait, unread`); overCapLogged = true; }
        return;
      }
      overCapLogged = false;
      const reading = await readDelegate({ connection, owner: e.rule.user, mint: e.rule.mint, keeper: keeperPk });
      const v = L.onReading(e.rule, e, reading, clock(), cfg);
      e.absent = v.absent;
      if (v.retire) { await retire(id, v.retire); continue; }
      if (v.phase === "armed") {
        try { await arm(id, e, reading); } catch (err) { e.phase = "pending"; e.nextCheckAt = clock() + cfg.recheckMs; log(`  [${id}] could not subscribe: ${err.message}`); }
      } else {
        e.nextCheckAt = clock() + cfg.recheckMs;
      }
    }
  }

  /// Price armed rules (no RPC) and fire the ones that trigger.
  async function priceTick() {
    for (const [id, e] of book) {
      if (e.phase !== "armed") continue;
      if (clock() - e.rule.openedAt > cfg.maxAgeMs) { await retire(id, L.RETIRE.EXPIRED); continue; }
      let t;
      try {
        const { price } = await priceOf(e.rule, e.live);
        t = triggerFor(e.rule, price);
      } catch (err) { log(`  [${id}] price unavailable: ${err.message}`); continue; }
      if (!t.kind) continue;

      // RULE 1: the chain decides, right now, before anything is sold.
      if (!budget.ok()) { log(`  [${id}] ${t.kind} triggered but the RPC budget is spent — not firing blind`); continue; }
      const fresh = await readDelegate({ connection, owner: e.rule.user, mint: e.rule.mint, keeper: keeperPk });
      if (fresh.readError) { log(`  [${id}] ${t.kind} triggered; chain unreadable — will retry`); continue; }
      const v = L.onReading(e.rule, e, fresh, clock(), cfg);
      if (v.retire) { await retire(id, v.retire, "re-read before firing"); continue; }
      e.live = fresh;

      log(`  [${id}] ${t.kind.toUpperCase()} — firing`);
      try {
        const res = await fire({ pos: e.rule, live: fresh, kind: t.kind });
        if (res.dryRun) { await retire(id, L.RETIRE.DRY_RUN_FIRED, `${t.kind}, nothing signed`); continue; }
        await retire(id, L.RETIRE.EXITED, res.signature);
        if (source.markExited) { try { await source.markExited(id, { kind: t.kind, signature: res.signature }); } catch { /* the chain is the record */ } }
      } catch (err) { log(`  [${id}] exit failed: ${err.message} — stays armed`); }
    }
  }

  function status() {
    const by = {};
    for (const r of retired.values()) by[r] = (by[r] || 0) + 1;
    return {
      pending: [...book.values()].filter((e) => e.phase === "pending").length,
      armed: armedCount(),
      retired: by,
      budget: budget.report(),
      dryRun,
    };
  }

  return { syncRules, checkPending, priceTick, onPush, status, _book: book, _retired: retired };
}

module.exports = { createEngine };
