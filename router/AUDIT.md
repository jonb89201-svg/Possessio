# Cold-Seat Audit Guide — possessio_router V1

Written for an auditor with **zero prior context**. Read order: this file → SPEC.md →
`program/src/rules.rs` (the decision core + its tests) → `program/src/lib.rs` (handlers).
The design intent: everything worth distrusting is a pure function in `rules.rs`; the
handlers only gather inputs and enforce what those functions decide.

## The five inherited invariants → where they live

These originate as the Model B keeper's five rules (`keeper/index.js` header). V1
compiles them from process discipline into chain law:

| # | Invariant | Enforced at | Proven by |
|---|---|---|---|
| 1 | Revoke is instant; authority read live, never cached | `rules::check_exit` (`src_delegate == Some(router)`, `delegated_amount ≥ amount`, from the ATA **as read in this tx**) | unit: `wrong_delegate_refuses_rule_1`, `delegated_amount_is_a_ceiling_rule_3` |
| 2 | Never act without an instruction | structural: `execute_exit` is the only fund-moving ix and cannot run without a registry rule | source inspection: no other ix touches tokens |
| 3 | Never exceed the grant | pre: `amount ≤ cap ≤ delegated_amount`; post: `check_deltas` reverts overdraw even by a hostile venue | unit: `cap_is_a_ceiling`, `deltas_refuse_overdraw_even_when_venue_lies` |
| 4 | Proceeds to the user | `dest_ata.owner == owner` account constraint + `received ≥ min_out` delta | unit: `deltas_refuse_short_proceeds`; constraint at `ExecuteExit::dest_ata` |
| 5 | The trigger is never in here | the program stores no prices and cannot fire itself | source inspection: no price, no oracle, no self-schedule |

## Threat model — attacks considered

| Attacker | Attack | Defense |
|---|---|---|
| Cranker (holds no authority) | fire a rule at a bad moment | in-scope grief, bounded by `min_out` > 0 and one-shot rules; cannot redirect or exceed |
| Cranker | pass a hostile account list to the CPI | only the router PDA is ever marked signer (metas stripped); deltas revert theft |
| Hostile/compromised venue | pull more than `amount` via the delegate | `check_deltas` → `SrcOverdraw` → whole tx reverts, venue effects included |
| Hostile venue | return dust | `min_out > 0` enforced + `MinOutNotMet` revert |
| Hostile venue | re-enter `execute_exit` | rule deactivated AND registry serialized to the buffer **before** the CPI; venue ≠ self enforced twice (set_rule + execute) |
| Anyone | execute against someone else's registry/ATAs | registry PDA seeds + `has_one=owner`; both ATAs constrained `owner == owner` |
| Owner (self-harm) | set a rule with venue = this program / zero cap / same-mint pair | `check_rule_params` refuses |
| Rent/DoS | overflow the registry | `MAX_RULES=16`, fixed space, owner pays rent, owner can close |

## Known V1 boundaries (deliberate, documented)

- **Timing is off-chain.** No oracle exists for these assets. `min_out` is the only
  price protection; it is cranker-supplied per execution. A future refinement (Gemini
  review question) is owner-authored floor semantics in the rule itself.
- **Venue interface is generic.** V1 does not bind to Jupiter's ABI; it CPIs an
  owner-ratified program with cranker-built data and judges results by balance deltas.
  This is the audit's central argument to attack: *is delta-judgment sufficient?*
- **Token-2022:** ATAs are `InterfaceAccount` (both token programs accepted). Transfer-
  fee mints reduce `received` — min_out must be set net of fees. Not yet exercised
  against a real Token-2022 mint (see Bounds).
- **`owner` in `execute_exit` is not a signer** (by design — 3am exits). Its integrity
  chain: registry PDA is seeds-derived from owner; `has_one = owner`; both ATAs must be
  owned by that key; the router PDA seeds include it. An auditor should specifically
  try to break this chain.

## Bounds — what was actually verified, and where it stops

Per Core Principle 7 (Ratification by Bounds), a pass is only as good as its stated bound.

