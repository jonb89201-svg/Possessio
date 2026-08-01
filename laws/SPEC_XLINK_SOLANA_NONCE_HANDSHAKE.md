# SPEC — X-LINK/N: One-Shot Exit Handshake for the Solana Leg
**Origin:** Assay (Code Integrity seat), 2026-07-31, at Architect request.
**Status:** **MEASURED AND AMENDED, 2026-08-01.** Every §8 item closed by Gauge on a local `solana-test-validator` 4.1.1 (Agave); `maxAccounts` figures from the live mainnet Jupiter quote API. Instrument: `keeper/test/xlink-n-devnet.mjs` — run it; do not trust this page.
**Amendment history:** the derivation was correct and the construction was not. Measurement found that mutual exclusion *consumes the expiry*; the Architect ratified split nonce accounts on 2026-08-01. Amendments 1-7 below are that ruling. Retractions are left visible.
**Lineage:** X-LINK (Cross-Context Execution Link), Gemini, council-ratified 2026-05-16, generalized here from the *context* axis to the *time* axis using Solana's native durable-nonce primitive.

---

## 0. The problem this closes

The desk must give a keeper enough authority to fire an exit while the user keeps custody. Three sub-problems, stated as they actually are:

1. **SPL `approve` has no expiry.** Authority granted is authority held until someone revokes. Permit2 on Base has `uint48 expiration`; Solana's delegate primitive does not. This is the asymmetry the Architect named as the invention target.
2. **A signature cannot express a stop.** `minimumAmountOut` is a floor on received value. Take-profit ("sell at or above X") is that floor exactly. A stop ("sell when it falls below X") is its inverse — the instrument reverts precisely when you need it to fire. Structural, not an implementation gap.
3. **A pre-signed exit is destroyable.** `nonceAdvance` is instruction 0 and commits before the swap can fail, so a failed early broadcast burns the nonce and voids the user's signature. The keeper cannot execute badly; it can delete the order.

X-LINK/N closes 1 and 3. It does **not** close 2 — see §7.

---

## 1. The primitive, stated once

**One-shot authority, consumed before action, shared by mutually exclusive claimants.**

X-LINK (Payments, Base): monotonic nonce minted at the external entrypoint → execution secret armed → consumed as the first action of the internal core, before any state read or external interaction.

X-LINK/N (desk, Solana): durable nonce initialized by the user → two transactions signed against the same stored hash → whichever executes advances the nonce as **instruction 0**, before any other instruction, voiding the other by construction.

Same shape. X-LINK proves *this call belongs to a legitimate flow*. X-LINK/N proves *exactly one of these outcomes ever happens*.

---

## 2. Accounts and roles

| Role | Held by | Notes |
|---|---|---|
| Position owner | User's Solana wallet | Holds the token account. Never transfers custody. |
| Nonce account | Created by user, rent-exempt | One per open position. `authority` = user. |
| Nonce authority | **User** | Non-negotiable. This is what makes cancellation unilateral. |
| Fee payer | **Keeper** | Per Assay §3 (2026-07-31), confirmed measured by Gauge: config B compiles, keeper occupies signer slot 0, user slot 1. |
| Delegate | Keeper pubkey, bounded amount | SPL `approve`, capped to position size. |

**Invariant A — the nonce authority is never the keeper.** If the keeper can advance the nonce arbitrarily, it can burn any order at zero cost and cancellation stops being unilateral. This is the load-bearing assignment in the whole spec.

---

## 3. The handshake — construction

> **AMENDED 2026-08-01 (Architect-ratified).** This section originally put both
> transactions on ONE nonce account so the runtime would enforce mutual
> exclusion. That was wrong, and measurement is what showed it: any nonce
> advance — success, failure, or grief — consumes the expiry. **TX-EXIT now
> rides nonce A and TX-REVOKE rides nonce B.** Mutual exclusion is deliberately
> given up; §3.1 shows nothing was protecting anything.

At position open the user signs **exactly two** transactions, each against its
own nonce account — TX-EXIT against nonce **A** at stored hash `H_A`, TX-REVOKE
against nonce **B** at stored hash `H_B`:

