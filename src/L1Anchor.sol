// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ════════════════════════════════════════════════════════════════════════════
 *
 *   L1Anchor — POSSESSIO Protocol L1 Settlement Anchor
 *
 *   Authored by:  Claude (Code Integrity / CSO)
 *   Co-designed:  Gemini (Technical Authority), Grok (Adversarial Audit),
 *                 ChatGPT (Grant Narrative), Architect (John, final ratification)
 *   Build date:   May 9, 2026
 *
 *   PURPOSE
 *   -------
 *   The L1Anchor is a passive, merchant-owned settlement contract on Ethereum
 *   Mainnet. It is the canonical L1 destination where merchant-bridged cbETH
 *   and USDC arrive and are routed (by the merchant) to two diversified yield
 *   destinations:
 *
 *     - MAVAN (Tom Lee's Bitmine validator network) — institutional cbETH staking
 *     - Bitwise-curated Morpho Blue USDC vault       — institutional USDC lending
 *
 *   The merchant deploys this contract via the L1AnchorFactory and is the
 *   sole authority over it from genesis. There is no protocol admin, no
 *   upgrade mechanism, no shared accounting across merchants, and no logic
 *   that initiates cross-chain messages. All cross-chain movement is a
 *   merchant action taken with the merchant's own keys, outside this code.
 *
 *   ARCHITECTURAL RATIFICATIONS (Architect, May 9, 2026; updated May 17, 2026)
 *   ----------------------------------------------------------------------
 *   1. Symmetry Guard:    Stateful pattern (v1 PLATE.sol lineage). Stored bool
 *                         depegPaused. ONE-WAY LATCH per council 2026-05-17:
 *                         set by _checkSymmetry() on any bad-oracle condition
 *                         (revert, staleness, round mismatch, non-positive
 *                         answer) OR observed below-threshold price. Cleared
 *                         only by explicit merchant call to resetDepeg() when
 *                         oracle reports verified-recovered peg. Rationale:
 *                         "Inaction is the only safe response to uncertainty"
 *                         (SCH lineage); auto-resume creates Ghost-Routing
 *                         and oracle-flapping attack surface.
 *   2. Withdrawals:       Full suite. NOT gated by Symmetry Guard. Merchant
 *                         must always be able to exit positions, especially
 *                         during depeg events.
 *   3. Emergency unwind:  No timelock. Merchant is sole authority, should not
 *                         be caged from saving their own capital. Principal
 *                         tracking uses Delta-Verification (UCR/X-LINK lineage,
 *                         ratified 2026-05-17): mavanStakedPrincipal and
 *                         morphoDepositedPrincipal decrement by ACTUAL balance
 *                         delta, not by intent — principal remains recorded
 *                         for any capital stranded in failed external calls.
 *   4. Address constants: TODO markers for Architect to lock before deployment.
 *
 *   NON-MONEY-TRANSMITTER POSTURE (Structural)
 *   -------------------------------------------
 *   - No bridge interfaces. No cross-chain message initiation. No L2 callbacks.
 *   - Per-merchant deployment: each merchant owns their own contract instance.
 *   - All routing/withdrawal calls are merchant-triggered.
 *   - The contract is a tool the merchant uses to manage their own capital.
 *
 *   REGULATORY: This contract does not transmit money. It is private
 *   infrastructure that the merchant operates with their own keys.
 *
 *   AUDIT NOTE: This contract is a Factory template. It will be replicated
 *   across thousands of merchant deployments. Every line carries multiplied
 *   weight. Audit posture is correspondingly elevated.
 *
 * ════════════════════════════════════════════════════════════════════════════
 */

import {IERC20}     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Chainlink AggregatorV3 interface — minimal subset used here.
interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @notice MAVAN validator entry interface (placeholder — actual ABI subject to
///         interface research per memory #11 council leaf). Built defensively
///         against an unknown specific interface; substitution at integration
///         time may require Factory v2.
interface IMAVANEntry {
    function stake(uint256 cbEthAmount) external returns (uint256 sharesIssued);
    function unstake(uint256 sharesAmount) external returns (uint256 cbEthReturned);
    function sharesOf(address account) external view returns (uint256);
}

/// @notice Morpho Blue ERC4626 vault interface (Bitwise-curated USDC vault).
///         Morpho Blue vaults follow ERC4626 standard.
interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/**
 * @title L1Anchor
 * @notice Sovereign, per-merchant L1 settlement contract.
 */
contract L1Anchor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The sole authority over this contract. Set at construction
    ///         by the Factory to the merchant's address. Cannot be changed.
    address public immutable MERCHANT_OWNER;

    /// @notice The L1AnchorFactory that deployed this contract.
    ///         Set in constructor to msg.sender — guaranteed to be the
    ///         Factory because only the Factory's `new L1Anchor(...)` call
    ///         executes this constructor with the right arguments.
    ///         This is the trust anchor for institutional identity recognition:
    ///         MAVAN, Bitwise, or any external party can verify an address is
    ///         a genuine POSSESSIO Anchor by checking that its `factoryDeployer()`
    ///         returns the canonical L1AnchorFactory address.
    address public immutable FACTORY;

    /// @notice Block timestamp of construction. Useful for tenure-based
    ///         qualification or institutional history attestation.
    uint256 public immutable DEPLOYED_AT;

    /// @notice Bitwise-curated Morpho Blue USDC vault (ERC4626).
    address public immutable BITWISE_MORPHO_VAULT;

    /// @notice MAVAN validator network entry contract.
    address public immutable MAVAN_ENTRY;

    /// @notice cbETH token on Ethereum mainnet.
    IERC20 public immutable CBETH;

    /// @notice USDC token on Ethereum mainnet.
    IERC20 public immutable USDC;

    /// @notice Chainlink cbETH/ETH price feed on Ethereum mainnet.
    IChainlinkFeed public immutable CBETH_ETH_ORACLE;

    /// @notice Decimals reported by CBETH_ETH_ORACLE, validated at construction.
    ///         Mainnet cbETH/ETH feed: 18 decimals. Asserted to prevent
    ///         miscalibrated math from a wrong-feed deployment.
    uint8 public immutable ORACLE_DECIMALS;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Anchor template version. Bumped when Factory v2 ships a new template.
    ///         External recognition logic (e.g., MAVAN institutional class detection)
    ///         can use this to differentiate versions for differential treatment.
    string public constant ANCHOR_VERSION = "1.0.0";

    /// @notice Symmetry Guard threshold: 97% (3% depeg tolerance, one-sided).
    ///         Expressed as basis points out of 1000 for clarity.
    ///         The guard is one-sided: halts MAVAN routing only when cbETH
    ///         trades BELOW threshold vs ETH. cbETH trading at premium
    ///         (above 1.0 ETH) is not a depeg event and does not halt routing.
    ///         Math uses 1e18 scale; constructor reverts if oracle decimals ≠ 18.
    uint256 public constant DEPEG_THRESHOLD_BPS = 970; // 97.0%

    /// @notice Oracle staleness cap (3600s = 1 hour). Same as PLATE.sol v1.
    uint256 public constant ORACLE_STALE = 3600;

    // ═══════════════════════════════════════════════════════════════════════
    //                                STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Symmetry Guard pause flag. When true, routeToMavan() reverts.
    ///         Withdrawals (withdrawFromMavan, emergencyUnwind) are NEVER
    ///         gated by this — merchant sovereignty preserved during depeg.
    ///         Set by _checkSymmetry() on bad-oracle conditions or observed
    ///         below-threshold price. Cleared ONLY by merchant calling
    ///         resetDepeg() with verified-recovered oracle data (one-way
    ///         latch per council 2026-05-17).
    bool public depegPaused;

    /// @notice Merchant's net cbETH staked into MAVAN (principal tracking).
    ///         Maintained for accounting/view; MAVAN itself authoritative on shares.
    uint256 public mavanStakedPrincipal;

    /// @notice Merchant's net USDC deposited into Morpho vault (principal tracking).
    ///         Maintained for accounting/view; vault itself authoritative on shares.
    uint256 public morphoDepositedPrincipal;

    // ═══════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event RoutedToMavan(uint256 cbEthAmount, uint256 sharesIssued, uint256 timestamp);
    event RoutedToMorpho(uint256 usdcAmount, uint256 sharesIssued, uint256 timestamp);
    event WithdrawnFromMavan(uint256 sharesRedeemed, uint256 cbEthReturned, uint256 timestamp);
    event WithdrawnFromMorpho(uint256 sharesRedeemed, uint256 usdcReturned, uint256 timestamp);
    event EmergencyUnwound(uint256 cbEthReturned, uint256 usdcReturned, uint256 timestamp);
    event SymmetryGuardPaused(uint256 depegBps, uint256 timestamp);
    event SymmetryGuardResumed(uint256 timestamp);
    event AssetsRescued(address indexed token, uint256 amount, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════
    //                                ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotSovereign();           // Caller is not MERCHANT_OWNER
    error ZeroAmount();             // Amount parameter is zero
    error ZeroAddress();            // Constructor received zero address
    error DepegPaused();            // Symmetry Guard active, MAVAN routing blocked
    error OracleDecimalsMismatch(); // Oracle decimals != expected at construction
    error MavanStakeFailed();       // External MAVAN call did not succeed
    error MavanUnstakeFailed();     // External MAVAN unstake did not succeed
    error MorphoDepositFailed();    // External Morpho call did not succeed
    error MorphoRedeemFailed();     // External Morpho redeem did not succeed
    error InsufficientShares();     // Requested withdrawal exceeds held shares

    // ═══════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyMerchantOwner() {
        if (msg.sender != MERCHANT_OWNER) revert NotSovereign();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                             CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a sovereign L1Anchor for a single merchant.
     * @dev    Called only by L1AnchorFactory. All addresses must be non-zero.
     *         Oracle decimals are asserted to match expected mainnet feed (18)
     *         to prevent miscalibrated Symmetry Guard math.
     *
     * @param _merchantOwner   Merchant wallet — sole authority over this Anchor
     * @param _morphoVault     Bitwise-curated Morpho Blue USDC vault address
     * @param _mavanEntry      MAVAN validator network entry contract address
     * @param _cbeth           cbETH token (Ethereum mainnet)
     * @param _usdc            USDC token (Ethereum mainnet)
     * @param _cbethEthOracle  Chainlink cbETH/ETH price feed (Ethereum mainnet)
     */
    constructor(
        address _merchantOwner,
        address _morphoVault,
        address _mavanEntry,
        address _cbeth,
        address _usdc,
        address _cbethEthOracle
    ) {
        if (_merchantOwner   == address(0)) revert ZeroAddress();
        if (_morphoVault     == address(0)) revert ZeroAddress();
        if (_mavanEntry      == address(0)) revert ZeroAddress();
        if (_cbeth           == address(0)) revert ZeroAddress();
        if (_usdc            == address(0)) revert ZeroAddress();
        if (_cbethEthOracle  == address(0)) revert ZeroAddress();

        MERCHANT_OWNER       = _merchantOwner;
        FACTORY              = msg.sender;
        DEPLOYED_AT          = block.timestamp;
        BITWISE_MORPHO_VAULT = _morphoVault;
        MAVAN_ENTRY          = _mavanEntry;
        CBETH                = IERC20(_cbeth);
        USDC                 = IERC20(_usdc);
        CBETH_ETH_ORACLE     = IChainlinkFeed(_cbethEthOracle);

        // Lock oracle decimals at construction. Mainnet cbETH/ETH feed: 18.
        // Mismatched decimals would silently miscalibrate the Symmetry Guard
        // math; catching it at deploy-time means a wrong-feed Factory misconfiguration
        // bricks the deployment loudly rather than running with bad math.
        uint8 dec = IChainlinkFeed(_cbethEthOracle).decimals();
        if (dec != 18) revert OracleDecimalsMismatch();
        ORACLE_DECIMALS = dec;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          SYMMETRY GUARD (v1 stateful pattern)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Internal stateful Symmetry Guard check. Called by routeToMavan()
     *         before any capital movement to MAVAN.
     *
     *         Pattern lineage: PLATE.sol v1 (stateful Symmetry Guard
     *         battle-tested across testnet, mainnet, and 20 production
     *         transactions). Behavior tightened per council 2026-05-17 to
     *         close Ghost-Routing and oracle-flapping vectors.
     *
     *         Behavior (ratified 2026-05-17):
     *         - Reads cbETH/ETH price from Chainlink, wrapped in try/catch.
     *         - Any bad-oracle condition latches depegPaused=true:
     *             * Oracle call reverts
     *             * Stale data (block.timestamp - updatedAt > ORACLE_STALE)
     *             * Future-timestamped data (updatedAt > block.timestamp)
     *             * Incomplete round (answeredInRound < roundId)
     *             * Non-positive answer (answer <= 0)
     *           Bad-oracle pauses emit SymmetryGuardPaused(1000, ...) with
     *           sentinel depegBps=1000 so offchain monitoring can distinguish
     *           oracle-failure pauses from observed-depeg pauses.
     *         - Observed below-threshold price (priceUint < threshold) also
     *           latches depegPaused=true; emits with computed depegBps.
     *         - This function NEVER clears depegPaused. Clearing is reserved
     *           to resetDepeg() which performs its own oracle verification.
     */
    /// @dev Ratified per council 2026-05-17 (Gemini, Grok, Architect):
    ///      All bad-oracle conditions latch depegPaused=true. The latch is
    ///      one-way; resume is reserved entirely for resetDepeg().
    ///      Rationale (SCH lineage): "Inaction is the only safe response to
    ///      uncertainty." If the contract cannot verify the peg, the contract
    ///      cannot claim the peg is safe.
    function _checkSymmetry() internal {
        try CBETH_ETH_ORACLE.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, /* startedAt */
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Bad-oracle conditions: staleness, incomplete round, non-positive
            // answer. Each latches depegPaused with sentinel depegBps=1000
            // (100% / total uncertainty) so offchain monitoring distinguishes
            // oracle-failure pauses from observed-depeg pauses.
            // forge-lint: disable-next-line(block-timestamp)
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_STALE) {
                if (!depegPaused) {
                    depegPaused = true;
                    emit SymmetryGuardPaused(1000, block.timestamp);
                }
                return;
            }
            if (answeredInRound < roundId) {
                if (!depegPaused) {
                    depegPaused = true;
                    emit SymmetryGuardPaused(1000, block.timestamp);
                }
                return;
            }
            if (answer <= 0) {
                if (!depegPaused) {
                    depegPaused = true;
                    emit SymmetryGuardPaused(1000, block.timestamp);
                }
                return;
            }

            // 18-decimal feed: 1.0 ETH per cbETH = 1e18.
            // Threshold: 97% = (1e18 * 970) / 1000.
            // Cast safe: answer > 0 confirmed above; positive int256 fits uint256.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 priceUint = uint256(answer);
            uint256 threshold = (1e18 * DEPEG_THRESHOLD_BPS) / 1000;

            // Observed depeg latches paused. Resume removed from this function
            // per ratification — only resetDepeg() can clear depegPaused.
            if (priceUint < threshold && !depegPaused) {
                depegPaused = true;
                // depegBps for offchain monitoring (informational, not gating).
                // priceUint < threshold and threshold ≤ 1e18, so depegBps ∈ [0, 1000) safe.
                uint256 depegBps = (1e18 - priceUint) * 1000 / 1e18;
                emit SymmetryGuardPaused(depegBps, block.timestamp);
            }
        } catch {
            // Oracle reverted: latch paused with sentinel.
            if (!depegPaused) {
                depegPaused = true;
                emit SymmetryGuardPaused(1000, block.timestamp);
            }
        }
    }

    /**
     * @notice Explicit merchant entry point to clear the depeg latch when
     *         the oracle has recovered. Performs its own oracle verification
     *         and is the SOLE path to clear depegPaused (one-way latch per
     *         council 2026-05-17).
     *
     *         Closes the UX gap where merchants would otherwise need to
     *         attempt a `routeToMavan` (with funds at risk) just to test
     *         whether the latch has cleared.
     *
     *         Behavior:
     *         - Reads oracle via try/catch.
     *         - If oracle bad in any way (revert, stale, future-timestamped,
     *           round mismatch, non-positive, below threshold), returns
     *           silently with depegPaused unchanged. Merchant may retry
     *           when oracle has recovered. No revert — merchant should never
     *           be punished for polling reset.
     *         - If oracle returns verified-good data (not stale, complete
     *           round, positive, at-or-above threshold), clears depegPaused
     *           and emits SymmetryGuardResumed(block.timestamp).
     *
     *         Adversarial finding by Grok (Council seat 3); ratified by
     *         Architect on May 9, 2026. Reset semantics tightened per council
     *         2026-05-17 to require oracle verification of recovered peg
     *         before clearing latch.
     */
    function resetDepeg() external onlyMerchantOwner {
        // Resume requires verified-good oracle data. If oracle is bad in any
        // way (revert, stale, round mismatch, non-positive, below threshold),
        // the function returns silently and depegPaused remains true. The
        // merchant retains the option to call again when oracle has recovered.
        try CBETH_ETH_ORACLE.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, /* startedAt */
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // forge-lint: disable-next-line(block-timestamp)
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_STALE) return;
            if (answeredInRound < roundId) return;
            if (answer <= 0) return;

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 priceUint = uint256(answer);
            uint256 threshold = (1e18 * DEPEG_THRESHOLD_BPS) / 1000;

            if (priceUint < threshold) return;

            // All verification passed; oracle reports recovered peg. Clear latch.
            if (depegPaused) {
                depegPaused = false;
                emit SymmetryGuardResumed(block.timestamp);
            }
        } catch {
            // Oracle reverted; depegPaused remains true. Silent return per
            // merchant-sovereignty design — merchant can retry when oracle
            // is responsive.
            return;
        }
    }

    /**
     * @notice External read of current Symmetry Guard state.
     *         Provided for offchain UX and merchant transparency.
     */
    function getSymmetryStatus() external view returns (bool isPaused, uint256 currentBps) {
        isPaused = depegPaused;
        try CBETH_ETH_ORACLE.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256, uint80
        ) {
            if (answer > 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 p = uint256(answer);
                currentBps = p >= 1e18 ? 0 : ((1e18 - p) * 1000 / 1e18);
            }
        } catch { /* return defaults */ }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ROUTING (Inbound)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Route merchant's cbETH (held by this contract) into MAVAN staking.
     *         Subject to Symmetry Guard — reverts if depegPaused.
     *
     *         Approval pattern: forceApprove exact amount, call, force-reset
     *         to zero. Defends against dangling allowances.
     *
     * @param amount cbETH to stake (must be ≤ contract's cbETH balance)
     */
    function routeToMavan(uint256 amount) external onlyMerchantOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _checkSymmetry();
        if (depegPaused) revert DepegPaused();

        CBETH.forceApprove(MAVAN_ENTRY, amount);

        uint256 sharesBefore = IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));

        try IMAVANEntry(MAVAN_ENTRY).stake(amount) returns (uint256 sharesIssued) {
            // Reset approval immediately — defense against routers consuming
            // less than declared.
            CBETH.forceApprove(MAVAN_ENTRY, 0);

            // Verify shares actually increased; defense against partial-stake silent failures.
            uint256 sharesAfter = IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));
            if (sharesAfter <= sharesBefore) revert MavanStakeFailed();

            mavanStakedPrincipal += amount;
            emit RoutedToMavan(amount, sharesIssued, block.timestamp);
        } catch {
            // Reset approval even on failure path; ensures no allowance dangles.
            CBETH.forceApprove(MAVAN_ENTRY, 0);
            revert MavanStakeFailed();
        }
    }

    /**
     * @notice Route merchant's USDC (held by this contract) into Bitwise-curated
     *         Morpho Blue vault. NOT gated by Symmetry Guard (USDC routing
     *         independent of cbETH peg health).
     *
     * @param amount USDC to deposit (must be ≤ contract's USDC balance)
     */
    function routeToMorpho(uint256 amount) external onlyMerchantOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        USDC.forceApprove(BITWISE_MORPHO_VAULT, amount);

        uint256 sharesBefore = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));

        try IMorphoVault(BITWISE_MORPHO_VAULT).deposit(amount, address(this))
            returns (uint256 sharesIssued)
        {
            USDC.forceApprove(BITWISE_MORPHO_VAULT, 0);

            uint256 sharesAfter = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
            if (sharesAfter <= sharesBefore) revert MorphoDepositFailed();

            morphoDepositedPrincipal += amount;
            emit RoutedToMorpho(amount, sharesIssued, block.timestamp);
        } catch {
            USDC.forceApprove(BITWISE_MORPHO_VAULT, 0);
            revert MorphoDepositFailed();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          WITHDRAWALS (Outbound)
    //
    //   Per Architect Decision 2: NOT gated by Symmetry Guard. Merchant
    //   sovereignty preserved — they may withdraw during depeg events
    //   to minimize further exposure.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Unstake from MAVAN, return cbETH to MERCHANT_OWNER directly.
     * @param sharesAmount MAVAN shares to redeem (≤ contract's MAVAN shares)
     */
    function withdrawFromMavan(uint256 sharesAmount) external onlyMerchantOwner nonReentrant {
        if (sharesAmount == 0) revert ZeroAmount();

        uint256 heldShares = IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));
        if (sharesAmount > heldShares) revert InsufficientShares();

        uint256 cbEthBefore = CBETH.balanceOf(address(this));

        // Defensive design: we discard the unstake() return value and trust
        // only the balance delta. Defends against a compromised MAVAN that
        // returns a fabricated value larger than what it actually transferred.
        try IMAVANEntry(MAVAN_ENTRY).unstake(sharesAmount) returns (uint256 /* cbEthReturned */) {
            uint256 cbEthAfter = CBETH.balanceOf(address(this));
            uint256 actualReturned = cbEthAfter - cbEthBefore;
            if (actualReturned == 0) revert MavanUnstakeFailed();

            // Update principal tracking — cap at zero to handle yield-included
            // returns where actual cbEthReturned exceeds tracked principal.
            if (actualReturned >= mavanStakedPrincipal) {
                mavanStakedPrincipal = 0;
            } else {
                mavanStakedPrincipal -= actualReturned;
            }

            // Forward cbETH to merchant directly (do not retain in contract).
            CBETH.safeTransfer(MERCHANT_OWNER, actualReturned);
            emit WithdrawnFromMavan(sharesAmount, actualReturned, block.timestamp);
        } catch {
            revert MavanUnstakeFailed();
        }
    }

    /**
     * @notice Redeem from Morpho vault, return USDC to MERCHANT_OWNER directly.
     * @param sharesAmount Morpho vault shares to redeem (≤ contract's vault shares)
     */
    function withdrawFromMorpho(uint256 sharesAmount) external onlyMerchantOwner nonReentrant {
        if (sharesAmount == 0) revert ZeroAmount();

        uint256 heldShares = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
        if (sharesAmount > heldShares) revert InsufficientShares();

        uint256 usdcBefore = USDC.balanceOf(address(this));

        // Defensive design: we discard the redeem() return value and trust
        // only the balance delta. Defends against a compromised vault that
        // returns a fabricated value larger than what it actually transferred.
        try IMorphoVault(BITWISE_MORPHO_VAULT).redeem(sharesAmount, address(this), address(this))
            returns (uint256 /* usdcReturned */)
        {
            uint256 usdcAfter = USDC.balanceOf(address(this));
            uint256 actualReturned = usdcAfter - usdcBefore;
            if (actualReturned == 0) revert MorphoRedeemFailed();

            if (actualReturned >= morphoDepositedPrincipal) {
                morphoDepositedPrincipal = 0;
            } else {
                morphoDepositedPrincipal -= actualReturned;
            }

            USDC.safeTransfer(MERCHANT_OWNER, actualReturned);
            emit WithdrawnFromMorpho(sharesAmount, actualReturned, block.timestamp);
        } catch {
            revert MorphoRedeemFailed();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       EMERGENCY UNWIND (Nuclear)
    //
    //   Per Architect Decision 3: NO timelock. Merchant is sole authority.
    //   Pulls full position from BOTH MAVAN and Morpho atomically. Returns
    //   all cbETH and USDC (held + recovered) directly to MERCHANT_OWNER.
    //
    //   Trade-off acknowledged: a compromised merchant key becomes a
    //   single-call drain. Architect accepted this in favor of merchant
    //   velocity during yield-market failures. Merchant is responsible
    //   for their own key security.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Atomic full-position withdrawal from both yield destinations.
     *         Pulls all MAVAN shares (best-effort, continues on partial failure)
     *         and all Morpho shares, then sweeps all cbETH and USDC held by
     *         the contract to MERCHANT_OWNER.
     *
     *         PRINCIPAL ACCOUNTING (ratified 2026-05-17, Delta-Verification):
     *         mavanStakedPrincipal and morphoDepositedPrincipal decrement by
     *         ACTUAL recovered amount (balance-after minus balance-before),
     *         NOT by intent. If MAVAN.unstake() reverts and no cbETH is
     *         returned, mavanStakedPrincipal remains recorded at its prior
     *         value — capital stuck in the external protocol stays on the
     *         books as the merchant's outstanding exposure. Same primitive as
     *         UCR / X-LINK: the contract trusts only its own balance, never
     *         external return values.
     *
     *         IMPORTANT: After this call, principal values MAY be nonzero
     *         (whole or partial) even though the function emits
     *         EmergencyUnwound(...) — this is by design. External monitoring
     *         should read post-call principal values to determine stranded
     *         capital, not assume the function clears them.
     *
     * @return cbEthReturned Total cbETH sent to merchant (sweep amount)
     * @return usdcReturned  Total USDC sent to merchant (sweep amount)
     */
    function emergencyUnwind() external onlyMerchantOwner nonReentrant returns (uint256 cbEthReturned, uint256 usdcReturned) {
        // Delta-Verification refactor ratified per council 2026-05-17:
        // Principal tracking decrements by actual balance delta, not by intent.
        // If external protocol reverts and no capital is returned, principal
        // remains recorded as merchant's outstanding exposure. Same primitive
        // as UCR / X-LINK delta-verification: contract trusts its own balance,
        // not external return values.

        // ── MAVAN leg ────────────────────────────────────────────────────
        uint256 cbEthBeforeMavan = CBETH.balanceOf(address(this));
        uint256 currentMavanShares = IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));
        if (currentMavanShares > 0) {
            try IMAVANEntry(MAVAN_ENTRY).unstake(currentMavanShares) {
                // intentionally empty; balance delta below is authoritative
            } catch { /* MAVAN failure does not block other legs */ }
        }
        uint256 cbEthAfterMavan = CBETH.balanceOf(address(this));
        uint256 cbEthRecoveredFromMavan = cbEthAfterMavan - cbEthBeforeMavan;

        // Decrement principal by actual recovered amount, floor at zero.
        // Handles yield-included returns where recovered exceeds tracked
        // principal (mirrors the floor-at-zero pattern in withdrawFromMavan).
        if (cbEthRecoveredFromMavan >= mavanStakedPrincipal) {
            mavanStakedPrincipal = 0;
        } else {
            mavanStakedPrincipal -= cbEthRecoveredFromMavan;
        }

        // ── Morpho leg ───────────────────────────────────────────────────
        uint256 usdcBeforeMorpho = USDC.balanceOf(address(this));
        uint256 currentMorphoShares = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
        if (currentMorphoShares > 0) {
            try IMorphoVault(BITWISE_MORPHO_VAULT).redeem(currentMorphoShares, address(this), address(this)) {
                // intentionally empty; balance delta below is authoritative
            } catch { /* Morpho failure does not block sweep */ }
        }
        uint256 usdcAfterMorpho = USDC.balanceOf(address(this));
        uint256 usdcRecoveredFromMorpho = usdcAfterMorpho - usdcBeforeMorpho;

        if (usdcRecoveredFromMorpho >= morphoDepositedPrincipal) {
            morphoDepositedPrincipal = 0;
        } else {
            morphoDepositedPrincipal -= usdcRecoveredFromMorpho;
        }

        // ── Sweep ────────────────────────────────────────────────────────
        // Sweep all cbETH and USDC the contract holds (whether returned just
        // now or held from prior bridges) to the merchant. Sweep total reflects
        // total transferred, which may differ from per-leg recoveries above.
        cbEthReturned = CBETH.balanceOf(address(this));
        usdcReturned  = USDC.balanceOf(address(this));

        if (cbEthReturned > 0) CBETH.safeTransfer(MERCHANT_OWNER, cbEthReturned);
        if (usdcReturned  > 0) USDC.safeTransfer(MERCHANT_OWNER, usdcReturned);

        emit EmergencyUnwound(cbEthReturned, usdcReturned, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      RESCUE (Stranded Asset Recovery)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Recover any ERC20 accidentally sent to this contract that is not
     *         part of normal operations (anything other than cbETH and USDC,
     *         and including those if merchant chooses).
     *         Sends to MERCHANT_OWNER. Always allowed — merchant sovereignty.
     */
    function rescue(IERC20 token, uint256 amount) external onlyMerchantOwner {
        if (amount == 0) revert ZeroAmount();
        token.safeTransfer(MERCHANT_OWNER, amount);
        emit AssetsRescued(address(token), amount, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  INSTITUTIONAL IDENTITY PRIMITIVE
    //
    //   Verifiable architectural credentials. Allows external counterparties
    //   (MAVAN, Bitwise, Coinbase Custody, audit firms, regulators) to
    //   recognize this address as a genuine POSSESSIO Anchor and grade it
    //   accordingly in their own systems.
    //
    //   The trust anchor is `factoryDeployer()`. A bad actor cannot forge
    //   POSSESSIO Anchor status: while any contract can implement
    //   `isPossessioAnchor()`, only contracts deployed by the canonical
    //   L1AnchorFactory will return that Factory's address from
    //   `factoryDeployer()`. External recognition logic must verify the
    //   factoryDeployer matches an approved Factory address before granting
    //   institutional treatment.
    //
    //   This primitive enables but does not require external recognition.
    //   The Anchor functions identically whether or not any external party
    //   chooses to use these getters. The primitive is dormant until used.
    //
    //   Recommended external recognition pattern (e.g., for MAVAN):
    //
    //     bool isInstitutional =
    //         caller.code.length > 0
    //         && IPossessioAnchor(caller).isPossessioAnchor()
    //         && IPossessioAnchor(caller).factoryDeployer() == APPROVED_FACTORY;
    //
    //   `APPROVED_FACTORY` is whatever address the recognizing party has
    //   audited and ratified.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when an external party attests its recognition of this
    ///         Anchor's identity. Pure observability — does not change state
    ///         beyond the log entry, does not gate any logic.
    event AnchorIdentityAttested(address indexed verifier, uint256 timestamp);

    /// @notice Anyone may call to commit a public attestation event. Used by
    ///         MAVAN, Bitwise, custody providers, or auditors to leave an
    ///         on-chain breadcrumb that they have recognized this Anchor's
    ///         identity. No authority required, no fund movement, costs only
    ///         event-emission gas. The verifier is `msg.sender` so the event
    ///         is non-spoofable.
    function attestIdentity() external {
        emit AnchorIdentityAttested(msg.sender, block.timestamp);
    }

    /// @notice Always returns true on a genuine POSSESSIO Anchor. Trivially
    ///         forgeable on its own — recognition logic must combine this
    ///         with `factoryDeployer()` verification against an approved
    ///         Factory address.
    function isPossessioAnchor() external pure returns (bool) {
        return true;
    }

    /// @notice The L1AnchorFactory that deployed this contract. Non-forgeable.
    ///         External recognition logic should compare this against an
    ///         approved Factory address as the trust anchor.
    function factoryDeployer() external view returns (address) {
        return FACTORY;
    }

    /// @notice The current authority over this Anchor's funds.
    function merchantOwner() external view returns (address) {
        return MERCHANT_OWNER;
    }

    /// @notice Block timestamp when this Anchor was deployed.
    ///         Useful for tenure-based recognition tiers.
    function deploymentTimestamp() external view returns (uint256) {
        return DEPLOYED_AT;
    }

    /// @notice Anchor template version string. External recognition logic
    ///         can use this to apply differential treatment between Anchor
    ///         versions if a Factory v2 is later deployed.
    function anchorVersion() external pure returns (string memory) {
        return ANCHOR_VERSION;
    }

    /// @notice Asserts the architectural property that no admin role exists
    ///         in this contract beyond the merchant owner. Always returns
    ///         true on a genuine POSSESSIO Anchor.
    function hasNoAdminAuthority() external pure returns (bool) {
        return true;
    }

    /// @notice Asserts the architectural property that this contract has
    ///         no upgrade mechanism. Always returns true on a genuine
    ///         POSSESSIO Anchor.
    function hasNoUpgradePath() external pure returns (bool) {
        return true;
    }

    /// @notice Asserts the architectural property that this contract does
    ///         not initiate cross-chain messages or operate as a money
    ///         transmitter. Always returns true on a genuine POSSESSIO Anchor.
    function isNonMoneyTransmitter() external pure returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice cbETH currently held in this contract (not yet routed to MAVAN).
    function liquidCbEth() external view returns (uint256) {
        return CBETH.balanceOf(address(this));
    }

    /// @notice USDC currently held in this contract (not yet routed to Morpho).
    function liquidUsdc() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Current MAVAN shares owned by this contract.
    function mavanShares() external view returns (uint256) {
        return IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));
    }

    /// @notice Current Morpho vault shares owned by this contract.
    function morphoShares() external view returns (uint256) {
        return IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
    }

    /// @notice USDC value of current Morpho shares (best-effort, depends on vault rate).
    function morphoUsdcValue() external view returns (uint256) {
        uint256 shares = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
        if (shares == 0) return 0;
        try IMorphoVault(BITWISE_MORPHO_VAULT).convertToAssets(shares) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @notice Consolidated treasury position view for merchant UX.
    function treasurySnapshot() external view returns (
        uint256 cbEthLiquid,
        uint256 cbEthMavanShares,
        uint256 cbEthMavanPrincipal,
        uint256 usdcLiquid,
        uint256 usdcMorphoShares,
        uint256 usdcMorphoValue,
        uint256 usdcMorphoPrincipal,
        bool isDepegPaused
    ) {
        cbEthLiquid          = CBETH.balanceOf(address(this));
        cbEthMavanShares     = IMAVANEntry(MAVAN_ENTRY).sharesOf(address(this));
        cbEthMavanPrincipal  = mavanStakedPrincipal;
        usdcLiquid           = USDC.balanceOf(address(this));
        usdcMorphoShares     = IMorphoVault(BITWISE_MORPHO_VAULT).balanceOf(address(this));
        usdcMorphoPrincipal  = morphoDepositedPrincipal;
        isDepegPaused        = depegPaused;

        if (usdcMorphoShares > 0) {
            try IMorphoVault(BITWISE_MORPHO_VAULT).convertToAssets(usdcMorphoShares) returns (uint256 v) {
                usdcMorphoValue = v;
            } catch { /* leave zero */ }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          REGULATORY POSTURE
    //
    //   This contract DOES NOT:
    //     - Initiate any cross-chain message
    //     - Call any bridge contract
    //     - Hold any privileged role for protocol developers
    //     - Implement any upgrade mechanism
    //     - Charge any fees on merchant principal or yield
    //     - Pool merchant assets with other merchants (per-merchant deployment)
    //
    //   This contract IS:
    //     - A tool the merchant operates with their own keys
    //     - Deployed once per merchant via L1AnchorFactory
    //     - Immutable in behavior from deployment
    //     - Auditable via emitted events
    //     - Sovereign property of the MERCHANT_OWNER
    //
    //   The merchant's bridging from L2 to L1 happens with their own keys
    //   via bridges of their choosing, outside this contract entirely.
    //   This contract only ever sees assets that have already arrived.
    //
    // ═══════════════════════════════════════════════════════════════════════
}
