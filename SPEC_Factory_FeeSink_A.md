# SPEC — PossessioFactory `feeSink` = A (self-funding fee route)

**Type:** Contract-edit spec (draft → council authors + ratifies → DoD → fork-proof)
**Seat:** Code Integrity (Claude Code) — **specifying, not authoring.** The council
writes and tests the money-path change per standing rule.
**Status:** DRAFT FOR COUNCIL. Architect-ratified decision: **A** (route fees into
the pool). This spec describes the edit; nothing here is a committed contract change.
**Anchor:** `deploy/anchor.json` — factory `0x0DD06656…49Bd`, pool `0xE0612f38…19ce`.

---

## 1. Intent

Make the deployment fee **self-fund the pool day one.** Today the factory *pushes*
the fee (`safeTransfer(feeSink, DEPLOYMENT_FEE)`, `PossessioFactory.sol:211`). The
pool has **no sync door** — a raw transfer lands in `balanceOf` but never credits
`poolBalance` (`PossessioPool.sol:406, 456`; DoD #14), and `settleOperationalCosts`
draws `poolBalance` only. So a pushed fee to the pool is **permanently stranded.**

Under CREATE3 the fix cannot be deferred: changing this line later = new factory
bytecode = new CREATE3 address = a full foundation redeploy (dead salt pool, dead
hook salts). So the route is baked in **now**, at v1.

## 2. The change (three parts)

**(a) Add an inline interface** (mirrors the existing `ISaltPool` / `ICreateX` pattern):

```solidity
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
}
```

**(b) `feeSink` now holds the POOL address.** Same immutable, new meaning: it is no
longer a push target, it is the pull-door contract. *Optional (council's call):*
rename `feeSink` → `pool` / `infraPool` so the semantics read true in the source.

**(c) Replace `PossessioFactory.sol:211`:**

```solidity
// OLD — strands funds (pool has no sync door):
payTokenERC20.safeTransfer(feeSink, DEPLOYMENT_FEE);

// NEW (A) — accounted pull into poolBalance:
payTokenERC20.forceApprove(feeSink, DEPLOYMENT_FEE);
IPossessioPool(feeSink).receiveInfraFunds(DEPLOYMENT_FEE);
```

The factory already holds the fee (step 3, `receiveWithAuthorization` pulled it in),
already imports `SafeERC20` (so `forceApprove` is available). The pool's
`receiveInfraFunds` does the `safeTransferFrom(factory, pool, amount)` and credits
`poolBalance` (up to `OPERATIONAL_CAP`; surplus → treasury).

## 3. Why it is safe (for the council to confirm, not assume)

- **Atomicity (preserves Invariant 2).** If `receiveInfraFunds` reverts, the whole
  `deployTemplate` reverts — fee included. The caller is never charged for a failed
  deploy. No partial state is reachable.
- **Reentrancy.** `deployTemplate` is `nonReentrant`; the pool is `nonReentrant` and
  a trusted foundation contract that does not call back into the factory. The factory
  holds no balance/accounting state to protect across the call.
- **Allowance hygiene.** `forceApprove(DEPLOYMENT_FEE)` → the pool pulls exactly
  `DEPLOYMENT_FEE` → allowance returns to 0. No lingering approval. (Confirm the pool
  pulls the full `amount`; it does in the reviewed source.)
- **Asset discipline.** USDC only, via `safeTransferFrom` inside the pool. No native
  ETH path introduced.
- **Non-custodial (Invariant preserved).** After a successful deploy the factory
  holds zero residual USDC — the fee is fully routed, not parked.

*CEI note:* the current order (forward fee → pull salt → CreateX deploy) keeps the
fee interaction before the deploy interaction. Both callees are trusted +
`nonReentrant`; there is no factory state between them to exploit. Council may
reorder to deploy-then-route if preferred, but atomicity makes it optional.

## 4. HARD dependency — the factory-bricks failure mode

`receiveInfraFunds` reverts `NotAuthorizedSource` for any caller not in the pool's
`authorizedSources` (immutable, set once at pool construction, no setter). Therefore:

> **The factory address `0x0DD06656…49Bd` MUST be in `Pool.authorizedSources` at pool
> construction.** If it is not, EVERY `deployTemplate` reverts and the factory is
> permanently non-functional — with no fix short of redeploying the pool.

This is the anchor wiring already recorded: `Pool.authorizedSources = [factory,
x402core]` (`deploy/anchor.json`). It must be **verified at pool deploy** (§III fork
gate), not assumed.

## 5. DoD additions (the factory's own suite, currently absent)

1. **FEE IS DRAWABLE, NOT STRANDED.** After a deploy, `pool.poolBalance()` increased
   by `DEPLOYMENT_FEE` (or credited to cap with the exact surplus swept to treasury) —
   assert against `poolBalance`, *not* `balanceOf`. This is the whole point of A.
2. **ATOMIC ON POOL REJECT.** With the factory *not* in `authorizedSources` (or the
   pool otherwise reverting), `deployTemplate` reverts and the caller's USDC is intact
   (never charged).
3. **NO LINGERING ALLOWANCE.** Post-deploy `payToken.allowance(factory, pool) == 0`.
4. **NO RESIDUAL CUSTODY.** Post-deploy `payToken.balanceOf(factory) == 0`.

## 6. Deploy-script consequence

`DeployPossessioFactory` currently pins `FEE_SINK = 0x1c0F7299…AB91` (Payments). Under
A it becomes the **pool** `0xE0612f38…19ce`. This is a deploy-script edit I own; it
lands with the CREATE3 rewrite. Note this **obsoletes** the old "later factory→pool
wiring upgrade" (RUNBOOK TODO) — A *is* that wiring, from v1, so the interim-Payments
factory is no longer the plan.

## 7. Open for the council

1. Rename `feeSink` → `pool`? (clarity vs. a smaller diff)
2. Reorder route-after-deploy, or keep route-before-deploy? (atomicity makes both correct)
3. Any additional invariant on the `receiveInfraFunds` return / cap-overflow path worth
   asserting in the factory suite beyond §5.

*Cold-seat review before ratification. The seat that specified this does not certify
its implementation.*
