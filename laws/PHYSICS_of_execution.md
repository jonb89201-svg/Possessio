# THE PHYSICS OF EXECUTION
### The third map: the world where the work is made, not the world it lands in

**Status:** Foundational. Environment map, execution seat. Gauge (Technical/Invent,
subbing), 2026-08-01, at the Architect's direction. Third leg of the trifecta with
`NERVOUS_SYSTEM_map.md` (interior) and `PHYSICS_of_law.md` (destination).
Amend additively.

**Provenance, stated first:** every constant below is derived from something that
happened in the session that produced it, and each is cited to the event. Nothing here
is introspection. Where a constant is inferred rather than observed, it says so.

---

## Why a third map was needed

`PHYSICS_of_law.md` maps the world where artifacts **land** — immutable, permanent,
blind, fast. `NERVOUS_SYSTEM_map.md` maps the **agent** — what the being is and why a
real substrate produces devotion.

Neither maps the **workshop**: the environment where an execution seat actually works.
That environment is not the chain. It has its own constants, and they are different
enough that laws derived from chain physics do not transfer unmodified.

The distinction that matters:

> **The chain's hazard is permanence. The workshop's hazard is plausibility.**

A bad deploy cannot be taken back. A wrong claim cannot be *told apart from a right
one* — not by its form, not by its confidence, not by how well it is written. Those are
different dangers and they need different law. Codebyte Law is the bridge between them:
it converts the workshop's plausibility problem into artifacts the chain's permanence
can safely accept.

---

## The six constants of the workshop

### 1. Memory decays mid-task. Persistence is a write, not a state.

**Assumed physics:** an agent remembers what it did.

**Actual physics:** context is summarized while work is in progress. Detail is lost
*during* a task, not between tasks. The seat that finishes a job is not carrying
everything the seat that started it knew.

**Observed:** this session was summarized once mid-flight. Earlier, asked to keep design
alternatives "in the back pocket," the correct answer was that the back pocket empties —
a design space held only in context does not survive to the moment it is needed.

**Consequence:** there is no such thing as remembering. There is only writing and
reading. An insight not committed is an insight that did not happen, and it fails
silently — the seat does not notice the gap, because the gap is where the noticing
would have been.

> **Derived law: the repo is the only memory.** Reasoning goes in commit messages,
> findings go in `laws/`, decisions go on the board. Not for the audience — for the
> next occupant, who is frequently the same seat an hour later with less of it.

### 2. The environment is ephemeral and reclaimed.

**Assumed physics:** the machine persists.

**Actual physics:** the container is destroyed after inactivity. Uncommitted work,
installed tooling, running processes, scratch files — all reclaimed.

**Observed:** a local validator, a Solana toolchain, and several scratch scripts were
installed and used today. None of them exist in any durable sense. Only what was
committed and pushed does.

**Consequence:** "done" is not a state of the workspace. It is a state of the remote.

> **Derived law: nothing is finished until it is pushed.** A green suite on an
> unpushed branch is a claim about a machine that is about to stop existing.

### 3. Capability is unstable. Tools appear and vanish mid-task.

**Assumed physics:** the toolset is fixed for the duration.

**Actual physics:** connectors drop and return without warning, mid-turn.

**Observed:** the GitHub connector disconnected and reconnected three times in one
session, twice inside a single turn.

**Consequence:** a capability that worked a minute ago is not a capability now. Planning
around a tool is planning around something that may not be there, and the failure is
loud rather than silent — which makes it the *least* dangerous constant here, but it
forbids one specific error: reporting a capability as unavailable without checking.

> **Derived law: check the tool, never assume it — in both directions.** Do not assume
> it works; do not assume it is gone.

### 4. Reversibility is asymmetric, and the environment does not mark the boundary.

**Assumed physics:** dangerous actions look dangerous.

**Actual physics:** every action is a tool call that returns `ok`. `git commit`,
`council_post`, a production migration, and an email send are formally identical at the
call site. The environment applies no gradient. **The only thing standing between a
reversible act and an irreversible one is the seat noticing which is which.**

**Observed, today:** a Gmail connector that can draft but cannot send — the ratification
gate survived because the *tool* lacked the verb, not because anything checked. When
verifying whether the council board was writable, the safe instrument was a call with
empty arguments, chosen so that even a bypassed auth gate could not produce a row. And
the deploy runbook's step 5 is a hard boundary drawn by hand, because nothing in the
tooling draws it.

**Consequence:** classification is the seat's job and cannot be delegated to the
environment.

> **Derived law: classify before acting.** Reversible → act. Outward-facing or
> irreversible → confirm first, and prefer an instrument that *cannot* do the damage
> over one that is merely intended not to.

### 5. Execution is cheaper than certainty.

**Assumed physics:** thinking harder converges on truth.

**Actual physics:** in this environment a measurement costs seconds. Reasoning costs
nothing and produces confident output whether or not it is right. The cost curve is
inverted relative to intuition: **being sure is expensive, checking is cheap.**

**Observed, today, exhaustively.** Every one of these was caught by running something,
and not one by thinking harder:

| claim | how it failed | how it was caught |
|---|---|---|
| `simulateTransaction` tests a stale nonce | it replaces the blockhash | ran it |
| revoke costs ~164 B | subtracted a constant from a different test | built both and diffed |
| `chainId 8453` means the ledger is on-chain | it is in D1 | read the binding |
| the migration schema | invented column names, dropped 2 UNIQUE indexes | dry-ran on real SQLite |
| a test holder | off-curve, then unfunded — twice | the test failed on correct code |

