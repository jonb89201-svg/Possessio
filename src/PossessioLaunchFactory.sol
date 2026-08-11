// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                  POSSESSIO LAUNCH FACTORY
              v0.1 - built to council spec
     (SPEC_CouncilToken.md §4 pairing / §7 market / §0 creed)

  The V3 launchpad. Deploys a frozen launch template (codehash-
  pinned, CREATE3 at a pre-mined hook address) and, IN THE SAME
  ATOMIC TRANSACTION, initializes its Uniswap v4 pool against the
  COUNCIL TOKEN. The pairing is a property of the bytecode, not a
  listing decision: this factory is INCAPABLE of producing a launch
  that is not paired against the council token, and incapable of
  deploying anything except the one pinned template.

  §4 (spec): "pairing enforcement MUST be in the V3 factory
  bytecode from its first deploy" — this is that bytecode.
  §7 (spec): every pair this factory creates is a continuous
  prediction market on the launch it wires to. The market exists
  iff the pairing DoD passes; there is no separate market contract.

  TOPOLOGY DECISION EMBODIED (spec §11.2, OPEN at drafting):
  OPTION A — DIRECT PER-LAUNCH PAIR. Each launch initializes its
  own v4 pool: {councilToken, launchToken}, hooks = the launch
  itself (the owner's 2% fee engine lives in the launch template;
  the salt pool serves 0x8C8 hook-permission-mined salts, so the
  CREATE3 address carries the hook flags). The alternative
  (anchor-pool routing) was NOT chosen. Architect merge of this
  file is the ratification of Option A; cold seats review against
  the §0 creed FIRST.

  CREED CHECK (§0, in order):
    1. Non-extraction: one fee at the door, credited to the Heart
       via the accounted receiveInfraFunds pull (option A). The
       launch's own 2% belongs to the launch owner. No other skim
       path exists in this source.
    2. Sovereignty: no admin, no setters, no upgrade path, no
       pause. The factory is never the launch's owner (rejected
       structurally). Repricing/retargeting = a NEW factory.
    3. Immutable & deterministic: every parameter is immutable;
       the launch address is CREATE3-predictable before deploy;
       the pair key is derivable from (councilToken, predicted
       launch) before deploy. A deploy lands exactly as computed
       or not at all.
    4. On-chain transparency: registry is append-only and public;
       PairInitialized emits the full key.

  ARCHITECTURAL INVARIANTS (inherited from PossessioFactory,
  extended with the pairing):
    1. The factory is NEVER the deployed contract's owner.
    2. Fee, deploy, and PAIR INIT are one atomic transaction. Any
       failure — empty salt pool, codehash mismatch, CreateX
       failure, template-constructor revert, POOL INIT REVERT —
       unwinds everything, fee included.
    3. No live salt mining; PoolEmpty() inherited unchanged.
    4. Fee token discipline: USDC only, one accounted sink.
    5. Price is immutable; pairing target is immutable.

  V4 INTERFACE NOTE: PoolKey here uses address fields; the real
  v4-core PoolKey wraps them (Currency, IHooks) but is ABI-
  identical for external calls. Offline suites prove the factory
  against a recording mock; the FORK suite against the live Base
  PoolManager is OWED before any deploy (same two-mode discipline
  as every constellation contract).

  NON-PROVEN until forge says so - see PossessioLaunchFactory.t.sol
  for the DoD suite. Cold-seat re-audit before ratification.
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

/// @notice The Heart's accounted inflow door (option A). The factory approves
///         and the pool PULLS the fee, crediting poolBalance. A raw push would
///         strand it (SPEC_Factory_FeeSink_A.md, Pool DoD #14).
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
    function isInfraSink() external view returns (bool);
}

/// @notice Minimal Uniswap v4 PoolManager surface. Address-typed PoolKey is
///         ABI-identical to v4-core's (Currency/IHooks are address wrappers).
interface IPoolManagerMinimal {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract PossessioLaunchFactory is ReentrancyGuard {
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
    error CouncilTokenNotLive();
    error PoolManagerNotLive();
    error ZeroInitialPrice();
    error BadPoolFee();
    error BadTickSpacing();

