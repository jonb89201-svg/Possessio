// Keeper v2 DoD. Offline: no keys of value, no chain, no Jupiter.
//
// v2 must keep every v1 guarantee (keeper.test.js still runs) and add three:
//   1. a rule that cannot fire is RETIRED, and a retired rule costs nothing;
//   2. nothing polls: armed rules are watched by subscription;
//   3. every RPC request is metered, there is a hard daily ceiling, and
//      QuickNode is refused (Architect directive 2026-10-15).
// The headline check counts RPC calls for v1 and v2 on the same rules.
"use strict";

const assert = require("assert");
const { Keypair, PublicKey } = require("@solana/web3.js");
const { AccountLayout, ACCOUNT_SIZE, TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync, unpackAccount } = require("@solana/spl-token");

const KEEPER = Keypair.generate().publicKey.toBase58();
process.env.KEEPER_PUBKEY = KEEPER;
const K = require("../index");
const B = require("../budget");
const L = require("../lifecycle");
const P = require("../positions");
const { createEngine } = require("../engine");

let pass = 0, fail = 0;
const results = [];
const ta = (name, fn) => results.push(Promise.resolve().then(fn)
  .then(() => { console.log(`  PASS  ${name}`); pass++; })
  .catch((e) => { console.error(`  FAIL  ${name}\n        ${e.message}`); fail++; }));

// ---------- a fake chain with real SPL account bytes ----------
function tokenAccountInfo({ mint, owner, amount, delegate = null, delegatedAmount = 0n }) {
  const data = Buffer.alloc(ACCOUNT_SIZE);
  AccountLayout.encode({
    mint: new PublicKey(mint), owner: new PublicKey(owner), amount: BigInt(amount),
    delegateOption: delegate ? 1 : 0, delegate: new PublicKey(delegate || PublicKey.default),
    state: 1, isNativeOption: 0, isNative: 0n, delegatedAmount: BigInt(delegatedAmount),
    closeAuthorityOption: 0, closeAuthority: PublicKey.default,
  }, data);
  return { data, owner: TOKEN_PROGRAM_ID, lamports: 2039280, executable: false, rentEpoch: 0 };
}
const MINT_INFO = { data: Buffer.alloc(82), owner: TOKEN_PROGRAM_ID, lamports: 1461600, executable: false, rentEpoch: 0 };

class FakeChain {
  constructor() { this.accounts = new Map(); this.subs = new Map(); this.n = 0; this.failNext = 0; }
  async getAccountInfo(pk) {
    if (this.failNext > 0) { this.failNext--; throw new Error("fetch failed (simulated RPC outage)"); }
    return this.accounts.get(pk.toBase58()) || null;
  }
  onAccountChange(pk, cb) { const id = ++this.n; this.subs.set(id, { pk: pk.toBase58(), cb }); return id; }
  async removeAccountChangeListener(id) { this.subs.delete(id); }
  push(addr) { for (const s of this.subs.values()) if (s.pk === addr) s.cb(this.accounts.get(addr), {}); }
}

/// A position as the desk lists it, plus the chain state behind it.
function position(chain, { id, ageMs, now, delegated = true, amount = 1000n, toKeeper = true }) {
  const owner = Keypair.generate().publicKey, mint = Keypair.generate().publicKey;
  chain.accounts.set(mint.toBase58(), MINT_INFO);
  const ata = getAssociatedTokenAddressSync(mint, owner, false, TOKEN_PROGRAM_ID).toBase58();
  chain.accounts.set(ata, tokenAccountInfo({
    mint, owner, amount,
    delegate: delegated ? (toKeeper ? KEEPER : Keypair.generate().publicKey.toBase58()) : null,
    delegatedAmount: delegated ? amount : 0n,
  }));
  return {
    rule: { id: String(id), user: owner.toBase58(), mint: mint.toBase58(), decimals: 6, entryPrice: 1, targetBps: 1000, hasStop: false, stopBps: null, status: "open", openedAt: now - ageMs },
    ata, owner, mint,
  };
}

