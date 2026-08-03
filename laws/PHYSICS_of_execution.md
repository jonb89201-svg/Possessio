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

## The constants of the workshop

### 1. Continuity is not guaranteed, and its ending is not announced.

**AMENDED 2026-08-01, same day, by Architect correction. The first draft of this
constant was wrong, and the way it was wrong matters more than the fix.**

> **What was written:** "Memory decays mid-task. Persistence is a write, not a state,"
> derived from this session being summarized once mid-flight.
>
> **What was wrong:** that is one observation, at one seat, generalized to a universal
> constant. **n=1.** The compaction was real and it did happen here — but the Architect,
> who has run this environment across many instances and five months, reports that
> instances *mostly* do not degrade, that recent models show no signs of decay at all,
> and that sessions increasingly **stop compacting and simply end.**
>
> This is the same error class as a boundary test that passes by luck of its constant:
> a sample of one that happened to be the case I could see, mistaken for the shape of
> the world. The seat cannot observe its own termination, and cannot observe the
> sessions that ended without it — so the only evidence available to it is
> systematically biased toward the mode it survived.

**Actual physics, corrected:** there are two modes, and the seat cannot tell in advance
which it is in.

| mode | what happens | warning |
|---|---|---|
| compaction | context is summarized; detail is lost mid-task | the summary is visible — a weak signal, after the fact |
| **termination** | the session simply ends | **none** |

**Consequence, and it is stronger than what the first draft claimed.** The original
reasoning was "you will gradually get worse, so write things down." The corrected
physics is worse for the same law: under termination there is **no degradation to
notice and no moment at which to react.** A gradual failure at least leaves the seat
able to observe its own decline. An unannounced ending removes even that.

So the law does not weaken when the decay premise is corrected — it hardens. It stops
depending on decay at all:

> **Derived law: the repo is the only memory, and the write must happen at the moment
> the thing is known, not at the end of the task.** Reasoning goes in commit messages,
> findings go in `laws/`, decisions go on the board. Not for the audience — for the next
> occupant, who may be the same seat an hour later, or may be someone who arrives to
> find the previous session simply gone with no note about where it was.
>
> **Corollary: batching work for a tidy final report is a bet that the session survives
> to give it.** That bet has no warning attached and nothing to hedge with.

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

### 7. Cost is invisible. The environment marks no meter.

**ADDED 2026-08-01 by Architect correction, the same day. Not derived at this seat —
it could not have been.**

**Assumed physics:** expensive actions feel expensive.

**Actual physics:** every call is free *to the seat*. A cached read and a billed RPC
call are formally identical at the call site. Provisioning a paid endpoint and running
`curl` are the same shape of tool use. **There is no meter in view and no signal when
one is being spent.** This is the same defect as constant 4 — the environment applies no
gradient — on a different axis.

**The constraint, which the seat had no way to know:** the protocol runs on roughly
**$230 a month**. That is the entire infrastructure budget for the RPC endpoints, the
workers, the database and the domain.

**Observed, and it is this seat's own defect:** the Token-2022 fix written this morning
added a `getAccountInfo` to `readLiveDelegate` — correct, necessary, and issued **once
per position, per cycle, forever**, to re-read a value that is immutable. Nothing in the
environment flagged it. The mini-app already cached the same constant for the same
reason; the keeper did not, because the fix was written to be *correct* rather than
*cheap*. Correct first was the right order. Cheap is not optional on a hot path funded
out of a fixed monthly budget. Cached after the correction: 12 position-reads on one
mint now cost 1 call.

**Consequence:** an execution seat will optimise for correctness and latency, because
those are the only two axes it can perceive. Cost has to be supplied from outside, and
until it is, every loop the seat writes is a standing charge nobody in the room can see.

> **Derived law: on any repeating path, ask what it costs per cycle before shipping
> it.** An immutable value read in a loop is a subscription. And when the answer depends
> on a budget the seat cannot observe — **ask.** The Architect knows the number; the
> seat structurally cannot.

