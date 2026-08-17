//! The pure decision core. No accounts, no CPI, no clock reads — every check a
//! cold auditor must trust is a total function over plain values, unit-tested
//! below without a validator. The instruction handlers in lib.rs may ONLY
//! gather inputs and enforce what these functions decide.

use anchor_lang::prelude::*;

use crate::{Rule, RouterError, RULE_KIND_EXIT};

/// Everything execute_exit must know, gathered by the handler from live
/// account state. `delegate`/`delegated_amount` come from the user's token
/// account AS READ IN THIS TRANSACTION — authority is checked at write time,
/// atomically with the act, never cached (keeper Rule 1, compiled).
pub struct ExitInputs {
    pub now_ts: i64,
    pub amount: u64,
    pub min_out: u64,
    pub src_mint: Pubkey,
    pub dest_mint: Pubkey,
    pub src_delegate: Option<Pubkey>,
    pub src_delegated_amount: u64,
    pub router_authority: Pubkey,
    pub venue_program: Pubkey,
    pub venue_is_executable: bool,
    pub self_program: Pubkey,
}

/// May this exit proceed? Err = the whole transaction aborts; nothing moved.
pub fn check_exit(rule: &Rule, i: &ExitInputs) -> Result<()> {
    require!(rule.active, RouterError::RuleInactive);
    require!(rule.kind == RULE_KIND_EXIT, RouterError::RuleKindUnknown);
    require!(
        rule.expires_ts == 0 || i.now_ts < rule.expires_ts,
        RouterError::RuleExpired
    );
    require!(i.amount > 0, RouterError::AmountZero);
    // A zero floor would let a hostile venue return dust "successfully".
    require!(i.min_out > 0, RouterError::MinOutZero);
    // V1.1 (audit F2, Caliper 2026-08-16; Gemini concurring independently):
    // min_out alone was entirely cranker-supplied — a whole-position exit
    // with min_out=1 passed both check_exit and check_deltas, demonstrated
    // with a passing test. The floor is now OWNER-AUTHORED in the rule at
    // set_rule (entry-basis, computed by the owner's client) and the
    // cranker's min_out may tighten it but never undercut it.
    require!(i.min_out >= rule.min_out_floor, RouterError::MinOutBelowFloor);
    require!(i.amount <= rule.amount_cap, RouterError::CapExceeded);
    require_keys_eq!(i.src_mint, rule.mint, RouterError::MintMismatch);
    require_keys_eq!(i.dest_mint, rule.dest_mint, RouterError::MintMismatch);
    // Keeper Rule 1: the chain decides, in this transaction, whether authority
    // is live. A revoke (SPL or rule-level) is effective at the very next tx.
    require!(
        i.src_delegate == Some(i.router_authority),
        RouterError::DelegateMismatch
    );
    // Keeper Rule 3: never exceed the delegated amount.
    require!(
        i.src_delegated_amount >= i.amount,
        RouterError::DelegatedInsufficient
    );
    // The venue is ratified per-rule by the owner, must be a program, and must
    // not be this program (closes the self-reentrancy door before any CPI).
    require_keys_eq!(i.venue_program, rule.venue_program, RouterError::VenueMismatch);
    require!(i.venue_is_executable, RouterError::VenueNotExecutable);
    require!(
        i.venue_program != i.self_program,
        RouterError::SelfCpiForbidden
    );
    Ok(())
}

/// The post-CPI settlement law. The venue ran with our PDA's signature over a
/// delegate that may permit MORE than `amount` — so intent alone proves
/// nothing. Balances are re-read after the CPI and these deltas are the only
/// authority on what actually happened. Any violation reverts the whole
/// transaction, venue effects included. This is what makes an arbitrary,
/// even hostile, venue unable to overdraw the user or short the proceeds.
pub fn check_deltas(
    src_before: u64,
    src_after: u64,
    dest_before: u64,
    dest_after: u64,
    amount: u64,
    min_out: u64,
    rule_dest_mint: Pubkey,
    dest_mint_at_delta: Pubkey,
) -> Result<()> {
    // V1.1 (audit F1): re-assert the destination mint AT THE DELTA SITE, on
    // the post-CPI reloaded account — the judged balance must be a balance of
    // the rule's dest mint, not merely of an account that once matched.
    // Token-account mints are immutable today; this is defense in depth
    // priced at one comparison.
    require_keys_eq!(dest_mint_at_delta, rule_dest_mint, RouterError::DeltaMintMismatch);
    let spent = src_before
        .checked_sub(src_after)
        .ok_or(RouterError::SrcOverdraw)?; // balance UP is as wrong as overdrawn
    require!(spent <= amount, RouterError::SrcOverdraw);
    let received = dest_after
        .checked_sub(dest_before)
        .ok_or(RouterError::MinOutNotMet)?;
    // Keeper Rule 4: proceeds land with the USER — dest is the owner's own
    // ATA by account constraint, and it must have grown by at least the floor.
    require!(received >= min_out, RouterError::MinOutNotMet);
    Ok(())
}