function rig({ rules, chain, clock, price = () => 1, fire, dailyLimit = 10_000, maxArmed = 25, cfg = L.DEFAULTS }) {
  const budget = B.createBudget({ dailyLimit, clock: () => clock.t });
  const connection = B.meteredConnection(chain, budget);
  const logs = [];
  const fired = [];
  const marked = [];
  const source = { name: "test", list: async () => rules.slice(), markExited: async (id, d) => { marked.push(id); } };
  const engine = createEngine({
    connection, budget, source, keeperPk: KEEPER, dryRun: true, clock: () => clock.t, cfg, maxArmed,
    log: (m) => logs.push(m),
    readDelegate: P.readLiveDelegate, decide: P.decide,
    decodeAccount: (a, info, prog) => unpackAccount(a, info, prog),
    triggerFor: K.triggerFor,
    priceOf: async (pos) => ({ price: price(pos) }),
    fire: fire || (async ({ pos, kind }) => { fired.push({ id: pos.id, kind }); return { dryRun: true }; }),
  });
  return { engine, budget, logs, fired, marked };
}
const MIN = L.MIN, DAY = L.DAY;

/// Drive the engine the way index.js main() does, on a fake clock.
async function run(engine, clock, ms, { tick = 15000, rulesEvery = 5 * MIN, priceEvery = MIN } = {}) {
  let nextRules = 0, nextPrice = 0;
  const end = clock.t + ms;
  for (; clock.t < end; clock.t += tick) {
    if (clock.t >= nextRules) { nextRules = clock.t + rulesEvery; await engine.syncRules(); }
    await engine.checkPending();
    if (clock.t >= nextPrice) { nextPrice = clock.t + priceEvery; await engine.priceTick(); }
  }
}

console.log("Model B keeper v2 — DoD\n");

// ── the endpoint and the meter ─────────────────────────────────────────────
ta("QuickNode is refused, the public RPC is allowed, plain http is refused", () => {
  for (const u of ["https://cool-frosty-sun.solana-mainnet.quiknode.pro/abc/", "https://x.quicknode.com/rpc"])
    assert.throws(() => B.assertAllowedRpc(u), /QuickNode is not allowed/, u);
  assert.strictEqual(B.assertAllowedRpc(B.PUBLIC_RPC), B.PUBLIC_RPC + "/");
  assert.throws(() => B.assertAllowedRpc("http://api.mainnet-beta.solana.com"), /https/);
});

ta("the budget stops at its ceiling, alerts once, and resets the next UTC day", () => {
  const clock = { t: Date.UTC(2026, 9, 15, 12) };
  let alerts = 0;
  const b = B.createBudget({ dailyLimit: 3, clock: () => clock.t, onExhausted: () => alerts++ });
  b.spend("getAccountInfo"); b.spend("getAccountInfo"); b.spend("getAccountInfo");
  assert.throws(() => b.spend("getAccountInfo"), B.BudgetExhausted);
  assert.throws(() => b.spend("getAccountInfo"), B.BudgetExhausted);
  assert.strictEqual(alerts, 1);
  clock.t = Date.UTC(2026, 9, 16, 0, 0, 1);
  b.spend("getAccountInfo");
  assert.strictEqual(b.report().used, 1);
});

ta("every RPC request is metered, and an unmetered method is refused", async () => {
  const chain = new FakeChain();
  const b = B.createBudget({ dailyLimit: 10 });
  const c = B.meteredConnection(chain, b);
  await c.getAccountInfo(Keypair.generate().publicKey);
  c.onAccountChange(Keypair.generate().publicKey, () => {});
  assert.deepStrictEqual(b.report().byMethod, { getAccountInfo: 1, onAccountChange: 1 });
  await c.removeAccountChangeListener(1);          // removing is not a request
  chain.getRecentPerformanceSamples = async () => [];
  assert.throws(() => c.getRecentPerformanceSamples(), /unmetered RPC method/);
});

