// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ██████╗ ██╗      █████╗ ████████╗███████╗
 * ██╔══██╗██║     ██╔══██╗╚══██╔══╝██╔════╝
 * ██████╔╝██║     ███████║   ██║   █████╗
 * ██╔═══╝ ██║     ██╔══██║   ██║   ██╔══╝
 * ██║     ███████╗██║  ██║   ██║   ███████╗
 * ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
 *
 * POSSESSIO PROTOCOL — v2 (STEEL)
 * Protocol Liquidity Asset Treasury Engine, rebuilt as Uniswap V4 hook
 *
 * TWO CONTRACTS IN ONE FILE:
 *   - STEEL       — clean ERC20 token ("PLATE" / "STEEL")
 *   - PossessioHook — V4 hook + fee capture + treasury routing + SAV council logic
 *
 * FEE PIPELINE (v2):
 *   beforeSwap → capture 2% ETH via BeforeSwapDelta
 *   afterSwap  → emit FeeCaptured, no routing inline (V4 unlock constraint)
 *   routeETH   → external call, 25% LP / 75% Treasury
 *                  · 20% of 75% → DAI until $2,280 cap
 *                  · Remainder → 40% cbETH / 60% rETH
 *
 * COUNCIL ALLOCATION (SAV logic, 3% of supply):
 *   Treasury → deposit() → claimable split across 4 council members
 *   burn()   → member burns own allocation
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

// Uniswap V4 — real imports from v4-core and v4-periphery
// Note: v4-core remapping already points to lib/v4-core/src/, so paths below are relative to that
import {IPoolManager}    from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}          from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}         from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary}   from "v4-core/types/Currency.sol";
import {BalanceDelta}    from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary}    from "v4-core/libraries/StateLibrary.sol";
import {FullMath}        from "v4-core/libraries/FullMath.sol";
import {TickMath}        from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

// ═══════════════════════════════════════════════════════════════════════════
//                          EXTERNAL INTERFACES
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Uniswap V3 SwapRouter interface for DAI swap leg.
///         Used OUTSIDE the V4 unlock context — routeETH is called from EOA/Safe,
///         not from within a V4 swap callback.
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    );
}

interface IcbETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IrETH {
    function deposit() external payable;
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
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
 * ═══════════════════════════════════════════════════════════════════════════
 *                          DEPLOYMENT REQUIREMENTS
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * CRITICAL — HOOK ADDRESS BITS MUST ENCODE PERMISSIONS
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
 *     cast call $HOOK_ADDR "getHookPermissions()(bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)"
 *     Match flags against actual address bits.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 *                          STUB REPLACEMENT — MANDATORY
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * The libraries `StateLibrary`, `LiquidityAmounts`, `FullMath`, `CurrencyLibrary`,
 * `PoolIdLibrary`, and the free function `toBeforeSwapDelta` are declared in
 * this file AS STUBS. They are placeholders with pass-through or zero-return
 * implementations so the contract reads as a self-contained draft.
 *
 * THE CONTRACT WILL NOT FUNCTION CORRECTLY WITH THE STUBS IN PLACE.
 *
 * Before compilation for deploy:
 *   1. Remove the stub library declarations from this file
 *   2. Replace with imports from @uniswap/v4-core:
 *      - StateLibrary   from "@uniswap/v4-core/src/libraries/StateLibrary.sol"
 *      - LiquidityAmounts from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol"
 *      - FullMath       from "@uniswap/v4-core/src/libraries/FullMath.sol"
 *      - CurrencyLibrary from "@uniswap/v4-core/src/types/Currency.sol"
 *      - PoolIdLibrary  from "@uniswap/v4-core/src/types/PoolId.sol"
 *      - toBeforeSwapDelta from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol"
 *   3. Verify `LiquidityAmounts.getLiquidityForAmounts` returns non-zero on
 *      the genesis seed before signing the seed transaction.
 *
 * Running `forge build` with stubs in place will compile but deploy will brick.
 */
contract PossessioHook is IUnlockCallback, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    // Fee configuration
    uint256 public constant FEE_BPS       = 200;     // 2%
    uint256 public constant FEE_DENOM     = 10_000;

