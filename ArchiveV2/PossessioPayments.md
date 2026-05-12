# PossessioPayments

A merchant payment processor — non-custodial smart contract infrastructure for Base mainnet card-payment settlement and rewards-accruing treasury accumulation.

## What it is

PossessioPayments is a smart contract the merchant deploys and owns. It receives USDC inflows from card-network settlement (e.g. Stripe split payouts to a merchant-controlled wallet), routes a configurable portion into a DAI working-capital reserve, and routes the remainder into a cbETH rewards-accruing treasury.

POSSESSIO sells the contract as one-time software. After deployment, POSSESSIO retains zero on-chain authority. The merchant holds OWNER_ROLE and operates the contract themselves.

## What it is not

- Not a custodial product. Funds never leave the merchant's contract.
- Not a payment processor in the regulated sense. The contract receives USDC the merchant routed to it; it does not initiate payments or operate card-network rails.
- Not a financial service. It's smart contract software the merchant deploys.
- Not a money transmitter. The merchant's funds remain in the merchant's possession throughout.

## Stripe compatibility

PossessioPayments is **Stripe compatible**. The merchant integrates their existing Stripe account through standard API integration. Stripe handles card-network rails as it always has. Net proceeds route into the PossessioPayments contract via the merchant's standard Stripe payout configuration.

No partnership, approval, or special status is required. The merchant operates their Stripe account. The merchant operates their PossessioPayments contract. POSSESSIO doesn't sit between them.

## Architecture

### Token routing

Inflows arrive as USDC. The merchant configures a daily withdrawal limit on DAI (operating capital). Sweep operations convert excess USDC into the cbETH treasury position.

- **USDC inflows** — primary intake from card-network settlement
- **DAI reserve** — operating capital, configurable ceiling, daily withdrawal limit, merchant-controlled distributions to payees
- **cbETH treasury** — long-term rewards-accruing position, accrues Coinbase's liquid staking rewards passively

### UCR — Universal Coin Router

The internal routing mechanism. UCR receives USDC inflows, applies the merchant's configured split between DAI and cbETH, executes swaps via Uniswap V3 SwapRouter02 on Base, and emits structured events for off-chain accounting.

UCR enforces:
- Sweep cooldown (`SWEEP_DELAY = 24 hours` minimum between sweeps)
- Slippage protection on swaps
- Reentrancy guards
- Pause/resume governance via timelock

### cbETH treasury notes

cbETH is held as a rewards-accruing asset that accrues Ethereum staking rewards passively via Coinbase's liquid staking token. cbETH is **not redeemed on-chain** by this contract. Merchants who wish to convert cbETH to ETH may do so via DEX swap or off-chain Coinbase unwrap.

This single-LST design is structural: rETH on Base mainnet is a bridged OptimismMintableERC20 token whose `burn()` function is gated by `onlyBridge` — non-redeemable from user contracts on Base. cbETH-only treasury avoids the bridge dependency entirely.

## Permission structure

PossessioPayments uses OpenZeppelin AccessControl with three roles:

### OWNER_ROLE

The merchant. Full authority:
- Withdraw funds (DAI from operating reserve, emergency withdraws of any token)
- Set parameters (DAI ceiling, daily limits, payee mappings)
- Grant and revoke OPERATOR_ROLE and GUARDIAN_ROLE
- Toggle Guardian enable/disable
- Queue and execute timelocked operations

OWNER_ROLE is granted to the merchant address at deployment and cannot be revoked except by the owner themselves.

### OPERATOR_ROLE

Optional day-to-day role. Granted by the owner post-deploy if a delegated operator is needed (e.g. a store manager handling routine sweep operations).

OPERATOR_ROLE can:
- Execute sweep operations (UCR routing)
- Queue pause via standard governance flow
- Execute scheduled pause operations

OPERATOR_ROLE **cannot**:
- Withdraw funds
- Change parameters
- Manage roles
- Bypass timelocks

### GUARDIAN_ROLE

Optional security-system role. Granted by the owner if a separate security system needs emergency pause capability.

GUARDIAN_ROLE can pause the contract **only when** `guardianEnabled == true`. The owner toggles `guardianEnabled` separately. Default is `guardianEnabled = false`.

GUARDIAN_ROLE **cannot**:
- Withdraw funds
- Resume operations after pause (only owner can resume)
- Sweep
- Change parameters
- Manage roles

This role exists for security service integration (e.g. an off-chain monitoring system that detects suspicious activity and triggers pause). The merchant remains the only party who can resume after a guardian pause.

## Timelocks

PossessioPayments uses two timelock periods for different classes of action:

- **`TIMELOCK = 48 hours`** — owner-pause resume delay; daily limit increases must be queued and executed after this delay
- **`EMERGENCY_DELAY = 7 days`** — emergency withdrawal of arbitrary tokens requires this delay

The two delays serve different purposes. Routine operations (resuming after pause, increasing daily limits) wait 48h to give the merchant time to detect compromise. Emergency withdrawals (force-recovery in terminal scenarios) wait 7 days to prevent rapid drain by a compromised key.

