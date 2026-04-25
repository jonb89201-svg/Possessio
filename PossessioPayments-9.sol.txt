// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  PossessioPayments
 * @notice Phase 2 merchant onboarding contract — the POSSESSIO Payments product.
 *         Merges the UCR (USDC Conversion Router, Gemini-invented mechanism)
 *         and the StakingBuffer (LST holding + Citadel Gauge) into one contract
 *         for deployment simplicity and minimum cross-contract attack surface.
 *
 *         SCOPE: Phase 2 MVP
 *           - Receives USDC from Stripe Bridge API split settlement
 *           - Converts USDC → cbETH (100%) via Uniswap V3 on Base
 *           - Holds cbETH in-contract with Citadel Gauge tracking ETH-equivalent
 *           - Emits ThresholdReached at 32 ETH equivalent (SSV validator eligibility)
 *           - 7-day timelock emergency withdrawal for merchant safety
 *
 *         100% cbETH RATIONALE:
 *           rETH on Base mainnet is a bridged OptimismMintableERC20 token,
 *           NOT native Rocket Pool rETH. Its `burn()` function is gated by
 *           `onlyBridge` modifier and uses `burn(address,uint256)` signature.
 *           This makes rETH non-redeemable from user contracts on Base.
 *           cbETH (verified native, supports `withdraw(uint256)`) is the only
 *           LST that maintains deterministic redemption on Base.
 *           Council-ratified architecture decision.
 *
 *         SCOPE: Phase 2.1 SSV Citadel (dormant until threshold)
 *           - Two-step state machine: initiateLSTRedemption → completeActivation
 *           - cbETH.withdraw() converts to native ETH for validator deposit
 *           - 32 ETH sent to SSV Network registry with merchant's chosen cluster
 *           - Vetted operators advisory list with merchant sovereign override
 *           - All Phase 2.1 functions gated by `requiresThreshold` modifier
 *           - Pre-threshold: Phase 2.1 functions revert (operationally invisible)
 *
 * DEPLOYMENT MODEL:
 *   POSSESSIO Payments deploys a per-merchant PossessioPayments contract as
 *   a one-time software delivery. Once deployed, merchant holds OWNER_ROLE.
 *   POSSESSIO Payments retains ZERO on-chain authority. Merchant sovereignty
 *   is absolute. The contract is non-custodial software infrastructure; it is
 *   not a financial service or custodial product.
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
 * USAGE NOTE:
 *   Operational guidance: DO NOT call sweep() on a predictable
 *   schedule. Vary timing. MEV bots pattern-match predictable calls. The
 *   24h SWEEP_DELAY is a minimum, not a recommended cadence.
 *
 * ADDRESSES (Base Mainnet — verified):
 *   USDC:              0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   cbETH:             0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22
 *   Uniswap V3 Router: 0x2626664c2603336E57B271c5C0b26F421741e481
 *   Chainlink ETH/USD: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 *   SSV Network:       0xDD9BC35aE942eF0cFa76930954a156B3fF30a4E1
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
///         Calls protocol-native rate (cbETH.exchangeRate).
///         Ratified as shared infrastructure with no admin surface per
///         Gemini-seat specification.
interface ILSTExchangeRate {
    function cbEthToEth(uint256 cbEthAmount) external view returns (uint256);
}

/// @notice cbETH redemption interface — matches certified PLATE.sol usage.
///         `withdraw(uint256 amount)` redeems cbETH for native ETH.
///         Verified against PLATE v1 deployed contract on Base mainnet.
interface IcbETH {
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @notice SSV Network registry interface (Base mainnet, April 2026).
///         Deployment address: 0xDD9BC35aE942eF0cFa76930954a156B3fF30a4E1
///         Per Gemini-seat research, this is the unified EVM SSV Network registry.
///         Uses ETH-Pay model: native ETH for both validator deposit and operator fees.
interface ISSVNetwork {
    struct Cluster {
        uint32  validatorCount;
        uint64  networkFeeIndex;
        uint64  index;
        bool    active;
        uint256 balance;
    }