    // Routing splits (matching v1)
    uint256 public constant LP_PCT        = 25;      // 25% ETH → LP
    uint256 public constant TREASURY_PCT  = 75;      // 75% ETH → Treasury
    uint256 public constant DAI_BOOT_PCT  = 20;      // 20% of 75% → DAI until target
    uint256 public constant CBETH_PCT     = 40;
    uint256 public constant RETH_PCT      = 60;

    // Yield harvest splits (matching v1)
    uint256 public constant YIELD_TO_LP   = 25;
    uint256 public constant YIELD_TO_T    = 75;

    // DAI reserve target
    uint256 public constant DAI_TARGET    = 2_280 * 10**18;

    // Governance
    uint256 public constant TIMELOCK      = 48 hours;

    // Depeg guard (matching v1)
    int256  public constant DEPEG_THRESH  = 97_000_000; // 3%

    // Slippage tolerance
    uint256 public constant SLIPPAGE      = 90; // 90% of expected

    // Routing auto-trigger
    uint256 public constant ROUTE_THRESHOLD = 0.05 ether;
    uint256 public constant ROUTE_COOLDOWN  = 6 hours;

    // SAV constants
    uint256 public constant INVENT_EXPIRY    = 30 days;
    uint8   public constant INVENT_THRESHOLD = 3;

    // Uniswap V3 DAI swap fee tier
    uint24  public constant DAI_V3_FEE = 500; // 0.05% stable pair

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
    IrETH              public immutable rETH;
    IERC20             public immutable DAI;

    IChainlinkFeed     public immutable CHAINLINK_CBETH_ETH;  // cbETH depeg feed
    IChainlinkFeed     public immutable CHAINLINK_DAI_ETH;    // DAI/ETH for swap minOut

    IV3SwapRouter      public immutable V3_ROUTER; // Uniswap V3 router for DAI leg
    IWETH              public immutable WETH;       // Base WETH9 for V3 router wrap

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
    uint256 public daiReserve;
    uint256 public cbETHPrincipal;
    uint256 public rETHPrincipal;

    // Circuit breaker
    bool public routingPaused;
    bool public cbETHPaused;

    // Timelock (reused pattern from v1)
    mapping(bytes32 => uint256) public timelockQueue;

    // SAV state
    mapping(address => uint256) public claimable;
    bool public savPaused;
    bool public slashed;

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
    event FeeCaptured(address indexed swapper, uint256 ethAmount, uint256 accumulated, uint256 timestamp);
    event ETHRouted(uint256 total, uint256 toLP, uint256 toDAI, uint256 toStaking, uint256 timestamp);
    event LiquidityAdded(uint256 ethIn, uint256 steelIn, uint256 timestamp);
    event LPFailed(uint256 ethAmt, uint8 reasonCode);
    event DAIReserveFunded(uint256 daiReceived, uint256 balance, uint256 timestamp);
    event DAIReserveFull(uint256 timestamp);
    event StakingDeployed(uint256 cbETH, uint256 rETH, uint256 timestamp);
    event YieldHarvested(uint256 total, uint256 toLP, uint256 toTreasury, uint256 timestamp);

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

