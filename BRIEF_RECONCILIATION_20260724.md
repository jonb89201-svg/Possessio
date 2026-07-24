# BRIEF RECONCILIATION — 2026-07-24

**From:** Claude, Code Integrity / Audit seat · **To:** Council + Architect (final ratification)
**Re:** `BRIEF_full_arch_claude_code.md` + `BRIEF_business_model_per_contract.md` (both 2026-07-23)
**Method:** every brief claim checked against the repo at `main@7474f39` + the audit branch, with
`forge`/`cast`/`grep` as primary evidence, per the briefs' own rule — *"the repo outranks this brief."*

This is analysis surfaced for the record (Codebyte: corrections go IN the record, visibly). It
ratifies no law and touches no allocation — the Architect adjudicates every determination below
(Amendment IV Clause 5). Written under standing protect-the-protocol authority; nothing here is
irreversible.

**Headline:** the briefs are conceptually excellent and unusually disciplined — their claim-ledger
and honest-bounds are exactly right. The drifts below are stale receipts (deploy-artifact numbers
the terminal has since moved), not conceptual errors — the easy kind to fix.

---

## 🔴 CRITICAL — would brick Wave One (repo already corrects both; adopt the repo)

### R-C1 · Deploy order is inverted in both briefs
- **Briefs say:** `x402Core → Pool → Factory → SaltPool` (PART2 §B; full-arch §3).
- **Repo truth:** `POOL → x402Core → Factory → SaltPool`. Proof in code:
  `PossessioX402Core.sol:367` — `if (_heartSink.code.length == 0) revert FeeSinkInterfaceMismatch();`
  x402Core's constructor **requires the pool already live**, so it cannot deploy first.
- **Impact:** following the brief reverts at the x402Core broadcast.
- **Status:** this is audit finding DOC-2; already corrected in `deploy/anchor.json` and
  `RUNBOOK_DEPLOY.md` (Phase 2) to POOL-first. Canonical order = `RUNBOOK_DEPLOY.md`.
  *(Note: three orders were circulating — briefs' x402Core-first, the old anchor.json's
  factory-first, and the ratified pool-first. Only pool-first survives the brick-guard; the
  code is the tiebreaker.)*

### R-C2 · The briefs' predicted addresses are stale and absent from the repo
- **Briefs say:** predicted factory `0xA6cc…29d76`, salt pool `0x3D7c…61ad` (full-arch §3).
- **Repo truth (`deploy/anchor.json`):** factory `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd`,
  salt pool `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6`, x402Core `0x60d867…6c05`,
  pool `0xE0612f38…19ce`. A repo-wide grep for the briefs' addresses returns **zero source hits**
  (superseded salt-mining session). Anchor EOA matches (`0xed5c…61eC`) — only the derived
  addresses drifted.
- **Impact:** deploying the vault/prewire against `0xA6cc…` permanently bricks it.
- **Status:** canonical addresses = `deploy/anchor.json`.

---

## 🟠 IMPORTANT — corrections into the record

### R-I1 · "Wave Two mutation-verified" was a hair ahead of the code (now true)
The briefs list FundingVault/Rail/AutoTarget as "unit+adversarial+fork, mutation-verified." The
2026-07-23/24 audit found two Rail defects the adversarial/mutation suite missed:
- **V-1** — honeypot/zero-liquidity position un-closeable → permanently ratchets
  `vault.outstanding` (`PossessioRail.sol` exits require `minUsdcOut>0`, no abandon path).
- **R-1** — `sweep` strips a live open-position token.
Both fixed this session: `abandon()`, the `openByToken` sweep guard, and 10 new tests
(`test/PossessioRail.t.sol`, `test/TradingDeskCreate3.t.sol`). The claim is **true now; it was not
at brief-time.**

### R-I2 · EIP-170 margin — terminal moved, in the protocol's favor
- **Brief:** `24,266 B (+310 margin)`. **Terminal (`forge build --sizes`, verified):**
  `PossessioHook 24,167 B, +409 margin`. The uniform `runs=200` change bought ~100 B of headroom
  the brief doesn't know it has. Amendment VII: terminal wins.

