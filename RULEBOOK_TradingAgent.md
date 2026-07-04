# RULEBOOK — The Trading Agent's Constitution

**Type:** Governing law (ratify → build in build-mode → device-verify →
hot-mode gated behind the wave's key ceremony)
**Version:** v1.0 — 2026-07-04 — RATIFIED (Architect)
**Scope:** pump.fun (Solana), pre-DEX-listing window only, v1.
**Standing law:** Codebyte Law applies. No clause here is advisory —
every number was ratified line-by-line this session. Amendments require
the same ratification discipline as a contract change (§6).

---

## §0 — Session Gate (checked before ANY trade)

**The question:** is right now a day worth playing at all?

**The signal:** trailing volume (last 1–24h, Solana meme/DEX activity)
compared against its own **trailing 7-day average** — a RELATIVE
threshold, not a fixed dollar figure. Research basis (2026-07-04):
Solana DEX weekly volume has swung between ~$7B and ~$31B+ in recent
months, with single-week moves of 25–39% driven specifically by meme-coin
activity. A fixed number is wrong within a month; a relative one
self-corrects with the market.

**Rule:** if trailing volume < ~60–70% of the 7-day trailing average →
**sit out entirely**, regardless of what any individual pump.fun token
looks like. The exact cutoff (60% vs 70%) is a starting point, NOT
frozen — the ledger (§5) logs the gate's reading on every session, and
the threshold gets tightened or loosened by ratification once real
correlation data exists between gate readings and outcomes.

**Reasoning, on record:** a rational creator launches into attention,
not silence. Healthy ambient volume is a proxy for "creators are
choosing to launch right now, into a crowd that will show up" — it says
nothing about any single coin's quality, and everything about whether
the crowd your edge depends on (§1) exists today.

---

## §1 — The Method (the claim the ledger will kill or confirm)

**Entry:**
- Venue: pump.fun, **pre-DEX only** — token must NOT yet appear on
  DexScreener. This is the entire edge: buying before the distribution
  event that DexScreener's listing represents.
- Age: **4–7 minutes** alive (past instant-rug window, before stale).
- Entry market cap: **~$10,000**.

**Exit — four triggers, first to fire wins, no exceptions, no judgment
calls:**

| # | Trigger | Action | Meaning |
|---|---|---|---|
| 1 | MC reaches **$20,000** | Sell | Take-profit — thesis paid off (~2x) |
| 2 | MC falls to **$6,000** | Sell | Stop-loss — thesis failed (~-40% to -60% depending on entry point in-band) |
| 3 | Token **appears on DexScreener** | Sell at market, any price | Edge-loss stop — the pre-discovery edge is gone the instant discovery happens. This is not a price rule; it is a THESIS rule. Holding past this point is a different trade than the one being run. |
| 4 | **10 minutes elapsed**, none of the above fired | Sell | Time-stop — the method's window has closed |

**Reward:asset shape:** ~2.5:1 (up ~100% / down ~40–60%) — the Architect's
stated thesis is that the asymmetry compensates for a win rate that need
not be high (rough breakeven ≈ 29% at 2.5:1, before fees). This is an
EMPIRICAL CLAIM, not an assumption — §5 exists to test it.

**Architect's own framing, on record:** *"We get in and back out.
Hopefully with a decent return. But I am willing to take that risk
because the reward overcompensates."* — and separately: *"If they are
truly successful, trades should be no problem [at $2]. A real method can
actually get verified without dramatic risk."*

---

## §2 — Identity & Selection Law

**F-1, absolute, no exceptions:** mutating calls (build/execute a trade)
accept **contract addresses only**. A symbol or ticker anywhere in a
buy/sell call is a REFUSAL, not a lookup. Basis: a live query this
session for "aerodrome" returned one canonical token and TWENTY-TWO
impostors with matching names and seeded fake prices. Ticker-matching in
a mutating call is how an agent buys a honeypot.

Symbol→address resolution lives ONLY in the read-only search layer,
returns ALL candidates with spam scores, and a human — or a future
address-allowlist — makes the pick.

**Rug gate (default, adjustable by ratification):** before entry, check:
- Mint authority renounced
- LP locked or burned
- Creator wallet holds **≤15%** of supply (default; tighten/loosen by
  ratification, not by trade-time discretion)

Any check fails → skip the token. No override, no "just this once."

---

## §3 — Caps (RATIFIED, 2026-07-04)

| Cap | Value |
|---|---|
| Max notional per trade | **$2** |
| Max trades per day | **10** |
| Max total daily exposure | **$20** |
| Max slippage | **200 bps**, hard ceiling, server-enforced not client-trusted |

**Why $2, on record:** *"Knock it down to $2 max per trade. If they are
truly successful trades should be no problem. And a real method can
actually get verified without dramatic risk."* Verification is a
function of hit rate and % return, both size-agnostic — the ledger
proves or falsifies the method identically at $2 or $200. The $2 cap
doubles as a fee-efficiency filter: a method that only clears costs at
larger size is a weaker method than one that survives at $2 notional.

Raising any cap requires ratification backed by a verified ledger (§5),
never by projection or a good feeling after a winning week.

---

## §4 — Execution Model (Codebyte-safe by construction)

Two modes, selectable per call, gated by server config — inherited
unchanged from `SPEC_CrossChainTradingMCP.md` v0.2:

| Mode | What it does | Key posture | Default |
|---|---|---|---|
| `build` | Fetch quote, return the UNSIGNED transaction. Architect signs. | No key ever touches the agent | **ALWAYS ON, cannot be disabled** |
| `hot` | Agent signs with a configured key and submits | Key in env, agent-held | **OFF** unless three gates below all fire |

**`hot` mode requires ALL THREE, simultaneously, every call:**
1. `ALLOW_HOT=1` in server config
2. A signer key configured
3. Explicit `confirm:true` on that specific call

Missing any one → refuse, return the `build` payload instead.

**F-4, normative:** the hot-mode key belongs to a **DEDICATED trading
wallet**, funded only to the cap (§3), holding nothing else. The wallet
IS the cap — enforced by physics as well as by code. This is the SAME
wallet the wave's key ceremony creates for the trading agent (per the
"two sides of the same coin" architecture: Claude Code = hands,
this council seat = eyes/judgment).