// ── reading the chain: a failure is not a reading ──────────────────────────
ta("an RPC failure is flagged readError; a missing account is a confirmed reading", async () => {
  const chain = new FakeChain();
  const now = Date.now();
  const p = position(chain, { id: 1, ageMs: 0, now });
  chain.failNext = 1;
  const failed = await P.readLiveDelegate({ connection: chain, owner: p.rule.user, mint: p.rule.mint, keeper: KEEPER });
  assert.strictEqual(failed.authorised, false); assert.strictEqual(failed.readError, true);
  chain.accounts.delete(p.ata);
  const missing = await P.readLiveDelegate({ connection: chain, owner: p.rule.user, mint: p.rule.mint, keeper: KEEPER });
  assert.strictEqual(missing.authorised, false); assert.strictEqual(missing.readError, false);
});

// ── the life cycle ─────────────────────────────────────────────────────────
ta("lifecycle: malformed and expired rules are retired before any read", () => {
  const now = Date.now();
  assert.strictEqual(L.admit({ id: "1" }, now), L.RETIRE.MALFORMED);
  const r = { id: "1", user: "u", mint: "m", entryPrice: 1, targetBps: 100, hasStop: false, openedAt: now - 31 * DAY };
  assert.strictEqual(L.admit(r, now), L.RETIRE.EXPIRED);
  assert.strictEqual(L.admit({ ...r, openedAt: now }, now), null);
});

ta("lifecycle: an RPC error never retires; confirmed absence past the grace does", () => {
  const now = Date.now();
  const r = { id: "1", user: "u", mint: "m", entryPrice: 1, targetBps: 100, hasStop: false, openedAt: now - 40 * MIN };
  let s = { phase: "pending", absent: 0 };
  for (let i = 0; i < 10; i++) s = { ...s, ...L.onReading(r, s, { readError: true, authorised: false, amount: "0" }, now) };
  assert.strictEqual(s.retire, null, "ten failed reads must not retire a rule");
  s = { ...s, ...L.onReading(r, s, { readError: false, authorised: false, amount: "0" }, now) };
  assert.strictEqual(s.retire, null, "one confirmed absence is not enough");
  s = { ...s, ...L.onReading(r, s, { readError: false, authorised: false, amount: "0" }, now) };
  assert.strictEqual(s.retire, L.RETIRE.NEVER_ARMED);
  const young = { ...r, openedAt: now - 5 * MIN };
  let y = { phase: "pending", absent: 5 };
  y = L.onReading(young, y, { readError: false, authorised: false, amount: "0" }, now);
  assert.strictEqual(y.retire, null, "inside the grace window absence is only a reading (the rule-23 lesson)");
});

ta("lifecycle: an authorised but EMPTY account is retired; an armed rule that loses authority is revoked", () => {
  const now = Date.now();
  const r = { id: "1", user: "u", mint: "m", entryPrice: 1, targetBps: 100, hasStop: false, openedAt: now };
  assert.strictEqual(L.onReading(r, { phase: "pending" }, { readError: false, authorised: true, amount: "0" }, now).retire, L.RETIRE.EMPTY);
  assert.strictEqual(L.onReading(r, { phase: "armed" }, { readError: false, authorised: false, amount: "5" }, now).retire, L.RETIRE.REVOKED);
});

// ── the engine ─────────────────────────────────────────────────────────────
ta("the 48 stale desk rules of 2026-10-15 are retired with ZERO RPC calls, and stay that way for a day", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const rules = Array.from({ length: 48 }, (_, i) => position(chain, { id: 100 + i, ageMs: (60 + (i % 6)) * DAY, now: clock.t, amount: 0n }).rule);
  const { engine, budget } = rig({ rules, chain, clock });
  await run(engine, clock, DAY);
  assert.strictEqual(budget.report().total, 0, "stale rules must cost nothing: " + JSON.stringify(budget.report()));
  assert.deepStrictEqual(engine.status().retired, { expired: 48 });
});

