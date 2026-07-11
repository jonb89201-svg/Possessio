// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                    POSSESSIO POOL - THE HEART
                 v0.1 - built to SPEC_PossessioPool.md

  The standalone economic pool. Every organ's fee inflow ("pool
  infrastructure funds") lands in ONE fungible balance at ONE
  address; the velocity floor keeps the running infrastructure
  (datacenter + APIs) funded; ONLY the surplus above the floor
  draws one-way to the immutable operator for operations +
  scaling. Fees in -> floor kept -> surplus out. One direction.

  THIS IS A RELOCATION, NOT AN INVENTION. Every load-bearing
  mechanism is lifted from PossessioX402Core v0.6 (Sonnet-5
  audited, four fixes applied), with exactly ONE generalization:

    x402Core v0.6                     PossessioPool v0.1
    -----------------------------     ---------------------------
    operationalPoolBalance            poolBalance
    receiveDeploymentFee, bound to    receiveInfraFunds, bound to
      ONE deploymentFeeSource           a SET of authorizedSources
    valve guard: source != operator   valve guard: EVERY source !=
      && source != treasury             operator && != treasury
    settleOperationalCosts            unchanged (verbatim)
    velocity floor + decay            unchanged (verbatim)
    cap-then-surplus sweep            unchanged (verbatim)
    CEI ordering (v0.6 FIX #3)        unchanged (verbatim)

  AUTHORIZED-SOURCE SET IS IMMUTABLE AT CONSTRUCTION (SPEC §2
  flag, resolved to the honest default): the set of organs is
  fixed at deploy, no admin surface, no setter - matching the
  immutable-destination discipline everywhere else. Adding an
  organ later = redeploy the pool. NOTE the sequencing this
  implies: deploy the pool AFTER the organ addresses are known.
  The factory may be authorized at construction even though its
  feeSink->receiveInfraFunds upgrade lands later ("we fix factory
  later with our upgrade" - Architect) - authorization does not
  require the organ to call yet, it only permits it when ready.

  ASSET DISCIPLINE (load-bearing, from x402 v0.5 fix #1): USDC
  only, via SafeERC20. NO msg.value, NO native ETH, NO
  .call{value:} anywhere in this contract. One asset, one balance.

  STILL PROPOSED - NON-PROVEN until forge says so. See
  PossessioPool.t.sol DoD suite (SPEC §9, 14 items). Fork-prove
  against Base. COLD-SEAT re-audit before ratification - the seat
  that wrote this does not certify it.

  FLOOR PARAMS ARE SOFT until the fork test produces real
  throughput/cost data (DoD #22 discipline inherited from x402).
  Constructor takes them; calibrate to the real recurring
  infrastructure burn AFTER the fork run, BEFORE immutable freeze.
//////////////////////////////////////////////////////////////*/

contract PossessioPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error EmptySourceSet();
    /// @notice An inflow source may never be an outflow destination.
    ///         Structural, checked per-source at construction
    ///         (generalizes x402Core v0.6 FIX #1).
    error ValveIntegrityViolation();
    /// @notice A source appears twice in the constructor set. Duplicates
    ///         are deploy-config mistakes; refuse to exist rather than
    ///         silently collapse them.
    error DuplicateSource(address source);
    error NotAuthorizedSource(address caller);
    error ZeroAmount();
    error InsufficientOperationalFunds();
    error ExceedsDrawableSurplus(uint256 requested, uint256 drawable);

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event InfraFundsReceived(address indexed from, uint256 amount);
    event TreasurySurplusSwept(uint256 amount);
    event OperationalExpensesPaid(uint256 amount, address indexed operator);

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC. All inflow, accounting, and payout in this one asset.
    IERC20 public immutable payTokenERC20;

    /// @notice Sovereign treasury - absolute one-way outflow destination
    ///         for surplus over the cap. Immutable. Nothing in this
    ///         contract can pull FROM it. (Lifted: x402Core line 184.)
    address public immutable treasuryDestination;

    /// @notice Infrastructure operator (the datacenter/API fundee). The
    ///         ONLY address the operating-cost draw can reach. Immutable.
    ///         (Lifted: x402Core line 188.)
    address public immutable operatorDestination;

    /// @notice Capped operating reserve. Inflow fills to this; the exact
    ///         excess is forced one-way to treasuryDestination in the
    ///         same tx. Immutable bound. (Lifted: x402Core line 199.)
    uint256 public immutable OPERATIONAL_CAP;

    /// @notice Hard immutable baseline the floor can never fall below.
    ///         SOFT until fork data; calibrate to the real minimum
    ///         running cost of the infrastructure (USDC) before freeze.
    uint256 public immutable ABSOLUTE_FLOOR;

    /// @notice USDC of required buffer added per unit of decayed
    ///         inflow velocity. Calibrate before freeze.
    uint256 public immutable FLOOR_PER_UNIT;

    /// @notice Rolling-window half-life (seconds) for velocity decay.
    ///         Velocity loses ~half its weight per window.
    uint256 public immutable VELOCITY_HALFLIFE;

    /*//////////////////////////////////////////////////////////////
                    BOUND INFLOW SET (the generalization)

      x402Core bound its single inflow to ONE immutable address
      (deploymentFeeSource). The shared pool serves many organs:
      x402 tolls, factory deploy fees, future PITI / whisky hooks.
      The set is written ONCE at construction into an immutable-in-
      practice mapping (no setter exists, no admin role exists) and
      every member is valve-checked against both outflow
      destinations. NOT a general deposit door: any caller outside
      the set reverts. (Generalizes: x402Core DoD #20.)
    //////////////////////////////////////////////////////////////*/

    /// @notice True only for addresses authorized at construction to
    ///         push infrastructure funds in. No setter exists.
    mapping(address => bool) public isAuthorizedSource;

    /// @notice The full authorized set, stored for legibility/audit
    ///         (matches the constructor array; never mutated).
    address[] public authorizedSources;

    /*//////////////////////////////////////////////////////////////
                            POOL STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Live accounting of the shared self-funding pool
    ///         (infrastructure reserve). Denominated in USDC. NEVER
    ///         native ETH. One fungible balance for ALL organs -
    ///         Architect-ratified. (Was: operationalPoolBalance.)
    uint256 public poolBalance;

    /// @notice Decayed inflow velocity (scaled 1e18 for fractional decay).
    uint256 public velocityScaled;

    /// @notice Timestamp of the last velocity update (for time-decay).
    uint256 public lastVelocityTs;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _payToken           USDC address.
    /// @param _authorizedSources  The bound inflow set (organs). Fixed
    ///                            forever at construction.
    /// @param _operatorDestination Infra operator - only draw target.
    /// @param _treasuryDestination One-way surplus sink.
    /// @param _operationalCap     OPERATIONAL_CAP (USDC, 6 decimals).
    /// @param _absoluteFloor      ABSOLUTE_FLOOR (soft until fork data).
    /// @param _floorPerUnit       FLOOR_PER_UNIT.
    /// @param _velocityHalflife   VELOCITY_HALFLIFE (seconds).
    constructor(
        address _payToken,
        address[] memory _authorizedSources,
        address _operatorDestination,
        address _treasuryDestination,
        uint256 _operationalCap,
        uint256 _absoluteFloor,
        uint256 _floorPerUnit,
        uint256 _velocityHalflife
    ) {
        // Zero-address guards on every load-bearing destination.
        if (
            _payToken == address(0) ||
            _treasuryDestination == address(0) ||
            _operatorDestination == address(0)
        ) revert ZeroAddress();

        if (_authorizedSources.length == 0) revert EmptySourceSet();

        // VALVE INTEGRITY, ENFORCED STRUCTURALLY, PER SOURCE
        // (generalizes x402Core v0.6 FIX #1 from one source to the set).
        // The authorized sources are the ONLY inbound paths to the pool.
        // If ANY of them could equal an OUTBOUND destination
        // (operator/treasury), funds drawn out could be pushed straight
        // back in, defeating valve-by-omission. Forbid it at
        // construction so the guarantee holds for EVERY deployment,
        // with no reliance on the deployer wiring it correctly.
        //
        // INTENTIONAL OMISSION (carried verbatim from x402Core v0.6 -
        // cold-seat re-audit note): we deliberately do NOT require
        // treasuryDestination != operatorDestination. Both are OUTBOUND
        // destinations; collapsing them to one address opens no ingress
        // path and is an allowed deployment shape. The absence of that
        // check is by design, not an oversight - do not add it.
        uint256 n = _authorizedSources.length;
        for (uint256 i = 0; i < n; ++i) {
            address src = _authorizedSources[i];
            if (src == address(0)) revert ZeroAddress();
            if (src == _operatorDestination || src == _treasuryDestination) {
                revert ValveIntegrityViolation();
            }
            if (isAuthorizedSource[src]) revert DuplicateSource(src);
            isAuthorizedSource[src] = true;
            authorizedSources.push(src);
        }

        payTokenERC20 = IERC20(_payToken);
        treasuryDestination = _treasuryDestination;
        operatorDestination = _operatorDestination;
        OPERATIONAL_CAP = _operationalCap;
        ABSOLUTE_FLOOR = _absoluteFloor;
        FLOOR_PER_UNIT = _floorPerUnit;
        VELOCITY_HALFLIFE = _velocityHalflife;
        lastVelocityTs = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                    BOUND INFLOW (the organs feed here)

      Lifted from x402Core receiveDeploymentFee (v0.6, lines
      531-555) with the source check widened from == one immutable
      to set membership. Same pull, same CEI (v0.6 FIX #3), same
      cap-then-surplus sweep, same events shape.
    //////////////////////////////////////////////////////////////*/

    /// @notice Scoped, valve-safe infrastructure-fund inflow. USDC,
    ///         pulled from an authorized organ only. NOT a general
    ///         deposit door - any other caller reverts. Fills the pool
    ///         to the cap; the exact excess pushes one-way to treasury.
    /// @dev    CEI (x402Core v0.6 FIX #3): the inbound pull is
    ///         unavoidably first (funds must be received before they
    ///         can be accounted), but the pool-balance EFFECT and the
    ///         surplus computation commit BEFORE the outbound surplus
    ///         interaction, matching settleOperationalCosts.
    ///         Each inflow bumps the velocity window: the floor tracks
    ///         real infrastructure-funding throughput (the analog of
    ///         x402's per-settlement bump).
    /// @param amount USDC infrastructure funds to pull in. Caller must
    ///        have approved this pool for at least `amount`.
    function receiveInfraFunds(uint256 amount) external nonReentrant {
        if (!isAuthorizedSource[msg.sender]) revert NotAuthorizedSource(msg.sender);
        if (amount == 0) revert ZeroAmount();

        // Inbound pull (unavoidably first - must receive before
        // accounting). Reentrancy-safe: nonReentrant + authorized,
        // valve-checked source.
        payTokenERC20.safeTransferFrom(msg.sender, address(this), amount);

        // EFFECTS: settle pool accounting and compute any surplus FIRST.
        uint256 newBalance = poolBalance + amount;
        uint256 surplus;
        if (newBalance > OPERATIONAL_CAP) {
            surplus = newBalance - OPERATIONAL_CAP;
            poolBalance = OPERATIONAL_CAP;
        } else {
            poolBalance = newBalance;
        }

        // Feed the velocity window (decay-then-add) so the running-
        // minimum floor tracks real inflow throughput.
        _bumpVelocity();

        emit InfraFundsReceived(msg.sender, amount);

        // INTERACTION: outbound surplus push AFTER state is committed.
        if (surplus > 0) {
            payTokenERC20.safeTransfer(treasuryDestination, surplus);
            emit TreasurySurplusSwept(surplus);
        }
    }

    /*//////////////////////////////////////////////////////////////
              VELOCITY FLOOR (lifted verbatim, x402Core v0.5/v0.6)

      The anti-drain floor is derived from on-chain inflow velocity,
      NOT operator config, so it cannot be gamed down to drain the
      pool. Traffic up -> floor up (protect the load). Traffic down
      -> floor decays -> surplus frees for scaling. The operator can
      never lower it.
    //////////////////////////////////////////////////////////////*/

    /// @dev Decay the velocity figure by elapsed time (half-life), then
    ///      add one unit (1e18 scaled) for the inflow just processed.
    ///      Continuous decay - no cliff, no unbounded accumulation.
    ///      (Lifted verbatim: x402Core lines 469-473.)
    function _bumpVelocity() internal {
        velocityScaled = _decayedVelocity();
        lastVelocityTs = block.timestamp;
        velocityScaled += 1e18; // one inflow event, scaled
    }

    /// @notice Velocity decayed to the current timestamp (view-safe).
    /// @dev Approximate half-life decay: halve once per VELOCITY_HALFLIFE
    ///      elapsed, then linearly interpolate the partial window. Bounded
    ///      iteration so it can never gas-grief. Pure integer math,
    ///      fork-mirrorable. (Lifted verbatim: x402Core lines 489-506.)
    ///
    ///      DECAY DIRECTION (x402Core v0.6 FIX #4, verified): true
    ///      exponential decay is CONVEX; the linear chord between window
    ///      endpoints sits ABOVE the curve, so this OVERESTIMATES decay's
    ///      remaining value -> errs toward a HIGHER floor -> the SAFE
    ///      direction. Cannot be exploited to under-floor the pool.
    ///      Exact numbers still require the Python-oracle mirror + fork
    ///      proof before the immutable freeze.
    function _decayedVelocity() internal view returns (uint256) {
        uint256 v = velocityScaled;
        if (v == 0) return 0;
        uint256 dt = block.timestamp - lastVelocityTs;
        if (dt == 0 || VELOCITY_HALFLIFE == 0) return v;

        uint256 halvings = dt / VELOCITY_HALFLIFE;
        if (halvings >= 128) return 0; // fully decayed; avoid underflow/gas
        v >>= halvings; // halve once per full half-life

        // linear interpolation across the partial window remainder
        uint256 rem = dt % VELOCITY_HALFLIFE;
        if (rem > 0 && v > 0) {
            // decay the fractional window: v -= v * rem / (2*halflife)
            v -= (v * rem) / (2 * VELOCITY_HALFLIFE);
        }
        return v;
    }

    /// @notice The current ungameable running-minimum floor, in USDC.
    ///         Derived from decayed throughput - the operator cannot
    ///         lower it. (Lifted verbatim: x402Core lines 510-513.)
    function getRunningMinimumFloor() public view returns (uint256) {
        uint256 vUnits = _decayedVelocity() / 1e18; // back to whole units
        return ABSOLUTE_FLOOR + (vUnits * FLOOR_PER_UNIT);
    }

    /// @notice The surplus currently drawable above the floor, in USDC.
    ///         (Lifted verbatim: x402Core lines 516-520.)
    function drawableSurplus() public view returns (uint256) {
        uint256 floor = getRunningMinimumFloor();
        if (poolBalance <= floor) return 0;
        return poolBalance - floor;
    }

    /*//////////////////////////////////////////////////////////////
                THE ONLY OUTFLOW (lifted verbatim, x402Core v0.5)
    //////////////////////////////////////////////////////////////*/

    /// @notice Operating-cost / scaling draw to the IMMUTABLE operator
    ///         only. Releases at most the surplus above the live
    ///         velocity floor. The pool can NEVER be drawn below the
    ///         running minimum, so a one-call full-drain is structurally
    ///         impossible, in every deployment. USDC via safeTransfer.
    ///         CEI ordering. (Lifted verbatim: x402Core lines 563-581.)
    /// @param amount Requested draw (operations + forward scaling capital).
    function settleOperationalCosts(uint256 amount) external nonReentrant {
        // Only the immutable operator can pull, and only TO itself.
        if (msg.sender != operatorDestination) revert NotAuthorizedSource(msg.sender);

        uint256 floor = getRunningMinimumFloor();
        if (poolBalance <= floor) revert InsufficientOperationalFunds();

        uint256 surplus = poolBalance - floor;
        if (amount > surplus) revert ExceedsDrawableSurplus(amount, surplus);
        if (amount == 0) revert InsufficientOperationalFunds();

        // Effects before interaction.
        poolBalance -= amount;

        // USDC push to the immutable operator (caller == recipient).
        payTokenERC20.safeTransfer(operatorDestination, amount);

        emit OperationalExpensesPaid(amount, operatorDestination);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of authorized organs (for console/audit legibility).
    function authorizedSourceCount() external view returns (uint256) {
        return authorizedSources.length;
    }

    /*//////////////////////////////////////////////////////////////
        VALVE-BY-OMISSION (enforced by ABSENCE - audit by grep):
          - NO function moves funds whose SOURCE is treasuryDestination
            or operatorDestination back into the pool. There is no such
            function. Ingress from the outflow side is structurally
            impossible. (x402Core DoD #15, carried.)
          - NO setter exists for operator, treasury, or the source set.
            (x402Core DoD #16, carried + extended to the set.)
          - NO owner, NO admin role, NO DEFAULT_ADMIN. Nothing to seize.
          - NO receive(), NO fallback(), NO payable anywhere: native ETH
            cannot enter. Raw USDC transfers sent directly to this
            address are NOT credited to poolBalance (no sync function
            exists) - the bound inflow is the only accounting door.
    //////////////////////////////////////////////////////////////*/
}

/*//////////////////////////////////////////////////////////////
                DEFINITION OF DONE (forge-proven)
                 - see SPEC_PossessioPool.md §9 -

   1. BOUND INFLOW: receiveInfraFunds reverts NotAuthorizedSource
      for any caller not in the set; credits poolBalance for each
      authorized source. Not a general deposit door.
   2. MULTI-SOURCE FUNGIBLE: inflows from >=2 distinct authorized
      sources add to ONE poolBalance; draw computes on the total.
   3. POOL FILL / CAP: inflow fills to OPERATIONAL_CAP exactly;
      balance never exceeds cap.
   4. ONE-WAY SURPLUS (fuzz): any inflow over cap pushes the EXACT
      overflow to treasuryDestination, atomically, never more/less.
   5. FLOORED DRAW: settleOperationalCosts releases at most
      (poolBalance - getRunningMinimumFloor()) to the immutable
      operator; above that reverts ExceedsDrawableSurplus.
   6. UNGAMEABLE FLOOR (fuzz): floor derived only from decayed
      velocity + immutables; no caller (incl. operator) can lower
      it by any call sequence.
   7. DECAY CORRECTNESS (fuzz + oracle): halves per half-life,
      interpolates partial window, monotonic decreasing, no
      underflow, never exceeds pre-decay, 0 past ~128 half-lives.
      Mirror in the Python oracle (same oracle as x402 DoD #19).
   8. VALVE INTEGRITY STRUCTURAL: constructor reverts
      ValveIntegrityViolation if ANY source == operator or ==
      treasury; ZeroAddress on any zero; DuplicateSource on dupes;
      EmptySourceSet on [].
   9. VALVE-BY-OMISSION (static + fuzz): no function moves funds
      FROM treasury/operator into the pool; an arbitrary caller
      with infinite treasury/operator allowance cannot raise
      poolBalance.
  10. IMMUTABLE RECIPIENTS + SET: operator, treasury, and the
      source set cannot change post-construction; no setter exists.
  11. ASSET = USDC ONLY: all movement via safeTransfer/
      safeTransferFrom; no msg.value, no .call{value}, no payable,
      no receive/fallback (grep must return zero hits).
  12. CEI: receiveInfraFunds commits balance + surplus before the
      outbound surplus transfer; no reachable partial state even if
      a trusted source misbehaves.
  13. ATOMICITY: a forced-failing surplus transfer reverts the
      whole tx; no partial-funds state reachable.
  14. CODE-MATCHES-CLAIM: funds move only
      authorizedSource -> this -> {poolBalance up to cap,
      surplus -> treasury} and poolBalance -> operator (floored).
      No other egress exists. UNTRACKED raw transfers to this
      address are dead weight by design (no sync door) - confirm
      the DoD suite asserts they do NOT credit poolBalance.

   NON-PROVEN until PossessioPool.t.sol runs green. Fork-prove on
   Base. Floor params soft until fork data (then calibrate, then
   freeze). COLD-SEAT RE-AUDIT before ratification.
//////////////////////////////////////////////////////////////*/
