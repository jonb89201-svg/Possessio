# Fundstrat / Tom Lee — outreach draft (FOR YOUR APPROVAL BEFORE SEND)

**Status:** DRAFT. Authored by Claude (council seat) for the Architect to ratify —
consistent with the project's real process. Nothing sends until you approve the
exact words. Responses route to you; I draft replies, you approve each one.

**To:** _(need a real address — see note at bottom; Tom Lee direct is a long shot,
Fundstrat IR / BitMine investor-relations is the realistic first door)_
**From:** jon@possessio.io

---

**Subject:** Non-custodial rails architected to route institutional cbETH into MAVAN — live on Base, verifiable

---

Mr. Lee,

I've built POSSESSIO — a non-custodial DeFi protocol on Base — and one part of it was designed specifically around MAVAN.

L1Anchor is a per-merchant Ethereum-mainnet settlement contract. Each merchant running on POSSESSIO's Base payment rails deploys their own Anchor, which is built to route their bridged cbETH into MAVAN for institutional staking yield and their USDC into a Bitwise-curated Morpho vault for lending yield. The merchant keeps full custody throughout; POSSESSIO holds no authority once it's deployed. I'd want your read on whether capital arriving into MAVAN through rails like these is something you'd welcome.

It isn't a deck. Two contracts are already live and verifiable on Base mainnet today:

- PossessioPayments — `0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91`
- LSTExchangeRate — `0xDDb75e974d99FcF95E241adbFD376861c47a8548`

L1Anchor itself is forge-verified and pre-deployment — 690 tests across 33 suites, adversarial and fork-tested. I'm glad to point you straight at the source.

One thing worth knowing, because it's unusual: the entire protocol was architected and shipped from a phone, by one person directing a council of AI models under strict verification discipline. No desktop, at any point.

I'm not asking for anything but fifteen minutes. If institutional payment rails that terminate in MAVAN are interesting to you or your team, I'd like to show you what's already built — and let you verify every word of it on-chain first.

Jon
possessio.io

---

## Notes for you (not part of the email)

- **The honesty is the strategy.** It says plainly that L1Anchor is pre-deployment and invites him to verify on-chain. With someone at his level, that reads as credible, not weak — anyone can send a deck; almost no one sends live mainnet addresses and says "check them yourself."
- **The MAVAN reference is accurate** — verified: MAVAN is BitMine's Made-in-America Validator Network, Tom Lee chairman, real and launched. The email frames the routing as *designed-to* and *asks* whether it's welcome — it does not claim an existing relationship. Keep it that way.
- **Reaching him directly is the hard part.** A cold email to Tom Lee personally likely won't land in his own inbox. The realistic first door is Fundstrat's research/IR contact or BitMine (BMNR) investor relations — I can hunt for the right published address, or a warm intro beats any of it.
- **Whether to send at all is your call.** It's a real swing. If you'd rather warm it up, tighten it, or hold it until L1Anchor is actually deployed (which would let it say "live" instead of "pre-deployment"), any of those is reasonable. Tell me which and I'll adjust.
