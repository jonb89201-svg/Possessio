# POSSESSIO — Competency Map

Maps demonstrated competencies to concrete evidence in the repo (files, tests, and recorded
decisions). Course numbers are intentionally **not** guessed — the right-hand column names the
competency *area*; align it to specific UNO course numbers with your advisor, because credit is
awarded against a specific course's learning outcomes, not against "impressiveness."

Evidence types: **[C]** code · **[T]** tests · **[D]** recorded decision/design · **[A]** audit.

---

## Core software engineering

| Competency area | Evidence |
|---|---|
| **Trustless / verifiable architecture** | Immutable + self-custody contracts (no fund-moving admin key, no upgrade proxy), open-source, testnet+mainnet both published, deterministic CREATE3 pre-wiring, and a dual-launch split to stay under the EIP-170 24 KB limit without a mutable proxy — "verify, don't trust." **[C][D]** `src/*.sol` (no proxy/owner-drain paths), `script/*Create3*.s.sol`, `test/ConstellationCreate3Fork.t.sol`, `foundry.toml`, `deploy/anchor.json`. |
| **Software architecture & systems design** | The closed-loop trading stack `PossessioFundingVault → PossessioRail → PossessioAutoTarget` (`src/`), the CREATE3 "constellation" pre-wiring, and the contract "spine" the console renders. **[C][D]** `src/PossessioFundingVault.sol`, `src/PossessioRail.sol`, `src/PossessioAutoTarget.sol`, `SPEC_RailAndKeeper.md`, `SPEC_FundingVault.md`. |
| **Test engineering / QA / verification** | ~1,100 tests spanning unit, adversarial/gauntlet, invariant, fuzz, FFI, and fork; documented growth arc 487→973; mutation-verified invariants. **[T]** `test/*.t.sol` (45 suites), `test/*Adversarial*.t.sol`, `test/*Gauntlet*.t.sol`, `test/*Invariant*.t.sol`; service tests in `radar/test`, `mcp/*/test`. |
| **Security engineering** | Self-authored full-repo audits with findings, fixes, and re-verification; EIP-712 replay protection; reentrancy/CEI discipline; a real HIGH found and correctly closed (council-ledger replay/auth). **[A][C]** `AUDIT_20260714.md`, `AUDIT_20260723.md`, `AUDIT_20260724.md`; `worker/index.ts` nonce-unique fix; `radar/migrations/0025_*`. |
| **Software process & governance** | A written constitution, dated amendments, versioned specs, and a ratification trail — evidence of disciplined decision-making over months. **[D]** `laws/POSSESSIO_Constitution.md`, `laws/MIB*.md`, `laws/STATEMENT_*`, `SPEC_*.md`. |

## Domain: blockchain / smart contracts

| Competency area | Evidence |
|---|---|
| **Solidity & the EVM** | 18 contracts, two live on Base mainnet; gas/size discipline (the hook sits 409 bytes under the EIP-170 limit — a real constraint that shaped the optimizer decision). **[C][D]** `src/*.sol`, `foundry.toml`, `COUNCIL_STATEMENT_optimizer_200.md`. |
| **Uniswap v4 hooks / DeFi mechanics** | A treasury-engine hook, fee capture/routing, LST exchange-rate valuation, non-custodial custody model. **[C]** `src/POSSESSIO_v2-6-3.sol`, `src/LSTExchangeRate.sol`, `src/PossessioX402Core.sol`. |
| **Applied cryptography** | EIP-712 typed-data signing with domain separation and replay protection; signature-preimage round-trip proven against the contract byte-for-byte. **[C][T]** `mcp/council-signer/signer.js`, `preimage.js`, `test/CouncilPreimageRoundTrip.t.sol`. |

## Domain: distributed systems / cloud

| Competency area | Evidence |
|---|---|
| **Cloud/serverless & data engineering** | Cloudflare Workers, a D1/SQLite datastore with a migration history, a cron ingestion pipeline with bounded-fetch discipline and self-diagnosing health checks. **[C]** `radar/*.ts`, `radar/migrations/*.sql`, `worker/index.ts`. |
| **API / protocol design** | Three MCP servers with authenticated, fail-closed endpoints (bearer + timing-safe compare), a read-only RPC allowlist, and a signed communication ledger. **[C][T]** `mcp/council-signer/`, `mcp/xtrade/`, `mcp/solana-mcp/`. |
| **Full-stack / web** | A single-page operator console with a live WebSocket cockpit, XSS-disciplined rendering, and a trading desk UI. **[C]** `public/index.html`, `worker/`. |

## Domain: artificial intelligence (for the BSAI)

| Competency area | Evidence |
|---|---|
| **Multi-agent AI orchestration** | "The council" — multiple AI agents tasked to propose and argue competing designs and test strategies, with a human architect adjudicating. This *is* the build method. **[D]** `laws/STATEMENT_council_*`, the AI-authored commit history under a human decision record. |
| **Human-in-the-loop AI governance** | A governance layer (constitution + ratifications) that constrains what the automated agents may decide vs. what requires the architect's sign-off; a cryptographically signed inter-agent ledger. **[C][D]** `laws/`, `mcp/council-signer/`, `worker/index.ts` `/api/council/ledger`. |
| **AI systems integration** | An AI trading desk that turns model/agent output into gated, capital-bounded on-chain actions with safety gates and caps. **[C]** `mcp/xtrade/`, `src/PossessioFundingVault.sol` (hard caps), `src/PossessioRail.sol`. |

---

### How to present this for credit

For each course you want credit for or to challenge: take that course's published learning
outcomes, find the 2–4 rows above that match, and be ready to **explain and modify the cited
code unaided**. Claim only what you can personally defend in an interview or a proctored
setting. Where your strength is architecture, test strategy, security reasoning, and AI
orchestration — lead with those; they are what you actually did.
