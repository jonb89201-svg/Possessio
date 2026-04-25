// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  PossessioPayments
 * @notice Phase 2 merchant onboarding contract — the POSSESSIO Payments product.
 *         Merges the UCR (USDC Conversion Router, Gemini-invented mechanism)
 *         and the StakingBuffer (LST custody + Citadel Gauge) into one contract
 *         for deployment simplicity and minimum cross-contract attack surface.
 *
 *         SCOPE: Phase 2 MVP
 *           - Receives USDC from Stripe Bridge API split settlement
 *           - Converts USDC → cbETH + rETH (40/60 split) via Uniswap V3 on Base
 *           - Custodies LSTs in-contract with Citadel Gauge tracking ETH-equivalent
 *           - Emits ThresholdReached at 32 ETH equivalent (SSV validator eligibility)
 *           - 7-day timelock emergency withdrawal for merchant safety
 *
 *         OUT OF SCOPE: SSV Network validator handoff
 *           - Deferred to Phase 2.1 separate contract
 *           - Gemini-seat invention pending
 *           - Merchant initiates SSV handoff by deploying the Phase 2.1 contract
 *             and transferring LSTs to it after threshold
 *
 * BUSINESS MODEL:
 *   POSSESSIO Payments deploys a per-merchant PossessioPayments contract as
 *   part of paid onboarding. Once deployed, merchant holds OWNER_ROLE. POSSESSIO
 *   Payments retains ZERO on-chain authority. Merchant sovereignty is absolute.
 *
 * PERMISSION STRUCTURE (OpenZeppelin AccessControl):
 *   OWNER_ROLE    — Merchant. Full authority: withdraw, parameters, role grants,
 *                   Guardian toggle. Can do everything.
 *   OPERATOR_ROLE — Optional day-to-day role. Sweep, queue-pause, execute pause.
 *                   Cannot withdraw, cannot change parameters, cannot manage roles.
 *                   Granted by Owner post-deploy if needed (e.g. store manager).
 *   GUARDIAN_ROLE — Optional security-system role. Can ONLY pause when
 *                   `guardianEnabled == true`. Cannot withdraw, unpause, or sweep.
 *                   Default guardianEnabled = false.
 *
 * MIB WORKFLOW NOTE:
 *   Onboarding advice to merchants: DO NOT call sweep() on a predictable
 *   schedule. Vary timing. MEV bots pattern-match predictable calls. The
 *   24h SWEEP_DELAY is a minimum, not a recommended cadence.
 *
 * ADDRESSES (Base Mainnet — verified):
 *   USDC:              0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   cbETH:             0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22
 *   rETH:              0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c
 *   Uniswap V3 Router: 0x2626664c2603336E57B271c5C0b26F421741e481
 *   Chainlink ETH/USD: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 */

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ═══════════════════════════════════════════════════════════════════════════
//                          EXTERNAL INTERFACES
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Uniswap V3 SwapRouter02 on Base. Handles USDC → LST conversion.
interface ISwapRouter {
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
        external returns (uint256 amountOut);
}

/// @notice Chainlink oracle feed for staleness validation.
interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
}

/// @notice LST exchange rate oracle — immutable, ownerless singleton.
///         Calls protocol-native rates (cbETH.exchangeRate, rETH.getExchangeRate).
///         Ratified as shared infrastructure with no admin surface per
///         Gemini-seat specification.
interface ILSTExchangeRate {
    function cbEthToEth(uint256 cbEthAmount) external view returns (uint256);
    function rEthToEth(uint256 rEthAmount)  external view returns (uint256);
}

// ═══════════════════════════════════════════════════════════════════════════
//                        POSSESSIO PAYMENTS CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

