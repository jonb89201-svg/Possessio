# xtrade - Possessio Trading Agent MCP (v0.2, build-mode + facts layer)

Governed by [`RULEBOOK_TradingAgent.md`](../../RULEBOOK_TradingAgent.md)
(RATIFIED) and [`SPEC_CrossChainTradingMCP.md`](../../SPEC_CrossChainTradingMCP.md).
v1 scope: **pump.fun / Solana, pre-DEX window only.**

## The facts layer (closes AUDIT 2026-07-14 W-2)

Gate facts are no longer the caller's word. `facts.js` gathers every fact
the Sec0/Sec1/Sec2 gates consume **server-side**, each tagged with its
source, basis, and fetch status:

| Fact | Source (class) | How |
|---|---|---|
| `mintRenounced` | Solana JSON-RPC (1) | `getAccountInfo` jsonParsed: mintAuthority AND freezeAuthority both null |
| `creatorHoldingPct` | Solana JSON-RPC (1) | creator wallet balance if the radar tape carries the creator address; else the **top-holder conservative proxy** (`getTokenLargestAccounts` / `getTokenSupply`) - the substitution is stated in the fact's `basis`, never silent. Pre-graduation the proxy includes the bonding curve, so it over-refuses (fail-closed). |
| `onDexScreener` | DexScreener (2) | **R-1 semantics** (RADAR_FIX_R1R2): only NON-`pumpfun` dexId pairs count as discovery/graduation. The bonding-curve index entry (`dexId:"pumpfun"`, appears ~60s after birth) never trips the predicate. |
| `lpLockedOrBurned` | derived from (2) | pre-graduation there is no external LP - liquidity is the program-owned curve (verified by absence of non-pumpfun pairs). Graduated tokens: UNAVAILABLE, fail-closed. |
| `mc` | Solana JSON-RPC (1) + DexScreener SOL/USD leg (2) | **pre-DEX, chain-read:** the pump.fun bonding-curve PDA is derived locally (program `6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P`, seed `"bonding-curve"`+mint; derivation cross-validated against `@solana/web3.js` and pinned in tests), `getAccountInfo(base64)` decodes the u64 LE reserves (anchor discriminator checked, owner checked), and `MC_sol = (vSol/vTok) x supply / 1e9` - the EXACT `radar/screen.ts curveMcUsd` formula (same field order, same clamps, same divide-first overflow ordering) - priced with a single class-2 SOL/USD read (deepest-liquidity DexScreener wSOL pair, fetched once per call). Curve missing or `complete` (graduated) falls through to the class-2 DexScreener pair MC. **The radar tape is demoted to a cross-check**: >25% tape-vs-chain disagreement is logged in `basis`; chain wins. Once a pre-grad curve decodes, a failed SOL/USD leg is `UNAVAILABLE` (fail-closed) - never a downgrade to advisory sources. Tape/frontend remain fallbacks ONLY when the chain read itself is unreachable (then the fact is class 3 and hot honestly refuses). |
| `ageMin` | Solana JSON-RPC (1) | **chain-read:** `getSignaturesForAddress` walked oldest-ward (`before` pagination) to exhaustion; the oldest signature's `blockTime` is the token's first activity (null-blockTime entries skipped, counted). For the method's minutes-old targets this is one page. **Pagination bound:** capped at 5 pages x 1000 signatures - past the cap the fact carries the PROVEN LOWER BOUND on age ("older than N min"), which fails the 4-7min entry window in the fail-closed direction (a token with thousands of signatures is far past the pre-DEX window). Tape/frontend fallback only when the RPC read fails. |
| `sessionGate` | none yet | `/radar/session-gate` is queried but returns NO_READING_YET (nothing writes sessions). Result: `UNAVAILABLE` -> the server **REFUSES fail-closed**. |

**Fail-closed philosophy:** a fact that cannot be fetched is `UNAVAILABLE`
and `build_trade` refuses, naming the missing fact. There is **no**
downgrade to caller-asserted facts, ever. All fetches: 5s timeout, at most
one retry.

Caller-supplied `facts` are still accepted in the schema (continuity) but
are **untrusted hints**: gates run on fetched facts only, and any
divergence between asserted and fetched is written to the Sec5 ledger row
(`factsDivergence`). Ledger `factsSource` is `"chain-read"` when every
gate-critical fact fetched, `"chain-read-incomplete"` on a fail-closed
refusal.

### Hot-path precondition - now computed, never a constant

The old `FACTS_VERIFIED_ON_DEVICE = false` constant is gone. In its place
`facts.hotFactsGuard` runs **per call**: it passes only when every
gate-critical fact came from source class 1 or 2 (Solana RPC /
DexScreener) on that very call. With chain-read `ageMin`/`mc` (curve-PDA
decode + signature walk, above) a live pre-DEX token **can** now satisfy
the guard - live-verified 2026-07-15 (chain MC $8,438.28 vs tape $8,444.84
for the same tape candidate, chain age 8.24min vs tape-derived 7.81min).
Facts served by the class-3 fallback paths (RPC outage) still refuse, per
fact, per call.

