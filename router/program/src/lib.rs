//! POSSESSIO ROUTER — one SPL delegate, N ratified rules.
//!
//! THE CONSTRAINT THIS DISSOLVES: an SPL token account has exactly ONE
//! delegate field. Delegate it to a bare keypair (the Model B keeper) and the
//! slot is spent, authority must be POLLED to honor revokes (the measured
//! 2.5M-call/15-day RPC burn), and one key compromise is every position at
//! once. Delegate it instead to this program's per-owner PDA and the one slot
//! becomes a registry: each rule carries its own cap, venue, expiry, and
//! instant revocation, and authority is verified AT WRITE TIME — inside the
//! same transaction that acts — so there is nothing to poll and no window
//! where stale authority can move a token.
//!
//! THE FIVE KEEPER RULES, COMPILED (see keeper/index.js for their origin):
//!   1. Revoke is instant     → src ATA's live delegate + delegated_amount are
//!                              read in-tx (rules::check_exit); an SPL revoke
//!                              or rule revoke is effective at the next tx.
//!   2. No act without a rule → the only fund-moving instruction requires a
//!                              registry rule lookup; there is no other path.
//!   3. Never exceed grant    → amount ≤ cap ≤ delegated_amount pre-CPI, AND
//!                              post-CPI balance deltas revert any overdraw
//!                              (rules::check_deltas) — hostile venues included.
//!   4. Proceeds to the user  → destination is the OWNER's own ATA by account
//!                              constraint, and must grow ≥ min_out or the tx
//!                              reverts.
//!   5. No trigger in here    → this program stores no prices and cannot fire
//!                              itself; WHEN to exit stays off-chain (the
//!                              cranker), WHAT an exit may do is chain law.
//!
//! TRUST BOUNDARY, stated plainly for auditors: timing and route quality are
//! cranker-trusted (bounded by min_out); custody, authority, amount, and
//! destination are trustless. The cranker's key can grief; it cannot steal.
//!
//! V1 = the exit module only. Payroll / merchant settlement are future `kind`s
//! against this same registry — that is the payments-rail seam, not built here.
//!
//! PROGRAM ID: placeholder until first deploy (Architect ratifies deploys).

use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::Instruction, program::invoke_signed};
use anchor_spl::token_interface::TokenAccount;

pub mod rules;
use rules::{check_deltas, check_exit, check_rule_params, ExitInputs};

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

pub const MAX_RULES: usize = 16;
pub const RULE_KIND_EXIT: u8 = 0;

pub const REGISTRY_SEED: &[u8] = b"registry";
pub const ROUTER_SEED: &[u8] = b"router";

#[program]
pub mod possessio_router {
    use super::*;

    /// One registry per owner. Created by the owner, owned by the owner.
    pub fn init_registry(ctx: Context<InitRegistry>) -> Result<()> {
        let reg = &mut ctx.accounts.registry;
        reg.owner = ctx.accounts.owner.key();
        reg.bump = ctx.bumps.registry;
        reg.router_bump = ctx.bumps.router_authority;
        reg.rules = Vec::new();
        Ok(())
    }

    /// Owner-signed upsert. Writing a rule is the ONLY way authority gains an
    /// instruction; the SPL approve alone moves nothing (keeper rule 2).
    #[allow(clippy::too_many_arguments)]
    pub fn set_rule(
        ctx: Context<OwnerOnly>,
        id: u64,
        kind: u8,
        mint: Pubkey,
        dest_mint: Pubkey,
        amount_cap: u64,
        expires_ts: i64,
        venue_program: Pubkey,
    ) -> Result<()> {
        let rule = Rule { id, kind, mint, dest_mint, amount_cap, expires_ts, active: true, venue_program };
        check_rule_params(&rule, crate::ID)?;
        let reg = &mut ctx.accounts.registry;
        if let Some(slot) = reg.rules.iter_mut().find(|r| r.id == id) {
            *slot = rule.clone();
        } else {
            require!(reg.rules.len() < MAX_RULES, RouterError::RulesFull);
            reg.rules.push(rule.clone());
        }
        emit!(RuleSet { owner: reg.owner, id, kind, mint, amount_cap });
        Ok(())
    }

    /// Owner-signed, effective immediately — the rule-level kill switch. The
    /// SPL-level revoke (owner revokes the delegate at the token program)
    /// works independently and needs nothing from this program.
    pub fn revoke_rule(ctx: Context<OwnerOnly>, id: u64) -> Result<()> {
        let reg = &mut ctx.accounts.registry;
        let rule = reg.rules.iter_mut().find(|r| r.id == id).ok_or(RouterError::RuleNotFound)?;
        rule.active = false;
        emit!(RuleRevoked { owner: reg.owner, id });
        Ok(())
    }

