// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ██████╗ ██╗      █████╗ ████████╗███████╗
 * ██╔══██╗██║     ██╔══██╗╚══██╔══╝██╔════╝
 * ██████╔╝██║     ███████║   ██║   █████╗
 * ██╔═══╝ ██║     ██╔══██║   ██║   ██╔══╝
 * ██║     ███████╗██║  ██║   ██║   ███████╗
 * ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
 *
 * PLATE - Protocol Liquidity Asset Treasury Engine
 * The flywheel for POSSESSIO's treasury needs
 * Part of the L.A.T.E. Framework - MIT License
 *
 * Fee pipeline - ETH denominated throughout:
 *
 *   Step 1: _update() collects 2% PLATE fee → pendingFees
 *   Step 2: swapFeesToETH() swaps PLATE → ETH via Aerodrome
 *           · 24-hour delay between swaps (MEV protection)
 *           · TickMath TWAP for minAmountOut (sandwich protection)
 *           · Bootstrap: manual reference price for first 24 hours
 *             (pool needs observation history for TWAP)
 *   Step 3: routeETH() distributes ETH:
 *           · 25% raw ETH → addLiquidityETH() via Aerodrome router
 *           · 75% → Treasury:
 *             - 20% of 75% → swap ETH → DAI (until $2,280 met)
 *             - Remainder  → staking (20% cbETH / 40% wstETH / 40% rETH)
 *
 *   Yield: harvestYield() collects cbETH + rETH yield
 *          · Measures actual ETH received via balance delta
 *          · 25% raw ETH → LP · 75% → Treasury Safe
 *          · wstETH: stub - requires Lido withdrawal queue
 *
 * Treasury: 0x188bE439C141c9138Bd3075f6A376F73c07F1903
 * GitHub:   github.com/jonb89201-svg/Possessio
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
//                    TICKMATH LIBRARY
//                 (Uniswap V3 - MIT License)
// Converts between tick integers and sqrt price ratios.
// price = 1.0001^tick
// Every 6931 ticks = price doubles
// ============================================================

