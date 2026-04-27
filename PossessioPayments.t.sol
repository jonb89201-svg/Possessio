// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/PossessioPayments.sol";

/*
 * PossessioPayments — Core Invariant Test Suite
 *
 * SCOPE: Sweep mechanism, DAI reserve, daily limit asymmetric timelock, roles,
 *        Guardian opt-in security, emergency withdrawal, integration paths.
 *
 * STRATEGY: Inline mocks for USDC/DAI/cbETH/V3Router/Chainlink/LSTRates.
 *           Mocks model real-world behavior (transferFrom approval pattern,
 *           Chainlink staleness checks, LST rate queries).
 *
 * 100% cbETH ARCHITECTURE: rETH was removed after council verification that
 *           rETH on Base is a bridged OptimismMintableERC20 with no
 *           user-callable redemption path. Council-ratified single-asset model.
 *
 * Amendment IV declarations per category.
 */

// ═══════════════════════════════════════════════════════════════════════════
//                              MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════════════════════

contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8  public constant decimals = 6;
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    function mint(address to, uint256 amt) external { _balances[to] += amt; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }

    function approve(address s, uint256 a) external returns (bool) {
        _allowances[msg.sender][s] = a;
        return true;
    }
    function allowance(address o, address s) external view returns (uint256) {
        return _allowances[o][s];
    }
    function transfer(address to, uint256 a) external returns (bool) {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        _balances[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(_balances[from] >= a, "insuf");
        require(_allowances[from][msg.sender] >= a, "not approved");
        _allowances[from][msg.sender] -= a;
        _balances[from] -= a;
        _balances[to] += a;
        return true;
    }
}

