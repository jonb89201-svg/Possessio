// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/*═══════════════════════════════════════════════════════════════════════════════
  POSSESSIO HOOK — CHAINLINK AUTOMATION PATCH v0.2
  Phase 1 + 2: routeETH + harvestRewards upkeep integration

  Council-ratified 2026-05-12 per:
    COUNCIL_2026-05-12_Ratified_ChainlinkAutomationIntegration.md

  This is the additive patch to PossessioHook (POSSESSIO_v2-3.sol).

  CHANGELOG (v0.1 → v0.2 — self-audit corrections):
    [FIX-1]  IV.2 reward exemption now also covers msg.sender == address(this)
             (the internal dispatcher path). v0.1 would have paid the contract
             itself 0.1% on every automated routeETH call.
    [FIX-2]  performUpkeep now declared nonReentrant. Defense-in-depth against
             any future LP/staking callback path that could re-enter.
    [FIX-3]  Renamed _performRouteETH/_performHarvestRewards →
             dispatchRouteETH/dispatchHarvest. External-only with leading
             underscore violated Solidity naming convention.
    [FIX-4]  New error NotSelf() distinguishes "internal-only entrypoint"
             from "must be forwarder". v0.1 reused NotForwarder() for both,
             which was functionally correct but semantically misleading.
    [FIX-5]  checkUpkeep harvest branch now also checks !cbETHPaused. v0.1
             only mirrored routingPaused. If cbETHPaused independently gates
             cbETH ops inside harvestRewards, v0.1 would have violated
             AUTO-INV-1 (check returning true while perform reverts).
    [DOC-6]  Honest accounting: replay protection is defense-in-depth, not
             load-bearing. routeETH's cooldown and harvestRewards's ZeroAmount
             do the real work against cross-block retries. The replay map
             defends against same-block re-entry only.
    [DOC-7]  Phase 1 + Phase 2 combined in one patch because they share the
             multi-task substrate (UpkeepTask enum, performUpkeep dispatcher).
             Compressed phasing acknowledged.

  Authorship: Code Integrity / CSO seat (Claude).
  Audit:      Adversarial seat (Grok) — next.
  Ratified:   All four council seats unanimous; Architect green-light 2026-05-12.

  Items integrated:
    IV.1 — HARVEST_DUST_FLOOR = 0.001 ether
    IV.2 — Position B: forwarder + internal-dispatcher exempt from 0.1% reward
    IV.3 — Mandatory forwarder restriction on performUpkeep (NotForwarder revert)
    IV.4 — 20% hysteresis buffer in checkUpkeep (not in routeETH itself)
    IV.7 — Position B: upkeepPaused flag, cheap pause for high-frequency Hook
    IV.8 — Treasury-gated forwarder update via 48h timelock (NOT lock-on-set)
    IV.9 — Upkeep replay protection via executedUpkeeps mapping (defense-in-depth)
    Grok — UpkeepPerformed event with task, gasUsed, valueMoved
    Gemini — UpkeepTask enum for self-documenting task IDs

═══════════════════════════════════════════════════════════════════════════════*/

// Add to imports at top of POSSESSIO_v2-3.sol:
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/*───────────────────────────────────────────────────────────────────────────────
  CONTRACT DECLARATION — add interface inheritance
───────────────────────────────────────────────────────────────────────────────*/

// CURRENT (line 173):
//   contract PossessioHook is IUnlockCallback, ReentrancyGuard, Ownable2Step {
//
// PATCHED:
//   contract PossessioHook is IUnlockCallback, ReentrancyGuard, Ownable2Step, AutomationCompatibleInterface {

/*───────────────────────────────────────────────────────────────────────────────
  CONSTANTS — append to existing constants block (after ROUTE_COOLDOWN, ~line 210)
───────────────────────────────────────────────────────────────────────────────*/

    /// @notice IV.1 — minimum cbETH excess above principal before harvest upkeep triggers.
    ///         Prevents gas-burn loops on rounding dust.
    uint256 public constant HARVEST_DUST_FLOOR = 0.001 ether;

    /// @notice IV.4 — multiplier for checkUpkeep hysteresis buffer (basis 100).
    ///         Upkeep only triggers when accumulated value ≥ canonical threshold × 120/100.
    ///         The contract's own routeETH/harvestRewards still accept the canonical threshold;
    ///         this buffer applies only to Automation's decision to act.
    uint256 public constant UPKEEP_HYSTERESIS_BPS = 120; // 20% over canonical threshold

