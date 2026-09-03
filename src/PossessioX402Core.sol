// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SymmetryGuardCore} from "./SymmetryGuardCore.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
            POSSESSIO x402 CORE - FOUNDATION SKELETON
                         v0.6 - 2026-06-30

  v0.6 (COUNCIL_0): applies four findings from the Sonnet-5 cold-seat
  audit of v0.5. The fixes are made here; RE-AUDIT goes to a cold seat
  (not this seat - the fixer does not certify the fix).

    FIX #1 - VALVE INTEGRITY NOW STRUCTURAL (the real one). v0.5's
      valve-by-omission was convention-dependent: nothing stopped
      deploymentFeeSource being set == operatorDestination or
      heartSink at deploy, which would let drawn funds be
      reinjected via receiveDeploymentFee - defeating "ingress
      structurally impossible" for that path. The constructor now
      reverts ValveIntegrityViolation if they collide. The guarantee
      holds for EVERY deployment with no reliance on deploy discipline.
      (Plus zero-address guards on all load-bearing destinations.)
      -> The valve claim is now what we said it was, not softer.

    FIX #2 - DEAD tollSink REMOVED. It was assigned, read nowhere
      (settleCall routes through the pool). An immutable named "Sink"
      that does nothing is auditor-bait; deleted entirely.

    FIX #3 - CEI CONSISTENCY in receiveDeploymentFee. Pool-balance
      effect now commits before the outbound surplus push, matching
      settleOperationalCosts. (Inbound pull is unavoidably first.)

    FIX #4 - DECAY DIRECTION VERIFIED (no code change). Linear
      interpolation over the partial half-life window overestimates
      decay (linear chord above the convex exp curve) -> errs toward a
      HIGHER floor -> safe direction, cannot under-floor the pool.
      Recorded in _decayedVelocity. Exact numbers still need the oracle
      mirror + fork proof before freeze.

  CARRIED FORWARD (out of scope, different contract): SymmetryGuardCore's
  DUST_SPAM_WINDOW / MIN_HITS / DUST_FLOOR immutable-constant calibration
  remains open before its own freeze.

  STILL PROPOSED - verify against builder repo + FORK TEST before trusting.
  This file goes BACK to a cold seat for re-audit of these four fixes.

  --- v0.5 / v0.4 / v0.3 history retained below ---

  v0.5 (COUNCIL_0): integrates Gemini's velocity-derived-floor CONCEPT
  (approved) but REIMPLEMENTED to fix four real flaws in his draft:
    1. ASSET CONSISTENCY: everything is USDC via safeTransfer. Gemini's
       draft mixed native ETH (msg.value / .call{value}) with USDC in one
       balance - would have broken accounting and failed on first call.
    2. REAL DECAY: velocity is a time-decayed rolling figure (half-life),
       not a monotonic counter with a 30-day cliff reset (which would
       inflate the floor to lock the pool, or cliff to open a drain).
    3. BOUND INFLOW: receiveDeploymentFee is bound to the immutable
       deploymentFeeSource (Gemini asserted this in a comment but the
       code let anyone call it - a general deposit door). USDC pull.
    4. NO MAGIC NUMBERS: floor params (ABSOLUTE_FLOOR, FLOOR_PER_UNIT,
       VELOCITY_HALFLIFE) are constructor-set + calibrate-before-freeze,
       not hardcoded constants.

  RESULT: ungameable floor (derived from throughput, operator can't lower
  it), deployment-fee inflow funds scaling, draw releases only the surplus
  above the live floor -> pool can never be drained below the running
  minimum, in every deployment.

  STILL PROPOSED - verify against builder repo + FORK TEST before trusting.
  The decay math is integer-approximate; mirror it in the Python oracle
  and prove it on a fork before freeze.

  --- v0.4 / v0.3 history retained below ---

  CHANGED FROM v0.2 (COUNCIL_0's two seams, with one correction):

  SEAM 1 - _expectedValue (ADOPTED AS PROPOSED):
    expectedValue = basePrice + (basePrice * tollBps) / 10_000
    Seller nets exactly basePrice; toll rides on top. This fixes a
    real latent bug in the v0.1/v0.2 split math: (value*tollBps)/10_000
    taxes the toll itself, under-paying the seller. Now corrected:
    tollValue = value - basePrice; netToSeller = basePrice.
    basePrice now needs a place to live -> channel registry, below.

  SEAM 2 - submitter model (PROPOSED bare-permissionless, CORRECTED here):
    COUNCIL_0's reasoning: EIP-3009's `to==address(this)` binding plus
    the exact-value check plus nonce-burn fully constrain any caller,
    so settleCall can be permissionless with no access control.
    THE GAP: `seller` is a plain function argument, NOT part of what
    the buyer's EIP-712 signature covers (EIP-3009's typed struct is
    only {from, to, value, validAfter, validBefore, nonce}). A
    permissionless caller can submit a valid intercepted signature
    with their OWN address as `seller` - tollValue still safely
    reaches tollSink, but netToSeller (the bulk of the payment) goes
    to the attacker, not the real seller. This is a theft vector as
    proposed, not a closed surface.

    FIX (grounded in the EIP-3009 issue thread's own suggestion: "the
    app developer could dedicate some leading bytes of the nonce...
    as the identifier to prevent cross-use"): the buyer's nonce is
    NOT random - it's a commitment the buyer computes off-chain at
    signing time: nonce = keccak256(seller, channelId, value, salt).
    settleCall recomputes that commitment and requires it to match
    the nonce actually in the signed authorization. Since EIP-3009's
    own signature check covers `nonce`, the buyer's signature now
    indirectly covers seller+channelId+value too. A permissionless
    submitter can no longer substitute `seller` without invalidating
    either the commitment check (here) or the EIP-712 signature
    (inside receiveWithAuthorization) - one of the two always fails.
    settleCall stays permissionless; the binding does the work
    access control would have, same as COUNCIL_0 intended, just
    actually closed.

  NEW: minimal first-claim channel registry (basePrice needs a home).
    First address to price a channelId owns it; only that address can
    reprice. Default convention, flagged as overridable - see TODO.
    Doubles as defense-in-depth: even a defeated nonce-commitment
    still has to pass `seller == channelSeller[channelId]`.

  KNOWN TENSION, worth fuzzing rather than fixing here: tollBps is
  read LIVE at settle-time via totalFeeBps, but the buyer signed
  `value` based on whatever tollBps the seller's 402 header quoted
  earlier. If guard state shifts between quote and settle (abuse
  accruing in that window), a legitimate payment can revert on
  AmountMismatch. Same shape as x402's documented verify/settle gap,
  just on the price axis instead of the delivery axis. Test the
  staleness window; don't silently widen the equality to a tolerance
  band without an explicit decision to do so.
//////////////////////////////////////////////////////////////*/

interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @notice The Heart (PossessioPool) — x402Core's surplus sink. Surplus over
///         the operating cap is routed here via the accounted door
///         (receiveInfraFunds), option A, exactly as the factory routes its
///         deployment fee. isInfraSink() is the brick-guard marker the
///         constructor verifies (identical to PossessioFactory's IPossessioPool).
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
    function isInfraSink() external view returns (bool);
    function isAuthorizedSource(address source) external view returns (bool);
}

