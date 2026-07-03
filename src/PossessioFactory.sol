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
    4. Fee token discipline: USDC only, one sink, no mixing.
    5. Price is immutable. No DEPLOYMENT_FEE setter exists anywhere.

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

    /// @notice The single shared USDC treasury sink (Payments contract).
    address public immutable feeSink;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event TemplateDeployed(address indexed owner, address indexed deployed, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _deploymentFee,
        bytes32 _templateCodehash,
        address _saltPool,
        address _payToken,
        address _feeSink
    ) {
        if (_deploymentFee == 0) revert ZeroFee();
        if (_templateCodehash == bytes32(0)) revert ZeroCodehash();
        if (_templateCodehash == EMPTY_CODEHASH) revert EmptyTemplateCodehash();
        if (_saltPool == address(0) || _payToken == address(0) || _feeSink == address(0)) {
            revert ZeroAddress();
        }

        DEPLOYMENT_FEE = _deploymentFee;
        templateCodehash = _templateCodehash;
        saltPool = ISaltPool(_saltPool);
        payToken = IERC3009(_payToken);
        payTokenERC20 = IERC20(_payToken);
        feeSink = _feeSink;
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

        // 4. Forward the fee to the single shared USDC sink.
        payTokenERC20.safeTransfer(feeSink, DEPLOYMENT_FEE);

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
}
