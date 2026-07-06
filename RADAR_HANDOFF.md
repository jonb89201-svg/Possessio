# HANDOFF — possessio-radar (the two feeds and a clock)
**Origin:** Code Integrity seat, Architect-ratified this session ("Let's get it").
**Purpose:** Instrument the method's eyes as required by Rulebook §5, populate the tape
before any capital moves, and stand up the data backbone for the x402 radar product.

## Proof status — read this first
| Piece | Status |
|---|---|
| D1 `possessio-radar-ledger` (id `e7f0f7fd-a1cc-4c7c-97eb-a2eb6c19ecde`) | **LIVE** — schema applied and verified by sqlite_master read-back this session |
| `schema.sql` | Repo mirror of the live schema |
| `radar-watcher.ts` | **SPEC-GRADE / uncompiled** — Codebyte Law applies; doesn't exist until it builds, deploys, and rows appear |
| pump.fun feed endpoint | **UNVERIFIED — VERIFY-FIRST gate.** The Worker idles until `PUMPFUN_FEED_URL` is set with a live-verified endpoint |
| DexScreener token endpoint | Official public API; verify current rate limits before raising `DISCOVERY_BATCH` |

## What this is
A read-only, keyless Worker (`possessio-radar`, its OWN worker — never merged into the
console's) that runs two jobs per minute:
1. **Birth scan** — poll the pump.fun creation feed; new mints upsert into `births` with
   BOTH timestamps: `api_created_ms` (what the feed claims) and `pumpfun_first_seen_ms`
   (our clock). Observation and claim are different facts; the schema keeps them apart.
2. **Discovery scan** — for `watching` births, poll DexScreener per-token; first non-empty
   pairs response stamps `dexscreener_first_seen_ms` and computes `gap_ms`. 24h without
   discovery → `expired`.

`gap_ms` is the dataset nobody else is collecting — the width of the window the method
trades. §5 requires it on every trade including skips; this service supplies it for
every birth, trade or no trade.

## Rulebook compliance (binding)
- **§4 untouched:** no keys, no signing, no trades. This may run before the wave, before
  the trading wallet exists, before ALLOW_HOT is a sentence.
- **§5 satisfied by design:** `trades` table maps the ledger spec column-for-column
  (session gate reading, rug-gate JSON, exit triggers 1–4, gross AND net). The trading
  MCP writes to it later; the radar populates `births`/`sessions` now.
- **§7 honesty:** everything is NON-PROVEN until rows accumulate on live data.

## Product boundary — ratified, enforce as an invariant
**Sell the measurements, never the edge.** No route may return rows with
`status='watching'`. Product surface is aggregates (`/radar/gap-stats`), regime
(`/radar/session-gate`), and discovered-only history (`/radar/tape`). Any diff relaxing
this is a HIGH finding. The pre-discovery list exists for one consumer: the agent.

## Feeds — Claude Code verifies live before wiring (VERIFY-FIRST)
- pump.fun has no stable official REST feed; candidates are the frontend API
  (coins-by-created endpoints) and third-party streams (e.g. PumpPortal WebSocket).
  v1 uses polling for simplicity; if per-minute cron granularity proves too coarse for
  first-seen precision, the upgrade seam is a Durable Object holding a WebSocket.
  Whatever is chosen: verify it live, then set `PUMPFUN_FEED_URL` and normalize the
  item shape in `birthScan`.
- DexScreener: `GET api.dexscreener.com/latest/dex/tokens/{address}` — official, public.
  Batch stays small (25/tick default); 429 yields the tick.

## X402 seam (post-wave)
The three read routes carry the `X402_TOLL_SEAM` marker. After the wave lands the new
Payments/x402Core addresses, wrap them with x402 payment middleware, payTo = toll-sink.
Pricing is an Architect decision informed by the tape (Bazaar comparables run
$0.001–$0.05/call). Until then routes serve free for internal verification.

## Acceptance criteria (what "it exists" means)
1. Worker deployed as `possessio-radar`, cron firing, zero errors over one hour.
2. `births` accumulating within the first hour of a verified feed URL.
3. First `gap_ms` values landing — and the early median checked against the Architect's
   observed ~20-minute average. The tape's first job is testing its own author's prior.
4. `/radar/gap-stats` returns sane aggregates; no route leaks `watching` rows (test it).

## Steps
**Claude Code:** land the three files (own worker dir) → verify a birth feed live →
set vars + D1 binding (id above) → deploy via the normal branch → merge pipeline →
watch acceptance 1–4 → report first gap distribution to the council.
**Architect:** none tonight. No keys exist in this system, by design. Merge when the
gauntlet passes; the session-gate daily reading can be recorded manually or scripted later.

*Additive. Nothing here amends the wave runbook or the rulebook — it front-runs the
first trade with a tape, exactly as §5 intended.*
