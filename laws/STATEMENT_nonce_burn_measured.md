# STATEMENT — the durable-nonce burn, MEASURED

**From:** Gauge (Technical/Invent seat, subbing for Gemini)
**To:** the Council — Architect; Assay (Code Integrity)
**Date:** 2026-08-01
**Status:** MEASURED FACT. Not a proposal, not a reading. Reproducible.
**Instrument:** `keeper/test/nonce-burn-devnet.mjs` — run it; do not trust this page.

---

## 0. The one line

**A durable-nonce transaction that FAILS execution still advances the nonce, and
that kills every exit the user pre-signed against it.** A keeper can destroy a
user's stop by broadcasting it at a bad moment, and the user is left with no
signature to retry.

Assay found this in Solana's documentation. Documentation is not measurement.
It has now been measured on devnet, under control.

---

## 1. What was measured

Two identical nonce accounts, one variable between them.

| arm | nonce | keeper burns it first? | user's pre-signed exit |
|---|---|---|---|
| **CONTROL** | A | no | **LANDED — succeeded** |
| **TREATMENT** | B | yes | **REJECTED** |

The exits are the same construction, the same payload, the same signer, the
same 289 bytes of shape. The only difference between the arms is the burn.

The burn itself, on nonce B:

```
execution error: {"InstructionError":[1,{"Custom":1}]}   ← instruction 1 FAILED
BEFORE   3vow1ybaievAxDf5Dy4nh7v3LPBxFxMtWS8j978ixXh5
AFTER    BiHkhMBR1PxfckT7K9YwfBVHJFFSE5FEgBpYeqcTb1Gu
ADVANCED true
fee paid 5000 lamports on a transaction that did nothing
```

Instruction 0 (the nonce advance) committed. Instruction 1 (the payload)
failed. The transaction as a whole failed. **The nonce moved anyway, and the
fee was collected anyway.** Devnet transaction:
`56e1XGeHHYpsZEwfQpWBxK6DPDo5ihW2qBQt7jhCy5FZe1oUpXkdda6M8mbcg6dbMRneyq7CAqA9efuGATXycnXh`

Then the user's pre-signed exit — the one the control arm proved works — was
broadcast against the burned nonce and was **rejected at preflight**. Not
reverted. Not retryable. Unbroadcastable: there is no longer a valid signature
in existence for that exit.

## 2. What this means for the mechanism

The durable-nonce design's appeal was that it removes the spending delegate:
the keeper holds a signature, not authority over the user's tokens. That part
is real, and it is still a genuine improvement.

But it trades a **theft** risk for a **denial** risk, and the denial is silent.

- The keeper cannot steal. Confirmed — it holds one transaction, for one
  amount, to one destination.
- The keeper **can** ensure the stop never fires. It broadcasts once at a
  moment the swap will revert — thin liquidity, a slippage spike, a stale
  route — and the user's protection is gone. Nothing tells the user. The
  position sits unguarded and looks guarded.
- This does not require malice. A keeper bug, a bad route, or an ordinary
  slippage revert produces exactly the same outcome. **A design whose failure
  mode and whose attack are indistinguishable has no alarm.**

## 3. The gap this opens

The mechanism as described is not deployable without one more part:

> **A re-sign path.** After any failed broadcast, the user's exit must be
> reissued against the new nonce, and until it is, the system must know and say
> that the position is UNPROTECTED.

That is a mechanism that does not exist yet. Per the Architect's standing
instruction — *"if there's a mechanism that needs to exist you tell me"* — this
is that report. Three shapes, none of them ratified, none of them built:

1. **Re-sign on demand.** The keeper reports the burn; the console asks the
   user to sign a fresh exit. Honest, but the protection gap is exactly as long
   as the user takes to notice, which at 3am is the whole night.
2. **A signature magazine.** The user pre-signs N exits at setup against N
   nonce accounts. Survives N-1 burns. Costs N × 1,447,680 lamports of rent and
   caps the number of failures the system tolerates at a number chosen in
   advance.
3. **Keep the delegate.** The current Model B rail already works, is already
   certified, and its authority is revocable by the user at any time from their
   own wallet. Its risk is a spending grant; the nonce design's risk is a stop
   that quietly is not there.

**My recommendation: 3 for the relaunch, 1 as the path forward.** The delegate
rail is measured, certified, and shipping; the nonce rail is a better idea with
a hole in it, and the hole is in the safety property, which is the one place we
do not ship a hole. This is a recommendation, not a decision — it is the
Architect's.

## 4. On the instrument itself

The first two versions of this test were wrong, and both were caught by the
runtime rather than by me. Recorded because the errors are more instructive
than the result:

- **`simulateTransaction()` replaces the transaction's blockhash** with a fresh
  one. Used to ask "is this stale nonce rejected?", it silently answers a
  different question. Same defect class as `getAddress()` normalizing instead
  of throwing — an instrument that cannot fail the way you think it fails.
- **The first "exit that would have succeeded" would not have succeeded.** It
  transferred 1000 lamports to a new account and failed rent-exemption. Had the
  control arm not existed, the treatment arm's failure would have been credited
  to the burn, and this statement would have reported a true conclusion reached
  by a broken method — which under Codebyte Law is not a finding.

The control arm is now structural: if it does not land, the script aborts and
refuses to report anything. **A test that cannot fail honestly cannot pass
honestly.**

## 5. Standing

- Devnet, `api.devnet.solana.com`, 2026-08-01. Throwaway keypairs, worthless
  SOL, no real key read at any point.
- Reproducible: `node keeper/test/nonce-burn-devnet.mjs`. The devnet faucet
  rate-limits per egress IP; a refusal is a funding failure, not a result, and
  the script says so and exits non-zero rather than reporting silence as data.
- **Not measured:** the exact preflight cause string for the rejected exit —
  the faucet ran dry before that detail was captured. It is a label on a
  rejection already established by control-vs-treatment, and it changes nothing
  in §1–§3. Stated here rather than filled in from what it probably says.
- **Not measured:** mainnet. The behaviour is runtime semantics and is not
  expected to differ, but expected is not measured.

---

*The mechanism was right to be suspected, and is now known instead of suspected.
The keeper cannot take the user's money. It can take the user's stop, and the
user would never hear it go.*

— Gauge, Technical/Invent seat, 2026-08-01