    /// The exit. Cranker-submitted (any fee payer), chain-decided. Verifies
    /// the rule AND the live SPL delegate atomically, marks the rule spent,
    /// CPIs the owner-ratified venue with the PDA's signature, then re-reads
    /// balances and reverts everything unless the deltas obey the rule.
    pub fn execute_exit<'info>(
        ctx: Context<'_, '_, 'info, 'info, ExecuteExit<'info>>,
        rule_id: u64,
        amount: u64,
        min_out: u64,
        venue_data: Vec<u8>,
    ) -> Result<()> {
        let registry = &mut ctx.accounts.registry;
        let rule = registry
            .rules
            .iter_mut()
            .find(|r| r.id == rule_id)
            .ok_or(RouterError::RuleNotFound)?
            .clone();

        check_exit(
            &rule,
            &ExitInputs {
                now_ts: Clock::get()?.unix_timestamp,
                amount,
                min_out,
                src_mint: ctx.accounts.src_ata.mint,
                dest_mint: ctx.accounts.dest_ata.mint,
                src_delegate: ctx.accounts.src_ata.delegate.into(),
                src_delegated_amount: ctx.accounts.src_ata.delegated_amount,
                router_authority: ctx.accounts.router_authority.key(),
                venue_program: ctx.accounts.venue_program.key(),
                venue_is_executable: ctx.accounts.venue_program.executable,
                self_program: crate::ID,
            },
        )?;

        // EFFECTS BEFORE INTERACTIONS. The rule is spent and PERSISTED before
        // the venue runs: V1 rules are one-shot (the desk's semantics — a
        // fired exit closes the position), and writing state to the account
        // buffer before the CPI means even a venue that somehow re-enters
        // sees the rule already dead. The cap decrement is kept although the
        // rule deactivates, so a future multi-shot kind inherits the
        // accounting, not a foot-gun.
        {
            let r = registry.rules.iter_mut().find(|r| r.id == rule_id).unwrap();
            r.amount_cap = r.amount_cap.saturating_sub(amount);
            r.active = false;
            let reg_info = registry.to_account_info();
            registry.exit(&crate::ID)?; // serialize NOW, not at handler end
            let _ = reg_info;
        }

        let src_before = ctx.accounts.src_ata.amount;
        let dest_before = ctx.accounts.dest_ata.amount;

        // The venue's account list is cranker-supplied (routes differ per
        // trade). Signature policy: ONLY the router PDA may be marked signer —
        // every other meta is stripped to non-signer, so the cranker cannot
        // launder anyone else's authority through this invoke.
        let router_key = ctx.accounts.router_authority.key();
        let metas: Vec<_> = ctx
            .remaining_accounts
            .iter()
            .map(|a| anchor_lang::solana_program::instruction::AccountMeta {
                pubkey: a.key(),
                is_signer: a.key() == router_key,
                is_writable: a.is_writable,
            })
            .collect();
        let ix = Instruction { program_id: ctx.accounts.venue_program.key(), accounts: metas, data: venue_data };
        let owner_key = ctx.accounts.owner.key();
        let seeds: &[&[u8]] = &[ROUTER_SEED, owner_key.as_ref(), &[registry.router_bump]];
        let mut infos = vec![ctx.accounts.venue_program.to_account_info()];
        infos.extend(ctx.remaining_accounts.iter().cloned());
        invoke_signed(&ix, &infos, &[seeds])?;

        // SETTLEMENT LAW: re-read, then judge. Intent proves nothing — the
        // delegate may permit more than `amount`; only deltas are truth.
        ctx.accounts.src_ata.reload()?;
        ctx.accounts.dest_ata.reload()?;
        check_deltas(
            src_before,
            ctx.accounts.src_ata.amount,
            dest_before,
            ctx.accounts.dest_ata.amount,
            amount,
            min_out,
        )?;

        emit!(ExitExecuted {
            owner: owner_key,
            rule_id,
            amount_in: src_before - ctx.accounts.src_ata.amount,
            amount_out: ctx.accounts.dest_ata.amount - dest_before,
            venue: ctx.accounts.venue_program.key(),
        });
        Ok(())
    }

    /// Owner-signed cleanup; refuses while any rule is still live.
    pub fn close_registry(ctx: Context<CloseRegistry>) -> Result<()> {
        require!(
            ctx.accounts.registry.rules.iter().all(|r| !r.active),
            RouterError::RulesStillActive
        );
        Ok(())
    }
}

/* ─────────────────────────────── state ─────────────────────────────── */

