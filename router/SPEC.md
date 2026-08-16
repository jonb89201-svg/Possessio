# POSSESSIO Router — V1 Specification

**Status:** V1 build for cold-seat audit → Gemini innovation review → Architect ratification.
**Nothing here is deployed.** Deploys require Architect ratification (Codebyte Law).

## The constraint this dissolves

An SPL token account has exactly **one** `delegate` field. Today that slot is spent on a
bare keypair (the Model B keeper), which forces: (a) authority to be **polled** to honor
revokes — the measured 2,541,604-call/15-day QuickNode burn; (b) total blast radius —
one key compromise is every armed position at once; (c) one function per approve —
payroll, merchant settlement, and an exit rule cannot coexist.

V1 spends the slot on a **per-owner program PDA** (`["router", owner]`). The single
delegate becomes a registry of rules, each with its own cap, venue, expiry, and instant
revocation. Authority is verified **at write time** — inside the transaction that acts —
so there is nothing to poll and no window where stale authority can move a token.

## Architecture

```
[ Owner wallet ] --(one SPL approve)--> delegate = Router PDA ["router", owner]
       |
       | owner-signed instructions
       v
[ Registry PDA ["registry", owner] ]  rules: Vec<Rule> (max 16)
       ^
       | execute_exit(rule_id, amount, min_out, venue_data) — any cranker/fee payer
       v
[ possessio_router program ] --CPI (PDA-signed)--> [ rule.venue_program (swap venue) ]
                              then re-reads balances; deltas must obey the rule or ALL reverts
```

## State

`Registry { owner, bump, router_bump, rules: Vec<Rule> }` — one per owner, PDA
`["registry", owner]`, created/owned/closed by the owner.

`Rule { id, kind, mint, dest_mint, amount_cap, expires_ts (0=never), active, venue_program }`
— V1 `kind` = 0 (EXIT) only. Payroll / merchant settlement are future kinds against this
same registry (the payments-rail seam). V1 exit rules are **one-shot**: a fired exit
deactivates the rule, matching desk semantics (target hit → position closed).

## Instructions

| ix | signer | effect |
|---|---|---|
| `init_registry` | owner | create registry + derive router PDA bumps |
| `set_rule(...)` | owner | validated upsert (`rules::check_rule_params`) |
| `revoke_rule(id)` | owner | `active=false`, effective immediately |
| `execute_exit(id, amount, min_out, venue_data)` | any cranker | see below |
| `close_registry` | owner | rent back; refuses while any rule active |

### execute_exit, precisely

1. Rule lookup (no rule → refuse; keeper Rule 2 is structural — this is the only
   fund-moving instruction and it cannot run without a rule).
2. `rules::check_exit` — pure function over: rule state, clock, amount, min_out, both
   ATA mints, the src ATA's **live** `delegate` and `delegated_amount` (keeper Rules 1+3),
   venue identity/executability, self-CPI ban.
3. **Effects before interactions:** cap decremented, rule deactivated, registry
   **serialized to the account buffer before the CPI** — a re-entering venue sees the
   rule already dead.
4. CPI to `rule.venue_program` with cranker-supplied accounts + data, signed by the
   router PDA. Signature policy: only the router PDA may be marked signer; every other
   meta is stripped to non-signer.
5. **Settlement law** (`rules::check_deltas`): balances re-read; the tx reverts —
   venue effects included — unless `src_spent ≤ amount` and `dest_received ≥ min_out`
   with the destination being the owner's own ATA (keeper Rules 3+4). Intent proves
   nothing; deltas are the only truth. This is what makes an arbitrary, even hostile,
   venue unable to overdraw the user or short the proceeds.

## Trust boundary (state it, don't hide it)

- **Trustless:** custody (user keeps their coins), authority (live delegate checked
  in-tx), amount (cap + delta-revert), destination (owner's ATA only), revocation
  (rule-level and SPL-level, both instant at the next tx).
- **Cranker-trusted, bounded:** *when* to fire, route quality above `min_out`. Memecoins
  have no oracle; timing cannot be chain-verified. A stolen cranker key can grief
  (fire a valid rule at a bad moment, within min_out); it **cannot steal**.
- **Owner-trusted:** venue choice per rule (ratified at `set_rule`).

## What this deletes from the current system

- The keeper's 5-second delegate poll (the entire RPC burn) — authority checks move
  into the execution tx, cost zero standing RPC.
- The keeper keypair as a custody risk — the PDA cannot be exfiltrated.
- The one-delegate-one-function limit — N rules per approve.

The cranker still watches **prices** off-chain (that is the radar/desk's job and the
measured-bands work), but price-watching is DexScreener/Jupiter reads, not per-position
`getAccountInfo` authority polling.

## ARCHITECT DECISIONS — required before any deploy

1. **Upgrade authority.** An upgradeable program whose admin can rewrite the router IS
   the keeper-key risk at a higher level. Immutable / timelock / multisig — choose
   deliberately. V1 code contains no admin, no global authority, no fee switch.
2. **Fee posture.** V1 takes zero fees. If the payments rail charges basis points on
   flow, that is a new, ratified `kind`/field — not a quiet addition.
3. **Migration.** Whether the Model B keeper coexists (runs as the cranker against this
   program) or the desk cuts over whole. Recommended V1 path: keeper becomes the
   cranker, its key demoted from custody-critical to grief-only.
4. **Venue policy.** V1 binds venue per rule (owner-ratified). Whether a global
   allowlist PDA is wanted instead is a design question for Gemini review.

## Verification bounds (Ratification by Bounds)

See AUDIT.md §Bounds. Summary: `cargo check` clean and 14/14 unit tests executed green
in this environment; **not** built for SBF, **not** run against a validator or
program-test bank, **not** deployed anywhere. Those are the audit's outstanding steps,
in that order.
