// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  PossessioPayments
 * @notice Phase 2 merchant payment processor — the POSSESSIO Payments product.
 *         Non-custodial smart contract infrastructure for Base mainnet merchant
 *         card-payment settlement and treasury accumulation. Sold to merchants
 *         as a one-time software deployment; POSSESSIO retains ZERO on-chain
 *         authority post-deployment.
 *
 *         CORE MECHANICS:
 *           - Receives USDC inflows (e.g. from card-network split settlement)
 *           - Routes a merchant-controlled portion to DAI working-capital reserve
 *           - Routes the remainder into cbETH yield-bearing treasury
 *           - 100% of swept value remains in merchant-owned reserves
 *           - No protocol fee extraction at any layer
 *
 *         CONTRACT POSITION IN PROTOCOL:
 *           PossessioPayments is the Base mainnet product in the POSSESSIO
 *           multi-chain product line. Each contract is single-purpose and
 *           single-chain. There are no cross-chain dependencies in this
 *           contract. Merchants who later wish to operate Ethereum L1
 *           validator infrastructure can independently deploy the separate
 *           POSSESSIO Validator product on Ethereum mainnet and bridge cbETH
 *           between contracts using their preferred bridge under their own
 *           risk acceptance.
 *
 *         100% cbETH RATIONALE:
 *           rETH on Base mainnet is a bridged OptimismMintableERC20 token,
 *           NOT native Rocket Pool rETH. Its `burn()` function is gated by
 *           `onlyBridge` modifier, making rETH non-redeemable from user
 *           contracts on Base. cbETH is held as a yield-bearing treasury
 *           asset that accrues Ethereum staking rewards passively via
 *           Coinbase's liquid staking token. cbETH is not redeemed by this
 *           contract; merchants who wish to convert cbETH to ETH may do so
 *           via DEX swap or off-chain Coinbase unwrap.
 *
 *         v2.4 AMENDMENT (2026-05-24) — 50/50 DUAL ACQUISITION + Phase 1.1 fixes:
 *           After DAI reserve refill, remaining USDC splits 50/50 (merchant-
 *           configurable post-deploy) between:
 *             · cbETH leg → USDC→WETH→cbETH multi-hop (Uniswap V3 + Aerodrome)
 *             · Morpho leg → USDC direct deposit to Bitwise Morpho Blue USDC vault
 *                            (ERC4626, mirror of L1Anchor.routeToMorpho pattern)
 *
 *           Morpho USDC routing target is council-ratified (historical Claude
 *           seats with continuity on this protocol). Bitwise-curated Morpho
 *           Blue USDC vault is the canonical destination matching L1Anchor.sol
 *           BITWISE_MORPHO_VAULT immutable. Native USDC on Base — no bridge
 *           dependency.
 *
 *           Additional v2.4 fixes folded into this drop:
 *             · X-LINK gas-griefing fix (Grok finding 2026-05-23): wrapper-side
 *               try/catch around _sweep clears _activeExecutionSecret on revert
 *               so failed sweeps don't burn nonces or strand armed secrets.
 *             · Event semantics fix (Bugcatcher/Grok finding 2026-05-23):
 *               UCRSwept fragmented into UCRSweptDaiOnly (DAI-leg-only sweep)
 *               and UCRSweptFull (cbETH+Morpho dual-leg sweep). Each leg gets
 *               its own per-leg event (CbEthAcquired, MorphoDeposited).
 *
 *         v2.3 AMENDMENT (2026-05-23) — VENUE CORRECTION:
 *           Prior v2.2 routed USDC → cbETH through Uniswap V3 0.3% pool.
 *           Terminal verification on 2026-05-23 disqualified the V3 venue:
 *           the canonical USDC/cbETH 0.3% pool on Base (0xa8e4...8a) holds
 *           ~$6K TVL — insufficient for protocol-scale routing.

 *           v2.3 routes USDC → cbETH via multi-hop:
 *             USDC → WETH  (Uniswap V3, 0.05% fee)
 *             WETH → cbETH (Aerodrome Slipstream, tickSpacing=1)
 *
 *           Substrate artifacts: cast verification of Aerodrome pool
 *           0x47ca96ea59c13f72745928887f84c9f52c3d7348 returned active
 *           liquidity 8.687e24. Chainlink cbETH/ETH feed verified at
 *           18-decimal precision.
 *
 *           See: COUNCIL_2026-05-23_Bugcatcher_SubstrateClosure_Plate
 *                V2VenueAmendment.md for full substrate stack.
 *
 *           v2.4.1 (2026-05-24) — Plate review findings folded:
 *             · Finding 1 (MEDIUM): USDC leakage check added to Morpho leg
 *               for defense-in-depth parity with cbETH leg's swap-consumption
 *               checks. Now both legs revert on declared-vs-consumed mismatch.
 *             · Finding 2 (LOW): MorphoDeposited event now records verified
 *               share-delta (sharesAfter - sharesBefore) instead of vault's
 *               claimed sharesIssued. Under honest vault both match; under
 *               misbehaving vault the verified delta is the truth.
 *           Plate's L1Anchor parity flag — same gaps may exist in L1Anchor's
 *           routeToMorpho. Cross-contract propagation queued downstream.
 *
 *           v2.4 attribution — COUNCIL_2 + COUNCIL_3 shared work:
 *             · Bugcatcher: v2.3 architecture (multi-hop USDC→WETH→cbETH,
 *               Aerodrome Slipstream venue, IcbETH lockdown, per-leg leakage
 *               protection, constructor decimal-class guard, ORACLE_STALE_CBETH).
 *             · Plate: v2.3 review pass — caught the ORACLE_STALE_CBETH drift
 *               where the constant was declared but the call site still used
 *               the legacy 3600s ORACLE_STALE on the 24-hour-heartbeat cbETH
 *               feed. Live-deployment-fail bug. Fixed in combined v2.3.
 *             · Grok: v2.3/v2.5 adversarial full review — caught the X-LINK
 *               gas-griefing accounting wart (secret armed before _sweep call;
 *               if _sweep reverts, nonce is burned and secret left armed for
 *               next-call overwrite). Identified the 50/50 dual-acquisition
 *               implementation gap against the pre-ratified Morpho USDC target.
 *             · Bugcatcher: v2.4 amendment integrating Grok's findings + the
 *               50/50 split + event semantics fragmentation in a single drop.
 *
 *             Discipline floor caught all three drift classes before deployment.
 *             Multi-Byte work compounded at the council.
 *
 *         v2.4.2 (2026-05-27) — INSTITUTIONAL READ-SURFACE HARDENING:
 *
 *           Code Integrity (COUNCIL_2, Claude council seat) routed two findings
 *           for pre-institutional-review (UNICEF/Tom Lee/PayPal/Stripe outreach
 *           tier). Both findings address read-surface gaps where v2.4 dual-
 *           acquisition architecture outpaced the contract's reporting surface.
 *
 *           Finding 1 — getTreasuryGauge() underreports:
 *             _computeCurrentEthEquivalent predates v2.4 dual-acquisition. It
 *             reported only the cbETH leg, excluding the Morpho USDC leg's
 *             accumulated value. For cbEthBps = 5000 default, approximately
 *             half the treasury value was invisible to the gauge.
 *
 *           Finding 2 — getMorphoBalance() missing:
 *             Read-surface asymmetry. Every other token holding (USDC, DAI,
 *             cbETH) had a single-call getter. Morpho leg required three RPC
 *             calls (MORPHO_VAULT() → balanceOf() → convertToAssets()) to
 *             match the same disclosure.
 *
 *           v2.4.2 fix:
 *             1. Constructor refactored to DeployParams struct (matches
 *                PossessioHook.DeployParams pattern; eliminates stack-too-deep
 *                risk preemptively; one named param per field for institutional
 *                reviewer readability).
 *             2. Two new Chainlink feeds wired (USDC/USD and ETH/USD, both
 *                8-decimal, Base mainnet). USDC/ETH direct does not exist on
 *                Base — cast-verified 2026-05-27. Compositional path:
 *                  USDC-in-ETH = (usdcAmt * 1e12 * usdcUsdE8) / ethUsdE8 / 1e6
 *                Both feeds must be fresh for Morpho leg to count. NatSpec
 *                documents the compositional staleness explicitly.
 *             3. _computeCurrentEthEquivalent extended to dual-leg aggregation.
 *                Try/catch wraps each oracle read and each vault read; partial
 *                failure cleanly downgrades (e.g., Morpho leg reports 0 if
 *                vault paused, cbETH leg still reports correctly).
 *             4. getMorphoBalance() added as dual-return view (shares +
 *                currentUSDCValue) with try/catch around convertToAssets per
 *                L1Anchor pattern. NatSpec notes vault yield accrual surfaces
 *                as monotonic value growth between reads.
 *
 *           Verified Base mainnet feed addresses (cast 2026-05-27):
 *             USDC/USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B (8 dec)
 *             ETH/USD:  0x71041dDdaD3595F9CEd3DcCFBe3D1F4b0a16Bb70 (8 dec)
 *
 *           v2.4.2 attribution:
 *             · Code Integrity: substrate routing, both findings, gauge-gap
 *               framing against institutional-review macro context.
 *             · Bugcatcher: option adjudication (Option A vs B on both
 *               findings), terminal-substrate feed verification spec,
 *               decimal-conversion math, struct-input refactor,
 *               compositional staleness documentation, contract production.
 *
 *           No deployed-funds risk in v2.4.2 — read-surface additions only.
 *           Plate test gauntlet update required (constructor → struct, new
 *           feed mocks, gauge dual-leg assertions, getMorphoBalance tests).
 *
 * DEPLOYMENT MODEL:
 *   POSSESSIO sells the merchant a per-merchant PossessioPayments contract as
 *   a one-time software delivery. Once deployed, merchant holds OWNER_ROLE.
 *   POSSESSIO retains ZERO on-chain authority post-deployment. The contract is
 *   non-custodial software infrastructure; it is not a financial service or
 *   custodial product. POSSESSIO does not extract transaction fees.
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
 * ADDRESSES (Base Mainnet — terminal-verified 2026-05-23):
 *   USDC:                       0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   WETH:                       0x4200000000000000000000000000000000000006
 *   cbETH:                      0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22
 *   Uniswap V3 Router:          0x2626664c2603336E57B271c5C0b26F421741e481
 *   Aerodrome Slipstream Pool:  0x47ca96ea59c13f72745928887f84c9f52c3d7348
 *                               (cbETH/WETH, tickSpacing=1, stable tier)
 *   Aerodrome Slipstream Router: <PENDING Phase 2 terminal verification>
 *   Bitwise Morpho USDC Vault:  <SET PER DEPLOYMENT — mirror L1Anchor.BITWISE_MORPHO_VAULT>
 *   Chainlink cbETH/ETH:        0x806b4Ac04501c29769051e42783cF04dCE41440b
 *                               (18-decimal exchange-rate feed; 24h heartbeat)
 *   Chainlink DAI/ETH:          (set per deployment, 8-decimal price feed)
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