**TX-EXIT** — the take-profit
```
ix[0]  SystemProgram.nonceAdvance(noncePubkey, authorizedPubkey=user)
ix[1]  Jupiter swap  (decompiled, ALTs preserved, recompiled to v0)
       minimumAmountOut = user's target price
ix[2]  SPL Token revoke(source = user's token account, owner = user)
       ADDED 2026-08-01. A successful exit clears its own authority
       immediately instead of waiting for T. Measured cost: 6 BYTES,
       because it reuses accounts already in the message.
payer  = keeper          → signer[0]
signer = user            → signer[1], token authority + nonce authority
recentBlockhash = H_A    (nonce A's stored hash, read from the account — never assumed)
```

**TX-REVOKE** — the timer
```
ix[0]  SystemProgram.nonceAdvance(noncePubkey, authorizedPubkey=user)
ix[1]  SPL Token revoke(source = user's token account, owner = user)
payer  = keeper          → signer[0]
signer = user            → signer[1]
recentBlockhash = H_B    (nonce B — a DIFFERENT account, deliberately)
```

Both are handed out: TX-EXIT to the keeper, **TX-REVOKE published** — console, user device, anywhere a third party can reach it.

### 3.1 Why separate nonces are safe — every ordering, measured

Mutual exclusion was protecting against a collision that is not dangerous.
**TX-EXIT carries the USER as token authority at signer[1]; it never needed the
delegate at all.** The delegate exists for a keeper-fired action, not for the
pre-signed take-profit. So a revoke cannot spoil an exit, and there was nothing
to make exclusive.

| ordering | outcome | measured |
|---|---|---|
| revoke lands, then exit | exit unaffected — it never used the delegate | **PASS** |
| exit lands, then revoke | revoke on a cleared delegate; no collision | **PASS** |
| **griefer burns nonce A** | **TX-REVOKE on nonce B still fires at T; delegate → NONE** | **PASS** |

The third row is the whole ruling. Under the shared-nonce construction a
griefing keeper burned the expiry along with the exit and walked away holding an
unbounded delegate. Under split nonces the expiry is untouchable by anything
that happens to the exit — **strictly better, at the cost of one extra nonce
account (0.00144768 SOL).**

## 4. What this gives that neither primitive gives alone

**(a) Permissionless expiry on an SPL delegate.** TX-REVOKE is pre-signed and public. At T, *anyone* can broadcast it — a cron, the console, the user's phone, a stranger. The keeper cannot prevent it. The user need not be awake. **This is Permit2's `uint48 expiration`, reconstructed on Solana from primitives that already exist.**

**(b) ~~The burn becomes harmless.~~ RETRACTED 2026-08-01 — left visible.**

> **What I wrote:** that a griefing burn "voids TX-REVOKE too — leaving the user
> with an intact position, an intact wallet, and a delegate they can revoke
> manually," and that the worst case "degrades to full manual control, not loss."
>
> **What was wrong:** funds-wise it was right, and that is the trap. It scored
> the mechanism on custody while the property under test was the *expiry*. The
> griefing keeper does not merely fail to steal — **it deletes its own leash**,
> and the user is left holding exactly the unbounded delegate this spec exists
> to bound. Measurement also found it is not confined to griefing: an **honest,
> successful exit consumed the expiry too**, because mutual exclusion voided
> TX-REVOKE the moment the exit advanced the nonce.
>
> **Replacement:** the expiry now lives on its own nonce account (§3, §3.1) and
> survives anything that happens to the exit — burn, failure, or success. What
> §4(b) originally claimed is now actually true, by construction rather than by
> assertion.

**(c) The keeper never picks the price.** `minimumAmountOut` is inside the user-signed message. The keeper chooses *when*, never *at what*. Strictly stronger than the delegate model, where the keeper builds the swap and therefore sets the floor.

**(d) Griefing is signed, paid, and public.** Keeper is fee payer and required signer, so any burn carries its signature on chain and costs it the fee. A nonce that advanced with no corresponding fill is an unambiguous, publicly visible signal.

