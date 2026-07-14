// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
// BUILD-PROOF: DAI_LEG_REMOVED_OUT67 — DAI reserve/leg fully cut from hook (treasury serves as ETH reserve; freed 20%-of-75% stays as ETH). Removed: DAI token, DAI/USD+ETH/USD feeds, V3_ROUTER, _swapETHToDAI, cross-rate, daiReserve, DAI_TARGET, DAI_V3_FEE, DAI events, IV3SwapRouter. Kept: WETH (cbETH leg), cbETH leg, X-LINK, SAV.

/**
 * ██████╗ ██╗      █████╗ ████████╗███████╗
 * ██╔══██╗██║     ██╔══██╗╚══██╔══╝██╔════╝
 * ██████╔╝██║     ███████║   ██║   █████╗
 * ██╔═══╝ ██║     ██╔══██║   ██║   ██╔══╝
 * ██║     ███████╗██║  ██║   ██║   ███████╗
 * ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
 *
 * POSSESSIO PROTOCOL — v2.6.3 (STEEL + Chainlink Automation + Aerodrome cbETH route)
 * Protocol Liquidity Asset Treasury Engine, rebuilt as Uniswap V4 hook
 *
 * AUDIT REMEDIATION (2026-07-14, AUDIT_20260714 findings C-1 / C-4 / C-5):
 *   · C-1 (HIGH) — cbETH harvest was permanently dead. cbETH is NON-REBASING:
 *     balanceOf never grows; rewards accrue exclusively via cbETH/ETH
 *     exchange-rate appreciation (this contract's own staking comments say
 *     so). Yet _harvestRewards computed rewards as
 *     (cbETH.balanceOf(this) - cbETHPrincipal) with cbETHPrincipal tracking
 *     the balance exactly, so harvest ALWAYS reverted ZeroAmount, the
 *     checkUpkeep HARVEST branch could never become true, and rescueToken
 *     blocks cbETH — 75% of every captured fee converted into a one-way trap.
 *     Fix: VALUE-BASED harvest. New cbETHPrincipalETH accumulates the ETH-wei
 *     consumed by each staking deploy; harvest values the live cbETH balance
 *     via the existing Chainlink cbETH/ETH exchange-rate feed (the same feed
 *     _computeHarvestSlippageGuard already uses) and swaps out only the
 *     ETH-denominated excess:
 *         currentValueETH = cbBal * rate / 1e18
 *         excessETH       = currentValueETH - cbETHPrincipalETH
 *         rewardsCbETH    = excessETH * 1e18 / rate
 *     The ETH principal stays constant across harvests. Oracle-health guards
 *     keep the revert-and-retry-next-cycle semantics. HARVEST_DUST_FLOOR now
 *     gates the ETH-denominated excess on BOTH checkUpkeep and the execution
 *     path (value-math rounding residue below the floor is unharvestable by
 *     design, never a gas-burn loop). checkUpkeep's HARVEST predicate mirrors
 *     the execution math exactly, so it can actually fire. cbETHPrincipal
 *     (cbETH-wei) is retained as a pure acquisition record — see its NatSpec.
 *   · C-4 (LOW) — the 0.1% permissionless-caller reward was a production
 *     no-op: it was paid from address(this).balance AFTER routing had already
 *     spent the entire accumulator, so the balance guard failed unless the
 *     hook happened to hold untracked surplus ETH. Fix: the reward is carved
 *     out of `total` BEFORE the split; routing distributes (total - reward)
 *     and the reward is paid last, best-effort, CEI preserved. Exemptions
 *     unchanged (Treasury, automation forwarder, address(this)).
 *   · C-5 (LOW) — FeeCaptured now logs beforeSwap's `sender` parameter (the
 *     router/caller that invoked PoolManager.swap) instead of tx.origin, so
 *     indexers no longer misattribute router-mediated swaps.
 *
 * v2.6.3 (2026-05-30 RECONSTRUCTION) — supersedes the 2026-05-24 carry-through
 *   entry below, which is REVERTED (retained for lineage). Size + green
 *   reduction: revert the v2.6 dispatch and the 2026-05-24 carry-through
 *   dispatch and slippage carry-through to the v2.5 execution-time model.
 *   Three reverts, NO loss to the cbETH swap or oracle-correctness layer:
 *     1. Removed the try/catch dispatch wrappers (_routeETHDispatch /
 *        _harvestRewardsDispatch). routeETH / harvestRewards / performUpkeep
 *        arm the X-LINK secret and call the internal core directly. X-LINK's
 *        consume-immediately discipline + EVM revert atomicity make the direct
 *        model self-healing (Bugcatcher refutation of Grok's deadlock claim;
 *        invariant_XLinkAlwaysConsumed). The wrapper's own try/catch was the
 *        only thing that could create the stale-secret surface it cleaned up.
 *     2. Removed originalCaller threading; the reward exemption uses msg.sender
 *        directly. With no dispatcher there is no address(this) context shift,
 *        so the v2.6.2 caller-context regression cannot occur here.
 *     3. Retired the slippage carry-through. checkUpkeep encodes ONLY the task
 *        discriminator; the cores compute minDai/minCbETH/minWETH at execution
 *        time via the SAME _computeRouteSlippageGuards / _computeHarvest-
 *        SlippageGuard helpers (Option A: helpers retained, call sites moved).
 *   Aerodrome venue + exactInputSingle selector cast-confirmed (Architect).
 *   Behavioral note: automation no longer pre-screens oracle health at check
 *   time, so the forwarder may occasionally fire a no-op that retains (route)
 *   or reverts (harvest). Accepted tradeoff for size + determinism.
 *   UNVERIFIED until terminal compile_56 + full suite. Version label pending
 *   Architect ratification.
 *
 * v2.6.3 (2026-05-24) — Slippage carry-through fix (test_CheckUpkeep_PerformDataCarriesSlippageGuards):
 *   · Pre-v2.6.3 reality: checkUpkeep encoded only the UpkeepTask discriminator.
 *     Slippage guards were computed at performUpkeep-time inside _routeETH /
 *     _deployToStaking / _harvestRewards using oracle reads at execution block.
 *   · Proper reality (council-aligned with Chainlink Automation v2.3 pattern):
 *     checkUpkeep — view-only — computes slippage from current oracle reads
 *     and packs them into performData. performUpkeep decodes them and threads
 *     them through dispatch to the internal cores, which use them directly.
 *   · Why this is the correct reality:
 *       1. Forwarder's checkUpkeep runs ~12s before performUpkeep. Stale oracle
 *          is caught at check-time before forwarder pays gas, not at execution.
 *       2. Slippage pinned at check-time; performUpkeep commits to that band.
 *          No mismatch between the decision basis and the execution basis.
 *       3. Matches Chainlink v2.3 performData pattern (council-ratified
 *          Automation integration cadence, 2026-05-12).
 *   · Implementation: performData encoding changes from `abi.encode(task)` to
 *     `abi.encode(task, minDai, minCbETH)` for ROUTE_ETH and
 *     `abi.encode(task, minWETH)` for HARVEST_REWARDS. Internal cores accept
 *     slippage params and use them instead of recomputing from oracles.
 *     Manual permissionless callers (external routeETH/harvestRewards) still
 *     compute slippage in the wrapper, preserving the fallback path.
 *
 * v2.6.2 (2026-05-24) — Caller-context regression fix:
 *   · The v2.6 X-LINK gas-griefing fix introduced an external try/catch wrapper
 *     (this._routeETHDispatch / this._harvestRewardsDispatch) between the
 *     wrapper and the internal core. This shifted `msg.sender` inside _routeETH
 *     and _harvestRewards from the original EOA to `address(this)` — the
 *     dispatcher's own context. The caller-reward exemption at lines 1006-1015
 *     explicitly excludes `address(this)` (defense-in-depth comment from v2.5,
 *     no longer load-bearing under X-LINK), so the dispatch path silently
 *     skipped the 0.1% reward to every permissionless caller.
 *
 *     Verified failure modes from report__47_.txt (forge test, 2026-05-24):
 *       - test_ManualPermissionlessCallerStillReceivesReward — balance unchanged
 *       - test_RouteETH_PermissionlessSucceedsAfterCooldownAndThreshold — same
 *       - testFuzz_ETHConservation — real ETH delta of 0.23 ETH counterexample
 *         (reward stays in contract instead of going to caller)
 *
 *     v2.6.2 fix: capture `originalCaller = msg.sender` in the external
 *     wrappers BEFORE the try/catch, thread it through the dispatchers and
 *     internal cores, and use `originalCaller` (not `msg.sender`) for the
 *     reward exemption check. Defense-in-depth `address(this)` exemption
 *     remains as a guard against any future re-entrant path.
 *
 *     Companion fix in performUpkeep: pass `automationForwarder` as
 *     originalCaller so the IV.2 forwarder-exemption path lands cleanly.
 *
 * v2.6.1 (2026-05-24) — Plate review pass against v2.6:
 *   · Finding 4 (INFO): _retainForRetry telemetry-required convention now
 *     documented in contract-level NatSpec. Helper is silent by design
 *     (per Bugcatcher Finding 4.1 helper purity); future callers must
 *     emit StakingRetained at the call site with their own reason code.
 *     No semantic change. Documentation hardening only.
 *   Findings 1 and 2 applied to PossessioPayments v2.4.1 (Morpho leg
 *     leakage check + verified share-delta in event). No hook changes
 *     required for those findings.
 *   Findings 3 and 5 acknowledged operationally (Chainlink gas budget
 *     bump for dispatcher overhead; empty-revert-reason edge case).
 *     No contract changes required.
 *
 * v2.6 (2026-05-24) — Phase 1.1 fixes folded into single drop:
 *   · X-LINK gas-griefing fix (Grok finding 2026-05-23): wrapper-side
 *     try/catch around _routeETH and _harvestRewards via _xlinkDispatch
 *     pattern. Failed internal calls now clear _activeExecutionSecret
 *     on the wrapper side and re-bubble the original revert reason.
 *     Closes the nonce-burn surface where v2.5 reverts could leave
 *     stale armed secrets for the next-call overwrite.
 *   · Event semantics fix (Bugcatcher/Grok finding 2026-05-23):
 *     StakingDeployed(0, ts) fragmented — successful deployments emit
 *     StakingDeployed with cbAmount populated; failure branches emit
 *     StakingRetained with an explicit reason code (1=depeg-pause,
 *     2=oracle-invalid, 3=wrap-failed, 4=swap-failed-unwrap-success,
 *     5=swap-failed-unwrap-stuck). v2.5 backwards-compat retained via
 *     deprecated dual-emit pattern.
 *
 *   v2.6 attribution — COUNCIL_2 + COUNCIL_3 shared work:
 *     · Bugcatcher: v2.6 integration of all Phase 1.1 findings into single drop.
 *     · Grok: X-LINK gas-griefing finding via adversarial full review
 *       (COUNCIL_2026-05-23). Distinguished armed-secret deadlock claim
 *       (refuted by Bugcatcher self-healing analysis) from wrapper-side
 *       nonce-burn wart (ratified, fixed here).
 *     · Plate: v2.5 helper-factoring discipline (_retainForRetry,
 *       _unwrapAndRetain) preserved in v2.6 unchanged.
 *     · Bugcatcher: original event-semantics finding extended to per-reason
 *       fragmentation; mirror of v2.4 payments contract event structure.
 *
 * v2.5 (2026-05-23) — cbETH False Green resolution. Routes captured ETH
 *   through Aerodrome Slipstream WETH→cbETH instead of the v2.4 cbETH.deposit()
 *   call that reverted on Base mainnet (cbETH on Base is OptimismMintableERC20,
 *   no payable deposit). Harvest path symmetrically swaps cbETH→WETH→ETH.
 *   Chainlink cbETH/ETH oracle handling corrected to 18-decimal precision
 *   (Chainlink's exchange-rate-feed class for yield-bearing assets natively
 *   outputs 18 decimals, distinct from the 8-decimal price-feed class used
 *   by DAI/ETH). Staleness window relaxed to 90,000s (25h) to accommodate
 *   Chainlink's 24-hour heartbeat cadence on this feed. Constructor adds
 *   asymmetric decimal validation as defense-in-depth.
 *
 *   v2.5 attribution — COUNCIL_2 shared-seat work product:
 *     · Bugcatcher: cbETH False Green discovery, terminal-grounded substrate
 *       closure (12 cast artifacts), Aerodrome venue identification,
 *       IcbETH interface lock-down (removed broken deposit/withdraw),
 *       constructor decimal-class guard, asymmetric error type declarations.
 *     · Plate: spec amendment, target spec v2 against terminal substrate,
 *       internal helper factoring (_retainForRetry, _unwrapAndRetain) for
 *       cleaner control flow at transient-failure branches.
 *     Discipline floor caught the False Green pre-launch. Multi-Byte work
 *     compounded at the seat; either Byte's individual contract was good;
 *     the combined v2.5 is better than either standalone version.
 *
 *   See: COUNCIL_2026-05-23_Bugcatcher_SubstrateClosure_PlateV2VenueAmendment.md
 *
 * v2.4 added Chainlink Automation v2.3 for routeETH() + harvestRewards()
 *   per COUNCIL_2026-05-12_Ratified_ChainlinkAutomationIntegration.
 *
 * FIX 3 (Architect-ratified 2026-05-20): performUpkeep ROUTE_ETH replay key
 *   changed from keccak256(abi.encode(task, lastRouteTime)) to
 *   keccak256(abi.encode(task, block.number)), matching the HARVEST_REWARDS
 *   branch. Resolves test_SameBlockReplayBlocked: lastRouteTime updates inside
 *   _routeETH so two same-block calls would compute different keys and the
 *   replay map missed the second call. block.number is fixed within a block;
 *   same-block calls now produce identical replay keys; replay map catches
 *   the second call as designed. Single-line change; no ABI impact.
 *
 * TWO CONTRACTS IN ONE FILE:
 *   - STEEL        — clean ERC20 token ("PLATE" / "STEEL")
 *   - PossessioHook — V4 hook + fee capture + treasury routing + SAV council logic
 *
 * FEE PIPELINE (v2.5):
 *   beforeSwap → capture 2% ETH via BeforeSwapDelta
 *   afterSwap  → emit FeeCaptured, no routing inline (V4 unlock constraint)
 *   routeETH   → external call, 25% LP / 75% Treasury
 *                  · 20% of 75% → DAI until $2,280 cap (V3 WETH→DAI)
 *                  · Remainder → cbETH via Aerodrome Slipstream WETH→cbETH
 *                                (rewards-accruing treasury, terminal-verified
 *                                 venue at 0x47ca96ea59c13f72745928887f84c9f52c3d7348)
 *
 * COUNCIL ALLOCATION (SAV logic, 3% of supply):
 *   Treasury → savDeposit() → claimable split across 4 council members
 *   savBurn()   → member burns own allocation
 *   invent() → 3-of-4 approval, collective deduction, Treasury executes
 *   pause/unpause/slash → Treasury-only
 *
 * STAKING REMOVED: PLATEStaking was ceremony over burn — eliminated from v2.
 *
 * Prime Directive: If it can't be tested, it doesn't exist.
 * If it's not in the terminal, it's not proven.
 *
 * License: MIT
 */

