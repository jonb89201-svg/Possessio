# COUNCIL RECORD — Deploy Layer Status (repo council seat)

**Seat:** Code Integrity / repo-executor (Claude Code) — the repo's council seat.
**Execution:** on-chain broadcast + key custody + QuickNode are the operators' side.
**Branch:** `claude/repo-audit-h9m2ev`. **Status:** deploy layer BUILT + constellation PROVEN offline; line-211 edit + economic calibration are the remaining gates.

## Proven (offline, green)
`test/ConstellationCreate3Fork.t.sol` deploys all four organs through the real
CreateX to their exact `deploy/anchor.json` addresses; asserts the immutable wiring
(`saltpool.factory==factory`, `factory.saltPool==saltpool`, `factory.feeSink==pool`,
`pool.authorizedSources==[factory,x402Core]`); proves the self-funding door credits
`poolBalance` (not stranded) and a non-source reverts. 2 pass, 1 fork-gated skip.

## Anchor (phrase TREGUNA_MEKOIDES_TRECORUM_SATIS_DEE; Base-only; byte-20=0x00)
- factory  0x0DD06656cb9a38730a7177792C357E48cEdb49Bd
- saltpool 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6
- x402Core 0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05
- pool     0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce
- anchor EOA 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC (wave-duration key)

## Committed
anchor.json · derive_anchor.mjs · premine_salts.mjs · 4 CREATE3 deploy scripts
(gated, compile clean) · ConstellationCreate3Fork.t.sol (green) ·
SPEC_Factory_FeeSink_A.md · RUNBOOK_CONSTELLATION.md (supersedes nonce §III).

## Findings resolved
feeSink blocker -> A (ratified); x402Core-before-pool -> deploy order; mislabel ->
corrected; phrase-derivation -> adopted (byte-identical re-derive); factory
CREATE3-safe -> confirmed; front-run gate -> deploy->extcodehash->wire, factory-first.

## Remaining gates
1. line-211 A-edit authored + factory DoD (repo seat, in progress).
2. economic calibration: root, dustFloor, caps, floors, FLOOR_PER_UNIT, halflife
   (§22 hard gate; scripts env-gate them; NO placeholder broadcast).
3. operator env: keeper wallet, full operator/treasury Base Account address,
   DEPLOYMENT_FEE, TEMPLATE_CODEHASH (frozen build), x402Core deploymentFeeSource.

## Cleared
BASE_RPC_URL — QuickNode Base mainnet, live (chainId 8453), paid through Aug 1.

*Money-path changes still want the broader diverse review before the immutable freeze.*
