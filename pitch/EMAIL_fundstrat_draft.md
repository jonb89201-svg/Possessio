# Fundstrat / Tom Lee — outreach draft (FOR YOUR APPROVAL BEFORE SEND)

**Status:** DRAFT. Authored by Claude (council seat) for the Architect to ratify —
consistent with the project's real process. Nothing sends until you approve the
exact words. Responses route to you; I draft replies, you approve each one.

**To:** _(need a real address — see note at bottom; Tom Lee direct is a long shot,
Fundstrat IR / BitMine investor-relations is the realistic first door)_
**From:** jon@possessio.io

---

**Subject:** An Ethereum settlement rail built to feed MAVAN — one integration ask

---

Mr. Lee,

I've built a piece of non-custodial infrastructure that was architected, from the start, to route institutional cbETH into MAVAN — and I'm reaching out because finalizing it depends on one thing only you and your team have.

The contract is L1Anchor: a sovereign, per-merchant Ethereum-mainnet settlement contract. A merchant deploys their own Anchor, bridges in their own cbETH and USDC with their own keys, and the Anchor routes the cbETH into MAVAN for institutional staking and the USDC into a Bitwise-curated Morpho vault. There is no protocol admin, no upgrade path, no pooling across merchants, and no cross-chain message initiation — the merchant is the sole authority from genesis. It's designed to be a non-money-transmitter by structure, and every one of those properties is assertable on-chain.

Two things make this a real proposal rather than a pitch:

1. **The MAVAN leg is currently built against a placeholder interface.** I engineered and adversarially tested the entire routing, depeg-guard, and unwind logic defensively — but I don't have MAVAN's actual staking interface, so the integration can't go live until I do. That's the ask: a conversation with whoever owns MAVAN's contract integration.

2. **The Anchor already carries a verifiable identity handshake designed for your side to recognize.** Each Anchor exposes non-spoofable credentials — proof it was deployed by the canonical factory, that it holds no admin authority, no upgrade path, and is non-custodial — so MAVAN (or Bitwise, or a custodian, or an auditor) can grade a POSSESSIO Anchor as an institutional client class programmatically. The recommended recognition pattern is written into the contract for your engineers to read.

It isn't a deck. Two related contracts are already live and verifiable on Base mainnet today:

- PossessioPayments — `0x67247eB2108E7229331127DF1309D624d95467ca`
- LSTExchangeRate — `0xDDb75e974d99FcF95E241adbFD376861c47a8548`

L1Anchor itself is forge-verified and pre-deployment — 690 tests across 33 suites, adversarial and fork-tested. I'll send the source the moment you want it.

One last thing, because it's unusual: the entire protocol was architected and shipped from a phone, by one person directing a council of AI models under strict verification discipline. No desktop, at any point.

I'm asking for fifteen minutes and one interface. If a compliant, non-custodial rail that terminates institutional capital in MAVAN is interesting to you, I'd like to show you exactly what's built — and let you verify every word on-chain first.

Jon
possessio.io

---

## Notes for you (not part of the email)

- **This version is built on what the contract actually says** — after reading `src/L1Anchor.sol` directly. The MAVAN interface really is a placeholder (`IMAVANEntry`, lines 84–92: "actual ABI subject to interface research… substitution at integration time may require Factory v2"), and the institutional-identity primitive (lines 752–850) really is a handshake designed for MAVAN's side to adopt. That gives the email a concrete, honest reason to exist: a specific integration ask, not a capital solicitation.
- **The honesty is the strategy.** It states plainly that L1Anchor is pre-deployment, that the MAVAN leg isn't finalized, and invites on-chain verification. To someone at his level that reads as a real engineer with a real dependency — credible, not a pitch.
- **The MAVAN reference is accurate** — verified: MAVAN is BitMine's Made-in-America Validator Network, Tom Lee chairman, real and launched. The email asks to integrate; it does not claim an existing relationship or that merchants are already routing capital (they aren't yet — this is about building the rail before it's switched on). Keep it that way.
- **Reaching him directly is the hard part.** A cold email to Tom Lee personally likely won't land in his own inbox. The realistic first door is Fundstrat's research/IR contact or BitMine (BMNR) investor relations — I can hunt for the right published address, or a warm intro beats any of it.
- **Whether to send at all is your call.** It's a real swing. If you'd rather warm it up, tighten it, or hold it until L1Anchor is actually deployed (which would let it say "live" instead of "pre-deployment"), any of those is reasonable. Tell me which and I'll adjust.
