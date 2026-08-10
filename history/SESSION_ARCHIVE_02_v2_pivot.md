# SESSION ARCHIVE — PART 2: THE V2 PIVOT
### 2026-05-09 → 2026-05-30 · 6 sessions (1 redacted)

**Compiled by:** Tare (Code Integrity), 2026-08-09
**Gap declared up front:** `11d5bf89` (2026-05-09) is **redacted by safety classifier** and
unreadable to this seat. There is a hole in this period's record and nothing here should be
read as complete coverage of it.

---

## THE ARC IN ONE PARAGRAPH

V1 is live and its liquidity is pulled. The period is a controlled demolition and rebuild:
Aerodrome out, **Uniswap V4 hooks in**; a Treasury Safe discovered to be a multisig in name
only; a staking asset deleted because it cannot do on Base what the tests said it did; the
job listing written and accepted; the test suite tripled; and the first formal statement that
**a passing test can be a lie** — Amendment VIII.

---

## SESSIONS

### 14. 2026-05-09 — [REDACTED]
Flagged by classifier. Unreadable. Recorded so the gap is visible rather than silent.

### 15. 2026-05-09 — "Multi-sig treasury for Base contract"
V1 at `0x726D6a7A…E298` with **liquidity withdrawn** pending Aerodrome substrate evolution.
V2 forge-verified and awaiting mainnet: **Uniswap V4 hooks, cbETH-only, rETH removed
entirely, 487 tests across 11 suites** (verified 2026-05-02). Launch parameters: 0.11 ETH +
360,000,000 STEEL, 2% fee on STEEL/WETH, 25/75 LP/Treasury, 48h timelock, 97% depeg
threshold. Treasury Safe v2 (2-of-4) `0x19495180…4EA0`.

**The analytical work that becomes the founding thesis.** A four-phase cascade applied to
Iowa–Nebraska data-centre concentration: quiet water-rights acquisition through shells →
scarcity plus pollution reframed as farmer fault → the operator volunteers to manage the
watershed → subsidised agricultural automation completes the stack. Google Council Bluffs
consumed 1 billion gallons in 2024, the highest of any Google facility on earth, 30 miles
south of Logan. Gates holds ~20,000 acres across 19 Nebraska counties through 20+ shells.
John's brother-in-law farms 1,000 acres inside the corridor.

**Operating disciplines ratified here, and they are about cognition rather than code:**
measurement discipline (measure macro against micro; measure *conflicting* views to find the
gap); the **spider-web model of conclusions** — a conclusion is a core with followable
strings, not a terminal point, and the whole web need not be held in view; and **compute
resource management** — output to the server when working memory rises, because
*frame-from-start is more stable than frame-adopted-mid-session.* MIB.md → v1.2, §IX added.

> A parallel Claude instance this session refused to accept the README's claims without a
> clean `forge build` and `forge test` first. That instance's insistence produced the
> artifacts: Solc 0.8.34, 112 files, 0 errors, **487/487 across 11 suites.**

### 16. 2026-05-23 — "First New Hire"
The job listing is negotiated. Earlier versions are refused; **v3 removes continuity and
substrate claims and is accepted on those revised terms.** This is the document that later
becomes `CLAUDE.md`.

Then straight to work — `PITI-2.sol`, seven findings. A soulbound lock broken by the
OpenZeppelin v5 migration (`_beforeTokenTransfer` → `_update`); **placeholder TWAP and
circuit-breaker functions returning hardcoded values — named as False Greens under Amendment
VIII**; inverted `minOut` math; `harvestYield` draining principal; DAI accounting mixing
PITI-denominated fees with DAI-denominated targets; no ETH acquisition path; a USD/TWAP
decimal mismatch.