contract PossessioX402Core is SymmetryGuardCore, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC3009 public immutable payToken;
    IERC20   public immutable payTokenERC20;

    /*//////////////////////////////////////////////////////////////
              SELF-FUNDING LOOP + ONE-WAY VALVE (Gemini, APPROVED)

      MERGED FROM Technical Authority's invention, audited clean:
        - Dual-sink immutability: both outbound destinations fixed at
          construction, never updatable. No arbitrary recipient.
        - Valve-by-omission (Problem 1): there is NO function anywhere
          in this contract that moves funds FROM heartSink or
          operatorDestination back into the settlement/trading path.
          Capital movement outward is push-only. Ingress to the trading
          seat is structurally impossible - enforced by ABSENCE, not a
          check. Audit confirmed: grep the contract for any transfer
          whose SOURCE is treasury/operator - there are none.
        - Cap-then-surplus fill (Problem 2, first half): toll accrues to
          operationalPoolBalance up to OPERATIONAL_CAP; the exact excess is
          routed one-way INTO THE HEART (receiveInfraFunds — feeSink=A, council
          2026-07-20) in the same tx. The Heart handles its own treasury sweep.

      NOT MERGED (the one open seam): settleOperationalCosts - the PAYOUT
      of the pool to cover infra cost. Gemini's last draw-to-balance
      version was REJECTED by the Architect ("theft of funds promised to
      a function"). The theft-of-purpose-bound version is pending from
      Technical Authority. See the marked stub below.
    //////////////////////////////////////////////////////////////*/

    /// @notice The Heart (PossessioPool) — x402Core's surplus sink. Surplus
    ///         over the cap is routed here via receiveInfraFunds (option A),
    ///         one-way. Immutable. Nothing in this contract can pull FROM it.
    ///         The Heart handles its own surplus→treasury sweep downstream, so
    ///         infra money flows INTO the Heart (feeSink=A philosophy) rather
    ///         than out to a raw treasury EOA. Verified as a live infra-sink at
    ///         construction (brick-guard) — same discipline as the factory.
    address public immutable heartSink;

    /// @notice Infrastructure operator (the datacenter/API fundee).
    ///         Immutable. The ONLY address operating-cost payout can reach.
    address public immutable operatorDestination;

    /// @notice The ONLY address permitted to push deployment fees into the
    ///         pool (the factory / deploy contract). Immutable. This is what
    ///         makes receiveDeploymentFee valve-safe instead of a general
    ///         deposit door - Gemini's draft asserted this in a comment but
    ///         did not enforce it; enforced here.
    address public immutable deploymentFeeSource;

    /// @notice Capped operating reserve. Toll fills this; surplus above it
    ///         is routed one-way into the Heart (heartSink). Immutable bound.
    uint256 public immutable OPERATIONAL_CAP;

    /// @notice One-time cost (payToken/USDC) to self-register via registerOpen.
    ///         The ROTATION TAX: settleCall gates on registered[caller], and a
    ///         fresh address gets a fresh (clean) guard slot - so escaping a
    ///         behavioural-fee reputation by hopping addresses must cost
    ///         something, or the open toll is trivially sybilled. Set to 0 for
    ///         a free-open deployment (registerOpen still works, no fee pulled);
    ///         any positive value is the tax. Immutable, per deployment.
    ///         "No signup" means no ACCOUNT, not no fee - registration is
    ///         accountless (EIP-3009), permissionless, and priced.
    uint256 public immutable REGISTRATION_FEE;

    /// @notice Live accounting of the self-funding pool (infra reserve).
    ///         Denominated in payToken (USDC). NEVER native ETH.
    uint256 public operationalPoolBalance;

    /// @notice Surplus over the operating cap routed into the Heart via the
    ///         accounted door (receiveInfraFunds), replacing the old raw
    ///         treasury sweep. The Heart credits its poolBalance and manages
    ///         any onward treasury sweep itself.
    event HeartSurplusRouted(uint256 amount);

    /// @notice Brick-guard: heartSink is not a live infra-sink (EOA, wrong
    ///         contract, or isInfraSink()==false). Same guard as the factory.
    error FeeSinkInterfaceMismatch();

    /*//////////////////////////////////////////////////////////////
        VELOCITY-DERIVED FLOOR (Gemini concept, APPROVED - reimplemented)

      The anti-drain floor is derived from on-chain settlement velocity,
      NOT operator config, so it cannot be gamed down to drain the pool.
      Traffic up -> floor up (protect the load). Traffic down -> floor
      decays -> surplus frees for scaling. Operator can never lower it.

      CORRECTED from Gemini's draft:
        - ALL USDC (payToken). No msg.value, no native ETH .call. The
          pool, inflows, and payouts are one asset. (Gemini's draft mixed
          ETH and USDC in one balance - broke the accounting.)
        - REAL time-decayed rolling window, not a monotonic counter with
          a 30-day cliff. The velocity figure decays continuously so the
          floor neither inflates unbounded (locking the pool) nor cliffs
          to zero (opening a drain window).
        - Floor params are constructor-set + bounded, not hardcoded
          magic numbers (same discipline as DUST_FLOOR - calibrate before
          freeze).

      Floor = ABSOLUTE_FLOOR + (decayedVelocity * FLOOR_PER_UNIT).
      Draw releases ONLY (poolBalance - floor), to the immutable operator.
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard immutable baseline the floor can never fall below.
    ///         Constructor-set; calibrate to real min running cost (USDC).
    uint256 public immutable ABSOLUTE_FLOOR;

    /// @notice USDC of required buffer added per unit of decayed velocity.
    ///         Constructor-set; calibrate before freeze.
    uint256 public immutable FLOOR_PER_UNIT;

    /// @notice Rolling-window half-life (seconds) for velocity decay.
    ///         Constructor-set. Velocity loses ~half its weight per window.
    uint256 public immutable VELOCITY_HALFLIFE;

    /// @notice Decayed settlement velocity (scaled 1e18 for fractional decay).
    uint256 public velocityScaled;

    /// @notice Timestamp of the last velocity update (for time-decay).
    uint256 public lastVelocityTs;

    event OperationalExpensesPaid(uint256 amount, address indexed operator);
    event DeploymentFeeReceived(address indexed from, uint256 amount);
    /// @notice A permissionless identity registered itself via registerOpen and
    ///         paid the rotation tax. Distinct from SymmetryGuardCore.Registered
    ///         (the merkle/allowlist path) so the two routes stay legible on-chain.
    event RegisteredOpen(address indexed caller, uint256 fee);

    error InsufficientOperationalFunds();
    error ExceedsDrawableSurplus(uint256 requested, uint256 drawable);
    error NotDeploymentFeeSource(address caller);

    /*//////////////////////////////////////////////////////////////
                          CHANNEL REGISTRY (NEW)

      Minimal first-claim model: setBasePrice claims an unowned
      channelId for msg.sender, or reprices one already owned by
      msg.sender. No claim fee, no admin gate - TODO flags whether
      that's the right default.
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => address) public channelSeller;
    mapping(bytes32 => uint256) public channelBasePrice;

    event ChannelPriced(bytes32 indexed channelId, address indexed seller, uint256 basePrice);

    error ChannelNotOwnedByCaller(bytes32 channelId, address currentOwner);
    error ChannelNotPriced(bytes32 channelId);

    function setBasePrice(bytes32 channelId, uint256 basePrice) external {
        address owner = channelSeller[channelId];
        if (owner == address(0)) {
            channelSeller[channelId] = msg.sender;
        } else if (owner != msg.sender) {
            revert ChannelNotOwnedByCaller(channelId, owner);
        }
        channelBasePrice[channelId] = basePrice;
        emit ChannelPriced(channelId, msg.sender, basePrice);
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CallSettled(
        address indexed caller,
        address indexed seller,
        bytes32 indexed channelId,
        uint256 grossValue,
        uint256 tollValue,
        uint256 netToSeller,
        uint256 tollBps,
        bytes32 nonce
    );

    error AmountMismatch(uint256 signed, uint256 expected);
    error CallerNotRegistered(address caller);
    /// @notice registerOpen called by an already-registered identity. Refused so
    ///         a second fee can never be charged, and so re-registration can
    ///         never be used as a reputation reset.
    error AlreadyRegistered(address caller);
    /// @notice registerOpen signed value != REGISTRATION_FEE. Exact equality
    ///         only - no tolerance band (same discipline as settleCall).
    error WrongRegistrationFee(uint256 signed, uint256 expected);
    error SellerMismatch(bytes32 channelId, address provided, address registered);
    error NonceCommitmentMismatch(bytes32 signedNonce, bytes32 expectedCommitment);
    error UnauthorizedCall();

    /// @notice v0.6 FIX #1 (Sonnet-5 audit): the valve-by-omission guarantee
    ///         was convention-dependent - nothing stopped deploymentFeeSource
    ///         from being set equal to operator/treasury at deploy, which would
    ///         let drawn funds be reinjected via receiveDeploymentFee, defeating
    ///         "ingress structurally impossible" for that path. Now structural.
    error ValveIntegrityViolation();
    error ZeroAddress();
    /// @notice X-H2 (re-audit 2026-09-01): the Heart is a live Pool but THIS
    ///         x402Core is not in its immutable source set — every surplus push
    ///         at the cap would revert forever. Caught at construction.
    error HeartSourceNotAuthorized();
    error FloorParamsInvalid();

    constructor(
        bytes32 root,
        uint256 dustFloor,
        address _payToken,
        address _heartSink,
        address _operatorDestination,
        address _deploymentFeeSource,
        uint256 _operationalCap,
        uint256 _absoluteFloor,
        uint256 _floorPerUnit,
        uint256 _velocityHalflife,
        uint256 _registrationFee
    ) SymmetryGuardCore(root, dustFloor) {
        // Zero-address guards on every load-bearing destination.
        if (
            _payToken == address(0) ||
            _heartSink == address(0) ||
            _operatorDestination == address(0) ||
            _deploymentFeeSource == address(0)
        ) revert ZeroAddress();

        // BRICK GUARD (council, mirrors PossessioFactory): heartSink must be a
        // LIVE contract implementing the accounted door (receiveInfraFunds),
        // marked by isInfraSink(). A code-length pre-check catches the EOA /
        // undeployed case (a high-level call to a no-code address reverts on
        // return-decode OUTSIDE try/catch); the try/catch then catches
        // has-code-but-wrong-contract and an explicit `false`. This makes the
        // surplus push CRITICAL yet safe — a bricked Heart cannot be wired in.
        // DEPLOY ORDER: the Heart must be live before x402Core (RUNBOOK: POOL →
        // x402Core → factory → saltPool). The Pool constructor does not require
        // its sources live, so Pool-first is sound.
        if (_heartSink.code.length == 0) revert FeeSinkInterfaceMismatch();
        try IPossessioPool(_heartSink).isInfraSink() returns (bool ok) {
            if (!ok) revert FeeSinkInterfaceMismatch();
        } catch {
            revert FeeSinkInterfaceMismatch();
        }
        // X-H2 (re-audit 2026-09-01): isInfraSink() proves the sink is a Pool;
        // it does not prove this x402Core is in the Pool's immutable source
        // set. A Pool that rejects us constructs clean and then reverts every
        // surplus push at the cap — a permanent dead x402Core. Prove the wiring
        // here (the Pool bakes our predicted CREATE3 address at ITS deploy).
        try IPossessioPool(_heartSink).isAuthorizedSource(address(this)) returns (bool authorized) {
            if (!authorized) revert HeartSourceNotAuthorized();
        } catch {
            revert FeeSinkInterfaceMismatch();
        }

        // FIX #1 - VALVE INTEGRITY, ENFORCED STRUCTURALLY (not by deploy discipline).
        // deploymentFeeSource is the ONLY inbound path to the pool. If it could
        // equal an OUTBOUND destination (operator/treasury), funds drawn out
        // could be pushed straight back in, defeating valve-by-omission. Forbid
        // it at construction so the guarantee holds for EVERY deployment, with
        // no reliance on the deployer wiring it correctly.
        //
        // INTENTIONAL OMISSION (cold-seat re-audit note): we deliberately do
        // NOT require heartSink != operatorDestination. Both are
        // OUTBOUND destinations; collapsing them to one address opens no ingress
        // path and is an allowed deployment shape. The absence of that check is
        // by design, not an oversight - do not add it.
        if (
            _deploymentFeeSource == _operatorDestination ||
            _deploymentFeeSource == _heartSink
        ) revert ValveIntegrityViolation();

        payToken = IERC3009(_payToken);
        payTokenERC20 = IERC20(_payToken);
        heartSink = _heartSink;
        operatorDestination = _operatorDestination;
        deploymentFeeSource = _deploymentFeeSource;
        // X-H1 / X-L3 (re-audit 2026-09-01): bounds the floor math relies on —
        // see getRunningMinimumFloor's draw-room invariant, and the
        // 2*VELOCITY_HALFLIFE term in _decayedVelocity.
        // X-H1 fresh-pass finding (re-audit, second pass): ABSOLUTE_FLOOR == 0
        // makes the draw-room guarantee vacuous (maxFloor collapses to the
        // full cap). Mirrors PossessioPool's identical guard.
        if (_absoluteFloor == 0) revert FloorParamsInvalid();
        if (_operationalCap < 2 * _absoluteFloor) revert FloorParamsInvalid();
        if (_velocityHalflife > type(uint128).max) revert FloorParamsInvalid();
        OPERATIONAL_CAP = _operationalCap;
        ABSOLUTE_FLOOR = _absoluteFloor;
        FLOOR_PER_UNIT = _floorPerUnit;
        VELOCITY_HALFLIFE = _velocityHalflife;
        REGISTRATION_FEE = _registrationFee;
        lastVelocityTs = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                         THE FOUNDATION SETTLE PATH

      Flow:
        1. registered(caller) - identity gate, read-only.
        2. Channel lookup: basePrice must exist; seller param must
           match the registry's current owner (defense-in-depth,
           catches stale/wrong 402 headers even before the nonce
           check runs).
        3. Price: expectedValue = basePrice + basePrice*tollBps/10_000.
           Exact equality against signed `value`. No tolerance band.
        4. Nonce-commitment check: nonce must equal
           keccak256(seller, channelId, value, salt) - buyer computed
           this at signing time, so the EIP-712 signature now covers
           seller+channelId+value indirectly. This is what makes
           permissionless submission safe.
        5. receiveWithAuthorization - front-run-closed, USDC lands here.
        6. Split: basePrice -> seller; toll -> operating pool (surplus
           over cap routed one-way into the Heart). Exact. (No tollSink.)
        7. _observe - DustSpam fed live; RoundTrip inert by construction.
    //////////////////////////////////////////////////////////////*/
    function settleCall(
        address caller,
        address seller,
        bytes32 channelId,
        bytes32 salt,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // 1. Identity gate.
        if (!registered[caller]) revert CallerNotRegistered(caller);

        // 2. Channel lookup + registry cross-check (defense-in-depth).
        uint256 basePrice = channelBasePrice[channelId];
        if (basePrice == 0) revert ChannelNotPriced(channelId);
        address registeredSeller = channelSeller[channelId];
        if (seller != registeredSeller) revert SellerMismatch(channelId, seller, registeredSeller);

        // 3. Price binding - exact equality, no underpay/overcharge.
        uint256 tollBps = totalFeeBps(caller, channelId);
        uint256 expectedValue = basePrice + (basePrice * tollBps) / 10_000;
        if (value != expectedValue) revert AmountMismatch(value, expectedValue);

        // 4. Nonce-commitment - this is what makes permissionless safe.
        //    Buyer chose nonce = this commitment at signing time; a
        //    submitter substituting `seller` breaks the match.
        bytes32 expectedCommitment = keccak256(abi.encode(seller, channelId, value, salt));
        if (nonce != expectedCommitment) revert NonceCommitmentMismatch(nonce, expectedCommitment);

        // 5. Front-run-closed settlement. msg.sender == to == address(this).
        payToken.receiveWithAuthorization(
            caller, address(this), value, validAfter, validBefore, nonce, v, r, s
        );

        // 6. Split - exact, post-fix. Seller nets exactly basePrice.
        //    Toll feeds the self-funding loop (Gemini, APPROVED), NOT a
        //    dead sink. CEI: state updated before the external surplus push.
        uint256 tollValue = value - basePrice;
        payTokenERC20.safeTransfer(seller, basePrice);

        // 6a. Accrue toll into the operating pool; route only the surplus
        //     above the immutable cap, one-way, INTO THE HEART via the
        //     accounted door (receiveInfraFunds — feeSink=A). There is NO path
        //     that moves funds the other direction (valve-by-omission). CEI:
        //     state committed before the external push; the brick-guard makes
        //     the critical push safe.
        if (tollValue > 0) {
            uint256 newBalance = operationalPoolBalance + tollValue;
            if (newBalance > OPERATIONAL_CAP) {
                uint256 surplus = newBalance - OPERATIONAL_CAP;
                operationalPoolBalance = OPERATIONAL_CAP;      // effects before interaction
                payTokenERC20.forceApprove(heartSink, surplus);
                IPossessioPool(heartSink).receiveInfraFunds(surplus);
                emit HeartSurplusRouted(surplus);
            } else {
                operationalPoolBalance = newBalance;
            }
        }

        // 7. Observe.
        _observe(caller, channelId, false, value);

        // 7a. Feed the velocity window (time-decayed) so the running-minimum
        //     floor tracks real settlement throughput. Decay-then-add.
        //     X-H1 dust gate (re-audit 2026-09-01): a settle below DUST_FLOOR
        //     is not throughput — 32 self-settles of 1 wei must not pin the
        //     floor at its cap (the cheapest door to the absorbing lock).
        if (value >= DUST_FLOOR) _bumpVelocity();

        emit CallSettled(caller, seller, channelId, value, tollValue, basePrice, tollBps, nonce);
    }

    /*//////////////////////////////////////////////////////////////
        VELOCITY FLOOR + DEPLOYMENT-FEE INFLOW + FLOORED DRAW

      Gemini's velocity-derived-floor concept, reimplemented correct:
        - USDC throughout (payTokenERC20.safeTransfer), never native ETH.
        - Real time-decayed rolling velocity (half-life decay), not a
          monotonic counter with a cliff reset.
        - Deployment-fee inflow BOUND to the immutable deploymentFeeSource
          and paid in USDC via pull (transferFrom), not an open payable.
        - Draw releases only (poolBalance - dynamicFloor) to the immutable
          operator. Floor is ungameable (derived from throughput), so the
          pool can never be drained below the live running minimum.
    //////////////////////////////////////////////////////////////*/

    /// @dev Decay the velocity figure by elapsed time (half-life), then
    ///      add one unit (1e18 scaled) for the settlement just processed.
    ///      Continuous decay - no cliff, no unbounded accumulation.
    function _bumpVelocity() internal {
        velocityScaled = _decayedVelocity();
        lastVelocityTs = block.timestamp;
        velocityScaled += 1e18; // one settlement, scaled
    }

    /// @notice Velocity decayed to the current timestamp (view-safe).
    /// @dev Approximate half-life decay: halve once per VELOCITY_HALFLIFE
    ///      elapsed, then linearly interpolate the partial window. Bounded
    ///      iteration (caps at ~256 halvings -> effectively zero) so it
    ///      can never gas-grief. Pure integer math, fork-mirrorable.
    ///
    ///      v0.6 NOTE (Sonnet-5 audit, FIX #4 - verified, no code change):
    ///      true exponential decay is CONVEX; a linear chord between the two
    ///      window endpoints always sits ABOVE the curve. So this linear
    ///      interpolation OVERESTIMATES decay's remaining value -> errs toward
    ///      a HIGHER floor -> the SAFE direction. It cannot be exploited to
    ///      under-floor the pool. Exact numbers still require the Python-oracle
    ///      mirror + fork proof before the immutable freeze; the DIRECTION of
    ///      the imprecision is now established as conservative.
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
    ///         Derived from decayed throughput - operator cannot lower it.
    /// @dev X-H1 (re-audit 2026-09-01) — DRAW-ROOM INVARIANT, mirrored from
    ///      PossessioPool: the velocity term is capped so the floor never
    ///      exceeds OPERATIONAL_CAP - ABSOLUTE_FLOOR. Without it, 32 settles
    ///      inside one decay window pinned floor >= cap and drawableSurplus
    ///      locked at 0 with no escape. Constructor requires CAP >= 2*FLOOR.
    function getRunningMinimumFloor() public view returns (uint256) {
        uint256 vUnits = _decayedVelocity() / 1e18; // back to whole units
        uint256 floor = ABSOLUTE_FLOOR + (vUnits * FLOOR_PER_UNIT);
        uint256 maxFloor = OPERATIONAL_CAP - ABSOLUTE_FLOOR;
        return floor > maxFloor ? maxFloor : floor;
    }

    /// @notice The surplus currently drawable above the floor, in USDC.
    function drawableSurplus() public view returns (uint256) {
        uint256 floor = getRunningMinimumFloor();
        if (operationalPoolBalance <= floor) return 0;
        return operationalPoolBalance - floor;
    }

    /// @notice Scoped, valve-safe deployment-fee inflow. USDC, pulled from
    ///         the immutable deploymentFeeSource only. NOT a general deposit
    ///         door - any other caller reverts. Funds the pool to capitalize
    ///         scaling; surplus over the cap routes one-way into the Heart.
    /// @dev    v0.6 FIX #3 (Sonnet-5 audit): CEI consistency. The inbound pull
    ///         is unavoidable (funds must be received before they can be
    ///         accounted), but the pool-balance EFFECT is now committed before
    ///         the OUTBOUND surplus interaction, matching settleOperationalCosts.
    /// @param amount USDC deployment fee to pull in.
    function receiveDeploymentFee(uint256 amount) external nonReentrant {
        if (msg.sender != deploymentFeeSource) revert NotDeploymentFeeSource(msg.sender);
        if (amount == 0) revert InsufficientOperationalFunds();

        // Inbound pull (unavoidably first - must receive before accounting).
        // Reentrancy-safe: nonReentrant guard + immutable, trusted source.
        payTokenERC20.safeTransferFrom(msg.sender, address(this), amount);

        // EFFECTS: settle pool accounting and compute any surplus FIRST.
        uint256 newBalance = operationalPoolBalance + amount;
        uint256 surplus;
        if (newBalance > OPERATIONAL_CAP) {
            surplus = newBalance - OPERATIONAL_CAP;
            operationalPoolBalance = OPERATIONAL_CAP;
        } else {
            operationalPoolBalance = newBalance;
        }
        emit DeploymentFeeReceived(msg.sender, amount);

        // INTERACTION: route surplus INTO THE HEART (receiveInfraFunds — option
        // A) AFTER state is committed. Brick-guard makes the critical push safe.
        if (surplus > 0) {
            payTokenERC20.forceApprove(heartSink, surplus);
            IPossessioPool(heartSink).receiveInfraFunds(surplus);
            emit HeartSurplusRouted(surplus);
        }
    }

    /*//////////////////////////////////////////////////////////////
        OPEN + PRICED REGISTRATION (the permissionless identity door)

      settleCall gates on registered[caller]. SymmetryGuardCore.register
      is the MERKLE path - a fixed allowlist committed at deploy, right
      for a private deployment, impossible for an open toll (a merkle
      root cannot admit an address that was not in the tree).

      This is the second path: anyone may register, paying REGISTRATION_FEE
      once. "No signup" means no ACCOUNT - so the pull is EIP-3009
      (receiveWithAuthorization), the same accountless, front-run-closed
      primitive settleCall uses. No approval, no prior interaction.

      WHY PRICED: a free-open door is trivially sybilled. A fresh address
      gets a fresh guard slot, so a bad behavioural-fee reputation could be
      shed for the cost of gas. The fee is the ROTATION TAX: N identities
      cost N * REGISTRATION_FEE. It does not gate honesty - it prices
      evasion.

      VALVE-SAFE: the fee moves ONLY toward the pool. This function has no
      outbound path to the registrant and opens no new inbound path to the
      Heart - it reuses the existing accounted door (receiveInfraFunds) for
      surplus, exactly as receiveDeploymentFee and settleCall's toll do.
      Nothing here can move funds OUT of the pool.

      The merkle path is untouched. A deployment may use either, both, or
      (with REGISTRATION_FEE = 0) free-open.
    //////////////////////////////////////////////////////////////*/

    /// @notice Register msg.sender permissionlessly by paying REGISTRATION_FEE.
    ///         One-time, exact-value, accountless. The signed authorization must
    ///         be for `value == REGISTRATION_FEE`, from msg.sender, to this
    ///         contract.
    /// @dev CEI ordering mirrors receiveDeploymentFee: pull, commit accounting
    ///      and the identity, THEN push any surplus into the Heart.
    /// @param value       Signed authorization amount. MUST equal REGISTRATION_FEE.
    /// @param validAfter  EIP-3009 window start.
    /// @param validBefore EIP-3009 window end.
    /// @param nonce       EIP-3009 nonce (burned by the token; replay-dead).
    function registerOpen(
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // 1. One identity, one charge. Also blocks re-registration being used
        //    as a reputation reset (guard slots are keyed on (sender, poolId)
        //    and are NOT touched here either way).
        if (registered[msg.sender]) revert AlreadyRegistered(msg.sender);

        // 2. Exact price. No tolerance band (settleCall discipline).
        if (value != REGISTRATION_FEE) revert WrongRegistrationFee(value, REGISTRATION_FEE);

        uint256 surplus;
        if (value > 0) {
            // 3. Front-run-closed pull. The authorization is bound to
            //    from == msg.sender and to == address(this), so no other
            //    submitter can consume it and it cannot register a third party.
            payToken.receiveWithAuthorization(
                msg.sender, address(this), value, validAfter, validBefore, nonce, v, r, s
            );

            // 4. EFFECTS: pool accounting first, surplus computed before any
            //    external interaction.
            uint256 newBalance = operationalPoolBalance + value;
            if (newBalance > OPERATIONAL_CAP) {
                surplus = newBalance - OPERATIONAL_CAP;
                operationalPoolBalance = OPERATIONAL_CAP;
            } else {
                operationalPoolBalance = newBalance;
            }
        }

        // 5. EFFECTS: grant the identity. Committed before the external push.
        registered[msg.sender] = true;
        emit RegisteredOpen(msg.sender, value);

        // 6. INTERACTION: route surplus INTO THE HEART via the accounted door,
        //    after state is committed. Brick-guard makes this push safe.
        if (surplus > 0) {
            payTokenERC20.forceApprove(heartSink, surplus);
            IPossessioPool(heartSink).receiveInfraFunds(surplus);
            emit HeartSurplusRouted(surplus);
        }
    }

    /// @notice Operating-cost / scaling draw to the IMMUTABLE operator only.
    ///         Releases at most the surplus above the live velocity floor.
    ///         The pool can NEVER be drawn below the running minimum, so a
    ///         one-call full-drain is structurally impossible, in every
    ///         deployment. USDC via safeTransfer. CEI ordering.
    /// @param amount Requested draw (operations + forward scaling capital).
    function settleOperationalCosts(uint256 amount) external nonReentrant {
        // Only the immutable operator can pull, and only TO itself.
        if (msg.sender != operatorDestination) revert UnauthorizedCall();

        uint256 floor = getRunningMinimumFloor();
        if (operationalPoolBalance <= floor) revert InsufficientOperationalFunds();

        uint256 surplus = operationalPoolBalance - floor;
        if (amount > surplus) revert ExceedsDrawableSurplus(amount, surplus);
        if (amount == 0) revert InsufficientOperationalFunds();

        // Effects before interaction.
        operationalPoolBalance -= amount;

        // USDC push to the immutable operator (caller == recipient).
        payTokenERC20.safeTransfer(operatorDestination, amount);

        emit OperationalExpensesPaid(amount, operatorDestination);
    }

    /*//////////////////////////////////////////////////////////////
        STILL OPEN - architect decision, not guessed here:
          - Channel registry governance: is first-claim the right
            default, or should claiming require a fee / admin
            approval / be tied to the seller's own on-chain identity
            (e.g. registered() status)? Currently anyone can claim
            any unclaimed channelId.
          - Reprice cooldown: owner can change basePrice instantly,
            mid-flight against any already-signed-but-unsettled
            buyer authorization (which would now simply revert on
            AmountMismatch rather than settle wrong - safe, but
            worth deciding if that's the desired UX).
          - salt: caller-supplied, not validated for uniqueness
            beyond what EIP-3009's own nonce-burn provides. Confirm
            this is sufficient or if salt needs its own scoping.
    //////////////////////////////////////////////////////////////*/
}

