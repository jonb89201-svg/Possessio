# SPEC — Trade Pre-Flight Guard (PFG) for the AI trader

**Type:** Build spec (draft → **cold-seat (Grok) review** → Architect ratify →
build → adversary + fork/sim test)
**Date:** 2026-07-20 · **Seat:** Code Integrity (repo council seat)
**Status:** DRAFT FOR REVIEW — do NOT build until the cold seat has read it.
Referenced dependency of `SPEC_FundingVault.md` (§6a) and `SPEC_AutoTarget.md`.

---

## 0. Provenance (so the record is honest)

This is **not** a Grok recommendation — Grok's x402Core audit was clean and
scoped to x402Core, and he has no priors on the trader. The call to apply a
pre-flight guard to *trading* came from a **different council seat (Gemini)**.
It stands on four independent legs:
1. **The Gemini seat — two independent instances converged.** The *warm* seat
   (which **authored `sal_pfg` itself**, leg 4) flagged that the same pre-flight
   discipline SAV runs before a hook deploy belongs before every trade buy/sell.
   Separately, a **cold Gemini seat with no priors** on this repo reached the
   same conclusion unprompted. That matters: the recommendation is not just the
   original designer attached to their own instrument — a blind seat converged
   on it too. (What neither validated is the load-bearing KDA question below;
   that is still open for the cold seat to attack.)
2. **The forward strat verdict** (n=50, avg −10%, rug 40%, worst −82%): the
   losses are *post-entry rugs and gapping fills* the entry gate never saw. The
   verdict's own remedy: *"a post-entry rug re-check to cut the −82% tails
   without clipping the +75% runners."*
3. **The Architect's read** — apply the same idea before every buy/sell.
4. **`sal_pfg` precedent** — the SAV Pre-Flight Guard (`script/sal_pfg`,
   README §PFG): five sequenced gates that already protect the council's own
   allocation from executing into manipulated/hollow pool state.

The PFG generalizes that proven instrument from "before hook deploy" to "before
every trade."

---

## 1. Goal

Cut the −82% tail without clipping the +75% runners, by refusing to *buy into*
(and honestly recording *selling into*) hollow or manipulated liquidity. Every
trade carries a **gate-result attestation** rendered on the transactions page —
so *"did the keeper fire on the right tick, and was the fill honest"* is
something you can look at, not trust.

---

## 2. The gates (sal_pfg's five, adapted to a memecoin trade)

Read keeper-side against **live pool state** at the trade block/slot. Critical
gates **fail closed**; soft gates **warn + accumulate**.

| gate | reads | BUY action | why |
|---|---|---|---|
| **Heartbeat** | guard-logic integrity (ratified hash) | veto on drift | the guard can't be silently swapped |
| **Sequencer** | chain liveness — Base block time / Solana slot time | warn; veto on severe congestion | congested chain → bad fills |
| **Liquidity Integrity (JIT)** | reserves now + Δ over N blocks/slots | **veto** if below floor or collapsing | a rug draining *in progress* |
| **Kinetic Depth Anchor (KDA)** | simulate a **dust swap** (quote) and read actual out | **veto** on zero/hollow out | THE memecoin gate — hollow/fake liquidity reveals itself regardless of tick concentration |
| **Price Discovery** | price now vs N-ago; cross-ref a reference if one exists | **veto** on extreme spike | don't buy the top of a manipulation |

**KDA is the load-bearing gate.** The −82% fills come from *apparent* liquidity
that isn't real; a tiny simulated swap that returns ~nothing is the tell no
market-cap number shows.

---

## 3. BUY vs SELL — different postures

- **BEFORE A BUY → VETO (fail-closed).** Any critical gate veto ⇒ the keeper
  does **not** call `FundingVault.drawForTrade`; the position never opens. Honest
  refusal, like `PoolEmpty()` — never a degraded path. This is the buy
  pre-flight the FundingVault (§6a) and the metered-feed council statement
  require.
- **BEFORE A SELL → ATTEST (mostly).** A **stop always exits** — you want out of
  a rug even into bad liquidity; the PFG's job here is to *record why the fill
  was what it was* (attestation), not to trap you in. **Veto only** the narrow
  case of a **target-sell into a manipulated spike** (don't hand your +50% to a
  wash-trade that evaporates on your sell).

---

## 4. The attestation (the receipt surface)

A compact, per-gate result the keeper produces and records with the trade:

