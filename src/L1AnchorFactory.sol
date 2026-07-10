// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {L1Anchor} from "./L1Anchor.sol";

/**
 * @title L1AnchorFactory
 * @notice Canonical Factory for deploying merchant-owned L1Anchor instances.
 *
 *         The Factory hardcodes institutional endpoint addresses (MAVAN entry,
 *         Bitwise Morpho vault, cbETH, USDC, Chainlink cbETH/ETH oracle) so
 *         that individual merchants cannot be deceived into deploying their
 *         Anchor against malicious counterparties.  A merchant calls
 *         `deployAnchor()` and the Factory does the rest:
 *
 *         1. Constructs a new L1Anchor with msg.sender as MERCHANT_OWNER
 *         2. Passes the canonical institutional addresses as constructor args
 *         3. Records the new Anchor in the registry
 *         4. Emits AnchorCreated for off-chain indexing
 *
 *         The Factory address itself is the trust anchor for the L1Anchor's
 *         Institutional Identity Primitive: external counterparties (MAVAN,
 *         Bitwise, custody providers, audit firms, regulators) verify a
 *         contract is a genuine POSSESSIO Anchor by calling
 *         `factoryDeployer()` on the Anchor and confirming it returns the
 *         address of *this* canonical Factory (after auditing the Factory's
 *         deployed bytecode).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 *                               ARCHITECTURAL POSTURE
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  - Non-Money Transmitter: the Factory does not move merchant capital.  It
 *    deploys contracts.  Merchant capital movement happens entirely through
 *    the deployed Anchor under MERCHANT_OWNER authority.
 *
 *  - No admin authority: the Factory has no owner, no admin, no upgrade path.
 *    It is a stateless deployment helper from a code-execution standpoint;
 *    the registry it maintains is append-only and read-only externally.
 *
 *  - Immutable institutional endpoints: the addresses for MAVAN, Bitwise's
 *    Morpho vault, cbETH, USDC, and the Chainlink oracle are immutable in
 *    this Factory.  If any of those institutional endpoints change (e.g.,
 *    Bitwise migrates to a new vault, MAVAN ships a v2 staking contract),
 *    a new Factory is deployed.  Existing Anchors keep operating against
 *    their original endpoints; new merchants deploy against the new Factory
 *    if they want the new endpoints.  This forces honest versioning rather
 *    than silent endpoint migration.
 *
 *  - Per-merchant deployment: each call to deployAnchor() produces a fresh
 *    Anchor instance owned by msg.sender.  Merchants cannot share Anchors;
 *    cross-merchant fund commingling is mechanically impossible.
 *
 *  - Open access: anyone can call deployAnchor().  The protocol does not
 *    gate who may operate as a merchant.  Whether to recognize a particular
 *    Anchor's merchant as institutional is the recognizing party's decision
 *    (MAVAN, Bitwise, custody, regulators) using the Identity Primitive
 *    surface on the deployed Anchor.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 *                               WHAT THIS CONTRACT IS NOT
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  - Not a money transmitter: no value moves through the Factory
 *  - Not an upgrade manager: no Anchor upgrade path exists; this Factory
 *    deploys one Anchor template version (1.0.0) and that's permanent
 *  - Not a fee collector: deployment is free at the Factory level (gas only).
 *    Future Factory versions may add a deployment fee; this version is free
 *    so the v2 mainnet launch has no friction for early merchants. The
 *    deployment fee for the fee-bearing version is TO BE DETERMINED BY
 *    FUNDSTRAT — the economics of the L1 settlement rail that terminates
 *    institutional capital in MAVAN are a joint decision with the network
 *    operator, not set unilaterally by POSSESSIO.
 *  - Not an Anchor authority: once deployed, the Factory has no power over
 *    the Anchor's behavior.  The Anchor's MERCHANT_OWNER is the sole
 *    authority.  The Factory's only role is the construction event.
 *
 * @custom:version 1.0.0
 */
