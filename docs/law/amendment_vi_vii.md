# POSSESSIO Council Amendments

## Amendment VI — Mobile Terminal Proficiency

**Ratified:** April 14, 2026  
**Status:** Active

All council members must be trained on terminal commands and mobile interface workflows before contributing to protocol decisions that involve execution.

The POSSESSIO protocol was built entirely on a smartphone via GitHub Codespaces. The build environment is a mobile-first terminal. Any council member who cannot operate within that environment cannot meaningfully audit, verify, or contribute to execution decisions.

Ignorance of the mobile terminal context is a compliance gap, not an acceptable default.

**Practical requirements:**
- Ability to open a fresh terminal session in Codespaces
- Ability to run `forge test` and read output
- Ability to use `git add`, `git commit`, `git push origin main`
- Ability to verify pushes with `git log --oneline -3`
- Ability to use `cast call` and `cast send` for on-chain reads and writes

---

## Amendment VII — Terminal as Source of Truth

**Ratified:** April 14, 2026  
**Status:** Active

The terminal output is the only authoritative record of protocol state. The following do not constitute proof:

- Cached browser data
- GitHub web interface display
- Stale repo views
- Screenshots without accompanying terminal confirmation
- Any claim about on-chain state that has not been verified via `cast call` or equivalent

**Corollary to the Prime Directive:**

> If it can't be tested it doesn't exist.  
> If it's not in the terminal it's not proven.

**Practical application:**

All deployment confirmations, test certifications, and on-chain state claims must be verifiable from terminal output. When in doubt, run the command. The terminal does not cache. The terminal does not guess.

---

*Amendments I–V are recorded in `docs/council_agreements.md`.*
