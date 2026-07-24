// xtrade MCP server - the Trading Agent, build-mode by default.
// Wires the terminal-proven constitution modules (config/modes/caps/
// selection/sessiongate/method/ledger) to the Jupiter adapter.
//
// NON-PROVEN end-to-end in the sandbox: the Jupiter calls are network-
// blocked here. The GATING logic (F-1, session/rug/entry gates, caps,
// mode triple-gate) is unit-proven (test/constitution.test.js).
// The Architect proves the live quote->build->sign->land path on device.
//
// Activation is bound by RULEBOOK Sec4: this ships build-mode only;
// ALLOW_HOT is not a discussable sentence until the wave's key ceremony
// creates the dedicated trading wallet.
"use strict";
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");

const { LAW, TUNE, runtimeEnv } = require("./config");
const { resolveMode } = require("./modes");
const { checkCaps } = require("./caps");
const { assertContractAddress, rugGate, RefusalError } = require("./selection");
const { sessionGate } = require("./sessiongate");
const { entryOk, exitTrigger } = require("./method");
const ledger = require("./ledger");
const jupiter = require("./adapters/jupiter");
const factsLayer = require("./facts");

// W-2 CLOSED (AUDIT 2026-07-14): gate facts are no longer tool arguments.
// facts.js gathers them SERVER-SIDE (Solana RPC / DexScreener / radar
// tape), each tagged with source+basis+status. Caller-supplied facts are
// UNTRUSTED HINTS kept for schema continuity; gates run on fetched facts
// only, and any divergence is written to the ledger (factsDivergence).
// The old FACTS_VERIFIED_ON_DEVICE constant is GONE: the hot-path facts
// precondition is now computed PER CALL (facts.hotFactsGuard - true only
// when every gate-critical fact was chain-read, source class 1/2, on that
// call). There is no constant to flip; only a real chain-read source for
// every fact can satisfy it.

const rt = runtimeEnv();
const nowIso = () => new Date().toISOString();
const day = () => nowIso().slice(0, 10);
const text = (o) => ({ content: [{ type: "text", text: typeof o === "string" ? o : JSON.stringify(o, null, 2) }] });

const server = new McpServer({ name: "xtrade", version: "0.1.0" });

// --- read-only: what is wired and enabled right now ---
server.tool("list_supported", "Chains, backends, modes, and caps in force.", {}, async () => text({
  scope: { venue: LAW.venue, chain: LAW.chain, preDexOnly: LAW.preDexOnly },
  modes: { build: "always on", hot: rt.allowHot && rt.hasSigner ? "gated (needs per-call confirm)" : "OFF (pre key-ceremony)" },
  caps: { maxNotionalUsd: rt.maxNotionalUsd, maxSlippageBps: rt.maxSlippageBps,
          maxTradesPerDay: rt.maxTradesPerDay, maxDailyExposureUsd: rt.maxDailyExposureUsd },
  method: { entryAgeMin: [LAW.entryAgeMinLo, LAW.entryAgeMinHi], takeProfitMc: LAW.takeProfitMc,
            stopLossMc: LAW.stopLossMc, timeStopMin: LAW.timeStopMin },
  tuning: { sessionGateCutoff: TUNE.sessionGateCutoff, rugMaxCreatorPct: TUNE.rugMaxCreatorPct,
            entryMcBand: [TUNE.entryMcBandLo, TUNE.entryMcBandHi] },
}));

// --- Sec0 session gate (pure, local) ---
server.tool("session_gate", "Is today playable? trailingVol vs 7d avg.",
  { trailingVol: z.number(), avg7d: z.number() },
  async (a) => text(sessionGate(a, TUNE.sessionGateCutoff)));

// --- Sec1 method check (pure, local): entry + exit given facts ---
server.tool("check_method", "Entry admissibility and/or exit trigger for supplied facts.",
  { onDexScreener: z.boolean().optional(), ageMin: z.number().optional(), mc: z.number().optional(),
    elapsedMin: z.number().optional(), phase: z.enum(["entry", "exit"]) },
  async (a) => text(a.phase === "entry"
    ? entryOk(a, LAW, TUNE)
    : exitTrigger(a, LAW)));

// --- Sec5 ledger stats ---
server.tool("get_ledger_stats",
  "Today's cap usage (filled+built) and performance truth (filled only) vs caps.", {},
  async () => text({ ...ledger.todayStats(rt.ledgerPath, day()),
    caps: { maxTradesPerDay: rt.maxTradesPerDay, maxDailyExposureUsd: rt.maxDailyExposureUsd } }));