/*//////////////////////////////////////////////////////////////
                    DEFINITION OF DONE (forge-proven)

   1. settleCall settles a valid EIP-3009 auth; seller nets exactly
      basePrice, the toll (value-basePrice) accrues to the operating
      pool (or surplus to treasury), for tollBps in [200..500].
   2. FRONT-RUN CLOSED: an auth signed to==this cannot be settled by
      any other submitter path.
   3. SELLER-SUBSTITUTION CLOSED (NEW - the actual gap this version
      fixes): a permissionless caller cannot settle a valid signed
      authorization while substituting their own address as `seller`.
      Must revert (either NonceCommitmentMismatch or signature
      failure inside receiveWithAuthorization).
   4. CEILING INVARIANT (fuzz): totalFeeBps never exceeds
      MAX_TOTAL_FEE_BPS regardless of channel/caller history.
   5. ROUND-TRIP INERT (fuzz): shapeHits stays 0 for any sequence.
   6. DUST-SPAM LIVE: repeated small-value settleCall calls correctly
      raise dustHits and feed totalFeeBps on the next quote.
   7. REGISTRATION GATE: unregistered caller reverts; rotation to a
      fresh address requires a fresh leaf/proof.
   8. AMOUNT BINDING: signed value disagreeing with expectedValue
      reverts. No tolerance band exists unless explicitly added.
   9. REPLAY: same nonce cannot settle twice.
  10. ATOMICITY: a forced-failing split/surplus transfer reverts the
      entire tx, no partial-funds state reachable.
  11. CHANNEL OWNERSHIP: setBasePrice reverts ChannelNotOwnedByCaller
      for a non-owner attempting to reprice an already-claimed channel.
  12. CODE-MATCHES-CLAIM: funds move only
      caller->this->{seller, operatingPool->treasurySurplus}. No other
      egress path exists.

   --- MERGED VALVE / LOOP (Gemini, APPROVED) ---
  13. POOL FILL: toll accrues to operationalPoolBalance up to
      OPERATIONAL_CAP exactly; balance never exceeds the cap.
  14. ONE-WAY SURPLUS (fuzz): any settlement pushing the pool over the
      cap routes the EXACT overflow into the Heart (heartSink) via
      receiveInfraFunds, atomically, and never more or less.
  15. VALVE-BY-OMISSION (static + fuzz): NO function moves funds whose
      SOURCE is heartSink or operatorDestination back into
      settlement/pool. Prove by inspection (absence) AND fuzz an
      arbitrary caller with infinite allowance cannot raise
      the pool or seller path. Ingress is structurally impossible.
  16. IMMUTABLE RECIPIENTS: heartSink and operatorDestination
      cannot be changed post-construction; no setter exists.

   --- OPERATING DRAW + VELOCITY FLOOR (v0.5, implemented) ---
  17. FLOORED DRAW: settleOperationalCosts releases AT MOST
      (operationalPoolBalance - getRunningMinimumFloor()) to the immutable
      operator; a request above that reverts ExceedsDrawableSurplus. The
      pool can NEVER be drawn below the floor - full-drain impossible.
  18. UNGAMEABLE FLOOR (fuzz): getRunningMinimumFloor() is derived only
      from decayed settlement velocity + immutable params. No caller,
      including the operator, can lower it by any call sequence. Prove the
      operator cannot manipulate velocity downward to widen the draw.
  19. DECAY CORRECTNESS (fuzz + oracle): _decayedVelocity() halves once
      per VELOCITY_HALFLIFE, interpolates the partial window, monotonically
      decreases with elapsed time, never underflows, never exceeds the
      pre-decay value, returns 0 past ~128 half-lives. Mirror in Python.
  20. DEPLOYMENT-FEE BOUND: receiveDeploymentFee reverts NotDeploymentFeeSource
      for ANY caller except the immutable deploymentFeeSource. It is not a
      general deposit door. USDC pulled via transferFrom; surplus over cap
      routes one-way into the Heart (receiveInfraFunds).
  21. DRAW ASSET = USDC: settleOperationalCosts and receiveDeploymentFee
      move USDC via safeTransfer/safeTransferFrom only. No native ETH path
      exists anywhere (no msg.value, no .call{value}).

   --- v0.6 FIXES (Sonnet-5 audit - RE-AUDIT THESE, cold seat) ---
  23. VALVE INTEGRITY STRUCTURAL: constructor reverts ValveIntegrityViolation
      if deploymentFeeSource == operatorDestination OR == heartSink.
      Prove no deploy config can wire the inbound fee path to an outbound
      destination (which would let drawn funds be reinjected). Also: every
      load-bearing address reverts ZeroAddress if zero at construction.
  24. HEART BRICK-GUARD (council 2026-07-20): constructor reverts
      FeeSinkInterfaceMismatch if heartSink is an EOA, a non-infra-sink
      contract, or isInfraSink()==false — so the critical surplus push into
      the Heart can never brick. Requires the Heart live at construction
      (deploy order POOL → x402Core → factory → saltPool).
  24. tollSink GONE: no declaration, no param, no reference anywhere. Grep
      must return zero hits. Confirm nothing dangling references it.
  25. CEI IN receiveDeploymentFee: pool-balance effect commits before the
      outbound surplus transfer (matches settleOperationalCosts). Prove no
      reachable reentrancy/partial-state even if the trusted source misbehaves.
  26. DECAY ERRS HIGH: confirm linear interpolation overestimates remaining
      velocity vs true exponential (errs toward higher floor = safe). Mirror
      in the Python oracle; the magnitude still needs fork proof, the
      DIRECTION is the claim to re-verify.

   --- OPEN, BLOCKS FREEZE ---
  22. FLOOR PARAM CALIBRATION (deploy-time): ABSOLUTE_FLOOR, FLOOR_PER_UNIT,
      VELOCITY_HALFLIFE, OPERATIONAL_CAP, DEPLOYMENT_FEE, and dustFloor must
      all be calibrated to real USDC operating-cost + API-payment data before
      the immutable freeze. Code is ready; the NUMBERS are data-gated.

   NON-PROVEN until defined: floor param values (#22); channel registry
   governance (first-claim vs. gated); reprice cooldown; quote/settle
   staleness window (lock vs. re-sign). The decay math is integer-approximate
   - fork-prove before freeze.
//////////////////////////////////////////////////////////////*/
