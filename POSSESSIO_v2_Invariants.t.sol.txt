// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ==========================================================================
 *  POSSESSIO_v2_Invariants_t.sol
 *
 *  Council-ratified invariant tests for POSSESSIO_v2-4.sol.
 *
 *  Distinct from:
 *    POSSESSIO_v2_t.sol           -- core unit tests
 *    POSSESSIO_v2_Gauntlet_t.sol  -- adversarial gauntlet tests
 *
 *  Provenance:
 *    Surfaced through line-by-line audit of POSSESSIO_v2.sol
 *    Cross-referenced against existing test surface
 *    Ratified by Architect via council deliberation (April 27, 2026)
 *
 *  Coverage focus:
 *    Anti-poisoning / accumulator integrity
 *    State isolation across slash/pause/route
 *    Rounding boundary semantics in executeInvent
 *    Re-propose timing boundaries
 *    Principal accounting consistency
 *
 *  Each test pins a specific contract behavior. Failure of any test
 *  indicates either a bug in the contract OR a behavior change that
 *  council should ratify before merging.
 * ==========================================================================
 */

import "forge-std/Test.sol";
import {PossessioHook, STEEL} from "../src/POSSESSIO_v2-4.sol";

// Mocks are inlined at the bottom of this file -- see contracts after
// POSSESSIO_v2_Invariants_t. This matches the existing repo convention
// of single-file standalone test suites (no shared test/mocks/ directory).

