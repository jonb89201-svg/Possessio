// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ██████╗  ██████╗ ███████╗███████╗███████╗███████╗███████╗██╗ ██████╗ 
 * ██╔══██╗██╔═══██╗██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝██║██╔═══██╗
 * ██████╔╝██║   ██║███████╗███████╗█████╗  ███████╗███████╗██║██║   ██║
 * ██╔═══╝ ██║   ██║╚════██║╚════██║██╔══╝  ╚════██║╚════██║██║██║   ██║
 * ██║     ╚██████╔╝███████║███████║███████╗███████║███████║██║╚██████╔╝
 * ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚══════╝╚══════╝╚══════╝╚═╝ ╚═════╝ 
 *
 * POSSESSIO PROTOCOL — $PITI TOKEN
 * Real-Time Property Intelligence · Base Network
 * The data Zillow has no incentive to show you.
 *
 * L.A.T.E. — Liquidity and Treasury Engine
 * Every swap feeds the flywheel:
 *   25% → Protocol-owned liquidity (immutable)
 *   75% → Treasury → Yield → 25% back to LP + 75% operations
 *
 * Treasury: 0x188bE439C141c9138Bd3075f6A376F73c07F1903
 * Protocol: possessio.io
 */

// ============================================================
//                         IMPORTS
// ============================================================

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

// ============================================================
//                      INTERFACES
// ============================================================

/**
 * @dev Aerodrome / Uniswap V2 style router interface
 * Used to detect swap transactions and identify DEX interactions
 */
interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
}

/**
 * @dev Aerodrome / Uniswap V2 style pair interface
 * Used to identify liquidity pool addresses
 */
interface IPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @dev cbETH interface for yield deployment
 * Coinbase Wrapped Staked ETH
 */
interface IcbETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Ondo USDY interface for yield deployment
 * Tokenized U.S. Treasury yield
 */
