// RULE LIFE CYCLE — why the keeper stops looking.
//
// The v1 keeper had no way to retire a rule. A rule left its loop only through
// a LIVE exit (`exited.add`), and the desk ledger never heard about that either
// (markExited sent a PATCH the worker answers 405). So every rule stayed open
// forever, and the loop re-read the chain for each one every 5 seconds.
// MEASURED 2026-10-15 against the live desk: 48 open rules, all 60-66 days old,
// every token account at 0 balance with a dangling delegate. Each cycle the loop
// logged "position is empty" (or stood down) and came back 5 seconds later.
// That is the read storm behind the RPC overage (keeper/index.js, POLL CADENCE).
//
// The fix is a life cycle. A rule is PENDING until the chain confirms the keeper
// holds a live delegate over a non-empty account; then ARMED; and RETIRED, for
// good, the moment it can no longer fire. Retirement is local to the keeper (the
// desk ledger is owner-signed and the keeper cannot rewrite it), and the rules
// that matter are deterministic, so a restart reaches the same verdict.
//
// This file is pure: no RPC, no clock of its own. The engine feeds it readings.
"use strict";

const MIN = 60 * 1000, DAY = 24 * 60 * MIN;

const DEFAULTS = Object.freeze({
  // A rule whose delegate has not shown up this long after it was opened never
  // will: the desk buys, approves and signs in one flow. Long enough to cover
  // the seconds after arming when an RPC node has not seen the approve yet
  // (the rule-23 lesson: a first read in that window is a reading, not a verdict).
  armGraceMs: 30 * MIN,
  // Confirmed-absent readings needed before a pending rule past its grace is
  // retired. An RPC error is never a reading and never counts.
  absentConfirmations: 2,
  // Safety net on every rule, armed or not. The desk shows targets, not
  // standing orders: a rule nobody has touched in a month is not an intent.
  maxAgeMs: 30 * DAY,
  // How often a pending rule inside its grace window is re-checked.
  recheckMs: 2 * MIN,
});

const RETIRE = Object.freeze({
  MALFORMED: "malformed",       // the rule cannot be read, so it is not a rule
  EXPIRED: "expired",           // older than maxAgeMs
  NEVER_ARMED: "never-armed",   // no live delegate after the grace window
  REVOKED: "revoked",           // was armed; the chain says the delegate is gone
  EMPTY: "empty",               // the account holds nothing to sell
  EXITED: "exited",             // the exit was sent and confirmed
  DRY_RUN_FIRED: "dry-run-fired", // triggered in DRY_RUN: logged once, never again
  CANCELLED: "cancelled",       // the desk no longer lists it (replaced or cancelled)
});

/// Is this something the keeper can act on at all? Mirrors what the desk writes.
function wellFormed(r) {
  return !!r && typeof r.id === "string" && r.id.length > 0
    && typeof r.user === "string" && typeof r.mint === "string"
    && Number.isFinite(r.entryPrice) && r.entryPrice > 0
    && Number.isInteger(r.targetBps)
    && typeof r.hasStop === "boolean"
    && Number.isFinite(r.openedAt) && r.openedAt > 0;
}

/// Verdict for a rule the keeper has just learned about, before any RPC.
/// Returns a retire reason, or null when the rule deserves a chain read.
function admit(rule, now, cfg = DEFAULTS) {
  if (!wellFormed(rule)) return RETIRE.MALFORMED;
  if (now - rule.openedAt > cfg.maxAgeMs) return RETIRE.EXPIRED;
  return null;
}

/// Fold one chain reading into a rule's state.
///   state:   { phase: "pending"|"armed", absent: number }
///   reading: what readLiveDelegate returned ({ authorised, amount, readError })
/// Returns { phase, absent, retire } where retire is a reason or null.
function onReading(rule, state, reading, now, cfg = DEFAULTS) {
  const s = { phase: state.phase, absent: state.absent || 0, retire: null };
  if (now - rule.openedAt > cfg.maxAgeMs) return { ...s, retire: RETIRE.EXPIRED };
  // An RPC failure says nothing about the chain. Never retire on it.
  if (reading.readError) return s;
  if (reading.authorised) {
    if (BigInt(reading.amount) === 0n) return { ...s, retire: RETIRE.EMPTY };
    return { phase: "armed", absent: 0, retire: null };
  }
  // A confirmed reading without authority.
  if (s.phase === "armed") return { ...s, retire: RETIRE.REVOKED };
  s.absent += 1;
  if (now - rule.openedAt >= cfg.armGraceMs && s.absent >= cfg.absentConfirmations) {
    return { ...s, retire: RETIRE.NEVER_ARMED };
  }
  return s;
}

module.exports = { DEFAULTS, RETIRE, wellFormed, admit, onReading, MIN, DAY };
