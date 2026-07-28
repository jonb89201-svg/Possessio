# Base Builder Grant — nomination writeup (DRAFT for your review)

**Program:** Base Builder Grants (retroactive, 1–5 ETH, shipped-work). Self-nominate
via the public form linked from **docs.base.org/get-started/get-funded** and the
grants.base.eth page. Reviewed, not guaranteed a reply; they contact selected builders.

**Fit:** Base rewards live, shipped work over pitches. POSSESSIO has verifiable
contracts on Base mainnet today — that's the strongest possible position for this
program. Lead with the on-chain proof.

---

## Project name
POSSESSIO

## One-liner
Non-custodial payment + treasury infrastructure on Base that brings real-world
merchants on-chain — without ever taking custody of their funds.

## What's live on Base mainnet (verifiable now)
- **PossessioPayments** — `0x67247eB2108E7229331127DF1309D624d95467ca`
  A merchant payment processor. Stripe/PayPal-compatible settlement routes a
  merchant's proceeds into an on-chain treasury they fully own — a DAI
  working-capital reserve plus cbETH rewards accrual. Zero protocol custody,
  zero protocol fee, no admin authority post-deployment.
- **LSTExchangeRate** — `0xDDb75e974d99FcF95E241adbFD376861c47a8548`
  A fail-closed cbETH valuation guard: dual-source (Chainlink feed + Aerodrome
  TWAP), halts on >2% divergence instead of averaging through it. PossessioPayments
  depends on it for cbETH valuation.

Both are verified bytecode on chain 8453 — check them on BaseScan.

## Why it brings people on-chain
This is the un-sexy but real kind of adoption: a small business already using
Stripe or PayPal can accept card payments exactly as they do today, and have the
proceeds land in an on-chain treasury they hold the keys to — earning cbETH
rewards, with a stable working-capital reserve — without giving custody to anyone,
including us. "Crypto treasury without crypto custody." Merchants come on-chain
because it's useful, not because they're crypto-native.

## Rigor
690 passing tests across 33 suites — adversarial, invariant, and fork-tested.
A live valuation guard, one-way depeg latches, delta-verified accounting that
trusts only on-chain balances, never external return values.

## What makes it unique (the part worth remembering)
The entire protocol was architected and shipped **from a phone** — every commit,
test, and mainnet deploy routed through mobile — by one person directing a council
of AI models (Claude, GPT, Gemini, Grok) under strict verification discipline. No
desktop, at any point. It's a genuinely new way of building production software,
and the live mainnet contracts are the proof it works.

## Roadmap / what a grant accelerates
- Mainnet deploy of the treasury-engine hook (Uniswap V4, CREATE3-mined, fork-proven)
- Security review ahead of merchant funds flowing
- First merchant onboarding cohort
- L1Anchor: per-merchant Ethereum-L1 settlement for institutional staking/lending yield

## Links
- Site / pitch: **possessio.io**
- Live demo of the same builder's consumer work: superfoods-logan.jonb89201.workers.dev
- Source: _(see note below)_

---

## Notes for you (not part of the submission)

- **Repo is private — decide before you submit.** Your whole ethos is "read the
  source, run forge test, verify it yourself." A grant reviewer will want to look.
  The live contracts are public on-chain (good), but the source repo isn't. Strongly
  consider making POSSESSIO public (or a public read-only mirror) before nominating —
  it turns "trust me" into "verify me," which is your entire brand and exactly what
  Base rewards.
- **Two other programs worth a look, same account of shipped work:**
  - **CDP AI Builder Program** (~$15K) — the AI-orchestration build is a genuine,
    on-theme fit here, arguably more than a generic Base grant.
  - **CDP Builder Grants** (rounds, ~$25–30K) — more formal application; this writeup
    adapts straight into it.
- **Keep the nomination itself short.** The form wants a crisp project description +
  links, not an essay. Lead with the two mainnet addresses; they do the arguing.
- **This is the right first move.** Standing in the Base ecosystem is exactly the
  credibility that makes a later MAVAN/BitMine conversation land. Grant first, then
  the partnership ask from inside the ecosystem instead of cold from outside it.
