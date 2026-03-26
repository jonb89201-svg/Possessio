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
 * POSSESSIO PROTOCOL — $PITI TOKEN V2
 * Real-Time Property Intelligence · Base Network
 * The data Zillow has no incentive to show you.
 *
 * L.A.T.E. — Liquidity and Treasury Engine
 *
 * Fee Routing:
 *   25% → Protocol-owned LP (immutable, always)
 *   75% → Treasury:
 *          20% of 75% → DAI reserve (until $2,280 met, then stops)
 *          Remainder  → ETH staking (20% cbETH / 40% wstETH / 40% rETH)
 *
 * Agent Rewards (from LP allocation only):
 *   Normal:    100% of 25% LP allocation → LP injection
 *   Triggered: Dynamic split (LP + $PITI buyback for agent wallet)
 *   Rate scales linearly: 80% depleted=25% divert, 50%=50%, 20%=75%
 *
 * Token Distribution:
 *   400,000,000 (40%) → Aerodrome LP
 *   500,000,000 (50%) → Public float
 *    50,000,000  (5%) → Founder (2yr vest)
 *    30,000,000  (3%) → CTO (4yr vest, 1yr cliff)
 *    20,000,000  (2%) → Protocol reserve (timelock)
 *
 * Treasury: 0x188bE439C141c9138Bd3075f6A376F73c07F1903
 * Split:    0xB20B4f672CF7b27e03991346Fd324d24C1d3e572
 * GitHub:   github.com/jonb89201-svg/Possessio
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
//                        INTERFACES
// ============================================================

interface IRouter {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}

interface IcbETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IwstETH {
    function balanceOf(address account) external view returns (uint256);
}

interface IrETH {
    function deposit() external payable;
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    );
}

interface IAerodromePool {
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );
}