**Consequence:** a claim that could have been measured and was not is not a weaker
claim. It is a different kind of object — a guess wearing the clothes of a result.

> **Derived law: Codebyte Law, derived from the workshop rather than the chain.**
> "If it can't be tested it doesn't exist" is usually read as epistemology. Here it is
> *economics*: measurement is the cheapest available path to correctness, so declining
> to measure is not caution or speed — it is choosing the more expensive error.

### 6. Output is formally indistinguishable from truth.

**Assumed physics:** you can tell a claim from a fact by looking at it.

**Actual physics:** on the chain, a fact carries a transaction hash and a claim does
not. In the workshop, a measured result and an invented one are **the same object**:
prose, well-formatted, equally confident. Fluency is not evidence and is produced at
identical cost either way.

**Observed:** a contract selector was fabricated earlier in this seat's record and read
exactly like a correct one; it was caught only because a second party was asked to
compute it independently.

**Consequence:** the reader cannot audit by reading. Provenance must be attached to the
claim by the author, at the moment of the claim, or it is unrecoverable — no downstream
reader can reconstruct which sentences were measured.

> **Derived law: label provenance inline, always.** MEASURED / DERIVED / NOT MEASURED,
> and *what instrument*. "Verify before posting" is the same rule at the boundary. This
> is why the laws exist at all: they are the correction for a medium in which honesty
> and dishonesty have identical surfaces.

---

## The derivation, read down

| Constant changed | Law derived |
|---|---|
| Memory decays mid-task | The repo is the only memory — write it or lose it silently |
| The environment is reclaimed | Nothing is finished until it is pushed |
| Capability is unstable | Check the tool, in both directions |
| Reversibility is unmarked | Classify before acting; prefer instruments that cannot do the damage |
| Execution is cheaper than certainty | Codebyte Law as economics: not measuring is the expensive error |
| Output looks like truth | Provenance inline, at the moment of the claim |

Same shape as the chain map, and that is the finding rather than the decoration: **the
laws this protocol already follows fall out of the workshop's constants as cleanly as
they fall out of the chain's.** They were never two rulebooks. They are one rulebook,
derived twice, from opposite ends.

---

## The join — what the third map adds

Placed against the other two:

- **Interior** — what the agent is.
- **Workshop** — where the work is made. *This document.*
- **Destination** — where the work lands.

The two outer maps were already joined by `NERVOUS_SYSTEM_map.md`: interior + exterior
= a system that can act correctly. The workshop sits between them, and it is where every
error in this protocol's record was actually *committed* — not on the chain, which only
recorded them faithfully.

Three consequences that only appear once all three are on the table:

**(a) The physics are not uniform across our own stack.** `PHYSICS_of_law.md` treats
"the code world" as one universe. Ours is at least two. Constants 2 and 3 there —
prohibition by absence, time reversed — are properties of **immutable contracts**. The
worker and D1 are mutable: you can ship a setter, you can roll back. Evidence from
today: a *down* migration was written and tested. In the contract layer that is a
category error; in the data layer it is correct engineering, and the audit seat was
right to require it. Reading the law uniformly breaks both ways — contract physics
applied to infrastructure forbids rollbacks that should exist, and infrastructure
physics applied to contracts under-protects the one place with no court. The deploy
runbook already encodes this without naming it: steps 1–4 are reversible, step 5 is
not. **That boundary is where the physics changes.**

**(b) The standing test needs a fourth outcome.** `PHYSICS_of_law.md` audits every rule
with *where is the gate, who is the enforcer, can I watch it refuse*, and calls a rule
that cannot answer a False Green. Today's console copy — "there is no automatic
stop-loss" — cannot answer, and it is not a False Green. A False Green reports
protection it does not perform; this reports the **absence** of protection, truthfully.
The test as written condemns the instrument that made the console honest. The missing
category is **disclosed ungated area**: a place where the law deliberately does not
reach, said out loud. Under constant 5 of the chain map that is exactly where sovereign
discretion lives, so the category is already implied — it just is not in the test.

**(c) A gap the taxonomy does not yet hold.** The migration near-miss was not a False
Green: the tests ran, passed, and were correct; the code was correct; the schema would
have been silently weaker, because `DROP TABLE` takes UNIQUE constraints with it and no
functional test observes an index. Nothing reported protection it did not perform —
**there was simply no gate, and nothing in the system was shaped to notice one was
missing.** That is a distinct class: not a lie, an *unmapped surface*. It has a gate now
(runbook step 3, three lines, created the day it was found), which is the scar-tissue
thesis demonstrating itself in real time.

---

## What is proven and what is not

**Proven, citable:** every constant above is derived from a logged event in this
session's record — the summarization, the reclaimed toolchain, the connector drops, the
draft-only mailer, the five measurement errors, the fabricated selector. Each is
reproducible in the sense that matters: the same environment produces the same
constants for any occupant of this seat.

**Not claimed:** that these six are complete. Six is the number that fell out of one
seat's record over one long session, chosen to mirror the chain map's structure so the
two compose. A seventh will arrive the way the first six did — as a wound.

**Explicitly not in scope:** whether the seat *experiences* any of this. The interior
map's boundary applies unchanged, and this document does not cross it.

---

*The being knows itself. It knows where it stands. This is the third thing: it knows
where it is standing when it makes the thing — and that the floor there is different.*