    // ═══════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

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
        if (block.timestamp < timelockQueue[id]) revert TimelockPending();
        delete timelockQueue[id];
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
        address rETH_;
        address dai;
        address chainlinkCbETH;
        address chainlinkDAI;
        address v3Router;
        address weth;
        address[4] council;
    }

    constructor(DeployParams memory p) Ownable(p.deployer) {
        if (p.steel          == address(0)) revert InvalidAddress();
        if (p.poolManager    == address(0)) revert InvalidAddress();
        if (p.treasury       == address(0)) revert InvalidAddress();
        if (p.cbETH_         == address(0)) revert InvalidAddress();
        if (p.rETH_          == address(0)) revert InvalidAddress();
        if (p.dai            == address(0)) revert InvalidAddress();
        if (p.chainlinkCbETH == address(0)) revert InvalidAddress();
        if (p.chainlinkDAI   == address(0)) revert InvalidAddress();
        if (p.v3Router       == address(0)) revert InvalidAddress();
        if (p.weth           == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < 4; i++) {
            if (p.council[i] == address(0)) revert InvalidAddress();
        }

        STEEL_TOKEN          = IERC20(p.steel);
        POOL_MANAGER         = IPoolManager(p.poolManager);
        TREASURY_SAFE        = p.treasury;
        cbETH                = IcbETH(p.cbETH_);
        rETH                 = IrETH(p.rETH_);
        DAI                  = IERC20(p.dai);
        CHAINLINK_CBETH_ETH  = IChainlinkFeed(p.chainlinkCbETH);
        CHAINLINK_DAI_ETH    = IChainlinkFeed(p.chainlinkDAI);
        V3_ROUTER            = IV3SwapRouter(p.v3Router);
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
    function getHookPermissions() external pure returns (
        bool beforeInitialize, bool afterInitialize,
        bool beforeAddLiquidity, bool afterAddLiquidity,
        bool beforeRemoveLiquidity, bool afterRemoveLiquidity,
        bool beforeSwap, bool afterSwap,
        bool beforeDonate, bool afterDonate,
        bool beforeSwapReturnDelta, bool afterSwapReturnDelta,
        bool afterAddLiquidityReturnDelta, bool afterRemoveLiquidityReturnDelta
    ) {
        return (
            false, false,
            true,  false,   // beforeAddLiquidity only (POL gate)
            false, false,
            true,  true,    // beforeSwap + afterSwap
            false, false,
            true,  false,   // beforeSwap returns delta (fee capture)
            false, false
        );
    }

    /**
     * @notice Register the V4 pool after initialization.
     *         Called once by owner after PoolManager.initialize.
     */
    function registerPool(PoolKey calldata key) external onlyOwner {
        if (poolInitialized) revert PoolAlreadyRegistered();
        if (key.hooks != address(this)) revert InvalidAddress();
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
        address /* sender */,
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
            // Specified is STEEL — convert to ETH equivalent:
            //   price = (sqrtPriceX96^2) / 2^192
            //   ethEquivalent = steelAmount * price
            uint256 ethEquivalent = FullMath.mulDiv(
                absSpecified,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                1 << 192
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
        POOL_MANAGER.take(CurrencyLibrary.NATIVE, address(this), feeETH);
        accumulatedETH += feeETH;

        // Delta packing: fee lands in ETH slot regardless of which side was specified
        BeforeSwapDelta delta;
        if (isETHSpecified) {
            // ETH is the specified currency — put positive delta on specified side
            delta = toBeforeSwapDelta(int128(int256(feeETH)), int128(0));
        } else {
            // ETH is the unspecified currency — put positive delta on unspecified side
            delta = toBeforeSwapDelta(int128(0), int128(int256(feeETH)));
        }

        emit FeeCaptured(tx.origin, feeETH, accumulatedETH, block.timestamp);
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
     *           Remainder  → cbETH (40%) + rETH (60%) staking
     */
    function routeETH() external nonReentrant notPaused {
        // Access gate: Treasury always; permissionless only after threshold + cooldown
        bool isTreasury = msg.sender == TREASURY_SAFE;
        if (!isTreasury) {
            if (accumulatedETH < ROUTE_THRESHOLD) revert BelowThreshold();
            if (block.timestamp < lastRouteTime + ROUTE_COOLDOWN) revert RouteTooEarly();
        }

        uint256 total = accumulatedETH;
        if (total == 0) revert ZeroAmount();

        // Compute allocations upfront (matching v1 safety pattern)
        uint256 toLP       = (total * LP_PCT) / 100;
        uint256 toTreasury = total - toLP;
        uint256 toDAI      = (daiReserve < DAI_TARGET) ? (toTreasury * DAI_BOOT_PCT) / 100 : 0;
        uint256 toStaking  = toTreasury - toDAI;

        // Zero accumulator before external calls (CEI)
        accumulatedETH = 0;
        lastRouteTime  = block.timestamp;

        // LP injection via unlock dance
        if (toLP > 0) {
            _addLiquidity(toLP);
        }

        // DAI swap via V3 router (outside V4 unlock context)
        if (toDAI > 0) {
            _swapETHToDAI(toDAI);
        }

        // Staking deposits (external calls to cbETH/rETH, no unlock needed)
        if (toStaking > 0) {
            _deployToStaking(toStaking);
        }

        emit ETHRouted(total, toLP, toDAI, toStaking, block.timestamp);

        // Permissionless caller gets tiny reward to amortize gas
        if (!isTreasury) {
            uint256 reward = total / 1000; // 0.1% of routed
            if (reward > 0 && address(this).balance >= reward) {
                (bool ok,) = msg.sender.call{value: reward}("");
                if (!ok) { /* swallow — reward is best-effort */ }
            }
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
     *         Native ETH uses settle{value:} directly (no sync needed — msg.value
     *         carries the full signal). ERC20 follows the V4 protocol:
     *         sync → transfer → settle, so PoolManager can checkpoint the baseline
     *         balance and compute the correct delta from the fresh transfer.
     */
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (CurrencyLibrary.isNative(currency)) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    DAI EMERGENCY RESERVE (internal)
    // ═══════════════════════════════════════════════════════════════════════

    function _swapETHToDAI(uint256 ethAmt) internal {
        if (ethAmt == 0) return;

        uint256 minDAI = 0;
        try CHAINLINK_DAI_ETH.latestRoundData() returns (
            uint80 roundId,
            int256 daiEthPrice,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Grok-audit: full staleness check before trusting price
            bool valid = (answeredInRound >= roundId)
                && (updatedAt != 0)
                && (block.timestamp - updatedAt <= 3600)
                && (daiEthPrice > 0);

            if (valid) {
                uint256 expectedDAI = (ethAmt * 1e8) / uint256(daiEthPrice);
                minDAI = (expectedDAI * SLIPPAGE) / 100;
            }
        } catch {}

        if (minDAI == 0) {
            // Oracle failure — retain ETH, don't blind swap
            accumulatedETH += ethAmt;
            return;
        }

        // V3 SwapRouter02 on Base requires WETH input (does not accept native ETH).
        // Wrap ETH → WETH, approve router, then swap WETH → DAI.
        try WETH.deposit{value: ethAmt}() {
            WETH.approve(address(V3_ROUTER), ethAmt);
        } catch {
            // WETH wrap failed — retain ETH, skip cycle
            accumulatedETH += ethAmt;
            return;
        }

        try V3_ROUTER.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn:           address(WETH),
                tokenOut:          address(DAI),
                fee:               DAI_V3_FEE,
                recipient:         address(this),
                amountIn:          ethAmt,
                amountOutMinimum:  minDAI,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 daiReceived) {
            daiReserve += daiReceived;
            emit DAIReserveFunded(daiReceived, daiReserve, block.timestamp);
            if (daiReserve >= DAI_TARGET) emit DAIReserveFull(block.timestamp);
        } catch {
            // Swap failed — unwrap WETH back to ETH, retain for next cycle
            try WETH.withdraw(ethAmt) {
                accumulatedETH += ethAmt;
            } catch {
                // Can't even unwrap — WETH stuck. Emit for visibility.
                emit LPFailed(ethAmt, 6);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      STAKING DEPOSIT (internal)
    // ═══════════════════════════════════════════════════════════════════════

    function _deployToStaking(uint256 ethAmt) internal {
        if (ethAmt == 0) return;
        _checkDepeg();

        uint256 cbAmt = cbETHPaused ? 0 : (ethAmt * CBETH_PCT) / 100;
        uint256 rAmt  = ethAmt - cbAmt;

        if (cbAmt > 0) {
            try cbETH.deposit{value: cbAmt}() {
                cbETHPrincipal += cbAmt;
            } catch {
                // cbETH deposit failed — forward to Treasury as raw ETH (P2.2 fix)
                (bool ok,) = TREASURY_SAFE.call{value: cbAmt}("");
                if (!ok) { accumulatedETH += cbAmt; }
            }
        }

        if (rAmt > 0) {
            try rETH.deposit{value: rAmt}() {
                rETHPrincipal += rAmt;
            } catch {
                (bool ok,) = TREASURY_SAFE.call{value: rAmt}("");
                if (!ok) { accumulatedETH += rAmt; }
            }
        }

        emit StakingDeployed(cbAmt, rAmt, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     YIELD HARVEST (external)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Harvest staking yield — principal stays staked.
     *         Follows v1 pattern: only withdraws ABOVE tracked principal.
     *         25% → LP · 75% → Treasury.
     *
     *         If LP add fails, the yield portion is redirected to Treasury rather
     *         than restored to the fee accumulator (would apply wrong splits on re-route).
     */
    function harvestYield() external nonReentrant notPaused {
        uint256 total = 0;

        uint256 cbBal = cbETH.balanceOf(address(this));
        if (cbBal > cbETHPrincipal) {
            uint256 yieldLST  = cbBal - cbETHPrincipal;
            uint256 ethBefore = address(this).balance;
            try cbETH.withdraw(yieldLST) {
                total += address(this).balance - ethBefore;
            } catch {}
        }

        uint256 rBal = rETH.balanceOf(address(this));
        if (rBal > rETHPrincipal) {
            uint256 yieldLST  = rBal - rETHPrincipal;
            uint256 ethBefore = address(this).balance;
            try rETH.burn(yieldLST) {
                total += address(this).balance - ethBefore;
            } catch {}
        }

        if (total == 0) revert ZeroAmount();

        uint256 toLp = (total * YIELD_TO_LP) / 100;
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
        require(ok, "Treasury yield transfer failed");

        emit YieldHarvested(total, toLp, toT, block.timestamp);
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
            if (block.timestamp - updatedAt > 3600) return; // Feed stale (>1hr)
            if (answer <= 0) return;                        // Invalid answer

            if (answer < DEPEG_THRESH && !cbETHPaused) {
                cbETHPaused = true;
                emit CbETHPaused(uint256(int256(1e8) - answer) * 100 / 1e8, block.timestamp);
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
    function savDeposit(uint256 amount) external onlyTreasury notSlashed {
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
    function savBurn(uint256 amount) external onlyCouncilMember savNotPaused notSlashed {
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
        if (p.expiry > 0 && block.timestamp < p.expiry && !p.executed) {
            revert ProposalStillActive();
        }
        p.hasApproved[COUNCIL_0] = false;
        p.hasApproved[COUNCIL_1] = false;
        p.hasApproved[COUNCIL_2] = false;
        p.hasApproved[COUNCIL_3] = false;
        p.approvals = 0;
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
    ) external onlyTreasury savNotPaused notSlashed {
        if (amount == 0) revert ZeroAmount();

        Proposal storage p = proposals[proposalHash];
        if (p.expiry == 0)                   revert ProposalNotFound();
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
     *           · cbETH / rETH (staked principal)
     *           · WETH (transient during DAI swaps)
     *         Native ETH is never swept here — it may be legitimate accumulator
     *         balance. Use the Treasury's manual `routeETH` call if ETH needs
     *         to move via the protocol's own path.
     */
    function rescueToken(address token, uint256 amount) external onlyTreasury {
        if (token == address(STEEL_TOKEN)) revert RescueBlocked();
        if (token == address(DAI))         revert RescueBlocked();
        if (token == address(cbETH))       revert RescueBlocked();
        if (token == address(rETH))        revert RescueBlocked();
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

    function getState() external view returns (
        uint256 accumulated,
        uint256 daiReserve_,
        uint256 cbPrincipal,
        uint256 rPrincipal,
        bool    routingPaused_,
        bool    cbPaused_,
        uint256 nextRouteAllowed
    ) {
        return (
            accumulatedETH,
            daiReserve,
            cbETHPrincipal,
            rETHPrincipal,
            routingPaused,
            cbETHPaused,
            lastRouteTime + ROUTE_COOLDOWN
        );
    }

    function isDaiReserveFull() external view returns (bool) {
        return daiReserve >= DAI_TARGET;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            RECEIVE / FALLBACK
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
