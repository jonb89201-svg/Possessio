# SPEC — Council Signer (the reproducible AI→seat-key voting bridge)

**Type:** Build spec (SAV governance primitive) → **FULL COUNCIL review** →
Architect ratify → build → adversary test
**Date:** 2026-07-20 · **Seat:** Code Integrity (repo council seat)
**Status:** DRAFT FOR FULL-COUNCIL REVIEW. Part of the SAV council mechanism, so
it takes the whole council. Pairs with `SPEC_FundingVault.md` (console launch) and
the F4 deliberation-layer finding (the other half of the council OS).

---

## 0. The gap this closes (honest first)

The on-chain council governance exists (`POSSESSIO_v2-6-3.sol`:
`proposeInvent`/`approveInvent` `onlyCouncilMember`, `executeInvent`/`savSlash`
`onlyTreasury`, `INVENT_THRESHOLD = 3`). But it has **never been exercised** —
all four seats are nonce-0 / zero-balance on Base. Every "council vote" to date
has been **text**, relayed by the Architect. The bridge from *"an AI decides"* to
*"a transaction is signed by that seat's key"* was never built.

That bridge is also **the thing every future operator copies.** SAV is only a
product if a second operator can stand up their own 4-AI council on their own
hook. So the signing method must be **reproducible by construction** — a packaged
connector + a launch step, not a bespoke ritual. This spec defines it.

---

## 1. The one question it answers: how does an AI sign?

A human holds a key in a wallet and clicks. An AI does not. "Connect four AIs to
SAV" reduces to: **each AI needs a signing capability bound to its seat key.**
Three reproducible shapes, on an independence↔simplicity axis:

| method | how it signs | independence | reproducible? |
|---|---|---|---|
| **Human-relayed** | operator reads AI text, signs each seat | none (one hand, four hats) | trivially, but not autonomous |
| **Per-AI scoped signer** (this spec) | each AI calls a voting-only tool bound to its key | real, per-runtime | yes — a packaged connector |
| **On-chain session-key scoped** | key permissioned on-chain to council selectors only | real + key-loss-proof | yes, more build (§6 hardening) |

This spec ships **method 2** as v1 (with method 3 as the flagged hardening track),
because it's reproducible, autonomous, and — critically — **safe by scope**.

---

## 2. What the Council Signer IS (and refuses to be)

A minimal **MCP connector** (the same shape this session's own Base wallet runs
on — `mcp__Base__sign`/`send` proves the mechanism is real, not hypothetical).
One instance per seat, provisioned with an immutable `(seatKey, hookAddress,
chainId)`. It exposes a **voting-only** tool surface:

- `council_propose(proposalHash)` → signs+submits `proposeInvent(bytes32)` to the
  **one** bound hook.
- `council_approve(proposalHash)` → signs+submits `approveInvent(bytes32)`.
- `council_burn(amount)` → signs+submits `savBurn(uint256)` (a seat can only ever
  burn *its own* claimable — a self-limiting, safe action).
- `council_status()` → read-only: current proposal, approvals, this seat's state.

It **cannot** expose: arbitrary tx signing, transfers, `approve`, calls to any
other contract, or any selector beyond the hook's council-member functions. The
AI physically cannot do anything but participate in council governance on that one
hook. **The tool surface is the sandbox.**

---

## 3. The safety model (why it's safe even if everything leaks)

Two layers, and the second already exists on-chain:

1. **Connector scope (off-chain).** The MCP only exposes council selectors for one
   hook. An AI using the tool can't express anything else.
2. **The `onlyTreasury` floor (on-chain, already shipped).** Even if the raw seat
   key leaks *around* the connector, the key can only call `onlyCouncilMember`
   functions — it can `approveInvent` (cast a vote) and `savBurn` (destroy its own
   claim). It **cannot** move money: `executeInvent` and `savSlash` are
   `onlyTreasury`. A fully-compromised or rogue council casts bad votes that just
   *sit there* until the Architect executes — and the Architect can `savSlash`.