```
PFG {
  side: BUY | SELL_TARGET | SELL_STOP,
  verdict: PASS | WARN | VETO,
  gates: { heartbeat, sequencer, jit, kda, price } → each PASS|WARN|VETO,
  kda_quote: dust-in / actual-out,
  depth_usd, price, blockOrSlot, ts
}
```

- **On BUY:** the PASS attestation's hash is passed into
  `FundingVault.drawForTrade(intentId, amount, pfgHash)` and recorded with the
  trade. No PASS → no draw.
- **On SELL:** the exit attestation is recorded at the desk's `markExecuted`
  (and/or the vault's `returnProceeds`).
- **On the transactions page:** each trade row shows `PFG buy ✓ 5/5` or
  `⚠ KDA veto — hollow`, and the exit-side depth/price — the honesty product.

---

## 5. Where it runs, per chain

Keeper-side (it needs live pool reads); the *attestation* is what touches chain.

- **EVM (Base / Robinhood):** V4 QuoterV2 staticcall (KDA), StateView (reserves,
  sqrtPrice), block time (sequencer). Exactly `sal_pfg`'s instruments.
- **Solana pre-DEX (pump.fun):** the bonding-curve **virtual reserves** (from the
  PumpPortal per-trade feed / birth JSON) give JIT + KDA (a curve quote is a
  pure function of reserves); slot time for sequencer. **This is the live edge —
  the Solana adapter is on the critical path.**
- **Solana post-DEX / EVM price cross-ref:** DexPaprika (post-DEX, free) for the
  price-discovery gate where a reference exists.

---

## 6. Honest caveats (named, not buried)

1. **PFG reduces the tail; it does not repeal gapping physics.** It stops you
   *buying* a hollow pool and *explains* a bad *stop* fill. But if liquidity
   vanishes in the slot *between* the gate and the fill, the stop still gaps.
   Expect the −82% worst case to *shrink and rarefy*, not disappear. Measure it
   on the forward ledger before claiming otherwise.
2. **Point-in-time reads.** A gate passes at block/slot T; a rug can land at
   T+1. PFG lowers probability, not to zero.
3. **Keeper-trust boundary.** The gate *logic* runs off-chain; a malicious keeper
   could fabricate a PASS. Mitigations: (a) the attestation is **public and
   auditable** — a faked PASS that preceded an −82% fill is visible on the
   transactions page; (b) the **FundingVault caps** bound the damage regardless;
   (c) a future trustless version moves KDA/price on-chain (a real `sal_pfg`-
   style view called atomically in the same tx as the swap). v1 is
   attest-and-cap; full on-chain PFG is a hardening track, flagged.

---

## 7. Open decisions (cold seat + Architect — not guessed here)

1. **Thresholds:** JIT liquidity floor + collapse-Δ %, KDA min-out ratio,
   price-drift veto %, sequencer congestion bound. **Calibrate from the forward
   ledger** (which −82% trades would a given KDA threshold have vetoed, and how
   many +75% runners would it have clipped? — the whole point is to cut tails
   without clipping runners).
2. **Veto vs warn per gate** — which are fail-closed on BUY.
3. **Attestation on-chain schema** — hash-only vs structured; storage vs
   event-only (cost vs queryability for the transactions page).
4. **v1 attest-and-cap vs on-chain trustless PFG** — start attest; flag the
   trustless track.
5. **Per-chain adapters** — EVM Quoter/StateView, Solana curve-reserves. Solana
   first (the edge).

---

## 8. Definition of Done (what this authorizes, once ratified)

- The keeper-side gate module (per-chain adapters) + the attestation schema.
- `FundingVault.drawForTrade` accepts + records the PFG hash; a missing/failed
  PASS blocks the draw (adversarial-tested).
- The desk records the exit attestation at `markExecuted`.
- The transactions page renders per-trade PFG results.
- **Calibration proof:** a backtest over the forward ledger showing the chosen
  thresholds cut the tail (fewer/less-deep sub-−50% trades) **without** clipping
  the runners — the numeric case the strat verdict demanded.

---

*Draft for the cold seat. The load-bearing claim to attack: does the KDA
dust-swap gate actually separate the −82% traps from the +75% runners on real
pre-DEX pump.fun state, or is bonding-curve liquidity too shallow-by-design for
the gate to discriminate? That question — not the plumbing — is what decides if
this earns its place.*