contract POSSESSIO_v2_Invariants_t is Test {
    // ======================================================================
    //                              FIXTURES
    // ======================================================================

    PossessioHook   hook;
    STEEL           steel;
    MockPoolManager pm;
    MockcbETH       cbeth;
    MockChainlink   cbethFeed;
    MockChainlink   daiFeed;
    MockV3Router    v3Router;
    MockWETH        weth;
    MockERC20       dai;

    address treasury = address(0xCAFE);
    address deployer = address(0xBEEF);

    // Council seats -- match POSSESSIO_v2.sol immutables
    address constant GEMINI  = 0x65841AFCE25f2064C0850c412634A72445a2c4C9;
    address constant CHATGPT = 0xEE9369d614ff97838B870ff3BF236E3f15885314;
    address constant CLAUDE  = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f;
    address constant GROK    = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2;

    address constant DEAD    = 0x000000000000000000000000000000000000dEaD;

    function setUp() public virtual {
        pm        = new MockPoolManager();
        cbeth     = new MockcbETH();
        cbethFeed = new MockChainlink();
        daiFeed   = new MockChainlink();
        v3Router  = new MockV3Router();
        weth      = new MockWETH();
        dai       = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Fresh, valid feed data so depeg / DAI swap paths don't grief setup
        cbethFeed.setRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        daiFeed.setRoundData(1, 0.0005 ether, block.timestamp, block.timestamp, 1);

        steel = new STEEL(deployer);

        address[4] memory council = [GEMINI, CHATGPT, CLAUDE, GROK];

        PossessioHook.DeployParams memory params = PossessioHook.DeployParams({
            deployer:        deployer,
            steel:           address(steel),
            poolManager:     address(pm),
            treasury:        treasury,
            cbETH_:          address(cbeth),
            dai:             address(dai),
            chainlinkCbETH:  address(cbethFeed),
            chainlinkDAI:    address(daiFeed),
            v3Router:        address(v3Router),
            weth:            address(weth),
            council:         council
        });

        vm.prank(deployer);
        hook = new PossessioHook(params);
    }

    // ======================================================================
    //                               HELPERS
    // ======================================================================

    /// @dev Seed the hook with `amount` STEEL via savDeposit, splitting evenly
    ///      across the 4 council seats. Caller assumes deployer holds total supply.
    function _seedSAV(uint256 amount) internal {
        vm.startPrank(deployer);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        steel.transfer(treasury, amount);
        vm.stopPrank();

        vm.startPrank(treasury);
        steel.approve(address(hook), amount);
        hook.savDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Propose `hash` as Gemini, then approve from all 4 seats.
    function _proposeAndApproveAll(bytes32 hash) internal {
        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        vm.prank(GEMINI);
        hook.approveInvent(hash);

        vm.prank(CHATGPT);
        hook.approveInvent(hash);

        vm.prank(CLAUDE);
        hook.approveInvent(hash);

        vm.prank(GROK);
        hook.approveInvent(hash);
    }

    // ======================================================================
    //  P2-INV-9 -- cbETHPrincipal never exceeds actual cbETH balance
    // ======================================================================

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AtSetup() public {
        assertEq(hook.cbETHPrincipal(), 0,                "principal starts at 0");
        assertEq(cbeth.balanceOf(address(hook)), 0,       "balance starts at 0");
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AfterExternalMint()
        public
    {
        cbeth.mint(address(hook), 5 ether);

        assertEq(hook.cbETHPrincipal(),           0);
        assertEq(cbeth.balanceOf(address(hook)),  5 ether);
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AfterMultipleMints()
        public
    {
        cbeth.mint(address(hook), 1 ether);
        cbeth.mint(address(hook), 2 ether);
        cbeth.mint(address(hook), 3 ether);

        assertEq(hook.cbETHPrincipal(),           0);
        assertEq(cbeth.balanceOf(address(hook)),  6 ether);
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    // ======================================================================
    //  P2-INV-10 -- Anti-poisoning: raw ETH never increments accumulatedETH
    // ======================================================================

    function test_Invariant_RawETH_DoesNotPoisonAccumulator_SingleSender() public {
        uint256 before = hook.accumulatedETH();

        address poisoner = address(0xBAD);
        vm.deal(poisoner, 1 ether);
        vm.prank(poisoner);
        (bool ok, ) = address(hook).call{value: 1 ether}("");
        assertTrue(ok, "receive() must accept ETH");

        assertEq(hook.accumulatedETH(), before, "accumulator must not move");
        assertEq(address(hook).balance, 1 ether, "ETH did arrive at hook");
    }

    function test_Invariant_RawETH_DoesNotPoisonAccumulator_MultipleSenders() public {
        uint256 before = hook.accumulatedETH();

        address[3] memory poisoners = [
            address(0xBAD1),
            address(0xBAD2),
            address(0xBAD3)
        ];

        for (uint256 i = 0; i < 3; i++) {
            vm.deal(poisoners[i], 1 ether);
            vm.prank(poisoners[i]);
            (bool ok, ) = address(hook).call{value: 1 ether}("");
            assertTrue(ok);
        }

        assertEq(hook.accumulatedETH(), before, "accumulator must not move");
        assertEq(address(hook).balance, 3 ether, "all 3 ETH arrived");
    }

    function test_Invariant_RawETH_FromTreasury_StillIgnoredForAccounting() public {
        uint256 before = hook.accumulatedETH();

        vm.deal(treasury, 1 ether);
        vm.prank(treasury);
        (bool ok, ) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(hook.accumulatedETH(), before, "Treasury raw send still ignored");
    }

    // ======================================================================
    //  P2-INV-7 -- Slash isolation from routing state
    // ======================================================================

    function test_Invariant_Slash_DoesNotPauseRouting_FromUnpausedState() public {
        _seedSAV(100 ether);

        assertFalse(hook.routingPaused(), "pre: routing not paused");

        vm.prank(treasury);
        hook.savSlash();

        assertTrue(hook.slashed(),         "post: slashed flag set");
        assertFalse(hook.routingPaused(),  "post: routing remains unpaused");
    }

    function test_Invariant_Slash_PreservesPausedState() public {
        _seedSAV(100 ether);

        vm.prank(treasury);
        hook.pauseRouting();
        assertTrue(hook.routingPaused(), "pre: routing paused");

        vm.prank(treasury);
        hook.savSlash();

        assertTrue(hook.routingPaused(),  "post: routing remains paused");
        assertTrue(hook.slashed(),        "post: slashed flag set");
    }

    function test_Invariant_Slash_DoesNotChangeCbETHPaused() public {
        _seedSAV(100 ether);

        bool cbBefore = hook.cbETHPaused();

        vm.prank(treasury);
        hook.savSlash();

        assertEq(hook.cbETHPaused(), cbBefore, "cbETHPaused must not change");
    }

    function test_Invariant_Slash_ZeroesAllClaimablesAtomically() public {
        _seedSAV(100 ether);

        assertGt(hook.claimable(GEMINI),  0);
        assertGt(hook.claimable(CHATGPT), 0);
        assertGt(hook.claimable(CLAUDE),  0);
        assertGt(hook.claimable(GROK),    0);

        vm.prank(treasury);
        hook.savSlash();

        assertEq(hook.claimable(GEMINI),  0);
        assertEq(hook.claimable(CHATGPT), 0);
        assertEq(hook.claimable(CLAUDE),  0);
        assertEq(hook.claimable(GROK),    0);
    }

    // ======================================================================
    //  P2-INV-5 -- executeInvent rounding semantics
    // ======================================================================

    function test_Invariant_ExecuteInvent_FlooringOnAmount7() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p7");
        _proposeAndApproveAll(hash);

        uint256 treasuryBefore = steel.balanceOf(treasury);

        vm.prank(treasury);
        hook.executeInvent(7, hash, "");

        // deductEach = 7/4 = 1; transferAmount = 1 * 4 = 4
        assertEq(steel.balanceOf(treasury) - treasuryBefore, 4);

        uint256 perSeat = (100 ether) / 4 - 1;
        assertEq(hook.claimable(GEMINI),  perSeat);
        assertEq(hook.claimable(CHATGPT), perSeat);
        assertEq(hook.claimable(CLAUDE),  perSeat);
        assertEq(hook.claimable(GROK),    perSeat);
    }

    function test_Invariant_ExecuteInvent_DivisibleAmount_FullTransfer() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p_clean");
        _proposeAndApproveAll(hash);

        uint256 treasuryBefore = steel.balanceOf(treasury);

        uint256 amount = 4 ether;
        vm.prank(treasury);
        hook.executeInvent(amount, hash, "");

        assertEq(steel.balanceOf(treasury) - treasuryBefore, amount);
    }

    function test_Invariant_ExecuteInvent_NoOrphanInClaimables() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p_orphan_check");
        _proposeAndApproveAll(hash);

        vm.prank(treasury);
        hook.executeInvent(13, hash, "");

        uint256 sumClaimable =
            hook.claimable(GEMINI)  +
            hook.claimable(CHATGPT) +
            hook.claimable(CLAUDE)  +
            hook.claimable(GROK);

        uint256 hookSteelBalance = steel.balanceOf(address(hook));

        assertEq(sumClaimable, (100 ether) - 4 * 3);
        assertGe(hookSteelBalance, sumClaimable);
    }

    // ======================================================================
    //  P2-INV-6 -- Re-propose timing boundary
    // ======================================================================

    function test_Invariant_Repropose_RevertsDuringActiveWindow() public {
        bytes32 hash = keccak256("active");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        skip(15 days);

        vm.expectRevert(PossessioHook.ProposalStillActive.selector);
        vm.prank(CHATGPT);
        hook.proposeInvent(hash);
    }

    function test_Invariant_Repropose_AllowedAtExactExpiry() public {
        bytes32 hash = keccak256("at_expiry");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        ( , uint256 expiry, ) = hook.getProposalStatus(hash);

        vm.warp(expiry);

        vm.prank(CHATGPT);
        hook.proposeInvent(hash);

        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 0, "re-propose must clear approvals");
    }

    function test_Invariant_Repropose_AllowedAfterExpiry() public {
        bytes32 hash = keccak256("after_expiry");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        vm.prank(GEMINI);
        hook.approveInvent(hash);

        skip(31 days);

        vm.prank(CHATGPT);
        hook.proposeInvent(hash);

        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 0, "re-propose must clear prior approvals");
    }

    function test_Invariant_Repropose_ClearsApprovalsForAllSeats() public {
        bytes32 hash = keccak256("clear_all");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        vm.prank(GEMINI);
        hook.approveInvent(hash);
        vm.prank(CHATGPT);
        hook.approveInvent(hash);
        vm.prank(CLAUDE);
        hook.approveInvent(hash);

        skip(31 days);

        vm.prank(GROK);
        hook.proposeInvent(hash);

        vm.prank(GEMINI);
        hook.approveInvent(hash);

        vm.prank(CHATGPT);
        hook.approveInvent(hash);

        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 2, "fresh approval cycle after re-propose");
    }
}