**What still blocks hot** - the guard passing does NOT make anything hot:
`sessionGate` remains the final refuser (nothing writes the radar
`sessions` table, `/radar/session-gate` answers NO_READING_YET, so
`build_trade`/`execute_trade` refuse at Sec0 - correct and intended until
the radar grows a sessions writer), and Sec4 steps 3-5 (on-device verify,
key ceremony/dedicated wallet, only then `ALLOW_HOT`) remain open. The
three Sec4 gates (`ALLOW_HOT=1` + signer + `confirm:true`) remain required
and remain unwired.

## Env vars (facts layer - no secrets in the repo, env only)

| Var | Meaning |
|---|---|
| `SOLANA_RPC_URL` | direct Solana JSON-RPC endpoint (wins if set; also honors legacy `SOLANA_RPC`) |
| `SOLANA_MCP_URL` + `SOLANA_MCP_KEY` | alternative: the read-only `mcp/solana-mcp` Cloudflare proxy. The key is a **capability-URL path segment** (`<URL>/<KEY>/mcp`, per worker.js); it is also sent as `x-access-key` for forward-compat. Allowlisted read methods only. |
| `RADAR_URL` | radar tape base (default `https://possessio-radar.jonb89201.workers.dev`) |
| `DEXSCREENER_BASE` | default `https://api.dexscreener.com` |
| `PUMPFUN_API_BASE` | default `https://frontend-api.pump.fun` (age/MC fallback only) |
| `SESSION_GATE_OVERRIDE` | **ARCHITECT-ONLY**, supervised runs: `pass` lets Sec0 proceed while no live session data source exists. Logged as `OVERRIDE`, never as a measurement. A real `/radar/session-gate` reading, once a session writer lands, always wins over the override. |

## What is terminal-proven vs device-verify

**Proven here** (`npm test` -> 58/58, no network, no keys - the facts
layer takes an injected fetch and is tested fully offline):
- Sec4 execution model: `build` always on; `hot` downgrades/refuses
  unless all three gates fire AND per-call facts are chain-read.
- Sec3 caps: $2/trade, 10/day, $20/day, 200bps - server-enforced; env
  may only TIGHTEN, never loosen LAW.
- Sec2 F-1: a ticker is a refusal; only a base58 Solana mint passes.
  Rug gate (mint renounced / LP locked / creator <=15%) on FETCHED facts.
- Facts layer: chain-read mint authority; R-1 DexScreener semantics;
  conservative creator proxy; fail-closed refusals naming the fact;
  divergence logging; session-gate UNAVAILABLE refusal + override path;
  bounded retries; direct-RPC and read-only-proxy sources.
- Chain-read `ageMin`/`mc` (test/facts-chain.test.js): PDA derivation
  pinned against `@solana/web3.js`; curve decode pinned against a REAL
  mainnet account captured during the live verify; hand-computed MC math
  mirroring `radar/screen.ts curveMcUsd`; graduated/missing-curve
  fallthrough; single/multi-page signature walks, the 5-page pagination
  bound (lower-bound age fails entry fail-closed), null blockTimes;
  SOL/USD failure -> `mc` UNAVAILABLE; tape-vs-chain >25% divergence
  logged; full-chain-read call passes `hotFactsGuard` while sessionGate
  still refuses.
- Sec0 session gate and Sec1 method (entry band + four exit triggers).
- Sec5 ledger: append-only; caps count filled+built; truth counts filled.

**Device-verify** (network-blocked in the build sandbox, per Codebyte
Law NON-PROVEN until it runs on the Architect's device):
- `facts.js` against live RPC / DexScreener / radar endpoints.
- `adapters/jupiter.js` - live quote + unsigned swap-tx build.
- `server.js` end-to-end MCP wiring (needs `npm install`).

## Run

```
cd mcp/xtrade
npm install          # @modelcontextprotocol/sdk + zod
npm test             # constitution + facts layer, offline
npm run check        # syntax-check server + facts + adapter
```

Wire it via `mcp.json.example` (attaches on the NEXT session).

## Activation is bound (RULEBOOK Sec4)

1. Ratify rulebook - DONE.
2. Build MCP in build-mode - DONE (+ facts layer, this change).
3. On-device verify (quote -> build -> sign -> land) - **pending Architect**.
4. Wave key ceremony creates the dedicated trading wallet - **pending**.
5. Only then is `ALLOW_HOT=1` a discussable sentence.

Also still gated before hot can ever run end-to-end:
- ~~a chain-read source for `ageMin`/`mc`~~ - **DONE** (bonding-curve PDA
  decode + signature walk, this change; `hotFactsGuard` can now pass on a
  live pre-DEX token when every fact chain-reads on the call);
- a **session-gate data source** (something must write the radar
  `sessions` table; `/radar/session-gate` answers NO_READING_YET today) -
  **sessionGate is now the final refuser**: `build_trade` refuses at Sec0
  before the facts roll-up even matters, which is correct and intended;
- Sec4 steps 3-5: on-device verify, the wave key ceremony / dedicated
  trading wallet, and only then an `ALLOW_HOT` sentence;
- creator address on the radar tape would upgrade `creatorHoldingPct`
  from the conservative top-holder proxy to the exact creator balance.

There is no state in which a key exists and the rulebook does not.
`execute_trade` refuses honestly until Sec4 step 4 - and, independently,
until facts are chain-read per call.