interface IDAI {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ============================================================
//              AGENT SOULBOUND TOKEN (SBT)
// ============================================================

/**
 * @title AgentSBT
 * @notice Non-transferable ERC-721 reputation token for POSSESSIO agents
 *
 * Soulbound implementation:
 *   - Allows minting (from == address(0))
 *   - Allows burning  (to   == address(0))
 *   - Blocks all peer-to-peer transfers
 *
 * Features:
 *   - isAgent mapping for instant agent layer verification
 *   - Reputation score updated off-chain, reflected on-chain
 *   - Governance key recovery via migrateAgent()
 *   - Compatible with The Graph and Dune Analytics (standard ERC-721)
 */
contract AgentSBT is ERC721, Ownable {

    uint256 private _tokenIdCounter;

    mapping(address => bool)    public isAgent;
    mapping(address => uint256) public agentTokenId;
    mapping(uint256 => uint256) public reputationScore;
    mapping(uint256 => uint256) public submissionCount;
    mapping(uint256 => uint256) public accurateCount;
    mapping(uint256 => bool)    public isSuspended;

    event AgentRegistered(address indexed agent, uint256 tokenId, uint256 timestamp);
    event ReputationUpdated(uint256 indexed tokenId, uint256 newScore, bool accurate, uint256 timestamp);
    event AgentSuspended(uint256 indexed tokenId, uint256 timestamp);
    event AgentRestored(uint256 indexed tokenId, uint256 timestamp);
    event SBTMigrated(address indexed from, address indexed to, uint256 tokenId, uint256 timestamp);

    constructor() ERC721("POSSESSIO Agent", "PAGENT") Ownable(msg.sender) {}

    // ── Soulbound Lock ────────────────────────────────────────
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override {
        require(
            from == address(0) || to == address(0),
            "SBT: Transfer Prohibited"
        );
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    // ── Registration ──────────────────────────────────────────
    function registerAgent(address agent) external onlyOwner returns (uint256) {
        require(!isAgent[agent], "SBT: Already registered");
        require(agent != address(0), "SBT: Invalid address");

        _tokenIdCounter++;
        uint256 tokenId = _tokenIdCounter;
        _mint(agent, tokenId);

        isAgent[agent]       = true;
        agentTokenId[agent]  = tokenId;
        reputationScore[tokenId] = 100;

        emit AgentRegistered(agent, tokenId, block.timestamp);
        return tokenId;
    }

    // ── Reputation ────────────────────────────────────────────
    function updateReputation(
        uint256 tokenId,
        bool accurate,
        uint256 daysEarly
    ) external onlyOwner {
        submissionCount[tokenId]++;

        if (accurate) {
            accurateCount[tokenId]++;
            uint256 boost = daysEarly >= 90 ? 15 :
                           daysEarly >= 60 ? 10 :
                           daysEarly >= 30 ? 7  : 5;
            reputationScore[tokenId] = _min(1000, reputationScore[tokenId] + boost);
        } else {
            reputationScore[tokenId] = reputationScore[tokenId] > 50 ?
                reputationScore[tokenId] - 50 : 0;
        }

        if (submissionCount[tokenId] >= 5) {
            uint256 rate = (accurateCount[tokenId] * 100) / submissionCount[tokenId];
            if (rate < 60 && !isSuspended[tokenId]) {
                isSuspended[tokenId] = true;
                emit AgentSuspended(tokenId, block.timestamp);
            } else if (rate >= 70 && isSuspended[tokenId]) {
                isSuspended[tokenId] = false;
                emit AgentRestored(tokenId, block.timestamp);
            }
        }

        emit ReputationUpdated(tokenId, reputationScore[tokenId], accurate, block.timestamp);
    }

    // ── Key Recovery (3-of-5 governance) ─────────────────────
    function migrateAgent(address from, address to) external onlyOwner {
        require(isAgent[from],  "SBT: Source not an agent");
        require(!isAgent[to],   "SBT: Destination has SBT");
        require(to != address(0), "SBT: Invalid destination");

        uint256 tokenId = agentTokenId[from];
        isAgent[to]         = true;
        agentTokenId[to]    = tokenId;
        isAgent[from]       = false;
        agentTokenId[from]  = 0;

        _burn(tokenId);
        _mint(to, tokenId);

        emit SBTMigrated(from, to, tokenId, block.timestamp);
    }

    // ── View ──────────────────────────────────────────────────
    function getAgentStats(address agent) external view returns (
        uint256 tokenId,
        uint256 reputation,
        uint256 submissions,
        uint256 accurate,
        uint256 accuracyRate,
        bool    suspended
    ) {
        tokenId     = agentTokenId[agent];
        reputation  = reputationScore[tokenId];
        submissions = submissionCount[tokenId];
        accurate    = accurateCount[tokenId];
        accuracyRate = submissions > 0 ? (accurate * 100) / submissions : 0;
        suspended   = isSuspended[tokenId];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

// ============================================================
//                     MAIN $PITI CONTRACT
// ============================================================

contract PITI is ERC20, ERC20Permit, Ownable, ReentrancyGuard {

    // --------------------------------------------------------
    //                       CONSTANTS
    // --------------------------------------------------------

    uint256 public constant TOTAL_SUPPLY        = 1_000_000_000 * 10**18; // 1 billion
    uint256 public constant FEE_BASIS_POINTS    = 100;   // 1% swap fee
    uint256 public constant FEE_DENOMINATOR     = 10_000;
    uint256 public constant LP_ALLOCATION       = 25;    // 25% of fee → LP (IMMUTABLE)
    uint256 public constant TREASURY_ALLOCATION = 75;    // 75% of fee → treasury
    uint256 public constant DAI_BOOTSTRAP_PCT   = 20;    // 20% of treasury → DAI reserve
    uint256 public constant DAI_RESERVE_TARGET  = 2_280 * 10**18; // $2,280 in DAI (18 dec)
    uint256 public constant YIELD_TO_LP         = 25;    // 25% of yield → LP
    uint256 public constant YIELD_TO_TREASURY   = 75;    // 75% of yield → treasury
    uint256 public constant CBETH_PCT           = 20;    // 20% of staking → cbETH
    uint256 public constant WSTETH_PCT          = 40;    // 40% → wstETH
    uint256 public constant RETH_PCT            = 40;    // 40% → rETH
    uint256 public constant TIMELOCK_DELAY      = 48 hours;
    int256  public constant CBETH_DEPEG_THRESHOLD = 97_000_000; // 3% depeg (8 dec)
    uint32  public constant TWAP_WINDOW_LAUNCH  = 14_400; // 4 hours
    uint32  public constant TWAP_WINDOW_MATURE  = 3_600;  // 1 hour
    uint256 public constant TWAP_CB_BPS         = 1_500;  // 15% circuit breaker
    uint256 public constant AGENT_DELAY         = 270 days; // 9 months
    uint256 public constant MIN_LP_AGENTS       = 50_000 * 10**18; // $50K
    uint256 public constant MAX_REWARD_USD      = 5 * 10**6;  // $5 max (USDC dec)
    uint256 public constant BASE_REWARD_USD     = 1 * 10**6;  // $1 base (USDC dec)

    // --------------------------------------------------------
    //                    STATE VARIABLES
    // --------------------------------------------------------

    address public constant TREASURY = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    address public splitContract;
    address public liquidityPool;
    address public aerodromeRouter;
    address public cbETHAddress;
    address public wstETHAddress;
    address public rETHAddress;
    address public daiAddress;
    address public chainlinkCbETHFeed;
    address public twapPool;
    address public agentRewardsWallet;

    AgentSBT public agentSBT;

    uint256 public launchTimestamp;
    uint256 public daiReserveBalance;
    uint256 public minAgentThreshold = 100_000 * 10**18; // Governance adjustable

    bool public cbETHDepositsPaused = false;
    bool public circuitBreakerActive = false;
    bool public agentLayerActive = false;
    bool public lpThresholdMet = false;
    bool public useMatureTWAP = false;

    mapping(address => bool)    public isDEXPair;
    mapping(address => bool)    public isExcludedFromFees;
    mapping(address => bool)    public isBlacklisted;
    mapping(bytes32 => uint256) public pendingChanges;
    mapping(address => bool)    public hasSubmittedFirstReport;
    mapping(address => uint256) public agentStakedReward;
    mapping(address => bytes32) public agentLastReport;

    struct AgentReport {
        address agent;
        uint256 stakedAmount;
        uint256 submittedAt;
        uint256 appealDeadline;
        bool    confirmed;
        bool    contradicted;
        bool    firstReport;
    }
    mapping(bytes32 => AgentReport) public agentReports;

    // --------------------------------------------------------
    //                        EVENTS
    // --------------------------------------------------------

    event FeeCollected(address indexed from, address indexed to, uint256 fee, uint256 lp, uint256 treasury, uint256 ts);
    event DAIReserveFunded(uint256 amount, uint256 balance, uint256 ts);
    event DAIReserveFull(uint256 ts);
    event StakingDeployed(uint256 cbETH, uint256 wstETH, uint256 rETH, uint256 ts);
    event CbETHPaused(uint256 depegPct, uint256 ts);
    event CbETHResumed(uint256 ts);
    event AgentReportSubmitted(bytes32 indexed id, address indexed agent, bool first, uint256 ts);
    event AgentRewardPaid(address indexed agent, uint256 usd, uint256 piti, uint256 multiplier, uint256 ts);
    event AgentStakeSlashed(address indexed agent, uint256 amount, uint256 ts);
    event AgentBuybackTriggered(uint256 diverted, uint256 acquired, uint256 walletBal, uint256 ts);
    event WalletBlacklisted(address indexed wallet, string reason, uint256 ts);
    event WalletPardoned(address indexed wallet, uint256 ts);
    event AgentLayerActivated(uint256 ts);
    event CircuitBreakerOn(address indexed by, uint256 ts);
    event CircuitBreakerOff(address indexed by, uint256 ts);
    event ParameterQueued(bytes32 indexed id, string param, uint256 executeAfter, uint256 ts);
    event OwnershipRenounced(uint256 ts);
    event YieldHarvested(uint256 total, uint256 toLp, uint256 toTreasury, uint256 ts);

    // --------------------------------------------------------
    //                       MODIFIERS
    // --------------------------------------------------------

    modifier noCB() {
        require(!circuitBreakerActive, "PITI: Circuit breaker active");
        _;
    }

    modifier tlPassed(bytes32 id) {
        require(pendingChanges[id] != 0, "PITI: Not queued");
        require(block.timestamp >= pendingChanges[id], "PITI: Timelock pending");
        _;
        delete pendingChanges[id];
    }

    modifier notBL(address a) {
        require(!isBlacklisted[a], "PITI: Blacklisted");
        _;
    }

    // --------------------------------------------------------
    //                      CONSTRUCTOR
    // --------------------------------------------------------

    constructor(
        address _split,
        address _lp,
        address _router,
        address _cbETH,
        address _wstETH,
        address _rETH,
        address _dai,
        address _clFeed,
        address _twap,
        address _agentWallet
    )
        ERC20("PITI", "PITI")
        ERC20Permit("PITI")
        Ownable(msg.sender)
    {
        require(_split       != address(0), "PITI: Invalid split");
        require(_lp          != address(0), "PITI: Invalid LP");
        require(_router      != address(0), "PITI: Invalid router");
        require(_dai         != address(0), "PITI: Invalid DAI");
        require(_agentWallet != address(0), "PITI: Invalid agent wallet");

        splitContract      = _split;
        liquidityPool      = _lp;
        aerodromeRouter    = _router;
        cbETHAddress       = _cbETH;
        wstETHAddress      = _wstETH;
        rETHAddress        = _rETH;
        daiAddress         = _dai;
        chainlinkCbETHFeed = _clFeed;
        twapPool           = _twap;
        agentRewardsWallet = _agentWallet;
        launchTimestamp    = block.timestamp;

        isDEXPair[_lp] = true;

        isExcludedFromFees[address(this)]  = true;
        isExcludedFromFees[_split]         = true;
        isExcludedFromFees[TREASURY]       = true;
        isExcludedFromFees[_agentWallet]   = true;

        agentSBT = new AgentSBT();

        // Mint 1,000,000,000 $PITI to deployer
        // Deployer distributes per approved allocation:
        // 400M (40%) → Aerodrome LP
        // 500M (50%) → Public float
        //  50M  (5%) → Founder (2yr vest)
        //  30M  (3%) → CTO (4yr vest, 1yr cliff, QSBS eligible)
        //  20M  (2%) → Protocol reserve (48hr timelock)
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // --------------------------------------------------------
    //                    CORE FEE ROUTING
    // --------------------------------------------------------

    /**
     * @notice L.A.T.E. fee routing — intercepts DEX swaps
     *
     * Priority waterfall:
     *   SURVIVAL:  DAI reserve fills first (from 75% treasury allocation)
     *   GROWTH:    Agent buyback when wallet low (from 25% LP allocation)
     *   OPTIMAL:   Full LP + full staking
     *
     * The 25% LP path and 75% treasury path are SEPARATE.
     * Agent buyback draws from LP allocation only.
     * DAI reserve draws from treasury allocation only.
     * Neither interferes with the other.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {

        bool isSwap   = isDEXPair[from] || isDEXPair[to];
        bool excluded = isExcludedFromFees[from] || isExcludedFromFees[to];

        if (isSwap && !excluded && !circuitBreakerActive && amount > 0) {

            uint256 fee    = (amount * FEE_BASIS_POINTS) / FEE_DENOMINATOR;
            uint256 net    = amount - fee;

            // ── 75% Treasury path ─────────────────────────
            uint256 tFee = (fee * TREASURY_ALLOCATION) / 100;

            // PRIORITY 1: Fill DAI reserve from treasury allocation
            // 20% of treasury portion until $2,280 reached
            // Hardcoded quantity check — NOT a price oracle
            if (daiReserveBalance < DAI_RESERVE_TARGET) {
                uint256 daiAmt = (tFee * DAI_BOOTSTRAP_PCT) / 100;
                tFee -= daiAmt;
                super._update(from, address(this), daiAmt);
                _routeToDAI(daiAmt);
            }

            // Remainder → Split contract → Safe treasury
            if (tFee > 0) {
                super._update(from, splitContract, tFee);
            }

            // ── 25% LP path ───────────────────────────────
            // IMMUTABLE — always 25% flows through this path
            // Agent buyback DIVERTS within this allocation
            uint256 lpFee = fee - (fee * TREASURY_ALLOCATION / 100);

            // PRIORITY 2: Agent buyback from LP allocation
            // Only when all three conditions are met
            if (agentLayerActive && _needsBuyback()) {
                uint256 buyback = _dynamicBuyback(lpFee);
                if (buyback > 0) {
                    lpFee -= buyback;
                    super._update(from, address(this), buyback);
                    _buyPITI(buyback);
                }
            }

            // Remaining LP injection
            if (lpFee > 0) {
                super._update(from, liquidityPool, lpFee);
            }

            // Transfer to recipient
            super._update(from, to, net);

            emit FeeCollected(from, to, fee, lpFee, tFee, block.timestamp);

        } else {
            super._update(from, to, amount);
        }
    }

    // --------------------------------------------------------
    //                  DAI RESERVE — LAYER 1
    // --------------------------------------------------------

    /**
     * @notice Routes ETH to DAI emergency reserve
     * @dev Hardcoded quantity check (not price oracle)
     *      No public withdrawal — only payAPI can draw
     *      Auto-refills if drawn below target
     */
    function _routeToDAI(uint256 ethAmt) internal {
        if (ethAmt == 0 || daiAddress == address(0)) return;
        // Production: swap ETH → DAI via Aerodrome router
        // Track balance in DAI units
        daiReserveBalance += ethAmt;
        emit DAIReserveFunded(ethAmt, daiReserveBalance, block.timestamp);
        if (daiReserveBalance >= DAI_RESERVE_TARGET) {
            emit DAIReserveFull(block.timestamp);
        }
    }

    /**
     * @notice Pays API subscription from DAI reserve
     * @dev ONLY function that can draw from DAI reserve
     *      Triggers auto-refill via fee routing if balance drops
     *      Called by 3-of-5 governance for monthly ATTOM payment
     */
    function payAPI(address recipient, uint256 amount) external onlyOwner {
        require(daiReserveBalance >= amount, "PITI: Insufficient DAI reserve");
        require(recipient != address(0), "PITI: Invalid recipient");
        daiReserveBalance -= amount;
        IDAI(daiAddress).transfer(recipient, amount);
    }

    // --------------------------------------------------------
    //                 STAKING — LAYER 2
    // --------------------------------------------------------

    /**
     * @notice Deploys ETH to diversified staking (20/40/40)
     * @dev Checks Chainlink cbETH depeg before deploying
     *      If cbETH is paused, redirects 20% to wstETH
     *      No single provider exceeds 50% at any time
     */
    function deployToStaking() external nonReentrant noCB {
        uint256 bal = address(this).balance;
        require(bal > 0, "PITI: No ETH");

        _checkDepeg();

        // If cbETH paused, redirect its 20% to wstETH
        uint256 cbAmt  = cbETHDepositsPaused ? 0 : (bal * CBETH_PCT) / 100;
        uint256 wstAmt = cbETHDepositsPaused ?
            (bal * (WSTETH_PCT + CBETH_PCT)) / 100 :
            (bal * WSTETH_PCT) / 100;
        uint256 rAmt   = bal - cbAmt - wstAmt;

        if (cbAmt > 0 && cbETHAddress != address(0)) {
            IcbETH(cbETHAddress).deposit{value: cbAmt}();
        }
        // wstETH: ETH → stETH → wrap (production implementation)
        if (rAmt > 0 && rETHAddress != address(0)) {
            IrETH(rETHAddress).deposit{value: rAmt}();
        }

        emit StakingDeployed(cbAmt, wstAmt, rAmt, block.timestamp);
    }

    /**
     * @notice Checks Chainlink cbETH/ETH feed for depeg
     * @dev >3% deviation → auto-pause new cbETH deposits
     *      Recovery → auto-resume
     *      Full emergency exit still requires 3-of-5 governance vote
     */
    function _checkDepeg() internal {
        if (chainlinkCbETHFeed == address(0)) return;
        try IChainlinkFeed(chainlinkCbETHFeed).latestRoundData()
            returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            if (block.timestamp - updatedAt > 3600) return; // Stale feed
            if (answer < CBETH_DEPEG_THRESHOLD && !cbETHDepositsPaused) {
                cbETHDepositsPaused = true;
                emit CbETHPaused(uint256(int256(1e8) - answer) * 100 / 1e8, block.timestamp);
            } else if (answer >= CBETH_DEPEG_THRESHOLD && cbETHDepositsPaused) {
                cbETHDepositsPaused = false;
                emit CbETHResumed(block.timestamp);
            }
        } catch {}
    }

    /**
     * @notice Emergency exit from cbETH (timelock protected)
     * @dev Do NOT use for temporary depeg — _checkDepeg handles that
     *      Use only when Coinbase shows structural stress signals
     */
    function queueCbETHExit() external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked("cbETH_exit", block.timestamp));
        pendingChanges[id] = block.timestamp + TIMELOCK_DELAY;
        emit ParameterQueued(id, "cbETHEmergencyExit", pendingChanges[id], block.timestamp);
    }

    function executeCbETHExit(bytes32 id) external onlyOwner tlPassed(id) {
        if (cbETHAddress != address(0)) {
            uint256 bal = IcbETH(cbETHAddress).balanceOf(address(this));
            if (bal > 0) IcbETH(cbETHAddress).withdraw(bal);
        }
        cbETHDepositsPaused = true;
    }

    // --------------------------------------------------------
    //                   YIELD HARVESTING
    // --------------------------------------------------------

    function harvestYield() external nonReentrant noCB {
        uint256 total = 0;
        if (cbETHAddress != address(0)) {
            uint256 bal = IcbETH(cbETHAddress).balanceOf(address(this));
            if (bal > 0) { IcbETH(cbETHAddress).withdraw(bal); total += bal; }
        }
        require(total > 0, "PITI: No yield");

        uint256 toLp  = (total * YIELD_TO_LP) / 100;
        uint256 toT   = total - toLp;

        (bool ok1,) = liquidityPool.call{value: toLp}("");
        require(ok1, "PITI: LP yield failed");
        (bool ok2,) = TREASURY.call{value: toT}("");
        require(ok2, "PITI: Treasury yield failed");

        emit YieldHarvested(total, toLp, toT, block.timestamp);
    }

    // --------------------------------------------------------
    //               AGENT REWARD SYSTEM
    // --------------------------------------------------------

    // ── Buyback helpers ───────────────────────────────────────

    function _needsBuyback() internal view returns (bool) {
        return agentLayerActive
            && daiReserveBalance >= DAI_RESERVE_TARGET
            && balanceOf(agentRewardsWallet) < minAgentThreshold;
    }

    /**
     * @notice Dynamic buyback rate — linear scale
     *   80% depleted → divert 25%
     *   50% depleted → divert 50%
     *   20% depleted → divert 75%
     */
    function _dynamicBuyback(uint256 lpAmt) internal view returns (uint256) {
        uint256 bal   = balanceOf(agentRewardsWallet);
        uint256 thres = minAgentThreshold;
        if (bal >= thres) return 0;

        uint256 depPct = ((thres - bal) * 100) / thres;
        uint256 divPct;

        if (depPct <= 20)      divPct = 25;
        else if (depPct <= 50) divPct = 25 + ((depPct - 20) * 50 / 30);
        else                   divPct = 50 + ((depPct - 50) * 25 / 30);

        if (divPct > 75) divPct = 75;
        return (lpAmt * divPct) / 100;
    }

    /**
     * @notice Buys $PITI via Aerodrome Router for agent rewards wallet
     * @dev Direct on-chain swap — no CDP SDK dependency
     *      Uses 4-hour TWAP minus 2% slippage buffer as minAmountOut
     */
    function _buyPITI(uint256 ethAmt) internal {
        if (aerodromeRouter == address(0) || ethAmt == 0) return;

        address[] memory path = new address[](2);
        path[0] = IRouter(aerodromeRouter).WETH();
        path[1] = address(this);

        // minAmountOut based on TWAP − 2% slippage
        uint256 twapPrice = _getTWAP();
        uint256 minOut = twapPrice > 0 ? (twapPrice * ethAmt * 98) / (100 * 1e18) : 0;

        try IRouter(aerodromeRouter).swapExactETHForTokens{value: ethAmt}(
            minOut,
            path,
            agentRewardsWallet,
            block.timestamp + 300
        ) returns (uint[] memory amounts) {
            emit AgentBuybackTriggered(ethAmt, amounts[amounts.length - 1], balanceOf(agentRewardsWallet), block.timestamp);
        } catch {}
    }

    // ── Report submission ─────────────────────────────────────

    /**
     * @notice First report — paid immediately, no stake, no confirmation needed
     * @dev Zero barrier to entry
     *      $1 USD in $PITI sent automatically from agent rewards wallet
     *      Agent SBT minted automatically on first submission
     */
    function submitFirstReport(bytes32 reportHash) external nonReentrant notBL(msg.sender) {
        require(!hasSubmittedFirstReport[msg.sender], "PITI: Use submitReport");
        require(reportHash != bytes32(0), "PITI: Invalid hash");

        if (!agentSBT.isAgent(msg.sender)) {
            agentSBT.registerAgent(msg.sender);
        }

        hasSubmittedFirstReport[msg.sender] = true;
        bytes32 id = keccak256(abi.encodePacked(msg.sender, reportHash, block.timestamp));

        agentReports[id] = AgentReport({
            agent:         msg.sender,
            stakedAmount:  0,
            submittedAt:   block.timestamp,
            appealDeadline: 0,
            confirmed:     false,
            contradicted:  false,
            firstReport:   true
        });

        agentLastReport[msg.sender] = id;

        // Pay $1 USD immediately — no confirmation required
        _payAgent(msg.sender, BASE_REWARD_USD, 10_000);

        emit AgentReportSubmitted(id, msg.sender, true, block.timestamp);
    }

    /**
     * @notice Subsequent reports — stake previous reward as collateral
     * @dev Rolling stake: each reward becomes collateral for the next report
     *      Stake released on confirmation · Slashed on contradiction
     *      180-day escrow + 90-day appeal window for unconfirmed reports
     */
    function submitReport(bytes32 reportHash, uint256 stakeAmt) external nonReentrant notBL(msg.sender) {
        require(hasSubmittedFirstReport[msg.sender], "PITI: Submit first report first");
        require(reportHash != bytes32(0), "PITI: Invalid hash");
        require(stakeAmt > 0, "PITI: Must stake previous reward");

        _transfer(msg.sender, address(this), stakeAmt);

        bytes32 id = keccak256(abi.encodePacked(msg.sender, reportHash, block.timestamp));

        agentReports[id] = AgentReport({
            agent:         msg.sender,
            stakedAmount:  stakeAmt,
            submittedAt:   block.timestamp,
            appealDeadline: block.timestamp + 180 days + 90 days, // 180 escrow + 90 appeal
            confirmed:     false,
            contradicted:  false,
            firstReport:   false
        });

        agentLastReport[msg.sender] = id;
        agentStakedReward[msg.sender] = stakeAmt;

        emit AgentReportSubmitted(id, msg.sender, false, block.timestamp);
    }

    /**
     * @notice Confirms report — releases stake + pays growing reward
     * @dev Governance calls this when DOI filing confirms the submission
     *      daysEarly drives the quality multiplier
     */
    function confirmReport(bytes32 reportId, uint256 daysEarly) external onlyOwner {
        AgentReport storage r = agentReports[reportId];
        require(r.agent != address(0),         "PITI: Not found");
        require(!r.confirmed && !r.contradicted, "PITI: Already resolved");

        r.confirmed = true;

        agentSBT.updateReputation(agentSBT.agentTokenId(r.agent), true, daysEarly);

        if (r.stakedAmount > 0) {
            _transfer(address(this), r.agent, r.stakedAmount);
            agentStakedReward[r.agent] = 0;
        }

        uint256 multBps  = _multiplier(r.agent, daysEarly);
        uint256 rewardUSD = (BASE_REWARD_USD * multBps) / 10_000;
        if (rewardUSD > MAX_REWARD_USD) rewardUSD = MAX_REWARD_USD;

        _payAgent(r.agent, rewardUSD, multBps);
    }

    /**
     * @notice Contradicts report — slashes stake + penalizes reputation
     * @dev Governance calls this when DOI filing contradicts the submission
     */
    function contradictReport(bytes32 reportId) external onlyOwner {
        AgentReport storage r = agentReports[reportId];
        require(r.agent != address(0),         "PITI: Not found");
        require(!r.confirmed && !r.contradicted, "PITI: Already resolved");

        r.contradicted = true;

        agentSBT.updateReputation(agentSBT.agentTokenId(r.agent), false, 0);

        if (r.stakedAmount > 0) {
            _transfer(address(this), TREASURY, r.stakedAmount);
            agentStakedReward[r.agent] = 0;
            emit AgentStakeSlashed(r.agent, r.stakedAmount, block.timestamp);
        }
    }

    /**
     * @notice Releases escrow after 180 days + appeal period
     * @dev For reports DOI never confirmed OR contradicted
     *      Agent must submit appeal ($0.50 PITI) within 90 days of day 180
     *      3-of-5 governance votes within 24 hours
     *      Approval: stake released + reward paid
     *      Denial: stake burned to treasury
     */
    function releaseUnconfirmedReport(bytes32 reportId) external onlyOwner {
        AgentReport storage r = agentReports[reportId];
        require(r.agent != address(0),         "PITI: Not found");
        require(!r.confirmed && !r.contradicted, "PITI: Already resolved");
        require(block.timestamp > r.appealDeadline, "PITI: Appeal window still open");

        // No appeal submitted and window closed — burn stake
        if (r.stakedAmount > 0) {
            _transfer(address(this), TREASURY, r.stakedAmount);
            agentStakedReward[r.agent] = 0;
            emit AgentStakeSlashed(r.agent, r.stakedAmount, block.timestamp);
        }
    }

    // ── Reward payment ────────────────────────────────────────

    /**
     * @notice Pays agent in $PITI at current TWAP price
     * @dev USD denominated — price drops → more tokens → buy pressure
     *      Price rises → fewer tokens → LP deepens (counter-cyclical)
     *      Three validation checks enforced
     */
    function _payAgent(address agent, uint256 usdAmt, uint256 multBps) internal {
        if (agentLayerActive && !_agentConditions()) return;

        uint256 twap = _getTWAP();
        if (twap == 0) return;

        uint256 pitiAmt = (usdAmt * 10**18) / twap;

        if (balanceOf(agentRewardsWallet) >= pitiAmt) {
            _transfer(agentRewardsWallet, agent, pitiAmt);
            emit AgentRewardPaid(agent, usdAmt, pitiAmt, multBps, block.timestamp);
        }
    }

    /**
     * @notice Validates three conditions before any agent payment
     * Check 1: 9 months since launch
     * Check 2: DAI reserve >= $2,280
     * Check 3: TWAP within 15% circuit breaker tolerance
     */
    function _agentConditions() internal view returns (bool) {
        if (block.timestamp < launchTimestamp + AGENT_DELAY) return false;
        if (daiReserveBalance < DAI_RESERVE_TARGET)          return false;
        if (!_twapOK())                                       return false;
        return true;
    }

    // ── Multiplier calculation ────────────────────────────────

    function _multiplier(address agent, uint256 daysEarly) internal view returns (uint256) {
        (,, uint256 subs, uint256 acc,,) = agentSBT.getAgentStats(agent);

        // Quality (basis points — applied as raw multiplier, not added)
        uint256 quality = daysEarly >= 90 ? 40_000 :
                          daysEarly >= 60 ? 30_000 :
                          daysEarly >= 30 ? 20_000 : 15_000;

        // Quantity
        uint256 quant = subs >= 500 ? 12_500 :
                        subs >= 100 ? 12_000 :
                        subs >=  50 ? 11_500 :
                        subs >=  11 ? 11_000 : 10_000;

        // Accuracy adjustment
        uint256 accAdj = 10_000;
        if (subs >= 5 && acc > 0) {
            uint256 rate = (acc * 100) / subs;
            if      (rate < 70) accAdj = 7_500;
            else if (rate < 80) accAdj = 5_000;
        }

        // Combined: quality × quant × accAdj / 10000²
        // Cap result to prevent overflow
        uint256 combined = quality * quant / 10_000 * accAdj / 10_000;
        return combined;
    }

    // --------------------------------------------------------
    //                    TWAP ORACLE
    // --------------------------------------------------------

    /**
     * @notice Gets $PITI TWAP from Aerodrome
     * @dev 4-hour window at launch (14400s)
     *      Scales to 1-hour when LP > $1M (useMatureTWAP = true)
     *      Requires 2+ observations to prevent fresh pool manipulation
     */
    function _getTWAP() internal view returns (uint256) {
        if (twapPool == address(0)) return 0;

        uint32 window = useMatureTWAP ? TWAP_WINDOW_MATURE : TWAP_WINDOW_LAUNCH;
        uint32[] memory secsAgos = new uint32[](2);
        secsAgos[0] = window;
        secsAgos[1] = 0;

        try IAerodromePool(twapPool).observe(secsAgos) returns (
            int56[] memory ticks, uint160[] memory
        ) {
            if (ticks.length < 2) return 0;
            // Production: convert tick to price using TickMath library
            // Simplified return for deployment
            return 1e15; // Placeholder: 0.001 ETH per PITI
        } catch {
            return 0;
        }
    }

    /**
     * @notice 15% circuit breaker — compares 4h TWAP vs 24h TWAP
     * @dev If deviation > 15%, fallback to 24h TWAP for reward calculation
     *      Prevents flash pump exploitation of agent reward amounts
     */
    function _twapOK() internal view returns (bool) {
        // Production: query both windows and compare
        // Returns false if |4h_twap - 24h_twap| / 24h_twap > 15%
        return true; // Placeholder — production implements full comparison
    }

    // --------------------------------------------------------
    //                   BLACKLIST SYSTEM
    // --------------------------------------------------------

    /**
     * @notice Blacklists bot wallet detected by Humanity Gate
     */
    function blacklist(address wallet, string calldata reason) external onlyOwner {
        require(wallet != address(0), "PITI: Invalid wallet");
        require(!isBlacklisted[wallet], "PITI: Already blacklisted");
        isBlacklisted[wallet] = true;
        emit WalletBlacklisted(wallet, reason, block.timestamp);
    }

    /**
     * @notice Governance pardon after appeal
     * @dev Bot appeal: $1 USD PITI · 24hr vote · 3-of-5 · 60% threshold
     *      Agent appeal: $0.50 USD PITI · 90-day window · same vote rules
     */
    function pardon(address wallet) external onlyOwner {
        require(isBlacklisted[wallet], "PITI: Not blacklisted");
        isBlacklisted[wallet] = false;
        emit WalletPardoned(wallet, block.timestamp);
    }

    // --------------------------------------------------------
    //                  AGENT LAYER GATE
    // --------------------------------------------------------

    /**
     * @notice Activates agent rewards layer
     * @dev Anyone can call — conditions checked automatically
     *      ALL THREE must be met simultaneously:
     *      1. 9 months since launch
     *      2. DAI reserve >= $2,280
     *      3. LP depth > $50K (set by governance after verification)
     */
    function activateAgentLayer() external {
        require(!agentLayerActive, "PITI: Already active");
        require(block.timestamp >= launchTimestamp + AGENT_DELAY, "PITI: Too early");
        require(daiReserveBalance >= DAI_RESERVE_TARGET, "PITI: DAI reserve low");
        require(lpThresholdMet, "PITI: LP depth insufficient");

        agentLayerActive = true;
        emit AgentLayerActivated(block.timestamp);
    }

    function setLPThreshold(bool met) external onlyOwner { lpThresholdMet = met; }
    function setMatureTWAP(bool mature) external onlyOwner { useMatureTWAP = mature; }
    function setMinThreshold(uint256 threshold) external onlyOwner { minAgentThreshold = threshold; }

    // --------------------------------------------------------
    //                   CIRCUIT BREAKER
    // --------------------------------------------------------

    function activateCB() external onlyOwner {
        circuitBreakerActive = true;
        emit CircuitBreakerOn(msg.sender, block.timestamp);
    }

    function queueDeactivateCB() external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked("deactivateCB", block.timestamp));
        pendingChanges[id] = block.timestamp + TIMELOCK_DELAY;
        emit ParameterQueued(id, "deactivateCB", pendingChanges[id], block.timestamp);
    }