So the worst case at every layer is **a bad vote, never a drained cent.** That is
what lets v1 ship the simple scoped-signer and harden later without risk. The
signing method's *correctness* is not load-bearing for *safety* — the Treasury
gate is. (Established with the Architect, F3.)

---

## 4. Gas (the reproducibility friction, named)

The current hook takes a direct `onlyCouncilMember` call — `msg.sender` must be
the seat — so each seat needs a little gas. Two paths:

- **v1: fund each seat minimally.** A council vote is one cheap Base tx; a few
  cents of ETH per seat covers many votes. Launch step: "fund your 4 seats." Dead
  simple, fully reproducible.
- **Hardening: a `approveInventBySig` meta-tx path** (EIP-712 vote, a relayer/
  paymaster submits) so seats need **zero** gas — the AI signs a message, never a
  transaction. Cleaner reproducibility (no funding step), but a hook change. The
  v2 hook is **not deployed yet** (seats nonce-0), so this is addable pre-freeze
  if the council wants it. Flagged, not assumed.

---

## 5. Launch provisioning (the copyable flow — console step one)

"Connect your council" becomes a launch step, not a ritual:

1. Console generates 4 keypairs (or the operator brings 4 AI-agent addresses).
2. Hook deploys with `COUNCIL_0..3` = the 4 addresses (immutable, as today).
3. Console emits 4 Council Signer configs `(seatKey, hookAddr, chainId)` — one per
   AI.
4. Operator installs each config into that AI's runtime — one MCP connector per AI
   (Gemini / ChatGPT / Claude / Grok), the way this session has a Base wallet.
5. Fund each seat minimally (v1) — or skip if the sig-relay path (§4) is built.
6. **Council is live:** deliberate over the F4 layer, vote over the signers,
   execute over the Treasury.

That is the whole reproducible "council OS": **talk over F4 (Resend), vote over
the scoped signer, execute over Treasury.** Any operator copies these six steps.

---

## 6. Honest caveats (named, not buried)

1. **Independence is owner-determined and unenforceable** — you cannot prove
   on-chain that four seats are four genuinely-separate AIs vs one operator holding
   four keys. This spec does not pretend to enforce it; it **models** the honest
   practice (voting-only scoped signers, public record) and relies on the Treasury
   gate for safety, not on independence. (F3.)
2. **The connector is trusted to be scoped.** A malicious *build* of the connector
   could sign anything. Mitigation: it's open, and the on-chain `onlyTreasury`
   floor bounds the damage regardless. The on-chain session-key scope (§6
   hardening / method 3) removes even this trust — the real end state.
3. **v1 needs 4 funded keys.** Small, but a step. The sig-relay path removes it.
4. **This does not make the AIs vote *well*** — only lets them vote *at all*,
   safely. Vote quality is the council's problem; this is the plumbing.

---

## 7. Definition of Done (what full-council ratification authorizes)

- The Council Signer MCP connector: `(seatKey, hookAddr, chainId)` binding; the
  four voting-only tools (§2); **provably no path to any non-council selector or
  any other contract** (adversarial-tested: attempt a transfer, an arbitrary call,
  a second-hook call — all impossible through the tool surface).
- The console launch step (§5): provision 4 configs, register `COUNCIL_0..3`,
  funding (or sig-relay) instruction.
- A live end-to-end proof on testnet: 4 connectors, a real `proposeInvent` +
  3× `approveInvent` reaching `INVENT_THRESHOLD`, the Architect `executeInvent` —
  the first time the council mechanism is exercised on-chain at all.
- **Decision flagged for the council:** ship v1 funded-seats, or build the
  `approveInventBySig` sig-relay path into the (not-yet-deployed) hook first.

---

*For the full council. This is the bridge that turns SAV from "governance that
exists on-chain" into "governance anyone can operate" — and because how we let the
council use its keys becomes how everyone does, the load-bearing property is
**reproducibility, made safe by scope**: voting-only signers, a Treasury money-gate
underneath, and an honest admission that independence is the operator's to keep.*