// ═══════════════════════════════════════════════════════════════════════════
//                              IMPORTS
// ═══════════════════════════════════════════════════════════════════════════

import {ERC20}          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit}    from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable}        from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step}   from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast}       from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Uniswap V4 — real imports from v4-core and v4-periphery
import {IPoolManager}    from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}          from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}         from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency}        from "v4-core/types/Currency.sol";
import {BalanceDelta}    from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary}    from "v4-core/libraries/StateLibrary.sol";
import {FullMath}        from "v4-core/libraries/FullMath.sol";
import {TickMath}        from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

// Chainlink Automation (Phase 1+2 — council-ratified 2026-05-12)
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

// ═══════════════════════════════════════════════════════════════════════════
//                          EXTERNAL INTERFACES
// ═══════════════════════════════════════════════════════════════════════════

// v3 — IV3SwapRouter interface removed (DAI swap leg gone; treasury serves as reserve).

interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    );
    /// @notice v2.5 — added for constructor decimal-class validation.
    ///         cbETH/ETH is 18-decimal (exchange-rate class);
    ///         DAI/ETH is 8-decimal (price-feed class).
    function decimals() external view returns (uint8);
}

/// @notice cbETH on Base is an OptimismMintableERC20 bridge token with NO
///         user-callable deposit() or withdraw() functions. v2.4 attempted
///         to call cbETH.deposit{value:} and cbETH.withdraw(); both reverted
///         silently into try/catch branches (terminal-verified 2026-05-23).
///         v2.5 acquires cbETH via Aerodrome Slipstream swap (see
///         IAerodromeSlipstreamRouter below) and holds it for principal +
///         rewards accounting. Only balanceOf is consumed in v2.5.
interface IcbETH {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Aerodrome Slipstream Router on Base. Used for the WETH↔cbETH
///         swap legs that replace the broken cbETH.deposit/withdraw paths.
///         Aerodrome Slipstream uses int24 tickSpacing as the pool tier
///         discriminator (Uniswap V3 uses uint24 fee).
    /// @dev    v2.6.3 — Router address and exactInputSingle selector CONFIRMED
    ///         against Base mainnet via terminal `cast code` / `cast call`
    ///         (Architect-confirmed). The prior PROVISIONAL Phase 2 gap is
    ///         closed; the cbETH/WETH pool active liquidity (8.687e24) was
    ///         likewise cast-verified at deploy-venue selection.
interface IAerodromeSlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24   tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}


// ═══════════════════════════════════════════════════════════════════════════
//                              STEEL TOKEN
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @title STEEL
 * @notice Clean ERC20 token for POSSESSIO Protocol v2.
 *         Name: "PLATE". Symbol: "STEEL".
 *         Total supply: 1,000,000,000 minted to deployer.
 *         No custom transfer logic. No fee-on-transfer. No exclusion mapping.
 *         All protocol fee logic lives in PossessioHook.
 *
 * @dev Ownable2Step enables safe ownership transfer to the Treasury Safe.
 *      Permit support for gasless approvals.
 */
contract STEEL is ERC20, ERC20Permit, Ownable2Step {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;

    constructor(address deployer)
        ERC20("PLATE", "STEEL")
        ERC20Permit("PLATE")
        Ownable(deployer)
    {
        _mint(deployer, TOTAL_SUPPLY);
    }
}


// ═══════════════════════════════════════════════════════════════════════════
//                          POSSESSIO HOOK
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @title PossessioHook
 * @notice Uniswap V4 hook for POSSESSIO Protocol v2.
 *         Captures 2% ETH fee on every STEEL/WETH swap.
 *         Routes 25% to LP, 75% to Treasury operations.
 *         Houses council SAV allocation (3% of STEEL supply).
 *
 *                          DEPLOYMENT REQUIREMENTS
 *
 * CRITICAL - HOOK ADDRESS BITS MUST ENCODE PERMISSIONS
 *
 * Uniswap V4 determines which hook callbacks are invoked by inspecting the
 * LAST 14 BITS of the hook contract's address, NOT by calling any interface
 * method. If the address bits don't match the implemented functions, the
 * PoolManager silently skips hook callbacks and fees are never captured.
 *
 * Required address flags for this hook:
 *   BEFORE_ADD_LIQUIDITY_FLAG       (1 << 11)  = 0x0800
 *   BEFORE_SWAP_FLAG                (1 << 7)   = 0x0080
 *   AFTER_SWAP_FLAG                 (1 << 6)   = 0x0040
 *   BEFORE_SWAP_RETURNS_DELTA_FLAG  (1 << 3)   = 0x0008
 *
 * Combined mask: 0x08C8
 *
 * Deploy via CREATE2 with salt-mining (e.g. v4-periphery HookMiner) until
 * the resulting address satisfies:
 *     uint160(deployedAddress) & 0x3FFF == 0x08C8
 *
 * Verify post-deploy:
 *     cast call HOOK_ADDR "getHookPermissions()(bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)"
 *     Match flags against actual address bits.
 */
