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
    outcome: fields.outcome,               // "filled" | "skipped" | "refused"
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

// Sec3 daily caps read from here. Only FILLED trades count toward the
// notional caps; skips/refusals are logged but do not consume exposure.
function todayStats(ledgerPath, dayIso) {
  const day = dayIso; // "YYYY-MM-DD"
  const rows = readAll(ledgerPath).filter(
    (r) => r.outcome === "filled" && typeof r.ts === "string" && r.ts.slice(0, 10) === day
  );
  return {
    todayCount: rows.length,
    todayExposureUsd: rows.reduce((s, r) => s + (Number(r.notionalUsd) || 0), 0),
  };
}

module.exports = { record, append, readAll, todayStats };