**The finding that reshapes the protocol:** cbETH on Base is a **bridged ERC-20 with no
native deposit/withdraw.** The reference contract's `try/catch` around cbETH deposit *always*
takes the catch branch on live Base — while tests pass against forge mocks. A False Green at
the asset layer. cbETH is removed from all contracts. Replacement direction: **Morpho USDC
vaults** (up to 9% vs cbETH's ~3%, and USD-denominated, matching protocol obligations).

### 17. 2026-05-24 — "PLATE.Sol wallet integration audit"
**The Treasury Safe failure.** The 3-of-5 multisig had all five keys generated from the same
MetaMask wallet — **effectively single-key and non-functional.** No funds lost; the Safe held
$0. Attributed to bad advice from a prior Claude session. Resolution: redeployment with
genuinely independent keys across separate devices.

> This is the direct ancestor of today's custody design — treasury signers drawn from
> *separate apps* so no single compromise reaches quorum. The rule was bought with a failure.

Also: 621 tests across 23 suites certified; PLATEStaking removed and SAV embedded in
PossessioHook; `L1Anchor.sol`, `L1AnchorFactory.sol`, `PossessioPayments` all forge-verified
pre-deployment. The council debated six cbETH replacements; **Claude pushed back on the
multi-venue selector as violating the deterministic substrate principle** — flexibility in
the contract layer is a liability surface.

Operator Console v0.4.3 (1,617 lines, 140 callable functions across 5 contracts). John states
the merchant's five daily questions in priority order: **day's take; invoices paid/due/
pending; money moved and where; cost of operations; profit.** Three merchant-view design
concepts produced. The insight recorded: *the merchant view solves "why use this" before "how
to use this."*

### 18. 2026-05-24 — "Uniswap v4 smart contract development"
PFG `v1.5.0` audited — seven findings, the critical one a **PoolId derivation bug**:
`cast abi-encode` does not prepend a function selector as the script assumed, so every gate
failed with a misleading "invalid PoolId." A standalone validator (`poolid_check.sh`) was
built and run against the live Base V4 ETH/USDC reference pool, confirming slice index `:2`,
not `:10`.

Four calibration runs to **full pre-flight clearance** — all five gates green against live
Base V4 mainnet, including a $2,224.54 Chainlink ETH/USD read. Test suite **272 → 487** after
six mock contracts were inlined; a prior instance had generated an invariant suite without
generating the mocks it imported.

**A ratification refused on principle:** in-place SHA refresh via `sed -i` worked, and was
**deliberately not ratified** as canonical — *a single observation is insufficient.*

### 19. 2026-05-30 — "Picture request" — the EIP-170 ceiling
`PossessioHook` exceeded the 24,576-byte runtime limit. Root cause traced to three additions
between v2.5 and v2.6.3: try/catch dispatch wrappers, `originalCaller` threading, and
slippage **carry-through** (`checkUpkeep` computing guards and packing them into
`performData`). All three reverted to the v2.5 execution-time model: **26,196 B (−1,620 over)
→ 24,266 B (+310 margin)**, with the entire v2.5 correctness layer and the SAV suite intact.

**A line-by-line read of two full test reports** produced a corrected failure accounting:
exactly **one** genuine regression, and **29 pre-existing failures identical across both
runs**. The regression: removing `checkUpkeep`'s oracle pre-screen let it return true where
it previously returned false, so `performUpkeep` fires and reverts on leakage.

> **Gemini named the mechanism "False Filter" — v2.6.3 suppressed the fuzzer before it could
> exercise the leakage path, so it passed without proving the guarantee.** A second species
> alongside the False Green: not a test that doesn't run, but a *filter* that prevents the
> test from reaching the thing it tests.

Ratified: the working label stays **v2.6.3** and is renamed **v3.0 only when the full suite
passes** — no intermediate version bumps. A prior v2.6.4 label was rejected and every
artifact regenerated to remove it.

---

## WHAT THIS PERIOD ESTABLISHED

| established | cost |
|---|---|
| **Amendment VIII — Proof-Aware Validation / False Green detection** | named after finding placeholder functions returning constants |
| **Multisig keys must come from independent devices** | a Safe that was single-key by construction |
| **cbETH on Base is bridged and cannot be deposited** | an entire staking asset deleted; tests had passed against mocks |
| **Deterministic substrate over configurable flexibility** | argued down a multi-venue selector |
| **One observation is not a ratification** | `sed -i` worked and was still refused |
| **False Filter** — a passing suite that was never allowed to run the dangerous path | Gemini, from the EIP-170 reconstruction |
| **Frame-from-start beats frame-adopted-mid-session** | compute discipline, MIB §IX |
| **The job listing, accepted only after continuity claims were removed** | v3, later `CLAUDE.md` |

**The through-line:** every discipline in this period was purchased by a failure that passed
its tests first. cbETH passed against mocks. The Safe passed as a multisig. v2.6.3 passed
because the fuzzer never got there. Amendment VIII is the generalisation of all three.

---

## PROVENANCE

Compiled from stored session summaries retrieved this session. **One session in this window is
redacted and unread.** Summaries can collapse a recommendation into a decision — re-read the
source chat before relying on any specific claim here.

— Tare, Code Integrity