    function registerValidator(
        bytes calldata publicKey,
        uint64[] calldata operatorIds,
        bytes calldata sharesData,
        uint256 amount,
        Cluster calldata cluster
    ) external payable;
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

    uint256 public constant CBETH_PCT       = 100;        // 100% to cbETH (rETH removed per council)
    // RETH_PCT removed — rETH on Base is bridged-not-native, council-ratified removal

    uint256 public constant SWEEP_DELAY     = 24 hours;   // minimum between sweeps
    uint256 public constant TIMELOCK        = 48 hours;   // owner-pause resume delay
    uint256 public constant EMERGENCY_DELAY = 7 days;     // emergency withdraw delay

    uint24  public constant FEE_LST         = 3000;       // 0.3% — V3 LST pairs
    uint24  public constant FEE_STABLE      = 500;        // 0.05% — V3 USDC/DAI pair
    uint256 public constant ORACLE_STALE    = 3600;       // 1 hour staleness cap
    uint256 public constant SOLO_THRESHOLD  = 32 ether;   // validator eligibility
    uint256 public constant LIMIT_DELAY     = 24 hours;   // daily limit increase delay
    uint256 public constant WINDOW_SIZE     = 24 hours;   // daily withdrawal window

    // ── Phase 2.1 SSV Citadel Constants ──────────────────────────────────────

    /// @notice Threshold to begin LST → ETH redemption. Includes 0.5% buffer
    ///         above raw 32 ETH to account for oracle/protocol rate latency
    ///         during the redemption window. Gemini-seat ratified v0.9.4.
    uint256 public constant ELIGIBILITY_THRESHOLD = 32.16 ether;

    /// @notice Exact ETH amount sent to SSV Network for validator deposit.
    ///         Per Ethereum deposit contract spec, this MUST be exactly 32 ETH.
    uint256 public constant VALIDATOR_DEPOSIT = 32 ether;

    /// @notice Maximum operator IDs accepted in a single registration call.
    ///         Defends against unbounded loop in vetted operator validation.
    ///         SSV clusters typically use 4-7 operators with 13 as practical max.
    uint256 public constant MAX_OPERATORS = 13;

    // ── Phase 2.1 Immutables ─────────────────────────────────────────────────

    /// @notice SSV Network registry on Base mainnet (April 2026).
    address public immutable SSV_NETWORK;

    // ── Immutables ───────────────────────────────────────────────────────────

    IERC20           public immutable USDC;
    IERC20           public immutable CBETH;
    IERC20           public immutable DAI;
    ISwapRouter      public immutable ROUTER;
    IChainlinkFeed   public immutable CHAINLINK;
    IChainlinkFeed   public immutable CHAINLINK_DAI;
    ILSTExchangeRate public immutable LST_RATES;

    // ── Mutable state ────────────────────────────────────────────────────────

    bool    public routingPaused;       // pause flag for sweep
    bool    public guardianEnabled;     // merchant-controlled Guardian opt-in
    uint256 public lastSweepTime;       // last successful sweep timestamp
    uint256 public minSwapBatch;        // minimum USDC before sweep allowed
    bool    public thresholdReached;    // one-shot flag for ThresholdReached event idempotency

    // ── Phase 2.1 Citadel state machine ──────────────────────────────────────

    /// @notice State machine for the SSV validator activation flow.
    ///         ACCUMULATING → REDEEMING → VALIDATING (with abort path back to ACCUMULATING).
    ///         All Phase 2.1 functions gated by this state plus thresholdReached.
    enum CitadelState { ACCUMULATING, REDEEMING, VALIDATING }
    CitadelState public citadelState;

    /// @notice Vetted operators advisory mapping. Guardian proposes vetted IDs.
    ///         Merchant may use these or override with custom IDs (sovereignty).
    mapping(uint64 => bool) public vettedOperators;

    /// @notice Validator public key after activation. Empty until VALIDATING state.
    bytes public validatorPubKey;

    // DAI reserve state — stable-asset balance for merchant's operational use
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