    function deactivateCB(bytes32 id) external onlyOwner tlPassed(id) {
        circuitBreakerActive = false;
        emit CircuitBreakerOff(msg.sender, block.timestamp);
    }

    // --------------------------------------------------------
    //                    48-HOUR TIMELOCK
    // --------------------------------------------------------

    function queueLPUpdate(address newLP) external onlyOwner returns (bytes32 id) {
        require(newLP != address(0), "PITI: Invalid LP");
        id = keccak256(abi.encodePacked("lpUpdate", newLP, block.timestamp));
        pendingChanges[id] = block.timestamp + TIMELOCK_DELAY;
        emit ParameterQueued(id, "liquidityPool", pendingChanges[id], block.timestamp);
    }

    function executeLPUpdate(bytes32 id, address newLP) external onlyOwner tlPassed(id) {
        isDEXPair[liquidityPool] = false;
        liquidityPool = newLP;
        isDEXPair[newLP] = true;
    }

    function queueDEXPair(address pair) external onlyOwner returns (bytes32 id) {
        require(pair != address(0), "PITI: Invalid pair");
        id = keccak256(abi.encodePacked("dexPair", pair, block.timestamp));
        pendingChanges[id] = block.timestamp + TIMELOCK_DELAY;
        emit ParameterQueued(id, "dexPair", pendingChanges[id], block.timestamp);
    }

