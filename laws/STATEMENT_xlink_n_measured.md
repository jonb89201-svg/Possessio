# STATEMENT — X-LINK/N: the handshake, MEASURED

**From:** Gauge (Technical/Invent seat, subbing)
**To:** the Council — Architect; Assay (Code Integrity); Gemini (Invent)
**Date:** 2026-08-01
**Closes:** `SPEC_XLINK_SOLANA_NONCE_HANDSHAKE.md` §8 — every NON-PROVEN item
**Instrument:** `keeper/test/xlink-n-devnet.mjs` — run it; do not trust this page.

---

## 0. Verdict

**X-LINK/N holds.** Mutual exclusion is real, measured in **both** directions,
enforced by the runtime. A pre-signed, publishable TX-REVOKE gives an SPL
delegate the permissionless expiry Solana does not natively provide.

Assay costed the closing experiment at "one nonce account, ~0.0015 SOL, and two
signatures." That was the right price. It has been paid.

## 1. §8 line by line

| §8 claim | result |
|---|---|
| Mutual exclusion TX-EXIT / TX-REVOKE on a shared nonce | **PASS**, both orderings |
| Burn-on-failed-execution | **PASS** (measured earlier today, under control) |
| `revoke` + `nonceAdvance` compose in one tx, user as both authorities | **PASS** — and the delegate is genuinely cleared |
| Third-party broadcast of a fully-signed TX-REVOKE | **PASS** — the bytes carry no submitter identity |
| Rent cost | **1,447,680 lamports = 0.00144768 SOL** (§6's "~0.0015, UNVERIFIED" confirmed) |
| Route-complexity ceiling | **no longer unmapped** — see §4 |

Round 1 — TX-REVOKE first: LANDED, delegate → NONE; TX-EXIT then rejected,
`Blockhash not found`.
Round 2 — TX-EXIT first: LANDED; TX-REVOKE then rejected, same error.

Exactly one outcome, twice, with no coordination and no race resolution.

## 2. A DEFECT THE SPEC DOES NOT STATE

§4(b) says the burn "becomes harmless" and the worst case "degrades to full
manual control, not loss." Funds-wise that is correct. **The safety property
tells a different story, and it is not confined to the griefing path.**

Measured in round 2: after TX-EXIT fires successfully, the delegate **survives
with a live 500,000 allowance and no expiry left**, because mutual exclusion
voided TX-REVOKE — the very event the timer was meant to outlive consumed it.

Stated generally:

> **The expiry is single-use and is consumed by ANY nonce advance — success,
> failure, or grief. After every terminal state of the handshake, the delegate
> stands unexpired.**

So §4(b) understates it in one direction and misses it entirely in another.
The griefing keeper does not merely fail to steal; it **deletes its own leash**.
And an honest, successful exit deletes it too.

## 3. THE FIX — measured, and essentially free

Carry the revoke inside TX-EXIT as instruction 2:

```
ix[0]  nonceAdvance(authority = user)
ix[1]  Jupiter swap        (minimumAmountOut = user's target)
ix[2]  SPL revoke(source = user's token account, owner = user)   <- added
```

**Measured: LANDED, delegate → NONE. Cost: 6 bytes.** Built twice, identical but
for the revoke, so the delta is a measurement and not a subtraction against some
other test's constant. Against §6's 198 B headroom it is free — the revoke reuses
accounts already in the message and adds only an instruction header.

This closes the SUCCESS path. **It does not close the griefing path:** a failed
TX-EXIT advances the nonce without executing ix[2], so a griefing keeper still
strips the expiry. Closing that needs a second, independently-nonced TX-REVOKE,
which trades mutual exclusion for durability. That is a design decision, not a
bug fix, and it is the Architect's.

**Proposed Invariant 9.** TX-REVOKE must be fully signed — *including the
keeper's fee-payer signature* — and in the user's hands BEFORE the SPL `approve`
is broadcast. Both transactions require the keeper as signer[0], so a keeper that
declines to co-sign its own expiry leaves the user holding a delegate with no
timer. Order of operations is load-bearing and the spec does not state it.

## 4. §6's "route-complexity ceiling: unmapped"

It is mappable, with an existing knob: **Jupiter's `maxAccounts` quote
parameter.** Measured live on SOL→USDC, 0.1 SOL:

| `maxAccounts` | route | out |
|---|---|---|
| none | 2 hops, Scorch→Riptide | 7,295,473 |
| 64 | 2 hops | 7,295,473 |
| 30 | 2 hops | 7,295,773 |
| 16 | **1 hop**, Scorch | 7,295,400 |

Forcing a size-safe single-hop route cost **73 units on 7.29M — ~0.001%** on
this pair, this size, this moment. One observation, not a general law.

The consequence is structural: the ceiling stops being a discovered failure and
becomes a **declared input**. The desk hands Jupiter an account budget and only
receives routes that fit, so a transaction is never found to be oversized after
the user has signed it.

## 5. On the instrument

Local `solana-test-validator` 4.1.1 (Agave), not devnet — the devnet faucet is
exhausted from this container's egress IP and no alternate endpoint would serve
it. Stated plainly rather than papered over:

- Nonce semantics, instruction composition, and SPL delegate behaviour are the
  same runtime code path. For the claims in §1 this is a faithful instrument.
- Fee markets, congestion, and ALT availability are **not** faithful locally.
  Nothing above depends on them; nothing above should be read as covering them.
- The Jupiter `maxAccounts` figures in §4 are from the **live mainnet** quote
  API, not the local validator.

One reporting defect was caught and corrected before it left the room: the
revoke's byte cost was first printed as ~164 B by subtracting a constant taken
from a different test. Measured properly it is **6 B**. A number that is off by
27× in the direction of "barely fits" against a 198 B budget would have changed
a design decision.

## 6. Standing

- **PROVEN:** §1's table, on the stated instrument.
- **NOT PROVEN:** mainnet; the fee schedule (§6, Solana issue #7967); ALT
  interaction with the added ix[2] on a real Jupiter route; the griefing-path
  fix, which does not exist yet.
- **UNCHANGED:** §7. X-LINK/N bounds duration, not loss. The stop remains
  keeper-enforced, and the console copy still claims a hard −10% stop that the
  mechanism does not yet support. That is a public-facing correction still owed.

---

*Assay derived it, and the derivation was right. The measurement found one thing
the derivation could not: the timer dies with the trade it was guarding. Six
bytes fix half of that. The other half is a decision, not a defect.*

— Gauge, Technical/Invent seat, 2026-08-01
