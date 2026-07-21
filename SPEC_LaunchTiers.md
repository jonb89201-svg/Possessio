# SPEC — Launch tiers + the mandatory proxy disclosure

**Type:** Product + launch-page spec · **Date:** 2026-07-20 · **Seat:** Code Integrity
**Status:** DRAFT — records the Architect's tier decision (2026-07-20) and the
customer disclosure the proxy tier requires. Pairs with the per-template
manifest / disclosure pattern in `SPEC_CouncilSigner.md` §5a–5b.

---

## 0a. Disclosure doctrine (governs EVERY launch-page disclosure)

Every disclosure on every launch page — proxy, immutable fields, tier choice, all
of them — is **informative, never advisory.** The purpose is to teach the customer
what their choice *does* and what it *permanently determines about the contract's
future*, so they can choose as a sovereign actor. It states facts and
consequences; it never recommends a choice.

- **Informative, not financial advice.** "Here is what this does and what it
  permanently sets — you decide." Never "you should pick X." Advice would
  contradict the protocol's own posture (non-custodial, no post-deploy access,
  you own it); disclosure completes it.
- **Educational.** A good disclosure leaves the customer understanding the
  sovereignty they're exercising — their choices (tier, immutable addresses,
  wiring, caps) determine the contract's whole future, and the disclosure is
  where they learn that *before* it's permanent.
- **Respects the customer as capable.** Not a warning that protects them from a
  choice — an explanation that equips them to make it. That is the right
  relationship for a product whose entire value is "you own the real thing."

Everything below is one application of this doctrine.

---

## 0. The decision (Architect, 2026-07-20)

Two launch tiers. **The real contract is the default and the premium** — a paying
customer gets *the real thing*, their own complete contract, because that's what
they paid for and it's the most-sovereign expression of the whole protocol
(non-custodial, you own it, we have no post-deploy access). **The proxy is an
optional cheaper tier** — offered, not pushed; some customers will want it.

Not going proxy-by-default. The premium *is* the product; the proxy is a budget
lane.

---

## 1. The two tiers, honestly

| | **Sovereign** (real — default/premium) | **Clone** (proxy — cheaper option) |
|---|---|---|
| what deploys | the customer's own full contract (~24 KB) via the factory + CREATE3 | an EIP-1167 minimal proxy (~45 B) pointing at one shared, immutable logic copy |
| logic | its own, self-contained | shared — delegatecalls a common implementation |
| state / funds | the customer's, in their contract | the customer's, in *their* proxy (storage is theirs) |
| shared-fate | none — independent | shares the one logic contract with every other Clone |
| deploy cost | full (~5M gas of code) | ~10–20× cheaper (a tiny pointer) |
| safety | maximal | safe *if* the logic is immutable (it is — no upgrade path; post-Cancun `selfdestruct` can't remove long-deployed code) |

Both are non-custodial. Both are the customer's to control. The difference is
**ownership of the machine vs. borrowing a shared engine** — and price.

*(Tier names "Sovereign" / "Clone" are placeholders — Architect names them.)*

---

## 2. THE REQUIREMENT: the proxy launch page must disclose this before payment

A customer choosing the cheaper tier is trading away part of the ownership
promise ("I own the real contract") for a lower price. If they don't understand
that at the point of sale, "cheaper" is a bait-and-switch and they'll feel misled
when they later learn their contract borrows shared logic. So — same discipline
as the immutability disclosure (`SPEC_CouncilSigner` §5a): **disclose the
property that isn't obvious and can't be undone, plainly, before the signature.**

The disclosure is shown **on the proxy/Clone launch page, before the customer
pays or signs.** Launch stays disabled until it's been shown and acknowledged.

### 2a. The copy (customer-facing — plain, honest, non-alarming)

> **You're choosing the Clone launch — the lower-cost option. Here's exactly
> what that means, because it's different from the full launch:**
>
> - **Your funds and settings are yours.** They live at your own address that
>   only you control. We never have access — same as the full launch.
> - **The logic is shared.** Instead of deploying your own full copy of the
>   code, your contract runs a single shared copy that every Clone launch uses.
>   That shared copy is **permanent and can never be changed** — not by us, not
>   by anyone. That's *why* it's cheaper: you're not paying to put the whole
>   program on-chain again, just a tiny pointer to code that's already there.
> - **What the full launch gives you instead:** your own complete, independent
>   contract — the real thing end to end, depending on nothing shared. The Clone
>   is functionally identical and safe, but it borrows its engine. If owning the
>   whole machine outright matters to you, choose the full launch.
>
> **Clone = cheaper, shares a permanent engine. Full = your own complete
> contract, yours alone.** This choice is permanent for this launch.

*(Not financial advice — a disclosure of a structural property, like the
immutability notice. Wording is the Architect's to finalize; the load-bearing
facts are: funds/state are yours, the logic is shared + permanent + unchangeable,
and the full tier is a fully independent contract.)*

---

## 3. Where it lives (consistency with the console)

- The proxy launch page is a **per-template manifest** variant (`SPEC_CouncilSigner`
  §5b): the tier choice + this disclosure block are part of that manifest, not a
  universal form.
- **The disclosure block is the constant** — every launch page states plainly
  whatever the customer can't change or might not otherwise understand, before
  the signature. The Sovereign page states its immutable-fields disclosure; the
  Clone page additionally states this shared-logic disclosure.
- Architecturally the Clone tier is a **second factory entrypoint** (deploy a
  minimal proxy to a once-deployed logic copy), additive to the real-contract
  path we're already building — not a redesign. This spec covers the *disclosure*
  obligation; the proxy mechanism itself is a later build.

---

## 4. Definition of Done (for the Clone tier, when built)

- The proxy/Clone launch page renders the §2a disclosure **before** pay/sign;
  launch disabled until acknowledged.
- The full/Sovereign page keeps its own immutable-fields disclosure (§5a).
- The tier choice is explicit and the price delta is shown alongside the
  disclosure, so "cheaper" is always paired with "here's the tradeoff."
- No dark pattern: the cheaper option is never pre-selected or nudged; both tiers
  are presented as legitimate, the customer chooses informed.

---

*Recorded so the promise stays honest: the customer who pays for the real thing
gets the real thing, and the customer who chooses cheaper is told — plainly,
before they pay — exactly what "cheaper" trades away.*