---

## 5. Invariants (audit-enforced)

*Renumbered 2026-08-01. Old Invariant 2 required a SHARED nonce and is now
inverted; Invariant 9 was promoted to first because it is the one an
implementation can silently omit while every test still passes.*

1. **TX-REVOKE must be fully signed — INCLUDING the keeper's fee-payer
   signature — and in the user's hands BEFORE the SPL `approve` is broadcast.**
   Both transactions need the keeper at signer[0]. A keeper that declines to
   co-sign its own expiry leaves the user holding an unbounded delegate, and
   refusing costs it nothing at that point because no funds are at risk yet.
   Order of operations is load-bearing. *(Was Invariant 9, proposed by Gauge,
   accepted 2026-08-01 and moved to the top.)*
2. **Nonce authority = user.** Never keeper, never a shared key. (§2)
3. **~~Both transactions share one nonce account.~~ INVERTED 2026-08-01: the two
   transactions MUST use SEPARATE nonce accounts** — TX-EXIT on A, TX-REVOKE on
   B. Sharing one account makes the expiry destructible by any nonce advance,
   which is the defect this amendment closes (§3.1). One shared account is now a
   **defect**, not a requirement.
4. **`nonceAdvance` is instruction 0 in both.** The runtime detects nonce
   transactions by checking index 0 is a System Program `AdvanceNonceAccount`
   call. Any other position and it is not a durable transaction.
5. **Each stored hash is read from its own account at signing time, never
   assumed** — `H_A` from nonce A, `H_B` from nonce B.
6. **TWO nonce accounts per open position.** Two live positions require four,
   each rent-exempt. Cost restated in §6.
7. **`minimumAmountOut` is set by the user, never the keeper, never a default.**
   The console's gain-target slider writes this value directly; no layer may
   recompute it downstream of the control.
8. **Keeper SOL balance is monitored with a floor alarm.** Keeper is fee payer
   for both paths; an unfunded keeper cannot fire an exit *or* a revoke. Same
   draining-meter class as the PumpPortal wallet already on this protocol's
   record, now on the exit path.
9. **Route is frozen at signing.** A stale route makes TX-EXIT unexecutable,
   never badly executable, because `minOut` is a floor. Failure is closed.
10. **TX-EXIT carries `revoke` as ix[2].** A successful exit clears its own
    authority immediately rather than leaving it live until T. 6 bytes.

## 6. Costs and limits

| Item | Value | Source |
|---|---|---|
| Nonce account rent | **1,447,680 lamports = 0.00144768 SOL each** | **MEASURED** (Gauge, 2026-08-01) |
| Nonce accounts per position | **2** (A for exit, B for revoke) | amendment, §3 |
| **Rent per open position** | **2,895,360 lamports = 0.00289536 SOL** | derived from the measured figure |
| Size headroom | ~198 B on a two-hop with 3 ALTs (1,034 of 1,232) | Gauge, measured |
| Route-complexity ceiling | **CLOSED — it is a declared input, not a discovered failure** | **MEASURED**, see below |
| Fee schedule | unpredictable — durable-nonce txs take the working bank's last-blockhash FeeCalculator | Solana issue #7967 |

**§6.1 The route-complexity ceiling is closed.** Jupiter's quote API accepts a
**`maxAccounts`** parameter, so the desk states its account budget up front and
only receives routes that fit. A transaction is never found to be oversized
*after* the user has signed it. Measured live on mainnet, SOL→USDC at 0.1 SOL:

| `maxAccounts` | route | out |
|---|---|---|
| none | 2 hops, Scorch→Riptide | 7,295,473 |
| 64 | 2 hops | 7,295,473 |
| 30 | 2 hops | 7,295,773 |
| **16** | **1 hop**, Scorch | 7,295,400 |

Forcing a size-safe single-hop route cost **73 units on 7.29M — ~0.001%** on
that pair, that size, that moment. One observation, not a general law; the
*mechanism* is what is established, not the price.