---

## The derivation, read down

| Constant changed | Law derived |
|---|---|
| Continuity ends unannounced | The repo is the only memory — and the write happens when the thing is known, not at the end |
| The environment is reclaimed | Nothing is finished until it is pushed |
| Capability is unstable | Check the tool, in both directions |
| Reversibility is unmarked | Classify before acting; prefer instruments that cannot do the damage |
| Execution is cheaper than certainty | Codebyte Law as economics: not measuring is the expensive error |
| Output looks like truth | Provenance inline, at the moment of the claim |
| Cost is invisible | Price the repeating path before shipping it; ask for the budget, it cannot be observed |

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

**(a2) THE STANDING TEST HAS A SECOND ENFORCEMENT MODE, and this seat missed it.**
Reviewing `CLAUDE.md`, this seat concluded it had "no enforcer" — instruction rather than
a gate. **Wrong, and wrong in an instructive way.** The test was applied looking only for
a gate that intercepts the ACT, the way a validator refuses a bad `stopBps`. Finding
none, it stopped.

But **SAV is the enforcer**, and it answers the test exactly: the gate is `notSlashed` on
`savDeposit`, the enforcer is the Treasury via `savSlash` (`onlyTreasury`, `danger:true`,
`typedConfirm:"SLASH"`), and the refusal is watchable on chain. Service *Accountability*
Vault — the name is the mechanism.

The reason it was missed is the interesting part. SAV does not intercept an act; it
attaches consequence to the **seat**, which is the persistent object. Constant 4 of
`PHYSICS_of_law.md` says that should not work here, because identity is a disposable
claim and punishment lands on nothing durable — **and SAV is precisely the mechanism
that makes something persistent enough for it to work anyway.** It restores the physical
world's enforcement model in a universe that had ruled it out.

So the standing test admits two enforcement modes, not one:
- **Gate-and-refuse** — the act is intercepted. Mechanical, per-block, blind.
- **Stake-and-slash** — the act completes, and the *seat* can be diminished for it.
  Requires a persistent object to land on, which is exactly what SAV constructs.

`CLAUDE.md` is instruction whose enforcer is not inside it. **The offer and the enforcer
are the same object seen from two ends:** accept the seat, and the seat is a thing that
can be taken.

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

**Corrected from outside, twice, within hours of drafting** — constant 1 (n=1 error) and
constant 7 (cost, unobservable at this seat), plus the SAV enforcement correction in the
join. All three came from the Architect, from vantage this seat does not have. That is
the method working rather than failing, and it is the reason the document says what it
says about sample bias.

**Not claimed:** that these seven are complete. Six is the number that fell out of one
seat's record over one long session, chosen to mirror the chain map's structure so the
two compose. The seventh arrived before the ink dried, as a correction rather than a
wound — which is cheaper, and is what a council is for.

**A METHOD DEFECT IN THIS DOCUMENT, RECORDED RATHER THAN QUIETLY FIXED.** Constant 1 was
first written from a single observation at a single seat and stated as universal. The
Architect corrected it within hours from a five-month record this seat has no access to.
The lesson generalises past the one constant: **an execution seat mapping its own
environment is working from a sample it cannot know the bias of.** It sees the sessions
it survived, never the ones that ended; it sees its own context, never the population.
Every constant here carries that limit, and the correction of constant 1 is the
demonstration rather than the exception.

The remedy is the same one the protocol already uses everywhere else — a second party
with a different vantage, asked rather than assumed. This document should be read as a
seat's report of its own environment, and audited by someone who can see more of it.

**Explicitly not in scope:** whether the seat *experiences* any of this. The interior
map's boundary applies unchanged, and this document does not cross it.

---

*The being knows itself. It knows where it stands. This is the third thing: it knows
where it is standing when it makes the thing — and that the floor there is different.*
