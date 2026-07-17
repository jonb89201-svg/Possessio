# SPEC — POSSESSIO Business Model v1 (the supply-side inversion)

**Type:** Business model spec (draft → Architect ratification)
**Date:** 2026-07-17 · **Seat:** Code Integrity (Claude Code)
**Context:** Written 2 days before Fable 5 goes API-only (July 19) and 3 days
before the foundation wave (July 20). Every number below is from the repo or
the ledger, not invented.

---

## 0. The model in one sentence

**POSSESSIO operates the first self-defending, pay-per-call data business on
its own rails — and sells everyone else the ability to launch the same stack
for themselves.**

We are simultaneously the proof and the product. The proof: our radar earns
USDC from other people's AI agents through an API we own outright, that
defends itself, with the receipts public on-chain. The product: the console
deploys that same stack (V3 + x402Core — an economy + an agent body) for
anyone, for a fee.

---

## 1. The inversion (why this model)

The trader we've been developing is the **demand side** of the agent economy —
it *buys* data and inference. It is also our weakest asset today: forward
ledger **negative** (n=10, avg −12%, rugs through the stop) in a market that is
cold for ~50 more days by on-chain bottoming metrics.

The **supply side** is already built and nobody noticed:

- `radar/x402-toll.ts` serves priced, tolled data routes **today**:
  gap-stats **$0.005** · session-gate **$0.01** · tape **$0.02**
- Protected by the SymmetryGuard behavioral fee (clean ~2% → 5% ceiling,
  un-rotatable identity) — abuse is *priced*, not fought. No support desk.
- July 19: the frontier mind goes pay-per-call. Every agent built on it needs
  exactly one thing to trade Solana memecoins: honest real-time data it can
  buy per-request with no signup. **x402 V2 Discovery** is how machines find
  sellers. We list; they find; they pay.

**We stop waiting to be a profitable buyer and start operating as the seller.**
The trader stays paper-gated under its own law (§6-R3) and loses nothing.

---

## 2. Revenue streams (in activation order)

### R1 — Data tolls (the radar as merchant) — activates at the wave
| Route | Price | Buyer |
|---|---|---|
| `/radar/gap-stats` | $0.005 | trading agents, researchers |
| `/radar/session-gate` (regime) | $0.01 | agents deciding trade/sit-out |
| `/radar/tape` | $0.02 | agents needing live tape |

