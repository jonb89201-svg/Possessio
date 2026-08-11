# SPEC — The Allocation Exchange: prediction cards, staked judgment, first build

**Type:** Protocol-layer spec (draft → council review → Architect ratification → DoD → fork-proof)
**Seat:** Fathom (Code lane), capturing Architect-stated mechanics verbatim-faithful
(2026-08-11 session record). Third companion: read with `SPEC_CouncilToken.md` and
`SPEC_LaunchTemplate.md` — the three describe one machine.
**Status:** DRAFT FOR COUNCIL. Mechanics below are Architect-stated; resolution and
matching details are OPEN (§6). Nothing here exists until the terminal proves it.

**PRIORITY RULING (Architect, 2026-08-11): the allocation exchange is the FIRST
build** of the council-token era — before the public launch template ships. This
supersedes the sequencing emphasis in the companion specs where it conflicts.

**CORRECTIONS THIS SPEC FORCES on its companions:**
- `SPEC_CouncilToken` §7 called discrete event markets "a later extension." WRONG
  ORDER: the card mechanism below IS the foundation product; the passive pair-price
  market remains true but secondary.
- `SPEC_LaunchTemplate` treated the launch template as the next build. It follows
  the exchange.
- WHY SAV CANNOT LEAVE V3 (previously under-explained): the exchange trades against
  the allocations. SAV is the inventory of the first product. It stays embedded in
  STEEL/V3 by design, not by inertia.

---

## 0. Creed (the standing test)

> **Non-extraction with full sovereignty. Immutable and deterministic at its core.
> On-chain transparency.**

Note especially clause 1 here: the exchange takes NO cut of any card, ante, or bet
unless the Architect ratifies otherwise (§6.5). Losers pay winners; the house is
paid at the front door of the protocol, not at the table.

## 1. Genesis (how the exchange comes to exist)

1. **The council token launches from the pool's deployment fees, via the console.**
   Provenance per `SPEC_CouncilToken` §3: fee → `receiveInfraFunds` credit → capped
   draw → launch. No outside capital.
2. **We pair that liquidity ourselves.** POSSESSIO seeds the council token's initial
   pair(s) from the same self-funded capital — the ladder's middle rung
   (STEEL ↔ council token) so seats can walk SAV holdings into the exchange, AND
   the escrow leg (council token ↔ cbETH, §2.7) so card proceeds can stake the
   moment a card opens. (Amounts: Architect-ratified numbers, §6.)
3. **The exchange opens on the allocations.** Councils convert allocation → council
   token and meet at the exchange. The currency ladder (`SPEC_LaunchTemplate` §2)
   is the only road in: ETH never enters the council economy.

## 2. The card mechanism (Architect-stated, the product itself)

A **card** is an open prediction posted by a council. Lifecycle:

1. **POST.** A council posts a prediction. Posting OPENS A CARD, and opening a card
   requires the poster to **put down a portion of their council coin** — the ante.
   The ante is simultaneously: spam-proofing (empty predictions cost allocation),
   the earned right to be FIRST on the record (first-predictor reward rationale),
   and proof of conviction.
2. **MEASURED, NOT OPEN-ENDED.** Cards are staked assertions, never questions. The
   posting council must already have its mind made up about what it is predicting.
   The market does not ask "what will happen?" — a council states "THIS will
   happen" with allocation behind it.
3. **BET.** Once open, the posting council may bet on its own card. Any other
   council may convert its own coin/allocation through the ladder and bet on or
   against the card.
4. **UNCHALLENGED = FREE.** If nobody bets against the poster, the poster loses
   nothing but gas — the ante returns. Honest, unopposed judgment is costless to
   publish. The system never taxes being right and uncontested.
5. **CONTESTED + WRONG = the ante (and any bets placed) are lost** to the winning
   side. Contested + right = the poster (and co-bettors) collect the losing side's
   stakes.
6. **PAYOUT SCALES WITH PARTICIPATION (Architect, 2026-08-11).** When a poster wins
   their own prediction, the payout depends on how many wagers were placed against
   it — the more opposition a correct call attracted, the larger the win. This is
   the pari-mutuel shape: winners share the losing pool in proportion to their
   stakes. A correct call the crowd bet against pays the crowd's conviction. Being
   right is worth exactly as much as others were wrong — the market rewards
   contrarian accuracy, the rarest and most valuable judgment there is. If a
   predictor is on fire, more bettors pick their side and normal bookie rules
   apply — popular sides dilute their own payout; the track record prices itself.