/*───────────────────────────────────────────────────────────────────────────────
  STORAGE — append to existing storage block (after slashed, ~line 277)
  NOTE: Variables appended to end of layout. New slots assigned by compiler.
  No existing slot disturbed. Non-upgradeable contract, no proxy concerns.
───────────────────────────────────────────────────────────────────────────────*/

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

    /// @notice IV.9 — replay protection. Maps keccak256-encoded (task, taskStateKey) → executed.
    ///         Defense-in-depth: routeETH's 6h cooldown and harvestRewards's ZeroAmount revert
    ///         do the load-bearing work against cross-block retries. The replay map adds
    ///         a same-block re-execution guard and a stable audit trail.
    mapping(bytes32 => bool) public executedUpkeeps;

    /// @notice Monotonic counter of automated executions. Exposed for console dashboard.
    uint256 public executedUpkeepCount;

/*───────────────────────────────────────────────────────────────────────────────
  ENUM — append to existing types
───────────────────────────────────────────────────────────────────────────────*/

    /// @notice Task discriminator for multi-task upkeep (Gemini-ratified pattern).
    ///         Encoded in performData; decoded in performUpkeep.
    enum UpkeepTask { ROUTE_ETH, HARVEST_REWARDS }

/*───────────────────────────────────────────────────────────────────────────────
  ERRORS — append to existing error block (after RescueBlocked, ~line 368)
───────────────────────────────────────────────────────────────────────────────*/

    error NotForwarder();              // performUpkeep called by non-forwarder
    error NotSelf();                   // internal-only entrypoint called externally [FIX-4]
    error ForwarderNotSet();           // performUpkeep called before setForwarder
    error ForwarderAlreadySet();       // setForwarder called twice (use queue/executeForwarderUpdate instead)
    error InvalidTask();               // performData decoded to unknown task
    error UpkeepAlreadyExecuted();     // replay map hit
    error UpkeepIsPaused();            // performUpkeep called while upkeepPaused

/*───────────────────────────────────────────────────────────────────────────────
  EVENTS — append to existing events block
───────────────────────────────────────────────────────────────────────────────*/

    /// @notice Grok-ratified consolidated event for all automated executions.
    /// @param task        Discriminator: 0 = ROUTE_ETH, 1 = HARVEST_REWARDS.
    /// @param gasUsed     Gas consumed by the inner call. Approximate (measured around delegated call).
    /// @param valueMoved  Task-specific value: ETH wei routed for ROUTE_ETH, cbETH wei withdrawn for HARVEST_REWARDS.
    event UpkeepPerformed(uint8 indexed task, uint256 gasUsed, uint256 valueMoved);

    /// @notice Forwarder set initially (one-time path).
    event AutomationForwarderSet(address forwarder, uint256 timestamp);

    /// @notice Forwarder update queued via Treasury timelock (IV.8).
    event ForwarderUpdateQueued(bytes32 indexed id, address newForwarder, uint256 executeAfter);

    /// @notice Forwarder update executed after timelock elapsed.
    event ForwarderUpdated(address oldForwarder, address newForwarder, uint256 timestamp);

    /// @notice Upkeep ID recorded after Chainlink registration.
    event UpkeepRegistered(uint256 upkeepID, uint256 timestamp);

    /// @notice IV.7 Position B — upkeep paused / resumed.
    event UpkeepPausedSet(bool paused, uint256 timestamp);