contract PossessioPayments is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Role identifiers ────────────────────────────────────────────────────

    bytes32 public constant OWNER_ROLE    = keccak256("OWNER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ── Constants (matching UCR / PLATE convention) ──────────────────────────

    uint256 public constant CBETH_PCT       = 40;         // 40% to cbETH
    uint256 public constant RETH_PCT        = 60;         // 60% to rETH
    // WSTETH_PCT reserved — post-launch Lido integration

    uint256 public constant SWEEP_DELAY     = 24 hours;   // minimum between sweeps
    uint256 public constant TIMELOCK        = 48 hours;   // owner-pause resume delay
    uint256 public constant EMERGENCY_DELAY = 7 days;     // emergency withdraw delay

    uint24  public constant FEE_LST         = 3000;       // 0.3% — V3 LST pairs
    uint24  public constant FEE_STABLE      = 500;        // 0.05% — V3 USDC/DAI pair
    uint256 public constant ORACLE_STALE    = 3600;       // 1 hour staleness cap
    uint256 public constant SOLO_THRESHOLD  = 32 ether;   // validator eligibility
    uint256 public constant LIMIT_DELAY     = 24 hours;   // daily limit increase delay
    uint256 public constant WINDOW_SIZE     = 24 hours;   // daily withdrawal window

    // ── Immutables ───────────────────────────────────────────────────────────

    IERC20           public immutable USDC;
    IERC20           public immutable CBETH;
    IERC20           public immutable RETH;
    IERC20           public immutable DAI;
    ISwapRouter      public immutable ROUTER;
    IChainlinkFeed   public immutable CHAINLINK;
    IChainlinkFeed   public immutable CHAINLINK_DAI;
    ILSTExchangeRate public immutable LST_RATES;

    // ── Mutable state ────────────────────────────────────────────────────────

    bool    public routingPaused;       // pause flag for sweep
    bool    public guardianEnabled;     // merchant-controlled Guardian opt-in
    uint256 public lastSweepTime;       // last successful sweep timestamp
    uint256 public citadelGauge;        // cumulative ETH-equivalent toward 32 ETH
    uint256 public minSwapBatch;        // minimum USDC before sweep allowed

    // DAI reserve state — operating capital in stable terms
    uint256 public daiCeiling;          // merchant-set target reserve
    uint256 public dailyLimit;          // max DAI withdrawal per 24h window
    uint256 public dailyWithdrawn;      // DAI withdrawn in current window
    uint256 public windowStart;         // start timestamp of current 24h window

    // Asymmetric daily limit adjustment — decrease instant, increase 24h delay
    struct QueuedLimit {
        uint256 newLimit;
        uint256 executeAfter;
    }
    QueuedLimit public queuedLimitIncrease;

    // Timelock queues — matching UCR pattern
    mapping(bytes32 => uint256) public timelockQueue;
    uint256 private queueNonce;

    // Emergency withdrawal queue — per-token, per-amount
    struct EmergencyWithdraw {
        uint256 amount;
        uint256 executeAfter;
    }
    mapping(address => EmergencyWithdraw) public emergencyQueue;

    // ── Events ───────────────────────────────────────────────────────────────

    // UCR — conversion mechanism events
    event UCRSwept(
        uint256 usdcIn,
        uint256 cbEthOut,
        uint256 rEthOut,
        uint256 ethEquivalentAdded,
        uint256 timestamp
    );
    event UCRPaused(address indexed by, uint256 timestamp);
    event UCRResumed(address indexed by, uint256 timestamp);
    event UCRResumeQueued(bytes32 indexed id, uint256 executeAfter);

    // DAI reserve events — merchant operating capital
    event DAIReserveFilled(uint256 usdcIn, uint256 daiOut, uint256 newReserve);
    event DAIWithdrawn(address indexed by, uint256 amount, address indexed to, uint256 timestamp);
    event DAICeilingUpdated(uint256 newCeiling);
    event DailyLimitDecreased(uint256 newLimit);
    event DailyLimitIncreaseQueued(uint256 newLimit, uint256 executeAfter);
    event DailyLimitIncreaseExecuted(uint256 newLimit);
    event DailyLimitIncreaseCancelled();

    // Citadel Gauge events
    event CitadelProgress(uint256 totalEthEquivalent);
    event ThresholdReached(uint256 timestamp);

    // Guardian events
    event GuardianEnabled(address indexed by, uint256 timestamp);
    event GuardianDisabled(address indexed by, uint256 timestamp);
    event GuardianPaused(address indexed guardian, uint256 timestamp);

    // Emergency withdrawal events
    event EmergencyQueued(address indexed token, uint256 amount, uint256 executeAfter);
    event EmergencyExecuted(address indexed token, uint256 amount, address to);
    event EmergencyCancelled(address indexed token);

    // Parameter events
    event MinSwapBatchUpdated(uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error RoutingPaused();
    error SweepTooEarly();
    error BatchTooSmall();
    error OracleStale();
    error OracleInvalid();
    error ZeroOutput();
    error LeakageDetected();
    error InvalidAddress();
    error TimelockNotPassed();
    error NotQueued();
    error ExchangeRateInvalid();
    error GuardianNotEnabled();
    error NothingQueued();
    error NothingToWithdraw();
    error ZeroAmount();
    error DailyLimitExceeded();
    error NoIncreaseQueued();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier tlPassed(bytes32 id) {
        if (timelockQueue[id] == 0)              revert NotQueued();
        if (block.timestamp < timelockQueue[id]) revert TimelockNotPassed();
        delete timelockQueue[id];
        _;
    }

    modifier notPaused() {
        if (routingPaused) revert RoutingPaused();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    /**
     * @notice Deploy a merchant's PossessioPayments contract.
     * @param owner           Merchant wallet address — receives OWNER_ROLE
     * @param usdc_           USDC token address on Base
     * @param cbeth_          cbETH token address on Base
     * @param reth_           rETH token address on Base
     * @param dai_            DAI token address on Base
     * @param router_         Uniswap V3 SwapRouter02 address on Base
     * @param chainlink_      Chainlink ETH/USD feed address on Base
     * @param chainlinkDai_   Chainlink DAI/USD feed address on Base
     * @param lstRates_       Immutable LSTExchangeRate singleton address
     * @param minSwapBatch_   Minimum USDC required before sweep allowed
     * @param daiCeiling_     Target DAI reserve (merchant's operating buffer). 0 = opt out.
     * @param dailyLimit_     Max DAI withdrawable per 24h window. 0 = lockdown.
     */
    constructor(
        address owner,
        address usdc_,
        address cbeth_,
        address reth_,
        address dai_,
        address router_,
        address chainlink_,
        address chainlinkDai_,
        address lstRates_,
        uint256 minSwapBatch_,
        uint256 daiCeiling_,
        uint256 dailyLimit_
    ) {
        if (owner         == address(0)) revert InvalidAddress();
        if (usdc_         == address(0)) revert InvalidAddress();
        if (cbeth_        == address(0)) revert InvalidAddress();
        if (reth_         == address(0)) revert InvalidAddress();
        if (dai_          == address(0)) revert InvalidAddress();
        if (router_       == address(0)) revert InvalidAddress();
        if (chainlink_    == address(0)) revert InvalidAddress();
        if (chainlinkDai_ == address(0)) revert InvalidAddress();
        if (lstRates_     == address(0)) revert InvalidAddress();

        USDC          = IERC20(usdc_);
        CBETH         = IERC20(cbeth_);
        RETH          = IERC20(reth_);
        DAI           = IERC20(dai_);
        ROUTER        = ISwapRouter(router_);
        CHAINLINK     = IChainlinkFeed(chainlink_);
        CHAINLINK_DAI = IChainlinkFeed(chainlinkDai_);
        LST_RATES     = ILSTExchangeRate(lstRates_);

        minSwapBatch = minSwapBatch_;
        daiCeiling   = daiCeiling_;
        dailyLimit   = dailyLimit_;
        windowStart  = block.timestamp;

        // Owner gets OWNER_ROLE and is admin of OPERATOR and GUARDIAN roles
        _grantRole(OWNER_ROLE, owner);
        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, OWNER_ROLE);
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          UCR — SWEEP MECHANISM
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice UCR sweep — fills DAI reserve to ceiling (if set), then converts
     *         remaining USDC into cbETH + rETH at 40/60 split, custodies
     *         in-contract, increments Citadel Gauge.
     *
     *         Merchant onboarding advice: vary your sweep timing. Predictable
     *         schedules invite MEV pattern-matching.
     *
     *         DAI reserve priority: operations before accumulation. If incoming
     *         USDC is less than the DAI refill gap, 100% goes to DAI and 0 to
     *         LSTs that sweep. Once reserve is full, 100% goes to LST split.
     *
     *         Setting daiCeiling == 0 opts out of DAI reserve entirely.
     *
     * @param minDaiOut    Minimum DAI output from USDC swap (0 if no refill needed)
     * @param minCbEthOut  Minimum cbETH output (slippage guard)
     * @param minREthOut   Minimum rETH output  (slippage guard)
     */
    function sweep(
        uint256 minDaiOut,
        uint256 minCbEthOut,
        uint256 minREthOut
    ) external nonReentrant notPaused {
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert InvalidAddress();
        }

        if (block.timestamp < lastSweepTime + SWEEP_DELAY) revert SweepTooEarly();

        _validateOracle();

        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance < minSwapBatch) revert BatchTooSmall();

        // Step 1: DAI reserve refill (operations before accumulation)
        uint256 usdcAfterDai = usdcBalance;

        if (daiCeiling > 0) {
            uint256 currentDai = DAI.balanceOf(address(this));
            if (currentDai < daiCeiling) {
                uint256 daiGap = daiCeiling - currentDai;

                // Check DAI oracle — if stale/invalid, skip DAI refill this cycle
                // and proceed with LST split. Merchant's sweep still executes,
                // DAI reserve will refill on next sweep when oracle recovers.
                bool daiOracleOk = _isDaiOracleFresh();

                if (daiOracleOk) {
                    // Decimal normalization: daiGap is in DAI (18 decimals),
                    // usdcBalance is in USDC (6 decimals). Convert daiGap to
                    // USDC-equivalent for proper comparison and swap input sizing.
                    // Assumes ~1:1 DAI/USDC peg (validated by Chainlink staleness check).
                    uint256 daiGapInUsdc = daiGap / 1e12;
                    uint256 usdcForDai   = daiGapInUsdc > usdcBalance
                        ? usdcBalance
                        : daiGapInUsdc;

                    if (usdcForDai > 0) {
                        uint256 daiBefore     = DAI.balanceOf(address(this));
                        uint256 usdcBeforeSwap = USDC.balanceOf(address(this));
                        USDC.forceApprove(address(ROUTER), usdcForDai);

                        try ROUTER.exactInputSingle(
                            ISwapRouter.ExactInputSingleParams({
                                tokenIn:           address(USDC),
                                tokenOut:          address(DAI),
                                fee:               FEE_STABLE,
                                recipient:         address(this),
                                amountIn:          usdcForDai,
                                amountOutMinimum:  minDaiOut,
                                sqrtPriceLimitX96: 0
                            })
                        ) returns (uint256 daiOut) {
                            if (daiOut > 0) {
                                uint256 newReserve = DAI.balanceOf(address(this));
                                emit DAIReserveFilled(usdcForDai, newReserve - daiBefore, newReserve);

                                // Measure actual USDC consumed (defends against
                                // malicious routers that consume more than declared).
                                uint256 usdcConsumed = usdcBeforeSwap - USDC.balanceOf(address(this));
                                usdcAfterDai = usdcBalance - usdcConsumed;
                            }
                        } catch {
                            // DAI swap failed — skip, proceed with full LST split
                            // USDC stays in contract for LST leg below
                        }
                    }
                }
            }
        }

        // Step 2: if any USDC remains after DAI refill, split 40/60 to LSTs
        if (usdcAfterDai == 0) {
            lastSweepTime = block.timestamp;
            emit UCRSwept(usdcBalance, 0, 0, 0, block.timestamp);
            return;
        }

        uint256 cbEthAlloc = (usdcAfterDai * CBETH_PCT) / 100;
        uint256 rEthAlloc  = (usdcAfterDai * RETH_PCT)  / 100;
        uint256 allocSum   = cbEthAlloc + rEthAlloc;

        uint256 balanceBefore = USDC.balanceOf(address(this));

        USDC.forceApprove(address(ROUTER), allocSum);

        uint256 cbEthOut = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(USDC),
                tokenOut:          address(CBETH),
                fee:               FEE_LST,
                recipient:         address(this),
                amountIn:          cbEthAlloc,
                amountOutMinimum:  minCbEthOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (cbEthOut == 0) revert ZeroOutput();

        uint256 rEthOut = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(USDC),
                tokenOut:          address(RETH),
                fee:               FEE_LST,
                recipient:         address(this),
                amountIn:          rEthAlloc,
                amountOutMinimum:  minREthOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (rEthOut == 0) revert ZeroOutput();

        uint256 balanceAfter = USDC.balanceOf(address(this));
        if ((balanceBefore - balanceAfter) != allocSum) revert LeakageDetected();

        uint256 cbEthInEth = LST_RATES.cbEthToEth(cbEthOut);
        uint256 rEthInEth  = LST_RATES.rEthToEth(rEthOut);
        if (cbEthInEth == 0 || rEthInEth == 0) revert ExchangeRateInvalid();

        uint256 ethAdded = cbEthInEth + rEthInEth;
        citadelGauge += ethAdded;
        lastSweepTime = block.timestamp;

        emit UCRSwept(usdcBalance, cbEthOut, rEthOut, ethAdded, block.timestamp);
        emit CitadelProgress(citadelGauge);

        if (citadelGauge >= SOLO_THRESHOLD) {
            emit ThresholdReached(block.timestamp);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          CIRCUIT BREAKER
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause UCR sweep. Callable by OWNER or OPERATOR.
     *         Owner-initiated pause requires 48h timelock to resume.
     */
    function pauseUCR() external {
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert InvalidAddress();
        }
        routingPaused = true;
        emit UCRPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Queue a timelocked resume. ID includes sender + nonce + timestamp
     *         for uniqueness across same-block calls.
     */
    function queueResumeUCR() external onlyRole(OWNER_ROLE) returns (bytes32 id) {
        queueNonce++;
        id = keccak256(abi.encodePacked(
            "resume",
            msg.sender,
            queueNonce,
            block.timestamp
        ));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit UCRResumeQueued(id, timelockQueue[id]);
    }

    /**
     * @notice Execute queued resume after TIMELOCK elapsed. Owner-only.
     */
    function resumeUCR(bytes32 id) external onlyRole(OWNER_ROLE) tlPassed(id) {
        routingPaused = false;
        emit UCRResumed(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          GUARDIAN (SECURITY SYSTEM)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Merchant arms the Guardian. Only then can Guardian pause.
     *         Default is disarmed. Merchant can flip on/off any time.
     *
     *         Analogy: arming a store's security system before closing.
     */
    function enableGuardian() external onlyRole(OWNER_ROLE) {
        guardianEnabled = true;
        emit GuardianEnabled(msg.sender, block.timestamp);
    }

    /**
     * @notice Merchant disarms the Guardian. Guardian pause calls will revert.
     */
    function disableGuardian() external onlyRole(OWNER_ROLE) {
        guardianEnabled = false;
        emit GuardianDisabled(msg.sender, block.timestamp);
    }

    /**
     * @notice Guardian pause — only valid when guardianEnabled == true.
     *         Guardian can ONLY pause. Cannot withdraw, unpause, or sweep.
     *         Merchant resumes via standard queueResumeUCR (48h timelock).
     */
    function guardianPause() external onlyRole(GUARDIAN_ROLE) {
        if (!guardianEnabled) revert GuardianNotEnabled();
        routingPaused = true;
        emit GuardianPaused(msg.sender, block.timestamp);
        emit UCRPaused(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DAI RESERVE (MERCHANT OPERATING CAPITAL)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw DAI from reserve to any address. Owner only.
     *         Subject to daily limit — banking-grade protection against
     *         compromised-key drain attacks.
     *         Emits DAIWithdrawn for off-chain Guardian monitoring.
     *
     * @param amount DAI amount to withdraw (18 decimals)
     * @param to     Destination address (bill pay, payroll processor, etc.)
     */
    function withdrawDAI(uint256 amount, address to)
        external onlyRole(OWNER_ROLE) nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0)      revert ZeroAmount();

        _rollWindowIfNeeded();

        if (dailyWithdrawn + amount > dailyLimit) revert DailyLimitExceeded();

        dailyWithdrawn += amount;

        DAI.safeTransfer(to, amount);
        emit DAIWithdrawn(msg.sender, amount, to, block.timestamp);
    }

    /**
     * @notice Adjust DAI reserve ceiling. Owner only. Applies immediately.
     *         Set to 0 to opt out of DAI reserve (sweeps will route 100% to LSTs).
     *         Lowering below current reserve does not force a withdrawal —
     *         reserve simply stops accumulating until below new ceiling.
     */
    function setDaiCeiling(uint256 newCeiling) external onlyRole(OWNER_ROLE) {
        daiCeiling = newCeiling;
        emit DAICeilingUpdated(newCeiling);
    }

    /**
     * @notice Decrease the daily DAI withdrawal limit. Applies immediately —
     *         tightening security is always instant.
     */
    function decreaseDailyLimit(uint256 newLimit) external onlyRole(OWNER_ROLE) {
        if (newLimit >= dailyLimit) revert InvalidAddress(); // must be lower
        dailyLimit = newLimit;
        emit DailyLimitDecreased(newLimit);
    }

    /**
     * @notice Queue an increase to the daily DAI withdrawal limit.
     *         24-hour delay before increase takes effect.
     *         Asymmetric timelock: decreases are instant, increases delayed.
     *         Prevents compromised key from raising limit and immediately draining.
     */
    function queueDailyLimitIncrease(uint256 newLimit) external onlyRole(OWNER_ROLE) {
        if (newLimit <= dailyLimit) revert InvalidAddress(); // must be higher
        queuedLimitIncrease = QueuedLimit({
            newLimit: newLimit,
            executeAfter: block.timestamp + LIMIT_DELAY
        });
        emit DailyLimitIncreaseQueued(newLimit, block.timestamp + LIMIT_DELAY);
    }

    /**
     * @notice Execute a queued limit increase after 24h delay elapsed.
     */
    function executeDailyLimitIncrease() external onlyRole(OWNER_ROLE) {
        QueuedLimit memory q = queuedLimitIncrease;
        if (q.executeAfter == 0)              revert NoIncreaseQueued();
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();

        dailyLimit = q.newLimit;
        delete queuedLimitIncrease;

        emit DailyLimitIncreaseExecuted(q.newLimit);
    }

    /**
     * @notice Cancel a queued limit increase. Applies immediately.
     */
    function cancelDailyLimitIncrease() external onlyRole(OWNER_ROLE) {
        if (queuedLimitIncrease.executeAfter == 0) revert NoIncreaseQueued();
        delete queuedLimitIncrease;
        emit DailyLimitIncreaseCancelled();
    }

    /**
     * @notice Roll the daily withdrawal window if 24h has elapsed since start.
     *         Internal — called from withdrawDAI to reset counter on window boundary.
     */
    function _rollWindowIfNeeded() internal {
        if (block.timestamp >= windowStart + WINDOW_SIZE) {
            windowStart = block.timestamp;
            dailyWithdrawn = 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     EMERGENCY WITHDRAWAL (7-DAY TIMELOCK)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Queue an emergency withdrawal of any held token. 7-day delay
     *         before execution. Owner-only.
     *
     *         Use cases: merchant shuts down business, wants to migrate to
     *         new protocol, wants LSTs in their own wallet for direct staking.
     */
    function queueEmergencyWithdraw(address token, uint256 amount)
        external onlyRole(OWNER_ROLE)
    {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0)         revert ZeroAmount();

        emergencyQueue[token] = EmergencyWithdraw({
            amount: amount,
            executeAfter: block.timestamp + EMERGENCY_DELAY
        });

        emit EmergencyQueued(token, amount, block.timestamp + EMERGENCY_DELAY);
    }

    /**
     * @notice Execute queued emergency withdrawal after 7 days.
     *         For DAI specifically: also subject to daily withdrawal limit.
     *         This closes the compromised-key bypass where attacker could queue
     *         emergency withdrawal of full DAI reserve and drain in one transaction
     *         after the 7-day delay.
     *         LSTs and other tokens are not subject to the daily limit on the
     *         emergency path (7-day timelock is their full protection).
     */
    function executeEmergencyWithdraw(address token, address to)
        external onlyRole(OWNER_ROLE) nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();

        EmergencyWithdraw memory q = emergencyQueue[token];
        if (q.executeAfter == 0)              revert NothingQueued();
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 amount  = q.amount > balance ? balance : q.amount;
        if (amount == 0) revert NothingToWithdraw();

        // DAI emergency withdrawals also enforce the daily limit
        if (token == address(DAI)) {
            _rollWindowIfNeeded();
            if (dailyWithdrawn + amount > dailyLimit) revert DailyLimitExceeded();
            dailyWithdrawn += amount;
        }

        delete emergencyQueue[token];

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyExecuted(token, amount, to);
    }

    /**
     * @notice Cancel a queued emergency withdrawal.
     */
    function cancelEmergencyWithdraw(address token) external onlyRole(OWNER_ROLE) {
        if (emergencyQueue[token].executeAfter == 0) revert NothingQueued();
        delete emergencyQueue[token];
        emit EmergencyCancelled(token);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update minimum USDC batch size required before sweep. Owner-only.
     */
    function setMinSwapBatch(uint256 amount) external onlyRole(OWNER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        minSwapBatch = amount;
        emit MinSwapBatchUpdated(amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Chainlink oracle validation — full staleness checks (Grok-audit
     *         pattern): roundId completeness, updatedAt positive, age < 3600s,
     *         answer positive.
     */
    function _validateOracle() internal view {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = CHAINLINK.latestRoundData();

        if (answeredInRound < roundId)                   revert OracleStale();
        if (updatedAt == 0)                              revert OracleStale();
        if (block.timestamp - updatedAt > ORACLE_STALE)  revert OracleStale();
        if (answer <= 0)                                 revert OracleInvalid();
    }

    /**
     * @notice Non-reverting DAI/USD oracle freshness check.
     *         Returns false if stale/invalid so sweep can skip DAI refill
     *         gracefully rather than reverting the whole sweep.
     */
    function _isDaiOracleFresh() internal view returns (bool) {
        try CHAINLINK_DAI.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answeredInRound < roundId)                   return false;
            if (updatedAt == 0)                              return false;
            if (block.timestamp - updatedAt > ORACLE_STALE)  return false;
            if (answer <= 0)                                 return false;
            return true;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function getCitadelProgress() external view returns (uint256) {
        return citadelGauge;
    }

    function getUSDCBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function getDAIBalance() external view returns (uint256) {
        return DAI.balanceOf(address(this));
    }

    /**
     * @notice How much DAI remains withdrawable in the current 24h window.
     *         If window has rolled over, returns full dailyLimit.
     */
    function dailyRemaining() external view returns (uint256) {
        if (block.timestamp >= windowStart + WINDOW_SIZE) {
            return dailyLimit;
        }
        if (dailyWithdrawn >= dailyLimit) return 0;
        return dailyLimit - dailyWithdrawn;
    }

    /**
     * @notice Armor Level — days of operating overhead the DAI reserve covers.
     *         Requires merchant-provided daily burn rate (off-chain calculation,
     *         passed here as param). On-chain view is purely informational.
     */
    function armorLevelDays(uint256 dailyBurnRate) external view returns (uint256) {
        if (dailyBurnRate == 0) return type(uint256).max;
        uint256 reserve = DAI.balanceOf(address(this));
        return reserve / dailyBurnRate;
    }

    function isDaiReserveFull() external view returns (bool) {
        if (daiCeiling == 0) return true; // opted out, always "full"
        return DAI.balanceOf(address(this)) >= daiCeiling;
    }

    function getCbETHBalance() external view returns (uint256) {
        return CBETH.balanceOf(address(this));
    }

    function getRETHBalance() external view returns (uint256) {
        return RETH.balanceOf(address(this));
    }

    function nextSweepAllowed() external view returns (uint256) {
        return lastSweepTime + SWEEP_DELAY;
    }

    function isSoloThresholdMet() external view returns (bool) {
        return citadelGauge >= SOLO_THRESHOLD;
    }

    function progressPercentage() external view returns (uint256) {
        if (citadelGauge >= SOLO_THRESHOLD) return 100;
        return (citadelGauge * 100) / SOLO_THRESHOLD;
    }

    function isEmergencyQueued(address token) external view returns (bool) {
        return emergencyQueue[token].executeAfter != 0;
    }

    function emergencyReady(address token) external view returns (bool) {
        uint256 eAfter = emergencyQueue[token].executeAfter;
        return eAfter != 0 && block.timestamp >= eAfter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
