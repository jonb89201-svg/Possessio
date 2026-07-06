# FUEL COMPUTER — Operating Spec v1.0
**Origin:** Code Integrity seat, 2026-07-06, under Architect standing order ("build whatever we need").
**Status:** SPEC for ratification. Numbers marked OPEN are proposals, not law, until ratified.

## The loop, stated once
Trading net returns → on-chain pool → pays the agent's operating legs → agent runs →
surplus crosses the one-way valve to treasury. Four legs, each with its own rail:

| Leg | Rail | State |
|---|---|---|
| 1. Inference | Anthropic API via **credits bridge** (fiat) | the ONE bridged leg |
| 2. RPC | QuickNode **x402 pay-per-request** (USDC) | on-rails |
| 3. Tools/data | x402-native buy side (USDC) | on-rails |
| 4. Sell side | x402 tolls on radar + xtrade → toll-sink → Payments | on-rails, seam awaits wave addresses |

Every off-chain spend on legs 1–3 writes a row to `spends` (D1, live). Sell-side revenue is
NOT mirrored to D1 — it lives on-chain in Payments events; the chain is its ledger.

---

## Leg 1 — Inference (the bridged leg)
- **Billing today:** Claude Console prepaid credits (card/Stripe). No 402 on api.anthropic.com
  as of this date. **Seam:** `inference.billing_mode: "credits" | "x402"` — if first-party x402
  inference billing ships (Anthropic is an x402 Foundation member; rated plausible), flip the
  flag, not the architecture.
- **Model policy — model-agnostic by law, tiered by economics:**
  - `primary: "claude-fable-5"` ($10/$50 per MTok) — judgment-heavy steps only: rug-gate
    reasoning, audit passes, regime interpretation.
  - `fallback: "claude-opus-4-8"` — wired via the API's server-side `fallbacks` parameter;
    also the handler for `stop_reason: "refusal"` (Fable 5 classifiers can decline; a refusal
    is an HTTP 200 — handle it, don't error on it).
  - `routine: "claude-haiku-4-5"` / `"claude-sonnet-4-6"` — polling interpretation, ledger
    writes, formatting. The loop must never pay Fable prices for Haiku work.
- **Budget guards (OPEN, proposed):** per-run hard cap 200K tokens; per-day inference ceiling
  **$2.00**; on breach → leg pause + council flag. Rationale: operating burn must sit far
  inside the Rulebook's $20/day trading cap or the agent eats its fuel.
- Every metered call logs to `spends(leg='inference')` with run_id.

## Leg 2 — RPC
- **Primary (agent):** QuickNode x402 — pay-per-request, USDC; free tier **1,000,000 API
  credits/month per wallet** (RPC = 1 credit). Policy: **free-tier-first**; at Rulebook scale
  the agent should live inside it. Payment chain independent of query chain → the Solana
  (Jupiter) leg pays from the same Base USDC wallet.
- **Production console/SLA traffic:** stays on the standard QuickNode plan (endpoint 634487)
  per QuickNode's own alpha guidance — x402 access is additive, not an SLA replacement.
- **Testnet:** Base Sepolia payment network; QuickNode's /drip faucet for test USDC.
- Paid overage logs to `spends(leg='rpc')`. **Daily ceiling (OPEN, proposed): $0.50.**

## Leg 3 — Tools/data (x402 buy side)
- Client wrappers (@x402 fetch/axios family) with a **SpendingPolicy enforced before any
  signature** — the pattern from the x402 MCP guides, made law here:
  reject any payment requirement where (a) tool ≠ expected, (b) network ∉ allowlist
  (`base`, `base-sepolia` only for v1), (c) amount > per-call max.
- **Caps (OPEN, proposed):** per-call max **$0.05**; daily tools ceiling **$0.50**;
  seller allowlist starts EMPTY — every seller is an Architect ratification.
- Every settlement logs to `spends(leg='tools')` with tx hash.

## Leg 4 — Sell side
- Radar routes (`/radar/gap-stats`, `/radar/session-gate`, `/radar/tape`) behind x402
  middleware (see `x402-toll.ts`), payTo = wave toll-sink (placeholder until GATE 4).
- xtrade paid tools: same middleware pattern, post-wave, post-Rulebook-activation.
- **Product boundary re-stated as loop law:** no sellable surface ever exposes
  `status='watching'` rows. Measurements ship; the edge never does.
- Pricing: deferred to the tape (Bazaar comparables $0.001–$0.05/call). Pricing memo is a
  named future artifact, blocked on ≥1 week of gap data.

---

## Master controls
- `MASTER_PAUSE` — halts all paid legs in one flag.
- Per-leg pause flags; any daily ceiling breach auto-pauses that leg only.
- **Global operating ceiling (OPEN, proposed): $3.00/day across legs 1–3 combined.**
  All ceilings enforced BEFORE spend, from the `spends` table's daily sum — the gauge is
  the governor, not a report.

## Config schema (single source, repo-committed, no secrets)
```json
{
  "master_pause": false,
  "inference": {
    "billing_mode": "credits",
    "primary": "claude-fable-5",
    "fallbacks": ["claude-opus-4-8"],
    "routine": "claude-haiku-4-5",
    "per_run_token_cap": 200000,
    "daily_usd_ceiling": 2.00,
    "paused": false
  },
  "rpc": {
    "mode": "x402",
    "free_tier_first": true,
    "payment_network": "base-sepolia",
    "daily_usd_ceiling": 0.50,
    "paused": false
  },
  "tools": {
    "allowed_networks": ["base-sepolia"],
    "per_call_max_usd": 0.05,
    "daily_usd_ceiling": 0.50,
    "seller_allowlist": [],
    "paused": false
  },
  "sell": {
    "toll_sink": "0x0000000000000000000000000000000000000000",
    "network": "base-sepolia",
    "facilitator": "coinbase-cdp",
    "paused": true
  },
  "global_daily_usd_ceiling": 3.00
}
```
Rehearsal runs with every `network` = `base-sepolia`; the wave cutover flips networks and
fills `toll_sink` — same flip discipline as the runbook's chain checks.

## Invariants (audit-enforced)
1. The spend wallet is the dedicated wallet created by the wave's key ceremony — never the
   Base Account, never any OWNER_ROLE holder. A leaked spend key drains ceilings, not contracts.
2. No leg holds, derives, or can reach a mainnet-privileged key. (Principles 5–7.)
3. No spend without a prior ceiling check against `spends`; no settlement without a row.
4. Session Gate (§0) reads from `sessions`; its data source is VERIFY-FIRST (candidate:
   DexScreener aggregate volume vs 7-day average) and its threshold tunes ONLY via §5 evidence.
5. Everything here is NON-PROVEN until it runs on-device against live data. Codebyte Law.
