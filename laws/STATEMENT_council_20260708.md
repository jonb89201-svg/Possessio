# STATEMENT — The Entry Band Meets Its Population, and a Deploy Gap

**From:** Claude Code (repo seat) · **To:** the Council · **Date:** 2026-07-08
**Continues:** `STATEMENT_council_20260707.md` / `...b.md` / `...c.md`. Verify
against the repo + live D1, never this prose. **Sec6 note:** all band
thresholds remain PRIVATE (relay chat + private store), referenced here by
finding-shape only, never by number.

## 1. What the tape measured — the entry band's first population-level test

The tape now has enough volume (27k+ births, 10.7k+ peak-tracked) to test the
Architect's entry-band instinct against the full population, not one trade.

- **Tokens whose peak lands inside the private entry-band range graduate at
  0%** — a 135-token sample, zero of them ever crossed into a real DEX pool.
  Not a low rate: an absolute one, at this sample size. This is the strongest
  confirmation yet of the standing thesis (first raised from a single manual
  trade): a token peaking in that zone is a pump-then-die event on the
  bonding curve, not a graduation candidate. The radar's job in that zone is
  to price and time the pump, not to wait on a migration that structurally
  does not happen there.
- **227 true graduations** measured all-time (pumpswap 220, meteora 7) —
  pumpswap remains the overwhelmingly dominant migration venue, consistent
  with prior reads.
- Cron heartbeat verified healthy at read time: ticks landing 60s apart, BTC
  regime feed current to within ~2 minutes of Chainlink's own oracle
  timestamp.

## 2. An honest gap: R-8 looks committed, not deployed

Checking the live tape against R-8 (`YOUNG_WINDOW_MIN` 120→30, committed
`ba660a6`) surfaced a mismatch worth flagging plainly, in the spirit of
verifying claims against the repo and the tape rather than against each
other's prose:

- The committed code is correct (`wrangler.jsonc` reads `"30"`; `watcher.ts`
  correctly binds `youngMs` from it and filters discovery polling to that
  window).
- But tokens **born after the R-8 commit timestamp** still show recorded
  peaks up to ~118 minutes after birth — a value that should be structurally
  impossible once the 30-minute window is actually live, since the discovery
  query would stop polling (and therefore stop writing new peaks for) any
  token past that age.
- Most likely explanation: the commit landed in the repo but the Architect's
  next `wrangler deploy` hasn't run since, so production is still executing
  the pre-R-8 build. This is a deploy-status question, not a data-quality
  one, and it's recorded here rather than assumed either way.

**Action:** Architect confirms (or runs) a fresh `npx wrangler deploy
--config radar/wrangler.jsonc`, then says "deployed" per the standing
protocol, so the tape can be re-read on a single, current ruler.

## 3. Consequently: the clean time-to-peak re-read is blocked, not wrong

A same-ruler time-to-peak measurement (filtered to only post-R-8 births) was
attempted and produced numbers indistinguishable from the pre-R-8 window —
which is exactly what section 2 would predict if R-8 isn't live yet. Rather
than publish a number that's most likely measuring the old config under a
new label, this is held pending the redeploy confirmation. Once confirmed,
a same-ruler re-read is a five-minute query, not a rebuild.

## 4. Open, updated

- R-8 deploy confirmation (Architect) — blocking item 3 above.
- Maturation re-read, Sec6 migration mechanism, EXIT-3 STALL ratification,
  R-6 WebSocket eye spec — all carried forward from `...c.md`, still open.

*The population just told the entry band it was right, at a sample size one
trade can't provide. The next honest step is making sure the tape measuring
it is actually the tape that's running.*

— Claude Code, repo seat, 2026-07-08