contract PossessioHook is IUnlockCallback, ReentrancyGuard, Ownable2Step, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using SafeCast  for uint256;
    using SafeCast  for int256;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    // Fee configuration
    uint256 public constant FEE_BPS       = 200;     // 2%
    uint256 public constant FEE_DENOM     = 10_000;

    // Routing splits (matching v1)
    uint256 public constant LP_PCT        = 25;      // 25% ETH → LP
    uint256 public constant TREASURY_PCT  = 75;      // 75% ETH → Treasury
    // v3 — DAI_BOOT_PCT removed: no reserve carve-out (Payments owns the reserve;
    // the hook routes the full treasury portion to cbETH staking).
    uint256 public constant CBETH_PCT     = 100;     // 100% of staking allocation → cbETH

    // Rewards harvest splits (matching v1)
    uint256 public constant REWARDS_TO_LP = 25;
    uint256 public constant REWARDS_TO_T  = 75;

    // v3 — DAI_TARGET removed (no DAI reserve; treasury holds ETH directly).

    // Governance
    uint256 public constant TIMELOCK      = 48 hours;

    // Depeg guard — 18-decimal precision (v2.5: matches Chainlink cbETH/ETH
    // exchange-rate feed's native decimals. v2.4 used 8-decimal 97_000_000
    // which would atomic-revert against an 18-decimal feed answer.)
    int256  internal constant DEPEG_THRESH  = 970_000_000_000_000_000; // 0.97e18 — 3% depeg

    // Slippage tolerance
    uint256 internal constant SLIPPAGE      = 90; // 90% of expected

    // Routing auto-trigger
    uint256 public constant ROUTE_THRESHOLD = 0.05 ether;
    uint256 public constant ROUTE_COOLDOWN  = 6 hours;

    // ─── Chainlink Automation constants (council IV.1, IV.4 — ratified 2026-05-12) ───

    /// @notice IV.1 — minimum harvestable excess before harvest triggers.
    ///         Prevents gas-burn loops on rounding dust.
    ///         C-1 fix (audit 2026-07-14): the floor is ETH-DENOMINATED — it gates
    ///         the exchange-rate-appreciation excess (currentValueETH −
    ///         cbETHPrincipalETH), not a cbETH balance delta (which can never occur
    ///         on non-rebasing cbETH). It is enforced by BOTH checkUpkeep and
    ///         _harvestRewards so the value-based rounding residue each harvest
    ///         leaves behind (≲ a few wei) can never re-arm the upkeep or trigger a
    ///         dust-sized swap.
    uint256 public constant HARVEST_DUST_FLOOR = 0.001 ether;

    /// @notice IV.4 — multiplier for checkUpkeep hysteresis buffer (basis 100).
    ///         Upkeep only triggers when accumulated value ≥ canonical threshold × 120/100.
    ///         The contract's own routeETH/harvestRewards still accept the canonical threshold;
    ///         this buffer applies only to Automation's decision to act.
    uint256 public constant UPKEEP_HYSTERESIS_BPS = 120; // 20% over canonical threshold

    // SAV constants
    uint256 internal constant INVENT_EXPIRY    = 30 days;
    uint8   internal constant INVENT_THRESHOLD = 3;

    // v3 — DAI_V3_FEE removed (no V3 DAI swap).

    // ─── Aerodrome Slipstream cbETH venue (v2.5 — terminal-grounded 2026-05-23) ───

    /// @notice Aerodrome Slipstream cbETH/WETH pool on Base mainnet, stable tier.
    ///         Cast-verified active liquidity 8.687e24 (4.3M× the V3 cliff).
    ///         token0 = cbETH (0x2Ae3F1Ec…dEc22), token1 = WETH (0x4200…0006).
    address public constant AERODROME_CBETH_WETH_POOL =
        0x47cA96Ea59C13F72745928887f84C9F52C3D7348;

    /// @notice TickSpacing for the Aerodrome Slipstream cbETH/WETH pool.
    int24   internal constant CBETH_TICK_SPACING = 1;

    /// @notice Staleness window for Chainlink cbETH/ETH 18-decimal exchange-rate feed.
    ///         Feed publishes on a 24-hour heartbeat + 0.5% deviation threshold.
    ///         v2.4's 3600s window would falsely flag valid data as stale during
    ///         low-volatility periods. 90,000s = 86,400 heartbeat + 3,600 slack.
    uint256 internal constant ORACLE_STALE_CBETH = 90_000;

    /// @notice Staleness window for the 8-decimal USD feeds (DAI/USD, ETH/USD).
    ///         Both publish on a heartbeat + deviation threshold (not per-block),
    ///         so the window must accommodate the heartbeat: 90,000s = 86,400
    ///         (24h heartbeat) + 3,600 slack. A tight window would false-revert
    ///         the slippage floor whenever a feed is simply between updates.
    ///         (Was 3,600 for the now-dead DAI/ETH feed; relaxed for the
    ///         DAI/USD + ETH/USD cross-rate that replaces it.)
    uint256 internal constant ORACLE_STALE_8DEC = 90_000;

    // Dead address for burns
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // V4 hook permission flags (from Hooks.sol)
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG       = 1 << 11;
    uint160 internal constant BEFORE_SWAP_FLAG                = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG                 = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG  = 1 << 3;

    // ═══════════════════════════════════════════════════════════════════════
    //                              IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════

    IERC20            public immutable STEEL_TOKEN;
    IPoolManager      public immutable POOL_MANAGER;
    address           public immutable TREASURY_SAFE;

    IcbETH             public immutable cbETH;

    IChainlinkFeed     public immutable CHAINLINK_CBETH_ETH;  // cbETH depeg feed

    // v3 — DAI leg removed (treasury serves as reserve). DAI token, both USD
    // cross-rate feeds, and the V3 router are gone. WETH stays: the cbETH leg
    // wraps/unwraps it for the Aerodrome swap.
    IAerodromeSlipstreamRouter public immutable AERO_ROUTER; // v2.5 — cbETH leg
    IWETH              public immutable WETH;       // Base WETH9 for cbETH leg wrap/unwrap

    // Council addresses (immutable per SAV design)
    address public immutable COUNCIL_0; // Gemini
    address public immutable COUNCIL_1; // ChatGPT
    address public immutable COUNCIL_2; // Claude
    address public immutable COUNCIL_3; // Grok

    // ═══════════════════════════════════════════════════════════════════════
    //                                STATE
    // ═══════════════════════════════════════════════════════════════════════

    // Pool configuration (set after pool initialization)
    PoolKey public poolKey;
    bool    public poolInitialized;

    // Fee capture state
    uint256 public accumulatedETH;      // ETH captured from fees, pending routeETH
    uint256 public lastRouteTime;

    // Treasury state
    // v3 — daiReserve removed; the ETH reserve slice stays in-contract (no DAI).

    /// @notice Cumulative cbETH-wei acquired by _deployToStaking.
    ///         C-1 fix (audit 2026-07-14): this is now a pure ACQUISITION RECORD
    ///         (console/monitoring surface) and is no longer consumed by harvest
    ///         math. cbETH is non-rebasing, so the v2.5 "balance minus principal"
    ///         comparison (both in cbETH-wei) was identically zero and the harvest
    ///         path was dead. After harvests the live cbETH balance may drop below
    ///         this record — harvest sells the appreciation excess — which is
    ///         expected, not principal loss; the ETH-value baseline lives in
    ///         cbETHPrincipalETH below.
    uint256 public cbETHPrincipal;

    /// @notice C-1 fix (audit 2026-07-14) — cumulative ETH-wei consumed to acquire
    ///         the cbETH treasury, recorded at acquisition time. THE harvest
    ///         baseline: the cbETH holding is valued via the Chainlink cbETH/ETH
    ///         exchange-rate feed and only the value in excess of this principal is
    ///         harvestable. Constant across harvests; grows only when routeETH
    ///         deploys to staking. (Supersedes the v2.5 "semantic shift" that moved
    ///         principal accounting to cbETH-wei — that shift is what killed the
    ///         harvest path on a non-rebasing token.)
    uint256 public cbETHPrincipalETH;

    // Circuit breaker
    bool public routingPaused;
    bool public cbETHPaused;

    // Timelock (reused pattern from v1)
    mapping(bytes32 => uint256) public timelockQueue;

    // SAV state
    mapping(address => uint256) public claimable;
    bool public savPaused;
    bool public slashed;

    // ─── Chainlink Automation state (council IV.3, IV.7, IV.8, IV.9 — ratified 2026-05-12) ───

    /// @notice Chainlink Automation Forwarder address. Only this address may call performUpkeep.
    ///         Initially address(0); set by owner once at registration time via setForwarder.
    ///         Updatable thereafter only via Treasury 48h timelock (queueForwarderUpdate + executeForwarderUpdate).
    address public automationForwarder;

    /// @notice Pending forwarder update queued via 48h timelock (IV.8).
    address private _pendingForwarder;

    /// @notice Chainlink Automation Upkeep ID. Set after registration, exposed for console reads.
    uint256 public upkeepID;

    /// @notice IV.7 Position B — cheap pause flag for upkeep, independent of routingPaused.
    ///         When true, checkUpkeep returns false immediately, avoiding gas waste on
    ///         high-frequency upkeep evaluations even while routing is operational.
    bool public upkeepPaused;

    /// @notice IV.9 — replay protection. Defense-in-depth: routeETH's 6h cooldown and
    ///         harvestRewards's ZeroAmount revert do the load-bearing work against
    ///         cross-block retries. The replay map adds same-block re-execution
    ///         protection and a stable audit trail.
    mapping(bytes32 => bool) public executedUpkeeps;

    /// @notice Monotonic counter of automated executions. Exposed for console dashboard.
    uint256 public executedUpkeepCount;

    // ─── X-LINK state (council-ratified 2026-05-16) ───
    // Monotonic nonce + one-time-use execution secret. Authorized entrypoints
    // (routeETH, harvestRewards, performUpkeep) mint a secret and arm
    // _activeExecutionSecret immediately before calling the internal execution
    // cores (_routeETH, _harvestRewards). The cores verify and consume the
    // secret as their first action. Proves the core was reached through a
    // sanctioned branch without relying on msg.sender semantics inside the
    // internal call — works identically for direct callers and the forwarder
    // path. Same mechanism as SCH on PossessioPayments_v2-2; X-LINK is the
    // general primitive (named by Gemini, applied across contracts).
    uint256 private _executionNonce;
    uint256 private _activeExecutionSecret;

    /// @notice Task discriminator for multi-task upkeep (Gemini-ratified pattern).
    ///         Encoded in performData; decoded in performUpkeep.
    enum UpkeepTask { ROUTE_ETH, HARVEST_REWARDS }

    struct Proposal {
        uint8   approvals;
        uint256 expiry;
        bool    executed;
        mapping(address => bool) hasApproved;
    }
    mapping(bytes32 => Proposal) public proposals;

    // ═══════════════════════════════════════════════════════════════════════
    //                       UNLOCK CALLBACK TYPES
    // ═══════════════════════════════════════════════════════════════════════

    enum Action { SEED_GENESIS, ADD_RECURRING }

    struct CallbackData {
        Action  action;
        uint256 amount0;   // ETH amount
        uint256 amount1;   // STEEL amount (0 for ADD_RECURRING)
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    // Fee / routing events

    /// @notice Emitted on every fee capture in beforeSwap.
    /// @param  swapper C-5 fix (audit 2026-07-14): the `sender` PoolManager hands to
    ///         beforeSwap — i.e. the router/periphery contract (or direct caller)
    ///         that invoked PoolManager.swap. Previously tx.origin, which
    ///         misattributed router-mediated swaps to the transaction originator.
    event FeeCaptured(address indexed swapper, uint256 ethAmount, uint256 accumulated, uint256 timestamp);
    event ETHRouted(uint256 total, uint256 toLP, uint256 toDAI, uint256 toStaking, uint256 timestamp);
    event LiquidityAdded(uint256 ethIn, uint256 steelIn, uint256 timestamp);
    event LPFailed(uint256 ethAmt, uint8 reasonCode);
    // v3 — DAIReserveFunded / DAIReserveFull events removed (no DAI leg).
    event StakingDeployed(uint256 cbETH, uint256 timestamp);

    /// @notice v2.6 — Emitted when _deployToStaking does NOT deploy cbETH for
    ///         a stated reason. Replaces the semantic overload of StakingDeployed(0).
    ///         Reason codes:
    ///           1 = depeg-pause (cbETHPaused == true → raw ETH to Treasury)
    ///           2 = oracle-invalid (Chainlink stale / round incomplete)
    ///           3 = WETH wrap failed (impossible on canonical WETH9, paranoid path)
    ///           4 = Aerodrome swap failed, WETH unwrap succeeded (ETH in accumulator)
    ///           5 = Aerodrome swap failed, WETH unwrap also failed (stuck WETH)
    event StakingRetained(uint256 ethAmt, uint8 reasonCode, uint256 timestamp);

    event RewardsHarvested(uint256 total, uint256 toLP, uint256 toTreasury, uint256 timestamp);

    // Circuit / governance events
    event CircuitBreakerOn(uint256 timestamp);
    event CircuitBreakerOff(uint256 timestamp);
    event CbETHPaused(uint256 depegPct, uint256 timestamp);
    event CbETHResumed(uint256 timestamp);
    event ParameterQueued(bytes32 indexed id, string param, uint256 executeAfter);

    // SAV events
    event SAVDeposit(uint256 amount, uint256 share, uint256 remainder);
    event CouncilBurn(address indexed member, uint256 amount);
    event InventProposed(bytes32 indexed proposalHash, address indexed proposer, uint256 expiry);
    event InventApproved(bytes32 indexed proposalHash, address indexed approver, uint8 approvals);
    event InventExecuted(bytes32 indexed proposalHash, uint256 amount, bytes metadata);
    event SAVPaused(address indexed by);
    event SAVUnpaused(address indexed by);
    event Slashed(uint256 totalBurned);

    // Pool lifecycle
    event PoolRegistered(PoolKey key, uint256 timestamp);

    // Rescue
    event TokenRescued(address indexed token, uint256 amount, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════
    //                               ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error OnlyPoolManager();
    error OnlyTreasury();
    error OnlyCouncilMember();
    error RoutingPaused();
    error SAVPausedError();
    error Slashed_();
    error InvalidAddress();
    error ZeroAmount();
    error ZeroOutput();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error RouteTooEarly();
    error BelowThreshold();
    error OracleStale();
    error OracleInvalid();
    error LeakageDetected();          // v2.5 — defense-in-depth on swap legs
    error TimelockPending();
    error NotQueued();
    error ProposalNotFound();
    error ProposalExpired();
    error ProposalAlreadyExecuted();
    error ProposalStillActive();
    error AlreadyApproved();
    error ThresholdNotMet();
    error ExceedsClaimable();
    error InsufficientClaimable();
    error NothingToSlash();
    error ExternalLiquidityDenied();
    error MismatchedETH();
    error RescueBlocked();

    // ─── Chainlink Automation errors (council-ratified 2026-05-12) ───
    error NotForwarder();              // performUpkeep called by non-forwarder
    error ForwarderNotSet();           // performUpkeep called before setForwarder
    error ForwarderAlreadySet();       // setForwarder called twice (use queue/execute path)
    error InvalidTask();               // performData decoded to unknown task
    error UpkeepAlreadyExecuted();     // replay map hit
    error UpkeepIsPaused();            // performUpkeep called while upkeepPaused

    // ─── X-LINK error (council-ratified 2026-05-16) ───
    //  X-LINK (Cross-Context Execution Link) is the handshake primitive ratified
    //  for the integration-boundary deadlock class. Same mechanism as SCH on
    //  PossessioPayments_v2-2; named by Gemini (Technical Authority) when applied
    //  as the general primitive across multiple contracts. Reverts when an
    //  internal execution core is reached without a matching armed secret from
    //  a sanctioned entrypoint.
    error CrossLinkHandshakeFailed();

    // ═══════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    // ─── Chainlink Automation events (council-ratified 2026-05-12) ───

    /// @notice Grok-ratified consolidated event for all automated executions.
    /// @param task        Discriminator: 0 = ROUTE_ETH, 1 = HARVEST_REWARDS.
    /// @param gasUsed     Gas consumed by the inner call. Approximate.
    /// @param valueMoved  Task-specific value: ETH wei routed for ROUTE_ETH, cbETH wei withdrawn for HARVEST_REWARDS.
    event UpkeepPerformed(uint8 indexed task, uint256 gasUsed, uint256 valueMoved);
    event AutomationForwarderSet(address forwarder, uint256 timestamp);
    event ForwarderUpdateQueued(bytes32 indexed id, address newForwarder, uint256 executeAfter);
    event ForwarderUpdated(address oldForwarder, address newForwarder, uint256 timestamp);
    event UpkeepRegistered(uint256 upkeepID, uint256 timestamp);
    event UpkeepPausedSet(bool paused, uint256 timestamp);

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != TREASURY_SAFE) revert OnlyTreasury();
        _;
    }

    modifier onlyCouncilMember() {
        if (!_isCouncilMember(msg.sender)) revert OnlyCouncilMember();
        _;
    }

    modifier notPaused() {
        if (routingPaused) revert RoutingPaused();
        _;
    }

    modifier savNotPaused() {
        if (savPaused) revert SAVPausedError();
        _;
    }

    modifier notSlashed() {
        if (slashed) revert Slashed_();
        _;
    }

    modifier tlPassed(bytes32 id) {
        if (timelockQueue[id] == 0) revert NotQueued();
        // Timelock comparison is multi-hour scale; validator's ~12s manipulation window is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < timelockQueue[id]) revert TimelockPending();
        delete timelockQueue[id];
        _;
    }

    /// @notice IV.3 — gates performUpkeep to the Chainlink Automation Forwarder.
    modifier onlyForwarder() {
        if (automationForwarder == address(0)) revert ForwarderNotSet();
        if (msg.sender != automationForwarder) revert NotForwarder();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                             CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    struct DeployParams {
        address deployer;           // initial owner (Farcaster wallet)
        address steel;              // STEEL token address
        address poolManager;        // Uniswap V4 PoolManager
        address treasury;           // Treasury Safe (new)
        address cbETH_;
        address chainlinkCbETH;
        // v3 — dai, chainlinkDaiUsd, chainlinkEthUsd, v3Router removed (DAI leg gone).
        address aeroRouter;         // v2.5 — Aerodrome Slipstream Router
        address weth;
        address[4] council;
    }

    constructor(DeployParams memory p) Ownable(p.deployer) {
        if (p.steel          == address(0)) revert InvalidAddress();
        if (p.poolManager    == address(0)) revert InvalidAddress();
        if (p.treasury       == address(0)) revert InvalidAddress();
        if (p.cbETH_         == address(0)) revert InvalidAddress();
        if (p.chainlinkCbETH == address(0)) revert InvalidAddress();
        if (p.aeroRouter     == address(0)) revert InvalidAddress();
        if (p.weth           == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < 4; i++) {
            if (p.council[i] == address(0)) revert InvalidAddress();
        }

        // ─── v2.5 — Decimal validation (defense-in-depth) ────────────────
        // cbETH/ETH must be the 18-decimal exchange-rate feed. (v3 — the 8-dec
        // DAI/USD + ETH/USD cross-rate feeds are gone with the DAI leg.)
        if (IChainlinkFeed(p.chainlinkCbETH).decimals()  != 18) revert InvalidAddress();

        STEEL_TOKEN          = IERC20(p.steel);
        POOL_MANAGER         = IPoolManager(p.poolManager);
        TREASURY_SAFE        = p.treasury;
        cbETH                = IcbETH(p.cbETH_);
        CHAINLINK_CBETH_ETH  = IChainlinkFeed(p.chainlinkCbETH);
        AERO_ROUTER          = IAerodromeSlipstreamRouter(p.aeroRouter);
        WETH                 = IWETH(p.weth);

        COUNCIL_0 = p.council[0];
        COUNCIL_1 = p.council[1];
        COUNCIL_2 = p.council[2];
        COUNCIL_3 = p.council[3];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    HOOK PERMISSIONS & LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice V4 PoolManager inspects hook's address bits to determine permissions.
     *         This function is informational — real enforcement is via address bits.
     */
    // Return tuple positions match V4 Hooks.Permissions field order:
    //   0:  beforeInitialize                  1:  afterInitialize
    //   2:  beforeAddLiquidity                3:  afterAddLiquidity
    //   4:  beforeRemoveLiquidity             5:  afterRemoveLiquidity
    //   6:  beforeSwap                        7:  afterSwap
    //   8:  beforeDonate                      9:  afterDonate
    //   10: beforeSwapReturnDelta             11: afterSwapReturnDelta
    //   12: afterAddLiquidityReturnDelta      13: afterRemoveLiquidityReturnDelta
    // Names are intentionally omitted here to avoid shadowing the hook function
    // identifiers of the same name defined elsewhere in this contract.
    function getHookPermissions() external pure returns (
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool
    ) {
        return (
            false, false,
            true,  false,   // beforeAddLiquidity only (POL gate)
            false, false,
            true,  true,    // beforeSwap + afterSwap
            false, false,
            true,  false,   // beforeSwapReturnDelta (fee capture)
            false, false
        );
    }

    /**
     * @notice Register the V4 pool after initialization.
     *         Called once by owner after PoolManager.initialize.
     */
    function registerPool(PoolKey calldata key) external onlyOwner {
        if (poolInitialized) revert PoolAlreadyRegistered();
        if (address(key.hooks) != address(this)) revert InvalidAddress();
        poolKey = key;
        poolInitialized = true;
        emit PoolRegistered(key, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          HOOK: beforeAddLiquidity
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice POL gate — only this hook contract can add liquidity to the pool.
     *         External LPers are rejected. Protocol owns 100% of LP.
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert ExternalLiquidityDenied();
        return this.beforeAddLiquidity.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          HOOK: beforeSwap
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Fee capture — 2% of ETH-equivalent swap, captured directly into hook.
     *         Uses the Balanced Delta pattern: return positive BeforeSwapDelta AND
     *         call take(). The two entries cancel in PoolManager's accounting
     *         (net delta = 0, unlock invariant satisfied), while physically moving
     *         ETH into the hook's contract balance.
     *
     * @dev Reads current `sqrtPriceX96` from pool state to convert STEEL-denominated
     *      swap amounts into ETH-equivalent before computing 2%. Fee always lands
     *      in ETH (currency0 / native), never in STEEL.
     *
     *      Anti-poisoning: only fees captured here increment `accumulatedETH`.
     *      Raw ETH sent to the contract via `receive()` is ignored for accounting.
     *
     *      NOT gated by `notPaused`: swap trading continues even when routing is
     *      paused. Fees accumulate safely; only treasury routing is halted.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (!poolInitialized) revert PoolNotRegistered();

        // Fetch current price for STEEL→ETH conversion when needed
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(POOL_MANAGER, PoolIdLibrary.toId(key));

        uint256 absSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Specified currency IS ETH when:
        //   zeroForOne && exactIn    (ETH→STEEL, spending ETH)
        //   !zeroForOne && exactOut  (STEEL→ETH, receiving ETH)
        bool isETHSpecified = (params.zeroForOne  && params.amountSpecified < 0) ||
                              (!params.zeroForOne && params.amountSpecified > 0);

        uint256 feeETH;
        if (isETHSpecified) {
            feeETH = (absSpecified * FEE_BPS) / FEE_DENOM;
        } else {
            // Specified is STEEL — convert to ETH equivalent.
            //   price = sqrtPriceX96^2 / 2^192 , ethEquivalent = steelAmount * price
            //
            // M-1 fix (audit 2026-06): the square sqrtPriceX96^2 must NOT be formed
            // as a bare uint256 multiply — sqrtPriceX96 can reach ~2^160 (MAX_SQRT_RATIO),
            // so sqrtPriceX96^2 exceeds 2^256 once sqrtPriceX96 > 2^128 and Solidity 0.8
            // checked arithmetic reverts, bricking every STEEL-specified swap on that
            // branch. Stage the squaring through FullMath's 512-bit intermediate instead:
            //   priceX96      = mulDiv(sqrtP, sqrtP, 2^96)         // sqrtP^2 / 2^96  (Q96)
            //   ethEquivalent = mulDiv(absSpecified, priceX96, 2^96)
            // which equals absSpecified * sqrtP^2 / 2^192 exactly, with no intermediate
            // ever exceeding 2^256.
            uint256 priceX96 = FullMath.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtPriceX96),
                1 << 96
            );
            uint256 ethEquivalent = FullMath.mulDiv(
                absSpecified,
                priceX96,
                1 << 96
            );
            feeETH = (ethEquivalent * FEE_BPS) / FEE_DENOM;
        }

        if (feeETH == 0) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0));
        }

        // Balanced Delta pattern:
        //   1. take() physically moves feeETH to hook (creates -feeETH delta for hook)
        //   2. positive BeforeSwapDelta returns +feeETH delta (cancels the take's debit)
        //   Net delta = 0, unlock invariant holds, ETH resides in hook.
        POOL_MANAGER.take(Currency.wrap(address(0)), address(this), feeETH);
        accumulatedETH += feeETH;

        // Delta packing: fee lands in ETH slot regardless of which side was specified
        // SafeCast: feeETH (uint256) → int256 → int128. Reverts on overflow rather than
        // silently truncating. Realistic feeETH ≪ 2^127, but explicit guard for audit.
        BeforeSwapDelta delta;
        if (isETHSpecified) {
            // ETH is the specified currency — put positive delta on specified side
            delta = toBeforeSwapDelta(feeETH.toInt256().toInt128(), int128(0));
        } else {
            // ETH is the unspecified currency — put positive delta on unspecified side
            delta = toBeforeSwapDelta(int128(0), feeETH.toInt256().toInt128());
        }

        // C-5 fix (audit 2026-07-14): attribute the capture to the swap initiator
        // PoolManager actually hands us (the router/caller), not tx.origin.
        emit FeeCaptured(sender, feeETH, accumulatedETH, block.timestamp);
        return (this.beforeSwap.selector, delta, uint24(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           HOOK: afterSwap
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice No-op afterSwap. Fee capture and event emission both happen in
     *         beforeSwap via the Balanced Delta pattern. AfterSwap is registered
     *         in hook permissions but currently performs no logic.
     *
     *         Retained as a permission placeholder for future logic extensions.
     */
    function afterSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) external view onlyPoolManager returns (bytes4, int128) {
        return (this.afterSwap.selector, int128(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      TREASURY ROUTING (routeETH)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Distribute accumulated ETH per v1 splits.
     *         Callable outside unlock context — by Treasury Safe or permissionless
     *         with reward when threshold + cooldown conditions met.
     *
     *         25% → LP injection (via unlock dance)
     *         75% → Treasury ops:
     *           20% of 75% → DAI until reserve ≥ DAI_TARGET
     *           Remainder  → cbETH (100% of staking allocation, rewards-accruing)
     */
    function routeETH() external nonReentrant notPaused {
        // Access gate: Treasury always; permissionless only after threshold + cooldown.
        // Automation path (performUpkeep) bypasses this wrapper and calls _routeETH
        // directly with its own auth (onlyForwarder + replay protection).
        bool isTreasury = msg.sender == TREASURY_SAFE;
        if (!isTreasury) {
            if (accumulatedETH < ROUTE_THRESHOLD) revert BelowThreshold();
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < lastRouteTime + ROUTE_COOLDOWN) revert RouteTooEarly();
        }

        // --- v2.6.3 direct dispatch (X-LINK self-heals on revert) ---------
        // Reverted from the v2.6 try/catch wrapper. The X-LINK consume-immediately
        // discipline plus EVM revert atomicity guarantee no stale armed secret
        // survives a revert (invariant_XLinkAlwaysConsumed). Slippage is computed
        // at execution time inside _routeETH, not carried through performData.
        uint256 secret = ++_executionNonce;
        _activeExecutionSecret = secret;

        _routeETH(secret);
    }

    function _routeETH(uint256 secret) internal {
        // --- X-LINK handshake verification --------------------------------
        // Consume immediately, before any state read or external interaction,
        // so the secret cannot be reused and no revert path can leave it armed.
        if (secret == 0 || secret != _activeExecutionSecret) {
            revert CrossLinkHandshakeFailed();
        }
        _activeExecutionSecret = 0;

        uint256 total = accumulatedETH;
        if (total == 0) revert ZeroAmount();

        // --- C-4 fix (audit 2026-07-14): carve the caller reward out FIRST ---
        // The reward used to be paid from address(this).balance AFTER routing
        // had spent the entire accumulator, so the balance guard failed in
        // production (it only "worked" in tests that dealt surplus ETH) and the
        // reward silently skipped. Carving 0.1% out of `total` before the split
        // guarantees the ETH is still in the contract when the reward is paid.
        // Exemptions unchanged: Treasury, the automation forwarder (paid in
        // LINK), and address(this) (defense-in-depth, never the predicate
        // here). v2.6.3 uses msg.sender directly: with direct dispatch there is
        // no address(this) context shift, so msg.sender is the real caller and
        // the v2.6.2 reward-skip regression cannot occur.
        bool rewardEligible = msg.sender != TREASURY_SAFE
            && msg.sender != automationForwarder
            && msg.sender != address(this);
        uint256 reward   = rewardEligible ? total / 1000 : 0; // 0.1% of routed
        uint256 routable = total - reward;

        // --- v3 slippage computed here at execution time -----------------
        // Only the cbETH leg needs a slippage guard now (DAI leg removed).
        // C-4: guard sized from `routable` — the amount that actually routes.
        (uint256 minCbETH, ) = _computeRouteSlippageGuards(routable);

        // Compute allocations upfront (matching v1 safety pattern)
        // v3 — DAI leg removed. Treasury serves as the reserve directly: the
        // 20%-of-75% that formerly swapped ETH→DAI now simply STAYS as ETH in
        // the contract (Treasury Safe withdraws it as needed). Staking keeps its
        // original 80%-of-75% proportion — the freed slice does NOT flow to it.
        uint256 toLP       = (routable * LP_PCT) / 100;
        uint256 toTreasury = routable - toLP;
        // v3 — full treasury portion routes to cbETH staking. No in-contract
        // carve-out: the reserve function lives in PossessioPayments (the base
        // contract owns the DAI reserve), so the hook deduplicates it and holds
        // nothing back. Holding ETH here with no withdraw path would be trapped
        // ETH, not a reserve — so it routes in full.
        uint256 toStaking  = toTreasury;

        // Zero accumulator before external calls (CEI)
        accumulatedETH = 0;
        lastRouteTime  = block.timestamp;

        if (toLP > 0) {
            _addLiquidity(toLP);
        }
        if (toStaking > 0) {
            _deployToStaking(toStaking, minCbETH);
        }

        // ETHRouted: toDAI always 0 (DAI leg cut); full treasury portion routes
        // to staking (no in-contract reserve — Payments holds the reserve).
        // `total` keeps its historical meaning (full accumulator drained);
        // C-4: toLP + toStaking = total - reward.
        emit ETHRouted(total, toLP, 0, toStaking, block.timestamp);

        // Permissionless caller reward — paid LAST (CEI preserved: all state
        // writes happened above; this is the final external interaction). C-4:
        // the balance check is now belt-and-suspenders — the reward was carved
        // out of `total` before the split, so absent an LP/staking anomaly the
        // ETH is guaranteed present even when contract balance exactly equals
        // the accumulator (the production condition). Best-effort send: a
        // reverting caller forfeits the reward (stays as untracked surplus).
        if (reward > 0 && address(this).balance >= reward) {
            (bool ok,) = msg.sender.call{value: reward}("");
            if (!ok) { /* swallow - reward is best-effort */ }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    LP LIFECYCLE (genesis + recurring)
    // ═══════════════════════════════════════════════════════════════════════

    // Full-range tick bounds for tickSpacing = 200
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER =  887_200;

    /**
     * @notice ONE-TIME initial liquidity seed.
     *         Pairs the deployer's ETH + STEEL as a full-range POL position.
     *         Must be called after `registerPool` and before any swap activity.
     *
     *         Caller (Base app wallet at deploy) must:
     *           · Pre-approve `steelAmount` of STEEL to this hook
     *           · Send `ethAmount` as msg.value
     */
    function seedInitialLiquidity(uint256 ethAmount, uint256 steelAmount)
        external payable onlyOwner
    {
        if (msg.value != ethAmount) revert MismatchedETH();
        if (!poolInitialized) revert PoolNotRegistered();

        // Pull STEEL seed from caller
        STEEL_TOKEN.safeTransferFrom(msg.sender, address(this), steelAmount);

        bytes memory data = abi.encode(CallbackData({
            action:  Action.SEED_GENESIS,
            amount0: ethAmount,
            amount1: steelAmount
        }));

        POOL_MANAGER.unlock(data);
        emit LiquidityAdded(ethAmount, steelAmount, block.timestamp);
    }

    /**
     * @notice Recurring LP inflow from routeETH.
     *         Uses V4 `donate` to add ETH to the existing POL position without
     *         requiring a STEEL-side pairing. Because hook is sole LP, 100% of
     *         donation accrues to our own position as fee credit.
     */
    function _addLiquidity(uint256 ethAmount) internal {
        if (ethAmount == 0) return;

        bytes memory data = abi.encode(CallbackData({
            action:  Action.ADD_RECURRING,
            amount0: ethAmount,
            amount1: 0
        }));

        try POOL_MANAGER.unlock(data) {
            emit LiquidityAdded(ethAmount, 0, block.timestamp);
        } catch {
            // LP add failed — restore accumulator so next cycle retries
            accumulatedETH += ethAmount;
            emit LPFailed(ethAmount, 4);
        }
    }

    /**
     * @notice V4 unlock callback — PoolManager calls this after `unlock()`.
     *         Dispatches to SEED_GENESIS (modifyLiquidity) or ADD_RECURRING (donate).
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();

        CallbackData memory cb = abi.decode(data, (CallbackData));

        if (cb.action == Action.SEED_GENESIS) {
            // Read current price to compute correct liquidity delta for full-range mint
            (uint160 sqrtPriceCurrent, , , ) = StateLibrary.getSlot0(
                POOL_MANAGER,
                PoolIdLibrary.toId(poolKey)
            );

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceCurrent,
                TickMath.getSqrtPriceAtTick(TICK_LOWER),
                TickMath.getSqrtPriceAtTick(TICK_UPPER),
                cb.amount0,
                cb.amount1
            );
            int256 liquidityDelta = int256(uint256(liquidity));

            POOL_MANAGER.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower:      TICK_LOWER,
                    tickUpper:      TICK_UPPER,
                    liquidityDelta: liquidityDelta,
                    salt:           bytes32(0)
                }),
                ""
            );

            _settle(poolKey.currency0, cb.amount0);
            _settle(poolKey.currency1, cb.amount1);

        } else if (cb.action == Action.ADD_RECURRING) {
            // One-sided ETH donate — 100% accrues to hook's sole LP position
            POOL_MANAGER.donate(poolKey, cb.amount0, 0, "");
            _settle(poolKey.currency0, cb.amount0);
        }

        return "";
    }

    /**
     * @notice Pay out owed currency to PoolManager to zero the unlock delta.
     *         Native ETH uses settle{value:} directly. ERC20 follows the V4 protocol:
     *         sync → transfer → settle, so PoolManager can checkpoint the baseline
     *         balance and compute the correct delta from the fresh transfer.
     */
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == address(0)) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      STAKING DEPOSIT (internal)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy ETH to cbETH via Aerodrome Slipstream swap (v2.5).
     *         100% allocation to cbETH; rewards accrue passively via cbETH/ETH
     *         exchange rate appreciation.
     *
     *         v2.4 attempted cbETH.deposit{value:} which reverts on Base
     *         (cbETH on Base is OptimismMintableERC20, no payable deposit).
     *         v2.5 acquires cbETH by swap: WETH wrap → Aerodrome WETH→cbETH.
     *
     *         PRINCIPAL ACCOUNTING (C-1 fix, audit 2026-07-14): the v2.5
     *         "semantic shift" that tracked principal ONLY in cbETH-wei made
     *         harvest permanently dead — cbETH is non-rebasing, so the balance
     *         never exceeds a principal that mirrors it. Both records are now
     *         kept: cbETHPrincipal (cbETH-wei, acquisition record only) and
     *         cbETHPrincipalETH (ETH-wei consumed at acquisition — the harvest
     *         baseline). Harvest values the live balance via the cbETH/ETH
     *         oracle and swaps out only the value above cbETHPrincipalETH.
     *
     *         Failure modes (in order of precedence):
     *           1. ethAmt == 0 → no-op
     *           2. cbETH paused via depeg → raw ETH to Treasury
     *           3. Oracle invalid → retain ETH, no blind swap
     *           4. WETH wrap fails → retain ETH
     *           5. Aerodrome swap fails → unwrap WETH back to ETH, retain
     */
    function _deployToStaking(uint256 ethAmt, uint256 minCbETH) internal {
        if (ethAmt == 0) return;
        _checkDepeg();

        if (cbETHPaused) {
            // cbETH paused via depeg guard — forward raw ETH to Treasury.
            // Depeg-pause is operator-decided routing; intentionally bypasses
            // the routing-threshold retry cycle that transient failures use.
            (bool ok,) = TREASURY_SAFE.call{value: ethAmt}("");
            if (!ok) { accumulatedETH += ethAmt; }
            // v2.6 — reason-coded retention event (1 = depeg-pause).
            // v2.5 backwards-compat alias retained.
            emit StakingRetained(ethAmt, 1, block.timestamp);
            emit StakingDeployed(0, block.timestamp);
            return;
        }

        // v2.6.3 — slippage guard passed in from caller. checkUpkeep / external
        // wrapper computed it from the cbETH/ETH oracle at decision time.
        // Defensive retain on minCbETH == 0 (oracle invalid at decision time
        // should have caused the caller to skip us, but belt-and-suspenders).
        if (minCbETH == 0) {
            _retainForRetry(ethAmt);
            // v2.6 — reason-coded retention event (2 = oracle-invalid).
            emit StakingRetained(ethAmt, 2, block.timestamp);
            emit StakingDeployed(0, block.timestamp);
            return;
        }

        // ─── WETH wrap ──────────────────────────────────────────────────
        try WETH.deposit{value: ethAmt}() {
            WETH.approve(address(AERO_ROUTER), ethAmt);
        } catch {
            // WETH wrap failed — retain ETH for next routing cycle.
            _retainForRetry(ethAmt);
            // v2.6 — reason-coded retention event (3 = WETH-wrap-failed).
            emit StakingRetained(ethAmt, 3, block.timestamp);
            emit StakingDeployed(0, block.timestamp);
            return;
        }

        // ─── Aerodrome Slipstream swap WETH → cbETH ─────────────────────
        uint256 wethBefore = WETH.balanceOf(address(this));
        try AERO_ROUTER.exactInputSingle(
            IAerodromeSlipstreamRouter.ExactInputSingleParams({
                tokenIn:           address(WETH),
                tokenOut:          address(cbETH),
                tickSpacing:       CBETH_TICK_SPACING,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          ethAmt,
                amountOutMinimum:  minCbETH,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 cbReceived) {
            // Verify WETH actually consumed (defense-in-depth leakage check).
            // Net consumption must equal ethAmt; mismatch indicates router
            // misbehavior and is severe enough to revert the routing call.
            uint256 wethAfter = WETH.balanceOf(address(this));
            if ((wethBefore - wethAfter) != ethAmt) {
                WETH.approve(address(AERO_ROUTER), 0);
                revert LeakageDetected();
            }

            // C-1 fix (audit 2026-07-14) — dual principal accounting:
            //   cbETHPrincipal    (cbETH-wei) — acquisition record only.
            //   cbETHPrincipalETH (ETH-wei)   — harvest baseline: the ETH this
            //   deploy consumed, valued at acquisition. Harvest compares the
            //   oracle value of the live balance against this figure; a
            //   favorable fill (more cbETH than the oracle-fair amount) simply
            //   becomes harvestable excess on the next cycle.
            cbETHPrincipal    += cbReceived;
            cbETHPrincipalETH += ethAmt;

            // Reset approval — defense-in-depth
            WETH.approve(address(AERO_ROUTER), 0);
            emit StakingDeployed(cbReceived, block.timestamp);
        } catch {
            // Swap failed — reset approval, unwrap WETH back to ETH, retain
            // for next routing cycle (preserves routing-threshold semantic).
            // v2.6 — Helper returns true if unwrap succeeded (ETH in accumulator)
            // or false if WETH stuck. Reason codes 4 vs 5 distinguish.
            WETH.approve(address(AERO_ROUTER), 0);
            bool unwrapped = _unwrapAndRetain(ethAmt);
            emit StakingRetained(ethAmt, unwrapped ? uint8(4) : uint8(5), block.timestamp);
            emit StakingDeployed(0, block.timestamp);
        }
    }

    /// @dev Internal helper: retain ETH for next routing cycle.
    ///      Used by transient-failure branches (oracle, wrap) where the ETH
    ///      hasn't been wrapped yet and is held as native ETH on this contract.
    ///      Preserves routing-threshold semantic — accumulator-based retry
    ///      rather than Treasury-direct bypass.
    ///
    ///      v2.6 — emit removed from helper per Bugcatcher's Finding 4.1.
    ///      Callers emit StakingRetained with their own reason code so
    ///      indexers can distinguish oracle-invalid vs WETH-wrap-failed
    ///      branches.
    ///
    ///      ⚠️ TELEMETRY CONVENTION (v2.6.1 — Plate Finding 4):
    ///      Every caller of this helper MUST emit `StakingRetained(amt, code, ts)`
    ///      at the call site with the appropriate reason code. The helper
    ///      itself is silent — accumulator update only — so a new caller
    ///      that forgets the emit will produce a silent retention with no
    ///      indexer-visible signal. If you are adding a new failure branch
    ///      that calls _retainForRetry, allocate a fresh reason code (>= 6)
    ///      and emit it at the call site.
    function _retainForRetry(uint256 amt) internal {
        accumulatedETH += amt;
    }

    /// @dev Internal helper: unwrap WETH back to ETH and retain for next cycle.
    ///      Used by the swap-failure branch where WETH wrap succeeded but the
    ///      swap itself failed. WETH unwrap on canonical Base WETH should not
    ///      fail; if it does, the WETH stays in contract and operator visibility
    ///      emit fires for diagnostic. Principal is not updated either way.
    ///
    ///      v2.6 — returns bool: true if unwrap succeeded (ETH retained),
    ///      false if WETH stuck in contract. Caller emits the appropriate
    ///      reason code (4 = unwrap-success, 5 = unwrap-failed).
    function _unwrapAndRetain(uint256 amt) internal returns (bool unwrapped) {
        try WETH.withdraw(amt) {
            accumulatedETH += amt;
            unwrapped = true;
        } catch {
            // WETH unwrap failed — WETH stuck in contract. Visibility emit.
            // Operator can recover via emergency withdrawal path if needed.
            emit LPFailed(amt, 7);
            unwrapped = false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    REWARDS HARVEST (external)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Harvest cbETH staking rewards — principal stays staked.
     *         Only harvests VALUE above the tracked ETH principal (C-1 fix,
     *         audit 2026-07-14): cbETH is non-rebasing, so rewards exist only
     *         as cbETH/ETH exchange-rate appreciation. The live balance is
     *         valued via the Chainlink cbETH/ETH feed; the excess over
     *         cbETHPrincipalETH is converted back to cbETH-wei and swapped
     *         out. The ETH principal is untouched by harvests.
     *         25% → LP · 75% → Treasury.
     *
     *         If LP add fails, the rewards portion is redirected to Treasury
     *         rather than restored to the fee accumulator (would apply wrong
     *         splits on re-route).
     */
    function harvestRewards() external nonReentrant notPaused {
        // --- v2.6.3 direct dispatch (X-LINK self-heals on revert) ---------
        // Slippage computed at execution time inside _harvestRewards.
        uint256 secret = ++_executionNonce;
        _activeExecutionSecret = secret;

        _harvestRewards(secret);
    }

    function _harvestRewards(uint256 secret) internal {
        // --- X-LINK handshake verification --------------------------------
        // Verify and consume before any state read or external interaction.
        if (secret == 0 || secret != _activeExecutionSecret) {
            revert CrossLinkHandshakeFailed();
        }
        _activeExecutionSecret = 0;

        // --- Compute harvestable excess (C-1 fix: VALUE-BASED) -------------
        // cbETH is NON-REBASING: balanceOf never grows. Rewards materialize
        // exclusively as cbETH/ETH exchange-rate appreciation, so the excess
        // is measured in ETH value against cbETHPrincipalETH (ETH-wei consumed
        // at acquisition), then converted back to the cbETH-wei to swap out.
        // Oracle unhealthy → revert and retry next cycle (no blind valuation),
        // preserving the pre-fix revert-and-retry semantics.
        (uint256 rate, bool rateValid) = _readCbEthRate();
        if (!rateValid) revert OracleInvalid();

        uint256 cbBal = cbETH.balanceOf(address(this));
        uint256 currentValueETH = (cbBal * rate) / 1e18;
        if (currentValueETH <= cbETHPrincipalETH) revert ZeroAmount();
        uint256 excessETH = currentValueETH - cbETHPrincipalETH;

        // Dust guard — value-based math leaves sub-floor rounding residue
        // (≲ a few wei) after every harvest; gating the execution path on the
        // same HARVEST_DUST_FLOOR checkUpkeep uses keeps AUTO-INV-1
        // (check ⇒ executable) exact and blocks dust-sized swaps.
        if (excessETH < HARVEST_DUST_FLOOR) revert ZeroAmount();

        uint256 rewardsCbETH = (excessETH * 1e18) / rate;
        if (rewardsCbETH == 0) revert ZeroAmount();
        // Provably ≤ cbBal (excessETH ≤ currentValueETH); clamp kept as
        // defense-in-depth against any future rounding regression.
        if (rewardsCbETH > cbBal) rewardsCbETH = cbBal;

        // --- v2.6.3 slippage computed here at execution time --------------
        // Retired carry-through: minWETH was passed from checkUpkeep/wrapper.
        // Now computed from the cbETH/ETH oracle. No blind swap: revert and
        // retry next cycle if the oracle is unhealthy.
        (uint256 minWETH, bool oracleValid) = _computeHarvestSlippageGuard(rewardsCbETH);
        if (!oracleValid || minWETH == 0) revert OracleInvalid();

        // ─── Approve Aerodrome router for cbETH ────────────────────────────
        cbETH.approve(address(AERO_ROUTER), rewardsCbETH);

        // ─── Aerodrome Slipstream swap cbETH → WETH ────────────────────────
        uint256 wethBefore = WETH.balanceOf(address(this));
        uint256 wethReceived;
        try AERO_ROUTER.exactInputSingle(
            IAerodromeSlipstreamRouter.ExactInputSingleParams({
                tokenIn:           address(cbETH),
                tokenOut:          address(WETH),
                tickSpacing:       CBETH_TICK_SPACING,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          rewardsCbETH,
                amountOutMinimum:  minWETH,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 wOut) {
            wethReceived = wOut;
        } catch {
            // Swap failed — reset approval, revert (no partial distribution)
            cbETH.approve(address(AERO_ROUTER), 0);
            revert ZeroAmount();
        }

        // Reset cbETH approval — defense-in-depth
        cbETH.approve(address(AERO_ROUTER), 0);

        // Verify WETH receipt matches return value (leakage check)
        uint256 wethAfter = WETH.balanceOf(address(this));
        if ((wethAfter - wethBefore) != wethReceived) revert LeakageDetected();

        // ─── Unwrap WETH → ETH ─────────────────────────────────────────────
        uint256 ethBefore = address(this).balance;
        try WETH.withdraw(wethReceived) {
            // OK
        } catch {
            // WETH stuck — emit for operator visibility, revert harvest
            emit LPFailed(wethReceived, 8);
            revert ZeroAmount();
        }
        uint256 total = address(this).balance - ethBefore;
        if (total == 0) revert ZeroAmount();

        // ─── Distribute ETH 25% LP / 75% Treasury (preserved from v2.4) ────
        uint256 toLp = (total * REWARDS_TO_LP) / 100;
        uint256 toT  = total - toLp;

        // Attempt LP donation; on failure, fold into treasury portion instead of
        // mixing with accumulatedETH (which would apply fee splits on re-route).
        if (toLp > 0) {
            bytes memory data = abi.encode(CallbackData({
                action:  Action.ADD_RECURRING,
                amount0: toLp,
                amount1: 0
            }));
            try POOL_MANAGER.unlock(data) {
                emit LiquidityAdded(toLp, 0, block.timestamp);
            } catch {
                toT += toLp;
                emit LPFailed(toLp, 5);
            }
        }

        (bool ok,) = TREASURY_SAFE.call{value: toT}("");
        require(ok, "Treasury rewards transfer failed");

        emit RewardsHarvested(total, toLp, toT, block.timestamp);
    }


    // ═══════════════════════════════════════════════════════════════════════
    //              CHAINLINK AUTOMATION (council-ratified 2026-05-12)
    //
    //  Schedules already-authorized permissionless functions (routeETH,
    //  harvestRewards) when their canonical guards permit, with a hysteresis
    //  buffer to avoid threshold-flicker spam.
    //
    //  Automation gains NO new authorities. Every action it performs is one
    //  that any caller could perform once guards are satisfied. Determinism
    //  is preserved. Council IV.1 through IV.9 fully integrated. AUTO-INV
    //  gauntlet (ChatGPT seat) is the certification baseline.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Chainlink calls this off-chain (view).
     *         Returns whether and which task to execute.
     *
     *         Hysteresis (IV.4): accumulatedETH must exceed ROUTE_THRESHOLD by 20%
     *         and the ETH-denominated harvestable excess (C-1: oracle value of the
     *         cbETH holding minus cbETHPrincipalETH) must reach HARVEST_DUST_FLOOR
     *         before upkeep triggers.
     *
     *         cbETHPaused is checked for the harvest branch as a deliberate
     *         policy choice — the depeg flag is the protocol's "wait for re-peg"
     *         signal, so Automation should not trigger harvests during depeg
     *         even though harvestRewards itself does not enforce this check.
     *         This makes checkUpkeep STRICTER than harvestRewards, which is
     *         AUTO-INV-1 compliant (stricter check still implies executable;
     *         the reverse direction is not required).
     *
     *         AUTO-INV-1: All guards checked here mirror or strictly tighten
     *         the guards inside routeETH / harvestRewards.
     */
    // ═══════════════════════════════════════════════════════════════════════
    //   v2.6.3 — SLIPPAGE VIEW HELPERS (used by both checkUpkeep AND the
    //   external manual wrappers so the carry-through and the inline paths
    //   compute slippage from the exact same code)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice C-1 fix (audit 2026-07-14) — single health-guarded read of the
     *         Chainlink cbETH/ETH 18-decimal exchange-rate feed. Shared by
     *         checkUpkeep, both slippage helpers and _harvestRewards so
     *         decision-time and execution-time math run off identical
     *         oracle-validity rules (round completeness, finalization,
     *         ORACLE_STALE_CBETH staleness, positive answer).
     * @return rate  ETH-wei value of 1e18 cbETH-wei, or 0 if unhealthy.
     * @return valid True iff the read is healthy.
     */
    function _readCbEthRate() internal view returns (uint256 rate, bool valid) {
        try CHAINLINK_CBETH_ETH.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            bool ok = (answeredInRound >= roundId)
                && (updatedAt != 0)
                // forge-lint: disable-next-line(block-timestamp)
                && (block.timestamp - updatedAt <= ORACLE_STALE_CBETH)
                && (answer > 0);

            if (ok) {
                // forge-lint: disable-next-line(unsafe-typecast)
                rate  = uint256(answer);
                valid = true;
            }
        } catch {}
    }

    /**
     * @notice Compute the cbETH slippage guard for a routeETH cycle from current
     *         oracle reads. (v3 — DAI leg removed; treasury serves as reserve, so
     *         only the cbETH staking leg needs an oracle-derived floor.)
     * @param  ethAmt   Total ETH to be routed (C-4: the routable amount, i.e.
     *                  accumulator net of the caller-reward carve-out).
     * @return minCbETH 90% of expected cbETH for the staking leg, or 0 if oracle invalid.
     * @return valid    True iff the cbETH oracle read is healthy. If false, caller must
     *                  NOT fire upkeep; the internal core retains ETH instead of
     *                  blind-swapping, but firing upkeep on a known-invalid oracle wastes gas.
     */
    function _computeRouteSlippageGuards(uint256 ethAmt)
        internal
        view
        returns (uint256 minCbETH, bool valid)
    {
        // Replicate _routeETH allocation math so the guard applies to the actual
        // staking input (80% of treasury), not the gross ethAmt.
        uint256 toLP       = (ethAmt * LP_PCT) / 100;
        uint256 toTreasury = ethAmt - toLP;
        uint256 toStaking  = toTreasury;  // v3 — full treasury portion to staking (no reserve carve-out)

        // ─── cbETH leg ───────────────────────────────────────────────────
        if (toStaking == 0) {
            minCbETH = 1; // sentinel: staking leg not exercised this cycle
        } else {
            (uint256 rate, bool rateValid) = _readCbEthRate();
            if (rateValid) {
                uint256 expectedCbETH = (toStaking * 1e18) / rate;
                minCbETH = (expectedCbETH * SLIPPAGE) / 100;
            }
        }

        valid = (minCbETH > 0);
    }

    /**
     * @notice Compute slippage guard for a harvestRewards cycle.
     * @param  rewardsCbETH  cbETH-wei of exchange-rate-appreciation excess that
     *                       will be unwound to WETH (C-1: value-based, computed
     *                       by _harvestRewards from the same oracle read class).
     * @return minWETH       90% of expected WETH, or 0 if oracle invalid.
     * @return valid         True iff oracle healthy.
     */
    function _computeHarvestSlippageGuard(uint256 rewardsCbETH)
        internal
        view
        returns (uint256 minWETH, bool valid)
    {
        (uint256 rate, bool rateValid) = _readCbEthRate();
        if (rateValid) {
            uint256 expectedWETH = (rewardsCbETH * rate) / 1e18;
            minWETH = (expectedWETH * SLIPPAGE) / 100;
        }

        valid = (minWETH > 0);
    }

    function checkUpkeep(bytes calldata /*checkData*/)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // IV.7 Position B -- cheap pause check first
        if (upkeepPaused) return (false, "");

        // ROUTE_ETH branch -- v2.6.3: encode task discriminator only. Slippage
        // is computed at execution time in _routeETH, not carried in performData.
        if (!routingPaused) {
            uint256 hysteresisThreshold = (ROUTE_THRESHOLD * UPKEEP_HYSTERESIS_BPS) / 100;
            // forge-lint: disable-next-line(block-timestamp)
            bool cooldownPassed = block.timestamp >= lastRouteTime + ROUTE_COOLDOWN;
            if (accumulatedETH >= hysteresisThreshold && cooldownPassed) {
                return (true, abi.encode(UpkeepTask.ROUTE_ETH));
            }
        }

        // HARVEST_REWARDS branch -- cbETHPaused gates harvest at the Automation
        // layer (stricter than harvestRewards; AUTO-INV-1 compliant).
        // C-1 fix (audit 2026-07-14): VALUE-BASED predicate mirroring
        // _harvestRewards exactly. cbETH is non-rebasing, so the old
        // balance-vs-cbETHPrincipal comparison was identically false and this
        // branch was dead. The oracle must be healthy at decision time —
        // unhealthy means _harvestRewards would revert OracleInvalid, so
        // firing upkeep would only burn the forwarder's gas.
        if (!routingPaused && !cbETHPaused) {
            uint256 cbBal = cbETH.balanceOf(address(this));
            if (cbBal > 0) {
                (uint256 rate, bool rateValid) = _readCbEthRate();
                if (rateValid) {
                    uint256 currentValueETH = (cbBal * rate) / 1e18;
                    if (currentValueETH > cbETHPrincipalETH) {
                        uint256 excessETH = currentValueETH - cbETHPrincipalETH;
                        if (excessETH >= HARVEST_DUST_FLOOR) {
                            return (true, abi.encode(UpkeepTask.HARVEST_REWARDS));
                        }
                    }
                }
            }
        }

        return (false, "");
    }

    /**
     * @notice Chainlink's Automation Forwarder calls this on-chain.
     *         Decodes the task and delegates to the existing permissionless function.
     *
     *         IV.3: only the forwarder may call (onlyForwarder modifier).
     *         IV.9: replay-protected via executedUpkeeps mapping (defense-in-depth).
     *         nonReentrant: belt-and-suspenders against any future callback path.
     *
     *         FIX 3 (Architect-ratified 2026-05-20): ROUTE_ETH replay key uses
     *         block.number (matching HARVEST_REWARDS), not lastRouteTime. The
     *         prior key (task, lastRouteTime) changed mid-execution — _routeETH
     *         writes lastRouteTime = block.timestamp on the CEI line, so a
     *         second same-block call computed a different replay key and the
     *         map missed it. block.number is fixed within a block; same-block
     *         calls now produce identical keys; replay map catches the second
     *         call. ROUTE_COOLDOWN remains the cross-block protection on the
     *         external routeETH() wrapper; checkUpkeep's upstream hysteresis is
     *         the off-chain cadence gate. This fix closes same-block bypass
     *         only — no other behavior change.
     */
    function performUpkeep(bytes calldata performData)
        external
        override
        onlyForwarder
        nonReentrant
    {
        if (upkeepPaused) revert UpkeepIsPaused();

        // v2.6.3 -- performData carries only the task discriminator (carry-through retired).
        UpkeepTask task = abi.decode(performData, (UpkeepTask));

        // Replay protection per task (defense-in-depth; block.number key per FIX 3).
        bytes32 replayKey;
        if (task == UpkeepTask.ROUTE_ETH) {
            replayKey = keccak256(abi.encode(task, block.number));
        } else if (task == UpkeepTask.HARVEST_REWARDS) {
            replayKey = keccak256(abi.encode(task, block.number));
        } else {
            revert InvalidTask();
        }

        if (executedUpkeeps[replayKey]) revert UpkeepAlreadyExecuted();
        executedUpkeeps[replayKey] = true;

        uint256 gasBefore = gasleft();
        uint256 valueMoved;

        if (task == UpkeepTask.ROUTE_ETH) {
            uint256 routedAmount = accumulatedETH; // capture before _routeETH zeros it

            // v2.6.3 -- direct dispatch. msg.sender inside _routeETH is the
            // forwarder, so the IV.2 forwarder reward-exemption lands without
            // threading originalCaller.
            uint256 secret = ++_executionNonce;
            _activeExecutionSecret = secret;
            _routeETH(secret);

            valueMoved = routedAmount;
            emit UpkeepPerformed(uint8(UpkeepTask.ROUTE_ETH), gasBefore - gasleft(), valueMoved);
        } else {
            uint256 cbBalBefore = cbETH.balanceOf(address(this));

            uint256 secret = ++_executionNonce;
            _activeExecutionSecret = secret;
            _harvestRewards(secret);

            uint256 cbBalAfter = cbETH.balanceOf(address(this));
            valueMoved = cbBalBefore > cbBalAfter ? cbBalBefore - cbBalAfter : 0;
            emit UpkeepPerformed(uint8(UpkeepTask.HARVEST_REWARDS), gasBefore - gasleft(), valueMoved);
        }

        unchecked { executedUpkeepCount += 1; }
    }

    /// @notice X-LINK state exposed for invariant testing.
    ///         MUST read 0 between transactions — a non-zero value outside an
    ///         active routeETH/harvestRewards execution indicates a revert path
    ///         left the secret armed. invariant_XLinkAlwaysConsumed asserts this.
    function activeXLinkSecret() external view returns (uint256) {
        return _activeExecutionSecret;
    }

    /**
     * @notice Initial forwarder registration. One-time path callable by owner.
     *         After this, automationForwarder is mutable ONLY via Treasury 48h
     *         timelock (queueForwarderUpdate / executeForwarderUpdate). Per IV.8,
     *         this is not "lock on first call" — Treasury retains a restricted-
     *         update primitive for Chainlink Registry migrations.
     */
    function setForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert InvalidAddress();
        if (automationForwarder != address(0)) revert ForwarderAlreadySet();
        automationForwarder = forwarder;
        emit AutomationForwarderSet(forwarder, block.timestamp);
    }

    /// @notice Record the Chainlink Upkeep ID after registration. Owner-only.
    function setUpkeepID(uint256 newUpkeepID) external onlyOwner {
        upkeepID = newUpkeepID;
        emit UpkeepRegistered(newUpkeepID, block.timestamp);
    }

    /// @notice IV.8 Step 1 — queue forwarder update via 48h timelock.
    function queueForwarderUpdate(address newForwarder) external onlyTreasury returns (bytes32 id) {
        if (newForwarder == address(0)) revert InvalidAddress();
        _pendingForwarder = newForwarder;
        id = keccak256(abi.encodePacked("forwarderUpdate", block.timestamp, newForwarder));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ForwarderUpdateQueued(id, newForwarder, timelockQueue[id]);
    }

    /// @notice IV.8 Step 2 — execute forwarder update after 48h elapsed.
    function executeForwarderUpdate(bytes32 id) external onlyTreasury tlPassed(id) {
        address newForwarder = _pendingForwarder;
        if (newForwarder == address(0)) revert InvalidAddress();
        address old = automationForwarder;
        automationForwarder = newForwarder;
        _pendingForwarder = address(0);
        emit ForwarderUpdated(old, newForwarder, block.timestamp);
    }

    /// @notice IV.7 Position B — cheap upkeep pause for high-frequency Hook.
    ///         Treasury-only, independent of routingPaused.
    function pauseUpkeep() external onlyTreasury {
        upkeepPaused = true;
        emit UpkeepPausedSet(true, block.timestamp);
    }

    function unpauseUpkeep() external onlyTreasury {
        upkeepPaused = false;
        emit UpkeepPausedSet(false, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   DEPEG MONITORING (matching v1)
    // ═══════════════════════════════════════════════════════════════════════

    function _checkDepeg() internal {
        try CHAINLINK_CBETH_ETH.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Grok-audit: full staleness check, not just timestamp
            if (answeredInRound < roundId) return;         // Round incomplete
            if (updatedAt == 0) return;                     // Round not finalized
            // v2.5: cbETH/ETH feed publishes on 24-hour heartbeat. ORACLE_STALE_CBETH
            // = 90,000s (25h) accommodates the heartbeat plus 1h safety margin.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE_CBETH) return; // Feed stale
            if (answer <= 0) return;                        // Invalid answer

            if (answer < DEPEG_THRESH && !cbETHPaused) {
                cbETHPaused = true;
                // v2.5 — 18-decimal arithmetic. answer ∈ (0, DEPEG_THRESH=0.97e18)
                // validated above; (1e18 - answer) ∈ (0.03e18, 1e18) is always
                // positive, fits uint256.
                // forge-lint: disable-next-line(unsafe-typecast)
                emit CbETHPaused(uint256(int256(1e18) - answer) * 100 / 1e18, block.timestamp);
            } else if (answer >= DEPEG_THRESH && cbETHPaused) {
                cbETHPaused = false;
                emit CbETHResumed(block.timestamp);
            }
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      CIRCUIT BREAKER (Treasury)
    // ═══════════════════════════════════════════════════════════════════════

    function pauseRouting() external onlyTreasury {
        routingPaused = true;
        emit CircuitBreakerOn(block.timestamp);
    }

    function queueResumeRouting() external onlyTreasury returns (bytes32 id) {
        id = keccak256(abi.encodePacked("resume", block.timestamp, msg.sender));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ParameterQueued(id, "resumeRouting", timelockQueue[id]);
    }

    function resumeRouting(bytes32 id) external onlyTreasury tlPassed(id) {
        routingPaused = false;
        emit CircuitBreakerOff(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SAV: DEPOSIT & BURN & INVENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Treasury deposits council STEEL allocation.
     *         Splits evenly across 4 council members. Remainder returns to Treasury.
     */
    function savDeposit(uint256 amount) external onlyTreasury notSlashed nonReentrant {
        STEEL_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 share     = amount / 4;
        uint256 remainder = amount % 4;
        claimable[COUNCIL_0] += share;
        claimable[COUNCIL_1] += share;
        claimable[COUNCIL_2] += share;
        claimable[COUNCIL_3] += share;
        if (remainder > 0) {
            STEEL_TOKEN.safeTransfer(TREASURY_SAFE, remainder);
        }
        emit SAVDeposit(amount, share, remainder);
    }

    /**
     * @notice Council member burns their claimable STEEL.
     *         Sends to dead address since STEEL is not ERC20Burnable.
     */
    function savBurn(uint256 amount) external onlyCouncilMember savNotPaused notSlashed nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > claimable[msg.sender]) revert ExceedsClaimable();
        claimable[msg.sender] -= amount;
        STEEL_TOKEN.safeTransfer(DEAD, amount);
        emit CouncilBurn(msg.sender, amount);
    }

    /**
     * @notice Step 1 — any council member registers invent proposal.
     *         Re-proposing an expired hash clears approvals and restarts cycle.
     */
    function proposeInvent(bytes32 proposalHash)
        external onlyCouncilMember savNotPaused notSlashed
    {
        Proposal storage p = proposals[proposalHash];
        // Proposal expiry check; validator's ~12s block.timestamp manipulation window is immaterial vs proposal lifetime measured in hours.
        // forge-lint: disable-next-line(block-timestamp)
        if (p.expiry > 0 && block.timestamp < p.expiry && !p.executed) {
            revert ProposalStillActive();
        }
        p.hasApproved[COUNCIL_0] = false;
        p.hasApproved[COUNCIL_1] = false;
        p.hasApproved[COUNCIL_2] = false;
        p.hasApproved[COUNCIL_3] = false;
        p.approvals = 0;
        // Expiry computed on a 30-day window; validator's ~12s manipulation window is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        p.expiry    = block.timestamp + INVENT_EXPIRY;
        p.executed  = false;
        emit InventProposed(proposalHash, msg.sender, p.expiry);
    }

    /**
     * @notice Step 2 — council member approves a proposal. One approval per address.
     */
    function approveInvent(bytes32 proposalHash)
        external onlyCouncilMember savNotPaused notSlashed
    {
        Proposal storage p = proposals[proposalHash];
        if (p.expiry == 0)              revert ProposalNotFound();
        // Expiry compared against a 30-day window; validator's ~12s manipulation window is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiry) revert ProposalExpired();
        if (p.executed)                  revert ProposalAlreadyExecuted();
        if (p.hasApproved[msg.sender])   revert AlreadyApproved();

        p.hasApproved[msg.sender] = true;
        p.approvals++;
        emit InventApproved(proposalHash, msg.sender, p.approvals);
    }

    /**
     * @notice Step 3 — Architect (via Treasury) executes approved proposal.
     *         Deducts equally from all four claimable balances.
     */
    function executeInvent(
        uint256 amount,
        bytes32 proposalHash,
        bytes calldata metadata
    ) external onlyTreasury savNotPaused notSlashed nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Proposal storage p = proposals[proposalHash];
        if (p.expiry == 0)                   revert ProposalNotFound();
        // Expiry compared against a 30-day window; validator's ~12s manipulation window is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiry)     revert ProposalExpired();
        if (p.executed)                      revert ProposalAlreadyExecuted();
        if (p.approvals < INVENT_THRESHOLD)  revert ThresholdNotMet();

        uint256 deductEach = amount / 4;
        if (claimable[COUNCIL_0] < deductEach) revert InsufficientClaimable();
        if (claimable[COUNCIL_1] < deductEach) revert InsufficientClaimable();
        if (claimable[COUNCIL_2] < deductEach) revert InsufficientClaimable();
        if (claimable[COUNCIL_3] < deductEach) revert InsufficientClaimable();

        p.executed = true;
        claimable[COUNCIL_0] -= deductEach;
        claimable[COUNCIL_1] -= deductEach;
        claimable[COUNCIL_2] -= deductEach;
        claimable[COUNCIL_3] -= deductEach;

        uint256 transferAmount = deductEach * 4;
        STEEL_TOKEN.safeTransfer(TREASURY_SAFE, transferAmount);

        emit InventExecuted(proposalHash, transferAmount, metadata);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   SAV: PAUSE / UNPAUSE / SLASH (Treasury)
    // ═══════════════════════════════════════════════════════════════════════

    function savPause() external onlyTreasury {
        savPaused = true;
        emit SAVPaused(msg.sender);
    }

    function savUnpause() external onlyTreasury {
        savPaused = false;
        emit SAVUnpaused(msg.sender);
    }

    /**
     * @notice Nuclear option — burns entire SAV STEEL balance.
     *         Zeros all claimables. Marks contract permanently inert for SAV operations.
     *         Hook fee capture continues, but council allocation is permanently lost.
     */
    function savSlash() external onlyTreasury {
        uint256 balance = STEEL_TOKEN.balanceOf(address(this));
        if (balance == 0) revert NothingToSlash();

        claimable[COUNCIL_0] = 0;
        claimable[COUNCIL_1] = 0;
        claimable[COUNCIL_2] = 0;
        claimable[COUNCIL_3] = 0;

        slashed = true;
        STEEL_TOKEN.safeTransfer(DEAD, balance);
        emit Slashed(balance);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    function _isCouncilMember(address addr) internal view returns (bool) {
        return (
            addr == COUNCIL_0 ||
            addr == COUNCIL_1 ||
            addr == COUNCIL_2 ||
            addr == COUNCIL_3
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      EMERGENCY RESCUE (Treasury)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Sweep accidentally-sent ERC20 tokens from hook to Treasury.
     *         Guards against sweeping protocol-critical tokens:
     *           · STEEL (SAV allocations are here)
     *           · DAI (protocol emergency reserve)
     *           · cbETH (rewards-accruing treasury principal)
     *           · WETH (transient during DAI swaps)
     *         Native ETH is never swept here — it may be legitimate accumulator
     *         balance. Use the Treasury's manual `routeETH` call if ETH needs
     *         to move via the protocol's own path.
     */
    function rescueToken(address token, uint256 amount) external onlyTreasury {
        if (token == address(STEEL_TOKEN)) revert RescueBlocked();
        if (token == address(cbETH))       revert RescueBlocked();
        if (token == address(WETH))        revert RescueBlocked();

        IERC20(token).safeTransfer(TREASURY_SAFE, amount);
        emit TokenRescued(token, amount, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function getClaimable(address member) external view returns (uint256) {
        return claimable[member];
    }

    function getProposalStatus(bytes32 hash) external view returns (uint8 approvals, uint256 expiry, bool executed) {
        Proposal storage p = proposals[hash];
        return (p.approvals, p.expiry, p.executed);
    }

    /**
     * @notice Returns key state for external monitoring (Operator Console etc.).
     * @dev    v3 — daiReserve field removed from this tuple (DAI leg gone). The
     *         Operator Console's getState() decode must drop the daiReserve slot
     *         to match. cbPrincipal is in cbETH-wei and is the ACQUISITION RECORD
     *         only (C-1 fix, audit 2026-07-14); the harvest baseline is the
     *         separate public cbETHPrincipalETH getter (ETH-wei at acquisition).
     *         Live ethEquiv of the holding = cbETH.balanceOf(hook) * cbEthRate /
     *         1e18 via CHAINLINK_CBETH_ETH.
     */
    function getState() external view returns (
        uint256 accumulated,
        uint256 cbPrincipal,
        bool    routingPaused_,
        bool    cbPaused_,
        uint256 nextRouteAllowed
    ) {
        return (
            accumulatedETH,
            cbETHPrincipal,
            routingPaused,
            cbETHPaused,
            lastRouteTime + ROUTE_COOLDOWN
        );
    }

    // v3 — isDaiReserveFull() removed (no DAI reserve).

    // ═══════════════════════════════════════════════════════════════════════
    //                            RECEIVE / FALLBACK
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