Timelock enforcement is consistent: queued operations cannot execute before the delay elapses; the contract cannot be tricked into bypassing the delay through any caller path.

## Daily withdrawal limits

The merchant configures a daily limit on DAI withdrawals from the operating reserve. The daily window is exact 24-hour boundaries, not calendar days.

The limit can be **decreased immediately** by the owner (tightening the constraint).

The limit can only be **increased through timelock**: queue the increase, wait 48 hours, execute. This prevents an attacker who somehow obtains owner credentials from instantly raising the daily limit and draining the reserve.

Daily limit logic is isolated from emergency withdrawal logic. The 7-day emergency delay applies regardless of daily limit state.

## Sweep operation

The sweep operation moves accumulated USDC into the cbETH treasury via DEX swap.

Sweep characteristics:
- **24-hour cooldown** between sweeps (`SWEEP_DELAY`)
- Variable timing recommended — do **not** call sweep on a predictable schedule, as MEV bots pattern-match predictable calls
- Slippage protection on the underlying Uniswap V3 swap
- Reentrancy guards
- Reverts cleanly if no USDC available to sweep

The 24-hour cooldown is a minimum, not a recommended cadence. Merchants should vary their sweep timing to avoid pattern detection.

## Emergency withdrawal

For terminal events (compromise, sunset, force-recovery of stuck funds), the owner can queue an emergency withdrawal of any token to any destination, executable after the 7-day timelock.

Queue → wait 7 days → execute. The 7-day delay is non-bypassable. This is the merchant's safety valve for catastrophic scenarios; it is not for routine operations.

## Verified properties

The contract is forge-tested at 118/118 passing across two suites:

- `PossessioPayments_t.sol` — 86 core tests covering deployment, role separation, routing, sweep, withdraw, timelock, daily limit, pause/resume, and full-flow scenarios
- `PossessioPayments_Gauntlet.t.sol` — 32 adversarial tests covering attack vectors

### Adversarial coverage

The Gauntlet suite encodes invariants surfaced from known attack vectors:

- **Operating capital not held hostage** — no path exists where another party can lock the merchant's funds
- **Operator cannot escalate** — OPERATOR_ROLE cannot raise daily limits, withdraw, or grant roles to themselves
- **Guardian cannot withdraw or unpause** — GUARDIAN_ROLE is strictly pause-only
- **Deployer has no residual authority** — once deployed, POSSESSIO has no special permissions
- **No hidden upgradeability** — the contract has no upgrade functions, no proxy pattern, no admin override
- **Timelock cannot be bypassed** — emergency delay and standard timelock both enforced exactly
- **Window boundary correctness** — daily limit windows reset at exact 24h boundaries with no off-by-one
- **Oracle revert handled** — Chainlink failures degrade gracefully without compromising contract state
- **Oracle negative answer rejected** — malicious or buggy oracle responses don't propagate
- **Malicious token cannot drain** — sweep operation hardened against tokens designed to exploit conversion
- **Malicious router resistance** — no permanent approvals granted; approval handling bounded
- **No approval after successful sweep** — router approvals revoked after each operation
- **Sweep cooldown bypass blocked** — 24-hour cooldown enforced exactly
- **State integrity across multi-action sequences** — operations that span multiple calls don't leave the contract in inconsistent state
- **Recovery from failure paths** — failed operations can be retried cleanly; state remains consistent
- **Dust handling** — sweep handles small leftover balances correctly across 256 fuzz runs

Each test corresponds to an invariant the contract holds against a category of known DeFi exploit. The full list is in `test/PossessioPayments_Gauntlet.t.sol`.

## External dependencies

PossessioPayments integrates with the following Base mainnet addresses:

| Component | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| cbETH | `0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22` |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Chainlink ETH/USD oracle | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |

These addresses are immutable in the deployed contract. They are verified Base mainnet canonical contracts.

## Status

**Pre-deployment.** The contract is forge-verified at 118/118 passing. Continued testing is in progress. Mainnet deployment will follow when continued testing reaches the threshold the council judges sufficient for the merchant tier.

## Deployment model recap

- Merchant purchases PossessioPayments as one-time software
- Contract deployed with merchant address as OWNER_ROLE
- POSSESSIO has no role, no key, no override on the merchant's deployment
- Merchant configures DAI ceiling, daily limit, and any optional roles
- Merchant operates the contract — sweep, withdraw, manage payees, monitor balance
- POSSESSIO ships the software; the merchant runs it

## Why this matters

Conventional payment processors extract percentage-based fees on every transaction in perpetuity. PossessioPayments replaces ongoing percentage extraction with one-time software ownership. The merchant pays card-network fees (Stripe's published rates) once per transaction; the merchant does not pay POSSESSIO any percentage on any transaction, ever.

The cbETH treasury accrues Coinbase's protocol-determined rewards while held. The merchant's working capital sits in DAI for stable-value operational liquidity. The split is configured by the merchant.

The contract guarantees full custody to the merchant throughout. Funds never sit in third-party accounts waiting for remittance. The merchant's keys hold the merchant's funds.

---

For the broader POSSESSIO framework context, see [`README.md`](../README.md).