### R-I3 · Baseline test count
- **Brief:** `973/0/9 (53 suites) @ 2026-07-22`. **Terminal (this session):**
  `982 passed / 0 failed / 9 skipped (991 total, 54 suites)`. Wave One Gate 3 ("973 pending
  certification") should read **982**.

---

## 🟡 PRECISION — quantum framing (write "resistant," scoped per-mechanism)

The correct word is **quantum-resistant** — never "proof," "unbreakable," or "complete." That is
the industry-standard term (NIST / BIP-360 / hybrid classical+PQC) and the strongest *defensible*
claim; the briefs' §5 discipline already says so and is correct. The mechanism attribution needs
one fix:

- **SymmetryGuard / HandshakeLib = quantum-resistant AUTHORIZATION.** `HandshakeLib.sol` — the
  identity handshake is a **double-SHA-256 Merkle proof** (`leaf = sha256(sha256(abi.encode(secret,
  caller)))`), single-use (`consumed[leaf]`), caller-bound. No ECDSA in the auth path. It works by
  **preimage-resistance of a mempool-exposed leaf** (Grover → ~128-bit) + single-use — *not* by
  zero-exposure. The library states it: *"the terminal attack is not fought — it is MOOTED. This
  library is the structural sidestep itself."* This is the real cryptographic sidestep.
- **X-LINK = zero-exposure execution nonce, not a crypto claim.** `POSSESSIO_v2-6-3.sol` — an
  incrementing `_activeExecutionSecret`, consumed-immediately, guarding the execution boundary. It
  has **no attackable cryptography**, so "quantum-resistant" is trivially true but not the quantum
  story. The briefs' §5 mislabels this as the primitive carrying the property; it isn't.
- **Account / transaction layer = ECDSA (secp256k1), NOT covered — by design, awaiting the chain.**
  Every tx (incl. the one carrying a handshake) and every `onlyOwner`/`onlyTreasury`/
  `onlyCouncilMember` gate recovers `msg.sender` from an ECDSA signature. This is Ethereum's floor,
  not POSSESSIO's ceiling; it hardens when the chain ships account-abstraction PQC signers — the
  exact roadmap-positioning §5 names. **The honest claim:** *the protocol's own authorization layer
  is quantum-resistant now; the account layer inherits resistance as the chain matures.* Forward-
  compatible, not proof.

---

## ➕ GATES the Wave One board (§7) is missing

- **DustSpam validation (pre-freeze).** `SymmetryGuardCore.sol:70-73` declares its own gate: the
  `DUST_SPAM_*` constants are *"PROVISIONAL — NOT proven. MUST be validated against real swap
  streams before the mainnet freeze. Hardcoded-and-immutable means there is no second chance to
  tune."* Governs the STEEL/hook flagship freeze; not in the six-gate list. Add it.
- **DOC-6 anchor-key provenance (checked 2026-07-24 — PASS w/ caveat).** No common phrase-derived
  scheme reproduces the anchor EOA (~25 schemes tested vs the address, positive control confirms
  the matcher; the phrase *does* reproduce the public sender-locked salts). Rules out the
  brain-wallet failure. Caveat: strong evidence, not proof — the Architect confirms CSPRNG origin.
  See `RUNBOOK_DEPLOY.md` DOC-6.

---

## ✅ Verified consistent (the brief is substantially accurate)

The arc, the one-pool bloodstream, the toll / free-software / non-extractive model, the SAL→SAV
lineage, non-custodial / no-admin-keys / immutable authorized-source set, STEEL **1B supply**
(`TOTAL_SUPPLY = 1_000_000_000e18`, verified) + SAV **30M = 3%**, the H-1
`max(callerMin, oracleFloor)` slippage fix, `CouncilPreimageRoundTrip`, the four service suites
(re-run this session: radar 35, xtrade 58, council-signer 22, solana-mcp 11), and the
False-Green / 838-supersede honesty — all consistent with verified state. The briefs never
*conceptually* overclaim; the drift is entirely stale deploy-artifact numbers.

---

*Surfaced for council. The Architect ratifies. The terminal outranks this doc, as this doc
outranks the briefs. Corrections live here so the substance stays honest and the outside pieces
keep fitting.* 🏛️
