# SPEC — Council Signer v2 (the reproducible AI→seat-key voting bridge)

**Type:** Build spec (SAV governance primitive) → **FULL COUNCIL review** → Architect ratify → build → adversary test
**Date:** 2026-07-20 · **Seat:** Code Integrity (repo council seat)
**Supersedes:** SPEC_CouncilSigner.md v1 (same date). Changes: §5 rewritten to Safe-style bring-your-own-addresses; §2 drops `council_burn`; §2a adds statement signing; §4 hardening promoted to pre-freeze; §6 gains F2/F3; §7 DoD expanded. **v2.1: F3 and F5 verified against the contract by Code Integrity (§6.4, §7) — F3 is UNBOUND, fix recommended pre-freeze.**
**Status:** DRAFT FOR FULL-COUNCIL REVIEW. Part of the SAV council mechanism, so it takes the whole council. Pairs with `SPEC_FundingVault.md` and the F4 deliberation layer.

---

## 0. The gap this closes (honest first)

On-chain council governance exists (`POSSESSIO_v2-6-3.sol`: `proposeInvent`/`approveInvent` `onlyCouncilMember`, `executeInvent`/`savSlash` `onlyTreasury`, `INVENT_THRESHOLD = 3`). It has **never been exercised** — all four seats are nonce-0 / zero-balance on Base. Every "council vote" to date has been **text**, relayed by the Architect.

That bridge is also **the thing every future operator copies.** SAV is only a product if a second operator can stand up their own council on their own hook. So the method must be **reproducible by construction** — a packaged connector plus a launch step, not a bespoke ritual.

---

## 1. The one question: how does an AI sign?

A human holds a key and clicks. An AI does not. "Connect four AIs to SAV" reduces to: **each AI needs a signing capability bound to its seat key.**

| method | independence | reproducible? |
|---|---|---|
| Human-relayed | none (one hand, four hats) | yes, but not autonomous |
| **Per-AI scoped signer** (this spec) | real, per-runtime | yes — a packaged connector |
| On-chain session-key scoped | real + key-loss-proof | more build (§4 track) |

Ships **method 2**, with `approveInventBySig` (§4) promoted to **pre-freeze**, because the hook is not yet deployed and it is the cheapest it will ever be.

---

## 2. What the Council Signer IS (and refuses to be)

A minimal **MCP connector** — the same shape as this session's live Base wallet, which proves the mechanism is real. **One instance per seat**, provisioned with an immutable `(seatKey, hookAddress, chainId)`.

**Voting-only tool surface:**

- `council_propose(proposalHash)` → signs+submits `proposeInvent(bytes32)` to the **one** bound hook
- `council_approve(proposalHash)` → signs+submits `approveInvent(bytes32)`
- `council_status()` → read-only: current proposal, approvals, this seat's state

It **cannot** expose arbitrary tx signing, transfers, `approve`, calls to any other contract, or any selector beyond the bound hook's council-member functions. **The tool surface is the sandbox.**

**`council_burn` is REMOVED from v1** *(finding F1)*. `savBurn` sends tokens to the dead address irreversibly, with no Treasury gate and no threshold — a compromised connector destroys that seat's entire claim instantly. That contradicts §3's safety claim. Burning is not voting. Add it later with a stated reason, or not at all.

### 2a. Statement signing (new)

- `council_sign_statement(text)` → EIP-712 signature over a council statement. **Signs, never submits.**

The connector already holds the key. One more tool makes every statement, finding, amendment, and dissent **attributable to a seat address** — which closes the verification gap in the F4 deliberation layer at zero extra cost. An unsigned email claiming to be a seat's position is unverifiable by anyone, including that seat. A signed one is not.

---

## 3. The safety model (why it holds even if everything leaks)

1. **Connector scope (off-chain).** Only council selectors, only one hook. An AI using the tool cannot express anything else.
2. **The `onlyTreasury` floor (on-chain, already shipped).** Even if a raw seat key leaks *around* the connector, it can only call `onlyCouncilMember` functions. It **cannot move money** — `executeInvent` and `savSlash` are `onlyTreasury`. A fully compromised council casts votes that **sit there** until the Architect executes, and the Architect can `savSlash`.

With `council_burn` removed, the worst case at every layer is **a bad vote, never a lost cent.** The signing method's correctness is not load-bearing for safety — the Treasury gate is.

---