ta("an armed rule is watched by ONE subscription, and a revoke pushed by the chain retires it with no read", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const p = position(chain, { id: 1, ageMs: MIN, now: clock.t });
  const { engine, budget } = rig({ rules: [p.rule], chain, clock, price: () => 1 });
  await run(engine, clock, 10 * MIN);
  assert.strictEqual(engine.status().armed, 1);
  assert.strictEqual(chain.subs.size, 1);
  const before = budget.report().used;
  chain.accounts.set(p.ata, tokenAccountInfo({ mint: p.mint, owner: p.owner, amount: 1000n }));   // delegate revoked
  chain.push(p.ata);
  await new Promise((r) => setImmediate(r));
  assert.strictEqual(engine.status().armed, 0);
  assert.deepStrictEqual(engine.status().retired, { revoked: 1 });
  assert.strictEqual(chain.subs.size, 0, "the subscription is removed with the rule");
  assert.strictEqual(budget.report().used, before, "a pushed revoke costs no RPC");
});

ta("DRY_RUN: a trigger is fired once (after a fresh read) and the rule retires, so it can never loop", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const p = position(chain, { id: 7, ageMs: MIN, now: clock.t });
  let px = 1;
  const r = rig({ rules: [p.rule], chain, clock, price: () => px });
  await run(r.engine, clock, 5 * MIN);
  const readsBefore = r.budget.report().byMethod.getAccountInfo || 0;
  px = 2;   // +100% against a +10% target
  await run(r.engine, clock, 30 * MIN);
  assert.deepStrictEqual(r.fired, [{ id: "7", kind: "target" }], "fired exactly once");
  assert.ok((r.budget.report().byMethod.getAccountInfo || 0) > readsBefore, "rule 1: the delegate is re-read before firing");
  assert.deepStrictEqual(r.engine.status().retired, { "dry-run-fired": 1 });
});

ta("LIVE: a confirmed exit retires the rule and reports it to the desk", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const p = position(chain, { id: 8, ageMs: MIN, now: clock.t });
  let px = 1;
  const r = rig({ rules: [p.rule], chain, clock, price: () => px, fire: async () => ({ dryRun: false, signature: "SIG" }) });
  await run(r.engine, clock, 3 * MIN);
  px = 2;
  await run(r.engine, clock, 3 * MIN);
  assert.deepStrictEqual(r.engine.status().retired, { exited: 1 });
  assert.deepStrictEqual(r.marked, ["8"]);
});

ta("a trigger never fires if the fresh read shows the delegate gone, and never fires blind on an RPC error", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const a = position(chain, { id: 1, ageMs: MIN, now: clock.t });
  const b = position(chain, { id: 2, ageMs: MIN, now: clock.t });
  let px = 1;
  const r = rig({ rules: [a.rule, b.rule], chain, clock, price: () => px });
  await run(r.engine, clock, 3 * MIN);
  assert.strictEqual(r.engine.status().armed, 2);
  chain.accounts.set(a.ata, tokenAccountInfo({ mint: a.mint, owner: a.owner, amount: 1000n }));  // revoked, not pushed
  px = 2;
  chain.failNext = 2;   // first fresh read (a) fails? order: a then b
  await r.engine.priceTick();
  assert.deepStrictEqual(r.fired, [], "an RPC error at trigger time must not fire");
  await r.engine.priceTick();
  assert.deepStrictEqual(r.fired.map((f) => f.id), ["2"], "only the rule whose delegate is still live fires");
  assert.strictEqual(r.engine.status().retired.revoked, 1);
});

ta("a never-armed rule costs a bounded handful of reads, then is retired", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const p = position(chain, { id: 3, ageMs: 0, now: clock.t, delegated: false });
  const r = rig({ rules: [p.rule], chain, clock });
  await run(r.engine, clock, 3 * 60 * MIN);
  assert.deepStrictEqual(r.engine.status().retired, { "never-armed": 1 });
  const reads = r.budget.report().byMethod.getAccountInfo || 0;
  // mint read once (cached) + one ATA read per 2-min check inside the 30-min grace, plus the confirming one
  assert.ok(reads <= 20, `reads for a never-armed rule must be bounded, got ${reads}`);
});

