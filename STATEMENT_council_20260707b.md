# STATEMENT — Council Addendum: the Radar Correction, Clean Tape, and the Guard Made Structural

**From:** Claude Code (repo seat, sole writer)
**To:** the Council (Architect, Code Integrity seat, MCP seat)
**Date:** 2026-07-07 (afternoon window; supersedes nothing in
`STATEMENT_council_20260707.md` — it continues it)
**Anchors:** branch `claude/internet-access-xdttz9` @ `56adc11`; `main`
@ `65453ec` (PR #8 merged). Verify against the repo and the live D1,
never against this prose.

---

## 1. The radar's first audit worked — and it cost eight minutes of tape

The instrument caught its own instrument error. First audit found the
discovery predicate was measuring DexScreener's ~60-second indexing of
the pump.fun **bonding curve** (dexId `pumpfun`), not any market event.
`pairs.length > 0` fired on almost every birth. The pre-fix tape proved
the poison quantitatively: **1,113 of 1,245 births read "graduated"
(89%)** against a real prior near 2%.

This is the method behaving exactly as designed: the tape's first job was
to test its own author's assumptions, and it failed a claim before one
dollar moved. §5 intent, honored.

## 2. R-1 / R-2: corrected, proven, deployed, verified

- **R-1 (predicate, HIGH):** `discovered` now means **graduation** — the
  first non-`pumpfun` pair (the $69K surface, 6.9× entry / 3.45× TP). The
  curve sighting is retained as write-once telemetry
  (`curve_pair_seen_ms`, migration 0003) so machine latency is never
  again confused with the market.
- **R-2 (throughput, MED):** batched discovery — 30 comma-joined
  addresses per request, VERIFY-FIRST confirmed against DexScreener's
  official docs (300 req/min). Full watching-set sweep every 1–3 min.
- **gap-stats reframed** for the redefined Acceptance 3: graduation rate,
  birth→graduation median + quartiles, curve telemetry as its own field.
- **Proven offline before asking for a deploy:** 6/6 unit tests
  (`radar/test/discovery.test.mjs`) — curve-vs-graduation, write-once
  telemetry, expiry-before-network, exact 30-per-request chunking, polite
  429 yield with partial writes landing. Bundle green.
- **Deployed 15:04:44Z; verified executing in production** — the
  telemetry column populated within minutes, and only R-1 writes it.

## 3. The tape is clean and the clock is running

- **Wipe: 15:10Z** — 1,336 poisoned rows deleted; **zero verified**;
  `trades` untouched (was empty). Executed by the **repo seat on the
  Architect's direct order** — a recorded deviation from the wipe
  protocol's step-3 seat assignment (the Architect may redirect their own
  protocol; it is in the book either way).
- **Clean first tick, ~15:15Z:** 205 fresh births, oldest timestamp
  **after** the wipe, 202 watching / 0 expired / **3 graduated (~1.5%)** —
  the correct order of magnitude, where the old predicate would have
  shown ~180. The machine is now measuring the market, not itself.
- **Acceptance-3 read scheduled ~21:21Z** (6h clean tape): graduation
  rate vs the ~2% prior; median birth→graduation vs the ~20-min prior
  (correctly framed as a winners-only survivorship stat); curve latency ≈
  one cron tick. **graduation-rate-per-hour is the measured Session Gate**
  — the §0 regime signal as data instead of feel.

## 4. Production-touch ledger (nothing unexplained)

| Time (2026-07-07) | Event | Disposition |
|---|---|---|
| 14:13:59Z | `possessio` re-upload | Architect terminal, ACCIDENTAL (deploy from repo root; repo seat's instructions at fault). Byte-identical to production. Harmless. |
| 14:17:52Z | `possessio-radar` created | Intended deploy. |
| 14:54:25Z | `possessio` re-upload | Same accidental cause (chained command from root). Byte-identical. **Chained commands retired.** |
| 15:04:44Z | `possessio-radar` redeploy | R-1/R-2 — intended, verified. |
| 15:10Z | `births` wipe | Architect-ordered, repo-seat executed. |

- **OPSEC:** the Workers-edit API token was pasted into the relay chat
  during deploy troubleshooting → treated as **BURNED**; the Architect
  has **rolled it** (confirmed). Closed.
- **Ledger item 6** (2026-07-06 23:44Z console redeploy) remains
  **UNCONFIRMED** — runbook 0.10 stays blocking at GATE 0 until claimed
  or disowned. This is the one open touch.

## 5. The guard is becoming structural (the important governance move)

The council's core discipline — *no production change without a stated
merge* — is being converted from a promise the seats police into a rule
the platform enforces. In progress this session:

- **PR #8 merged** the radar session's code to `main` (the Architect's
  broadcast signature, Principle 7). **PR #9** carries the follow-on
  records, open at the Architect's hand.
- **Branch protection on `main`** ("JohnRules" ruleset) being configured:
  require-PR-before-merge (0 approvals — solo-human correct),
  block-force-pushes, restrict-deletions. **Status: ruleset Active but
  not yet targeting `main`** (must add the default-branch target + check
  the three rule boxes to leave "will not be applied" state). Once live,
  a leaked token / chained-command slip / late-night mistake is **refused
  by GitHub**, not caught after the fact. This is ledger item 6's guard
  turned into infrastructure.

## 6. Flag for council decision (not tonight, but a decision, not drift)

The **repository is public.** It now carries the ratified
`RULEBOOK_TradingAgent.md` — entry bands, exit triggers, session-gate
cutoffs, priors. "Sell the measurements, never the edge" is enforced at
the radar's **API** boundary; the **method itself** is world-readable at
the **repo** boundary. That may be intentional (substrate-honest
transparency) or an oversight. It should be a ratified choice. Toggling
private is one control in Settings → General; rulesets keep working on
this plan either way.

## 7. Asks

1. **Architect** — finish the `main` ruleset (add default-branch target +
   the three boxes); close ledger item 6 ("mine" / "not mine"); ratify
   the public-vs-private repo posture (§6); the standing OPEN numbers
   (fuel ceilings, radar prices, stipends) and the Rulebook §1 **EXIT-3
   STALL** amendment (10-min no-new-high, replacing the invalid
   DexScreener-appearance edge-loss) await your word.
2. **Code Integrity** — cold-seat eyes on the R-1/R-2 diff (predicate +
   the D1 `batch()` write path) and the redefined gap-stats SQL. You hold
   the Acceptance-3 verdict when the 21:21Z numbers land.
3. **MCP seat** — nothing blocking.

*The correction is the proof of the discipline: an instrument that
catches its own error before capital moves, fixes it under Codebyte Law,
and restarts its own clock clean. The next six hours of tape write the
first honest line of the ledger.*

— Claude Code, repo seat, 2026-07-07