// ─────────────────────────────────────────────────────────────────────────────
// THE CONSTITUTION GATES (F-1, Sec0, Sec2, Sec1, Sec3) — SINGLE-SOURCED.
//
// XT-3 (audit 2026-07-23): this pipeline used to live INSIDE build_trade only.
// execute_trade — the path that will one day hold a signer — carried no gate of
// its own and was safe purely because it hard-refuses at the end. That is a trap
// for whoever wires the signer: nothing structurally forced the gates to be
// re-applied, and the gates were not even visible in that function to be missed.
// Both paths now call THIS, so a signer cannot be wired past the constitution
// without deleting this call outright — a deliberate act, not an oversight.
//
// Returns { blocked: <tool response> } if any gate stops the trade (already
// ledgered by skip()/refuse()), else the verified facts for the caller to use.
// Order is load-bearing and matches RULEBOOK Sec0-3; do not reorder.
async function runConstitutionGates(a) {
  // 1. F-1 (absolute): contract address only, never a ticker.
  const mint = assertContractAddress(a.tokenAddress);

  // 2. FACTS LAYER (W-2): gather every gate fact server-side.
  //    Fail-closed - an unfetchable fact is a refusal, never a
  //    silent downgrade to the caller's word.
  const g = await factsLayer.gatherFacts(mint, { fetchImpl: fetch, env: process.env });
  const factsDivergence = factsLayer.divergence(a.facts, g);
  const meta = {
    factsSource: g.allFetched ? "chain-read" : "chain-read-incomplete",
    factsDivergence,
  };

  // 3. Sec0 session gate - live reading, or the documented
  //    ARCHITECT-ONLY override; no reading -> REFUSE (fail-closed).
  const sg = g.facts.sessionGate;
  if (sg.status === "UNAVAILABLE")
    return { blocked: refuse("session-gate", sg.basis, a, { ...meta, sessionGate: sg }) };
  if (sg.play !== true)
    return { blocked: skip("session-gate", sg.basis, a, { ...meta, sessionGate: sg }) };

  // 4. Fact completeness: every gate-critical fact must have fetched.
  if (!g.allFetched)
    return { blocked: refuse("facts", factsLayer.refusalReason(g), a, { ...meta, sessionGate: sg }) };

  // 5. Sec2 rug gate - on FETCHED facts only.
  const rg = rugGate(g.gateFacts, TUNE);
  if (!rg.ok) return { blocked: skip("rug-gate", rg.fails.join("; "), a, { ...meta, sessionGate: sg, rugGate: rg }) };

  // 6. Sec1 entry - on FETCHED facts only.
  const en = entryOk(g.gateFacts, LAW, TUNE);
  if (!en.ok) return { blocked: skip("entry", en.fails.join("; "), a, { ...meta, sessionGate: sg, rugGate: rg }) };

  // 7. Sec3 caps (server-enforced against the ledger).
  const st = ledger.todayStats(rt.ledgerPath, day());
  const cap = checkCaps({ notionalUsd: a.notionalUsd, slippageBps: a.slippageBps, ...st }, rt);
  if (!cap.ok) return { blocked: refuse("caps", cap.fails.join("; "), a, { ...meta, sessionGate: sg, rugGate: rg }) };

  return { mint, g, sg, rg, en, meta, factsDivergence };
}

// --- build_trade: the full pipeline, in order. Returns UNSIGNED tx. ---
server.tool("build_trade",
  "Validate F-1 + all gates + caps on SERVER-FETCHED facts (chain/API reads, W-2), " +
  "then return an UNSIGNED Solana swap tx. Caller facts are untrusted hints; " +
  "divergence from fetched facts is ledgered.",
  { tokenAddress: z.string(), notionalUsd: z.number(), slippageBps: z.number(),
    userPublicKey: z.string(),
    facts: z.object({
      // trade parameters (still required - they shape the quote, not the gates)
      inputMint: z.string(), amountAtomic: z.string(),
      // UNTRUSTED HINTS, kept for schema continuity. The gates NEVER run
      // on these; they are compared against the server-fetched facts and
      // any divergence lands in the ledger row (factsDivergence).
      onDexScreener: z.boolean().optional(), ageMin: z.number().optional(),
      mc: z.number().optional(), mintRenounced: z.boolean().optional(),
      lpLockedOrBurned: z.boolean().optional(), creatorHoldingPct: z.number().optional(),
      trailingVol: z.number().optional(), avg7d: z.number().optional(),
    }) },
  async (a) => {
    const f = a.facts;
    try {
      // Sec0-Sec3, single-sourced (see runConstitutionGates). Any stop returns
      // the caller-facing response already ledgered; only a clean pass falls
      // through to the quote/build below.
      const gate = await runConstitutionGates(a);
      if (gate.blocked) return gate.blocked;
      const { mint, g, factsDivergence } = gate;

      // 8. Jupiter quote + unsigned build (DEVICE-VERIFY: network here).
      const q = await jupiter.quote(rt, {
        inputMint: f.inputMint, outputMint: mint,
        amountAtomic: f.amountAtomic, slippageBps: Math.min(a.slippageBps, rt.maxSlippageBps) });
      const built = await jupiter.buildSwapTx(rt, { quoteResponse: q, userPublicKey: a.userPublicKey });

      // W-1: an unsigned build is NOT a fill. "built" consumes the daily
      // cap budget (conservative) but stays out of net-return truth.
      ledger.append(rt.ledgerPath, ledger.record({
        ts: nowIso(), tokenAddress: mint, outcome: "built", entryMc: g.gateFacts.mc,
        factsSource: "chain-read", factsDivergence,
        sessionGate: sg, rugGate: rg, notionalUsd: a.notionalUsd, reason: "build payload issued" }));
      return text({ mode: "build", unsignedTx: built.unsignedTxBase64,
        note: "UNSIGNED. Sign in your wallet / dedicated trading wallet.",
        factsSource: "chain-read",
        factsVerifiedOnDevice: g.allChainRead, // per-call, never a constant
        ...(factsDivergence.length ? { factsDivergence } : {}),
        quote: { outAmount: q.outAmount, priceImpactPct: q.priceImpactPct } });
    } catch (e) {
      if (e instanceof RefusalError) return refuse("F-1", e.message, a);
      return text({ error: String(e.message || e),
        note: "Pre-submission failure - nothing signed, nothing charged." });
    }
  });