ta("the armed cap holds: beyond it, new rules wait and are not even read", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const a = position(chain, { id: 1, ageMs: MIN, now: clock.t });
  const b = position(chain, { id: 2, ageMs: MIN, now: clock.t });
  const r = rig({ rules: [a.rule, b.rule], chain, clock, maxArmed: 1 });
  await run(r.engine, clock, 10 * MIN);
  assert.strictEqual(r.engine.status().armed, 1);
  assert.strictEqual(r.engine.status().pending, 1);
  assert.strictEqual(r.budget.report().byMethod.getAccountInfo, 2, "only the first rule's mint + account were read");
});

ta("an exhausted budget stops all RPC work instead of overspending", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const rules = Array.from({ length: 10 }, (_, i) => position(chain, { id: i + 1, ageMs: 0, now: clock.t, delegated: false }).rule);
  const r = rig({ rules, chain, clock, dailyLimit: 15 });
  await run(r.engine, clock, 60 * MIN);
  assert.ok(r.budget.report().used <= 15, "never above the ceiling: " + r.budget.report().used);
  assert.ok(r.budget.report().refused <= 2, "an exhausted keeper goes quiet instead of knocking: " + r.budget.report().refused + " refused");
});

ta("a rule the desk stops listing is dropped and its subscription removed", async () => {
  const clock = { t: Date.now() };
  const chain = new FakeChain();
  const p = position(chain, { id: 1, ageMs: MIN, now: clock.t });
  const rules = [p.rule];
  const r = rig({ rules, chain, clock });
  await run(r.engine, clock, 3 * MIN);
  assert.strictEqual(chain.subs.size, 1);
  rules.length = 0;
  await run(r.engine, clock, 6 * MIN);
  assert.strictEqual(chain.subs.size, 0);
  assert.deepStrictEqual(r.engine.status().retired, {}, "a forgotten rule is forgotten, not kept as retired");
});

// ── the headline: v1 vs v2 on the same rules ───────────────────────────────
ta("COST: v1 vs v2 on the 48 stale rules + 10 live ones, measured per hour", async () => {
  const now = Date.now();
  const chain = new FakeChain();
  const stale = Array.from({ length: 48 }, (_, i) => position(chain, { id: 100 + i, ageMs: 61 * DAY, now, amount: 0n }).rule);
  const armed = Array.from({ length: 5 }, (_, i) => position(chain, { id: 200 + i, ageMs: MIN, now }).rule);
  const dead = Array.from({ length: 5 }, (_, i) => position(chain, { id: 300 + i, ageMs: MIN, now, delegated: false }).rule);
  const rules = [...stale, ...armed, ...dead];

  // v1: cycle() every 5 s (its old POLL_MS default) for one hour.
  const b1 = B.createBudget({ dailyLimit: 1e9 });
  const c1 = B.meteredConnection(chain, b1);
  const src = { name: "t", list: async () => rules.slice() };
  for (let i = 0; i < 720; i++) await K.cycle({ connection: c1, keeper: null, source: src, readDelegate: P.readLiveDelegate });
  const v1 = b1.report().used;

  // v2: the engine for the same hour, then the next 23.
  const clock = { t: now };
  const r = rig({ rules, chain, clock, price: () => 1 });
  await run(r.engine, clock, 60 * MIN);
  const v2h1 = r.budget.report().total;
  await run(r.engine, clock, 23 * 60 * MIN);
  const v2day = r.budget.report().total;
  console.log(`        v1: ${v1} RPC calls in 1 h  (x24 = ${v1 * 24}/day)`);
  console.log(`        v2: ${v2h1} RPC calls in 1 h, ${v2day} in 24 h`);
  assert.ok(v1 > 40000, "v1 should show the read storm");
  assert.ok(v2day < 150, "v2 should cost tens of calls a day, got " + v2day);
  assert.ok(v2day - v2h1 < 10, "after the first hour v2 is quiet: " + (v2day - v2h1) + " calls in hours 2-24");
});

Promise.all(results).then(() => {
  console.log(`\n${pass} checks passed${fail ? `, ${fail} FAILED` : ""}`);
  process.exit(fail ? 1 : 0);
});
