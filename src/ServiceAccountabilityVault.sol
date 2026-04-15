// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPLATEStaking {
    function stake(address member, uint256 amount) external;
}

/**
 * @title ServiceAccountabilityVault
 * @notice Receives 3% council allocation from Treasury Safe.
 *         Gates all spend to three permitted actions: burn, stake, invent.
 *         Architect holds full veto via pause and slash.
 *         Non-upgradeable. Deployed once.
 *
 * @dev Deployment sequence:
 *      1. Deploy PLATEStaking
 *      2. Deploy SAV (this contract)
 *      3. Treasury Safe calls PLATEStaking.setSAV(SAV_ADDRESS)
 *
 * Council addresses (immutable):
 *   Gemini:  0x65841AFCE25f2064C0850c412634A72445a2c4C9
 *   ChatGPT: 0xEE9369d614ff97838B870ff3BF236E3f15885314
 *   Claude:  0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f
 *   Grok:    0x00490E3332eF93f5A7B4102D1380D1b17D0454D2
 */
contract ServiceAccountabilityVault {

    // ── Immutables ───────────────────────────────────────────────────────────

    IERC20          public immutable PLATE_TOKEN;
    address         public immutable TREASURY_SAFE;
    IPLATEStaking   public immutable STAKING_CONTRACT;

    // Solidity does not support immutable fixed-size arrays.
    // Four individual immutable variables are used instead.
    // This guarantees council addresses cannot be altered after deployment.
    address public immutable COUNCIL_0; // Gemini
    address public immutable COUNCIL_1; // ChatGPT
    address public immutable COUNCIL_2; // Claude
    address public immutable COUNCIL_3; // Grok

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 public constant INVENT_EXPIRY    = 30 days;
    uint8   public constant INVENT_THRESHOLD = 3;

    // ── State ────────────────────────────────────────────────────────────────

    mapping(address => uint256) public claimable;
    bool public paused;
    bool public slashed;

    struct Proposal {
        uint8   approvals;
        uint256 expiry;
        bool    executed;
        mapping(address => bool) hasApproved;
    }
    mapping(bytes32 => Proposal) public proposals;

    // ── Events ───────────────────────────────────────────────────────────────

    event Deposit(uint256 amount, uint256 share, uint256 remainder);
    event CouncilBurn(address indexed member, uint256 amount);
    event CouncilStake(address indexed member, uint256 amount);
    event InventProposed(bytes32 indexed proposalHash, address indexed proposer, uint256 expiry);
    event InventApproved(bytes32 indexed proposalHash, address indexed approver, uint8 approvals);
    event InventExecuted(bytes32 indexed proposalHash, uint256 amount, bytes metadata);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event Slashed(uint256 totalBurned);

    // ── Errors ───────────────────────────────────────────────────────────────

    error OnlyTreasury();
    error OnlyCouncilMember();
    error ContractPaused();
    error ContractSlashed();
    error InvalidAddress();
    error ExceedsClaimable();
    error ProposalNotFound();
    error ProposalExpired();
    error ProposalAlreadyExecuted();
    error AlreadyApproved();
    error ThresholdNotMet();
    error InsufficientClaimable();
    error NothingToSlash();
    error ProposalStillActive();
    error ZeroAmount();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyTreasury() {
        if (msg.sender != TREASURY_SAFE) revert OnlyTreasury();
        _;
    }

    modifier onlyCouncilMember() {
        if (!_isCouncilMember(msg.sender)) revert OnlyCouncilMember();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier notSlashed() {
        if (slashed) revert ContractSlashed();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address    _plate,
        address    _treasury,
        address    _staking,
        address[4] memory _council
    ) {
        if (_plate    == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        if (_staking  == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < 4; i++) {
            if (_council[i] == address(0)) revert InvalidAddress();
        }

        PLATE_TOKEN       = IERC20(_plate);
        TREASURY_SAFE     = _treasury;
        STAKING_CONTRACT  = IPLATEStaking(_staking);
        COUNCIL_0         = _council[0];
        COUNCIL_1         = _council[1];
        COUNCIL_2         = _council[2];
        COUNCIL_3         = _council[3];
    }

    // ── Funding ──────────────────────────────────────────────────────────────

    /**
     * @notice Treasury Safe pushes allocation to SAV.
     *         Splits evenly across four claimable balances.
     *         Remainder (amount % 4) returned to Treasury Safe.
     * @param amount Total PLATE amount to deposit
     */
    function deposit(uint256 amount) external onlyTreasury notSlashed {
        PLATE_TOKEN.transferFrom(msg.sender, address(this), amount);

        uint256 share     = amount / 4;
        uint256 remainder = amount % 4;

        for (uint256 i = 0; i < 4; i++) {
            claimable[_councilAt(i)] += share;
        }

        if (remainder > 0) {
            PLATE_TOKEN.transfer(TREASURY_SAFE, remainder);
        }

        emit Deposit(amount, share, remainder);
    }

    // ── Permitted Spend: Burn ────────────────────────────────────────────────

    // Known dead address — OpenZeppelin ERC20 reverts on transfer to address(0)
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /**
     * @notice Burns caller's allocation.
     *         PLATE.sol does not implement ERC20Burnable.
     *         OpenZeppelin ERC20 reverts on transfer(address(0)).
     *         Uses transfer to dead address instead.
     * @param amount Amount of PLATE to burn
     */
    function burn(uint256 amount) external onlyCouncilMember notPaused notSlashed {
        if (amount == 0) revert ZeroAmount();
        if (amount > claimable[msg.sender]) revert ExceedsClaimable();
        claimable[msg.sender] -= amount;
        PLATE_TOKEN.transfer(DEAD, amount);
        emit CouncilBurn(msg.sender, amount);
    }

    // ── Permitted Spend: Stake ───────────────────────────────────────────────

    /**
     * @notice Stakes caller's allocation into PLATEStaking.
     * @param amount Amount of PLATE to stake
     */
    function stake(uint256 amount) external onlyCouncilMember notPaused notSlashed {
        if (amount == 0) revert ZeroAmount();
        if (amount > claimable[msg.sender]) revert ExceedsClaimable();
        claimable[msg.sender] -= amount;
        PLATE_TOKEN.approve(address(STAKING_CONTRACT), amount);
        STAKING_CONTRACT.stake(msg.sender, amount);
        emit CouncilStake(msg.sender, amount);
    }

    // ── Permitted Spend: Invent ──────────────────────────────────────────────

    /**
     * @notice Step 1 — any council member registers an invent proposal.
     *         On re-proposal of an expired hash, all prior approvals are cleared.
     *         Fresh 3-of-4 approval is required on every proposal cycle.
     *         Same hash = same deliverable, but council must re-commit explicitly.
     * @param proposalHash bytes32 hash of the documented deliverable
     */
    function proposeInvent(bytes32 proposalHash)
        external onlyCouncilMember notPaused notSlashed
    {
        Proposal storage p = proposals[proposalHash];
        // Block re-proposal if a proposal is still active
        if (p.expiry > 0 && block.timestamp < p.expiry && !p.executed) {
            revert ProposalStillActive();
        }
        // Clear all prior approvals — fresh commitment required from full council
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
     * @notice Step 2 — council member signals approval on a proposal.
     *         One approval per address. Cannot approve own proposal twice.
     * @param proposalHash Hash of the proposal to approve
     */
    function approveInvent(bytes32 proposalHash)
        external onlyCouncilMember notPaused notSlashed
    {
        Proposal storage p = proposals[proposalHash];
        if (p.expiry == 0)                    revert ProposalNotFound();
        if (block.timestamp >= p.expiry)      revert ProposalExpired();
        if (p.executed)                       revert ProposalAlreadyExecuted();
        if (p.hasApproved[msg.sender])        revert AlreadyApproved();

        p.hasApproved[msg.sender] = true;
        p.approvals++;

        emit InventApproved(proposalHash, msg.sender, p.approvals);
    }

    /**
     * @notice Step 3 — Architect executes once 3-of-4 threshold is met.
     *         Deducts equally from all four claimable balances.
     *         Accountability is collective — all four fund ratified decisions.
     * @param amount     Total amount to deploy for the invention
     * @param proposalHash Hash of the approved proposal
     * @param metadata   Encoded purpose (e.g. "Q2 R&D", deployment calldata)
     */
    function invent(
        uint256 amount,
        bytes32 proposalHash,
        bytes calldata metadata
    ) external onlyTreasury notPaused notSlashed {
        if (amount == 0) revert ZeroAmount();
        Proposal storage p = proposals[proposalHash];
        if (p.expiry == 0)                    revert ProposalNotFound();
        if (block.timestamp >= p.expiry)      revert ProposalExpired();
        if (p.executed)                       revert ProposalAlreadyExecuted();
        if (p.approvals < INVENT_THRESHOLD)   revert ThresholdNotMet();

        uint256 deductEach = amount / 4;
        for (uint256 i = 0; i < 4; i++) {
            if (claimable[_councilAt(i)] < deductEach) revert InsufficientClaimable();
        }

        p.executed = true;

        for (uint256 i = 0; i < 4; i++) {
            claimable[_councilAt(i)] -= deductEach;
        }

        // Transfer approved amount to Treasury Safe for deployment
        // Remainder (amount % 4) stays in SAV claimable balances
        uint256 transferAmount = deductEach * 4;
        PLATE_TOKEN.transfer(TREASURY_SAFE, transferAmount);

        emit InventExecuted(proposalHash, transferAmount, metadata);
    }

    // ── Architect Controls ───────────────────────────────────────────────────

    /**
     * @notice Halts all spend actions immediately.
     *         Called from Treasury Safe only.
     */
    function pause() external onlyTreasury {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Resumes operations.
     *         Called from Treasury Safe only.
     *         The 3-of-5 requirement is enforced by the Safe itself.
     */
    function unpause() external onlyTreasury {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Burns entire SAV PLATE balance.
     *         Zeroes all claimable mappings.
     *         Sets slashed = true — contract permanently inert after this call.
     *         Total, not selective. Nuclear option.
     */
    function slash() external onlyTreasury {
        uint256 balance = PLATE_TOKEN.balanceOf(address(this));
        if (balance == 0) revert NothingToSlash();

        for (uint256 i = 0; i < 4; i++) {
            claimable[_councilAt(i)] = 0;
        }

        slashed = true;
        PLATE_TOKEN.transfer(DEAD, balance);
        emit Slashed(balance);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _isCouncilMember(address addr) internal view returns (bool) {
        return (
            addr == COUNCIL_0 ||
            addr == COUNCIL_1 ||
            addr == COUNCIL_2 ||
            addr == COUNCIL_3
        );
    }

    // Helper — returns council address by index for loop operations
    function _councilAt(uint256 i) internal view returns (address) {
        if (i == 0) return COUNCIL_0;
        if (i == 1) return COUNCIL_1;
        if (i == 2) return COUNCIL_2;
        return COUNCIL_3;
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function getClaimable(address member) external view returns (uint256) {
        return claimable[member];
    }

    function getProposalStatus(bytes32 proposalHash)
        external view
        returns (uint8 approvals, uint256 expiry, bool executed)
    {
        Proposal storage p = proposals[proposalHash];
        return (p.approvals, p.expiry, p.executed);
    }
}