contract L1AnchorFactory {
    // ═══════════════════════════════════════════════════════════════════════
    //                           VERSION CONSTANT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Factory version. Bumped if a new Factory deploys with different
    ///         institutional endpoints or different Anchor template version.
    string public constant FACTORY_VERSION = "1.0.0";

    /// @notice The Anchor template version this Factory deploys.  Must match
    ///         the deployed L1Anchor contract's ANCHOR_VERSION constant.
    string public constant ANCHOR_TEMPLATE_VERSION = "1.0.0";

    // ═══════════════════════════════════════════════════════════════════════
    //                       INSTITUTIONAL ENDPOINTS (immutable)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Bitwise-curated Morpho Blue USDC vault on Ethereum mainnet.
    ///         Hardcoded so merchants cannot be deceived into deploying against
    ///         a malicious vault.  If Bitwise migrates to a new vault, a new
    ///         Factory is deployed.
    address public immutable BITWISE_MORPHO_VAULT;

    /// @notice MAVAN validator network entry contract on Ethereum mainnet.
    ///         Same hardcoding rationale as the Morpho vault.
    address public immutable MAVAN_ENTRY;

    /// @notice cbETH token on Ethereum mainnet.
    address public immutable CBETH;

    /// @notice USDC token on Ethereum mainnet.
    address public immutable USDC;

    /// @notice Chainlink cbETH/ETH price feed on Ethereum mainnet.
    address public immutable CBETH_ETH_ORACLE;

    // ═══════════════════════════════════════════════════════════════════════
    //                              REGISTRY STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Append-only list of every Anchor this Factory has deployed.
    ///         External indexers can iterate this for ecosystem views.
    address[] public deployedAnchors;

    /// @notice Maps merchant address to their list of deployed Anchors.
    ///         A merchant may deploy multiple Anchors (separate businesses,
    ///         separate accounting domains, separate counterparty exposure).
    mapping(address merchant => address[] anchors) public anchorsOf;

    /// @notice True if an address is an Anchor deployed by this Factory.
    ///         Provides O(1) verification for external recognition logic.
    mapping(address anchor => bool deployedHere) public isAnchorOfFactory;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new Anchor is deployed.
     * @param merchant     The merchant address that called deployAnchor()
     *                     (becomes the Anchor's MERCHANT_OWNER)
     * @param anchor       The address of the newly deployed L1Anchor
     * @param anchorIndex  Zero-indexed position in deployedAnchors[]
     * @param timestamp    block.timestamp at deployment
     */
    event AnchorCreated(
        address indexed merchant,
        address indexed anchor,
        uint256 anchorIndex,
        uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @param _morphoVault      Bitwise-curated Morpho Blue USDC vault
     * @param _mavanEntry       MAVAN validator network entry contract
     * @param _cbeth            cbETH token (Ethereum mainnet)
     * @param _usdc             USDC token (Ethereum mainnet)
     * @param _cbethEthOracle   Chainlink cbETH/ETH price feed (Ethereum mainnet)
     */
    constructor(
        address _morphoVault,
        address _mavanEntry,
        address _cbeth,
        address _usdc,
        address _cbethEthOracle
    ) {
        if (_morphoVault    == address(0)) revert ZeroAddress();
        if (_mavanEntry     == address(0)) revert ZeroAddress();
        if (_cbeth          == address(0)) revert ZeroAddress();
        if (_usdc           == address(0)) revert ZeroAddress();
        if (_cbethEthOracle == address(0)) revert ZeroAddress();

        BITWISE_MORPHO_VAULT = _morphoVault;
        MAVAN_ENTRY          = _mavanEntry;
        CBETH                = _cbeth;
        USDC                 = _usdc;
        CBETH_ETH_ORACLE     = _cbethEthOracle;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         CORE: deployAnchor()
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a new L1Anchor owned by the caller.  Anyone may call.
     *
     *         The deployed Anchor:
     *           - Has msg.sender as MERCHANT_OWNER (the sole authority)
     *           - Has this Factory address as FACTORY (the trust anchor for
     *             institutional identity recognition)
     *           - Is constructed with the canonical institutional endpoints
     *             this Factory holds as immutables
     *           - Cannot be deployed against malicious counterparties because
     *             the merchant has no input on counterparty addresses
     *
     *         The merchant retains full sovereignty over the deployed Anchor.
     *         The Factory has no role after construction.
     *
     * @return anchor The address of the newly deployed L1Anchor.
     */
    function deployAnchor() external returns (address anchor) {
        L1Anchor newAnchor = new L1Anchor(
            msg.sender,             // MERCHANT_OWNER = caller
            BITWISE_MORPHO_VAULT,
            MAVAN_ENTRY,
            CBETH,
            USDC,
            CBETH_ETH_ORACLE
        );

        anchor = address(newAnchor);

        deployedAnchors.push(anchor);
        anchorsOf[msg.sender].push(anchor);
        isAnchorOfFactory[anchor] = true;

        emit AnchorCreated(
            msg.sender,
            anchor,
            deployedAnchors.length - 1,
            block.timestamp
        );

        return anchor;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total number of Anchors deployed by this Factory.
    function totalAnchors() external view returns (uint256) {
        return deployedAnchors.length;
    }

    /// @notice Number of Anchors deployed by a specific merchant.
    function anchorCountOf(address merchant) external view returns (uint256) {
        return anchorsOf[merchant].length;
    }

    /// @notice Returns all Anchors deployed by a specific merchant.
    ///         Useful for off-chain dashboards that show a merchant their
    ///         portfolio of Anchors across separate accounting domains.
    function getAnchorsOf(address merchant) external view returns (address[] memory) {
        return anchorsOf[merchant];
    }

    /// @notice Paginated read of the global Anchor registry.  Use this rather
    ///         than reading deployedAnchors[] in full when the registry grows
    ///         beyond what a single eth_call can return.
    /// @param  start  First index to return (inclusive)
    /// @param  count  Maximum number of Anchors to return
    /// @return page   Slice of deployedAnchors[] from start, length up to count
    function getAnchorsPage(
        uint256 start,
        uint256 count
    ) external view returns (address[] memory page) {
        uint256 total = deployedAnchors.length;
        if (start >= total) {
            return new address[](0);
        }

        uint256 end = start + count;
        if (end > total) {
            end = total;
        }

        uint256 len = end - start;
        page = new address[](len);
        for (uint256 i = 0; i < len; ++i) {
            page[i] = deployedAnchors[start + i];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  INSTITUTIONAL IDENTITY (Factory side)
    //
    //   The Factory itself exposes recognition surface so external parties
    //   can verify the Factory's identity before trusting Anchors deployed
    //   by it.  This is symmetric to the Anchor's identity primitive:
    //   counterparties verify the Factory once (against ratified bytecode
    //   and address), then trust all Anchors whose factoryDeployer() returns
    //   this Factory's address.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Always returns true on a genuine POSSESSIO Anchor Factory.
    ///         Trivially forgeable on its own; recognition logic must verify
    ///         this Factory's address against an audited canonical address.
    function isPossessioAnchorFactory() external pure returns (bool) {
        return true;
    }

    /// @notice Factory template version string.  External recognition logic
    ///         can use this to apply differential treatment between Factory
    ///         versions if a Factory v2 is later deployed.
    function factoryVersion() external pure returns (string memory) {
        return FACTORY_VERSION;
    }

    /// @notice The Anchor template version this Factory produces.
    function anchorTemplateVersion() external pure returns (string memory) {
        return ANCHOR_TEMPLATE_VERSION;
    }

    /// @notice Asserts the architectural property that this Factory has no
    ///         admin authority over deployed Anchors.  Always returns true.
    function hasNoAdminAuthority() external pure returns (bool) {
        return true;
    }

    /// @notice Asserts the architectural property that this Factory cannot
    ///         upgrade itself or the Anchors it has deployed.  Always returns
    ///         true.
    function hasNoUpgradePath() external pure returns (bool) {
        return true;
    }

    /// @notice Asserts the architectural property that this Factory does not
    ///         move merchant capital.  Always returns true.
    function isNonMoneyTransmitter() external pure returns (bool) {
        return true;
    }
}