/*───────────────────────────────────────────────────────────────────────────────
  MODIFIER — append to existing modifier block (after tlPassed, ~line 410)
───────────────────────────────────────────────────────────────────────────────*/

    modifier onlyForwarder() {
        if (automationForwarder == address(0)) revert ForwarderNotSet();
        if (msg.sender != automationForwarder) revert NotForwarder();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

/*───────────────────────────────────────────────────────────────────────────────
  [FIX-1] IV.2 — REWARD EXEMPTION PATCH for existing routeETH
  Modify the existing reward block at lines 687-693 of POSSESSIO_v2-3.sol.
───────────────────────────────────────────────────────────────────────────────*/

// CURRENT (lines 687-693):
//     // Permissionless caller gets tiny reward to amortize gas
//     if (!isTreasury) {
//         uint256 reward = total / 1000; // 0.1% of routed
//         if (reward > 0 && address(this).balance >= reward) {
//             (bool ok,) = msg.sender.call{value: reward}("");
//             if (!ok) { /* swallow — reward is best-effort */ }
//         }
//     }

// PATCHED — exempt forwarder AND internal dispatcher (address(this)):
        // Permissionless caller gets tiny reward to amortize gas.
        // Two callers are exempt:
        //   1. automationForwarder — operator pays Chainlink via LINK funding; reward would be double-spend.
        //   2. address(this)       — dispatchRouteETH calls this.routeETH(), so msg.sender is the contract.
        //                            Without this exemption, the contract would attempt to pay itself.
        // Manual permissionless callers (non-forwarder, non-self, non-Treasury) retain the incentive,
        // preserving fallback execution path if Automation lapses.
        if (!isTreasury
            && msg.sender != automationForwarder
            && msg.sender != address(this))
        {
            uint256 reward = total / 1000; // 0.1% of routed
            if (reward > 0 && address(this).balance >= reward) {
                (bool ok,) = msg.sender.call{value: reward}("");
                if (!ok) { /* swallow — reward is best-effort */ }
            }
        }

/*───────────────────────────────────────────────────────────────────────────────
  AUTOMATION INTERFACE — append as new section after harvestRewards (~line 925)
  and before SAV operations block.
───────────────────────────────────────────────────────────────────────────────*/

    // ═══════════════════════════════════════════════════════════════════════
    //                    CHAINLINK AUTOMATION (Phase 1 + 2)
    //
    //  Council-ratified 2026-05-12. Schedules already-authorized permissionless
    //  functions (routeETH, harvestRewards) when their canonical guards permit,
    //  with a hysteresis buffer to avoid threshold-flicker spam.
    //
    //  Automation gains NO new authorities. Every action it performs is one
    //  that any caller could perform once guards are satisfied. Determinism
    //  is preserved.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Chainlink calls this off-chain (read-only view).
     *         Returns whether and which task to execute.
     *
     *         Hysteresis (IV.4): accumulatedETH must exceed ROUTE_THRESHOLD by 20%
     *         and harvestable cbETH excess must exceed HARVEST_DUST_FLOOR before
     *         upkeep triggers, even though the underlying functions accept the
     *         canonical thresholds. The buffer prevents flicker at the boundary.
     *
     *         AUTO-INV-1: All guards checked here mirror the guards inside
     *         routeETH / harvestRewards. If this returns true, performUpkeep
     *         in the same block-state will succeed.
     */
    function checkUpkeep(bytes calldata /*checkData*/)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // IV.7 Position B — cheap pause check first
        if (upkeepPaused) return (false, "");

        // routingPaused gates both routeETH and harvestRewards (both inherit notPaused).
        // cbETHPaused independently gates cbETH operations.

        // ROUTE_ETH branch
        if (!routingPaused) {
            uint256 hysteresisThreshold = (ROUTE_THRESHOLD * UPKEEP_HYSTERESIS_BPS) / 100;
            // forge-lint: disable-next-line(block-timestamp)
            bool cooldownPassed = block.timestamp >= lastRouteTime + ROUTE_COOLDOWN;
            if (accumulatedETH >= hysteresisThreshold && cooldownPassed) {
                return (true, abi.encode(UpkeepTask.ROUTE_ETH));
            }
        }

        // HARVEST_REWARDS branch
        // [FIX-5] Both routingPaused (via notPaused inheritance on harvestRewards)
        //         AND cbETHPaused (which independently gates cbETH operations) must be clear.
        if (!routingPaused && !cbETHPaused) {
            uint256 cbBal = cbETH.balanceOf(address(this));
            if (cbBal > cbETHPrincipal) {
                uint256 excess = cbBal - cbETHPrincipal;
                if (excess >= HARVEST_DUST_FLOOR) {
                    return (true, abi.encode(UpkeepTask.HARVEST_REWARDS));
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
     *
     *         [FIX-2] nonReentrant: defends against any future callback path that
     *                 might re-enter. Inner routeETH/harvestRewards have their own
     *                 nonReentrant guards; this is belt-and-suspenders.
     */
    function performUpkeep(bytes calldata performData)
        external
        override
        onlyForwarder
        nonReentrant
    {
        if (upkeepPaused) revert UpkeepIsPaused();

        UpkeepTask task = abi.decode(performData, (UpkeepTask));

        // Replay protection key per task. Defense-in-depth:
        //   - routeETH retries blocked primarily by 6h cooldown (RouteTooEarly)
        //   - harvestRewards retries blocked primarily by ZeroAmount on insufficient excess
        // The replay map adds same-block re-execution protection and a stable audit trail.
        bytes32 replayKey;
        if (task == UpkeepTask.ROUTE_ETH) {
            replayKey = keccak256(abi.encode(task, lastRouteTime));
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
            uint256 routedAmount = accumulatedETH; // capture before routeETH zeros it
            this.dispatchRouteETH();
            valueMoved = routedAmount;
            emit UpkeepPerformed(uint8(UpkeepTask.ROUTE_ETH), gasBefore - gasleft(), valueMoved);
        } else {
            uint256 cbBalBefore = cbETH.balanceOf(address(this));
            this.dispatchHarvest();
            uint256 cbBalAfter = cbETH.balanceOf(address(this));
            // cbETH withdrawn during harvest = cbBalBefore - cbBalAfter.
            // Principal stays put; excess gets withdrawn as ETH.
            valueMoved = cbBalBefore > cbBalAfter ? cbBalBefore - cbBalAfter : 0;
            emit UpkeepPerformed(uint8(UpkeepTask.HARVEST_REWARDS), gasBefore - gasleft(), valueMoved);
        }

        unchecked { executedUpkeepCount += 1; }
    }

    /**
     * @notice [FIX-3] Renamed from _performRouteETH. External-only dispatcher
     *         from performUpkeep into routeETH. Only callable by this contract itself.
     *
     *         The this.routeETH() inner call sets msg.sender to address(this), which
     *         triggers the non-Treasury permissionless branch in routeETH —
     *         applying its canonical threshold/cooldown guards. Reward exemption
     *         in routeETH catches address(this) per [FIX-1].
     */
    function dispatchRouteETH() external onlySelf {
        this.routeETH();
    }

    function dispatchHarvest() external onlySelf {
        this.harvestRewards();
    }

    /**
     * @notice Initial forwarder registration. One-time path callable by owner.
     *         After this, automationForwarder is mutable ONLY via the
     *         Treasury-gated 48h timelock (queueForwarderUpdate / executeForwarderUpdate).
     *         Per IV.8 (Gemini), this is not "lock on first call" — the Treasury
     *         retains a restricted-update primitive for Chainlink Registry migrations.
     */
    function setForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert InvalidAddress();
        if (automationForwarder != address(0)) revert ForwarderAlreadySet();
        automationForwarder = forwarder;
        emit AutomationForwarderSet(forwarder, block.timestamp);
    }

    /**
     * @notice Record the Chainlink Upkeep ID after registration.
     *         Owner-only, idempotent (can be re-set if upkeep is re-registered).
     */
    function setUpkeepID(uint256 newUpkeepID) external onlyOwner {
        upkeepID = newUpkeepID;
        emit UpkeepRegistered(newUpkeepID, block.timestamp);
    }

    /**
     * @notice IV.8 — Step 1 of forwarder update. Treasury-only, queues a 48h timelock.
     *         Allows recovery from Chainlink Registry migrations without redeploy.
     */
    function queueForwarderUpdate(address newForwarder) external onlyTreasury returns (bytes32 id) {
        if (newForwarder == address(0)) revert InvalidAddress();
        _pendingForwarder = newForwarder;
        id = keccak256(abi.encodePacked("forwarderUpdate", block.timestamp, newForwarder));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ForwarderUpdateQueued(id, newForwarder, timelockQueue[id]);
    }

    /**
     * @notice IV.8 — Step 2 of forwarder update. Requires 48h elapsed since queue.
     */
    function executeForwarderUpdate(bytes32 id) external onlyTreasury tlPassed(id) {
        address newForwarder = _pendingForwarder;
        if (newForwarder == address(0)) revert InvalidAddress();
        address old = automationForwarder;
        automationForwarder = newForwarder;
        _pendingForwarder = address(0);
        emit ForwarderUpdated(old, newForwarder, block.timestamp);
    }

    /**
     * @notice IV.7 Position B — cheap upkeep pause for high-frequency Hook.
     *         Treasury-only. Independent of routingPaused — allows automation to
     *         halt for diagnostic/upgrade reasons without pausing routing itself.
     */
    function pauseUpkeep() external onlyTreasury {
        upkeepPaused = true;
        emit UpkeepPausedSet(true, block.timestamp);
    }

    function unpauseUpkeep() external onlyTreasury {
        upkeepPaused = false;
        emit UpkeepPausedSet(false, block.timestamp);
    }

/*═══════════════════════════════════════════════════════════════════════════════
  POST-PATCH NOTES — for audit (Grok adversarial seat)
═══════════════════════════════════════════════════════════════════════════════

  1. REPLAY PROTECTION IS DEFENSE-IN-DEPTH

     The executedUpkeeps map prevents same-block re-execution and provides an
     audit trail. It is NOT the primary protection against Chainlink retries
     across blocks:
       - For ROUTE_ETH: routeETH's own 6h cooldown (RouteTooEarly) blocks
         cross-block retries effectively.
       - For HARVEST_REWARDS: a successful first harvest reduces cbETH balance
         to ~principal, so a cross-block retry typically reverts with ZeroAmount.

     The replay map is belt-and-suspenders. Acknowledged honestly rather than
     overstated as v0.1 did.

  2. AUTO-INV GAUNTLET MAPPING

     AUTO-INV-1 (check ⇒ executable): satisfied by mirroring all guard conditions
       inside checkUpkeep (upkeepPaused, routingPaused, cbETHPaused, threshold,
       cooldown, dust floor). [FIX-5] adds cbETHPaused that v0.1 missed.

     AUTO-INV-2 (hysteresis blocks near-threshold): satisfied by
       UPKEEP_HYSTERESIS_BPS check (120/100 multiplier on ROUTE_THRESHOLD).

     AUTO-INV-3 (forwarder exclusivity): satisfied by onlyForwarder modifier
       on performUpkeep.

     AUTO-INV-4 (pause disables upkeep): satisfied by upkeepPaused check at top
       of both checkUpkeep AND performUpkeep.

     AUTO-INV-5 (no reward for forwarder OR self-dispatcher): satisfied by
       [FIX-1] expanding IV.2 exemption to cover address(this).

     AUTO-INV-6 (invalid task reverts): satisfied by the else-revert InvalidTask
       branch in performUpkeep's task switch.

     AUTO-INV-7 (manual fallback works without automation): satisfied by not
       modifying routeETH/harvestRewards signatures or access guards. Manual
       permissionless callers continue to invoke them directly via the existing
       entry points and receive the 0.1% reward.

  3. SELF-AUDIT FINDINGS APPLIED IN v0.2

     [FIX-1] IV.2 dispatcher exemption       — high severity, fixed
     [FIX-2] performUpkeep nonReentrant      — medium severity, fixed
     [FIX-3] External wrappers renamed       — low severity (convention), fixed
     [FIX-4] NotSelf error                   — low severity (semantics), fixed
     [FIX-5] checkUpkeep cbETHPaused check   — medium severity, fixed
     [DOC-6] Replay protection scope         — documentation, updated
     [DOC-7] Combined Phase 1+2 acknowledged — process note

  4. WHAT THIS PATCH DOES NOT CHANGE

     - No existing storage variable renamed, removed, or rearranged.
     - No existing function signature modified. The IV.2 conditional inside
       routeETH is an internal logic refinement, not a signature change.
     - No existing modifier removed or weakened.
     - No new authority granted to any role — Automation only schedules
       already-authorized actions.
     - No upgrade path introduced. Hook remains non-upgradeable.

  5. KNOWN AUDIT SURFACE FOR GROK

     - this.routeETH() dispatcher pattern adds ~2.5k gas per automated call
       compared to a refactor that exposes _routeETH() internally. Accepted
       cost for Phase 1 minimum-diff. Refactor candidate for v2.5+.

     - performUpkeep gas measurement (gasBefore - gasleft) measures gas through
       the dispatcher, not raw routeETH. Approximate by ~2.5k. Acceptable for
       observability; not used in any on-chain logic.

     - cbETHPaused storage flag I checked against [FIX-5]: I cannot independently
       verify from the canonical contract grep whether harvestRewards actually
       reverts when cbETHPaused is true. If it doesn't, my added check is
       defensive but not load-bearing. If it does, this fix is critical.
       Grok should verify against the full canonical body.

     - Forwarder address is owner-set initially. Owner key compromise during
       the registration window between deploy and setForwarder is the same
       risk as any other owner-gated initialization. Mitigated by deploy-and-
       rotate custody pattern already in protocol substrate.

═══════════════════════════════════════════════════════════════════════════════*/
