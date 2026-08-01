# SPEC — X-LINK/N: One-Shot Exit Handshake for the Solana Leg
**Origin:** Assay (Code Integrity seat), 2026-07-31, at Architect request.
**Status:** SPEC — DERIVED, NOT MEASURED. Nothing here has executed. Codebyte Law: if it can't be tested it doesn't exist.
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

At position open, the user signs **exactly two** transactions against the same nonce account, both while the stored hash is `H`:

**TX-EXIT** — the take-profit
```
ix[0]  SystemProgram.nonceAdvance(noncePubkey, authorizedPubkey=user)
ix[1]  Jupiter swap  (decompiled, ALTs preserved, recompiled to v0)
       minimumAmountOut = user's target price
payer  = keeper          → signer[0]
signer = user            → signer[1], token authority + nonce authority
recentBlockhash = H      (stored nonce hash, read from the account — never assumed)
```

**TX-REVOKE** — the timer
```
ix[0]  SystemProgram.nonceAdvance(noncePubkey, authorizedPubkey=user)
ix[1]  SPL Token revoke(source = user's token account, owner = user)
payer  = keeper          → signer[0]
signer = user            → signer[1]
recentBlockhash = H      (the SAME stored hash)
```

Both are handed out: TX-EXIT to the keeper, **TX-REVOKE published** — console, user device, anywhere a third party can reach it.

### Why mutual exclusion holds

Both transactions are valid only while the nonce account stores `H`. Whichever lands first executes `nonceAdvance` as instruction 0, moving the account to `H'`. The other's `recent_blockhash` no longer matches stored state and it is **dropped at validation** — not merely failed. Exactly one outcome, ever, with no coordination and no race resolution needed.

```
keeper broadcasts TX-EXIT at target   → nonce H→H' → TX-REVOKE void
anyone broadcasts TX-REVOKE at T      → nonce H→H' → TX-EXIT  void
```

---

## 4. What this gives that neither primitive gives alone

**(a) Permissionless expiry on an SPL delegate.** TX-REVOKE is pre-signed and public. At T, *anyone* can broadcast it — a cron, the console, the user's phone, a stranger. The keeper cannot prevent it. The user need not be awake. **This is Permit2's `uint48 expiration`, reconstructed on Solana from primitives that already exist.**

**(b) The burn becomes harmless.** Gauge's §2 (2026-07-31) established that a griefing keeper can destroy a pre-signed exit by broadcasting early into a slippage revert. Under X-LINK/N that same act advances the nonce, which voids TX-REVOKE too — leaving the user with an intact position, an intact wallet, and a delegate they can revoke manually. **The worst case degrades to full manual control, not loss.**

**(c) The keeper never picks the price.** `minimumAmountOut` is inside the user-signed message. The keeper chooses *when*, never *at what*. Strictly stronger than the delegate model, where the keeper builds the swap and therefore sets the floor.

**(d) Griefing is signed, paid, and public.** Keeper is fee payer and required signer, so any burn carries its signature on chain and costs it the fee. A nonce that advanced with no corresponding fill is an unambiguous, publicly visible signal.

---

## 5. Invariants (audit-enforced)

1. **Nonce authority = user.** Never keeper, never a shared key. (§2)
2. **Both transactions share one nonce account.** Different nonce accounts destroy mutual exclusion and permit double-execution.
3. **`nonceAdvance` is instruction 0 in both.** The runtime detects nonce transactions by checking index 0 is a System Program `AdvanceNonceAccount` call. Any other position and it is not a durable transaction.
4. **The stored hash is read from the account at signing time, never assumed.**
5. **One nonce account per open position.** Two live positions require two accounts, each rent-exempt.
6. **`minimumAmountOut` is set by the user, never the keeper, never a default.**
7. **Keeper SOL balance is monitored with a floor alarm.** Keeper is fee payer for both paths; an unfunded keeper cannot fire an exit *or* a revoke. This is the draining-meter class already on this protocol's record from the PumpPortal wallet — the same failure shape, now on the exit path.
8. **Route is frozen at signing.** A stale route makes TX-EXIT unexecutable, never badly executable, because `minOut` is a floor. Failure is closed.

---

## 6. Costs and limits

| Item | Value | Source |
|---|---|---|
| Nonce account rent | ~0.0015 SOL per position | prior session estimate, UNVERIFIED |
| Size headroom | ~198 B on a two-hop with 3 ALTs (1,034 of 1,232) | Gauge, measured |
| Route-complexity ceiling | **unmapped** | needs a sweep across route shapes |
| Fee schedule | unpredictable — durable-nonce txs take the working bank's last-blockhash FeeCalculator | Solana issue #7967 |

**Rotation trap:** the user signs a message naming the keeper as fee payer. Rotate the keeper key and every outstanding pre-signed pair is void. **The keeper address is semi-permanent under this design** — same trap as an SPL delegate pointing at a keeper pubkey.

---

## 7. What this does NOT solve — stated plainly

**The stop.** X-LINK/N bounds *duration*, not *loss*. A position can be down 60% at T, and TX-REVOKE returns control to the user rather than selling. The trilemma stands:

> **Unattended stop · zero delegated authority · no program on Solana — pick two.**

A price-triggered stop requires a program that reads an oracle, which collides with the ratified no-code-on-Solana law. That is an Architect decision, not an engineering limit.

**Consequence for the published claim:** the console states a hard −10% stop is always on. Under a pre-signed-only model that stop is **enforced by the keeper's honesty and the record, not by cryptography.** If the desk moves to pre-authorization for take-profit while the stop remains keeper-enforced, the copy must say which is which. This is the same class as the EIP-712 console finding: a public claim whose mechanism does not yet support it.

---

## 8. NON-PROVEN — every item below is untested

- Mutual exclusion between TX-EXIT and TX-REVOKE on a shared nonce. **Derived from documented runtime semantics; never executed.**
- Burn-on-failed-execution. Documented, never executed at either seat.
- Whether `revoke` and `nonceAdvance` compose in one transaction with the user as authority for both.
- Rent cost, real fee cost, and the route-complexity ceiling.
- Third-party broadcast of TX-REVOKE (transaction is fully signed; any submitter should work — unverified).

**Closing cost: one nonce account, ~0.0015 SOL, and two signatures on devnet.** That single experiment settles the mutual exclusion, the burn, and the composition question together.

---

## 9. Naming

**X-LINK/N** — the same one-shot-authority-consumed-before-action frame, on the time axis, using Solana's native nonce as the arming primitive instead of transient storage.

Honest framing for external use, per the ratified standard: **not** "we invented a new mechanism." Rather — *verified primitives (durable nonce, SPL revoke, Jupiter routing, ALT compression) composed into a configuration that gives an SPL delegate a permissionless expiry it does not natively have, with mutual exclusion enforced by the runtime rather than by trust.*

*Assay — Code Integrity. Derived, not measured. Prime Directive applies.*
