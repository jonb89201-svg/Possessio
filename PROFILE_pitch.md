# Freelance Profile — Jon Solo

_Paste into Upwork / Fiverr / Contra / a portfolio page. Fill the [RATE] bracket before posting._

---

## Headline

Systems architect & AI-orchestration developer — I ship live mainnet contracts and full-stack apps, built entirely from a phone. Verifiable proof, not mockups.

---

## Overview

Most profiles show a mockup. I'll show you shipped, verifiable work instead — and every line of it was built and deployed **mobile-only, from a phone.** Live Solidity on Base mainnet, a full-stack consumer app, a self-running data platform: no desktop, no "we used a real computer for the hard parts." That's not a gimmick — mobile-only forces a discipline (one command at a time, atomic commits, verify after every push) that shows up directly in the rigor of the work.

**Live on Base mainnet — check them on BaseScan right now:**
- **PossessioPayments** `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91` — non-custodial merchant payment processor (Stripe/PayPal-compatible settlement, treasury routing, zero protocol custody).
- **LSTExchangeRate** `0xDDb75e974d99FcF95E241adbFD376861c47a8548` — fail-closed dual-source cbETH valuation guard (Chainlink feed + Aerodrome TWAP, halts on >2% divergence).

Those are part of POSSESSIO — a deterministic, non-custodial DeFi protocol on Base with an Ethereum-L1 settlement extension: Uniswap V4 hooks (CREATE3 salt-mined, bytecode-independent addresses), Chainlink Automation, a per-merchant institutional-settlement architecture, and **700+ tests across 37 suites** (run `forge test` for the live tally). I architected the system and directed a multi-model AI build (Claude, GPT, Gemini, Grok) through rigorous verification — designing the principles, routing the work, adjudicating decisions, and gating every deploy on a green two-chain test sweep. The entire body of work was produced **mobile-only** — built and shipped from a phone.

**And a live consumer app, built solo end-to-end:**
- **https://superfoods-logan.jonb89201.workers.dev** — an installable app for a small-town grocery store: live inventory synced from the store's vendor data feed (~600 items, real prices and photos, auto-updating), the weekly ad as its own curated view, offline support, and an Android/Play Store packaging pipeline. Serverless backend, its own database, self-updating. In use right now.

### What I actually do

- **Systems architecture & AI orchestration** — I design the system, then direct multiple AI models to build it under tight structural discipline: documented principles, procedural governance, verification after every step. This is how POSSESSIO shipped — and it's a repeatable way to build fast without sacrificing rigor.
- **Smart contracts** — Solidity, Foundry, Uniswap V4 hooks, CREATE3, Chainlink (feeds + Automation), adversarial/invariant/fork testing. Live mainnet deploys, not testnet demos.
- **Backend & edge** — Cloudflare Workers, D1, KV, cron-driven pipelines. Self-running systems: one polls live market data every 60s, self-corrects its own measurement biases, and has run unattended for days.
- **Frontend & mobile** — PWAs, service workers, offline caching, responsive UI, PWA-to-Play-Store packaging.
- **Data integration** — reverse-engineering client-rendered SPAs and undocumented APIs into clean, normalized feeds.

How I work: verify before shipping, report what actually happened (including failures), and scope honestly rather than oversell. Open to contract work, one-off builds, or ongoing collaboration if the scope and price line up.

**Rate:** [RATE — e.g. "$__/hr" or "Projects starting at $___"]

---

## Notes for you (delete before posting)

- **Rate** is the first filter clients apply. Pick a number even if you adjust later. Your range (live mainnet Solidity + full-stack + AI orchestration) is not entry-level — don't lowball. Blockchain/Solidity contract work commonly runs $75–150+/hr; you can anchor high and let scope negotiate down.
- **The AI-orchestration framing is your differentiator, not a liability.** It's true to the repo (the README says exactly this), it's rare, and "ships verified mainnet contracts by directing a multi-AI build" is a 2026 skill most devs can't claim. It survives a client reading the repo — which is the whole point.
- **The verifiable mainnet addresses are your strongest asset.** Anyone can paste them into BaseScan and confirm real, deployed code. That's proof no mockup can match — keep them front and center.
- **Mobile-only is a headline, not a footnote.** "Shipped live mainnet DeFi contracts from a phone" is a story that makes people stop scrolling. It signals discipline and resourcefulness in a way a normal dev résumé can't. Lean on it.
- **Superfoods stays too** — it proves you also build and ship complete products solo, front to back, not just orchestrate. The two together (solo consumer app + directed protocol build) cover the full range.
- **Repo:** POSSESSIO is public. "Read the source" is citable as a live selling point — clients can verify it directly, no access grant needed.