/// @notice Uniswap V3 SwapRouter02 on Base. Used for USDC → WETH leg of the
///         cbETH acquisition path, and for the USDC → DAI reserve refill.
///         The legacy v2.2 single-hop USDC → cbETH path is removed; the V3
///         USDC/cbETH 0.3% pool has insufficient depth for protocol-scale routing
///         (terminal-verified ~$6K TVL on 2026-05-23).
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

/// @notice Aerodrome Slipstream Router on Base. Used for the WETH → cbETH leg
///         of the multi-hop cbETH acquisition path. Aerodrome Slipstream uses
///         `tickSpacing` (int24) as the pool tier discriminator, distinct from
///         Uniswap V3's `fee` (uint24) model.
/// @dev    Interface signature is PROVISIONAL. Function body implementation
///         pauses on Phase 2 substrate (cast verification of router address +
///         exact swap function selector against Base mainnet). Plate's spec
///         amendment §1.1, §2.3, §5.3 covers the same gap.
interface IAerodromeSlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24   tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

/// @notice Chainlink oracle feed for staleness validation.
///         decimals() added in v2.3 for constructor-guard decimal-class
///         verification: cbETH/ETH is 18-decimal (exchange-rate class);
///         DAI/ETH is 8-decimal (price-feed class). The asymmetry is
///         structural — Chainlink classifies yield-bearing-asset rate
///         feeds at native 18-decimal precision and legacy price feeds
///         at 8-decimal. Constructor guard enforces alignment at deploy.
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
///         v2.4 — interface mirrors L1Anchor.sol's IMorphoVault exactly so
///         the verified routing pattern carries cleanly. Morpho Blue vaults
///         follow the ERC4626 standard. Bitwise curates a USDC vault on Base
///         that is the canonical destination for both PossessioPayments
///         (this contract) and L1Anchor (the L1 settlement contract).
interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice cbETH exchange rate oracle — immutable, ownerless singleton.
///         Provides protocol-native cbETH/ETH rate for treasury gauge readout.
///         Ratified as shared infrastructure with no admin surface per
///         Gemini-seat specification.
interface ILSTExchangeRate {
    function cbEthToEth(uint256 cbEthAmount) external view returns (uint256);
}

// ═══════════════════════════════════════════════════════════════════════════
//                        POSSESSIO PAYMENTS CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @dev v2.3 (2026-05-23) — cbETH False Green resolution. Routes cbETH
 *      acquisition through multi-hop USDC→WETH→cbETH (V3 + Aerodrome
 *      Slipstream) instead of the v2.2 single-hop V3 USDC→cbETH path
 *      that was terminal-disqualified for insufficient depth. Constructor
 *      adds decimal-class validation for Chainlink feeds. Staleness window
 *      for the cbETH/ETH 18-decimal exchange-rate feed relaxed to 90,000s
 *      (25h) to accommodate Chainlink's 24-hour heartbeat cadence. See
 *      COUNCIL_2026-05-23_Bugcatcher_SubstrateClosure_PlateV2VenueAmendment.md
 *      for the full substrate stack.
 *
 *      v2.2 (2026-05-12) added Chainlink Automation for sweep().
 *      Setup requirement: OWNER must call
 *          grantRole(OPERATOR_ROLE, address(thisContract))
 *      after deployment so the internal dispatcher (which calls sweep with
 *      msg.sender == address(this)) has the necessary role. Sweep is gated
 *      OWNER_ROLE || OPERATOR_ROLE; granting OPERATOR_ROLE to the contract
 *      itself enables the automation path without weakening manual access.
 */
