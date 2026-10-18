// SPDX-License-Identifier: MIT
// BUILD-PROOF: PAYMENTS_V300_AUCTION — if absent on disk, the old file is still cached.
// v3.0.0 (2026-10-17) — the auction sweep (SPEC_AuctionSweep_v0.1, council sandbox):
//   The contract no longer trades into a pool. It announces a lot of USDC whose
//   cbETH price falls with time, and whoever delivers the cbETH first takes the
//   lot. The oracle is an anchor and a floor, not a trust root; the caller of
//   kick() and take() is a stranger by design. Removed with it: both routers and
//   the WETH hop, the per-leg slippage arguments, the operator role, the DAI
//   reserve and its refill (replaced by a USDC float), and the guardian (the
//   stolen-owner-key defence is now the payee allowlist on every exit).
//   Kept: the Morpho leg (deposited at kick, no price risk), cbEthBps, the
//   per-asset rolling exit limits (C-2, P-H1 cap, P-M4 leaky bucket), the 7-day
//   emergency path, the treasury gauge, the oracle validation, the optional
//   Chainlink Automation hooks, the factory-shaped constructor and the K-3 pin.
// v3.0.1 (2026-10-18) — cold-seat hardening (COLD_SEAT_AUDIT_20261018, council
//   sandbox): G-1 the Base L2 sequencer uptime feed gates kick and take, with a
//   grace period after a restart; G-2 sendUSDC keeps an open lot's USDC reserved
//   and an emergency USDC exit cancels the lot; G-3 the Morpho principal falls
//   pro rata as shares leave; G-4 the cbETH/ETH feed value is named for what it
//   holds (ETH per cbETH).
// v2.4.3 (2026-06-01) and v2.4.4 (2026-07-14): audit remediation batches; the
//   history of the swap-era contract is in the repository's audit reports.
pragma solidity ^0.8.24;

/**
 * @title  PossessioPayments
 * @notice Merchant payment processor — the POSSESSIO Payments product on Base.
 *         Non-custodial: sold to merchants as a one-time software deployment;
 *         POSSESSIO retains ZERO on-chain authority post-deployment and takes
 *         no fee at any layer.
 *
 *         CORE MECHANICS (v3.0):
 *           - Receives USDC inflows (e.g. card-network split settlement).
 *           - Keeps `usdcFloat` liquid for the merchant's operations.
 *           - Anyone may kick(): the Morpho share of the USDC above the float
 *             is deposited into the Bitwise Morpho Blue USDC vault at once, and
 *             the cbETH share is put up as a lot in a Dutch auction.
 *           - Anyone may take(): deliver the cbETH the curve asks for now, and
 *             receive the lot. The curve starts far above the oracle, falls
 *             through it, and holds at 99% of it. There is no trade into a
 *             pool, so there is nothing to sandwich, and a stolen key of any
 *             caller can do nothing a stranger could not.
 *           - 100% of value remains in merchant-owned reserves.
 *
 *         THE CURVE (Reserve DutchTrade's shape, our numbers; see _multiplier):
 *           phase 1, first 20% of the auction: geometric from 1536x to 1.5x the
 *             oracle amount — price discovery across three orders of magnitude;
 *             a take here means the oracle was badly low and is flagged;
 *           phase 2, next 25%: linear from 1.5x to 1.0x;
 *           phase 3, next 50%: linear from 1.0x to 0.99x (FLOOR_BPS);
 *           phase 4, last 5%: flat at 0.99x.
 *           The multiplier is applied to the LIVE oracle amount at the time of
 *           the take, not a snapshot at the kick (SPEC §4.6).
 *
 *         100% cbETH RATIONALE: rETH on Base is a bridged OptimismMintableERC20
 *         with no user-callable redemption path; cbETH accrues staking yield
 *         passively. cbETH is not redeemed by this contract; the merchant moves
 *         it out through sendCbETH to an allowlisted payee.
 *
 * DEPLOYMENT MODEL:
 *   One contract per merchant, launched by PossessioFactory, which writes the
 *   owner. Once deployed the merchant holds OWNER_ROLE and POSSESSIO holds
 *   nothing.
 *
 * PERMISSION STRUCTURE (OpenZeppelin AccessControl):
 *   OWNER_ROLE — the merchant (a Safe or a Base Account is advised). Settings,
 *                exits to allowlisted payees within the daily limits, the
 *                7-day emergency path to a payee, payee proposals (48 h) and
 *                removals (instant), pause, and a 48 h timelocked resume.
 *   anyone     — kick() and take(). Nothing else.
 *   forwarder  — optional Chainlink Automation; performUpkeep() is kick().
 *
 * ADDRESSES (Base mainnet): the BaseWiring library below. On chainid 8453 the
 *   constructor accepts no other wiring (K-3, external review 2026-10-15).
 */

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Chainlink Automation (Phase 3 — council-ratified 2026-05-12)
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

// ═══════════════════════════════════════════════════════════════════════════
//                          EXTERNAL INTERFACES
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Chainlink oracle feed for staleness validation. decimals() is read
///         by the constructor's decimal-class guard: cbETH/ETH is an 18-decimal
///         exchange-rate feed; USDC/USD and ETH/USD are 8-decimal price feeds;
///         the L2 Sequencer Uptime Status Feed is 0-decimal (answer 0 = up).
interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
    function decimals() external view returns (uint8);
}

/// @notice Morpho Blue ERC4626 vault interface (Bitwise-curated USDC vault).
///         Mirrors L1Anchor.sol's IMorphoVault exactly.
interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice cbETH exchange rate oracle — immutable, ownerless singleton, for
///         the treasury gauge readout.
interface ILSTExchangeRate {
    function cbEthToEth(uint256 cbEthAmount) external view returns (uint256);
}

/// @notice A taker that sources cbETH after receiving the lot (SPEC §4.5): the
///         contract sends `usdcOut`, calls this, then requires its cbETH
///         balance to have risen by `cbEthRequired`.
interface ITaker {
    function possessioTake(uint256 usdcOut, uint256 cbEthRequired, bytes calldata data) external;
}

/// @notice The canonical Base mainnet wiring (chainid 8453): one source of
///         truth for the template's K-3 pin, script/DeployPayments.s.sol and
///         the K-3 unit test. Internal constants are inlined, so the library
///         adds no runtime code and is never deployed. test/PaymentsFork_t.sol
///         keeps its own copy on purpose: deploying against the live contracts
///         is the independent check of these values.
library BaseWiring {
    address internal constant USDC              = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBETH             = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address internal constant MORPHO_VAULT      = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100; // Morpho USDC vault
    address internal constant CHAINLINK_CBETH   = 0x806b4Ac04501c29769051e42783cF04dCE41440b; // cbETH/ETH, 18-dec
    address internal constant CHAINLINK_USDC    = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD, 8-dec
    address internal constant CHAINLINK_ETH     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD, 8-dec
    address internal constant CHAINLINK_SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // L2 Sequencer Uptime Status Feed, 0-dec
    address internal constant LST_RATES         = 0xDDb75e974d99FcF95E241adbFD376861c47a8548; // LSTExchangeRate (certified)
}

// ═══════════════════════════════════════════════════════════════════════════
//                        POSSESSIO PAYMENTS CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