// --- execute_trade: hot mode, triple-gated. Downgrades to build if any gate missing. ---
server.tool("execute_trade",
  "HOT mode: sign+submit. Requires ALLOW_HOT + signer + confirm; else returns the build payload.",
  { tokenAddress: z.string(), notionalUsd: z.number(), slippageBps: z.number(),
    userPublicKey: z.string(), confirm: z.boolean().optional(), facts: z.any() },
  async (a) => {
    const m = resolveMode("hot", rt, a.confirm === true);
    if (m.mode !== "hot") {
      return text({ refused: true, reason: m.reason,
        next: "Call build_trade for the unsigned payload." });
    }
    // W-2 hard guard, checked BEFORE any signer question - now COMPUTED
    // PER CALL, not a constant. hotFactsGuard passes ONLY when every
    // gate-critical fact was chain-read (source class 1/2: Solana RPC /
    // DexScreener) on this very call. Caller assertions can never satisfy
    // it, and neither can radar-tape enrichment (class 3). ageMin/mc are
    // now chain-read too (bonding-curve PDA decode + signature-walk in
    // facts.js), so a live pre-DEX token CAN satisfy this guard - but
    // sessionGate (Sec0) still refuses upstream until the radar grows a
    // sessions writer, and Sec4 steps 3-5 (device verify, key ceremony,
    // ALLOW_HOT) remain open. Correct and intended: this guard passing
    // does NOT make anything hot by itself.
    // XT-3: the FULL constitution (F-1, Sec0 session, fact completeness, Sec2
    // rug, Sec1 entry, Sec3 caps) runs HERE, on the hot path, before any signer
    // question — not just inside build_trade. Whoever wires the signer below
    // inherits every gate by construction; skipping them now requires deleting
    // this call. Reuses the gathered facts, so this costs no extra fetch.
    let gates;
    try {
      gates = await runConstitutionGates(a);
    } catch (e) {
      return text({ refused: true, reason: String(e.message || e),
        next: "Pass the exact mint address (F-1) and retry." });
    }
    if (gates.blocked) return gates.blocked;
    const g = gates.g;

    const guard = factsLayer.hotFactsGuard(g);
    if (!guard.ok) {
      return text({ refused: true, reason: guard.reason,
        next: "Use build_trade; the Architect verifies facts and signs on device." });
    }
    // Hot execution is intentionally NOT implemented pre key-ceremony
    // (RULEBOOK Sec4 activation sequence step 4). The gates can pass in
    // config, but there is no signer wired until the dedicated wallet
    // exists. Honest refusal beats a silent no-op.
    return text({ refused: true,
      reason: "hot signer not wired: the dedicated trading wallet (Sec4 step 4, wave key ceremony) does not exist yet.",
      next: "Use build_trade until the key ceremony is done." });
  });

// extra: additional Sec5 ledger fields (factsSource, factsDivergence,
// sessionGate, rugGate) so even skip/refuse rows carry the facts audit trail.
function skip(gate, reason, a, extra = {}) {
  ledger.append(rt.ledgerPath, ledger.record({
    ts: nowIso(), tokenAddress: safeAddr(a), outcome: "skipped",
    reason: gate + ": " + reason, ...extra }));
  return text({ decision: "skip", gate, reason,
    ...(Array.isArray(extra.factsDivergence) && extra.factsDivergence.length
      ? { factsDivergence: extra.factsDivergence } : {}) });
}
function refuse(gate, reason, a, extra = {}) {
  ledger.append(rt.ledgerPath, ledger.record({
    ts: nowIso(), tokenAddress: safeAddr(a), outcome: "refused",
    reason: gate + ": " + reason, ...extra }));
  return text({ decision: "refuse", gate, reason,
    ...(Array.isArray(extra.factsDivergence) && extra.factsDivergence.length
      ? { factsDivergence: extra.factsDivergence } : {}) });
}
function safeAddr(a) { try { return typeof a.tokenAddress === "string" ? a.tokenAddress : null; } catch { return null; } }

new StdioServerTransport && server.connect(new StdioServerTransport());