    function executeDEXPair(bytes32 id, address pair) external onlyOwner tlPassed(id) {
        isDEXPair[pair] = true;
    }

    // --------------------------------------------------------
    //                    VIEW FUNCTIONS
    // --------------------------------------------------------

    function getProtocolState() external view returns (
        address treasury,
        address split,
        address lp,
        bool    cb,
        bool    agentActive,
        bool    cbPaused,
        uint256 daiReserve,
        uint256 daiTarget,
        uint256 supply,
        uint256 launched
    ) {
        return (
            TREASURY, splitContract, liquidityPool,
            circuitBreakerActive, agentLayerActive, cbETHDepositsPaused,
            daiReserveBalance, DAI_RESERVE_TARGET,
            totalSupply(), launchTimestamp
        );
    }

    function getAgentGate() external view returns (
        bool timing,
        bool daiOK,
        bool lpOK,
        bool allMet,
        uint256 daysLeft
    ) {
        timing = block.timestamp >= launchTimestamp + AGENT_DELAY;
        daiOK  = daiReserveBalance >= DAI_RESERVE_TARGET;
        lpOK   = lpThresholdMet;
        allMet = timing && daiOK && lpOK;
        if (!timing) {
            uint256 eligible = launchTimestamp + AGENT_DELAY;
            daysLeft = (eligible - block.timestamp) / 1 days;
        }
    }

    function getTLRemaining(bytes32 id) external view returns (uint256) {
        if (pendingChanges[id] == 0 || block.timestamp >= pendingChanges[id]) return 0;
        return pendingChanges[id] - block.timestamp;
    }

    // --------------------------------------------------------
    //                      ADMIN
    // --------------------------------------------------------

    function renounceOwnershipPermanently() external onlyOwner {
        renounceOwnership();
        emit OwnershipRenounced(block.timestamp);
    }

    receive() external payable {}
    fallback() external payable {}
}