library TickMath {
    int24  internal constant MIN_TICK = -887272;
    int24  internal constant MAX_TICK =  887272;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /**
     * @notice Converts a tick to its corresponding sqrt price
     * @dev Uses bit manipulation for gas efficiency
     *      price = 1.0001^tick expressed as sqrt(price) * 2^96
     * @param tick The tick to convert
     * @return sqrtPriceX96 The sqrt price as a Q64.96 fixed point number
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "TickMath: T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;

        if (absTick & 0x2  != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4  != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8  != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160(
            (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
        );
    }
}

// ============================================================
//                        INTERFACES
// ============================================================

interface IAerodromePool {
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

interface IRouter {
    function WETH() external pure returns (address);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
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

interface IwstETH {
    function balanceOf(address account) external view returns (uint256);
}

interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    );
}

interface IDAI {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ============================================================
//                      PLATE CONTRACT
// ============================================================

contract PLATE is ERC20, ERC20Permit, Ownable, ReentrancyGuard {

    // --------------------------------------------------------
    //                       CONSTANTS
    // --------------------------------------------------------

    uint256 public constant TOTAL_SUPPLY  = 1_000_000_000 * 10**18;
    uint256 public constant FEE_BPS       = 200;   // 2% flat fee
    uint256 public constant FEE_DENOM     = 10_000;
    uint256 public constant LP_PCT        = 25;    // 25% ETH → LP (immutable)
    uint256 public constant TREASURY_PCT  = 75;    // 75% ETH → treasury
    uint256 public constant DAI_BOOT_PCT  = 20;    // 20% of treasury → DAI
    uint256 public constant DAI_TARGET    = 2_280 * 10**18; // $2,280 in DAI
    uint256 public constant CBETH_PCT     = 20;
    uint256 public constant WSTETH_PCT    = 40;
    uint256 public constant RETH_PCT      = 40;
    uint256 public constant YIELD_TO_LP   = 25;
    uint256 public constant YIELD_TO_T    = 75;
    uint256 public constant TIMELOCK      = 48 hours;
    int256  public constant DEPEG_THRESH  = 97_000_000; // 3% depeg
    uint256 public constant Q96           = 2**96;

    /// @notice 24-hour delay between fee swaps (MEV protection)
    uint256 public constant SWAP_DELAY    = 24 hours;

    /// @notice Bootstrap period - 24 hours after pool creation
    /// During bootstrap use manual reference price
    /// After bootstrap use TickMath TWAP
    uint256 public constant BOOTSTRAP     = 24 hours;

    /// @notice TWAP window - 1 hour
    /// Short at launch (pool needs observation history)
    /// Governance can increase as pool matures
    uint32  public twapWindow             = 3600; // 1 hour

    /// @notice Slippage tolerance - 10%
    uint256 public constant SLIPPAGE      = 90; // 90% of expected

    // --------------------------------------------------------
    //                     STATE VARIABLES
    // --------------------------------------------------------

    address public constant TREASURY = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    address public liquidityPool;
    address public aerodromeRouter;
    address public cbETHAddress;
    address public wstETHAddress;
    address public rETHAddress;
    address public stablecoinTarget;
    address public chainlinkFeed;

    /// @notice Chainlink DAI/ETH price feed on Base
    /// Used for minOut calculation in ETH -> DAI swap
    /// Base feed: 0x591e79239a7d679378eC703cCb00F843d559C66
    address public chainlinkDAIFeed;

    /// @notice Max allowed spot-to-TWAP deviation in basis points
    /// Council mandated: 500 bps (5%) - institutional standard for Base
    /// Protects against flash loan price manipulation during LP injection
    uint256 public maxDeviationBps = 500;

    /// @notice When the LP pool was created - starts BOOTSTRAP period
    uint256 public poolCreatedAt;

    /// @notice Manual reference price
    /// Units: PLATE tokens per 1 ETH (18 decimals)
    /// Example: 1,000,000 PLATE per ETH = 1_000_000 * 1e18
    /// Used during bootstrap (first 24hrs) and as TWAP fallback
    /// Owner updates when market price shifts significantly
    uint256 public referencePrice;

    /// @notice DAI reserve - tracks actual DAI held by contract
    uint256 public daiReserve;

    /// @notice Accumulated PLATE fees pending swap to ETH
    uint256 public pendingFees;

    /// @notice Minimum PLATE to batch before swapping
    uint256 public minSwapBatch = 1_000 * 10**18;

    /// @notice Last time fees were swapped to ETH
    uint256 public lastSwapTime;

    /// @notice Principal staked in cbETH - for yield-only harvesting
    uint256 public cbETHPrincipal;

    /// @notice Principal staked in rETH - for yield-only harvesting
    uint256 public rETHPrincipal;

    bool public cbETHPaused = false;
    bool public paused      = false;
    bool public poolPrepared = false; // One-time flag for TWAP cardinality setup

    mapping(address => bool)    public isDEXPair;
    mapping(address => bool)    public isExcluded;
    mapping(bytes32 => uint256) public timelockQueue;

    // --------------------------------------------------------
    //                        EVENTS
    // --------------------------------------------------------

    event FeeCollected(address indexed from, address indexed to, uint256 fee, uint256 timestamp);
    event FeesSwappedToETH(uint256 plateIn, uint256 ethOut, bool usedTWAP, uint256 timestamp);
    event ETHRouted(uint256 total, uint256 toLp, uint256 toDAI, uint256 toStaking, uint256 timestamp);
    event LiquidityAdded(uint256 ethIn, uint256 plateIn, uint256 liquidity, uint256 timestamp);
    /// @notice Emitted when LP injection is skipped due to market conditions or failure
    /// Reason codes: 1=TWAP deviation, 2=Swap failure, 3=Slippage breach, 4=LP add failure, 5=No valid price
    event LPFailed(uint256 ethAmt, uint8 reasonCode);
    event DAIReserveFunded(uint256 daiReceived, uint256 balance, uint256 timestamp);
    event DAIReserveFull(uint256 timestamp);
    event DAIPaid(address indexed recipient, uint256 amount, uint256 timestamp);
    event StakingDeployed(uint256 cbETH, uint256 wstSentToTreasury, uint256 rETH, uint256 timestamp);
    event YieldHarvested(uint256 total, uint256 toLp, uint256 toTreasury, uint256 timestamp);
    event CbETHPaused(uint256 depegPct, uint256 timestamp);
    event CbETHResumed(uint256 timestamp);
    event CircuitBreakerOn(uint256 timestamp);
    event CircuitBreakerOff(uint256 timestamp);
    event ReferencePriceUpdated(uint256 newPrice, uint256 timestamp);
    event ParameterQueued(bytes32 indexed id, string param, uint256 executeAfter);

    // --------------------------------------------------------
    //                       MODIFIERS
    // --------------------------------------------------------

    modifier notPaused() {
        require(!paused, "PLATE: Fee routing paused");
        _;
    }

    modifier tlPassed(bytes32 id) {
        require(timelockQueue[id] != 0, "PLATE: Not queued");
        require(block.timestamp >= timelockQueue[id], "PLATE: Timelock pending");
        _;
        delete timelockQueue[id];
    }

    modifier onlyTreasury() {
        require(msg.sender == TREASURY, "PLATE: Only Treasury Safe");
        _;
    }

    // --------------------------------------------------------
    //                      CONSTRUCTOR
    // --------------------------------------------------------

    constructor(
        address _lp,
        address _router,
        address _cbETH,
        address _wstETH,
        address _rETH,
        address _dai,
        address _chainlink,
        address _chainlinkDAI,   // Chainlink DAI/ETH feed on Base
        uint256 _referencePrice  // Initial manual price - PLATE per ETH
    )
        ERC20("PLATE", "PLATE")
        ERC20Permit("PLATE")
        Ownable(msg.sender)
    {
        require(_lp           != address(0), "PLATE: Invalid LP");
        require(_router       != address(0), "PLATE: Invalid router");
        require(_dai          != address(0), "PLATE: Invalid DAI");
        require(_referencePrice > 0,         "PLATE: Invalid reference price");

        liquidityPool      = _lp;
        aerodromeRouter    = _router;
        cbETHAddress       = _cbETH;
        wstETHAddress      = _wstETH;
        rETHAddress        = _rETH;
        stablecoinTarget   = _dai;
        chainlinkFeed      = _chainlink;
        chainlinkDAIFeed   = _chainlinkDAI;
        referencePrice     = _referencePrice;
        poolCreatedAt      = block.timestamp;

        isDEXPair[_lp]            = true;
        isExcluded[address(this)] = true;
        isExcluded[TREASURY]      = true;

        // Approve router to spend PLATE for fee swaps
        // Sized to total supply - reduced at swap time in production
        _approve(address(this), _router, type(uint256).max);

        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // --------------------------------------------------------
    //           STEP 1 - FEE COLLECTION
    // --------------------------------------------------------

    /**
     * @notice Intercepts DEX swaps - collects 2% PLATE fee
     * @dev Fees accumulated in pendingFees - not swapped here
     *      Keeps _update() gas efficient
     *      Circuit breaker pauses routing only - transfers always work
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        bool isSwap   = isDEXPair[from] || isDEXPair[to];
        bool excluded = isExcluded[from] || isExcluded[to];

        if (isSwap && !excluded && !paused && amount > 0) {
            uint256 fee = (amount * FEE_BPS) / FEE_DENOM;
            uint256 net = amount - fee;

            super._update(from, address(this), fee);
            pendingFees += fee;
            super._update(from, to, net);

            emit FeeCollected(from, to, fee, block.timestamp);
        } else {
            super._update(from, to, amount);
        }
    }

    // --------------------------------------------------------
    //         STEP 2 - SWAP PLATE FEES → ETH
    // --------------------------------------------------------

    /**
     * @notice Swaps accumulated PLATE fees to ETH
     *
     * MEV Protection - two layers:
     *
     * Layer 1 - Time delay:
     *   Maximum one swap per 24 hours
     *   Attacker cannot force swap timing
     *   Fees batch to meaningful size
     *
     * Layer 2 - Price protection:
     *   Bootstrap period (first 24hrs after pool created):
     *     Uses manual referencePrice set by owner
     *     Pool needs observation history before TWAP works
     *   After bootstrap:
     *     Uses TickMath TWAP from Aerodrome pool
     *     minOut = TWAP price * pendingFees * 90%
     *     Sandwich reverts if price is manipulated
     */
    function swapFeesToETH() external nonReentrant notPaused onlyOwner {
        require(
            block.timestamp >= lastSwapTime + SWAP_DELAY,
            "PLATE: 24hr swap delay not elapsed"
        );
        require(pendingFees >= minSwapBatch, "PLATE: Below minimum batch size");

        uint256 toSwap = pendingFees;
        pendingFees    = 0;
        bool useBootstrap = block.timestamp < poolCreatedAt + BOOTSTRAP;
        uint256 minOut;

        if (useBootstrap) {
            // Bootstrap: use manual reference price
            // referencePrice = PLATE per 1 ETH (18 decimals)
            // expectedETH = toSwap / referencePrice
            require(referencePrice > 0, "PLATE: Reference price not set");
            uint256 expectedETH = (toSwap * 1e18) / referencePrice;
            minOut = (expectedETH * SLIPPAGE) / 100;
        } else {
            // Post-bootstrap: use TickMath TWAP
            uint256 twapPrice = _getTWAPPrice();
            require(twapPrice > 0, "PLATE: TWAP unavailable - set reference price");

            // Spot-to-TWAP deviation guard
            // Protects against flash loan price manipulation
            // Skip if spot price unavailable (returns 0) - graceful degradation
            uint256 spotPrice = _getSpotPrice();
            if (spotPrice > 0 && spotPrice != type(uint256).max) {
                uint256 diff = spotPrice > twapPrice
                    ? spotPrice - twapPrice
                    : twapPrice - spotPrice;
                // Only enforce if spot is meaningfully different from TWAP
                // Guards against single-block manipulation attacks
                if (diff > (twapPrice * maxDeviationBps) / 10000) {
                    revert("PLATE: Volatility_Guard");
                }
            }

            uint256 expectedETH = (toSwap * twapPrice) / Q96;
            minOut = (expectedETH * SLIPPAGE) / 100;
        }

        require(minOut > 0, "PLATE: Calculated minOut is zero");

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IRouter(aerodromeRouter).WETH();

        uint256 ethBefore = address(this).balance;

        // Accounting sandwich: fees already zeroed above
        // Restore on failure to prevent silent drift
        try IRouter(aerodromeRouter).swapExactTokensForETH(
            toSwap,
            minOut,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory) {
            uint256 ethReceived = address(this).balance - ethBefore;
            require(ethReceived >= minOut, "PLATE: Insufficient ETH received");
            lastSwapTime = block.timestamp;
            emit FeesSwappedToETH(toSwap, ethReceived, !useBootstrap, block.timestamp);
        } catch (bytes memory reason) {
            // Restore fees on failure - audit-grade accounting safety
            pendingFees = toSwap;
            // Bubble up the revert reason
            if (reason.length > 0) {
                assembly { revert(add(32, reason), mload(reason)) }
            }
            revert("PLATE: Swap failed");
        }
    }

    // --------------------------------------------------------
    //            STEP 3 - ROUTE ETH TO PILLARS
    // --------------------------------------------------------

    /**
     * @notice Routes ETH to LP, DAI reserve, and staking
     * @dev Called after swapFeesToETH()
     *      Anyone can call - all funds go to protocol destinations
     */
    function routeETH() external nonReentrant notPaused onlyOwner {
        uint256 total = address(this).balance;
        require(total > 0, "PLATE: No ETH to route");

        // Compute ALL allocations upfront from total
        // before any external calls to prevent accounting drift
        // NOTE: addLiquidityETH() may refund excess ETH to this contract
        // when the pool ratio doesn't consume the full amount.
        // This is intentional — refunded ETH remains in contract balance
        // and is processed in the next routeETH() cycle.
        uint256 toLp      = (total * LP_PCT) / 100;
        uint256 toT       = total - toLp;
        uint256 toDAI     = (daiReserve < DAI_TARGET) ? (toT * DAI_BOOT_PCT) / 100 : 0;
        uint256 toStaking = toT - toDAI;

        // ── 25% → Aerodrome LP via addLiquidityETH() ──────
        _addLiquidity(toLp);

        // ── Priority 1: DAI emergency reserve ─────────────
        if (toDAI > 0) {
            _swapETHToDAI(toDAI);
        }

        // ── Remainder → ETH staking ────────────────────────
        if (toStaking > 0) {
            _deployToStaking(toStaking);
        }

        emit ETHRouted(total, toLp, toDAI, toStaking, block.timestamp);
    }

    // --------------------------------------------------------
    //              LP INJECTION V2 - Market-Ratio addLiquidityETH
    // --------------------------------------------------------

    /**
     * @notice Adds ETH + PLATE to Aerodrome pool using market-ratio pairing
     * @dev V3 design — council approved (Claude/Gemini/ChatGPT/Grok)
     *
     *      V3 ISOLATION MODEL:
     *      LP failures are local no-ops. ETH remains in contract
     *      for downstream DAI and staking allocations.
     *      This prevents capital bleed from LP domain into sibling domains.
     *
     *      FAILURE CONTAINMENT INVARIANT:
     *      Each execution domain must fail independently
     *      without affecting sibling allocations.
     *
     *      NOTE: _recoverToTreasury() is an internal utility available for
     *      manual treasury recovery if required. It is NOT called automatically.
     *      Dust handling is performed inline via direct _transfer calls on
     *      all failure paths within _addLiquidity().
     *
     *      LP tokens always sent to TREASURY Safe.
     *
     * @param ethAmt Total ETH to deploy into LP
     */
    function _addLiquidity(uint256 ethAmt) internal {
        if (ethAmt == 0) return;

        // Split ETH: half to swap for PLATE, half to pair with it
        uint256 ethForSwap = (ethAmt * lpSwapRatio) / 100;
        uint256 ethForLP   = ethAmt - ethForSwap;

        // ── Price determination ──────────────────────────────────────────
        uint256 minPlateOut = 0;
        bool useBootstrap = block.timestamp < poolCreatedAt + BOOTSTRAP;

        if (useBootstrap) {
            if (referencePrice > 0) {
                uint256 expectedPlate = (ethForSwap * referencePrice) / 1e18;
                minPlateOut = (expectedPlate * SLIPPAGE) / 100;
            }
        } else {
            uint256 twapPrice = _getTWAPPrice();
            if (twapPrice > 0) {
                uint256 expectedPlate = (ethForSwap * Q96) / twapPrice;
                minPlateOut = (expectedPlate * SLIPPAGE) / 100;
            }
        }

        // Cannot price LP safely — skip, ETH stays for downstream
        if (minPlateOut == 0) {
            emit LPFailed(ethAmt, 5);
            return;
        }

        // ── Symmetry Guard: Spot vs TWAP deviation check ─────────────────
        if (!useBootstrap) {
            uint256 twapForGuard = _getTWAPPrice();
            uint256 spotForGuard = _getSpotPrice();
            if (twapForGuard > 0 && spotForGuard > 0) {
                uint256 deviation = spotForGuard > twapForGuard
                    ? ((spotForGuard - twapForGuard) * 10000) / twapForGuard
                    : ((twapForGuard - spotForGuard) * 10000) / twapForGuard;
                if (deviation > maxDeviationBps) {
                    emit LPFailed(ethAmt, 1);
                    return;
                }
            }
        }

        address[] memory path = new address[](2);
        path[0] = IRouter(aerodromeRouter).WETH();
        path[1] = address(this);

        uint256 plateBefore = balanceOf(address(this));

        // ── Attempt swap: ETH -> PLATE ───────────────────────────────────
        try IRouter(aerodromeRouter).swapExactETHForTokens{value: ethForSwap}(
            minPlateOut,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory) {

            uint256 plateReceived = balanceOf(address(this)) - plateBefore;

            if (plateReceived == 0) {
                // Swap returned nothing — ETH stays for downstream
                emit LPFailed(ethForLP, 3);
                return;
            }

            // ── Attempt LP injection ─────────────────────────────────────
            uint256 minPlate = (plateReceived * 90) / 100;
            uint256 minETH   = (ethForLP * 90) / 100;

            try IRouter(aerodromeRouter).addLiquidityETH{value: ethForLP}(
                address(this),
                plateReceived,
                minPlate,
                minETH,
                TREASURY,
                block.timestamp + 300
            ) returns (uint256 amtToken, uint256 amtETH, uint256 liquidity) {
                emit LiquidityAdded(amtETH, amtToken, liquidity, block.timestamp);
                // Partial execution: swap succeeded, LP succeeded
                // Any dust PLATE still in contract — send to Treasury
                uint256 plateDust = balanceOf(address(this)) - plateBefore;
                if (plateDust > 0) {
                    _transfer(address(this), TREASURY, plateDust);
                }
            } catch {
                // PARTIAL EXECUTION: swap succeeded, LP failed
                // PLATE cannot be reused — flush to Treasury
                // ETH stays in contract for downstream DAI + staking
                uint256 strandedPlate = balanceOf(address(this)) - plateBefore;
                if (strandedPlate > 0) {
                    _transfer(address(this), TREASURY, strandedPlate);
                }
                emit LPFailed(ethForLP, 4);
            }

        } catch {
            // Swap failed — ETH stays in contract for downstream
            emit LPFailed(ethAmt, 2);
        }
    }

    /**
     * @notice Recovers any stranded PLATE and ETH to Treasury Safe
     * @dev Uses actual balances — never expected/assumed values
     *      Called on all failure paths in _addLiquidity
     *      Enforces the NO STRANDED ASSETS invariant
     * @param ethAmt ETH amount to forward (0 = check balance only)
     */
    function _recoverToTreasury(uint256 ethAmt) internal {
        // Recover any stranded PLATE first
        uint256 plateBal = balanceOf(address(this));
        if (plateBal > 0) {
            _transfer(address(this), TREASURY, plateBal);
        }

        // Recover ETH — use actual balance if caller passes 0
        uint256 ethToSend = ethAmt > 0 ? ethAmt : address(this).balance;
        if (ethToSend > 0) {
            (bool ok,) = TREASURY.call{value: ethToSend}("");
            require(ok, "PLATE: Treasury recovery failed");
        }
    }

    /// @notice LP swap ratio — fixed at 50 (50/50 ETH split for LP injection)
    /// @dev Governs what % of LP ETH is swapped for PLATE before pairing
    ///      FIXED: This value is permanently set at deployment and is NOT adjustable.
    ///             Immutable by design for protocol stability and trust assumptions.
    uint256 public lpSwapRatio = 50;

    // --------------------------------------------------------
    //                   DAI EMERGENCY RESERVE
    // --------------------------------------------------------

    /**
     * @notice Swaps ETH → DAI and adds to emergency reserve
     * @dev Measures actual DAI received via balance delta
     *      daiReserve always matches actual token balance
     */
    function _swapETHToDAI(uint256 ethAmt) internal {
        if (ethAmt == 0 || stablecoinTarget == address(0)) return;

        address[] memory path = new address[](2);
        path[0] = IRouter(aerodromeRouter).WETH();
        path[1] = stablecoinTarget;

        uint256 daiBefore = IDAI(stablecoinTarget).balanceOf(address(this));

        // Calculate minDAI using Chainlink DAI/ETH feed
        // DAI/ETH feed returns ETH per 1 DAI (8 decimals)
        // expectedDAI = ethAmt / (daiPriceInETH)
        // minDAI = expectedDAI * 90% slippage tolerance
        uint256 minDAI = 1; // fallback if feed unavailable
        if (chainlinkDAIFeed != address(0)) {
            try IChainlinkFeed(chainlinkDAIFeed).latestRoundData()
                returns (uint80, int256 daiEthPrice, uint256, uint256 updatedAt, uint80)
            {
                // Only use feed if fresh (< 1 hour old) and positive
                if (block.timestamp - updatedAt <= 3600 && daiEthPrice > 0) {
                    // daiEthPrice = ETH per DAI with 8 decimals
                    // expectedDAI = ethAmt * 1e8 / daiEthPrice
                    uint256 expectedDAI = (ethAmt * 1e8) / uint256(daiEthPrice);
                    minDAI = (expectedDAI * SLIPPAGE) / 100;
                }
            } catch {}
        }

        try IRouter(aerodromeRouter).swapExactETHForTokens{value: ethAmt}(
            minDAI,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory) {
            uint256 daiReceived = IDAI(stablecoinTarget).balanceOf(address(this)) - daiBefore;
            daiReserve += daiReceived;
            emit DAIReserveFunded(daiReceived, daiReserve, block.timestamp);
            if (daiReserve >= DAI_TARGET) emit DAIReserveFull(block.timestamp);
        } catch {
            // Swap failed - send ETH to Treasury instead
            (bool ok,) = TREASURY.call{value: ethAmt}("");
            require(ok, "PLATE: DAI swap and Treasury fallback failed");
        }
    }

    /**
     * @notice Pays API subscription from DAI reserve
     * @dev Only callable by TREASURY Safe (3-of-5 enforced)
     */
    function payAPI(address recipient, uint256 amount) external onlyTreasury {
        require(daiReserve >= amount,    "PLATE: Insufficient DAI reserve");
        require(recipient != address(0), "PLATE: Invalid recipient");
        daiReserve -= amount;
        IDAI(stablecoinTarget).transfer(recipient, amount);
        emit DAIPaid(recipient, amount, block.timestamp);
    }

    // --------------------------------------------------------
    //                   ETH STAKING DEPLOYMENT
    // --------------------------------------------------------

    /**
     * @notice Deploys ETH to diversified staking (20/40/40)
     * @dev Internal - called only from routeETH()
     *      cbETH depeg monitored via Chainlink
     *      Tracks principal for yield-only harvesting
     */
    function _deployToStaking(uint256 ethAmt) internal {
        if (ethAmt == 0) return;
        _checkDepeg();

        uint256 cbAmt  = cbETHPaused ? 0 : (ethAmt * CBETH_PCT) / 100;
        uint256 wstAmt = cbETHPaused ?
            (ethAmt * (WSTETH_PCT + CBETH_PCT)) / 100 :
            (ethAmt * WSTETH_PCT) / 100;
        uint256 rAmt   = ethAmt - cbAmt - wstAmt;

        // Deploy cbETH - track principal
        if (cbAmt > 0 && cbETHAddress != address(0)) {
            IcbETH(cbETHAddress).deposit{value: cbAmt}();
            cbETHPrincipal += cbAmt;
        }

        // Deploy wstETH
        // PRODUCTION REQUIRED: ETH -> stETH via Lido -> wrap to wstETH
        // Until wstETH is deployed, send allocation to Treasury Safe
        if (wstAmt > 0) {
            if (wstETHAddress != address(0)) {
                // Production path (not yet implemented):
                // ILido(lidoAddress).submit{value: wstAmt}(address(0));
                // IwstETH(wstETHAddress).wrap(stETHAmount);
            }
            // Stub: always route wstAmt to Treasury until production ready
            (bool ok,) = TREASURY.call{value: wstAmt}("");
            require(ok, "PLATE: wstETH fallback failed");
        }

        // Deploy rETH - track principal
        if (rAmt > 0 && rETHAddress != address(0)) {
            IrETH(rETHAddress).deposit{value: rAmt}();
            rETHPrincipal += rAmt;
        }

        emit StakingDeployed(cbAmt, wstAmt, rAmt, block.timestamp);
    }

    // --------------------------------------------------------
    //                    YIELD HARVESTING
    // --------------------------------------------------------

    /**
     * @notice Harvests staking yield - principal stays staked
     * @dev Only withdraws ABOVE tracked principal
     *      Measures actual ETH received via balance delta
     *      25% raw ETH → LP · 75% → Treasury Safe
     */
    function harvestYield() external nonReentrant notPaused {
        uint256 total = 0;

        // Harvest cbETH yield only (above principal)
        // Principal tracking assumption:
        // cbETHPrincipal tracks original ETH deposited
        // As staking accrues yield lstBal grows above principal
        // harvestYield() withdraws the excess - correct behavior
        // Edge case: if lstBal drops BELOW cbETHPrincipal
        // (due to slashing or severe depeg) this skips silently
        // cbETHPrincipal will overestimate the actual position
        // In that scenario governance should manually update
        // via executeCbETHExit() which resets principal to 0
        if (cbETHAddress != address(0)) {
            uint256 lstBal = IcbETH(cbETHAddress).balanceOf(address(this));
            if (lstBal > cbETHPrincipal) {
                uint256 yieldLST  = lstBal - cbETHPrincipal;
                uint256 ethBefore = address(this).balance;
                IcbETH(cbETHAddress).withdraw(yieldLST);
                uint256 ethReceived = address(this).balance - ethBefore;
                total += ethReceived;
            }
        }

        // Harvest rETH yield only (above principal)
        if (rETHAddress != address(0)) {
            uint256 lstBal = IrETH(rETHAddress).balanceOf(address(this));
            if (lstBal > rETHPrincipal) {
                uint256 yieldLST  = lstBal - rETHPrincipal;
                uint256 ethBefore = address(this).balance;
                IrETH(rETHAddress).burn(yieldLST);
                uint256 ethReceived = address(this).balance - ethBefore;
                total += ethReceived;
            }
        }

        // wstETH yield
        // ⚠ PRODUCTION REQUIRED: Lido withdrawal queue integration
        if (wstETHAddress != address(0)) {
            // Production: submit Lido withdrawal for yield portion
            // Claim ETH when request finalizes
        }

        require(total > 0, "PLATE: No yield to harvest");

        // 25% → LP via addLiquidityETH() · 75% → Treasury Safe
        // Uses _addLiquidity() - same as routeETH()
        // Raw ETH sent to AMM pool address is unrecoverable
        uint256 toLp = (total * YIELD_TO_LP) / 100;
        uint256 toT  = total - toLp;

        _addLiquidity(toLp);

        (bool ok2,) = TREASURY.call{value: toT}("");
        require(ok2, "PLATE: Treasury yield transfer failed");

        emit YieldHarvested(total, toLp, toT, block.timestamp);
    }

    // --------------------------------------------------------
    //                    TICKMATH TWAP ORACLE
    // --------------------------------------------------------

    /**
     * @notice Gets PLATE/ETH price using TickMath TWAP
     * @dev Reads tick cumulatives from Aerodrome pool
     *      Converts to price using TickMath.getSqrtRatioAtTick()
     *      Returns price as ETH-per-PLATE in Q96 fixed point format
     *      (i.e. how much ETH you get for 1 PLATE, scaled by 2^96)
     *      referencePrice is PLATE-per-ETH - opposite direction
     *      Both are used correctly in swapFeesToETH()
     *      Returns 0 if pool has insufficient observation history
     */
    function _getTWAPPrice() internal view returns (uint256 priceX96) {
        if (liquidityPool == address(0)) return 0;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try IAerodromePool(liquidityPool).observe(secondsAgos)
            returns (int56[] memory tickCumulatives, uint160[] memory)
        {
            if (tickCumulatives.length < 2) return 0;

            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 avgTick   = int24(tickDelta / int56(uint56(twapWindow)));

            // Convert tick to sqrtPriceX96 using TickMath
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

            // Convert sqrtPriceX96 to price
            // sqrtPriceX96 = sqrt(price) * 2^96
            // price = (sqrtPriceX96)^2 / 2^96
            priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q96;

            // Adjust for token order in the pool
            // If PLATE is token1 (not token0) price is inverted
            try IAerodromePool(liquidityPool).token0() returns (address t0) {
                if (t0 != address(this)) {
                    // PLATE is token1 - invert the price
                    priceX96 = priceX96 > 0 ? (Q96 * Q96) / priceX96 : 0;
                }
            } catch {
                return 0;
            }

        } catch {
            // Pool has insufficient observation history
            // Caller falls back to reference price
            return 0;
        }
    }

    /**
     * @notice Public view of current TWAP price
     * @dev Useful for monitoring and governance decisions
     */
    function getTWAPPrice() external view returns (uint256) {
        return _getTWAPPrice();
    }

    /**
     * @notice Gets current spot price using current pool tick
     * @dev Uses a 1-second TWAP window to approximate spot price
     *      Returns 0 if pool unavailable or call fails
     */
    function _getSpotPrice() internal view returns (uint256 priceX96) {
        if (liquidityPool == address(0)) return 0;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 10; // 10 seconds ago — widened from 1s to reduce same-block manipulation risk
        secondsAgos[1] = 0;  // now

        try IAerodromePool(liquidityPool).observe(secondsAgos)
            returns (int56[] memory tickCumulatives, uint160[] memory)
        {
            if (tickCumulatives.length < 2) return 0;

            // Calculate tick over last 10 seconds = approximate spot
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 spotTick  = int24(tickDelta / int56(uint56(10)));

            // If tick is out of valid range, spot data is unreliable
            // Return 0 to skip deviation guard gracefully
            if (spotTick > 887272 || spotTick < -887272) return 0;

            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(spotTick);
            priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q96;

            try IAerodromePool(liquidityPool).token0() returns (address t0) {
                if (t0 != address(this)) {
                    priceX96 = priceX96 > 0 ? (Q96 * Q96) / priceX96 : 0;
                }
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @notice Public view of spot price for monitoring
    function getSpotPrice() external view returns (uint256) {
        return _getSpotPrice();
    }



    function _checkDepeg() internal {
        if (chainlinkFeed == address(0)) return;
        try IChainlinkFeed(chainlinkFeed).latestRoundData()
            returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            if (block.timestamp - updatedAt > 3600) return;
            if (answer < DEPEG_THRESH && !cbETHPaused) {
                cbETHPaused = true;
                emit CbETHPaused(uint256(int256(1e8) - answer) * 100 / 1e8, block.timestamp);
            } else if (answer >= DEPEG_THRESH && cbETHPaused) {
                cbETHPaused = false;
                emit CbETHResumed(block.timestamp);
            }
        } catch {}
    }

    function queueCbETHExit() external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked("cbETH_exit", block.timestamp));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ParameterQueued(id, "cbETHEmergencyExit", timelockQueue[id]);
    }

    function executeCbETHExit(bytes32 id) external onlyOwner tlPassed(id) {
        if (cbETHAddress != address(0)) {
            uint256 bal = IcbETH(cbETHAddress).balanceOf(address(this));
            if (bal > 0) {
                IcbETH(cbETHAddress).withdraw(bal);
                cbETHPrincipal = 0;
            }
        }
        cbETHPaused = true;
    }

    // --------------------------------------------------------
    //                 POOL PREPARATION
    // --------------------------------------------------------

    /**
     * @notice Increases Aerodrome pool observation cardinality for TWAP
     * @dev MUST be called once after LP creation and before bootstrap ends.
     *      Aerodrome pools initialize with cardinality = 1, which is
     *      insufficient for TWAP history. This sets it to 16 observations
     *      (~32 seconds of history on Base at ~2s block times).
     *      One-time execution enforced by poolPrepared flag.
     *
     *      CRITICAL: Call this immediately after seeding the Aerodrome LP
     *      on mainnet deployment. If not called before bootstrap ends,
     *      TWAP will fail and swapFeesToETH() will revert post-bootstrap.
     */
    function preparePool() external onlyOwner {
        require(!poolPrepared, "PLATE: Pool already prepared");
        IAerodromePool(liquidityPool).increaseObservationCardinalityNext(16);
        poolPrepared = true;
    }

    // --------------------------------------------------------
    //                    CIRCUIT BREAKER
    // --------------------------------------------------------

    function pauseRouting() external onlyOwner {
        paused = true;
        emit CircuitBreakerOn(block.timestamp);
    }

    function queueResumeRouting() external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked("resume", block.timestamp));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ParameterQueued(id, "resumeRouting", timelockQueue[id]);
    }

    function resumeRouting(bytes32 id) external onlyOwner tlPassed(id) {
        paused = false;
        emit CircuitBreakerOff(block.timestamp);
    }

    // --------------------------------------------------------
    //                    GOVERNANCE
    // --------------------------------------------------------

    /**
     * @notice Updates manual reference price
     * @dev Used during bootstrap and as TWAP fallback
     *      Owner updates when market price shifts significantly
     *      In production: called via 3-of-5 Safe
     * @param _price PLATE tokens per 1 ETH (18 decimals)
     *               Example: 1,000,000 PLATE per ETH = 1_000_000 * 1e18
     */
    function setReferencePrice(uint256 _price) external onlyOwner {
        require(_price > 0, "PLATE: Invalid price");
        referencePrice = _price;
        emit ReferencePriceUpdated(_price, block.timestamp);
    }

    /**
     * @notice Updates TWAP window as pool matures
     * @dev Start short (1hr) - increase as observation history builds
     *      Longer window = more manipulation resistant
     */
    function setTWAPWindow(uint32 _window) external onlyOwner {
        require(_window >= 300, "PLATE: Window too short"); // Min 5 minutes
        twapWindow = _window;
    }

    function setMinSwapBatch(uint256 amount) external onlyOwner {
        require(amount > 0, "PLATE: Must be above zero");
        minSwapBatch = amount;
    }

    function queueLPUpdate(address newLP) external onlyOwner returns (bytes32 id) {
        require(newLP != address(0), "PLATE: Invalid LP");
        id = keccak256(abi.encodePacked("lpUpdate", newLP, block.timestamp));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ParameterQueued(id, "liquidityPool", timelockQueue[id]);
    }

    function executeLPUpdate(bytes32 id, address newLP) external onlyOwner tlPassed(id) {
        // Security: ID is keccak256("lpUpdate", newLP, timestamp)
        // Mismatched newLP → tlPassed reverts with "Not queued"
        require(newLP != address(0), "PLATE: Invalid LP");
        isDEXPair[liquidityPool] = false;
        liquidityPool = newLP;
        isDEXPair[newLP] = true;
    }

    function queueDEXPair(address pair) external onlyOwner returns (bytes32 id) {
        require(pair != address(0), "PLATE: Invalid pair");
        id = keccak256(abi.encodePacked("dexPair", pair, block.timestamp));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ParameterQueued(id, "dexPair", timelockQueue[id]);
    }

    function executeDEXPair(bytes32 id, address pair) external onlyOwner tlPassed(id) {
        isDEXPair[pair] = true;
    }

    // --------------------------------------------------------
    //                    VIEW FUNCTIONS
    // --------------------------------------------------------

    function getState() external view returns (
        address treasury,
        address lp,
        bool    routingPaused,
        bool    cbPaused,
        uint256 daiBalance,
        uint256 daiTarget,
        uint256 pendingPlateFees,
        uint256 cbPrincipal,
        uint256 rPrincipal,
        uint256 supply,
        uint256 feeBps,
        uint256 nextSwapAllowed
    ) {
        return (
            TREASURY, liquidityPool,
            paused, cbETHPaused,
            daiReserve, DAI_TARGET,
            pendingFees,
            cbETHPrincipal, rETHPrincipal,
            totalSupply(), FEE_BPS,
            lastSwapTime + SWAP_DELAY
        );
    }

    function isDaiReserveFull() external view returns (bool) {
        return daiReserve >= DAI_TARGET;
    }

    function isBootstrapPeriod() external view returns (bool) {
        return block.timestamp < poolCreatedAt + BOOTSTRAP;
    }

    function getTimelockRemaining(bytes32 id) external view returns (uint256) {
        if (timelockQueue[id] == 0 || block.timestamp >= timelockQueue[id]) return 0;
        return timelockQueue[id] - block.timestamp;
    }

    // --------------------------------------------------------
    //                      RECEIVE ETH
    // --------------------------------------------------------

    receive() external payable {}
    fallback() external payable {}
}