// ==========================================================================
//                              INLINE MOCKS
// ==========================================================================

/// @notice Minimal Chainlink AggregatorV3 mock.
contract MockChainlink {
    uint80  private _roundId;
    int256  private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80  private _answeredInRound;

    function setRoundData(
        uint80  roundId_,
        int256  answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80  answeredInRound_
    ) external {
        _roundId         = roundId_;
        _answer          = answer_;
        _startedAt       = startedAt_;
        _updatedAt       = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}

/// @notice Minimal cbETH mock.
contract MockcbETH {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;

    function deposit() external payable {
        _balances[msg.sender] += msg.value;
        _totalSupply          += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "MockcbETH: insufficient");
        _balances[msg.sender] -= amount;
        _totalSupply          -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "MockcbETH: ETH transfer failed");
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply  += amount;
    }

    receive() external payable {}
}

/// @notice Minimal WETH mock.
contract MockWETH {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function deposit() external payable {
        _balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(_balances[msg.sender] >= wad, "MockWETH: insufficient");
        _balances[msg.sender] -= wad;
        (bool ok, ) = msg.sender.call{value: wad}("");
        require(ok, "MockWETH: ETH transfer failed");
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        _allowances[msg.sender][guy] = wad;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(_balances[msg.sender] >= value, "MockWETH: insufficient");
        _balances[msg.sender] -= value;
        _balances[to]         += value;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    receive() external payable {}
}

/// @notice Minimal V3 router mock.
contract MockV3Router {
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
        external payable returns (uint256 amountOut)
    {
        return params.amountOutMinimum;
    }

    receive() external payable {}
}

/// @notice Minimal IPoolManager mock.
contract MockPoolManager {
    // Empty by design.
}

/// @notice Minimal ERC20 mock.
contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name     = name_;
        symbol   = symbol_;
        decimals = decimals_;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "MockERC20: insufficient");
        _balances[msg.sender] -= amount;
        _balances[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "MockERC20: insufficient");
        require(_allowances[from][msg.sender] >= amount, "MockERC20: not approved");
        _balances[from]                  -= amount;
        _balances[to]                    += amount;
        _allowances[from][msg.sender]    -= amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }
}