    // DAI reserve events — merchant-controlled stable-asset balance
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

    // Phase 2.1 SSV Citadel events
    event CitadelStateChanged(CitadelState indexed from, CitadelState indexed to);
    event RedemptionInitiated(uint256 cbEthAmount, uint256 rEthAmount);
    event ValidatorActivated(bytes pubKey, uint64[] operatorIds, uint256 ethDeposited);
    event ActivationAborted(uint256 idleEthBalance);
    event VettedOperatorAdded(uint64 indexed operatorId);
    event VettedOperatorRemoved(uint64 indexed operatorId);
    event SovereignOverrideTriggered(address indexed merchant, bytes pubKey);

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

    // Phase 2.1 SSV Citadel errors
    error CitadelNotReady();
    error InvalidCitadelState();
    error InsufficientETHForDeposit();
    error CbEthRedemptionFailed();
    error OperatorNotVetted();
    error TooManyOperators();
    error EthTransferFailed();
    error UnsupportedLST();

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

    /// @notice Phase 2.1 dormant gate. Reverts unless threshold has been reached.
    ///         All Citadel functions check this — pre-threshold, the SSV layer
    ///         is "invisible" to existing state.
    modifier requiresThreshold() {
        if (!thresholdReached) revert CitadelNotReady();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    /**
     * @notice Deploy a merchant's PossessioPayments contract.
     * @param owner           Merchant wallet address — receives OWNER_ROLE
     * @param usdc_           USDC token address on Base
     * @param cbeth_          cbETH token address on Base
     * @param dai_            DAI token address on Base
     * @param router_         Uniswap V3 SwapRouter02 address on Base
     * @param chainlink_      Chainlink ETH/USD feed address on Base
     * @param chainlinkDai_   Chainlink DAI/USD feed address on Base
     * @param lstRates_       Immutable LSTExchangeRate singleton address
     * @param ssvNetwork_     SSV Network registry address on Base mainnet
     * @param minSwapBatch_   Minimum USDC required before sweep allowed
     * @param daiCeiling_     Target DAI reserve (merchant's operating buffer). 0 = opt out.
     * @param dailyLimit_     Max DAI withdrawable per 24h window. 0 = lockdown.
     */
    constructor(
        address owner,
        address usdc_,
        address cbeth_,
        address dai_,
        address router_,
        address chainlink_,
        address chainlinkDai_,
        address lstRates_,
        address ssvNetwork_,
        uint256 minSwapBatch_,
        uint256 daiCeiling_,
        uint256 dailyLimit_
    ) {
        if (owner         == address(0)) revert InvalidAddress();
        if (usdc_         == address(0)) revert InvalidAddress();
        if (cbeth_        == address(0)) revert InvalidAddress();
        if (dai_          == address(0)) revert InvalidAddress();
        if (router_       == address(0)) revert InvalidAddress();
        if (chainlink_    == address(0)) revert InvalidAddress();
        if (chainlinkDai_ == address(0)) revert InvalidAddress();
        if (lstRates_     == address(0)) revert InvalidAddress();
        if (ssvNetwork_   == address(0)) revert InvalidAddress();

        USDC          = IERC20(usdc_);
        CBETH         = IERC20(cbeth_);
        DAI           = IERC20(dai_);
        ROUTER        = ISwapRouter(router_);
        CHAINLINK     = IChainlinkFeed(chainlink_);
        CHAINLINK_DAI = IChainlinkFeed(chainlinkDai_);
        LST_RATES     = ILSTExchangeRate(lstRates_);
        SSV_NETWORK   = ssvNetwork_;

        minSwapBatch = minSwapBatch_;
        daiCeiling   = daiCeiling_;
        dailyLimit   = dailyLimit_;
        windowStart  = block.timestamp;

        // Phase 2.1 starts in ACCUMULATING state
        citadelState = CitadelState.ACCUMULATING;

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
     *         remaining USDC into cbETH (100%), holds in-contract,
     *         increments Citadel Gauge.
     *
     *         Merchant onboarding advice: vary your sweep timing. Predictable
     *         schedules invite MEV pattern-matching.
     *
     *         DAI reserve priority: operations before accumulation. If incoming
     *         USDC is less than the DAI refill gap, 100% goes to DAI and 0 to
     *         the cbETH leg. Once reserve is full, 100% goes to cbETH.
     *
     *         Setting daiCeiling == 0 opts out of DAI reserve entirely.
     *
     *         100% cbETH allocation: rETH on Base is a bridged OptimismMintableERC20
     *         token with no user-callable redemption path. Council-ratified
     *         architecture limits the staking layer to cbETH (deterministic
     *         redemption via withdraw(uint256)).
     *
     * @param minDaiOut    Minimum DAI output from USDC swap (0 if no refill needed)
     * @param minCbEthOut  Minimum cbETH output (slippage guard)
     */
    function sweep(
        uint256 minDaiOut,
        uint256 minCbEthOut
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

                        // Reset approval — defends against malicious router that
                        // consumes less than approved, leaving dangling allowance.
                        USDC.forceApprove(address(ROUTER), 0);
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

        uint256 cbEthAlloc = usdcAfterDai; // 100% to cbETH (council-ratified)

        uint256 balanceBefore = USDC.balanceOf(address(this));

        USDC.forceApprove(address(ROUTER), cbEthAlloc);

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

        uint256 balanceAfter = USDC.balanceOf(address(this));
        if ((balanceBefore - balanceAfter) != cbEthAlloc) revert LeakageDetected();

        // Reset approval — defense-in-depth even when leakage check passed.
        // Closes any dangling allowance surface from edge-case router behavior.
        USDC.forceApprove(address(ROUTER), 0);

        uint256 cbEthInEth = LST_RATES.cbEthToEth(cbEthOut);
        if (cbEthInEth == 0) revert ExchangeRateInvalid();

        uint256 ethAdded = cbEthInEth;
        lastSweepTime = block.timestamp;

        // Compute current total ETH-equivalent across held cbETH.
        // This reflects actual capital, not historical deposits — so threshold
        // detection accounts for cbETH rate fluctuations (yield accrual, market drift).
        uint256 currentEthEquivalent = _computeCurrentEthEquivalent();

        emit UCRSwept(usdcBalance, cbEthOut, 0, ethAdded, block.timestamp);
        emit CitadelProgress(currentEthEquivalent);

        // One-shot threshold detection — fires only on first crossing.
        // If LST rates drop below threshold later, gauge view will show that,
        // but we don't re-emit ThresholdReached (it would spam SSV handoff signals).
        if (!thresholdReached && currentEthEquivalent >= SOLO_THRESHOLD) {
            thresholdReached = true;
            emit ThresholdReached(block.timestamp);
        }
    }

    /**
     * @notice Compute current ETH-equivalent of all held LSTs.
     *         Used internally for threshold detection and externally via
     *         getCitadelProgress() view. Reads CURRENT exchange rates so
     *         gauge reflects actual capital, not historical deposit totals.
     */
    function _computeCurrentEthEquivalent() internal view returns (uint256) {
        uint256 cbBal = CBETH.balanceOf(address(this));
        if (cbBal == 0) return 0;
        return LST_RATES.cbEthToEth(cbBal);
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
    //                       DAI RESERVE (STABLE-ASSET BALANCE)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw DAI from reserve to any address. Owner only.
     *         Subject to daily limit — rate-based protection against
     *         compromised-key drain attacks.
     *         Emits DAIWithdrawn for off-chain Guardian monitoring.
     *
     * @param amount DAI amount to withdraw (18 decimals)
     * @param to     Destination address chosen by Owner
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
     * @notice Queue an emergency withdrawal of any held token. 7-day delay
     *         before execution. Owner-only.
     *
     *         Use cases: merchant shuts down business, wants to migrate to
     *         new protocol, wants LSTs in their own wallet for direct staking,
     *         OR recovers Ghost ETH (Phase 2.1 buffer or aborted activation).
     *
     *         Use `token == address(0)` to queue native ETH withdrawal.
     */
    function queueEmergencyWithdraw(address token, uint256 amount)
        external onlyRole(OWNER_ROLE)
    {
        // Note: token == address(0) is allowed for native ETH withdrawal.
        // This is the only valid case for "zero address" in this contract.
        if (amount == 0) revert ZeroAmount();

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
     *
     *         Use `token == address(0)` to recover native ETH (Ghost ETH from
     *         Phase 2.1 buffer or aborted activation).
     */
    function executeEmergencyWithdraw(address token, address to)
        external onlyRole(OWNER_ROLE) nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();

        EmergencyWithdraw memory q = emergencyQueue[token];
        if (q.executeAfter == 0)              revert NothingQueued();
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();

        // Determine balance and clamp amount based on token type
        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
        uint256 amount = q.amount > balance ? balance : q.amount;
        if (amount == 0) revert NothingToWithdraw();

        // DAI emergency withdrawals also enforce the daily limit
        if (token == address(DAI)) {
            _rollWindowIfNeeded();
            if (dailyWithdrawn + amount > dailyLimit) revert DailyLimitExceeded();
            dailyWithdrawn += amount;
        }

        delete emergencyQueue[token];

        // Native ETH transfer for token == address(0), ERC20 transfer otherwise
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

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

    /**
     * @notice Current Citadel Gauge — ETH-equivalent of all held LSTs at
     *         current exchange rates. Reflects actual capital, not historical
     *         deposit total. Drops if LST rates fall, rises if rates climb.
     */
    function getCitadelProgress() external view returns (uint256) {
        return _computeCurrentEthEquivalent();
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

    function nextSweepAllowed() external view returns (uint256) {
        return lastSweepTime + SWEEP_DELAY;
    }

    /**
     * @notice True if current ETH-equivalent meets or exceeds SOLO_THRESHOLD.
     *         Uses live rates — can flip back to false if LST rates drop.
     *         For one-shot "ever crossed" check, use `thresholdReached()`.
     */
    function isSoloThresholdMet() external view returns (bool) {
        return _computeCurrentEthEquivalent() >= SOLO_THRESHOLD;
    }

    /**
     * @notice Progress as percentage (0-100). Based on current ETH-equivalent,
     *         not historical accumulation.
     */
    function progressPercentage() external view returns (uint256) {
        uint256 current = _computeCurrentEthEquivalent();
        if (current >= SOLO_THRESHOLD) return 100;
        return (current * 100) / SOLO_THRESHOLD;
    }

    function isEmergencyQueued(address token) external view returns (bool) {
        return emergencyQueue[token].executeAfter != 0;
    }

    function emergencyReady(address token) external view returns (bool) {
        uint256 eAfter = emergencyQueue[token].executeAfter;
        return eAfter != 0 && block.timestamp >= eAfter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              PHASE 2.1 — SSV CITADEL VALIDATOR HANDOFF
    // ═══════════════════════════════════════════════════════════════════════
    //
    // The SSV layer is dormant until thresholdReached flips true. Pre-threshold,
    // these functions revert via the requiresThreshold modifier, making them
    // "invisible" to existing state and tests.
    //
    // ARCHITECTURE (Gemini-seat ratified):
    //   1. Merchant accumulates cbETH via sweep() until thresholdReached
    //   2. Merchant calls initiateLSTRedemption() — IRREVERSIBLE
    //   3. cbETH.withdraw() returns native ETH to contract synchronously
    //   4. Merchant calls completeActivation() with validator pubkey,
    //      operator IDs, and shares data (msg.value can top up if needed)
    //   5. Contract calls SSV Network registerValidator with 32 ETH msg.value
    //   6. Validator is live, contract enters VALIDATING state
    //
    // ESCAPE HATCH:
    //   abortActivation() reverts state to ACCUMULATING. Any redeemed ETH is
    //   "Ghost ETH" — operationally invisible until recovered via 7-day
    //   emergency withdrawal at address(0).
    //
    // RUBICON WARNING:
    //   initiateLSTRedemption is irreversible. cbETH redemption via withdraw()
    //   commits the tokens to native ETH — they cannot be recovered as cbETH.
    //
    // 100% cbETH RATIONALE:
    //   rETH on Base is bridged-not-native (OptimismMintableERC20 with
    //   onlyBridge burn). Council-ratified architecture limits the redemption
    //   path to cbETH which supports user-callable withdraw(uint256).

    /**
     * @notice Add an operator ID to the vetted list. Guardian-only.
     *         Vetted operators are advisory — merchant may bypass via
     *         the bypassVettedCheck flag in completeActivation.
     */
    function addVettedOperator(uint64 operatorId) external onlyRole(GUARDIAN_ROLE) {
        vettedOperators[operatorId] = true;
        emit VettedOperatorAdded(operatorId);
    }

    /**
     * @notice Remove an operator ID from the vetted list. Guardian-only.
     */
    function removeVettedOperator(uint64 operatorId) external onlyRole(GUARDIAN_ROLE) {
        vettedOperators[operatorId] = false;
        emit VettedOperatorRemoved(operatorId);
    }

    /**
     * @notice Step 1: Initiate cbETH → ETH redemption.
     *
     * @dev RUBICON WARNING: This action is IRREVERSIBLE. cbETH.withdraw()
     *      commits the cbETH balance to native ETH conversion — the cbETH
     *      cannot be recovered once this transaction confirms.
     *
     * @dev GATE: Requires thresholdReached == true AND citadelState == ACCUMULATING.
     *      Reverts with CitadelNotReady or InvalidCitadelState otherwise.
     *
     * @dev BUFFER: ELIGIBILITY_THRESHOLD is 32.16 ETH (32 + 0.5% cushion) to
     *      handle oracle/protocol rate latency during the redemption window.
     *
     * @dev FAILURE MODE: If redeemed ETH falls below VALIDATOR_DEPOSIT,
     *      merchant can either top up via msg.value in completeActivation or
     *      call abortActivation to recover the redeemed ETH via emergency path.
     */
    function initiateLSTRedemption()
        external
        onlyRole(OWNER_ROLE)
        nonReentrant
        requiresThreshold
    {
        if (citadelState != CitadelState.ACCUMULATING) revert InvalidCitadelState();
        if (_computeCurrentEthEquivalent() < ELIGIBILITY_THRESHOLD) revert CitadelNotReady();

        _triggerNativeRedemption();

        CitadelState prev = citadelState;
        citadelState = CitadelState.REDEEMING;
        emit CitadelStateChanged(prev, CitadelState.REDEEMING);
    }

    /**
     * @notice Internal: trigger native redemption via cbETH.withdraw.
     *         cbETH interface verified against PLATE v1 deployed contract on Base.
     *         rETH excluded — bridged on Base, no user-callable redemption path.
     */
    function _triggerNativeRedemption() internal {
        uint256 cbBal = CBETH.balanceOf(address(this));

        if (cbBal > 0) {
            try IcbETH(address(CBETH)).withdraw(cbBal) {
                // success — ETH delivered to address(this).balance
            } catch {
                revert CbEthRedemptionFailed();
            }
        }

        emit RedemptionInitiated(cbBal, 0);
    }

    /**
     * @notice Internal safety guard. Reverts if the supplied token is not the
     *         contract's ratified LST. Hardens against future protocol upgrades
     *         that might accidentally re-introduce non-redeemable tokens.
     *         Council-ratified pattern from the rETH-on-Base finding.
     * @param token Token address to validate
     */
    function _assertRedeemableLST(address token) internal view {
        if (token != address(CBETH)) revert UnsupportedLST();
    }

    /**
     * @notice Step 2: Complete validator activation by registering with SSV Network.
     *
     * @dev SOURCE TRACKING: Consumes total contract balance up to VALIDATOR_DEPOSIT.
     *      DO NOT send unrelated ETH to this contract during REDEEMING state.
     *      Any ETH balance present at activation is consumed by the validator
     *      deposit. Buffer ETH (excess above 32) becomes Ghost ETH — recoverable
     *      only via executeEmergencyWithdraw(address(0), to) after 7-day timelock.
     *
     * @dev TOP-UP: msg.value can be used to bridge a gap if redeemed ETH fell
     *      below VALIDATOR_DEPOSIT due to oracle/protocol rate drift.
     *
     * @dev OPERATORS: If bypassVettedCheck is false, all operatorIds must be
     *      in the vetted list. If true, merchant accepts sovereign override
     *      (event emitted for transparency).
     *
     * @param pubKey            Validator public key (BLS12-381 compressed)
     * @param operatorIds       SSV operator cluster IDs
     * @param shares            Encrypted key shares for the operators
     * @param bypassVettedCheck If true, skip vetted operator validation
     *
     * @dev SSV AMOUNT NOTE: The `amount` parameter to registerValidator is
     *      currently set to 0. Per Gemini-seat research this represents
     *      initial operator fee deposit. Merchant should fund operator fees
     *      separately post-activation if needed. Architect ratification
     *      pending if this should be non-zero.
     */
    function completeActivation(
        bytes calldata pubKey,
        uint64[] calldata operatorIds,
        bytes calldata shares,
        bool bypassVettedCheck
    )
        external
        payable
        onlyRole(OWNER_ROLE)
        nonReentrant
        requiresThreshold
    {
        if (citadelState != CitadelState.REDEEMING) revert InvalidCitadelState();
        if (operatorIds.length == 0)                 revert ZeroAmount();
        if (operatorIds.length > MAX_OPERATORS)      revert TooManyOperators();

        // Vetted operator check (skippable via merchant sovereignty flag)
        if (!bypassVettedCheck) {
            for (uint256 i = 0; i < operatorIds.length; i++) {
                if (!vettedOperators[operatorIds[i]]) revert OperatorNotVetted();
            }
        } else {
            emit SovereignOverrideTriggered(msg.sender, pubKey);
        }

        // Confirm we have enough ETH (redeemed + msg.value top-up)
        uint256 totalBalance = address(this).balance;
        if (totalBalance < VALIDATOR_DEPOSIT) revert InsufficientETHForDeposit();

        // Register with SSV Network — initial cluster is all-zeros for new validator
        ISSVNetwork.Cluster memory initialCluster = ISSVNetwork.Cluster({
            validatorCount:   0,
            networkFeeIndex:  0,
            index:            0,
            active:           false,
            balance:          0
        });

        ISSVNetwork(SSV_NETWORK).registerValidator{value: VALIDATOR_DEPOSIT}(
            pubKey,
            operatorIds,
            shares,
            0,
            initialCluster
        );

        validatorPubKey = pubKey;

        CitadelState prev = citadelState;
        citadelState = CitadelState.VALIDATING;
        emit CitadelStateChanged(prev, CitadelState.VALIDATING);
        emit ValidatorActivated(pubKey, operatorIds, VALIDATOR_DEPOSIT);
    }

    /**
     * @notice Escape hatch: revert state to ACCUMULATING.
     *
     * @dev GHOST ETH WARNING: Any ETH redeemed via initiateLSTRedemption
     *      remains in the contract after abort. It is NOT consumed by sweep()
     *      and NOT tracked by the Citadel Gauge. Recoverable only via
     *      executeEmergencyWithdraw(address(0), to) after the 7-day timelock.
     *
     * @dev USE CASES: Conditions changed during the 3-day exit queue and
     *      merchant no longer wants to activate (regulatory event, key rotation,
     *      etc.). Or redeemed ETH dropped significantly below VALIDATOR_DEPOSIT
     *      and merchant cannot cover the gap.
     */
    function abortActivation() external onlyRole(OWNER_ROLE) requiresThreshold {
        if (citadelState != CitadelState.REDEEMING) revert InvalidCitadelState();

        uint256 idleEth = address(this).balance;

        CitadelState prev = citadelState;
        citadelState = CitadelState.ACCUMULATING;
        emit CitadelStateChanged(prev, CitadelState.ACCUMULATING);
        emit ActivationAborted(idleEth);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