**Activation sequence — binding, cannot be skipped:**
1. Ratify this rulebook (this document)
2. Build the MCP server in `build`-mode only
3. On-device verification (quote → build → sign → land, per
   `SPEC_CrossChainTradingMCP.md` §8)
4. **The wave's key ceremony** creates the dedicated trading wallet
5. Only after step 4 does `ALLOW_HOT=1` become a discussable sentence

There is no state in which a key exists and the rulebook does not.

---

## §5 — The Ledger (what makes this verifiable instead of anecdotal)

Every trade attempt — filled, skipped, or refused — logs:

- Timestamp, token address, chain
- **pump.fun first-seen timestamp** AND **DexScreener first-seen
  timestamp** (the gap between them is the likely single best predictor
  of the method's edge — log it even on skipped tokens where possible)
- §0 Session Gate reading at time of trade (trailing vol / 7d avg, and
  the pass/fail decision)
- Entry MC, entry price, entry timestamp
- Rug-gate check results (pass/fail per sub-check)
- Exit trigger fired (1–4 from §1's table), exit MC, exit price, exit
  timestamp
- **Gross return AND net return** (post fees/slippage) — net is the
  number that matters; gross flatters
- Running daily count against caps (§3)

**Purpose:** hit rate, average win, average loss, and the asymmetry
claim in §1 all resolve from this table alone. No trade's outcome is
judged by feel. A method that's real shows it here; a method that isn't
dies here cheaply, exactly as designed.

---

## §6 — Amendment Process

Any change to §0–§4 (gates, method numbers, caps) requires the same
ratification discipline as a contract change: stated explicitly by the
Architect, recorded with reasoning, applied going forward — never
silently, never mid-session, never justified by a single trade's
outcome. §5's ledger is the ONLY acceptable evidence for a proposed
change to §1's numbers or §3's caps.

---

## §7 — Non-Proven Scope

- The 60–70% Session Gate threshold is a research-based starting point,
  not empirically tuned yet — §5 exists to tune it.
- The rug-gate's 15% creator-holding default is unconfirmed by the
  Architect; stated as adjustable.
- Regime granularity beyond the single Session Gate (originally
  discussed as named masks — FRENZY / QUIET / RUG-HEAVY) is a possible
  future refinement once the ledger shows the single binary gate is
  insufficient. Not built now; not fabricated now.
- Backend confirm for Farcaster-native rail (Bankr) remains pending;
  v1 ships on Jupiter (Solana) only, per this method's scope.
- Everything here is **NON-PROVEN until it runs on the Architect's
  device against live data**, per Codebyte Law.