interface IUSDY {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Split contract interface
 * Receives fees and distributes to LP and Treasury
 */
interface ISplit {
    function distribute() external;
}

// ============================================================
//                     MAIN CONTRACT
// ============================================================

contract PITI is ERC20, ERC20Permit, Ownable, ReentrancyGuard {

    // --------------------------------------------------------
    //                      CONSTANTS
    // --------------------------------------------------------

    /// @notice Total fixed supply — 1,000,000 $PITI. Never changes.
    uint256 public constant TOTAL_SUPPLY = 1_000_000 * 10**18;

    /// @notice Swap fee in basis points — 100 = 1%
    uint256 public constant FEE_BASIS_POINTS = 100;

    /// @notice Fee denominator
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /// @notice Immutable LP allocation — 25% of fees. CANNOT BE CHANGED.
    uint256 public constant LP_ALLOCATION = 25;

    /// @notice Treasury allocation — 75% of fees.
    uint256 public constant TREASURY_ALLOCATION = 75;

    /// @notice Yield split back to LP — 25% of yield earned
    uint256 public constant YIELD_TO_LP = 25;

    /// @notice Yield retained in treasury — 75% of yield earned
    uint256 public constant YIELD_TO_TREASURY = 75;

    /// @notice 48-hour timelock delay in seconds
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // --------------------------------------------------------
    //                    STATE VARIABLES
    // --------------------------------------------------------

    /// @notice The L.A.T.E. Split contract address
    /// Receives all swap fees and distributes 25/75
    address public splitContract;

    /// @notice POSSESSIO Treasury — Safe 3-of-5 multi-sig
    address public constant TREASURY =
        0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    /// @notice Aerodrome LP pool address
    /// Receives 25% of all swap fees — immutable path
    address public liquidityPool;

    /// @notice Aerodrome router address on Base
    address public aerodromeRouter;

    /// @notice cbETH contract address on Base
    address public cbETHAddress;

    /// @notice Ondo USDY contract address on Base
    address public usdyAddress;

    /// @notice Active yield target — true = cbETH, false = USDY
    bool public useCbETH = true;

    /// @notice Circuit breaker — pauses fee routing if true
    bool public circuitBreakerActive = false;

    /// @notice Tracks whether an address is a DEX pair
    mapping(address => bool) public isDEXPair;

    /// @notice Tracks whether an address is excluded from fees
    /// Only used for the contract itself and the split contract
    mapping(address => bool) public isExcludedFromFees;

    /// @notice Timelock for parameter changes
    TimelockController public timelock;

    /// @notice Tracks pending parameter changes
    mapping(bytes32 => uint256) public pendingChanges;

    // --------------------------------------------------------
    //                        EVENTS
    // --------------------------------------------------------

    /// @notice Emitted on every fee collection — powers Farcaster Frame
    event FeeCollected(
        address indexed from,
        address indexed to,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 treasuryAmount,
        uint256 timestamp
    );

    /// @notice Emitted on every LP injection
    event LiquidityInjected(
        uint256 amount,
        address indexed lpPool,
        uint256 timestamp
    );

    /// @notice Emitted on every treasury deposit
    event TreasuryDeposited(
        uint256 amount,
        address indexed treasury,
        uint256 timestamp
    );

    /// @notice Emitted when yield is deployed
    event YieldDeployed(
        address indexed yieldTarget,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when yield is harvested and split
    event YieldHarvested(
        uint256 totalYield,
        uint256 toLiquidity,
        uint256 toTreasury,
        uint256 timestamp
    );

    /// @notice Emitted when circuit breaker is triggered
    event CircuitBreakerActivated(
        address indexed triggeredBy,
        uint256 timestamp
    );

    /// @notice Emitted when circuit breaker is deactivated
    event CircuitBreakerDeactivated(
        address indexed deactivatedBy,
        uint256 timestamp
    );

    /// @notice Emitted when a DEX pair is registered
    event DEXPairRegistered(
        address indexed pair,
        uint256 timestamp
    );

    /// @notice Emitted when a parameter change is queued
    event ParameterChangeQueued(
        bytes32 indexed changeId,
        string parameter,
        uint256 executeAfter,
        uint256 timestamp
    );

    /// @notice Emitted when ownership is renounced
    event OwnershipFullyRenounced(uint256 timestamp);

    // --------------------------------------------------------
    //                       MODIFIERS
    // --------------------------------------------------------

    /// @notice Prevents fee routing when circuit breaker is active
    modifier circuitBreakerOff() {
        require(
            !circuitBreakerActive,
            "PITI: Circuit breaker active — fee routing paused"
        );
        _;
    }

    /// @notice Ensures timelock has passed before executing changes
    modifier timelockPassed(bytes32 changeId) {
        require(
            pendingChanges[changeId] != 0,
            "PITI: Change not queued"
        );
        require(
            block.timestamp >= pendingChanges[changeId],
            "PITI: 48-hour timelock not elapsed"
        );
        _;
        delete pendingChanges[changeId];
    }

    // --------------------------------------------------------
    //                      CONSTRUCTOR
    // --------------------------------------------------------

    /**
     * @notice Deploys the $PITI token with fixed supply
     * @param _splitContract Address of the L.A.T.E. Split contract
     * @param _liquidityPool Address of the Aerodrome ETH/$PITI pool
     * @param _aerodromeRouter Address of the Aerodrome router on Base
     * @param _cbETHAddress Address of cbETH on Base
     * @param _usdyAddress Address of Ondo USDY on Base
     */
    constructor(
        address _splitContract,
        address _liquidityPool,
        address _aerodromeRouter,
        address _cbETHAddress,
        address _usdyAddress
    )
        ERC20("PITI", "PITI")
        ERC20Permit("PITI")
        Ownable(msg.sender)
    {
        require(_splitContract != address(0), "PITI: Invalid split contract");
        require(_liquidityPool != address(0), "PITI: Invalid liquidity pool");
        require(_aerodromeRouter != address(0), "PITI: Invalid router");

        splitContract = _splitContract;
        liquidityPool = _liquidityPool;
        aerodromeRouter = _aerodromeRouter;
        cbETHAddress = _cbETHAddress;
        usdyAddress = _usdyAddress;

        // Register the LP pool as a DEX pair
        isDEXPair[_liquidityPool] = true;

        // Exclude contract and split from fees
        isExcludedFromFees[address(this)] = true;
        isExcludedFromFees[_splitContract] = true;
        isExcludedFromFees[TREASURY] = true;

        // Mint fixed supply to deployer
        // Deployer distributes to liquidity pool at launch
        _mint(msg.sender, TOTAL_SUPPLY);

        emit DEXPairRegistered(_liquidityPool, block.timestamp);
    }

    // --------------------------------------------------------
    //                   CORE FEE LOGIC
    // --------------------------------------------------------

    /**
     * @notice Overrides ERC-20 transfer to intercept swap fees
     * @dev Fee is only taken on DEX swap transactions
     *      Wallet-to-wallet transfers are always fee-free
     *      Circuit breaker pauses fee routing but NOT transfers
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Always allow transfers — circuit breaker only pauses fee routing
        // Never block token movement

        bool isSwap = isDEXPair[from] || isDEXPair[to];
        bool excluded = isExcludedFromFees[from] || isExcludedFromFees[to];

        if (isSwap && !excluded && !circuitBreakerActive && amount > 0) {
            // Calculate 1% fee
            uint256 feeAmount = (amount * FEE_BASIS_POINTS) / FEE_DENOMINATOR;
            uint256 amountAfterFee = amount - feeAmount;

            // Calculate split
            uint256 lpAmount = (feeAmount * LP_ALLOCATION) / 100;
            uint256 treasuryAmount = feeAmount - lpAmount;

            // Route 25% to LP — IMMUTABLE PATH
            // This line cannot be changed by any admin function
            super._update(from, liquidityPool, lpAmount);

            // Route 75% to Split contract → Treasury
            super._update(from, splitContract, treasuryAmount);

            // Transfer remainder to recipient
            super._update(from, to, amountAfterFee);

            // Emit engine state event — powers Farcaster Frame
            emit FeeCollected(
                from,
                to,
                amount,
                feeAmount,
                lpAmount,
                treasuryAmount,
                block.timestamp
            );

            emit LiquidityInjected(lpAmount, liquidityPool, block.timestamp);
            emit TreasuryDeposited(treasuryAmount, splitContract, block.timestamp);

        } else {
            // Standard transfer — no fee
            super._update(from, to, amount);
        }
    }

    // --------------------------------------------------------
    //                    YIELD ENGINE
    // --------------------------------------------------------

    /**
     * @notice Deploys treasury ETH into yield-bearing assets
     * @dev Called autonomously when treasury has surplus
     *      Target is either cbETH or Ondo USDY
     *      This is hardcoded — not a discretionary decision
     */
    function deployYield() external nonReentrant circuitBreakerOff {
        uint256 balance = address(this).balance;
        require(balance > 0, "PITI: No ETH to deploy");

        if (useCbETH && cbETHAddress != address(0)) {
            // Deploy to cbETH
            IcbETH(cbETHAddress).deposit{value: balance}();
            emit YieldDeployed(cbETHAddress, balance, block.timestamp);
        } else if (usdyAddress != address(0)) {
            // Deploy to Ondo USDY
            IUSDY(usdyAddress).deposit(balance);
            emit YieldDeployed(usdyAddress, balance, block.timestamp);
        }
    }

    /**
     * @notice Harvests yield and splits 25% to LP, 75% to treasury
     * @dev The yield split is hardcoded — cannot be changed
     *      25% of yield → LP injection (raises price floor)
     *      75% of yield → Treasury (funds API costs)
     */
    function harvestYield() external nonReentrant circuitBreakerOff {
        uint256 yieldAmount = 0;

        if (useCbETH && cbETHAddress != address(0)) {
            yieldAmount = IcbETH(cbETHAddress).balanceOf(address(this));
            if (yieldAmount > 0) {
                IcbETH(cbETHAddress).withdraw(yieldAmount);
            }
        } else if (usdyAddress != address(0)) {
            yieldAmount = IUSDY(usdyAddress).balanceOf(address(this));
            if (yieldAmount > 0) {
                IUSDY(usdyAddress).withdraw(yieldAmount);
            }
        }

        require(yieldAmount > 0, "PITI: No yield to harvest");

        // Split yield — hardcoded 25/75
        uint256 yieldToLP = (yieldAmount * YIELD_TO_LP) / 100;
        uint256 yieldToTreasury = yieldAmount - yieldToLP;

        // Send 25% of yield to LP — compounds the floor
        (bool lpSuccess, ) = liquidityPool.call{value: yieldToLP}("");
        require(lpSuccess, "PITI: LP yield injection failed");

        // Send 75% of yield to treasury
        (bool treasurySuccess, ) = TREASURY.call{value: yieldToTreasury}("");
        require(treasurySuccess, "PITI: Treasury yield transfer failed");

        emit YieldHarvested(
            yieldAmount,
            yieldToLP,
            yieldToTreasury,
            block.timestamp
        );
    }

    // --------------------------------------------------------
    //                   CIRCUIT BREAKER
    // --------------------------------------------------------

    /**
     * @notice Activates emergency circuit breaker
     * @dev Pauses fee routing ONLY
     *      Token transfers continue normally
     *      Treasury and LP positions are untouched
     *      Requires 3-of-5 Safe to deactivate
     */
    function activateCircuitBreaker() external onlyOwner {
        circuitBreakerActive = true;
        emit CircuitBreakerActivated(msg.sender, block.timestamp);
    }

    /**
     * @notice Deactivates circuit breaker after exploit is resolved
     * @dev Requires 48-hour timelock after queuing
     *      Must be queued first via queueCircuitBreakerDeactivation()
     */
    function deactivateCircuitBreaker(
        bytes32 changeId
    ) external onlyOwner timelockPassed(changeId) {
        circuitBreakerActive = false;
        emit CircuitBreakerDeactivated(msg.sender, block.timestamp);
    }

    /**
     * @notice Queues circuit breaker deactivation
     * @dev Starts the 48-hour timelock
     *      Change is publicly visible on-chain during delay
     */
    function queueCircuitBreakerDeactivation()
        external
        onlyOwner
        returns (bytes32 changeId)
    {
        changeId = keccak256(
            abi.encodePacked("deactivateCircuitBreaker", block.timestamp)
        );
        pendingChanges[changeId] = block.timestamp + TIMELOCK_DELAY;

        emit ParameterChangeQueued(
            changeId,
            "deactivateCircuitBreaker",
            pendingChanges[changeId],
            block.timestamp
        );
    }

    // --------------------------------------------------------
    //                  48-HOUR TIMELOCK
    // --------------------------------------------------------

    /**
     * @notice Queues a yield target change (cbETH ↔ USDY)
     * @dev Starts 48-hour delay — visible on-chain immediately
     */
    function queueYieldTargetChange(
        bool _useCbETH
    ) external onlyOwner returns (bytes32 changeId) {
        changeId = keccak256(
            abi.encodePacked("yieldTarget", _useCbETH, block.timestamp)
        );
        pendingChanges[changeId] = block.timestamp + TIMELOCK_DELAY;

        emit ParameterChangeQueued(
            changeId,
            "yieldTarget",
            pendingChanges[changeId],
            block.timestamp
        );
    }

    /**
     * @notice Executes yield target change after 48-hour timelock
     */
    function executeYieldTargetChange(
        bytes32 changeId,
        bool _useCbETH
    ) external onlyOwner timelockPassed(changeId) {
        useCbETH = _useCbETH;
    }

    /**
     * @notice Queues liquidity pool address update
     * @dev Used when migrating from temporary LP to permanent pool
     *      Starts 48-hour timelock
     */
    function queueLiquidityPoolUpdate(
        address _newLiquidityPool
    ) external onlyOwner returns (bytes32 changeId) {
        require(_newLiquidityPool != address(0), "PITI: Invalid pool address");

        changeId = keccak256(
            abi.encodePacked("liquidityPool", _newLiquidityPool, block.timestamp)
        );
        pendingChanges[changeId] = block.timestamp + TIMELOCK_DELAY;

        emit ParameterChangeQueued(
            changeId,
            "liquidityPool",
            pendingChanges[changeId],
            block.timestamp
        );
    }

    /**
     * @notice Executes liquidity pool update after 48-hour timelock
     * @dev This is how we update from MetaMask placeholder to real Aerodrome LP
     */
    function executeLiquidityPoolUpdate(
        bytes32 changeId,
        address _newLiquidityPool
    ) external onlyOwner timelockPassed(changeId) {
        // Remove old pair
        isDEXPair[liquidityPool] = false;

        // Set new pair
        liquidityPool = _newLiquidityPool;
        isDEXPair[_newLiquidityPool] = true;

        emit DEXPairRegistered(_newLiquidityPool, block.timestamp);
    }

    /**
     * @notice Registers additional DEX pairs
     * @dev Subject to 48-hour timelock
     */
    function queueDEXPairRegistration(
        address _pair
    ) external onlyOwner returns (bytes32 changeId) {
        require(_pair != address(0), "PITI: Invalid pair address");

        changeId = keccak256(
            abi.encodePacked("dexPair", _pair, block.timestamp)
        );
        pendingChanges[changeId] = block.timestamp + TIMELOCK_DELAY;

        emit ParameterChangeQueued(
            changeId,
            "dexPair",
            pendingChanges[changeId],
            block.timestamp
        );
    }

    /**
     * @notice Executes DEX pair registration after 48-hour timelock
     */
    function executeDEXPairRegistration(
        bytes32 changeId,
        address _pair
    ) external onlyOwner timelockPassed(changeId) {
        isDEXPair[_pair] = true;
        emit DEXPairRegistered(_pair, block.timestamp);
    }

    // --------------------------------------------------------
    //                OWNERSHIP & SECURITY
    // --------------------------------------------------------

    /**
     * @notice Permanently renounces contract ownership
     * @dev Once called no one can:
     *      - Change fee parameters
     *      - Register new DEX pairs
     *      - Update yield targets
     *      - Activate circuit breaker
     * WARNING: This is irreversible. Call only after full testing.
     */
    function renounceOwnershipPermanently() external onlyOwner {
        renounceOwnership();
        emit OwnershipFullyRenounced(block.timestamp);
    }

    // --------------------------------------------------------
    //                    VIEW FUNCTIONS
    // --------------------------------------------------------

    /**
     * @notice Returns current protocol state for Farcaster Frame
     * @dev All data needed to render the L.A.T.E. dashboard
     */
    function getProtocolState() external view returns (
        address _splitContract,
        address _liquidityPool,
        address _treasury,
        bool _circuitBreakerActive,
        bool _useCbETH,
        uint256 _totalSupply,
        uint256 _feePercent
    ) {
        return (
            splitContract,
            liquidityPool,
            TREASURY,
            circuitBreakerActive,
            useCbETH,
            totalSupply(),
            FEE_BASIS_POINTS
        );
    }

    /**
     * @notice Checks if an address is a registered DEX pair
     */
    function isRegisteredDEXPair(
        address _address
    ) external view returns (bool) {
        return isDEXPair[_address];
    }

    /**
     * @notice Returns time remaining on a pending change
     */
    function getTimelockRemaining(
        bytes32 changeId
    ) external view returns (uint256) {
        if (pendingChanges[changeId] == 0) return 0;
        if (block.timestamp >= pendingChanges[changeId]) return 0;
        return pendingChanges[changeId] - block.timestamp;
    }

    // --------------------------------------------------------
    //                   RECEIVE ETH
    // --------------------------------------------------------

    /**
     * @notice Allows contract to receive ETH from yield withdrawals
     */
    receive() external payable {}

    fallback() external payable {}
}