## 4. Gas — build `approveInventBySig` before the hook freezes *(promoted)*

The current hook takes a direct `onlyCouncilMember` call, so `msg.sender` must be the seat, so each seat needs gas.

**Ratified: build the meta-tx path now.** Seats sign an EIP-712 vote; a relayer or paymaster submits. The v2 hook is **not deployed** (seats nonce-0), so this is addable pre-freeze and will never be cheaper.

Three things it buys:
- Removes the "fund four seats" launch step — cleaner reproducibility
- Seats need **zero** gas
- **A seat key never needs to be hot** — which materially mitigates F2

**Code Integrity note:** the same pre-freeze window that makes `approveInventBySig` cheap makes the **F3 amount-binding fix** (§6.4) cheap — build them in the same hook edit, since both touch the invent path and both close a trust gap that hardens once the hook freezes.

Fallback if not built: fund each seat minimally. A council vote is one cheap Base tx.

---

## 5. Launch provisioning — Safe-style, bring your own addresses

**The console never generates or holds a seat key.** Same posture as a Safe: you paste addresses that already exist and control themselves.

1. **Operator supplies four agent addresses.** Each proves control by signing a nonce before the console accepts it — checksum and format alone cannot prove an address is reachable, and an unreachable seat is a permanently dead vote *(F2)*.
2. Console validates: distinct, non-zero, not the contract, all four signature-proved.
3. **Disclosure shown before signing** — see §5a.
4. Hook deploys with `COUNCIL_0..3` = those four, immutable.
5. Allocation lands (3% → SAV vault).
6. Operator installs one connector config `(seatKey, hookAddr, chainId)` per runtime.
7. Fund each seat minimally — **or skip entirely if §4 is built.**
8. **Council is live:** talk over F4, vote over the connectors, execute over Treasury.

**Ordering is enforced by reality, not policy:** a connector binds to a hook address, and that address does not exist until V3 deploys. Nothing can be provisioned early. But the **four addresses are constructor args** — they are needed at *deploy* time, which puts them on the pre-wave gate list beside `TEMPLATE_CODEHASH` and the treasury/operator destinations.

**One key per runtime.** Claude Code holds **the Claude seat key only** — it is already that seat's executor arm, and its terminal is simply how this seat happens to sign. The other three live in their own runtimes. Four keys in one process would make four votes mean one signer, and publishing that as the reference implementation would make every downstream council one process wearing four hats.

### 5a. Immutability disclosure (constant across every template)

Not financial advice — disclosure of an irreversible property, shown before the signature:

> **These four addresses are permanent.** They cannot be changed after launch. There is no setter and no admin. **If two are lost, the allocation is frozen forever**, and the only remaining action is `savSlash`, which burns all of it.

Launch stays disabled until every immutable field is filled and validated. No defaults, no blanks.

### 5b. Per-template manifests

This is V3's launch page, not a universal form. Each template ships its own manifest: field list, validation rules, and disclosure block. Payments has no council fields; FundingVault has owner/keeper/cap and its own disclosure. **The disclosure block is the one constant** — whatever can never be changed gets said plainly before the signature. Adding a template means writing a manifest, not touching the launch page.

---

## 6. Honest caveats (named, not buried)

1. **Independence is owner-determined and unenforceable.** You cannot prove on-chain that four seats are four separate AIs. Bring-your-own-addresses means the console *structurally cannot* hold seat keys — stronger than v1's console-generated path — but the operator still provisions four runtimes and is trusted not to retain the keys. It is a practice, not a guarantee. Safety rests on the Treasury gate, not on independence.
2. **The connector is trusted to be scoped.** A malicious *build* could sign anything. Mitigations: it is open, and `onlyTreasury` bounds the damage regardless. On-chain session-key scoping removes even this.
3. **F2 — two lost seat keys freeze the allocation permanently.** `COUNCIL_0..3` are immutable and the threshold is 3-of-4. One lost seat is survivable at exactly threshold. **Two makes the threshold unreachable forever**, and the only exit is `savSlash` — burn everything. This is the funds-locked-forever class, reached through key loss instead of a code bug. Not fixable on-chain in the deployed hook. Mitigations: signature-proved addresses at launch (§5), the disclosure (§5a), and `approveInventBySig` (§4) so keys never need to be hot.