contract PossessioPayments is AccessControl, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    // ── Roles ───────────────────────────────────────────────────────────────
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    // ── Constants ───────────────────────────────────────────────────────────
    uint256 public constant UPKEEP_HYSTERESIS_BPS = 120;  // Automation kicks at 120% of minSwapBatch (IV.4)
    uint256 public constant TIMELOCK        = 48 hours;   // owner-pause resume delay
    uint256 public constant EMERGENCY_DELAY = 7 days;     // emergency withdraw delay
    uint256 public constant PAYEE_DELAY     = 48 hours;   // a proposed payee becomes active after this
    uint256 public constant ORACLE_STALE_CBETH  = 90_000; // 25h — cbETH/ETH exchange-rate feed (24h heartbeat)
    uint256 public constant ORACLE_STALE        = 3600;   // 1 hour — ETH/USD (~20-min heartbeat feed)
    uint256 public constant ORACLE_STALE_STABLE = 90_000; // 25h — USDC/USD (24h heartbeat)
    uint256 public constant SEQUENCER_GRACE     = 1 hours; // G-1: no kick or take until this long after the sequencer restarts
    uint256 public constant LIMIT_INCREASE_MAX_MULT = 2;  // P-H1: an increase is at most 2x the reference limit
    uint256 public constant LIMIT_DELAY     = 24 hours;   // daily limit increase delay
    uint256 public constant WINDOW_SIZE     = 24 hours;   // leaky-bucket window of the exit limits

    /// @notice The floor: a take never gets the lot for less than 99% of the
    ///         live oracle amount. Not owner-settable: a stolen key could lower
    ///         it. DERIVED from the measured feeds (SWEEP_REDESIGN §5): about
    ///         0.15% ETH/USD lag plus 0.03% cbETH/ETH plus the market gap.
    uint256 public constant FLOOR_BPS = 9900;
    uint64  public constant MIN_AUCTION_LENGTH = 10 minutes;
    uint64  public constant MAX_AUCTION_LENGTH = 2 hours;
    uint64  public constant MIN_KICK_DELAY     = 1 hours;
    uint64  public constant MAX_KICK_DELAY     = 7 days;
    uint256 private constant ONE = 1e18;
    uint256 private constant PHASE1_END_MULT = 15e17;     // 1.5x: a take above this is flagged

    // ── Immutables ──────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IERC20           public immutable CBETH;
    IMorphoVault     public immutable MORPHO_VAULT;        // Bitwise Morpho Blue USDC vault
    IChainlinkFeed   public immutable CHAINLINK;           // cbETH/ETH — 18-decimal exchange-rate feed
    IChainlinkFeed   public immutable CHAINLINK_USDC_USD;  // USDC/USD — 8-decimal price feed
    IChainlinkFeed   public immutable CHAINLINK_ETH_USD;   // ETH/USD — 8-decimal price feed
    IChainlinkFeed   public immutable SEQUENCER_UPTIME;    // L2 Sequencer Uptime Status Feed — 0-decimal, answer 0 = up
    ILSTExchangeRate public immutable LST_RATES;

    // ── Auction state ───────────────────────────────────────────────────────
    /// @notice The open lot. usdc == 0 means no lot. One lot at a time.
    struct Lot {
        uint128 usdc;        // 6-dec, the USDC the taker receives
        uint64  startedAt;
        uint64  endsAt;
    }
    Lot     public lot;
    uint256 public lastKickAt;         // last kick timestamp
    uint256 public minSwapBatch;       // minimum USDC above the float before a kick is allowed
    uint256 public usdcFloat;          // USDC the merchant keeps liquid; a kick sells only the balance above it
    uint256 public maxKickUsdc;        // cap per kick, both legs together; 0 = no cap
    uint64  public auctionLength;      // seconds a lot stays open, [MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH]
    uint64  public kickDelay;          // seconds between kicks, [MIN_KICK_DELAY, MAX_KICK_DELAY]
    bool    public auctionsPaused;     // owner circuit breaker: no kick, no take

    /// @notice Dual-acquisition split ratio, basis points: cbEthBps to the
    ///         auction (cbETH), the rest to the Morpho USDC vault. Range
    ///         [1000, 9000]. Merchant default 5000.
    uint16  public cbEthBps;

    /// @notice USDC principal still deposited in Morpho: up by each deposit, down
    ///         pro rata as shares leave (redeemMorpho, an emergency exit of the
    ///         shares). Deposits, not value: the gauge prices the shares live.
    uint256 public morphoDepositedPrincipal;

    // ── Payees (the stolen-owner-key defence) ───────────────────────────────
    /// @notice When a payee became, or becomes, active. 0 = not a payee. Every
    ///         exit (sendUSDC, sendCbETH, redeemMorpho, executeEmergencyWithdraw)
    ///         goes only to an active payee. Proposing takes PAYEE_DELAY;
    ///         removing is instant.
    mapping(address => uint64) public payeeActiveAt;

    // ── Chainlink Automation state (council IV.3, IV.7, IV.8, IV.9) ─────────
    address public automationForwarder;     // only this address may call performUpkeep
    address private _pendingForwarder;
    uint256 public upkeepID;
    bool    public upkeepPaused;
    mapping(bytes32 => bool) public executedUpkeeps;   // IV.9 replay protection
    uint256 public executedUpkeepCount;

    // ── Per-asset rolling exit limits (C-2, P-M4 leaky bucket) ──────────────
    uint256 public usdcDailyLimit;       // max USDC out per 24h window (6-dec); 0 = lockdown
    uint256 public usdcDailyWithdrawn;   // spent, as of usdcWindowStart
    uint256 public usdcWindowStart;      // last accounting timestamp
    uint256 public cbEthDailyLimit;      // max cbETH out per 24h window (18-dec); 0 = lockdown
    uint256 public cbEthDailyWithdrawn;
    uint256 public cbEthWindowStart;

    enum DailyLimitAsset { USDC, CBETH }

    struct QueuedLimit {
        uint256 newLimit;
        uint256 executeAfter;
    }
    /// @notice Queued per-asset limit increases, keyed by uint8(DailyLimitAsset).
    mapping(uint8 => QueuedLimit) public queuedAssetLimitIncrease;
    /// @notice P-H1: the highest limit set by the constructor or an executed increase.
    mapping(uint8 => uint256) public assetLimitRef;

    // Timelock queues
    mapping(bytes32 => uint256) public timelockQueue;
    uint256 private queueNonce;

    // Emergency withdrawal queue — per-token, per-amount
    struct EmergencyWithdraw {
        uint256 amount;
        uint256 executeAfter;
    }
    mapping(address => EmergencyWithdraw) public emergencyQueue;

    // ── Events ──────────────────────────────────────────────────────────────
    event Kicked(address indexed by, uint256 sellable, uint256 morphoIn, uint256 lotUsdc, uint256 endsAt);
    event LotTaken(address indexed taker, uint256 usdcOut, uint256 cbEthIn, uint256 multiplier);
    event LotExpired(uint256 usdc);
    event LotCancelled(uint256 usdc);   // G-2: an emergency USDC exit closed the lot
    /// @notice A take happened while the curve was still above 1.5x the oracle
    ///         amount: the oracle said cbETH was far cheaper than the market did.
    event ParOvershoot(address indexed taker, uint256 multiplier);
    event MorphoDeposited(uint256 usdcIn, uint256 sharesIssued);
    event TreasuryGaugeUpdated(uint256 totalEthEquivalent);
    event CbEthBpsUpdated(uint16 oldBps, uint16 newBps, uint256 timestamp);
    event MinSwapBatchUpdated(uint256 amount);
    event UsdcFloatUpdated(uint256 amount);
    event MaxKickUpdated(uint256 amount);
    event AuctionLengthUpdated(uint64 seconds_);
    event KickDelayUpdated(uint64 seconds_);
    event AuctionsPaused(address indexed by, uint256 timestamp);
    event AuctionsResumed(address indexed by, uint256 timestamp);
    event AuctionsResumeQueued(bytes32 indexed id, uint256 executeAfter);
    event PayeeProposed(address indexed payee, uint256 activeAt);
    event PayeeRemoved(address indexed payee);
    event USDCSent(address indexed by, uint256 amount, address indexed to, uint256 timestamp);
    event CbETHSent(address indexed by, uint256 amount, address indexed to, uint256 timestamp);
    event MorphoRedeemed(address indexed by, uint256 shares, uint256 usdcOut, address indexed to, uint256 timestamp);
    event AssetDailyLimitDecreased(uint8 indexed asset, uint256 newLimit);
    event AssetDailyLimitIncreaseQueued(uint8 indexed asset, uint256 newLimit, uint256 executeAfter);
    event AssetDailyLimitIncreaseExecuted(uint8 indexed asset, uint256 newLimit);
    event AssetDailyLimitIncreaseCancelled(uint8 indexed asset);
    event EmergencyQueued(address indexed token, uint256 amount, uint256 executeAfter);
    event EmergencyExecuted(address indexed token, uint256 amount, address to);
    event EmergencyCancelled(address indexed token);
    event UpkeepPerformed(uint256 gasUsed, uint256 valueMoved);
    event AutomationForwarderSet(address forwarder, uint256 timestamp);
    event ForwarderUpdateQueued(bytes32 indexed id, address newForwarder, uint256 executeAfter);
    event ForwarderUpdated(address oldForwarder, address newForwarder, uint256 timestamp);
    event UpkeepRegistered(uint256 upkeepID, uint256 timestamp);
    event UpkeepPausedSet(bool paused, uint256 timestamp);

    // ── Errors ──────────────────────────────────────────────────────────────
    error Paused();
    error LotOpen();
    error NoLot();
    error KickTooEarly();
    error BatchTooSmall();
    error ShortDelivery();
    error OracleStale();
    error OracleInvalid();
    error SequencerDown();          // G-1: the L2 sequencer uptime feed says down
    error SequencerGracePeriod();   // G-1: up again, but for less than SEQUENCER_GRACE
    error LotReserved();            // G-2: an open lot's USDC cannot be sent out
    error ZeroOutput();
    error LeakageDetected();
    error MorphoDepositFailed();
    error InvalidAddress();
    error InvalidBpsRange();
    error OutOfRange();
    error TimelockNotPassed();
    error NotQueued();
    error NothingQueued();
    error NothingToWithdraw();
    error ZeroAmount();
    error DailyLimitExceeded();
    error NoIncreaseQueued();
    error IncreaseTooLarge(uint256 requested, uint256 maxAllowed);
    error InvalidLimit();
    error NotAPayee(address to);
    error AlreadyPayee();
    error NoPayees();
    error NonCanonicalWiring(address got, address want);   // K-3
    error NotForwarder();
    error ForwarderNotSet();
    error ForwarderAlreadySet();
    error UpkeepAlreadyExecuted();
    error UpkeepIsPaused();

    // ── Modifiers ───────────────────────────────────────────────────────────
    modifier tlPassed(bytes32 id) {
        if (timelockQueue[id] == 0)              revert NotQueued();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < timelockQueue[id]) revert TimelockNotPassed();
        delete timelockQueue[id];
        _;
    }

    /// @notice IV.3 — gates performUpkeep to the Chainlink Automation Forwarder.
    modifier onlyForwarder() {
        if (automationForwarder == address(0)) revert ForwarderNotSet();
        if (msg.sender != automationForwarder) revert NotForwarder();
        _;
    }

    modifier notPaused() {
        if (auctionsPaused) revert Paused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────

    /// @notice Struct-input deployment parameters, abi-encoded into initArgs.
    struct DeployParams {
        address owner;              // written by the factory; the encoded value is discarded
        address usdc;
        address cbeth;
        address morphoVault;
        address chainlink;          // cbETH/ETH 18-dec exchange-rate feed
        address chainlinkUsdcUsd;   // USDC/USD 8-dec price feed
        address chainlinkEthUsd;    // ETH/USD 8-dec price feed
        address sequencerUptime;    // L2 Sequencer Uptime Status Feed, 0-dec (G-1)
        address lstRates;
        uint256 minSwapBatch;       // minimum USDC above the float before a kick
        uint256 usdcFloat;          // USDC kept liquid, never auctioned
        uint256 maxKickUsdc;        // cap per kick, 0 = no cap
        uint256 usdcDailyLimit;     // C-2 — 24h cap on USDC exits (sendUSDC + redeemMorpho), 6-dec
        uint256 cbEthDailyLimit;    // C-2 — 24h cap on cbETH exits (sendCbETH), 18-dec
        address[] payees;           // active at deployment; at least one, or the merchant is locked out
    }

    /**
     * @notice FACTORY-SHAPED constructor. PossessioFactory appends
     *         `abi.encode(owner, initArgs)` to the pinned template initCode, so
     *         any launchable template MUST take exactly `(address, bytes)`.
     *         THE FACTORY WRITES THE OWNER: `_factoryOwner` overrides whatever
     *         `p.owner` is carried inside `initArgs`.
     * @param _factoryOwner Owner, written by the factory. Never caller-supplied.
     * @param initArgs      abi.encode(DeployParams). Its `owner` field is ignored.
     */
    constructor(address _factoryOwner, bytes memory initArgs) {
        DeployParams memory p = abi.decode(initArgs, (DeployParams));
        p.owner = _factoryOwner;   // factory-written; the encoded value is discarded

        if (p.owner            == address(0)) revert InvalidAddress();
        if (p.usdc             == address(0)) revert InvalidAddress();
        if (p.cbeth            == address(0)) revert InvalidAddress();
        if (p.morphoVault      == address(0)) revert InvalidAddress();
        if (p.chainlink        == address(0)) revert InvalidAddress();
        if (p.chainlinkUsdcUsd == address(0)) revert InvalidAddress();
        if (p.chainlinkEthUsd  == address(0)) revert InvalidAddress();
        if (p.sequencerUptime  == address(0)) revert InvalidAddress();
        if (p.lstRates         == address(0)) revert InvalidAddress();

        // K-3 (external review, KupiaSec 2026-10-15): PossessioFactory pins this
        // template's code, not the wiring inside initArgs. On Base mainnet the
        // template accepts only the canonical wiring. Other chains (tests,
        // testnets) keep the non-zero checks above.
        if (block.chainid == 8453) _requireBaseWiring(p);

        // Decimal-class validation: cbETH/ETH is an 18-decimal exchange-rate
        // feed; USDC/USD and ETH/USD are 8-decimal price feeds.
        if (IChainlinkFeed(p.chainlink).decimals()        != 18) revert InvalidAddress();
        if (IChainlinkFeed(p.chainlinkUsdcUsd).decimals() != 8)  revert InvalidAddress();
        if (IChainlinkFeed(p.chainlinkEthUsd).decimals()  != 8)  revert InvalidAddress();
        if (IChainlinkFeed(p.sequencerUptime).decimals()  != 0)  revert InvalidAddress();

        USDC               = IERC20(p.usdc);
        CBETH              = IERC20(p.cbeth);
        MORPHO_VAULT       = IMorphoVault(p.morphoVault);
        CHAINLINK          = IChainlinkFeed(p.chainlink);
        CHAINLINK_USDC_USD = IChainlinkFeed(p.chainlinkUsdcUsd);
        CHAINLINK_ETH_USD  = IChainlinkFeed(p.chainlinkEthUsd);
        SEQUENCER_UPTIME   = IChainlinkFeed(p.sequencerUptime);
        LST_RATES          = ILSTExchangeRate(p.lstRates);

        minSwapBatch  = p.minSwapBatch;
        usdcFloat     = p.usdcFloat;
        maxKickUsdc   = p.maxKickUsdc;
        auctionLength = 30 minutes;
        kickDelay     = 24 hours;

        // C-2 per-asset exit limits; 0 = lockdown. P-H1 reference limits.
        usdcDailyLimit   = p.usdcDailyLimit;
        cbEthDailyLimit  = p.cbEthDailyLimit;
        assetLimitRef[uint8(DailyLimitAsset.USDC)]  = p.usdcDailyLimit;
        assetLimitRef[uint8(DailyLimitAsset.CBETH)] = p.cbEthDailyLimit;
        usdcWindowStart  = block.timestamp;
        cbEthWindowStart = block.timestamp;

        // Dual-acquisition baseline: 50% auction (cbETH), 50% Morpho USDC.
        cbEthBps = 5000;

        // Payees: the merchant's own addresses, active at once. An empty list
        // would deploy a contract nobody can withdraw from.
        uint256 n = p.payees.length;
        if (n == 0) revert NoPayees();
        for (uint256 i = 0; i < n; i++) {
            address who = p.payees[i];
            if (who == address(0)) revert InvalidAddress();
            payeeActiveAt[who] = uint64(block.timestamp);
            emit PayeeProposed(who, block.timestamp);
        }

        _grantRole(OWNER_ROLE, p.owner);
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
    }

    /// @dev K-3: the canonical Base mainnet wiring. Constructor-only, so it
    ///      adds no runtime code.
    function _requireBaseWiring(DeployParams memory p) private pure {
        _pin(p.usdc,             BaseWiring.USDC);
        _pin(p.cbeth,            BaseWiring.CBETH);
        _pin(p.morphoVault,      BaseWiring.MORPHO_VAULT);
        _pin(p.chainlink,        BaseWiring.CHAINLINK_CBETH);
        _pin(p.chainlinkUsdcUsd, BaseWiring.CHAINLINK_USDC);
        _pin(p.chainlinkEthUsd,  BaseWiring.CHAINLINK_ETH);
        _pin(p.sequencerUptime,  BaseWiring.CHAINLINK_SEQUENCER);
        _pin(p.lstRates,         BaseWiring.LST_RATES);
    }

    function _pin(address got, address want) private pure {
        if (got != want) revert NonCanonicalWiring(got, want);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              THE AUCTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice USDC above the float: what a kick would sell before the cap.
    function sellableUsdc() public view returns (uint256) {
        uint256 bal = USDC.balanceOf(address(this));
        return bal > usdcFloat ? bal - usdcFloat : 0;
    }

    /// @notice True while a lot is open and not expired. Its USDC is reserved
    ///         for the taker (G-2): sendUSDC cannot reach below it.
    function lotOpen() public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return lot.usdc != 0 && block.timestamp < lot.endsAt;
    }

    /// @notice True when kick() would open a lot now. Non-reverting; used by
    ///         Automation's checkUpkeep and by any keeper's pre-flight.
    function canKick() public view returns (bool) {
        if (auctionsPaused) return false;
        // forge-lint: disable-next-line(block-timestamp)
        if (lot.usdc != 0 && block.timestamp < lot.endsAt) return false;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < lastKickAt + kickDelay) return false;
        if (sellableUsdc() < minSwapBatch) return false;
        if (!_cbEthOracleFresh()) return false;
        if (_usdcToEth(1e6) == 0) return false;
        if (!_sequencerUp()) return false;
        return true;
    }

    /**
     * @notice Kick: deposit the Morpho share of the USDC above the float, and
     *         put the cbETH share up as a lot. Anyone may call it; a kick can
     *         only happen when the rules allow, and it moves nothing below the
     *         curve. Reverts if a lot is open, the delay has not passed, the
     *         batch is too small, or an oracle is stale (fail closed).
     */
    function kick() external nonReentrant notPaused {
        _kick();
    }

    function _kick() internal {
        // 1. An expired lot is closed first; an open one blocks the kick.
        if (lot.usdc != 0) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < lot.endsAt) revert LotOpen();
            emit LotExpired(lot.usdc);
            delete lot;
        }
        // 2. Cadence.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < lastKickAt + kickDelay) revert KickTooEarly();
        // 3. Size: only the balance above the float, at least the batch, at most the cap.
        uint256 sellable = sellableUsdc();
        if (sellable < minSwapBatch || sellable == 0) revert BatchTooSmall();
        uint256 kickAmount = sellable;
        if (maxKickUsdc != 0 && kickAmount > maxKickUsdc) kickAmount = maxKickUsdc;
        // 4. Oracle, fail closed: both the cbETH/ETH rate and the USDC→ETH path
        //    must be fresh, or nothing is priced and nothing moves (P-1 rule).
        //    G-1: and the sequencer must have been up for SEQUENCER_GRACE.
        _requireSequencerUp();
        _oracleCbEth(1e6);
        // 5. The split, as in v2.4: the lot (cbETH side) is cbEthBps of the
        //    kick and the integer-division residue goes to the Morpho leg by
        //    construction. The Morpho share is deposited now: no price risk.
        uint256 lotUsdc = (kickAmount * cbEthBps) / 10000;
        uint256 morphoAlloc = kickAmount - lotUsdc;
        if (morphoAlloc > 0) _depositMorpho(morphoAlloc);
        // 6. The lot.
        uint256 endsAt;
        if (lotUsdc > 0) {
            endsAt = block.timestamp + auctionLength;
            lot = Lot({usdc: uint128(lotUsdc), startedAt: uint64(block.timestamp), endsAt: uint64(endsAt)});
        }
        lastKickAt = block.timestamp;
        emit Kicked(msg.sender, sellable, morphoAlloc, lotUsdc, endsAt);
        emit TreasuryGaugeUpdated(_computeCurrentEthEquivalent());
    }

    /// @dev The Morpho leg, as in v2.4.1: consumption and share-delta checks.
    function _depositMorpho(uint256 morphoAlloc) internal {
        uint256 usdcBefore   = USDC.balanceOf(address(this));
        uint256 sharesBefore = MORPHO_VAULT.balanceOf(address(this));
        USDC.forceApprove(address(MORPHO_VAULT), morphoAlloc);
        try MORPHO_VAULT.deposit(morphoAlloc, address(this)) returns (uint256 /* sharesIssued */) {
            USDC.forceApprove(address(MORPHO_VAULT), 0);
            if ((usdcBefore - USDC.balanceOf(address(this))) != morphoAlloc) revert LeakageDetected();
            uint256 sharesAfter = MORPHO_VAULT.balanceOf(address(this));
            if (sharesAfter <= sharesBefore) revert MorphoDepositFailed();
            morphoDepositedPrincipal += morphoAlloc;
            emit MorphoDeposited(morphoAlloc, sharesAfter - sharesBefore);
        } catch {
            USDC.forceApprove(address(MORPHO_VAULT), 0);
            revert MorphoDepositFailed();
        }
    }

    /// @dev G-3 (cold-seat audit 2026-10-18): the principal falls pro rata with
    ///      the shares that leave, so morphoDepositedPrincipal reads "what is
    ///      still deposited", never a cumulative total.
    function _reduceMorphoPrincipal(uint256 sharesOut, uint256 sharesBefore) internal {
        if (sharesBefore == 0) return;
        uint256 principal = morphoDepositedPrincipal;
        uint256 out = sharesOut >= sharesBefore ? principal : (principal * sharesOut) / sharesBefore;
        morphoDepositedPrincipal = principal - out;
    }

    /**
     * @notice Take the open lot: deliver the cbETH the curve asks for now (an
     *         approval of at least currentRequired() is needed) and receive
     *         the lot's USDC. Anyone may call it.
     */
    function take() external nonReentrant notPaused {
        (uint256 usdcOut, uint256 required, uint256 m) = _settleStart();
        uint256 cbBefore = CBETH.balanceOf(address(this));
        CBETH.safeTransferFrom(msg.sender, address(this), required);
        if (CBETH.balanceOf(address(this)) - cbBefore < required) revert ShortDelivery();
        USDC.safeTransfer(msg.sender, usdcOut);
        _settleEnd(usdcOut, required, m);
    }

    /**
     * @notice Take the open lot with a callback: the USDC goes out first, the
     *         taker sources cbETH inside possessioTake, and the balance check
     *         settles it. Effects precede the call; the contract-wide
     *         reentrancy guard covers kick, take and the exits.
     */
    function takeWithCallback(bytes calldata data) external nonReentrant notPaused {
        (uint256 usdcOut, uint256 required, uint256 m) = _settleStart();
        uint256 cbBefore = CBETH.balanceOf(address(this));
        USDC.safeTransfer(msg.sender, usdcOut);
        ITaker(msg.sender).possessioTake(usdcOut, required, data);
        if (CBETH.balanceOf(address(this)) < cbBefore + required) revert ShortDelivery();
        _settleEnd(usdcOut, required, m);
    }

    /// @dev Checks the lot, prices it, and closes it BEFORE any transfer.
    function _settleStart() internal returns (uint256 usdcOut, uint256 required, uint256 m) {
        Lot memory l = lot;
        // forge-lint: disable-next-line(block-timestamp)
        if (l.usdc == 0 || block.timestamp >= l.endsAt) revert NoLot();
        _requireSequencerUp();   // G-1: nothing is priced while the sequencer is down or just back
        m = _multiplier(block.timestamp - l.startedAt, l.endsAt - l.startedAt);
        required = _required(l.usdc, m);
        usdcOut = l.usdc;
        delete lot;
    }

    function _settleEnd(uint256 usdcOut, uint256 required, uint256 m) internal {
        emit LotTaken(msg.sender, usdcOut, required, m);
        if (m > PHASE1_END_MULT) emit ParOvershoot(msg.sender, m);
        emit TreasuryGaugeUpdated(_computeCurrentEthEquivalent());
    }

    /// @notice The curve's multiplier now, 1e18 = the oracle amount. 0 if no lot.
    function currentMultiplier() external view returns (uint256) {
        Lot memory l = lot;
        // forge-lint: disable-next-line(block-timestamp)
        if (l.usdc == 0 || block.timestamp >= l.endsAt) return 0;
        return _multiplier(block.timestamp - l.startedAt, l.endsAt - l.startedAt);
    }

    /// @notice The cbETH a take must deliver now for the open lot. Reverts if
    ///         there is no lot or an oracle is stale (so does take).
    function currentRequired() external view returns (uint256) {
        Lot memory l = lot;
        // forge-lint: disable-next-line(block-timestamp)
        if (l.usdc == 0 || block.timestamp >= l.endsAt) revert NoLot();
        return _required(l.usdc, _multiplier(block.timestamp - l.startedAt, l.endsAt - l.startedAt));
    }

    /// @dev Live anchor: the oracle amount is read at the time of the take.
    ///      Rounds up, in the contract's favour.
    function _required(uint256 usdc, uint256 m) internal view returns (uint256) {
        return (_oracleCbEth(usdc) * m + ONE - 1) / ONE;
    }

    /**
     * @notice The multiplier at elapsed time `t` of an auction of length `L`
     *         (SPEC §4.3; Reserve DutchTrade's shape):
     *           phase 1, t in [0, 0.20L): geometric from 1536x to 1.5x, as ten
     *             halvings with linear interpolation inside each halving, so no
     *             fixed-point power is needed: m = 1.5 * 2^(9-n) * (2 - f) with
     *             s = 10t/(0.20L), n = floor(s), f = s - n;
     *           phase 2, [0.20L, 0.45L): linear from 1.5x to 1.0x;
     *           phase 3, [0.45L, 0.95L): linear from 1.0x to FLOOR_BPS;
     *           phase 4, [0.95L, L): flat at FLOOR_BPS.
     *         Monotone non-increasing in t; continuous at every boundary.
     */
    function _multiplier(uint256 t, uint256 L) internal pure returns (uint256 m) {
        uint256 p1 = (L * 20) / 100;
        uint256 p2 = (L * 45) / 100;
        uint256 p3 = (L * 95) / 100;
        uint256 floor_ = FLOOR_BPS * 1e14;              // 0.99e18
        if (t < p1) {
            uint256 s18 = (t * 10 * ONE) / p1;          // [0, 10e18)
            uint256 n   = s18 / ONE;                    // 0..9
            uint256 f18 = s18 - n * ONE;                // [0, 1e18)
            m = (PHASE1_END_MULT * (uint256(1) << (9 - n)) * (2 * ONE - f18)) / ONE;
        } else if (t < p2) {
            m = PHASE1_END_MULT - ((PHASE1_END_MULT - ONE) * (t - p1)) / (p2 - p1);
        } else if (t < p3) {
            m = ONE - ((ONE - floor_) * (t - p2)) / (p3 - p2);
        } else {
            m = floor_;
        }
    }

    /// @dev The cbETH the oracle says `usdc` is worth now: USDC → USD → ETH
    ///      (two 8-decimal feeds) → cbETH (the 18-decimal exchange-rate feed).
    ///      Reverts on any stale or invalid feed: fail closed.
    function _oracleCbEth(uint256 usdc) internal view returns (uint256) {
        uint256 ethPerCbEth18 = _validateOracle();
        uint256 ethWei = _usdcToEth(usdc);
        if (ethWei == 0) revert OracleStale();
        return (ethWei * ONE) / ethPerCbEth18;   // cbETH = ETH / (ETH per cbETH)
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          CIRCUIT BREAKER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pause kicks and takes. Owner only. An open lot simply expires.
    function pauseAuctions() external onlyRole(OWNER_ROLE) {
        auctionsPaused = true;
        emit AuctionsPaused(msg.sender, block.timestamp);
    }

    /// @notice Queue a timelocked resume (TIMELOCK, 48 h).
    function queueResumeAuctions() external onlyRole(OWNER_ROLE) returns (bytes32 id) {
        queueNonce++;
        id = keccak256(abi.encodePacked("resume", msg.sender, queueNonce, block.timestamp));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit AuctionsResumeQueued(id, timelockQueue[id]);
    }

    function resumeAuctions(bytes32 id) external onlyRole(OWNER_ROLE) tlPassed(id) {
        auctionsPaused = false;
        emit AuctionsResumed(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     PAYEES (THE STOLEN-KEY DEFENCE)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Propose a payee; it becomes active after PAYEE_DELAY (48 h). The
    ///         console shows the event, so a proposal the merchant did not make
    ///         is visible in time to remove it and move funds to their own
    ///         payees. Re-proposing an active payee reverts.
    function proposePayee(address who) external onlyRole(OWNER_ROLE) {
        if (who == address(0)) revert InvalidAddress();
        if (payeeActiveAt[who] != 0) revert AlreadyPayee();
        uint256 activeAt = block.timestamp + PAYEE_DELAY;
        payeeActiveAt[who] = uint64(activeAt);
        emit PayeeProposed(who, activeAt);
    }

    /// @notice Remove a payee, or cancel a pending proposal. Instant.
    function removePayee(address who) external onlyRole(OWNER_ROLE) {
        if (payeeActiveAt[who] == 0) revert NotAPayee(who);
        delete payeeActiveAt[who];
        emit PayeeRemoved(who);
    }

    /// @notice True when `who` may receive an exit now.
    function isPayee(address who) public view returns (bool) {
        uint64 at = payeeActiveAt[who];
        // forge-lint: disable-next-line(block-timestamp)
        return at != 0 && block.timestamp >= at;
    }

    function _requirePayee(address to) internal view {
        if (!isPayee(to)) revert NotAPayee(to);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               EXITS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Send idle USDC to an active payee, within the rolling usdcDailyLimit
    ///         (shared with redeemMorpho's output). Larger exits go through
    ///         the 7-day emergency path.
    function sendUSDC(uint256 amount, address to) external onlyRole(OWNER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requirePayee(to);
        // G-2: an open lot's USDC is reserved for its taker, so the owner (or a
        // stolen key) cannot leave a lot standing that can no longer be taken.
        if (lotOpen() && USDC.balanceOf(address(this)) < amount + lot.usdc) revert LotReserved();
        _consumeUsdcDailyLimit(amount);
        USDC.safeTransfer(to, amount);
        emit USDCSent(msg.sender, amount, to, block.timestamp);
    }

    /// @notice Send cbETH to an active payee, within the rolling cbEthDailyLimit.
    function sendCbETH(uint256 amount, address to) external onlyRole(OWNER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requirePayee(to);
        _consumeCbEthDailyLimit(amount);
        CBETH.safeTransfer(to, amount);
        emit CbETHSent(msg.sender, amount, to, block.timestamp);
    }

    /// @notice Redeem Morpho vault shares to USDC, sent to an active payee. The
    ///         redeemed USDC counts against usdcDailyLimit, checked on the
    ///         vault's actual output.
    function redeemMorpho(uint256 shares, address to)
        external onlyRole(OWNER_ROLE) nonReentrant
        returns (uint256 usdcOut)
    {
        if (shares == 0) revert ZeroAmount();
        _requirePayee(to);
        uint256 sharesBefore = MORPHO_VAULT.balanceOf(address(this));
        usdcOut = MORPHO_VAULT.redeem(shares, to, address(this));
        if (usdcOut == 0) revert ZeroOutput();
        _reduceMorphoPrincipal(shares, sharesBefore);   // G-3
        _consumeUsdcDailyLimit(usdcOut);
        emit MorphoRedeemed(msg.sender, shares, usdcOut, to, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          C-2: PER-ASSET EXIT LIMITS (USDC / cbETH — audit 2026-07-14)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Decrease a per-asset daily exit limit. Applies immediately.
    function decreaseAssetDailyLimit(DailyLimitAsset asset, uint256 newLimit) external onlyRole(OWNER_ROLE) {
        if (asset == DailyLimitAsset.USDC) {
            if (newLimit >= usdcDailyLimit) revert InvalidLimit();
            usdcDailyLimit = newLimit;
        } else {
            if (newLimit >= cbEthDailyLimit) revert InvalidLimit();
            cbEthDailyLimit = newLimit;
        }
        emit AssetDailyLimitDecreased(uint8(asset), newLimit);
    }

    /// @notice Queue an increase to a per-asset daily exit limit; LIMIT_DELAY
    ///         (24 h) before it takes effect, and at most LIMIT_INCREASE_MAX_MULT
    ///         times the reference limit (P-H1).
    function queueAssetDailyLimitIncrease(DailyLimitAsset asset, uint256 newLimit) external onlyRole(OWNER_ROLE) {
        uint256 current = asset == DailyLimitAsset.USDC ? usdcDailyLimit : cbEthDailyLimit;
        if (newLimit <= current) revert InvalidLimit();
        _checkIncreaseCap(newLimit, assetLimitRef[uint8(asset)]);
        queuedAssetLimitIncrease[uint8(asset)] = QueuedLimit({
            newLimit: newLimit,
            executeAfter: block.timestamp + LIMIT_DELAY
        });
        emit AssetDailyLimitIncreaseQueued(uint8(asset), newLimit, block.timestamp + LIMIT_DELAY);
    }

    function executeAssetDailyLimitIncrease(DailyLimitAsset asset) external onlyRole(OWNER_ROLE) {
        QueuedLimit memory q = queuedAssetLimitIncrease[uint8(asset)];
        if (q.executeAfter == 0)              revert NoIncreaseQueued();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();
        if (asset == DailyLimitAsset.USDC) {
            usdcDailyLimit = q.newLimit;
        } else {
            cbEthDailyLimit = q.newLimit;
        }
        if (q.newLimit > assetLimitRef[uint8(asset)]) assetLimitRef[uint8(asset)] = q.newLimit;
        delete queuedAssetLimitIncrease[uint8(asset)];
        emit AssetDailyLimitIncreaseExecuted(uint8(asset), q.newLimit);
    }

    function cancelAssetDailyLimitIncrease(DailyLimitAsset asset) external onlyRole(OWNER_ROLE) {
        if (queuedAssetLimitIncrease[uint8(asset)].executeAfter == 0) revert NoIncreaseQueued();
        delete queuedAssetLimitIncrease[uint8(asset)];
        emit AssetDailyLimitIncreaseCancelled(uint8(asset));
    }

    /// @dev P-H1: an increase may be at most LIMIT_INCREASE_MAX_MULT x the
    ///      reference. A zero reference (deployed in lockdown) is uncapped for
    ///      the first raise, which is still delayed.
    function _checkIncreaseCap(uint256 newLimit, uint256 ref) internal pure {
        if (ref == 0) return;
        uint256 maxAllowed = ref * LIMIT_INCREASE_MAX_MULT;
        if (newLimit > maxAllowed) revert IncreaseTooLarge(newLimit, maxAllowed);
    }

    /// @dev P-M4: every limit is a leaky bucket. The spent amount drains back
    ///      to zero linearly over WINDOW_SIZE, so there is no boundary to
    ///      straddle for 2x the cap in an instant.
    function _drained(uint256 spent, uint256 lastTs, uint256 limit) internal view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - lastTs;
        if (elapsed >= WINDOW_SIZE) return 0;
        uint256 refill = (limit * elapsed) / WINDOW_SIZE;
        return spent > refill ? spent - refill : 0;
    }

    function _consumeUsdcDailyLimit(uint256 amount) internal {
        uint256 spent = _drained(usdcDailyWithdrawn, usdcWindowStart, usdcDailyLimit);
        if (spent + amount > usdcDailyLimit) revert DailyLimitExceeded();
        usdcDailyWithdrawn = spent + amount;
        usdcWindowStart = block.timestamp;
    }

    function _consumeCbEthDailyLimit(uint256 amount) internal {
        uint256 spent = _drained(cbEthDailyWithdrawn, cbEthWindowStart, cbEthDailyLimit);
        if (spent + amount > cbEthDailyLimit) revert DailyLimitExceeded();
        cbEthDailyWithdrawn = spent + amount;
        cbEthWindowStart = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     EMERGENCY WITHDRAWAL (7-DAY TIMELOCK)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Queue an emergency withdrawal of any held token (migration,
    ///         shutdown, bridging cbETH to L1). 7-day delay. Owner only.
    function queueEmergencyWithdraw(address token, uint256 amount) external onlyRole(OWNER_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0)         revert ZeroAmount();
        emergencyQueue[token] = EmergencyWithdraw({amount: amount, executeAfter: block.timestamp + EMERGENCY_DELAY});
        emit EmergencyQueued(token, amount, block.timestamp + EMERGENCY_DELAY);
    }

    /// @notice Execute a queued emergency withdrawal after 7 days, to an active
    ///         payee. This is the deliberate escape hatch above the daily caps.
    function executeEmergencyWithdraw(address token, address to) external onlyRole(OWNER_ROLE) nonReentrant {
        _requirePayee(to);
        EmergencyWithdraw memory q = emergencyQueue[token];
        if (q.executeAfter == 0)              revert NothingQueued();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 amount  = q.amount > balance ? balance : q.amount;
        if (amount == 0) revert NothingToWithdraw();
        delete emergencyQueue[token];
        // G-2: a USDC emergency exit cancels the lot instead of leaving one
        // standing that can no longer be taken. G-3: shares leaving take their
        // share of the principal with them.
        if (token == address(USDC) && lot.usdc != 0) { emit LotCancelled(lot.usdc); delete lot; }
        if (token == address(MORPHO_VAULT)) _reduceMorphoPrincipal(amount, balance);
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyExecuted(token, amount, to);
    }

    function cancelEmergencyWithdraw(address token) external onlyRole(OWNER_ROLE) {
        if (emergencyQueue[token].executeAfter == 0) revert NothingQueued();
        delete emergencyQueue[token];
        emit EmergencyCancelled(token);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════
    // None of these can move funds or lower the floor; a stolen key can only
    // make auctions rarer or smaller.

    /// @notice Minimum USDC above the float before a kick is allowed.
    function setMinSwapBatch(uint256 amount) external onlyRole(OWNER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        minSwapBatch = amount;
        emit MinSwapBatchUpdated(amount);
    }

    /// @notice USDC kept liquid for operations; never auctioned.
    function setUsdcFloat(uint256 amount) external onlyRole(OWNER_ROLE) {
        usdcFloat = amount;
        emit UsdcFloatUpdated(amount);
    }

    /// @notice Cap per kick, both legs together. 0 = no cap.
    function setMaxKickUsdc(uint256 amount) external onlyRole(OWNER_ROLE) {
        maxKickUsdc = amount;
        emit MaxKickUpdated(amount);
    }

    /// @notice How long a lot stays open, within [10 min, 2 h].
    function setAuctionLength(uint64 seconds_) external onlyRole(OWNER_ROLE) {
        if (seconds_ < MIN_AUCTION_LENGTH || seconds_ > MAX_AUCTION_LENGTH) revert OutOfRange();
        auctionLength = seconds_;
        emit AuctionLengthUpdated(seconds_);
    }

    /// @notice Minimum time between kicks, within [1 h, 7 d].
    function setKickDelay(uint64 seconds_) external onlyRole(OWNER_ROLE) {
        if (seconds_ < MIN_KICK_DELAY || seconds_ > MAX_KICK_DELAY) revert OutOfRange();
        kickDelay = seconds_;
        emit KickDelayUpdated(seconds_);
    }

    /// @notice The split: cbEthBps to the auction, the rest to Morpho. Bounded
    ///         to [1000, 9000] so neither leg can be zeroed without a redeploy.
    function setCbEthBps(uint16 newBps) external onlyRole(OWNER_ROLE) {
        if (newBps < 1000 || newBps > 9000) revert InvalidBpsRange();
        uint16 oldBps = cbEthBps;
        cbEthBps = newBps;
        emit CbEthBpsUpdated(oldBps, newBps, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice cbETH/ETH feed validation: round completeness, updatedAt, age
    ///         within ORACLE_STALE_CBETH (25 h, a 24 h heartbeat feed), answer
    ///         positive. Returns ETH per cbETH, 1e18-scaled: the feed's answer is
    ///         how much ETH one cbETH is worth (description "CBETH / ETH";
    ///         MEASURED on Base 2026-10-18: 1.1417e18). G-4: named for what it holds.
    function _validateOracle() internal view returns (uint256 ethPerCbEth18) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = CHAINLINK.latestRoundData();
        if (answeredInRound < roundId)                        revert OracleStale();
        if (updatedAt == 0)                                   revert OracleStale();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > ORACLE_STALE_CBETH)  revert OracleStale();
        if (answer <= 0)                                      revert OracleInvalid();
        ethPerCbEth18 = uint256(answer);
    }

    /// @dev Non-reverting twin of _validateOracle, for canKick.
    function _cbEthOracleFresh() internal view returns (bool) {
        try CHAINLINK.latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (answeredInRound < roundId) return false;
            if (updatedAt == 0) return false;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE_CBETH) return false;
            return answer > 0;
        } catch {
            return false;
        }
    }

    /// @dev G-1 (cold-seat audit 2026-10-18): the Base L2 Sequencer Uptime
    ///      Status Feed. answer 0 = up, 1 = down; startedAt = when the current
    ///      status began. After a restart, kicks and takes wait SEQUENCER_GRACE
    ///      so the price feeds can catch up before anything is priced. A
    ///      reverting feed fails closed.
    function _requireSequencerUp() internal view {
        (, int256 answer, uint256 startedAt, , ) = SEQUENCER_UPTIME.latestRoundData();
        if (answer != 0) revert SequencerDown();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < startedAt + SEQUENCER_GRACE) revert SequencerGracePeriod();
    }

    /// @dev Non-reverting twin of _requireSequencerUp, for canKick.
    function _sequencerUp() internal view returns (bool) {
        try SEQUENCER_UPTIME.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer != 0) return false;
            // forge-lint: disable-next-line(block-timestamp)
            return block.timestamp >= startedAt + SEQUENCER_GRACE;
        } catch {
            return false;
        }
    }

    /**
     * @notice Convert a USDC amount (6-dec) to ETH-wei (18-dec) through two
     *         USD-quoted Base feeds: USDC/USD and ETH/USD (there is no USDC/ETH
     *         feed on Base). Returns 0 if EITHER feed is stale, reverting or
     *         invalid; callers treat 0 as "unpriced" and fail closed where it
     *         matters (kick, take) or downgrade where it does not (the gauge).
     *             ethWei = usdcAmt * 1e12 * usdcUsdE8 / ethUsdE8
     */
    function _usdcToEth(uint256 usdcAmt) internal view returns (uint256 ethAmt) {
        if (usdcAmt == 0) return 0;
        int256 usdcUsdE8;
        try CHAINLINK_USDC_USD.latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (answeredInRound < roundId)                           return 0;
            if (updatedAt == 0)                                      return 0;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE_STABLE)   return 0;
            if (answer <= 0)                                         return 0;
            usdcUsdE8 = answer;
        } catch {
            return 0;
        }
        int256 ethUsdE8;
        try CHAINLINK_ETH_USD.latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (answeredInRound < roundId)                           return 0;
            if (updatedAt == 0)                                      return 0;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE)          return 0;
            if (answer <= 0)                                         return 0;
            ethUsdE8 = answer;
        } catch {
            return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        ethAmt = (usdcAmt * 1e12 * uint256(usdcUsdE8)) / uint256(ethUsdE8);
    }

    /// @notice ETH-equivalent of the cbETH leg (via LST_RATES) plus the Morpho
    ///         leg (convertToAssets, then the two feeds). Each leg downgrades
    ///         to 0 on its own failure; the gauge never reports a stale sum.
    function _computeCurrentEthEquivalent() internal view returns (uint256) {
        uint256 cbEthInEth;
        uint256 cbBal = CBETH.balanceOf(address(this));
        if (cbBal > 0) {
            try LST_RATES.cbEthToEth(cbBal) returns (uint256 v) { cbEthInEth = v; } catch { cbEthInEth = 0; }
        }
        uint256 morphoInEth;
        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        if (morphoShares > 0) {
            try MORPHO_VAULT.convertToAssets(morphoShares) returns (uint256 usdcValue) {
                morphoInEth = _usdcToEth(usdcValue);
            } catch {
                morphoInEth = 0;
            }
        }
        return cbEthInEth + morphoInEth;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Treasury gauge: ETH-equivalent of both legs at current rates.
    function getTreasuryGauge() external view returns (uint256) {
        return _computeCurrentEthEquivalent();
    }

    function getUSDCBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function getCbETHBalance() external view returns (uint256) {
        return CBETH.balanceOf(address(this));
    }

    /// @notice Morpho leg: shares held and their current USDC value (0 if the
    ///         vault read reverts while shares > 0: "vault state unclear").
    function getMorphoBalance() external view returns (uint256 shares, uint256 currentUSDCValue) {
        shares = MORPHO_VAULT.balanceOf(address(this));
        if (shares == 0) return (0, 0);
        try MORPHO_VAULT.convertToAssets(shares) returns (uint256 v) { currentUSDCValue = v; } catch { currentUSDCValue = 0; }
    }

    function usdcDailyRemaining() external view returns (uint256) {
        uint256 spent = _drained(usdcDailyWithdrawn, usdcWindowStart, usdcDailyLimit);
        return spent >= usdcDailyLimit ? 0 : usdcDailyLimit - spent;
    }

    function cbEthDailyRemaining() external view returns (uint256) {
        uint256 spent = _drained(cbEthDailyWithdrawn, cbEthWindowStart, cbEthDailyLimit);
        return spent >= cbEthDailyLimit ? 0 : cbEthDailyLimit - spent;
    }

    function nextKickAllowed() external view returns (uint256) {
        return lastKickAt + kickDelay;
    }

    function isEmergencyQueued(address token) external view returns (bool) {
        return emergencyQueue[token].executeAfter != 0;
    }

    function emergencyReady(address token) external view returns (bool) {
        uint256 eAfter = emergencyQueue[token].executeAfter;
        // forge-lint: disable-next-line(block-timestamp)
        return eAfter != 0 && block.timestamp >= eAfter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          CHAINLINK AUTOMATION (council-ratified 2026-05-12, Phase 3)
    //
    //  Optional. Automation gains NO authority: performUpkeep is kick(), which
    //  anyone may call. Hysteresis (IV.4): the sellable USDC must reach 120% of
    //  minSwapBatch before Automation kicks; kick itself takes the canonical
    //  threshold.
    // ═══════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata /*checkData*/)
        external view override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (upkeepPaused) return (false, "");
        if (!canKick()) return (false, "");
        uint256 hysteresisThreshold = (minSwapBatch * UPKEEP_HYSTERESIS_BPS) / 100;
        if (sellableUsdc() < hysteresisThreshold) return (false, "");
        return (true, "");
    }

    /// @notice The forwarder's kick. Replay-protected (IV.9) on top of the
    ///         kick's own delay.
    function performUpkeep(bytes calldata /*performData*/) external override onlyForwarder nonReentrant notPaused {
        if (upkeepPaused) revert UpkeepIsPaused();
        bytes32 replayKey = keccak256(abi.encode("kick", lastKickAt));
        if (executedUpkeeps[replayKey]) revert UpkeepAlreadyExecuted();
        executedUpkeeps[replayKey] = true;
        uint256 gasBefore = gasleft();
        uint256 usdcBefore = USDC.balanceOf(address(this));
        _kick();
        uint256 usdcAfter = USDC.balanceOf(address(this));
        emit UpkeepPerformed(gasBefore - gasleft(), usdcBefore > usdcAfter ? usdcBefore - usdcAfter : 0);
        unchecked { executedUpkeepCount += 1; }
    }

    /// @notice One-time forwarder registration. Updates afterwards go through
    ///         the 48 h timelock below.
    function setForwarder(address forwarder) external onlyRole(OWNER_ROLE) {
        if (forwarder == address(0)) revert InvalidAddress();
        if (automationForwarder != address(0)) revert ForwarderAlreadySet();
        automationForwarder = forwarder;
        emit AutomationForwarderSet(forwarder, block.timestamp);
    }

    function setUpkeepID(uint256 newUpkeepID) external onlyRole(OWNER_ROLE) {
        upkeepID = newUpkeepID;
        emit UpkeepRegistered(newUpkeepID, block.timestamp);
    }

    function queueForwarderUpdate(address newForwarder) external onlyRole(OWNER_ROLE) returns (bytes32 id) {
        if (newForwarder == address(0)) revert InvalidAddress();
        _pendingForwarder = newForwarder;
        id = keccak256(abi.encodePacked("forwarderUpdate", block.timestamp, newForwarder));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ForwarderUpdateQueued(id, newForwarder, timelockQueue[id]);
    }

    function executeForwarderUpdate(bytes32 id) external onlyRole(OWNER_ROLE) tlPassed(id) {
        address newForwarder = _pendingForwarder;
        if (newForwarder == address(0)) revert InvalidAddress();
        address old = automationForwarder;
        automationForwarder = newForwarder;
        _pendingForwarder = address(0);
        emit ForwarderUpdated(old, newForwarder, block.timestamp);
    }

    function pauseUpkeep() external onlyRole(OWNER_ROLE) {
        upkeepPaused = true;
        emit UpkeepPausedSet(true, block.timestamp);
    }

    function unpauseUpkeep() external onlyRole(OWNER_ROLE) {
        upkeepPaused = false;
        emit UpkeepPausedSet(false, block.timestamp);
    }
}
