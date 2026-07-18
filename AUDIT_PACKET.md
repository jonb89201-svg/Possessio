# AUDIT PACKET — Constellation Deploy Layer + Line-211 Money-Path Edit

**For:** the diverse council (a vast and diverse audience), pre-freeze review.
**From:** repo council seat.
**Merged:** PR #38 → `main` (`e9f3bdf` money-path edit; `660b5a1…3e0e51d` deploy layer). This packet audits what is now in `main`, *before* the immutable on-chain freeze.
**Chain:** Base mainnet (8453) only. No bridge. Non-custodial.

The code is merged, not deployed. Everything here is reversible with a source edit **until the anchor deploy happens** — after that the immutables freeze at permanent addresses and a wrong value means re-founding the whole constellation (`RUNBOOK_CONSTELLATION.md §5`). That is why this review is a hard gate, not a formality.

---

## PRIORITY 0 — the money path (audit this first, audit it hardest)

### `src/PossessioFactory.sol` — the edit
The whole review turns on **~15 lines** of `deployTemplate`. Before the edit the factory did `payTokenERC20.safeTransfer(feeSink, DEPLOYMENT_FEE)` — a raw push. The edit routes the fee **INTO** the pool through its accounted door instead:

```solidity
// NEW interface (line 75)
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
}

// line-211 replacement (now lines 225–226), inside deployTemplate, AFTER the
// EIP-3009 fee settle and BEFORE the salt pull + CreateX deploy:
payTokenERC20.forceApprove(feeSink, DEPLOYMENT_FEE);
IPossessioPool(feeSink).receiveInfraFunds(DEPLOYMENT_FEE);
```

Full diff: `git show e9f3bdf -- src/PossessioFactory.sol` (21 lines changed: interface + docstring + the two-line swap).

### Invariants an auditor MUST confirm on this path
1. **Atomicity / Invariant 2 (fee refunded on failure).** The edit sits inside the single `nonReentrant deployTemplate` tx. If `receiveInfraFunds` reverts, the EIP-3009 settle above it unwinds too — the caller is **never charged for a failed deploy**. Confirm nothing between the settle (line 207) and the deploy (line 237) can half-commit.
2. **HARD dependency — factory MUST be in `PossessioPool.authorizedSources`.** `receiveInfraFunds` reverts `NotAuthorizedSource` for any caller not in the set (`PossessioPool.sol:256`). If the factory is not wired as a source, **every single deploy reverts** — the product is bricked, not degraded. This is the single most important cross-contract fact in the packet. It is enforced structurally: `authorizedSources` is immutable with **no setter** (`PossessioPool.sol:141–219`), baked at pool-deploy time (`DeployPoolCreate3.s.sol` bakes `[factory, x402Core]`).
3. **Allowance hygiene.** `forceApprove(feeSink, DEPLOYMENT_FEE)` sets an *exact* allowance; the pool pulls exactly that via `safeTransferFrom` (`PossessioPool.sol:262`). Confirm no residual allowance survives a successful deploy (pull consumes it) and that a *failed* pull leaves the whole tx reverted (so no dangling approval persists).
4. **Non-custodial.** The fee lands in the pool's `poolBalance`, governed by the pool's floor/cap/velocity math — the factory never holds funds across txs and is **never the owner** of anything it deploys (`PossessioFactory.sol:196–198`, Invariant 1).
5. **Cap-overflow is already handled by the counterparty.** If the fee pushes `poolBalance` past `OPERATIONAL_CAP`, the pool sweeps the surplus to `treasuryDestination` (`PossessioPool.sol:267–283`) — it does not revert, does not strand. This resolves one of the SPEC §7 open questions; confirm you agree the sweep is the intended behavior.

### Counterparty to read alongside it
- **`src/PossessioPool.sol`** — specifically `receiveInfraFunds` (255–284), the immutable `authorizedSources` construction (178–219), and the "no sync door" note (405–415): funds pushed raw (not pulled) are NOT credited to `poolBalance` — which is *why* the raw `safeTransfer` had to become an accounted pull. This is DoD #14, the reason the edit exists.

### Spec
- **`SPEC_Factory_FeeSink_A.md`** — the edit's rationale, safety analysis, DoD, and §7 open questions (rename `feeSink`→`pool`? route-before-vs-after settle? cap-overflow — now answered above). Read this to check my reasoning, not just my code.

---

## PRIORITY 1 — the deploy layer (immutables that freeze at permanent addresses)