**Executed in this environment (terminal-proven):**
- `cargo check` — clean compile, anchor-lang/anchor-spl 0.31.1, rustc 1.94.1.
- `cargo test` — **14/14 green**, covering every refusal branch of `check_exit`,
  `check_deltas`, `check_rule_params` plus happy paths. These are native unit tests of
  the pure decision core — they execute the real functions, not descriptions of them.

**NOT verified here (the outstanding audit ladder, in order):**
1. `cargo build-sbf` — no Solana toolchain in this sandbox; the SBF artifact has never
   been produced.
2. Integration against a bank (`solana-program-test`/`litesvm`): account constraints,
   PDA derivations, the serialize-before-CPI ordering, and the reload/delta path have
   **not** been executed — only compiled.
3. Token-2022 live behavior (transfer hooks, transfer fees) — unexercised.
4. A real venue CPI (Jupiter) — unexercised; the generic-venue design is untested
   against Jupiter's actual account demands.
5. Devnet deploy + end-to-end (approve → rule → exit) — not done; requires ratification.

Any claim beyond the executed bounds is unproven and should be treated as such.

## V1.1 remediation (audit: Caliper 2026-08-16 · innovation pass: Gemini · implemented: Fathom)

| Finding | Disposition | Where |
|---|---|---|
| F1 — dest mint not re-verified at delta site (medium) | **FIXED**: `check_deltas` takes the post-reload dest mint and re-asserts vs the rule (`DeltaMintMismatch`) | `rules.rs::check_deltas`; test `f1_delta_site_reasserts_dest_mint` |
| F2 — min_out entirely cranker-supplied; whole-position exit at min_out=1 passed (medium, load-bearing pre-deploy) | **FIXED**: `Rule.min_out_floor` (owner-authored at `set_rule`, entry-basis, must be > 0) + `min_out ≥ floor` in `check_exit` (`MinOutBelowFloor`); Gemini's `min_exit_ratio_bps` converged on the same hole independently | `rules.rs`; tests `f2_regression_cranker_cannot_undercut_the_owner_floor`, `rule_params_validation` |
| F3 — writable-meta question on `remaining_accounts` (low/info) | **OPEN — integration-gated**: only bank tests close it. Named as the gate below. | AUDIT §Bounds ladder step 2 |
| F4 — unfired rules block `close_registry` (cosmetic) | **DOCUMENTED** in SPEC (revoke-then-close is the intended path; refusal is the safe branch) | SPEC.md §Instructions |

**Refused, with reasons (recorded per council discipline):** Ed25519 backend-keypair gate
on `execute_exit` — recreates keeper-key custody risk and kills permissionless cranking;
the untrusted-cranker property is the product. (Ed25519 introspection for gasless
owner-signed `set_rule`/`revoke` is good and **deferred**, not refused.)

**Deferred lane:** `sequence_nonce` (multi-shot kinds only; one-shot V1 replay dies with
the serialize-before-CPI gate), sliding-window caps (unix-window clock, not
`clock.epoch`), pro-rata floors for multi-shot rules.

**THE BANK-TEST GATE, named:** "reentrancy cleared" and the F3 writable-meta question
remain *argued from source*, not executed, until ladder step 2 runs
(`solana-program-test`/litesvm — measured feasible in these containers by Caliper,
2026-08-16). Division per house rule: Fathom writes the bank tests, Caliper attacks them.

## For Gemini's innovation pass — the open questions

1. Attack delta-judgment: any sequence where a venue satisfies both deltas yet harms
   the owner? (e.g., writable meta abuse on accounts outside the two judged ATAs —
   should V1 constrain WHICH accounts may be writable in `remaining_accounts`?)
2. The `owner`-not-signer integrity chain above — break it if you can.
3. Multi-shot rules (cap-metered, not one-shot) for payroll: what changes in the
   settlement law?
4. Venue policy: per-rule ratification (V1) vs. global allowlist PDA vs. both.
5. Should the registry emit a Farcaster-verifiable event shape (FID binding) now, or
   is that a pure client concern?