contract PossessioPayments is AccessControl, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    // ── Role identifiers ────────────────────────────────────────────────────

    bytes32 public constant OWNER_ROLE    = keccak256("OWNER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ── Constants ───────────────────────────────────────────────────────────

    uint256 public constant CBETH_PCT       = 100;        // 100% to cbETH (rETH removed per council)
    // RETH_PCT removed — rETH on Base is bridged-not-native, council-ratified removal

    uint256 public constant SWEEP_DELAY     = 24 hours;   // minimum between sweeps

    // ─── Chainlink Automation constant (council IV.4 — ratified 2026-05-12) ───

    /// @notice IV.4 — multiplier for checkUpkeep hysteresis buffer (basis 100).
    ///         Upkeep only triggers when USDC balance ≥ minSwapBatch × 120/100.
    ///         The contract's own sweep still accepts the canonical minSwapBatch;
    ///         this buffer applies only to Automation's decision to act.
    uint256 public constant UPKEEP_HYSTERESIS_BPS = 120; // 20% over canonical threshold
    uint256 public constant TIMELOCK        = 48 hours;   // owner-pause resume delay
    uint256 public constant EMERGENCY_DELAY = 7 days;     // emergency withdraw delay

    uint24  public constant FEE_LST         = 500;        // 0.05% — V3 USDC/WETH leg (deepest pair on Base)
    uint24  public constant FEE_STABLE      = 500;        // 0.05% — V3 USDC/DAI pair

    // ─── Aerodrome Slipstream venue (v2.3 amendment — terminal-grounded 2026-05-23) ───

    /// @notice Aerodrome Slipstream cbETH/WETH pool on Base mainnet.
    ///         Stable tier (tickSpacing=1). Replaces the V3 USDC/cbETH path
    ///         which was terminal-disqualified (~$6K TVL).
    ///         Cast-verified active liquidity: 8.687e24 (4.3M× the V3 cliff).
    address public constant AERODROME_CBETH_WETH_POOL = 0x47cA96Ea59C13F72745928887f84C9F52C3D7348;

    /// @notice TickSpacing for the Aerodrome Slipstream cbETH/WETH pool.
    int24   public constant CBETH_TICK_SPACING = 1;

    /// @notice Staleness window for the cbETH/ETH exchange-rate feed.
    ///         Chainlink publishes this feed on a 24-hour heartbeat with 0.5%
    ///         deviation threshold. The legacy 3600s window would reject
    ///         valid feed data during low-volatility periods. 90,000s allows
    ///         one heartbeat cycle + 1-hour slack for publisher delay.
    uint256 public constant ORACLE_STALE_CBETH = 90_000;  // 25h — cbETH/ETH exchange-rate feed

    /// @notice Legacy staleness window retained for the DAI/ETH price feed
    ///         and any other 8-decimal Chainlink feed in the contract surface.
    uint256 public constant ORACLE_STALE    = 3600;       // 1 hour — DAI/ETH and similar
    uint256 public constant LIMIT_DELAY     = 24 hours;   // daily limit increase delay
    uint256 public constant WINDOW_SIZE     = 24 hours;   // daily withdrawal window

    // ── Immutables ──────────────────────────────────────────────────────────

    IERC20           public immutable USDC;
    IERC20           public immutable CBETH;
    IERC20           public immutable DAI;
    IERC20           public immutable WETH;  // v2.3 — added for USDC→WETH→cbETH multi-hop
    ISwapRouter      public immutable ROUTER;  // Uniswap V3 SwapRouter02 (USDC→WETH, USDC→DAI)
    IAerodromeSlipstreamRouter public immutable AERO_ROUTER;  // v2.3 — Aerodrome Slipstream (WETH→cbETH)
    IMorphoVault     public immutable MORPHO_VAULT;  // v2.4 — Bitwise Morpho Blue USDC vault
    IChainlinkFeed   public immutable CHAINLINK;       // cbETH/ETH — 18-decimal exchange-rate feed
    IChainlinkFeed   public immutable CHAINLINK_DAI;   // DAI/ETH — 8-decimal price feed
    IChainlinkFeed   public immutable CHAINLINK_USDC_USD; // v2.4.2 — USDC/USD — 8-decimal price feed (Base mainnet 0x7e86…2bc6B)
    IChainlinkFeed   public immutable CHAINLINK_ETH_USD;  // v2.4.2 — ETH/USD — 8-decimal price feed (Base mainnet 0x7104…Bb70)
    ILSTExchangeRate public immutable LST_RATES;

    // ── Mutable state ───────────────────────────────────────────────────────

    bool    public routingPaused;       // pause flag for sweep
    bool    public guardianEnabled;     // merchant-controlled Guardian opt-in
    uint256 public lastSweepTime;       // last successful sweep timestamp
    uint256 public minSwapBatch;        // minimum USDC before sweep allowed

    /// @notice v2.4 — Dual-acquisition split ratio. Basis points (10000 = 100%).
    ///         5000 = 50% to cbETH leg, 50% to Morpho USDC leg. Merchant default.
    ///         Range bounds enforced by setCbEthBps: [1000, 9000] (10%–90%).
    uint16  public cbEthBps;

    /// @notice v2.4 — Cumulative USDC principal deposited to Morpho.
    ///         Tracks deposits, not current value (which fluctuates with vault yield).
    uint256 public morphoDepositedPrincipal;

    // ─── Chainlink Automation state (council IV.3, IV.7, IV.8, IV.9 — ratified 2026-05-12) ───

    /// @notice Chainlink Automation Forwarder address. Only this address may call performUpkeep.
    ///         Initially address(0); set by OWNER once at registration via setForwarder.
    ///         Updatable thereafter only via OWNER 48h timelock.
    address public automationForwarder;

    /// @notice Pending forwarder update queued via 48h timelock (IV.8).
    address private _pendingForwarder;

    /// @notice Chainlink Automation Upkeep ID. Set after registration.
    uint256 public upkeepID;

    /// @notice IV.7 Position A for Payments — but a cheap pause flag still useful here.
    ///         Independent of routingPaused flag (which is what notPaused checks).
    bool public upkeepPaused;

    /// @notice IV.9 — replay protection. Same-block re-execution guard + audit trail.
    ///         Primary cross-block protection: SWEEP_DELAY (24h) inside sweep itself.
    mapping(bytes32 => bool) public executedUpkeeps;

    /// @notice Monotonic counter of automated executions. For console dashboard.
    uint256 public executedUpkeepCount;

    // ─── Secure-Context-Handshake state (council-ratified 2026-05-14) ───
    // Monotonic nonce + one-time-use execution secret. Authorized entrypoints
    // (sweep, performUpkeep) mint a secret and arm _activeExecutionSecret
    // immediately before calling _sweep; _sweep verifies and consumes it as its
    // first action. This proves _sweep was reached through a sanctioned branch
    // without relying on msg.sender semantics inside the internal call — works
    // identically for the OWNER/OPERATOR path and the forwarder path.
    uint256 private _executionNonce;
    uint256 private _activeExecutionSecret;

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

    // ── Events ──────────────────────────────────────────────────────────────

    // Sweep mechanism events — v2.4: fragmented from UCRSwept for indexer clarity.
    // Each distinct sweep outcome gets its own event; each routing leg emits
    // its own per-leg event. UCRSwept retained as a deprecated alias for
    // backwards-compat with v2.3 indexers; new code should subscribe to the
    // specific events below.

    /// @notice Emitted when sweep completes with DAI refill but no leftover USDC.
    ///         No cbETH or Morpho leg ran this cycle (DAI reserve consumed all USDC).
    event UCRSweptDaiOnly(uint256 usdcIn, uint256 daiOut, uint256 timestamp);

    /// @notice Emitted when sweep completes with both DAI refill (if any) and
    ///         dual-leg routing (cbETH + Morpho USDC). Per-leg detail in
    ///         CbEthAcquired and MorphoDeposited events emitted in same tx.
    event UCRSweptFull(
        uint256 usdcIn,
        uint256 cbEthOut,
        uint256 morphoSharesOut,
        uint256 ethEquivalentAdded,
        uint256 timestamp
    );

    /// @notice Per-leg: cbETH leg of dual-acquisition completed.
    event CbEthAcquired(uint256 usdcIn, uint256 wethIntermediate, uint256 cbEthOut);

    /// @notice Per-leg: Morpho USDC leg of dual-acquisition completed.
    event MorphoDeposited(uint256 usdcIn, uint256 sharesIssued);

    /// @notice Emitted when sweep cycle ratio changes (Owner-controlled).
    event CbEthBpsUpdated(uint16 oldBps, uint16 newBps, uint256 timestamp);

    /// @notice DEPRECATED in v2.4 — retained for v2.3 indexer backwards-compat.
    ///         New code should subscribe to UCRSweptDaiOnly / UCRSweptFull.
    event UCRSwept(
        uint256 usdcIn,
        uint256 cbEthOut,
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

    // Treasury Gauge events
    event TreasuryGaugeUpdated(uint256 totalEthEquivalent);

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

    // Chainlink Automation events (council-ratified 2026-05-12)
    event UpkeepPerformed(uint256 gasUsed, uint256 valueMoved);
    event AutomationForwarderSet(address forwarder, uint256 timestamp);
    event ForwarderUpdateQueued(bytes32 indexed id, address newForwarder, uint256 executeAfter);
    event ForwarderUpdated(address oldForwarder, address newForwarder, uint256 timestamp);
    event UpkeepRegistered(uint256 upkeepID, uint256 timestamp);
    event UpkeepPausedSet(bool paused, uint256 timestamp);

    // ── Errors ──────────────────────────────────────────────────────────────

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

    // ─── v2.4 — Morpho dual-acquisition errors ───
    error MorphoDepositFailed();
    error InvalidBpsRange();

    // ─── Chainlink Automation errors (council-ratified 2026-05-12) ───
    error NotForwarder();
    error ForwarderNotSet();
    error ForwarderAlreadySet();

    // ─── Secure-Context-Handshake error (council-ratified 2026-05-14) ───
    error SecurityHandshakeFailed();
    error UpkeepAlreadyExecuted();
    error UpkeepIsPaused();

    // ── Modifiers ───────────────────────────────────────────────────────────

    modifier tlPassed(bytes32 id) {
        if (timelockQueue[id] == 0)              revert NotQueued();
        // Timelock comparison against 48h TIMELOCK; validator's ~12s manipulation window is immaterial.
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
        if (routingPaused) revert RoutingPaused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────

    /**
     * @notice Deploy a merchant's PossessioPayments contract.
     * @param owner           Merchant wallet address — receives OWNER_ROLE
     * @param usdc_           USDC token address on Base
     * @param cbeth_          cbETH token address on Base
     * @param dai_            DAI token address on Base
     * @param weth_           WETH token address on Base (v2.3 — multi-hop intermediate)
     * @param router_         Uniswap V3 SwapRouter02 address on Base
     * @param aeroRouter_     Aerodrome Slipstream Router address on Base (v2.3)
     * @param morphoVault_    Bitwise Morpho Blue USDC vault address on Base (v2.4)
     * @param chainlink_      Chainlink cbETH/ETH feed address on Base (18-decimal)
     * @param chainlinkDai_   Chainlink DAI/ETH feed address on Base (8-decimal)
     * @param lstRates_       Immutable LSTExchangeRate singleton address
     * @param minSwapBatch_   Minimum USDC required before sweep allowed
     * @param daiCeiling_     Target DAI reserve (merchant's operating buffer). 0 = opt out.
     * @param dailyLimit_     Max DAI withdrawable per 24h window. 0 = lockdown.
     */
    /// @notice v2.4.2 — Struct-input deployment parameters.
    ///         Matches PossessioHook.DeployParams pattern; eliminates stack-too-deep
    ///         risk preemptively; one named field per param for institutional reviewer
    ///         readability. All address fields must be non-zero; constructor reverts
    ///         InvalidAddress otherwise. All Chainlink feed addresses validated for
    ///         decimal-class correctness.
    struct DeployParams {
        address owner;
        address usdc;
        address cbeth;
        address dai;
        address weth;
        address router;
        address aeroRouter;
        address morphoVault;
        address chainlink;          // cbETH/ETH 18-dec exchange-rate feed
        address chainlinkDai;       // DAI/ETH 8-dec price feed
        address chainlinkUsdcUsd;   // v2.4.2 — USDC/USD 8-dec price feed
        address chainlinkEthUsd;    // v2.4.2 — ETH/USD 8-dec price feed
        address lstRates;
        uint256 minSwapBatch;
        uint256 daiCeiling;
        uint256 dailyLimit;
    }

    constructor(DeployParams memory p) {
        if (p.owner            == address(0)) revert InvalidAddress();
        if (p.usdc             == address(0)) revert InvalidAddress();
        if (p.cbeth            == address(0)) revert InvalidAddress();
        if (p.dai              == address(0)) revert InvalidAddress();
        if (p.weth             == address(0)) revert InvalidAddress();
        if (p.router           == address(0)) revert InvalidAddress();
        if (p.aeroRouter       == address(0)) revert InvalidAddress();
        if (p.morphoVault      == address(0)) revert InvalidAddress();
        if (p.chainlink        == address(0)) revert InvalidAddress();
        if (p.chainlinkDai     == address(0)) revert InvalidAddress();
        if (p.chainlinkUsdcUsd == address(0)) revert InvalidAddress();
        if (p.chainlinkEthUsd  == address(0)) revert InvalidAddress();
        if (p.lstRates         == address(0)) revert InvalidAddress();

        // ─── Decimal-class validation (v2.3 defense-in-depth + v2.4.2 extension) ───
        // cbETH/ETH must be 18-decimal exchange-rate feed (Chainlink yield-bearing-asset class).
        // DAI/ETH must be 8-decimal price feed (Chainlink standard price-feed class).
        // USDC/USD and ETH/USD must both be 8-decimal price feeds (cast-verified 2026-05-27).
        // Asymmetric requirement reflects Chainlink's feed-class taxonomy.
        if (IChainlinkFeed(p.chainlink).decimals()        != 18) revert InvalidAddress();
        if (IChainlinkFeed(p.chainlinkDai).decimals()     != 8)  revert InvalidAddress();
        if (IChainlinkFeed(p.chainlinkUsdcUsd).decimals() != 8)  revert InvalidAddress();
        if (IChainlinkFeed(p.chainlinkEthUsd).decimals()  != 8)  revert InvalidAddress();

        USDC               = IERC20(p.usdc);
        CBETH              = IERC20(p.cbeth);
        DAI                = IERC20(p.dai);
        WETH               = IERC20(p.weth);
        ROUTER             = ISwapRouter(p.router);
        AERO_ROUTER        = IAerodromeSlipstreamRouter(p.aeroRouter);
        MORPHO_VAULT       = IMorphoVault(p.morphoVault);
        CHAINLINK          = IChainlinkFeed(p.chainlink);
        CHAINLINK_DAI      = IChainlinkFeed(p.chainlinkDai);
        CHAINLINK_USDC_USD = IChainlinkFeed(p.chainlinkUsdcUsd);
        CHAINLINK_ETH_USD  = IChainlinkFeed(p.chainlinkEthUsd);
        LST_RATES          = ILSTExchangeRate(p.lstRates);

        minSwapBatch = p.minSwapBatch;
        daiCeiling   = p.daiCeiling;
        dailyLimit   = p.dailyLimit;
        windowStart  = block.timestamp;

        // v2.4 — Dual-acquisition baseline: 50% cbETH, 50% Morpho USDC.
        // Council-ratified merchant-default per historical Claude seats.
        cbEthBps = 5000;

        // Owner gets OWNER_ROLE and is admin of OPERATOR and GUARDIAN roles
        _grantRole(OWNER_ROLE, p.owner);
        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, OWNER_ROLE);
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          SWEEP MECHANISM
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Sweep — fills DAI reserve to ceiling (if set), then converts
     *         remaining USDC into cbETH (100%), holds in-contract.
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
     *         architecture limits the treasury layer to cbETH.
     *
     * @param minDaiOut    Minimum DAI output from USDC swap (0 if no refill needed)
     * @param minWethOut   Minimum WETH output from USDC→WETH leg (v2.3 — multi-hop intermediate)
     * @param minCbEthOut  Minimum cbETH output from WETH→cbETH leg (slippage guard)
     */
    function sweep(
        uint256 minDaiOut,
        uint256 minWethOut,
        uint256 minCbEthOut
    ) external nonReentrant notPaused {
        // External entrypoint for direct OWNER_ROLE / OPERATOR_ROLE callers.
        // Authorization is the role check below; reentrancy and pause guards
        // are carried by this wrapper. Execution logic lives in _sweep so the
        // Automation path (performUpkeep) can reuse it via an internal call
        // without re-acquiring the contract-level ReentrancyGuard.
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert InvalidAddress();
        }

        // ─── v2.4 X-LINK gas-griefing fix (Grok finding 2026-05-23) ─────
        // Secure-Context-Handshake: mint a monotonic one-time secret and arm
        // it. _sweep verifies + consumes on the validation side. v2.3 left
        // the secret armed on _sweep revert; v2.4 wraps the call in try/catch
        // so wrapper-side state is always cleaned up.
        uint256 secret = ++_executionNonce;
        _activeExecutionSecret = secret;

        try this._sweepDispatch(minDaiOut, minWethOut, minCbEthOut, secret) {
            // success — _sweep consumed the secret on the validation side
        } catch (bytes memory reason) {
            // Failed sweep — ensure the secret is cleared on the wrapper side
            // so subsequent attempts don't see stale armed state.
            _activeExecutionSecret = 0;
            // Re-bubble the revert reason so callers see the actual failure
            // instead of a generic catch-swallow.
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @notice Internal dispatcher exposed only for the external sweep wrapper's
    ///         try/catch pattern (v2.4 X-LINK fix). Solidity does not have
    ///         try/catch on internal calls; the dispatcher is `external` but
    ///         gated by `msg.sender == address(this)` so no external caller
    ///         can reach it directly.
    function _sweepDispatch(
        uint256 minDaiOut,
        uint256 minWethOut,
        uint256 minCbEthOut,
        uint256 secret
    ) external {
        if (msg.sender != address(this)) revert InvalidAddress();
        _sweep(minDaiOut, minWethOut, minCbEthOut, secret);
    }

    /// @notice Internal sweep execution core. No reentrancy guard, no role
    ///         check, no pause check — callers (external sweep, performUpkeep)
    ///         are each responsible for carrying the guards appropriate to
    ///         their entry path. Holds the canonical treasury execution logic
    ///         unchanged from the prior monolithic sweep().
    function _sweep(
        uint256 minDaiOut,
        uint256 minWethOut,
        uint256 minCbEthOut,
        uint256 secret
    ) internal {
        // ─── Secure-Context-Handshake verification ───────────────────────
        // _sweep is internal, but visibility alone is not the guard: this
        // checks that the caller minted and armed a matching one-time secret
        // through a sanctioned entrypoint. Consume immediately — before the
        // SWEEP_DELAY check, before oracle validation, before any external
        // interaction — so the secret cannot be reused and no revert path
        // below can leave it armed.
        if (secret == 0 || secret != _activeExecutionSecret) {
            revert SecurityHandshakeFailed();
        }
        _activeExecutionSecret = 0;

        // SWEEP_DELAY is 24 hours; validator's ~12s manipulation window is immaterial against 86,400s.
        // forge-lint: disable-next-line(block-timestamp)
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
                // and proceed with cbETH leg. Merchant's sweep still executes,
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
                            // DAI swap failed — skip, proceed with cbETH leg
                            // USDC stays in contract for cbETH leg below
                        }

                        // Reset approval — defends against malicious router that
                        // consumes less than approved, leaving dangling allowance.
                        USDC.forceApprove(address(ROUTER), 0);
                    }
                }
            }
        }

        // Step 2: if any USDC remains after DAI refill, split per cbEthBps
        // between cbETH (via multi-hop) and Morpho USDC vault (direct deposit).
        if (usdcAfterDai == 0) {
            lastSweepTime = block.timestamp;
            emit UCRSweptDaiOnly(usdcBalance, usdcBalance, block.timestamp);
            // v2.3 backwards-compat alias (deprecated event)
            emit UCRSwept(usdcBalance, 0, 0, block.timestamp);
            return;
        }

        // ═════════════════════════════════════════════════════════════════════
        // v2.4 — Dual-acquisition: 50/50 split (configurable via cbEthBps).
        //
        // cbETH leg:   USDC → WETH (Uniswap V3 0.05%) → cbETH (Aerodrome Slipstream)
        //              For L1 MAVAN staking destination.
        //
        // Morpho leg:  USDC → Bitwise Morpho Blue USDC vault (ERC4626 direct deposit)
        //              For stable-asset yield. Mirror of L1Anchor.routeToMorpho.
        //
        // Council-ratified merchant baseline. Both legs run in a single sweep
        // cycle. Failure on either leg reverts the whole sweep; partial
        // execution is not a valid state.
        // ═════════════════════════════════════════════════════════════════════

        // Compute per-leg allocations from cbEthBps (basis points out of 10,000).
        // Integer-division residue goes to the Morpho leg by construction.
        uint256 cbEthAlloc = (usdcAfterDai * cbEthBps) / 10000;
        uint256 morphoAlloc = usdcAfterDai - cbEthAlloc;

        // ─── cbETH leg: USDC → WETH → cbETH ─────────────────────────────────
        uint256 cbEthOut = 0;
        uint256 wethOut = 0;
        if (cbEthAlloc > 0) {
            // Sub-leg 1: USDC → WETH (Uniswap V3, 0.05% fee)
            uint256 usdcBeforeWethSwap = USDC.balanceOf(address(this));
            USDC.forceApprove(address(ROUTER), cbEthAlloc);

            wethOut = ROUTER.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn:           address(USDC),
                    tokenOut:          address(WETH),
                    fee:               FEE_LST,             // 0.05% — USDC/WETH (deep)
                    recipient:         address(this),
                    amountIn:          cbEthAlloc,
                    amountOutMinimum:  minWethOut,
                    sqrtPriceLimitX96: 0
                })
            );
            if (wethOut == 0) revert ZeroOutput();

            // Leakage check on USDC consumption (defense-in-depth).
            uint256 usdcAfterWethSwap = USDC.balanceOf(address(this));
            if ((usdcBeforeWethSwap - usdcAfterWethSwap) != cbEthAlloc) {
                revert LeakageDetected();
            }

            // Reset USDC approval on V3 router — defense-in-depth.
            USDC.forceApprove(address(ROUTER), 0);

            // Sub-leg 2: WETH → cbETH (Aerodrome Slipstream, tickSpacing=1)
            uint256 wethBeforeCbEthSwap = WETH.balanceOf(address(this));
            WETH.forceApprove(address(AERO_ROUTER), wethOut);

            cbEthOut = AERO_ROUTER.exactInputSingle(
                IAerodromeSlipstreamRouter.ExactInputSingleParams({
                    tokenIn:           address(WETH),
                    tokenOut:          address(CBETH),
                    tickSpacing:       CBETH_TICK_SPACING,
                    recipient:         address(this),
                    deadline:          block.timestamp,
                    amountIn:          wethOut,
                    amountOutMinimum:  minCbEthOut,
                    sqrtPriceLimitX96: 0
                })
            );
            if (cbEthOut == 0) revert ZeroOutput();

            // Leakage check on WETH consumption (defense-in-depth).
            uint256 wethAfterCbEthSwap = WETH.balanceOf(address(this));
            if ((wethBeforeCbEthSwap - wethAfterCbEthSwap) != wethOut) {
                revert LeakageDetected();
            }

            // Reset WETH approval on Aerodrome router — defense-in-depth.
            WETH.forceApprove(address(AERO_ROUTER), 0);

            emit CbEthAcquired(cbEthAlloc, wethOut, cbEthOut);
        }

        // ─── Morpho leg: USDC → Bitwise Morpho Blue vault (ERC4626 deposit) ─
        uint256 morphoShares = 0;
        if (morphoAlloc > 0) {
            // v2.4.1 — leakage check parity with cbETH leg (Plate Finding 1).
            // Capture both balances BEFORE the deposit so consumption and
            // mint can be verified independently after.
            uint256 usdcBeforeMorpho   = USDC.balanceOf(address(this));
            uint256 sharesBefore       = MORPHO_VAULT.balanceOf(address(this));

            USDC.forceApprove(address(MORPHO_VAULT), morphoAlloc);

            try MORPHO_VAULT.deposit(morphoAlloc, address(this))
                returns (uint256 /* sharesIssued */)
            {
                USDC.forceApprove(address(MORPHO_VAULT), 0);

                // v2.4.1 — USDC consumption leakage check (Plate Finding 1).
                // Symmetric defense-in-depth with the cbETH leg's leakage
                // checks. Any deviation between declared input and vault
                // consumption is severe enough to revert the whole sweep.
                uint256 usdcAfterMorpho = USDC.balanceOf(address(this));
                if ((usdcBeforeMorpho - usdcAfterMorpho) != morphoAlloc) {
                    revert LeakageDetected();
                }

                // Share-delta verification (existing).
                uint256 sharesAfter = MORPHO_VAULT.balanceOf(address(this));
                if (sharesAfter <= sharesBefore) revert MorphoDepositFailed();

                // v2.4.1 — Use verified delta, not vault's claim (Plate Finding 2).
                // Under honest vault both values match; under malicious vault
                // the verified delta is the truth. Event records truth.
                uint256 sharesActuallyMinted = sharesAfter - sharesBefore;
                morphoShares = sharesActuallyMinted;
                morphoDepositedPrincipal += morphoAlloc;

                emit MorphoDeposited(morphoAlloc, sharesActuallyMinted);
            } catch {
                USDC.forceApprove(address(MORPHO_VAULT), 0);
                revert MorphoDepositFailed();
            }
        }

        // ─── Treasury gauge update (cbETH leg only — Morpho yield is share-denominated) ──
        uint256 ethAdded = 0;
        if (cbEthOut > 0) {
            uint256 cbEthInEth = LST_RATES.cbEthToEth(cbEthOut);
            if (cbEthInEth == 0) revert ExchangeRateInvalid();
            ethAdded = cbEthInEth;
        }

        lastSweepTime = block.timestamp;
        uint256 currentEthEquivalent = _computeCurrentEthEquivalent();

        emit UCRSweptFull(usdcBalance, cbEthOut, morphoShares, ethAdded, block.timestamp);
        // v2.3 backwards-compat alias (deprecated event)
        emit UCRSwept(usdcBalance, cbEthOut, ethAdded, block.timestamp);
        emit TreasuryGaugeUpdated(currentEthEquivalent);
    }

    /**
     * @notice v2.4.2 — Convert a USDC amount (6-decimal) to ETH-wei equivalent
     *         (18-decimal) using compositional Chainlink oracle path.
     *
     *         USDC/ETH direct does not exist on Base mainnet — cast-verified
     *         2026-05-27. Composes via two USD-quoted Base mainnet feeds:
     *
     *             USDC → USD (CHAINLINK_USDC_USD, 8-decimal)
     *             USD → ETH (CHAINLINK_ETH_USD, 8-decimal, inverted)
     *
     *         Decimal math:
     *             usdcUsdE8 = "USD per USDC, scaled 1e8" (≈ 99955838 = $0.99955838)
     *             ethUsdE8  = "USD per ETH, scaled 1e8"
     *             ethAmt    = (usdcAmt * 1e12 * usdcUsdE8) / ethUsdE8 / 1e6
     *                       = usdcAmt * usdcUsdE8 * 1e6 / ethUsdE8
     *
     *         Scale check:
     *             usdcAmt    is 6-dec   = 1e6
     *             usdcUsdE8  is 8-dec   = 1e8
     *             ethUsdE8   is 8-dec   = 1e8
     *             1e6 multiplier upshifts to 18-dec for ETH-wei
     *             Numerator scale: 1e6 * 1e8 * 1e6 = 1e20
     *             Divide by ethUsdE8 (~1e8 * eth_in_usd): yields 1e20 / 1e8 = 1e12-ish
     *             …wait, this needs explicit derivation, see expanded math below.
     *
     *         Expanded derivation:
     *             1 USDC = usdcUsdE8 / 1e8 USD
     *             1 USD = 1e8 / ethUsdE8 ETH (in 18-dec terms when ethUsdE8 is USD-per-ETH)
     *             ⇒ 1 USDC = (usdcUsdE8 / 1e8) * (1e8 / ethUsdE8) ETH = usdcUsdE8 / ethUsdE8 ETH
     *             For x USDC (6-dec wei): x_in_eth_wei = (x_usdc * 1e12 * usdcUsdE8) / ethUsdE8
     *             1e12 multiplier converts USDC 6-dec to ETH 18-dec while the price ratio
     *             (usdcUsdE8 / ethUsdE8) carries the value.
     *
     *         Compositional staleness: returns 0 if EITHER feed is stale/reverting/invalid.
     *         Caller (gauge) treats 0 as "Morpho leg invisible this read" — same
     *         downgrade pattern as cbETH leg when LST_RATES fails.
     */
    function _usdcToEth(uint256 usdcAmt) internal view returns (uint256 ethAmt) {
        if (usdcAmt == 0) return 0;

        // ── USDC/USD freshness check
        int256 usdcUsdE8;
        try CHAINLINK_USDC_USD.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answeredInRound < roundId)                  return 0;
            if (updatedAt == 0)                             return 0;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE) return 0;
            if (answer <= 0)                                return 0;
            usdcUsdE8 = answer;
        } catch {
            return 0;
        }

        // ── ETH/USD freshness check
        int256 ethUsdE8;
        try CHAINLINK_ETH_USD.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answeredInRound < roundId)                  return 0;
            if (updatedAt == 0)                             return 0;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp - updatedAt > ORACLE_STALE) return 0;
            if (answer <= 0)                                return 0;
            ethUsdE8 = answer;
        } catch {
            return 0;
        }

        // ── Composed conversion (decimal math fully derived in NatSpec above)
        // Numerator pre-divides safely: usdcAmt × 1e12 × usdcUsdE8 fits comfortably
        // in uint256 (1e6 × 1e12 × 1e8 = 1e26, well below 2^256 ~ 1.16e77).
        // forge-lint: disable-next-line(unsafe-typecast)
        ethAmt = (usdcAmt * 1e12 * uint256(usdcUsdE8)) / uint256(ethUsdE8);
    }

    /**
     * @notice Compute current ETH-equivalent of treasury holdings across both legs
     *         of the dual-acquisition architecture.
     *
     *         v2.4.2 — Extended from cbETH-leg-only to dual-leg aggregation:
     *             cbETH leg:  CBETH.balanceOf(this) → LST_RATES.cbEthToEth → ETH-wei
     *             Morpho leg: MORPHO_VAULT.balanceOf(this) → convertToAssets → USDC →
     *                         _usdcToEth (Chainlink compositional path) → ETH-wei
     *
     *         Returns sum of both legs at CURRENT exchange rates, not historical
     *         deposit totals. Drops if cbETH rate falls or USDC depegs; rises if
     *         Morpho yield accrues or cbETH rate climbs.
     *
     *         Compositional staleness:
     *           - If LST_RATES reverts: cbETH leg reports 0, Morpho leg may still report.
     *           - If MORPHO_VAULT.convertToAssets reverts: Morpho leg reports 0,
     *             cbETH leg still reports.
     *           - If EITHER Chainlink USDC/USD or ETH/USD is stale: Morpho leg
     *             reports 0 (via _usdcToEth's compositional staleness floor).
     *         Each leg's failure cleanly downgrades; the gauge never reports a
     *         stale composite value. Console operators read 0 on a leg as
     *         "leg-value unknown this block" not "leg-value is literally zero."
     */
    function _computeCurrentEthEquivalent() internal view returns (uint256) {
        // ── cbETH leg (v2.4 baseline, defensively wrapped in v2.4.2)
        uint256 cbEthInEth;
        uint256 cbBal = CBETH.balanceOf(address(this));
        if (cbBal > 0) {
            try LST_RATES.cbEthToEth(cbBal) returns (uint256 v) {
                cbEthInEth = v;
            } catch {
                cbEthInEth = 0;
            }
        }

        // ── Morpho leg (v2.4.2 addition)
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
    //                          CIRCUIT BREAKER
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause sweep mechanism. Callable by OWNER or OPERATOR.
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
     *         Set to 0 to opt out of DAI reserve (sweeps will route 100% to cbETH).
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
        // LIMIT_DELAY is 24 hours; validator's ~12s manipulation window is immaterial against 86,400s.
        // forge-lint: disable-next-line(block-timestamp)
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
        // WINDOW_SIZE is 24 hours; validator's ~12s manipulation window is immaterial against 86,400s.
        // forge-lint: disable-next-line(block-timestamp)
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
     *         new infrastructure, or wants cbETH in their own wallet for
     *         direct treasury management or bridging to Ethereum L1.
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
     *         Other tokens (cbETH) are not subject to the daily limit on the
     *         emergency path (7-day timelock is their full protection).
     */
    function executeEmergencyWithdraw(address token, address to)
        external onlyRole(OWNER_ROLE) nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();

        EmergencyWithdraw memory q = emergencyQueue[token];
        if (q.executeAfter == 0)              revert NothingQueued();
        // EMERGENCY_DELAY is 7 days; validator's ~12s manipulation window is immaterial against 604,800s.
        // forge-lint: disable-next-line(block-timestamp)
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
     *         pattern): roundId completeness, updatedAt positive, age within
     *         heartbeat-appropriate window, answer positive.
     *
     *         Staleness window: ORACLE_STALE_CBETH = 90,000s (25h) — accommodates
     *         Chainlink's 24-hour heartbeat cadence for the cbETH/ETH 18-decimal
     *         exchange-rate feed. Legacy 3600s window would reject valid feed
     *         data during low-volatility periods.
     */
    function _validateOracle() internal view {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = CHAINLINK.latestRoundData();

        if (answeredInRound < roundId)                       revert OracleStale();
        if (updatedAt == 0)                                  revert OracleStale();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > ORACLE_STALE_CBETH) revert OracleStale();
        if (answer <= 0)                                     revert OracleInvalid();
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
            // Oracle staleness check at 3600s ORACLE_STALE; validator's ~12s manipulation window is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
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
     * @notice Treasury Gauge — ETH-equivalent of all treasury holdings at current
     *         exchange rates. v2.4.2: now includes BOTH cbETH leg AND Morpho USDC leg.
     *
     *         Reflects actual capital across the dual-acquisition architecture,
     *         not historical deposit total. Drops if cbETH rate falls or USDC
     *         depegs against ETH; rises if Morpho yield accrues or cbETH rate climbs.
     *
     *         Compositional staleness: see _computeCurrentEthEquivalent NatSpec
     *         for the per-leg downgrade semantics. A "0" return when treasury is
     *         non-empty indicates oracle path failure on every leg this block,
     *         not literal-zero treasury value.
     */
    function getTreasuryGauge() external view returns (uint256) {
        return _computeCurrentEthEquivalent();
    }

    function getUSDCBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function getDAIBalance() external view returns (uint256) {
        return DAI.balanceOf(address(this));
    }

    function getCbETHBalance() external view returns (uint256) {
        return CBETH.balanceOf(address(this));
    }

    /**
     * @notice v2.4.2 — Current Morpho leg position: shares held and their current
     *         USDC redemption value. Closes read-surface gap noted by Code Integrity
     *         routing 2026-05-27: every other token holding (USDC, DAI, cbETH) has
     *         a single-call getter; Morpho leg previously required three RPC calls.
     *
     *         Note on monotonic value growth between reads:
     *         The Bitwise Morpho Blue USDC vault accrues yield continuously. Reading
     *         this function repeatedly while `shares` stays constant will show
     *         `currentUSDCValue` increasing — that's the dual-acquisition design
     *         working correctly, not a bug. Consoles displaying the value should
     *         expect this and avoid false-positive "stale value" warnings.
     *
     *         Defensive try/catch around convertToAssets (matches L1Anchor's
     *         morphoUsdcValue pattern). If vault paused or reverting,
     *         currentUSDCValue returns 0 while shares still reflects holdings —
     *         caller can cross-reference `shares > 0 && currentUSDCValue == 0`
     *         as a "vault state unclear" signal.
     */
    function getMorphoBalance()
        external
        view
        returns (uint256 shares, uint256 currentUSDCValue)
    {
        shares = MORPHO_VAULT.balanceOf(address(this));
        if (shares == 0) return (0, 0);
        try MORPHO_VAULT.convertToAssets(shares) returns (uint256 v) {
            currentUSDCValue = v;
        } catch {
            currentUSDCValue = 0;
        }
    }

    /**
     * @notice How much DAI remains withdrawable in the current 24h window.
     *         If window has rolled over, returns full dailyLimit.
     */
    function dailyRemaining() external view returns (uint256) {
        // WINDOW_SIZE is 24 hours; validator's ~12s manipulation window is immaterial against 86,400s.
        // forge-lint: disable-next-line(block-timestamp)
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

    function nextSweepAllowed() external view returns (uint256) {
        return lastSweepTime + SWEEP_DELAY;
    }

    /// @notice Secure-Context-Handshake state, exposed for invariant testing.
    ///         MUST read 0 between transactions — a non-zero value outside an
    ///         active sweep execution indicates a revert path left the secret
    ///         armed. invariant_HandshakeAlwaysConsumed asserts this.
    function activeExecutionSecret() external view returns (uint256) {
        return _activeExecutionSecret;
    }

    function isEmergencyQueued(address token) external view returns (bool) {
        return emergencyQueue[token].executeAfter != 0;
    }

    function emergencyReady(address token) external view returns (bool) {
        uint256 eAfter = emergencyQueue[token].executeAfter;
        // Comparison against 7-day EMERGENCY_DELAY queue time; validator's ~12s manipulation window is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        return eAfter != 0 && block.timestamp >= eAfter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          CHAINLINK AUTOMATION (council-ratified 2026-05-12, Phase 3)
    //
    //  Schedules the already-authorized sweep() function when its canonical
    //  guards permit, with a hysteresis buffer on minSwapBatch.
    //
    //  Single-task upkeep. Automation gains NO new authorities. Every action
    //  it performs is one that any OWNER or OPERATOR could perform once
    //  guards are satisfied. Determinism preserved.
    //
    //  Council IV.1 (sweep portion), IV.3, IV.4, IV.7 (Position A), IV.8,
    //  IV.9 integrated.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Chainlink calls this off-chain (view).
     *         Returns whether sweep() should run.
     *
     *         Hysteresis (IV.4): USDC balance must exceed minSwapBatch × 120%
     *         before upkeep triggers. The sweep function itself accepts the
     *         canonical threshold; the buffer applies only to Automation.
     *
     *         AUTO-INV-1: All guards checked here mirror or strictly tighten
     *         the guards inside sweep().
     *
     *         performData carries the operator's minDaiOut, minWethOut, and
     *         minCbEthOut slippage guards as ABI-encoded (uint256, uint256,
     *         uint256). These are passed through to sweep(). The values are
     *         set by the operator via setSweepSlippageGuards() — see below.
     *         minWethOut was added in v2.3 for the multi-hop USDC→WETH→cbETH
     *         path; each leg has its own slippage guard.
     */
    function checkUpkeep(bytes calldata /*checkData*/)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (upkeepPaused) return (false, "");
        if (routingPaused) return (false, "");

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < lastSweepTime + SWEEP_DELAY) return (false, "");

        uint256 hysteresisThreshold = (minSwapBatch * UPKEEP_HYSTERESIS_BPS) / 100;
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance < hysteresisThreshold) return (false, "");

        return (true, abi.encode(
            sweepSlippageMinDai,
            sweepSlippageMinWeth,
            sweepSlippageMinCbEth
        ));
    }

    /**
     * @notice Chainlink's Automation Forwarder calls this on-chain.
     *
     *         IV.3: only the forwarder may call (onlyForwarder modifier).
     *         IV.9: replay-protected via executedUpkeeps mapping (defense-in-depth).
     *         nonReentrant: belt-and-suspenders.
     *
     *         Replay key keyed on lastSweepTime — once sweep() runs, lastSweepTime
     *         updates, so any retry would compute a different replay key, but
     *         sweep() would also revert with SweepTooEarly via its own 24h delay.
     *         The replay map is defense-in-depth.
     */
    function performUpkeep(bytes calldata performData)
        external
        override
        onlyForwarder
        nonReentrant
    {
        if (upkeepPaused) revert UpkeepIsPaused();

        (
            uint256 minDaiOut,
            uint256 minWethOut,
            uint256 minCbEthOut
        ) = abi.decode(performData, (uint256, uint256, uint256));

        bytes32 replayKey = keccak256(abi.encode("sweep", lastSweepTime));
        if (executedUpkeeps[replayKey]) revert UpkeepAlreadyExecuted();
        executedUpkeeps[replayKey] = true;

        uint256 gasBefore = gasleft();
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));

        // ─── v2.4 X-LINK gas-griefing fix (Grok finding 2026-05-23) ─────
        // Secure-Context-Handshake: mint a monotonic one-time secret and arm
        // it. onlyForwarder + nonReentrant remain this path's authorization
        // and reentrancy guards. v2.4 wraps the call so a failed _sweep
        // doesn't leave the secret armed for the next upkeep cycle.
        uint256 secret = ++_executionNonce;
        _activeExecutionSecret = secret;

        try this._sweepDispatch(minDaiOut, minWethOut, minCbEthOut, secret) {
            // success
        } catch (bytes memory reason) {
            _activeExecutionSecret = 0;
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }

        uint256 usdcBalanceAfter = USDC.balanceOf(address(this));
        uint256 valueMoved = usdcBalanceBefore > usdcBalanceAfter
            ? usdcBalanceBefore - usdcBalanceAfter : 0;

        emit UpkeepPerformed(gasBefore - gasleft(), valueMoved);
        unchecked { executedUpkeepCount += 1; }
    }

    /// @notice IV.4 — slippage guards passed to sweep() via Chainlink performData.
    ///         Operator-set; updates without timelock since values are protective
    ///         (too-tight = sweep reverts; too-loose = bad price). OWNER_ROLE only.
    ///         v2.3 — minWeth added for the USDC→WETH leg of the multi-hop path.
    uint256 public sweepSlippageMinDai;
    uint256 public sweepSlippageMinWeth;
    uint256 public sweepSlippageMinCbEth;

    function setSweepSlippageGuards(
        uint256 minDai,
        uint256 minWeth,
        uint256 minCbEth
    )
        external
        onlyRole(OWNER_ROLE)
    {
        sweepSlippageMinDai = minDai;
        sweepSlippageMinWeth = minWeth;
        sweepSlippageMinCbEth = minCbEth;
    }

    /// @notice v2.4 — Owner-controlled adjustment of the 50/50 split ratio.
    ///         Bounded to [1000, 9000] basis points (10%–90%) so neither leg
    ///         can be fully zeroed without an explicit contract amendment.
    ///         Merchants who want full single-leg routing should redeploy or
    ///         contact protocol for an amended contract.
    function setCbEthBps(uint16 newBps) external onlyRole(OWNER_ROLE) {
        if (newBps < 1000 || newBps > 9000) revert InvalidBpsRange();
        uint16 oldBps = cbEthBps;
        cbEthBps = newBps;
        emit CbEthBpsUpdated(oldBps, newBps, block.timestamp);
    }

    /**
     * @notice Initial forwarder registration. One-time path callable by OWNER_ROLE.
     */
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

    /// @notice IV.8 Step 1 — queue forwarder update via 48h timelock.
    function queueForwarderUpdate(address newForwarder)
        external
        onlyRole(OWNER_ROLE)
        returns (bytes32 id)
    {
        if (newForwarder == address(0)) revert InvalidAddress();
        _pendingForwarder = newForwarder;
        id = keccak256(abi.encodePacked("forwarderUpdate", block.timestamp, newForwarder));
        timelockQueue[id] = block.timestamp + TIMELOCK;
        emit ForwarderUpdateQueued(id, newForwarder, timelockQueue[id]);
    }

    /// @notice IV.8 Step 2 — execute forwarder update after 48h elapsed.
    function executeForwarderUpdate(bytes32 id)
        external
        onlyRole(OWNER_ROLE)
        tlPassed(id)
    {
        address newForwarder = _pendingForwarder;
        if (newForwarder == address(0)) revert InvalidAddress();
        address old = automationForwarder;
        automationForwarder = newForwarder;
        _pendingForwarder = address(0);
        emit ForwarderUpdated(old, newForwarder, block.timestamp);
    }

    /// @notice IV.7 — upkeep pause (Position A: OWNER_ROLE for Payments).
    function pauseUpkeep() external onlyRole(OWNER_ROLE) {
        upkeepPaused = true;
        emit UpkeepPausedSet(true, block.timestamp);
    }

    function unpauseUpkeep() external onlyRole(OWNER_ROLE) {
        upkeepPaused = false;
        emit UpkeepPausedSet(false, block.timestamp);
    }

}