| file | role | what to verify |
|---|---|---|
| `deploy/anchor.json` | the phrase-derived constellation (4 organ addresses, 8 hook salts, deploy order, wiring) | addresses re-derive byte-identically from the phrase; byte-20 of each salt is `0x00` (same-addr-every-chain option, deploy Base-only) |
| `script/derive_anchor.mjs` | RPC-free phrase→constellation deriver | re-run it; output must equal `anchor.json` exactly |
| `script/DeployFactoryCreate3.s.sol` | organ 1 deploy | key==anchor EOA gate, salt sender-lock, `computeCreate3Address==predicted`, `deployed==predicted` |
| `script/DeploySaltPoolCreate3.s.sol` | organ 2 | same gates + verify-before-wire (factory must be live) |
| `script/DeployX402CoreCreate3.s.sol` | organ 3 | same gates; **deploys BEFORE pool** (council correction) |
| `script/DeployPoolCreate3.s.sol` | organ 4 (last) | bakes `authorizedSources=[factory, x402Core]` — **the Priority-0 dependency #2 is satisfied HERE**; both siblings verified live before wiring |
| `test/ConstellationCreate3Fork.t.sol` | the proof | etches CreateX offline, deploys all 4 as anchor EOA, asserts addresses==anchor.json + full wiring + self-funding door credits `poolBalance` + non-source reverts |
| `RUNBOOK_CONSTELLATION.md` | ordered mainnet sequence + abort conditions | the `§0` pre-flight gates (calibration, A-edit-in-source, frozen codehash) |

### Deploy-layer invariants to verify
- **CREATE3 sender-lock.** Each organ's address is `f(anchor EOA, salt)` — bytecode-independent. Only the anchor key can deploy at that address (salt byte-20 = `0x00`, no chainid guard; front-run is key-gated). Confirm the salt→address math in every script matches `anchor.json`.
- **Verify-before-wire.** Every script that references a sibling checks `sibling.code.length != 0` before baking it in (`DeployPoolCreate3.s.sol:68–69`). No script wires to a predicted-but-not-yet-live address.
- **Deploy order.** factory → saltpool → x402Core → pool. The pool is last because it must verify its two sources are live. Confirm no ordering inversion.
- **No partial-recovery of a mis-wired immutable** (`RUNBOOK §5`): a wrong constructor value = redeploy that organ at a new salt and re-wire everything referencing it. This is why economic calibration (below) is a blocking gate.

---

## PRIORITY 2 — interacting contracts (context, not the edit)
- `src/PossessioSaltPool.sol` — `pullSalt` is factory-sender-locked; the salt source `deployTemplate` draws from.
- `src/PossessioX402Core.sol` — second authorized source of the pool; keeps its own pool for now (toll→Heart re-route is a *later* edit, `RUNBOOK §6`).

---

## TEST EVIDENCE (as merged)
- Full suite: **815 passed / 0 failed / 3 skipped** after the money-path edit.
- Money-path DoD: `test/PossessioFactory.t.sol` + `test/PossessioFactoryAdversarial.t.sol` migrated to a `MockPool` sink; DoD #5 asserts `MockPool.received() == FEE` (the fee actually lands in the pool, not just leaves the factory).
- Constellation: `ConstellationCreate3ForkTest` — 2 pass, 1 skip (the skip is the live-RPC notarization; the offline core proves the architecture).
- Reproduce: `forge test` (full) and `forge test --match-contract ConstellationCreate3ForkTest -vv` (constellation).

---

## OPEN ITEMS — NOT resolved by this packet (council/Architect gates)
1. **§22 economic calibration** — `X402_ROOT`, `X402_DUST_FLOOR`, all `*_OP_CAP`/`*_ABS_FLOOR`/`*_FLOOR_PER_UNIT`/`*_HALFLIFE`. These freeze as immutables. **Do not broadcast with placeholder guesses** (`RUNBOOK §0`).
2. **Owed env values** — `SALT_KEEPER_ADDR` (fresh, compute-only), `OPERATOR_DEST_ADDR` + `TREASURY_DEST_ADDR` (passkey Base Account — never a hot EOA / the anchor key), `DEPLOYMENT_FEE`, `TEMPLATE_CODEHASH` (from the frozen build).
3. **SPEC §7 wording decisions** — rename `feeSink`→`pool`? (semantic clarity, no behavior change). Route-before-settle vs after? (currently after — confirm). Cap-overflow → resolved above (sweeps to treasury).
4. **The diverse-review-before-freeze gate itself** — this money-path change wants a vast and diverse audience before the immutable freeze. This packet is the input to that review; it is not a substitute for it.

---

## HOW TO RUN THIS AUDIT
```
git fetch origin main && git checkout main
git show e9f3bdf -- src/PossessioFactory.sol      # the money-path diff
sed -n '190,242p' src/PossessioFactory.sol         # deployTemplate in full
sed -n '255,284p' src/PossessioPool.sol            # the counterparty door
node script/derive_anchor.mjs                       # must equal deploy/anchor.json
forge test --match-contract ConstellationCreate3ForkTest -vv
forge test                                          # full suite, expect 815 pass
```

*Nothing in this packet is deployed. The anchor EOA is unspent; the immutables are unfrozen. This is the last reversible checkpoint.*