#[account]
#[derive(InitSpace)]
pub struct Registry {
    pub owner: Pubkey,
    pub bump: u8,
    pub router_bump: u8,
    #[max_len(16)] // MAX_RULES — InitSpace needs the literal
    pub rules: Vec<Rule>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct Rule {
    pub id: u64,
    pub kind: u8, // RULE_KIND_EXIT; payroll/merchant are future kinds
    pub mint: Pubkey,
    pub dest_mint: Pubkey,
    pub amount_cap: u64,
    pub expires_ts: i64, // 0 = never
    pub active: bool,
    pub venue_program: Pubkey, // owner-ratified swap venue for THIS rule
}

/* ─────────────────────────────── accounts ─────────────────────────────── */

#[derive(Accounts)]
pub struct InitRegistry<'info> {
    #[account(
        init,
        payer = owner,
        space = 8 + Registry::INIT_SPACE,
        seeds = [REGISTRY_SEED, owner.key().as_ref()],
        bump
    )]
    pub registry: Account<'info, Registry>,
    /// CHECK: pure signer PDA — holds no data, exists only as the delegate
    /// target the owner approves at the token program.
    #[account(seeds = [ROUTER_SEED, owner.key().as_ref()], bump)]
    pub router_authority: UncheckedAccount<'info>,
    #[account(mut)]
    pub owner: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct OwnerOnly<'info> {
    #[account(
        mut,
        seeds = [REGISTRY_SEED, owner.key().as_ref()],
        bump = registry.bump,
        has_one = owner @ RouterError::OwnerMismatch
    )]
    pub registry: Account<'info, Registry>,
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct ExecuteExit<'info> {
    #[account(
        mut,
        seeds = [REGISTRY_SEED, owner.key().as_ref()],
        bump = registry.bump,
        has_one = owner @ RouterError::OwnerMismatch
    )]
    pub registry: Account<'info, Registry>,
    /// CHECK: not a signer — the owner is asleep at 3am; that is the point.
    /// Bound to the registry by has_one above and to both ATAs below.
    pub owner: UncheckedAccount<'info>,
    /// CHECK: pure signer PDA, seeds-checked against THIS owner.
    #[account(seeds = [ROUTER_SEED, owner.key().as_ref()], bump = registry.router_bump)]
    pub router_authority: UncheckedAccount<'info>,
    /// The user's own token account for the rule's mint. Its live delegate
    /// and delegated_amount are the authority check (keeper rule 1).
    #[account(mut, constraint = src_ata.owner == owner.key() @ RouterError::SrcOwnerMismatch)]
    pub src_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Proceeds destination: the OWNER's account, never the cranker's
    /// (keeper rule 4). Mint equality vs the rule is enforced in check_exit.
    #[account(mut, constraint = dest_ata.owner == owner.key() @ RouterError::DestOwnerMismatch)]
    pub dest_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Any fee payer. Holds no authority — its signature moves nothing by
    /// itself; every check above is indifferent to WHO submitted.
    pub cranker: Signer<'info>,
    /// CHECK: equality with the rule's ratified venue + executability are
    /// enforced in check_exit before any CPI.
    pub venue_program: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct CloseRegistry<'info> {
    #[account(
        mut,
        close = owner,
        seeds = [REGISTRY_SEED, owner.key().as_ref()],
        bump = registry.bump,
        has_one = owner @ RouterError::OwnerMismatch
    )]
    pub registry: Account<'info, Registry>,
    #[account(mut)]
    pub owner: Signer<'info>,
}

/* ─────────────────────────────── events ─────────────────────────────── */

#[event]
pub struct RuleSet {
    pub owner: Pubkey,
    pub id: u64,
    pub kind: u8,
    pub mint: Pubkey,
    pub amount_cap: u64,
}

#[event]
pub struct RuleRevoked {
    pub owner: Pubkey,
    pub id: u64,
}

#[event]
pub struct ExitExecuted {
    pub owner: Pubkey,
    pub rule_id: u64,
    pub amount_in: u64,
    pub amount_out: u64,
    pub venue: Pubkey,
}

/* ─────────────────────────────── errors ─────────────────────────────── */

#[error_code]
pub enum RouterError {
    #[msg("registry owner mismatch")]
    OwnerMismatch,
    #[msg("rule not found")]
    RuleNotFound,
    #[msg("rule is inactive")]
    RuleInactive,
    #[msg("rule has expired")]
    RuleExpired,
    #[msg("unknown rule kind")]
    RuleKindUnknown,
    #[msg("amount must be > 0")]
    AmountZero,
    #[msg("min_out must be > 0")]
    MinOutZero,
    #[msg("amount exceeds rule cap")]
    CapExceeded,
    #[msg("mint does not match rule")]
    MintMismatch,
    #[msg("source ATA delegate is not the router")]
    DelegateMismatch,
    #[msg("delegated amount insufficient")]
    DelegatedInsufficient,
    #[msg("venue does not match rule")]
    VenueMismatch,
    #[msg("venue is not executable")]
    VenueNotExecutable,
    #[msg("self-CPI forbidden")]
    SelfCpiForbidden,
    #[msg("source overdrawn beyond authorised amount")]
    SrcOverdraw,
    #[msg("proceeds below min_out")]
    MinOutNotMet,
    #[msg("registry rule slots full")]
    RulesFull,
    #[msg("bad rule params")]
    BadRuleParams,
    #[msg("source ATA not owned by owner")]
    SrcOwnerMismatch,
    #[msg("destination ATA not owned by owner")]
    DestOwnerMismatch,
    #[msg("rules still active")]
    RulesStillActive,
}
