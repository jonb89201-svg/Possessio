// RULEBOOK Sec5 - The Ledger. Append-only JSONL. Every attempt -
// filled, skipped, or refused - is recorded. This is what makes the
// method verifiable instead of anecdotal. NEVER committed (runtime data).
"use strict";
const fs = require("fs");
const path = require("path");

// One record per attempt. Fields mirror RULEBOOK Sec5 exactly.
function record(fields) {
  return {
    ts: fields.ts,                         // ISO string (caller stamps - keeps this pure/testable)
    tokenAddress: fields.tokenAddress || null,
    chain: fields.chain || "solana",
    outcome: fields.outcome,               // "filled" | "built" | "skipped" | "refused"
    // W-2: where the gate inputs came from. facts.js now gathers them
    // server-side: "chain-read" = every gate-critical fact fetched this
    // call; "chain-read-incomplete" = a fetch failed (the call is refused
    // fail-closed). The default stays "caller-asserted" so any row written
    // WITHOUT the facts layer remains honest about running on the
    // caller's word - never claim device-verified facts by default.
    factsSource: fields.factsSource ?? "caller-asserted",
    // W-2 audit trail: [{fact, asserted, fetched, source}] wherever the
    // caller's hint disagreed with the server's own read. null = no hints
    // or no disagreement.
    factsDivergence: fields.factsDivergence ?? null,
    pumpFirstSeen: fields.pumpFirstSeen ?? null,
    dexFirstSeen: fields.dexFirstSeen ?? null,   // gap vs pumpFirstSeen = the edge proxy
    sessionGate: fields.sessionGate ?? null,     // { ratio, cutoff, play }
    entryMc: fields.entryMc ?? null,
    entryPrice: fields.entryPrice ?? null,
    entryTs: fields.entryTs ?? null,
    rugGate: fields.rugGate ?? null,             // { ok, fails[] }
    exitTrigger: fields.exitTrigger ?? null,     // 1-4
    exitMc: fields.exitMc ?? null,
    exitPrice: fields.exitPrice ?? null,
    exitTs: fields.exitTs ?? null,
    grossReturn: fields.grossReturn ?? null,
    netReturn: fields.netReturn ?? null,         // the number that matters
    notionalUsd: fields.notionalUsd ?? null,
    reason: fields.reason ?? null,
  };
}

function append(ledgerPath, rec) {
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true });
  fs.appendFileSync(ledgerPath, JSON.stringify(rec) + "\n");
  return rec;
}

function readAll(ledgerPath) {
  if (!fs.existsSync(ledgerPath)) return [];
  return fs.readFileSync(ledgerPath, "utf8")
    .split("\n").filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
}

// Sec3 daily caps read from here. Cap accounting is CONSERVATIVE: both
// "filled" and "built" rows consume the daily count/exposure budget (an
// unsigned build reserves the notional it asked for, so build spam cannot
// mint unlimited payloads). Skips/refusals never consume exposure.
// Performance truth (Sec5 net-return) is STRICTER: only "filled" rows -
// a build is an unsigned payload, not a trade, and must never inflate
// the record the method is judged by.
const CAP_OUTCOMES = new Set(["filled", "built"]);

function todayStats(ledgerPath, dayIso) {
  const day = dayIso; // "YYYY-MM-DD"
  const rows = readAll(ledgerPath).filter(
    (r) => typeof r.ts === "string" && r.ts.slice(0, 10) === day
  );
  const capRows = rows.filter((r) => CAP_OUTCOMES.has(r.outcome));
  const filled = rows.filter((r) => r.outcome === "filled");
  const sumUsd = (rs, k) => rs.reduce((s, r) => s + (Number(r[k]) || 0), 0);
  return {
    // caps view (Sec3): filled + built
    todayCount: capRows.length,
    todayExposureUsd: sumUsd(capRows, "notionalUsd"),
    // performance view (Sec5): filled ONLY
    filledCount: filled.length,
    filledExposureUsd: sumUsd(filled, "notionalUsd"),
    netReturnUsd: sumUsd(filled, "netReturn"),
  };
}

module.exports = { record, append, readAll, todayStats };
