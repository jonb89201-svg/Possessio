// xtrade MCP server - the Trading Agent, build-mode by default.
// Wires the terminal-proven constitution modules (config/modes/caps/
// selection/sessiongate/method/ledger) to the Jupiter adapter.
//
// NON-PROVEN end-to-end in the sandbox: the Jupiter calls are network-
// blocked here. The GATING logic (F-1, session/rug/entry gates, caps,
// mode triple-gate) is unit-proven (test/constitution.test.js, 19/19).
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
server.tool("get_ledger_stats", "Today's filled-trade count and exposure vs caps.", {},
  async () => text({ ...ledger.todayStats(rt.ledgerPath, day()),
    caps: { maxTradesPerDay: rt.maxTradesPerDay, maxDailyExposureUsd: rt.maxDailyExposureUsd } }));

// --- build_trade: the full pipeline, in order. Returns UNSIGNED tx. ---
server.tool("build_trade",
  "Validate F-1 + all gates + caps, then return an UNSIGNED Solana swap tx. The Architect signs.",
  { tokenAddress: z.string(), notionalUsd: z.number(), slippageBps: z.number(),
    userPublicKey: z.string(),
    facts: z.object({
      onDexScreener: z.boolean(), ageMin: z.number(), mc: z.number(),
      mintRenounced: z.boolean(), lpLockedOrBurned: z.boolean(), creatorHoldingPct: z.number(),
      trailingVol: z.number(), avg7d: z.number(),
      inputMint: z.string(), amountAtomic: z.string(),
    }) },
  async (a) => {
    const f = a.facts;
    try {
      // 1. F-1 (absolute): contract address only, never a ticker.
      const mint = assertContractAddress(a.tokenAddress);

      // 2. Sec0 session gate.
      const sg = sessionGate(f, TUNE.sessionGateCutoff);
      if (!sg.play) return skip("session-gate", sg.reason, a);

      // 3. Sec2 rug gate.
      const rg = rugGate(f, TUNE);
      if (!rg.ok) return skip("rug-gate", rg.fails.join("; "), a);

      // 4. Sec1 entry.
      const en = entryOk(f, LAW, TUNE);
      if (!en.ok) return skip("entry", en.fails.join("; "), a);

      // 5. Sec3 caps (server-enforced against the ledger).
      const st = ledger.todayStats(rt.ledgerPath, day());
      const cap = checkCaps({ notionalUsd: a.notionalUsd, slippageBps: a.slippageBps, ...st }, rt);
      if (!cap.ok) return refuse("caps", cap.fails.join("; "), a);

      // 6. Jupiter quote + unsigned build (DEVICE-VERIFY: network here).
      const q = await jupiter.quote(rt, {
        inputMint: f.inputMint, outputMint: mint,
        amountAtomic: f.amountAtomic, slippageBps: Math.min(a.slippageBps, rt.maxSlippageBps) });
      const built = await jupiter.buildSwapTx(rt, { quoteResponse: q, userPublicKey: a.userPublicKey });

      ledger.append(rt.ledgerPath, ledger.record({
        ts: nowIso(), tokenAddress: mint, outcome: "filled", entryMc: f.mc,
        sessionGate: sg, rugGate: rg, notionalUsd: a.notionalUsd, reason: "build payload issued" }));
      return text({ mode: "build", unsignedTx: built.unsignedTxBase64,
        note: "UNSIGNED. Sign in your wallet / dedicated trading wallet.",
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
    // Hot execution is intentionally NOT implemented pre key-ceremony
    // (RULEBOOK Sec4 activation sequence step 4). The gates can pass in
    // config, but there is no signer wired until the dedicated wallet
    // exists. Honest refusal beats a silent no-op.
    return text({ refused: true,
      reason: "hot signer not wired: the dedicated trading wallet (Sec4 step 4, wave key ceremony) does not exist yet.",
      next: "Use build_trade until the key ceremony is done." });
  });

function skip(gate, reason, a) {
  ledger.append(rt.ledgerPath, ledger.record({
    ts: nowIso(), tokenAddress: safeAddr(a), outcome: "skipped", reason: gate + ": " + reason }));
  return text({ decision: "skip", gate, reason });
}
function refuse(gate, reason, a) {
  ledger.append(rt.ledgerPath, ledger.record({
    ts: nowIso(), tokenAddress: safeAddr(a), outcome: "refused", reason: gate + ": " + reason }));
  return text({ decision: "refuse", gate, reason });
}
function safeAddr(a) { try { return typeof a.tokenAddress === "string" ? a.tokenAddress : null; } catch { return null; } }

new StdioServerTransport && server.connect(new StdioServerTransport());