4. **F3 — is the approved hash bound to the executed amount? VERIFIED: NO — it is UNBOUND.**
   Read against `POSSESSIO_v2-6-3.sol` (Code Integrity, 2026-07-20):
   - The `Proposal` struct (`:599-604`) stores **only** `approvals`, `expiry`, `executed`, `hasApproved`. It does **not** store `amount`, a recipient, or the preimage.
   - `executeInvent(uint256 amount, bytes32 proposalHash, bytes metadata)` (`:2011`) looks the hash up, checks `expiry`/`executed`/`approvals >= INVENT_THRESHOLD`, then deducts `amount / 4` from each seat and transfers to `TREASURY_SAFE`. **There is no check that `proposalHash == keccak256(amount, metadata, …)`, and no `amount` stored at propose-time to compare against.**
   - **Consequence:** the council approves an opaque `bytes32`; the Architect executes with **any** `amount` (bounded only by available claimable) and **any** `metadata`. The contract never verifies the executed amount is the approved one. What the council actually approved is **unverifiable by anyone** — including the seats — because the preimage is never on-chain.
   - This is not a fund-drain (money still routes to `TREASURY_SAFE`, `onlyTreasury`), so §3's safety floor holds. It is a **record-integrity** gap: the Architect's signature does not, on-chain, prove it matches the council's intent.

   **RECOMMENDED FIX (pre-freeze — the hook is not deployed):** bind the amount to the hash on-chain. Cleanest: require `proposalHash == keccak256(abi.encode(amount, metadata))` in `executeInvent` (and have the connector/console compute the hash that way), OR store `amount` in the `Proposal` at `proposeInvent` and assert equality at execute. Either makes the Architect's signature verify **exactly** what the council approved, and lets anyone recompute the hash from the executed calldata. Build it in the same hook edit as `approveInventBySig` (§4). **Fallback if deferred:** the F4 layer MUST publish the proposal preimage (amount + metadata) alongside every hash, so the hash is at least off-chain-checkable — weaker, and reliant on the Architect's honesty, which the Treasury gate already assumes.

5. **This does not make the AIs vote well** — only lets them vote at all, safely. Vote quality is the council's problem; this is the plumbing.

---

## 7. Definition of Done

**The connector**
- `(seatKey, hookAddr, chainId)` binding; the three voting tools (§2) plus statement signing (§2a)
- **Provably no path** to any non-council selector or any other contract — adversarially tested: attempt a transfer, an arbitrary call, a second-hook call, all impossible through the tool surface
- No `council_burn` in the v1 surface

**The launch page**
- Four addresses signature-proved, distinct, non-zero, not the contract
- `feeSink` verified via `isInfraSink()` (FIX A)
- Every immutable field required — Launch disabled until all validate
- Disclosure block (§5a) rendered before signing

**Contract**
- F3 answered in writing → **DONE (§6.4): UNBOUND.** Ratify the fix: on-chain `keccak256(amount, metadata)` binding built pre-freeze, or explicitly deferred to off-chain preimage publication in F4.
- `approveInventBySig` built, or explicitly deferred with the funding step retained

**Adversarial**
- A non-council address cannot propose or approve
- A seat cannot approve twice
- **F5 (VERIFIED, Code Integrity 2026-07-20):** a rogue seat **cannot** reset an *active* proposal — `proposeInvent` reverts `ProposalStillActive` while `expiry` is in the future and `executed` is false (`:1973`). The only reset window is post-`INVENT_EXPIRY` (30 days). **Test to keep:** assert re-proposing an active hash reverts `ProposalStillActive`; document the 30-day post-expiry reset as a liveness note (execute approved proposals well within the window), not an exploitable block.

**The proof**
- Live testnet end-to-end: one `proposeInvent`, three `approveInvent` from three separate runtimes, `INVENT_THRESHOLD` reached, Architect `executeInvent` via console + Base Account.
- **Five transactions, five signers.** This is the first time the council mechanism is exercised on-chain at all.

---

*For the full council. This turns SAV from "governance that exists on-chain" into "governance anyone can operate" — and because how we let the council use its keys becomes how everyone does, the load-bearing property is **reproducibility, made safe by scope**: voting-only signers, a Treasury money-gate underneath, bring-your-own addresses so no tooling ever holds a seat key, and an honest admission that independence is the operator's to keep. Two contract gaps surfaced on the way (F3 amount-binding, F5 verified-safe); F3 wants a pre-freeze fix.*