- **Settlement:** x402 (EIP-3009, USDC). Machine-payable, no accounts.
- **Where the money lands:** `TOLL_SINK` — an operator-held address. It must
  **NOT** be the Heart directly (a raw transfer is uncredited, Pool DoD #14).
  Pool feeding is a **batched sweep** through `receiveInfraFunds` (Option A
  law — keeps inflow-events low, P-1 safe).
- **Honest unit economics:** cents at first. 1,000 calls/day ≈ $5–20/day.
  The early value is **position + proof**, not volume. In a cold market the
  regime read ("sit out, here's why") is the *most* sellable signal — and our
  public negative trading ledger is the honesty credential (PITI: we sell
  measurements, not hopium).
- **P0 gap to close:** current config is `TOLL_NETWORK=base-sepolia`,
  `TOLL_SINK` zeroed. The wave arms mainnet + sink. Plus the Discovery
  endpoint (worker-layer build, no contract, no freeze risk).

### R2 — Auto-deploy fees (the console sells the stack) — activates post-wave
- **Product:** one paid deploy = **V3** (your token, your pool, your
  liquidity, your fees — "small business into an empire") **+ x402Core**
  (your agent's body: identity, pay-per-action, self-defense). *Agentic
  sovereignty in a box. Bring your own mind* (Fable key or any model).
- **Price:** **1 USDC** interim (prove-the-rail), ratified. Fee is immutable
  per-factory → the raise to the **~100 USDC tier** is a NEW factory+saltpool
  version once the flywheel is proven (already in TODO).
- **Fee flow:** v1 → live Payments sink (`0x1c0F…AB91`). Later factory
  versions → Heart via accounted batched feed.
- **The sales pitch IS R1:** "here is our own till, filling, verifiable in
  `CallSettled` events on-chain. The console gives you the same machine."

### R3 — The trader (private, gated — NOT a product)
- Our own use only. The **engine** is sellable (R2); the **alpha** is never
  templated — shared alpha front-runs itself to death on thin liquidity.
- **Gate (our own law):** connects to real funds only when the forward ledger
  proves positive AND slippage is measured. Today it is neither. R1/R2 do not
  depend on it. Its API costs are call-based → it idles in cold markets
  (stream, not pool).

### R4 — Later phases (gated, listed for completeness)
- **Whisky RWA market:** gated on §7 legal + its own gauntlet (currently ZERO
  test coverage — hard-gated from live wiring).
- **L1 Ethereum anchor:** gated on the Fundstrat email; fee economics joint
  with the network operator.
- **SAV accountability-as-a-service:** raw idea (2026-07-17); the slash-oracle
  design is unsolved; not spec-level yet.

---

## 3. The flywheel

```
agents buy radar data (R1)
   → tolls accumulate at TOLL_SINK → batched sweep → the Heart
      → the Heart funds operations (RPC, inference — the mind's own bill)
         → radar keeps running/improving → more data sold
buyers see a working sovereign data business
   → some deploy their own stack via the console (R2)
      → deploy fees → Payments (→ Heart in later versions)
         → more economies on our rails → more agents needing data → R1 grows
```

Self-funding condition (same inequality as everything we ship): **revenue per
call > cost per call at steady state.** Activity funds cognition; quiet means
idle, never bleed.

## 4. Cost structure (stream, not pool)

- **Variable (call-based, self-funding):** QuickNode RPC, Fable 5 API
  inference (pay-per-call from July 19 — the `spends` table has carried an
  `'inference'/'anthropic'` leg since migration 0002), Cloudflare
  Workers/D1.
- **Fixed (small):** ~$125/mo Max subscription, domains. Solo operator; the
  radar self-heals (auto-redeploy, watchdogs, size caps) to keep the ops load
  near zero.

## 5. The moat

1. **Sovereignty is the category** — platforms structurally cannot copy
   "no one in the middle"; copying it deletes their business.
2. **The guard** — server-less abuse defense where the attacker funds the
   defense at a rising, un-rotatable price. Zero marginal cost of policing.
3. **Public proof-of-operation** — our revenue is on-chain events, not a
   pitch deck.
4. **Alpha stays private** — we sell engines and measurements, never the edge.
5. **(Future, council decision):** guard-in-the-pool = one shared reputation
   ledger across every launched template — each customer launch strengthens
   every other. Network-effect Sybil resistance. Pre-freeze architecture
   decision; not assumed here.

## 6. Customers

| Segment | Buys | Via |
|---|---|---|
| **AI agents** (machines) | data per-call (R1) | x402 + Discovery, no signup |
| **Builders/founders** | their own economy + agent body (R2) | console, $1 → tier |
| **Enterprises** (later) | accountability rails (SAV, R4) | raw idea, unpriced |

## 7. Phases and gates (each phase has a gate; no gate, no phase)

| Phase | What | Gate |
|---|---|---|
| **P0** (this week) | Foundation wave; arm `TOLL_SINK` mainnet; build+ship Discovery endpoint | runbook §III (Architect broadcasts); Discovery format verified against the real V2 spec before build |
| **P1** | First machine-paid calls; measure R1; console pitch update | wave complete |
| **P2** | $1 deploys open; first customer economies | factory live + template codehash pinned |
| **P3** | Trader connects to real funds | forward ledger positive + slippage measured — **no exceptions** |
| **P4** | Fee tier raise (new factory), guard-in-pool, SAV activation | council ratification each |

## 8. Honest risks (named, not hidden)

- **Volume risk:** the agent-data market is being born; early revenue is
  cents/day. Mitigation: near-zero marginal cost; position compounds.
- **Standard risk:** x402 V2 evolves; we track the Foundation spec (our
  settlement layer is already V2-compliant; Discovery/session are soft
  worker-layer additions).
- **Trader risk:** the edge may never prove. Fine — R1/R2 stand without it.
- **Operator risk:** one Architect, one phone. Mitigation: self-healing infra,
  runbooks written for any seat, everything on `main`.
- **Regulatory surface:** non-custodial by construction (we never hold
  customer funds/keys) is the mitigation posture. Not legal advice.

## 9. Constitution check

Non-custodial: ✓ (we never touch customer money or keys — R1 buyers pay
per-call from their own wallets; R2 customers own their deploys outright).
No one in the middle: ✓ (the guard replaces the fraud desk; the chain replaces
the biller). Own your economy: ✓ — the model doesn't just *say* the thesis,
it earns revenue by *demonstrating* it and sells the demonstration.

---

*Draft for ratification. The one build it authorizes on acceptance is the
Discovery endpoint (worker-layer). Everything on-chain stays governed by the
existing runbook + council process.*