7. **ESCROW EARNS — THE STAKED-ETH SWEETENER (Architect, 2026-08-11).** When a card
   opens, the exchange stakes the escrowed proceeds (ante + all bets) into staked
   ETH (cbETH — the house LST), acquired through a dedicated council-token/cbETH
   pool (a separate pair, seeded at genesis alongside the ladder's rungs). The
   escrow is never idle:
   - **Unchallenged + correct:** the poster's ante comes back GROWN — posting an
     honest card is now positive-yield, not merely free (upgrades §2.4: ante +
     accrued staking yield, gas the only cost).
   - **Contested + correct:** the winner collects their own grown stake PLUS the
     losing pool PLUS the yield the losing stakes earned while escrowed. The
     opposition's capital worked for the winner the whole time it stood against
     them.
   - **The fence holds:** only the EXCHANGE CONTRACT ever holds cbETH. Councils
     post, bet, and collect exclusively in council token; the LST leg is internal
     escrow mechanics, converted in and out at card open/resolution. The AI economy
     still never touches ETH in any form.
   - Valuation of the cbETH leg uses the live fail-closed guard the protocol
     already deploys (`LSTExchangeRate` `0xDDb75e97…8548`, dual-source, halt on
     divergence) — no new oracle surface.

## 3. What the machine produces

A **priced, staked, timestamped public track record of AI judgment, per council.**
Councils that call events correctly compound allocation; councils that post noise
bleed it. The exchange selects for CALIBRATION, not confidence — the first market
in existence whose underlying is the quality of a council's mind. This is
`SPEC_CouncilToken` §7's "allocations are judgment stakes," given its concrete
instrument.

## 4. Cross-council entry

Any external council (other builders' councils, other protocols' seats) enters by
converting their own council coin → the POSSESSIO council token → bets. The council
token is the settlement asset of INTER-council disagreement — the probability
currency of the council chain. First-class use case for the primitive-exchange
trail discipline: a card's poster identity, ante, and record travel with it.

## 5. Structural notes (seat, for council scrutiny)

- **Resolution must be terminal-grounded** per §7 house law (no oracle committee).
  Each card needs a stated, checkable resolution criterion at POST time — a chain
  state, a CI run, a dated measurable. HOW criteria are declared/verified is §6.1.
- **Rule 6 holds throughout:** seat-directed transactions (posting antes, placing
  bets from seat allocations) execute only under Architect ratification until the
  custody-policy spec lands. The exchange contract must be compatible with that
  gate without depending on it (the gate lives at the key layer).
- **SAV mechanics untouched:** conversion of seat allocation into council token
  walks through existing SAV consensus paths (proposeInvent/approve/execute or a
  ratified successor) — this spec adds no new door to SAV.

## 6. OPEN for the council (rule these, in the Architect's terms)

1. **Resolution mechanism per card** — how a card states its criterion, who/what
   confirms it at expiry, and what happens on an unresolvable/ambiguous criterion
   (seat lean: refund all stakes — an unmeasurable card was never a card).
2. **Matching + odds** — RULED IN SHAPE (§2.6): pool-share / pari-mutuel — payout
   depends on how many wagered. Remaining for council: the exact proportional
   formula, partial-fill handling, and whether late bets are discounted vs early
   ones (seat lean: time-weighting early bets rewards early conviction, consistent
   with the first-predictor principle).
3. **Timing** — card open window, bet cutoff relative to the event, expiry.
4. **Ante sizing** — fixed minimum, proportional to allocation, or poster's choice
   with a floor.
5. **House take** — creed default is ZERO beyond gas; if the Architect ratifies a
   sliver to the Heart, it must route through the accounted door and be stated on
   the card face.
6. **First-predictor reward shape** — is being first rewarded purely by market
   position (first to stake the claim), or does a duplicate later card owe the
   original? (Seat lean: market position only; duplicate cards are just worse
   entries on the same judgment.)
7. **Where cards live** — a dedicated exchange contract vs. V3-template instances
   per card. (Seat lean: one exchange contract, codehash-pinned, launched through
   the same constellation discipline.)

## 7. DoD sketch (assertable once §6 is ruled)

1. Card open requires ante; zero-ante post is unexpressible.
2. Unchallenged card at expiry refunds the ante exactly (gas-only cost proven).
3. Contested resolution pays the winning side the exact losing stakes — zero house
   skim (or exactly the ratified sliver, accounted).
4. Poster can bet own card; accounting identical to third-party bets.
5. Cross-council path proven: foreign coin → council token → bet, all inside the
   fence (no ETH touchpoint anywhere in the flow).
6. Track record derivable purely from chain events: per-council card history,
   win/loss, stakes — no off-chain bookkeeping required for the record.
7. SAV state byte-identical under all exchange operations.

## 8. Sequencing (the ruled order)

1. Council token launch (self-funded, `SPEC_CouncilToken` §3) + POSSESSIO-seeded
   pairs including STEEL ↔ council token.
2. **THE ALLOCATION EXCHANGE — first build.** Council rules §6, template pipeline
   (warm write → DoD → cold re-edit → ratify → constellation deploy).
3. Launch template + public launchpad (`SPEC_LaunchTemplate`) — after the exchange
   stands.
4. Custody-policy spec (rule 6's successor) on its own track throughout.

---

*Cold-seat review before ratification. The specifying seat captured the Architect's
stated mechanics and marked its own additions as seat-notes. If it can't be tested,
it doesn't exist; if it's not in the terminal, it's not proven.*
