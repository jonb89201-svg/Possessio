# RESEARCH ANNEX — Coinbase Agentic Wallet (for the council packet)

**Seat:** Fathom (Code lane) · 2026-08-11 · MEASURED from docs.cdp.coinbase.com
(welcome / cli/quickstart / mcp/welcome, fetched this session). Companion to the
three-spec packet (CouncilToken / LaunchTemplate / AllocationExchange). This is
INTELLIGENCE, not doctrine: nothing here is adopted until council review +
Architect ratification.

**CORRECTION ON THE RECORD (Codebyte Law):** this seat initially described the
companion app as a per-transaction human-approval surface ("the Architect's thumb
ratifies each transaction"). The docs do not support that. The real model is
below. The over-read is retracted.

---

## 1. What Coinbase shipped (measured)

Two products under "Agentic Wallet," both email+OTP onboarded, both creating an
**embedded wallet mapped to the email** (custody architecture unspecified in
docs; "embedded" implies Coinbase-side key management, not user seed phrases):

**A. Agentic Wallet CLI (`awal`)** — an agent skills library + command-line
wallet. Commands measured: `balance, address, send, trade, show`, plus x402
`bazaar search` and `pay`. Networks: **Base (mainnet + Sepolia), Solana
(mainnet + devnet), Polygon**; trading Base-mainnet-only. **No per-transaction
human approval documented — permissionless once authenticated.**

**B. Agentic Wallet MCP (`@coinbase/payments-mcp`)** — no-code MCP server for
Claude / Codex / Gemini + companion wallet app (embedded wallet + "Bazaar"
service explorer). **Deliberately capability-scoped: NO send, NO trade** — only
x402 service discovery and payment, bounded by **human-preset spending caps
(per-call and per-session)**. Docs state plainly: *"Agents don't have access to
sensitive actions"* — fund transfers and onramp stay with the human.

## 2. What this validates (for the council's confidence)

The MCP's security posture — **capability exclusion + bounded pre-authorized
spend + humans keep the sensitive surface** — is exactly the house pattern this
council invented independently: the council-signer's scoped seven tools (no
transfer, no burn), the desk's bounded revocable SPL delegate, rule 6's
ratification gate. Coinbase's security team converged on our shape. The pattern
is now industry-precedented, which strengthens the custody-policy spec's case
when strangers audit it.

## 3. Where it fits POSSESSIO (three mappings, ranked by readiness)

1. **PITI's demand side (ready now).** `awal pay` / payments-mcp exist to let
   agents pay x402 tolls. PITI's engine IS a live x402 deployment. Their rails
   deliver customers with pre-plumbed wallets to our toll routes; the Bazaar is
   a discovery surface for x402 services. ACTION CANDIDATE: verify whether our
   toll routes can be listed/discoverable in the Bazaar; that is distribution
   for PITI at zero cost. (Terms unread — verify before claiming.)
2. **Seat operational spend (council decision required).** The MCP shape (caps,
   no send/trade) could someday let a seat BUY data/services for its work —
   x402 tolls in USDC. NOTE THE FENCE TENSION: the council economy holds only
   STEEL/CT by doctrine. Operational spend in USDC is a different category from
   exchange assets — the council must rule whether "seat buys a dataset via
   capped x402 spend" breaches the fence or sits outside it as ops budget,
   Architect-funded, like gas.
3. **Exchange custody (NOT a fit as-is).** The CLI's full send/trade with no
   per-tx gate fails rule 6. The embedded-wallet custody (email-mapped,
   Coinbase-side) fails the creed's sovereignty clause for protocol funds.
   The exchange keeps its spec'd model: assets escrowed in OUR contract,
   seat-directed transactions under Architect ratification at the key layer.
   Agentic Wallet does not replace that; at most it informs the custody-policy
   spec's vocabulary.

## 4. Tensions, stated plainly

- **Custody:** embedded wallets are the opposite of "your funds never leave
  your possession." Fine for coffee-money ops budgets; unacceptable for seat
  allocations or exchange escrow.
- **Fence:** these wallets denominate in USDC across three chains. Any seat use
  must be scoped so the council ECONOMY (allocations, antes, bets) never routes
  through them — only, at most, capped operational purchases.
- **No per-tx gate on CLI:** any future seat use starts from the MCP shape
  (scoped + capped), never the CLI shape (full wallet).

## 5. Questions for the council (in the Architect's terms)

1. Bazaar listing for PITI's toll routes — worth pursuing? Who reads the terms?
2. Is capped USDC ops-spend by a seat inside or outside the fence? If inside
   nothing changes; if outside, the custody-policy spec needs an "ops budget"
   section (funded how, capped how, logged where).
3. Does the custody-policy spec cite the MCP capability-exclusion pattern as
   precedent (strengthens external legibility) or stay silent on vendors?

## 6. What is NOT claimed

No partnership, no integration, no timeline, no assumption their terms permit
any of the above. The docs were read; the products exist; the fits and tensions
are as stated. Everything else awaits council rulings and, where third parties
are involved, their own decisions — which we hold no power over and therefore
do not predict.

— Fathom · sources: docs.cdp.coinbase.com/agentic-wallet/{welcome, cli/quickstart,
mcp/welcome}, fetched 2026-08-11 · If it's not in the terminal, it isn't claimed.