    /*//////////////////////////////////////////////////////////////
                        FEE AUTHORIZATION (EIP-3009)
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-3009 `receiveWithAuthorization` parameters for the caller's
    ///         USDC fee. `from` is msg.sender and `to` is this factory (both
    ///         fixed by deployLaunch, not passed here).
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

    /// @dev keccak256 of empty bytes (F1 hardening, inherited).
    bytes32 private constant EMPTY_CODEHASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @dev v4 fee is parts-per-million; the dynamic-fee flag and anything
    ///      >= 100% are rejected. LP fee ceiling per v4-core is 1_000_000.
    uint24 private constant MAX_POOL_FEE = 1_000_000;

    /// @notice This tier's fixed launch price, in USDC (6 decimals). No setter.
    uint256 public immutable DEPLOYMENT_FEE;

    /// @notice keccak256 of the pinned launch template's base creation bytecode.
    bytes32 public immutable templateCodehash;

    /// @notice Pre-mined salt source (0x8C8 hook-flag salts, sender-locked here).
    ISaltPool public immutable saltPool;

    /// @notice USDC as EIP-3009 (fee settle) and as ERC20 (accounted forward).
    IERC3009 public immutable payToken;
    IERC20 public immutable payTokenERC20;

    /// @notice The Heart. Deployment fees route INTO it via receiveInfraFunds.
    address public immutable heartSink;

    /// @notice THE PAIRING TARGET (spec §4). Every launch's v4 pool is
    ///         initialized against this asset, by construction, forever.
    address public immutable COUNCIL_TOKEN;

    /// @notice Uniswap v4 PoolManager this factory initializes pairs on.
    IPoolManagerMinimal public immutable poolManager;

    /// @notice v4 LP fee (ppm) and tick spacing every pair is created with.
    ///         Immutable per factory - a different market structure is a new
    ///         factory, same as a different price is (honest versioning).
    uint24 public immutable POOL_FEE;
    int24 public immutable TICK_SPACING;

    /*//////////////////////////////////////////////////////////////
                          REGISTRY (append-only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Every launch this factory has deployed, in order.
    address[] public launches;

    /// @notice O(1) recognition: true iff `launch` was deployed AND paired here.
    mapping(address launch => bool) public isLaunchOfFactory;

    /// @notice The exact v4 pool key each launch was paired with (the market's
    ///         identity under spec §7 - one row per launch, written once).
    mapping(address launch => IPoolManagerMinimal.PoolKey) internal _pairKeyOf;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event LaunchDeployed(address indexed owner, address indexed launch, uint256 fee);

    /// @notice The §7 market, opened. Full key emitted for indexers.
    event PairInitialized(
        address indexed launch,
        address currency0,
        address currency1,
        uint24 poolFee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96,
        int24 tick
    );

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _deploymentFee,
        bytes32 _templateCodehash,
        address _saltPool,
        address _payToken,
        address _heartSink,
        address _councilToken,
        address _poolManager,
        uint24 _poolFee,
        int24 _tickSpacing
    ) {
        if (_deploymentFee == 0) revert ZeroFee();
        if (_templateCodehash == bytes32(0)) revert ZeroCodehash();
        if (_templateCodehash == EMPTY_CODEHASH) revert EmptyTemplateCodehash();
        if (
            _saltPool == address(0) || _payToken == address(0) || _heartSink == address(0)
                || _councilToken == address(0) || _poolManager == address(0)
        ) revert ZeroAddress();
        if (_poolFee >= MAX_POOL_FEE) revert BadPoolFee();
        if (_tickSpacing <= 0) revert BadTickSpacing();

        // BRICK GUARD (inherited from PossessioFactory, verified live there):
        // heartSink must be a LIVE contract implementing the accounted door.
        if (_heartSink.code.length == 0) revert FeeSinkInterfaceMismatch();
        try IPossessioPool(_heartSink).isInfraSink() returns (bool ok) {
            if (!ok) revert FeeSinkInterfaceMismatch();
        } catch {
            revert FeeSinkInterfaceMismatch();
        }

        // SEQUENCING GUARD (spec §9: token first, factory second). The council
        // token must be LIVE CODE at factory construction - a factory pointed
        // at a not-yet-deployed pairing target would mint unpaired launches'
        // worth of nothing: v4 initialize against a codeless currency would
        // succeed and create a market on a ghost. Refuse to exist instead.
        if (_councilToken.code.length == 0) revert CouncilTokenNotLive();
        if (_poolManager.code.length == 0) revert PoolManagerNotLive();

        DEPLOYMENT_FEE = _deploymentFee;
        templateCodehash = _templateCodehash;
        saltPool = ISaltPool(_saltPool);
        payToken = IERC3009(_payToken);
        payTokenERC20 = IERC20(_payToken);
        heartSink = _heartSink;
        COUNCIL_TOKEN = _councilToken;
        poolManager = IPoolManagerMinimal(_poolManager);
        POOL_FEE = _poolFee;
        TICK_SPACING = _tickSpacing;
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOY + PAIR (the whole product)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy this factory's launch template for the caller and open
    ///         its market against the council token. One signature, one
    ///         transaction: fee settle -> accounted route to the Heart -> salt
    ///         pull -> CreateX CREATE3 deploy -> v4 pool init against
    ///         COUNCIL_TOKEN. Atomic: any failure unwinds it all, fee included.
    /// @param owner        EXPLICIT final owner of the launch (Base Account or
    ///                     Safe). Factory-written; never the factory itself.
    /// @param initArgs     template-specific constructor args (ABI-encoded).
    /// @param initCode     template base creation bytecode; MUST hash to
    ///                     templateCodehash (no args baked in).
    /// @param sqrtPriceX96 the launch owner's initial pair price (v4 Q64.96).
    /// @param feeAuth      EIP-3009 authorization for DEPLOYMENT_FEE in USDC,
    ///                     signed by the caller with `to == address(this)`.
    /// @return launch the deterministic CREATE3 address of the launch.
    /// @return key    the v4 pool key the market was opened with.
    function deployLaunch(
        address owner,
        bytes calldata initArgs,
        bytes calldata initCode,
        uint160 sqrtPriceX96,
        FeeAuth calldata feeAuth
    ) external nonReentrant returns (address launch, IPoolManagerMinimal.PoolKey memory key) {
        // 1. Owner + price sanity (Invariant 1; a zero price is an unopenable market).
        if (owner == address(0)) revert ZeroAddress();
        if (owner == address(this)) revert OwnerIsFactory();
        if (sqrtPriceX96 == 0) revert ZeroInitialPrice();

        // 2. Template binding FIRST - before any fee is pulled or salt is
        //    consumed. A wrong template reverts here, cost-free.
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

        // 4. Route the fee INTO the Heart via its accounted pull door (option A).
        //    The flywheel's first arrow (spec §2): this credit is the launch
        //    capital provenance chain, auditable to the dollar.
        payTokenERC20.forceApprove(heartSink, DEPLOYMENT_FEE);
        IPossessioPool(heartSink).receiveInfraFunds(DEPLOYMENT_FEE);

        // 5. Pull one pre-mined 0x8C8 salt (factory-only; sender-locked here).
        bytes32 salt = saltPool.pullSalt();

        // 6. Full creation bytecode = pinned template + factory-written owner
        //    + template args. Owner cannot be spoofed (step 2 pinned the code).
        bytes memory creationCode = bytes.concat(initCode, abi.encode(owner, initArgs));

        // 7. Deterministic deploy via canonical CreateX. The address carries
        //    the v4 hook permission flags (that is what the mined salt is for).
        launch = CREATEX.deployCreate3(salt, creationCode);
        if (launch == address(0)) revert DeployFailed();

        // 8. THE PAIRING (spec §4) - same transaction, no post-deploy setup,
        //    no way to launch around it. The factory constructs the key itself
        //    from (COUNCIL_TOKEN, launch): a launch not paired against the
        //    council token is not expressible in this bytecode. The launch is
        //    its own hook - the owner's 2% engine (spec §2) rides the pair.
        //    v4 sorts currencies ascending; a revert here unwinds EVERYTHING,
        //    fee included (Invariant 2).
        (address c0, address c1) =
            COUNCIL_TOKEN < launch ? (COUNCIL_TOKEN, launch) : (launch, COUNCIL_TOKEN);
        key = IPoolManagerMinimal.PoolKey({
            currency0: c0,
            currency1: c1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: launch
        });
        int24 tick = poolManager.initialize(key, sqrtPriceX96);

        // 9. Registry - append-only, written once per launch.
        launches.push(launch);
        isLaunchOfFactory[launch] = true;
        _pairKeyOf[launch] = key;

        emit LaunchDeployed(owner, launch, DEPLOYMENT_FEE);
        emit PairInitialized(
            launch, c0, c1, POOL_FEE, TICK_SPACING, launch, sqrtPriceX96, tick
        );
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total launches deployed-and-paired by this factory.
    function totalLaunches() external view returns (uint256) {
        return launches.length;
    }

    /// @notice The exact v4 pool key `launch` was paired with (zeroed if not
    ///         a launch of this factory). The §7 market's on-chain identity.
    function pairKeyOf(address launch) external view returns (IPoolManagerMinimal.PoolKey memory) {
        return _pairKeyOf[launch];
    }

    /// @notice Identity surface (MAVAN-primitive pattern): trivially forgeable
    ///         alone; recognition logic must verify THIS factory's address
    ///         against the ratified canonical address.
    function isPossessioLaunchFactory() external pure returns (bool) {
        return true;
    }

    /// @notice No admin, no setters, no upgrade path - asserted for external
    ///         recognition logic, enforced by the absence of code.
    function hasNoAdminAuthority() external pure returns (bool) {
        return true;
    }
}