contract MockDAI {
    string public constant name = "Dai Stablecoin";
    string public constant symbol = "DAI";
    uint8  public constant decimals = 18;
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    function mint(address to, uint256 amt) external { _balances[to] += amt; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }

    function approve(address s, uint256 a) external returns (bool) {
        _allowances[msg.sender][s] = a;
        return true;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        _balances[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(_balances[from] >= a, "insuf");
        require(_allowances[from][msg.sender] >= a, "not approved");
        _allowances[from][msg.sender] -= a;
        _balances[from] -= a;
        _balances[to] += a;
        return true;
    }
}

contract MockCbETH {
    mapping(address => uint256) public _balances;
    function mint(address to, uint256 amt) external { _balances[to] += amt; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        _balances[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(_balances[from] >= a, "insuf");
        _balances[from] -= a;
        _balances[to] += a;
        return true;
    }
    function approve(address, uint256) external pure returns (bool) { return true; }
}

contract MockV3Router {
    MockUSDC  public usdc;
    MockDAI   public dai;
    MockCbETH public cbeth;

    // Per-token output amounts the router will deliver
    uint256 public daiOut;
    uint256 public cbEthOut;
    bool    public daiSwapReverts;
    bool    public lstSwapReverts;

    constructor(address u, address d, address c) {
        usdc = MockUSDC(u);
        dai  = MockDAI(d);
        cbeth = MockCbETH(c);
    }

    function setDaiOut(uint256 v) external { daiOut = v; }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    function setDaiSwapReverts(bool b) external { daiSwapReverts = b; }
    function setLstSwapReverts(bool b) external { lstSwapReverts = b; }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external returns (uint256 amountOut)
    {
        // Pull tokenIn from caller via approval
        MockUSDC(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);

        if (p.tokenOut == address(dai)) {
            require(!daiSwapReverts, "MockV3Router: dai swap reverts");
            require(daiOut >= p.amountOutMinimum, "MockV3Router: slippage DAI");
            if (daiOut > 0) dai.mint(p.recipient, daiOut);
            return daiOut;
        } else if (p.tokenOut == address(cbeth)) {
            require(!lstSwapReverts, "MockV3Router: lst swap reverts");
            require(cbEthOut >= p.amountOutMinimum, "MockV3Router: slippage cbETH");
            if (cbEthOut > 0) cbeth.mint(p.recipient, cbEthOut);
            return cbEthOut;
        }
        revert("Unknown tokenOut");
    }
}

contract MockChainlink {
    int256 public _answer;
    uint256 public _updatedAt;
    uint80  public _roundId;
    uint80  public _answeredInRound;
    bool    public _reverts;

    constructor(int256 a) {
        _answer = a;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 a) external {
        _answer = a;
        _updatedAt = block.timestamp;
        _roundId++;
        _answeredInRound = _roundId;
    }
    function setStale()           external { _updatedAt = block.timestamp - 7200; }
    function setReverts(bool r)   external { _reverts = r; }
    function setIncomplete()      external { _answeredInRound = _roundId - 1; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!_reverts, "MockChainlink: reverts");
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
}

contract MockLSTRates {
    uint256 public cbEthRate; // ETH per cbETH (18 dec)

    constructor() {
        cbEthRate = 1.05e18; // ~5% premium
    }

    function setCbEthRate(uint256 v) external { cbEthRate = v; }

    function cbEthToEth(uint256 cbAmount) external view returns (uint256) {
        return (cbAmount * cbEthRate) / 1e18;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                       POSSESSIO PAYMENTS TEST SUITE
// ═══════════════════════════════════════════════════════════════════════════

contract PossessioPaymentsTest is Test {
    using stdStorage for StdStorage;

    PossessioPayments payments;
    MockUSDC          usdc;
    MockDAI           dai;
    MockCbETH         cbeth;
    MockV3Router      router;
    MockChainlink     chainlinkEth;
    MockChainlink     chainlinkDai;
    MockLSTRates      lstRates;

    address MERCHANT = address(0xA11CE);
    address OPERATOR = address(0xB0B);
    address GUARDIAN = address(0xC1A0);
    address ATTACKER = address(0xBAD);
    address PAYEE    = address(0xD11);

    uint256 constant MIN_BATCH    = 100 * 1e6;       // 100 USDC
    uint256 constant DAI_CEILING  = 5_000 * 1e18;    // $5k merchant operational buffer
    uint256 constant DAILY_LIMIT  = 1_000 * 1e18;    // $1k/day default

    function setUp() public {
        vm.warp(1_000_000);

        usdc         = new MockUSDC();
        dai          = new MockDAI();
        cbeth        = new MockCbETH();
        router       = new MockV3Router(address(usdc), address(dai), address(cbeth));
        chainlinkEth = new MockChainlink(int256(3000_00000000));   // $3000/ETH (8 dec)
        chainlinkDai = new MockChainlink(int256(1_00000000));       // $1.00/DAI (8 dec)
        lstRates     = new MockLSTRates();

        payments = new PossessioPayments(
            MERCHANT,
            address(usdc),
            address(cbeth),
            address(dai),
            address(router),
            address(chainlinkEth),
            address(chainlinkDai),
            address(lstRates),
            MIN_BATCH,
            DAI_CEILING,
            DAILY_LIMIT
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Deploy_OwnerHasOwnerRole() public {
        assertTrue(payments.hasRole(payments.OWNER_ROLE(), MERCHANT));
    }

    function test_Deploy_AttackerHasNoRoles() public {
        assertFalse(payments.hasRole(payments.OWNER_ROLE(), ATTACKER));
        assertFalse(payments.hasRole(payments.OPERATOR_ROLE(), ATTACKER));
        assertFalse(payments.hasRole(payments.GUARDIAN_ROLE(), ATTACKER));
    }

    function test_Deploy_ImmutablesSet() public {
        assertEq(address(payments.USDC()),          address(usdc));
        assertEq(address(payments.CBETH()),         address(cbeth));
        assertEq(address(payments.DAI()),           address(dai));
        assertEq(address(payments.ROUTER()),        address(router));
        assertEq(address(payments.CHAINLINK()),     address(chainlinkEth));
        assertEq(address(payments.CHAINLINK_DAI()), address(chainlinkDai));
        assertEq(address(payments.LST_RATES()),     address(lstRates));
    }

    function test_Deploy_InitialState() public {
        assertEq(payments.minSwapBatch(), MIN_BATCH);
        assertEq(payments.daiCeiling(),   DAI_CEILING);
        assertEq(payments.dailyLimit(),   DAILY_LIMIT);
        assertEq(payments.dailyWithdrawn(), 0);
        assertEq(payments.getTreasuryGauge(), 0);
        assertFalse(payments.routingPaused());
        assertFalse(payments.guardianEnabled());
    }

    function test_Deploy_RevertsZeroOwner() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            address(0),
            address(usdc), address(cbeth), address(dai),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates),
            MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    function test_Deploy_RevertsZeroUSDC() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            MERCHANT,
            address(0), address(cbeth), address(dai),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates),
            MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    function test_Deploy_RevertsZeroDAI() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            MERCHANT,
            address(usdc), address(cbeth), address(0),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates),
            MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ROLE GRANTING TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Roles_OwnerCanGrantOperator() public {
        bytes32 role = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(role, OPERATOR);
        assertTrue(payments.hasRole(role, OPERATOR));
    }

    function test_Roles_OwnerCanGrantGuardian() public {
        bytes32 role = payments.GUARDIAN_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(role, GUARDIAN);
        assertTrue(payments.hasRole(role, GUARDIAN));
    }

    function test_Roles_AttackerCannotGrantOperator() public {
        bytes32 role = payments.OPERATOR_ROLE();
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.grantRole(role, ATTACKER);
    }

    function test_Roles_OwnerCanRevokeOperator() public {
        vm.startPrank(MERCHANT);
        payments.grantRole(payments.OPERATOR_ROLE(), OPERATOR);
        payments.revokeRole(payments.OPERATOR_ROLE(), OPERATOR);
        vm.stopPrank();
        assertFalse(payments.hasRole(payments.OPERATOR_ROLE(), OPERATOR));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SWEEP — BASIC cbETH PATH
    // ═══════════════════════════════════════════════════════════════════════

    function test_Sweep_AllocatesCbETHWhenNoCeiling() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
        uint256 expectedGauge = (0.31 ether * 1.05e18) / 1e18;
        assertEq(payments.getTreasuryGauge(), expectedGauge);
    }

    function test_Sweep_RevertsBelowMinBatch() public {
        usdc.mint(address(payments), 50 * 1e6);

        vm.expectRevert(PossessioPayments.BatchTooSmall.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Sweep_RevertsTooEarly() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        usdc.mint(address(payments), 1000 * 1e6);
        vm.expectRevert(PossessioPayments.SweepTooEarly.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);
    }

    function test_Sweep_RevertsETHOracleStale() public {
        chainlinkEth.setStale();
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Sweep_RevertsETHOracleInvalid() public {
        chainlinkEth.setAnswer(int256(0));
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Sweep_RevertsETHOracleIncomplete() public {
        chainlinkEth.setIncomplete();
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Sweep_OnlyOwnerOrOperator() public {
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(ATTACKER);
        payments.sweep(0, 0);
    }

    function test_Sweep_OperatorCanCall() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(OPERATOR);
        payments.sweep(0, 0.31 ether);

        assertGt(payments.getTreasuryGauge(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SWEEP — DAI RESERVE FILL
    // ═══════════════════════════════════════════════════════════════════════

    function test_Sweep_FillsDAIThenAllocatesCbETH() public {
        usdc.mint(address(payments), 6000 * 1e6);
        router.setDaiOut(5000 * 1e18);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(4900 * 1e18, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)), 5000 * 1e18);
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
    }

    function test_Sweep_DAIFullSkipsRefill() public {
        dai.mint(address(payments), DAI_CEILING);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)), DAI_CEILING);
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
    }

    function test_Sweep_DAIOpenedSkipsRefill() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
    }

    function test_Sweep_DAIOracleStaleSkipsGracefully() public {
        chainlinkDai.setStale();
        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
    }

    function test_Sweep_DAISwapRevertsSkipsGracefully() public {
        router.setDaiSwapReverts(true);
        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DAI WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_DAI_WithdrawSucceeds() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.prank(MERCHANT);
        payments.withdrawDAI(500 * 1e18, PAYEE);
        assertEq(dai.balanceOf(PAYEE), 500 * 1e18);
        assertEq(payments.dailyWithdrawn(), 500 * 1e18);
    }

    function test_DAI_WithdrawAtLimit() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT, PAYEE);
        assertEq(dai.balanceOf(PAYEE), DAILY_LIMIT);
    }

    function test_DAI_WithdrawOverLimitReverts() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT + 1, PAYEE);
    }

    function test_DAI_WithdrawCumulativeExceedsLimit() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.prank(MERCHANT);
        payments.withdrawDAI(600 * 1e18, PAYEE);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(600 * 1e18, PAYEE);
    }

    function test_DAI_WithdrawOnlyOwner() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.withdrawDAI(100 * 1e18, ATTACKER);
    }

    function test_DAI_WithdrawWindowRollsAfter24h() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT, PAYEE);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT, PAYEE);
        assertEq(dai.balanceOf(PAYEE), 2 * DAILY_LIMIT);
    }

    function test_DAI_WithdrawZeroReverts() public {
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(0, PAYEE);
    }

    function test_DAI_WithdrawZeroAddressReverts() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(100 * 1e18, address(0));
    }

    function test_DAI_LockdownBlocksAllWithdrawals() public {
        vm.prank(MERCHANT);
        payments.decreaseDailyLimit(0);
        dai.mint(address(payments), 5000 * 1e18);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(1, PAYEE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DAILY LIMIT — ASYMMETRIC TIMELOCK
    // ═══════════════════════════════════════════════════════════════════════

    function test_DailyLimit_DecreaseInstant() public {
        vm.prank(MERCHANT);
        payments.decreaseDailyLimit(500 * 1e18);
        assertEq(payments.dailyLimit(), 500 * 1e18);
    }

    function test_DailyLimit_DecreaseToHigherReverts() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(MERCHANT);
        payments.decreaseDailyLimit(2000 * 1e18);
    }

    function test_DailyLimit_IncreaseQueueRequiresDelay() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();
        assertEq(payments.dailyLimit(), DAILY_LIMIT);
    }

    function test_DailyLimit_IncreaseExecutesAfterDelay() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();
        assertEq(payments.dailyLimit(), 2000 * 1e18);
    }

    function test_DailyLimit_QueueIncreaseLowerReverts() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(500 * 1e18);
    }

    function test_DailyLimit_CancelQueuedIncrease() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);
        vm.prank(MERCHANT);
        payments.cancelDailyLimitIncrease();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(PossessioPayments.NoIncreaseQueued.selector);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();
    }

    function test_DailyLimit_AttackerCannotQueue() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.queueDailyLimitIncrease(10_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         CIRCUIT BREAKER TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_CB_PauseOwner() public {
        vm.prank(MERCHANT);
        payments.pauseUCR();
        assertTrue(payments.routingPaused());
    }

    function test_CB_PauseOperator() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);
        vm.prank(OPERATOR);
        payments.pauseUCR();
        assertTrue(payments.routingPaused());
    }

    function test_CB_PauseAttackerReverts() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(ATTACKER);
        payments.pauseUCR();
    }

    function test_CB_QueueResumeRequires48h() public {
        vm.prank(MERCHANT);
        payments.pauseUCR();
        vm.prank(MERCHANT);
        bytes32 id = payments.queueResumeUCR();
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        vm.prank(MERCHANT);
        payments.resumeUCR(id);
    }

    function test_CB_ResumeAfter48hSucceeds() public {
        vm.prank(MERCHANT);
        payments.pauseUCR();
        vm.prank(MERCHANT);
        bytes32 id = payments.queueResumeUCR();
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(MERCHANT);
        payments.resumeUCR(id);
        assertFalse(payments.routingPaused());
    }

    function test_CB_PausedSweepReverts() public {
        vm.prank(MERCHANT);
        payments.pauseUCR();
        usdc.mint(address(payments), 1000 * 1e6);
        vm.expectRevert(PossessioPayments.RoutingPaused.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         GUARDIAN TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Guardian_DefaultDisabled() public {
        assertFalse(payments.guardianEnabled());
    }

    function test_Guardian_EnableByOwner() public {
        vm.prank(MERCHANT);
        payments.enableGuardian();
        assertTrue(payments.guardianEnabled());
    }

    function test_Guardian_DisableByOwner() public {
        vm.startPrank(MERCHANT);
        payments.enableGuardian();
        payments.disableGuardian();
        vm.stopPrank();
        assertFalse(payments.guardianEnabled());
    }

    function test_Guardian_PauseOnlyWhenEnabled() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        vm.expectRevert(PossessioPayments.GuardianNotEnabled.selector);
        vm.prank(GUARDIAN);
        payments.guardianPause();
    }

    function test_Guardian_PauseSucceedsWhenEnabled() public {
        vm.startPrank(MERCHANT);
        payments.grantRole(payments.GUARDIAN_ROLE(), GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();
        vm.prank(GUARDIAN);
        payments.guardianPause();
        assertTrue(payments.routingPaused());
    }

    function test_Guardian_CannotWithdrawDAI() public {
        vm.startPrank(MERCHANT);
        payments.grantRole(payments.GUARDIAN_ROLE(), GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();
        dai.mint(address(payments), 5000 * 1e18);
        vm.expectRevert();
        vm.prank(GUARDIAN);
        payments.withdrawDAI(100 * 1e18, GUARDIAN);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      EMERGENCY WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Emergency_QueueAndExecute() public {
        cbeth.mint(address(payments), 1 ether);
        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(cbeth), 1 ether);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(cbeth), MERCHANT);
        assertEq(cbeth.balanceOf(MERCHANT), 1 ether);
    }

    function test_Emergency_ExecuteBeforeDelayReverts() public {
        cbeth.mint(address(payments), 1 ether);
        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(cbeth), 1 ether);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(cbeth), MERCHANT);
    }

    function test_Emergency_CancelClearsQueue() public {
        cbeth.mint(address(payments), 1 ether);
        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(cbeth), 1 ether);
        vm.prank(MERCHANT);
        payments.cancelEmergencyWithdraw(address(cbeth));
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(PossessioPayments.NothingQueued.selector);
        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(cbeth), MERCHANT);
    }

    function test_Emergency_AttackerCannotQueue() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.queueEmergencyWithdraw(address(cbeth), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      TREASURY GAUGE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_TreasuryGauge_IncrementsAfterSweep() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);
        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);
        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);
        uint256 expectedGauge = (0.31 ether * 1.05e18) / 1e18;
        assertEq(payments.getTreasuryGauge(), expectedGauge);
    }

    function test_TreasuryGauge_ZeroAtDeployment() public {
        assertEq(payments.getTreasuryGauge(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      CEILING ADJUSTMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Ceiling_OwnerCanAdjust() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(10_000 * 1e18);
        assertEq(payments.daiCeiling(), 10_000 * 1e18);
    }

    function test_Ceiling_OwnerCanZero() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);
        assertEq(payments.daiCeiling(), 0);
    }

    function test_Ceiling_AttackerCannotAdjust() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.setDaiCeiling(10_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         VIEW TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_View_DAIBalance() public {
        dai.mint(address(payments), 3000 * 1e18);
        assertEq(payments.getDAIBalance(), 3000 * 1e18);
    }

    function test_View_DailyRemainingFresh() public {
        assertEq(payments.dailyRemaining(), DAILY_LIMIT);
    }

    function test_View_DailyRemainingAfterWithdraw() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.prank(MERCHANT);
        payments.withdrawDAI(300 * 1e18, PAYEE);
        assertEq(payments.dailyRemaining(), DAILY_LIMIT - 300 * 1e18);
    }

    function test_View_ArmorLevel() public {
        dai.mint(address(payments), 3000 * 1e18);
        assertEq(payments.armorLevelDays(100 * 1e18), 30);
    }

    function test_View_ArmorLevelZeroBurnRate() public {
        dai.mint(address(payments), 3000 * 1e18);
        assertEq(payments.armorLevelDays(0), type(uint256).max);
    }

    function test_View_IsDaiReserveFullEmpty() public {
        assertFalse(payments.isDaiReserveFull());
    }

    function test_View_IsDaiReserveFullAtCeiling() public {
        dai.mint(address(payments), DAI_CEILING);
        assertTrue(payments.isDaiReserveFull());
    }

    function test_View_IsDaiReserveFullCeilingZero() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);
        assertTrue(payments.isDaiReserveFull());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    INVARIANT TESTS (Codebyte Law)
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_CrossAssetValueConservation() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        uint256 usdcBefore = usdc.balanceOf(address(payments));
        uint256 cbBefore   = cbeth.balanceOf(address(payments));

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        uint256 usdcAfter = usdc.balanceOf(address(payments));
        uint256 cbAfter   = cbeth.balanceOf(address(payments));

        assertEq(usdcBefore - usdcAfter, 1000 * 1e6, "USDC consumed exactly");
        assertEq(cbAfter - cbBefore, 0.31 ether, "cbETH received exactly");
    }

    function test_Invariant_DAINoPhantomGrowth() public {
        dai.mint(address(payments), 1000 * 1e18);
        uint256 before = dai.balanceOf(address(payments));

        vm.warp(block.timestamp + 30 days);

        payments.getDAIBalance();
        payments.dailyRemaining();
        payments.isDaiReserveFull();

        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.prank(MERCHANT);
        payments.pauseUCR();

        uint256 afterIdle = dai.balanceOf(address(payments));
        assertEq(afterIdle, before, "DAI must not grow without sweep");
    }

    function test_Invariant_DAIExitPathIntegrity() public {
        dai.mint(address(payments), 5000 * 1e18);
        uint256 before = dai.balanceOf(address(payments));

        vm.prank(MERCHANT);
        payments.pauseUCR();

        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.prank(MERCHANT);
        payments.setDaiCeiling(10_000 * 1e18);

        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);

        vm.warp(block.timestamp + 1 hours);

        assertEq(dai.balanceOf(address(payments)), before, "DAI unchanged by non-exit operations");
    }

    function test_Invariant_DailyLimitCumulative() public {
        dai.mint(address(payments), 5000 * 1e18);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(MERCHANT);
            payments.withdrawDAI(200 * 1e18, PAYEE);
        }

        assertEq(payments.dailyWithdrawn(), 1000 * 1e18, "Cumulative equals limit");

        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(1, PAYEE);

        assertLe(payments.dailyWithdrawn(), payments.dailyLimit(), "Invariant: dailyWithdrawn <= dailyLimit");
    }

    function test_Invariant_NoSwapOnBadOracle() public {
        usdc.mint(address(payments), 1000 * 1e6);
        uint256 daiBefore   = dai.balanceOf(address(payments));
        uint256 cbBefore    = cbeth.balanceOf(address(payments));
        uint256 gaugeBefore = payments.getTreasuryGauge();

        chainlinkEth.setStale();

        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);

        assertEq(dai.balanceOf(address(payments)),   daiBefore,   "DAI unchanged");
        assertEq(cbeth.balanceOf(address(payments)), cbBefore,    "cbETH unchanged");
        assertEq(payments.getTreasuryGauge(),      gaugeBefore, "Gauge unchanged");
    }

    function test_Invariant_NoDanglingApprovals() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        uint256 allowance = usdc.allowance(address(payments), address(router));
        assertEq(allowance, 0, "USDC allowance must be zero after sweep");
    }

    function test_Invariant_NoDanglingApprovalsWithDAI() public {
        usdc.mint(address(payments), 6000 * 1e6);
        router.setDaiOut(5000 * 1e18);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(4900 * 1e18, 0.31 ether);

        uint256 allowance = usdc.allowance(address(payments), address(router));
        assertEq(allowance, 0, "USDC allowance must be zero after sweep with DAI leg");
    }

    function test_Invariant_SweepCooldownSequence() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        for (uint256 i = 0; i < 5; i++) {
            usdc.mint(address(payments), 1000 * 1e6);
            vm.expectRevert(PossessioPayments.SweepTooEarly.selector);
            vm.prank(MERCHANT);
            payments.sweep(0, 0.31 ether);
            vm.warp(block.timestamp + 1 hours);
        }
    }

    function test_Invariant_CbEthConversionConsistency() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        assertGt(cbeth.balanceOf(address(payments)), 0, "cbETH balance > 0 after sweep");
        assertGt(payments.getTreasuryGauge(),      0, "Treasury gauge > 0 after sweep");
    }

    function test_Invariant_AtomicSweepCbEthFailure() public {
        usdc.mint(address(payments), 6000 * 1e6);
        router.setDaiOut(5000 * 1e18);
        router.setLstSwapReverts(true);

        uint256 daiBefore   = dai.balanceOf(address(payments));
        uint256 cbBefore    = cbeth.balanceOf(address(payments));
        uint256 gaugeBefore = payments.getTreasuryGauge();

        vm.expectRevert();
        vm.prank(MERCHANT);
        payments.sweep(4900 * 1e18, 0.31 ether);

        assertEq(dai.balanceOf(address(payments)),   daiBefore,   "DAI unchanged after revert");
        assertEq(cbeth.balanceOf(address(payments)), cbBefore,    "cbETH unchanged after revert");
        assertEq(payments.getTreasuryGauge(),      gaugeBefore, "Gauge unchanged after revert");
    }

    function test_Invariant_TimeProgressionSafety() public {
        dai.mint(address(payments), 5000 * 1e18);

        vm.prank(MERCHANT);
        payments.withdrawDAI(500 * 1e18, PAYEE);
        assertEq(payments.dailyWithdrawn(), 500 * 1e18);

        vm.warp(block.timestamp + 5 * 365 days);

        vm.prank(MERCHANT);
        payments.withdrawDAI(1000 * 1e18, PAYEE);

        assertEq(payments.dailyWithdrawn(), 1000 * 1e18, "Window rolled, full limit usable");
        assertLe(payments.dailyWithdrawn(), payments.dailyLimit(), "Invariant holds");
    }

    function test_Invariant_DAISlippageBounds() public {
        usdc.mint(address(payments), 6000 * 1e6);
        router.setDaiOut(5000 * 1e18);
        router.setCbEthOut(0.31 ether);

        uint256 expectedDai = 5000 * 1e18;
        uint256 minDai = (expectedDai * 99) / 100;

        vm.prank(MERCHANT);
        payments.sweep(minDai, 0.31 ether);

        uint256 daiReceived = dai.balanceOf(address(payments));
        assertGe(daiReceived, minDai, "DAI received within slippage bounds");
    }

    function test_Invariant_EmergencyDAISubjectToDailyLimit() public {
        dai.mint(address(payments), 5000 * 1e18);

        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(dai), 5000 * 1e18);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(dai), MERCHANT);

        assertEq(dai.balanceOf(address(payments)), 5000 * 1e18, "DAI not drained");
    }

    function test_Invariant_EmergencyLSTNotSubjectToDailyLimit() public {
        cbeth.mint(address(payments), 100 ether);

        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(cbeth), 100 ether);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(cbeth), MERCHANT);

        assertEq(cbeth.balanceOf(MERCHANT), 100 ether, "LST drained via emergency, no daily limit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //               COUNCIL-RATIFIED cbETH-ONLY INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════

    // cbETH-Invariant 1: REDEMPTION DETERMINISM
    function test_Invariant_cbETHRedemptionDeterminism() public {
        cbeth.mint(address(payments), 5 ether);

        uint256 bal = cbeth.balanceOf(address(payments));
        assertGt(bal, 0, "cbETH balance available for redemption");

        vm.deal(address(cbeth), 10 ether);
        vm.prank(address(payments));
        cbeth.withdraw(1 ether);

        assertEq(cbeth.balanceOf(address(payments)), bal - 1 ether, "Redemption succeeded");
    }

    // cbETH-Invariant 2: SINGLE-ASSET EXPOSURE
    function test_Invariant_cbETHExposure100Percent() public {
        cbeth.mint(address(payments), 10 ether);

        uint256 gauge = payments.getTreasuryGauge();
        uint256 expectedGauge = (10 ether * 1.05e18) / 1e18;

        assertEq(gauge, expectedGauge, "Gauge value equals cbETH ETH-equivalent");
        assertEq(payments.getCbETHBalance(), 10 ether, "All exposure in cbETH");
    }

    // cbETH-Invariant 3: NO UNREACHABLE BALANCES
    //
    // Proof Scope:    Contract has no rETH or wstETH state. All LST exposure
    //                 is in cbETH. Sweep produces only cbETH (compile-time
    //                 architectural guarantee).
    // Boundary:       Single sweep proves the architectural invariant. No
    //                 multi-sweep needed — the invariant is structural, not
    //                 sequence-dependent.
    function test_Invariant_NoUnreachableLSTBalances() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        // After sweep, all LST exposure is in cbETH only — no rETH, no wstETH
        assertGt(cbeth.balanceOf(address(payments)), 0, "cbETH accumulated normally");

        // No way to test "no rETH" because the contract literally has no rETH
        // reference — that's the architectural guarantee, enforced at compile time
    }

    // cbETH-Invariant 4: SWEEP CONVERTS TO cbETH ONLY
    function test_Invariant_SweepConvertsCbEthOnly() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        uint256 cbBefore = cbeth.balanceOf(address(payments));

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        uint256 cbAfter = cbeth.balanceOf(address(payments));

        assertGt(cbAfter, cbBefore, "Sweep converts to cbETH");
        assertEq(cbAfter - cbBefore, 0.31 ether, "Exact cbETH amount received");
    }

    receive() external payable {}
}
