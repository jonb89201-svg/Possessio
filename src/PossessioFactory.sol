// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                      POSSESSIO FACTORY
                 v0.1 - built to council spec
                 (SPEC_PossessioFactory.md)

  One factory per template tier. Each factory hardcodes ITS tier's
  price as an immutable DEPLOYMENT_FEE and pins ITS template by an
  immutable creation-code hash. No oracle, no admin setter, no
  runtime pricing. Repricing a tier = redeploy that one factory.

  deployTemplate is one atomic transaction: template-codehash check
  -> EIP-3009 fee settle -> forward to the shared USDC sink -> pull
  one pre-mined salt -> CreateX.deployCreate3 -> ownership handed to
  the caller's chosen custody address. Any revert unwinds the whole
  thing, fee included; the user is never charged for a failed deploy.

  ARCHITECTURAL INVARIANTS (structural, not conventions)
    1. The factory is NEVER the deployed contract's owner, not even
       transiently. It WRITES `owner` (the caller's chosen custody
       address) into the template's constructor args; it never sets
       itself. `owner == address(this)` is rejected.
    2. Fee and deploy are atomic. Empty pool, codehash mismatch,
       CreateX failure, or template-constructor revert unwinds the
       entire transaction, fee included.
    3. No live salt mining. The pool's PoolEmpty() (no fallback) is
       inherited unchanged.
    4. Fee token discipline: USDC only, no mixing. The fee goes to at
       most two pinned sinks: feeSink, and an optional partnerSink
       that receives a fixed PARTNER_BPS share (see PARTNER SHARE).
    5. Price is immutable. No DEPLOYMENT_FEE setter exists anywhere.

  PARTNER SHARE (2026-10-17)
    A security partner can be paid by the protocol itself, under the
    same rules as the protocol's own pool. partnerSink is a second
    PossessioPool (same contract, same limits) whose destinations are
    the partner's address. Both partnerSink and PARTNER_BPS are
    immutable, so the partner can audit this code and know the payment
    cannot be changed. The partner's cut rounds down, so any odd unit
    goes to feeSink. If the partner pool refuses a payment (for example
    because the token blocks its treasury address), the cut waits here
    in partnerOwed and anyone can retry with flushPartner(). The cut can
    only ever go to partnerSink, and a refused partner payment never
    blocks a deploy.

  TEMPLATE CONVENTION (RATIFIED)
    Every template's constructor is `constructor(address owner,
    bytes initArgs)`. The rail supplies `initCode` = the template's
    base creation bytecode (no args), which must hash to this
    factory's immutable templateCodehash. The factory appends
    abi.encode(owner, initArgs) itself, so `owner` is factory-written
    and cannot be spoofed by the caller (any extra bytes in initCode
    change its hash and revert).

  NON-PROVEN until forge says so - see PossessioFactory.t.sol for
  the DoD suite. Cold-seat re-audit before ratification.
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

interface ISaltPool {
    function pullSalt() external returns (bytes32 salt);
}

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
}

/// @notice The pool's accounted inflow door (option A). The factory approves and
///         the pool PULLS the fee, crediting poolBalance. A raw push would strand
///         it — the pool has no sync door (SPEC_Factory_FeeSink_A.md, DoD #14).
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
    function isInfraSink() external view returns (bool);
    function isAuthorizedSource(address source) external view returns (bool);
}

contract PossessioFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroFee();
    error ZeroCodehash();
    error EmptyTemplateCodehash();
    error OwnerIsFactory();
    error TemplateCodehashMismatch(bytes32 got, bytes32 expected);
    error DeployFailed();
    error FeeSinkInterfaceMismatch();
    /// @notice F-L3 (re-audit 2026-09-01): the sink is a live Pool but this
    ///         factory is not in its immutable source set — every fee push
    ///         would revert forever. Caught at construction.
    error FeeSinkSourceNotAuthorized();
    /// @notice partnerSink and PARTNER_BPS must be set together, partnerSink
    ///         must differ from feeSink, and the share must round to a
    ///         non-zero amount of the fee.
    error PartnerConfigInvalid();
    error PartnerShareTooHigh(uint256 bps);
    error PartnerSinkInterfaceMismatch();
    error PartnerSinkSourceNotAuthorized();
    error NothingOwed();

    /*//////////////////////////////////////////////////////////////
                        FEE AUTHORIZATION (EIP-3009)
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-3009 `receiveWithAuthorization` parameters for the
    ///         caller's USDC fee. `from` is msg.sender and `to` is this
    ///         factory (both fixed by deployTemplate, not passed here).
    struct FeeAuth {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical CreateX - identical address on every chain.
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @dev keccak256 of empty bytes. A factory pinned to this degenerate
    ///      hash would accept initCode == "" and deploy args-as-code; the
    ///      constructor forbids it (F1 hardening, cold-seat audit).
    bytes32 private constant EMPTY_CODEHASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @notice This tier's fixed price, in USDC (6 decimals). No setter.
    uint256 public immutable DEPLOYMENT_FEE;

    /// @notice keccak256 of this tier's template base creation bytecode.
    bytes32 public immutable templateCodehash;

    /// @notice Pre-mined salt source. Sender-locked to this factory.
    ISaltPool public immutable saltPool;

    /// @notice USDC as EIP-3009 (fee settle) and as ERC20 (sink forward).
    IERC3009 public immutable payToken;
    IERC20 public immutable payTokenERC20;

    /// @notice The pool the deployment fee is routed INTO via receiveInfraFunds
    ///         (option A — self-funding day one). Immutable; must be in the pool's
    ///         authorizedSources or every deploy reverts.
    address public immutable feeSink;

    /// @notice The partner's pool: a second PossessioPool, pinned like feeSink,
    ///         whose destinations are the security partner's address. Zero when
    ///         this factory has no partner.
    address public immutable partnerSink;

    /// @notice The partner's share of every fee, in basis points. Zero when
    ///         this factory has no partner; never above MAX_PARTNER_BPS.
    uint256 public immutable PARTNER_BPS;

    /// @notice The partner's share is capped at half the fee.
    uint256 public constant MAX_PARTNER_BPS = 5_000;

    /// @notice Partner cuts the partner pool refused, held here until
    ///         flushPartner() delivers them. Only partnerSink can receive them.
    uint256 public partnerOwed;

    /// @notice Every unit of USDC delivered to partnerSink so far, by deploys
    ///         and by flushes. Deferred cuts count only once delivered. The
    ///         partnership's milestones read from this figure directly.
    uint256 public partnerPaidTotal;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event TemplateDeployed(address indexed owner, address indexed deployed, uint256 fee);
    event PartnerPaid(uint256 amount);
    event PartnerPaymentDeferred(uint256 amount, uint256 totalOwed);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _deploymentFee,
        bytes32 _templateCodehash,
        address _saltPool,
        address _payToken,
        address _feeSink,
        address _partnerSink,
        uint256 _partnerBps
    ) {
        if (_deploymentFee == 0) revert ZeroFee();
        if (_templateCodehash == bytes32(0)) revert ZeroCodehash();
        if (_templateCodehash == EMPTY_CODEHASH) revert EmptyTemplateCodehash();
        if (_saltPool == address(0) || _payToken == address(0) || _feeSink == address(0)) {
            revert ZeroAddress();
        }

        // BRICK GUARD (council, verified live): feeSink must be a LIVE contract
        // that implements the accounted door (receiveInfraFunds). A zero/code
        // check alone is insufficient — the demonstrated brick was feeSink =
        // PossessioPayments (real code, no door), which deploys clean, passes
        // the extcodehash gate, then reverts EVERY deployTemplate forever at the
        // permanent anchor. The marker staticcall catches EOA (no code -> throws),
        // wrong-contract (no selector -> throws), and an explicit `false`.
        // NOTE: this makes feeSink a deploy-order dependency — the pool must be
        // live before the factory (RUNBOOK_CONSTELLATION.md §2, revised order).
        // The code-length pre-check catches the EOA/undeployed case explicitly
        // (a high-level call to a no-code address reverts on return-decode
        // OUTSIDE try/catch); the try/catch then catches has-code-but-wrong and
        // an explicit `false`.
        // F-L3 (re-audit 2026-09-01): the marker proves "a Pool"; the source
        // check proves "a Pool that accepts THIS factory". The Pool bakes our
        // predicted CREATE3 address into its source set at its own deploy, so a
        // correctly sequenced constellation passes; a mis-wired one refuses to
        // exist. (One helper for both sinks: review 2026-10-17, F-10.)
        _requireLivePool(_feeSink, false);

        // PARTNER SHARE: both set or both unset; the partner pool passes the same
        // live-pool and authorized-source checks as feeSink, so a mis-wired
        // partner pool refuses to exist instead of deferring every payment.
        if (_partnerBps > MAX_PARTNER_BPS) revert PartnerShareTooHigh(_partnerBps);
        if ((_partnerSink == address(0)) != (_partnerBps == 0)) revert PartnerConfigInvalid();
        if (_partnerSink != address(0)) {
            if (_partnerSink == _feeSink) revert PartnerConfigInvalid();
            if ((_deploymentFee * _partnerBps) / 10_000 == 0) revert PartnerConfigInvalid();
            _requireLivePool(_partnerSink, true);
        }

        DEPLOYMENT_FEE = _deploymentFee;
        templateCodehash = _templateCodehash;
        saltPool = ISaltPool(_saltPool);
        payToken = IERC3009(_payToken);
        payTokenERC20 = IERC20(_payToken);
        feeSink = _feeSink;
        partnerSink = _partnerSink;
        PARTNER_BPS = _partnerBps;
    }

    /// @dev A sink must be a live Pool that lists this factory as a source. The
    ///      code-length pre-check catches the EOA/undeployed case explicitly (a
    ///      high-level call to a no-code address reverts on return-decode OUTSIDE
    ///      try/catch); the try/catch then catches has-code-but-wrong and an
    ///      explicit `false`. `partner` selects the error family.
    function _requireLivePool(address sink, bool partner) private view {
        if (sink.code.length == 0) _interfaceMismatch(partner);
        try IPossessioPool(sink).isInfraSink() returns (bool ok) {
            if (!ok) _interfaceMismatch(partner);
        } catch {
            _interfaceMismatch(partner);
        }
        try IPossessioPool(sink).isAuthorizedSource(address(this)) returns (bool authorized) {
            if (!authorized) {
                if (partner) revert PartnerSinkSourceNotAuthorized();
                revert FeeSinkSourceNotAuthorized();
            }
        } catch {
            _interfaceMismatch(partner);
        }
    }

    function _interfaceMismatch(bool partner) private pure {
        if (partner) revert PartnerSinkInterfaceMismatch();
        revert FeeSinkInterfaceMismatch();
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOY (the whole product)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy this factory's template for the caller. One
    ///         signature, one transaction: fee settle + salt pull +
    ///         CreateX deploy + explicit ownership handoff, atomic.
    /// @param owner    EXPLICIT final owner (Base Account or Safe). The
    ///                 factory writes this into the template's args and
    ///                 is NEVER this value.
    /// @param initArgs template-specific constructor args (ABI-encoded);
    ///                 the template decodes them from its `bytes` arg.
    /// @param initCode template base creation bytecode; MUST hash to
    ///                 templateCodehash (no args baked in).
    /// @param feeAuth  EIP-3009 authorization for DEPLOYMENT_FEE in USDC,
    ///                 signed by the caller with `to == address(this)`.
    /// @return deployed the deterministic CREATE3 address of the template.
    function deployTemplate(
        address owner,
        bytes calldata initArgs,
        bytes calldata initCode,
        FeeAuth calldata feeAuth
    ) external nonReentrant returns (address deployed) {
        // 1. Owner sanity: never zero, never the factory (Invariant 1).
        if (owner == address(0)) revert ZeroAddress();
        if (owner == address(this)) revert OwnerIsFactory();

        // 2. Template binding FIRST - before any fee is pulled or salt is
        //    consumed (DoD #7). A wrong template reverts here, cost-free.
        bytes32 got = keccak256(initCode);
        if (got != templateCodehash) revert TemplateCodehashMismatch(got, templateCodehash);

        // 3. Fee settle. Front-run-closed: only THIS factory can settle its
        //    own authorization because `to == address(this)`.
        payToken.receiveWithAuthorization(
            msg.sender,
            address(this),
            DEPLOYMENT_FEE,
            feeAuth.validAfter,
            feeAuth.validBefore,
            feeAuth.nonce,
            feeAuth.v,
            feeAuth.r,
            feeAuth.s
        );

        // 4. Route the fee INTO the pool via its accounted pull door (option A,
        //    SPEC_Factory_FeeSink_A.md). forceApprove exact, then the pool pulls it
        //    and credits poolBalance. A raw safeTransfer would strand the fee (the
        //    pool has no sync door). If this factory is not in the pool's
        //    authorizedSources the call reverts — unwinding the whole deploy, fee
        //    included (Invariant 2 preserved: the caller is never charged on failure).
        //    With a partner, the partner's cut (rounded down) goes to partnerSink and
        //    the rest, including any odd unit, to feeSink. A refused partner cut is
        //    held, never lost, and never blocks the deploy (see _payPartner).
        uint256 partnerCut = (DEPLOYMENT_FEE * PARTNER_BPS) / 10_000;
        uint256 ownCut = DEPLOYMENT_FEE - partnerCut;
        payTokenERC20.forceApprove(feeSink, ownCut);
        IPossessioPool(feeSink).receiveInfraFunds(ownCut);
        if (partnerCut != 0) _payPartner(partnerCut);

        // 5. Pull one pre-mined salt (factory-only; sender-locked here).
        bytes32 salt = saltPool.pullSalt();

        // 6. Full creation bytecode = pinned template code + factory-written
        //    owner + template args. The factory WRITES owner; it cannot be
        //    spoofed (any extra bytes in initCode would have failed step 2).
        bytes memory creationCode = bytes.concat(initCode, abi.encode(owner, initArgs));

        // 7. Deterministic deploy via canonical CreateX.
        deployed = CREATEX.deployCreate3(salt, creationCode);
        if (deployed == address(0)) revert DeployFailed();

        emit TemplateDeployed(owner, deployed, DEPLOYMENT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                            PARTNER SHARE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deliver every held partner cut to partnerSink. Anyone may call;
    ///         the funds can only go to partnerSink. Reverts, holding the cuts,
    ///         if the partner pool still refuses them.
    function flushPartner() external nonReentrant returns (uint256 amount) {
        amount = partnerOwed;
        if (amount == 0) revert NothingOwed();
        partnerOwed = 0;
        payTokenERC20.forceApprove(partnerSink, amount);
        IPossessioPool(partnerSink).receiveInfraFunds(amount);
        partnerPaidTotal += amount;
        emit PartnerPaid(amount);
    }

    /// @dev Pay the partner's cut through its pool's accounted door. A refusal
    ///      (the pool's outbound surplus push can revert if the token blocks the
    ///      partner's treasury address) must not block the deploy, the same
    ///      push-payment DoS class as a refund to an address that can no longer
    ///      receive USDC. So the cut is held in partnerOwed instead, and the
    ///      dangling approval is cleared.
    ///      Accepted (review 2026-10-17, F-3): a caller can size the outer gas
    ///      so this inner call runs out of gas while the retained 1/64 still
    ///      completes the deploy, which defers the cut into partnerOwed. That
    ///      delays the partner, it never takes from them: the cut is held here
    ///      and anyone can flushPartner() it. A fixed stipend would turn an
    ///      honest refusal into a bricked launch, which is the worse trade.
    function _payPartner(uint256 amount) private {
        payTokenERC20.forceApprove(partnerSink, amount);
        try IPossessioPool(partnerSink).receiveInfraFunds(amount) {
            partnerPaidTotal += amount;
            emit PartnerPaid(amount);
        } catch {
            payTokenERC20.forceApprove(partnerSink, 0);
            partnerOwed += amount;
            emit PartnerPaymentDeferred(amount, partnerOwed);
        }
    }
}