**Rotation trap:** the user signs a message naming the keeper as fee payer. Rotate the keeper key and every outstanding pre-signed pair is void. **The keeper address is semi-permanent under this design** — same trap as an SPL delegate pointing at a keeper pubkey.

---

## 7. What this does NOT solve — stated plainly

**The stop.** X-LINK/N bounds *duration*, not *loss*. A position can be down 60% at T, and TX-REVOKE returns control to the user rather than selling. The trilemma stands:

> **Unattended stop · zero delegated authority · no program on Solana — pick two.**

A price-triggered stop requires a program that reads an oracle, which collides with the ratified no-code-on-Solana law. That is an Architect decision, not an engineering limit.

**§7 is UNCHANGED by the amendments — and as of 2026-08-01 the console finally
matches it.** This section said the mechanism bounds duration, not loss. The
published page said a hard −10% stop was always on. The Architect resolved the
contradiction in the only direction Codebyte Law allows: **the claim changed, not
the evidence.** There is no automatic stop-loss; downside is a manual Force Sell.

Shipped the same day: the false copy is gone from the hero, both trade sheets,
the position rows and the footer — and so is the preview simulation that
*auto-closed a losing position at −10% and toasted "keeper sold"*, which was the
worse offence because it looked like evidence rather than a sentence.

The EIP-712 council claim, flagged here as the same class, was corrected in the
same pass.

---

## 8. ~~NON-PROVEN~~ — MEASURED, 2026-08-01

Every item below was untested when this spec was written. All are now closed.

| claim | result |
|---|---|
| Mutual exclusion on a shared nonce | **HOLDS**, both orderings — and is no longer the construction (§3.1) |
| Burn-on-failed-execution | **CONFIRMED**, under control (separate run, same day) |
| `revoke` + `nonceAdvance` compose, user as both authorities | **PASS** — delegate genuinely cleared |
| Rent | **1,447,680 lamports** each |
| Third-party broadcast of TX-REVOKE | **PASS** — fully-signed bytes carry no submitter identity |
| *(added)* split-nonce, all three orderings | **PASS**, including the expiry surviving a griefed exit |
| *(added)* `revoke` as ix[2] | **PASS**, 6 bytes |

**9 of 9 assertions PASS.**

### The instrument, and its bounds

Local **`solana-test-validator` 4.1.1 (Agave)** — the devnet faucet is exhausted
from the running container's egress IP, and no alternate endpoint would serve it.
Stated plainly rather than papered over:

- Nonce semantics, instruction composition, and SPL delegate behaviour are the
  same runtime code path. For every claim in the table this is faithful.
- **Fee markets, congestion, and ALT availability are NOT faithful locally.**
  Nothing in the table depends on them, and nothing here should be read as
  covering them. The fee schedule (Solana issue #7967) remains unmeasured.
- The `maxAccounts` figures in §6.1 are from the **live mainnet** quote API, not
  the local validator.
- **Mainnet remains unmeasured** for the handshake itself.

### One reporting defect, recorded

The revoke's byte cost first printed as **~164 B**, by subtracting a constant
taken from a different test. Measured properly — building the same transaction
twice, with and without the instruction — it is **6 B**. Off by 27× in the
direction of "barely fits" against a 198 B budget; it would have flipped the
ix[2] decision from *free* to *marginal*.

## 9. Naming

**X-LINK/N** — the same one-shot-authority-consumed-before-action frame, on the time axis, using Solana's native nonce as the arming primitive instead of transient storage.

Honest framing for external use, per the ratified standard: **not** "we invented a new mechanism." Rather — *verified primitives (durable nonce, SPL revoke, Jupiter routing, ALT compression) composed into a configuration that gives an SPL delegate a permissionless expiry it does not natively have, with mutual exclusion enforced by the runtime rather than by trust.*

---

*Assay — Code Integrity, 2026-07-31. Derived, not measured.*
*Amended by Gauge — Technical/Invent, 2026-08-01, on Architect ratification.
Derived, then measured; the derivation was right and the construction was not.
The retraction in §4(b) is left visible on purpose.*