/// Rule upsert validation — what the owner is allowed to write.
pub fn check_rule_params(rule: &Rule, self_program: Pubkey) -> Result<()> {
    require!(rule.kind == RULE_KIND_EXIT, RouterError::RuleKindUnknown);
    require!(rule.amount_cap > 0, RouterError::BadRuleParams);
    require!(rule.mint != Pubkey::default(), RouterError::BadRuleParams);
    require!(rule.dest_mint != Pubkey::default(), RouterError::BadRuleParams);
    require!(rule.mint != rule.dest_mint, RouterError::BadRuleParams);
    require!(rule.expires_ts >= 0, RouterError::BadRuleParams);
    require!(rule.venue_program != Pubkey::default(), RouterError::BadRuleParams);
    require!(rule.venue_program != self_program, RouterError::SelfCpiForbidden);
    // V1.1 (audit F2): an exit rule with no owner-authored floor is the F2
    // hole by construction — refuse it at write time, not fire time.
    require!(rule.min_out_floor > 0, RouterError::BadRuleParams);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule() -> Rule {
        Rule {
            id: 1,
            kind: RULE_KIND_EXIT,
            mint: Pubkey::new_unique(),
            dest_mint: Pubkey::new_unique(),
            amount_cap: 1_000,
            expires_ts: 0,
            active: true,
            venue_program: Pubkey::new_unique(),
            min_out_floor: 1,
        }
    }

    fn deltas(
        src_b: u64, src_a: u64, dest_b: u64, dest_a: u64, amount: u64, min_out: u64,
    ) -> Result<()> {
        let m = Pubkey::new_unique();
        check_deltas(src_b, src_a, dest_b, dest_a, amount, min_out, m, m)
    }

    fn inputs(r: &Rule, router: Pubkey) -> ExitInputs {
        ExitInputs {
            now_ts: 1_000,
            amount: 500,
            min_out: 1,
            src_mint: r.mint,
            dest_mint: r.dest_mint,
            src_delegate: Some(router),
            src_delegated_amount: 500,
            router_authority: router,
            venue_program: r.venue_program,
            venue_is_executable: true,
            self_program: Pubkey::new_unique(),
        }
    }

    fn err_of(res: Result<()>) -> u32 {
        match res.unwrap_err() {
            Error::AnchorError(e) => e.error_code_number,
            _ => panic!("expected AnchorError"),
        }
    }
    fn code(e: RouterError) -> u32 {
        Error::from(e).into_anchor_error_code()
    }

    // Anchor error helper: extract code number for comparison.
    trait IntoCode {
        fn into_anchor_error_code(self) -> u32;
    }
    impl IntoCode for Error {
        fn into_anchor_error_code(self) -> u32 {
            match self {
                Error::AnchorError(e) => e.error_code_number,
                _ => panic!("expected AnchorError"),
            }
        }
    }

    #[test]
    fn happy_path_passes() {
        let r = rule();
        let router = Pubkey::new_unique();
        assert!(check_exit(&r, &inputs(&r, router)).is_ok());
    }

    #[test]
    fn inactive_rule_refuses() {
        let mut r = rule();
        r.active = false;
        let router = Pubkey::new_unique();
        assert_eq!(err_of(check_exit(&r, &inputs(&r, router))), code(RouterError::RuleInactive));
    }

    #[test]
    fn expired_rule_refuses_and_zero_means_never() {
        let mut r = rule();
        let router = Pubkey::new_unique();
        r.expires_ts = 999; // now_ts is 1_000 → expired
        assert_eq!(err_of(check_exit(&r, &inputs(&r, router))), code(RouterError::RuleExpired));
        r.expires_ts = 0; // never expires
        assert!(check_exit(&r, &inputs(&r, router)).is_ok());
    }

    #[test]
    fn wrong_delegate_refuses_rule_1() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.src_delegate = Some(Pubkey::new_unique()); // someone else's grant
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::DelegateMismatch));
        i.src_delegate = None; // revoked
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::DelegateMismatch));
    }

    #[test]
    fn delegated_amount_is_a_ceiling_rule_3() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.src_delegated_amount = 499; // one unit short of amount
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::DelegatedInsufficient));
    }

    #[test]
    fn cap_is_a_ceiling() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.amount = 1_001; // cap is 1_000
        i.src_delegated_amount = 2_000;
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::CapExceeded));
    }

    #[test]
    fn zero_amount_and_zero_floor_refuse() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.amount = 0;
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::AmountZero));
        let mut i = inputs(&r, router);
        i.min_out = 0;
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::MinOutZero));
    }

    #[test]
    fn mint_mismatch_refuses_both_sides() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.src_mint = Pubkey::new_unique();
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::MintMismatch));
        let mut i = inputs(&r, router);
        i.dest_mint = Pubkey::new_unique();
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::MintMismatch));
    }

    #[test]
    fn venue_must_match_be_executable_and_not_self() {
        let r = rule();
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.venue_program = Pubkey::new_unique();
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::VenueMismatch));
        let mut i = inputs(&r, router);
        i.venue_is_executable = false;
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::VenueNotExecutable));
        let mut i = inputs(&r, router);
        i.self_program = r.venue_program; // venue IS this program
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::SelfCpiForbidden));
    }

    #[test]
    fn deltas_happy_path() {
        assert!(deltas(1_000, 500, 0, 750, 500, 750).is_ok());
        // spending LESS than authorised is fine; receiving MORE is fine
        assert!(deltas(1_000, 600, 0, 900, 500, 750).is_ok());
    }

    #[test]
    fn deltas_refuse_overdraw_even_when_venue_lies() {
        // venue pulled 501 via the delegate though the rule said 500
        assert_eq!(
            err_of(deltas(1_000, 499, 0, 9_999, 500, 1)),
            code(RouterError::SrcOverdraw)
        );
        // src balance went UP — nonsense state, refuse
        assert_eq!(
            err_of(deltas(1_000, 1_001, 0, 9_999, 500, 1)),
            code(RouterError::SrcOverdraw)
        );
    }

    #[test]
    fn deltas_refuse_short_proceeds() {
        assert_eq!(
            err_of(deltas(1_000, 500, 0, 749, 500, 750)),
            code(RouterError::MinOutNotMet)
        );
        // dest balance FELL — venue stole from the destination: refuse
        assert_eq!(
            err_of(deltas(1_000, 500, 100, 99, 500, 1)),
            code(RouterError::MinOutNotMet)
        );
    }

    #[test]
    fn rule_params_validation() {
        let me = Pubkey::new_unique();
        let good = rule();
        assert!(check_rule_params(&good, me).is_ok());
        let mut r = rule();
        r.amount_cap = 0;
        assert_eq!(err_of(check_rule_params(&r, me)), code(RouterError::BadRuleParams));
        let mut r = rule();
        r.dest_mint = r.mint;
        assert_eq!(err_of(check_rule_params(&r, me)), code(RouterError::BadRuleParams));
        let mut r = rule();
        r.kind = 7;
        assert_eq!(err_of(check_rule_params(&r, me)), code(RouterError::RuleKindUnknown));
        let mut r = rule();
        r.venue_program = me; // self as venue
        assert_eq!(err_of(check_rule_params(&r, me)), code(RouterError::SelfCpiForbidden));
        // V1.1 / F2: a floorless exit rule is refused at WRITE time.
        let mut r = rule();
        r.min_out_floor = 0;
        assert_eq!(err_of(check_rule_params(&r, me)), code(RouterError::BadRuleParams));
    }

    // ── V1.1 remediation (audit F1 + F2, Caliper 2026-08-16) ────────────────

    #[test]
    fn f2_regression_cranker_cannot_undercut_the_owner_floor() {
        // Caliper's demonstrated hole, pinned as a permanent red line: a
        // whole-position exit with min_out=1 used to pass check_exit outright.
        let mut r = rule();
        r.min_out_floor = 750; // owner authored at set_rule, entry-basis
        let router = Pubkey::new_unique();
        let mut i = inputs(&r, router);
        i.min_out = 1; // the F2 attack
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::MinOutBelowFloor));
        i.min_out = 749; // just under still refuses
        assert_eq!(err_of(check_exit(&r, &i)), code(RouterError::MinOutBelowFloor));
        i.min_out = 750; // at the floor passes
        assert!(check_exit(&r, &i).is_ok());
        i.min_out = 800; // tightening beyond the floor is always allowed
        assert!(check_exit(&r, &i).is_ok());
    }

    #[test]
    fn f1_delta_site_reasserts_dest_mint() {
        let want = Pubkey::new_unique();
        let got = Pubkey::new_unique();
        assert_eq!(
            err_of(check_deltas(1_000, 500, 0, 750, 500, 750, want, got)),
            code(RouterError::DeltaMintMismatch)
        );
        assert!(check_deltas(1_000, 500, 0, 750, 500, 750, want, want).is_ok());
    }
}
