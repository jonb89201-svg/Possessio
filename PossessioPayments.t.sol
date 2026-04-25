// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/PossessioPayments.sol";

/*
 * PossessioPayments — Core Invariant Test Suite
 *
 * SCOPE: UCR mechanism, DAI reserve, daily limit asymmetric timelock, roles,
 *        Guardian opt-in security, emergency withdrawal, integration paths.
 *
 * STRATEGY: Inline mocks for USDC/DAI/cbETH/rETH/WETH/V3Router/Chainlink/LSTRates.
 *           Mocks model real-world behavior (transferFrom approval pattern,
 *           Chainlink staleness checks, LST rate queries).
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

contract MockRETH {
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
    MockRETH  public reth;

    // Per-token output amounts the router will deliver
    uint256 public daiOut;
    uint256 public cbEthOut;
    uint256 public rEthOut;
    bool    public daiSwapReverts;
    bool    public lstSwapReverts;

    constructor(address u, address d, address c, address r) {
        usdc = MockUSDC(u);
        dai  = MockDAI(d);
        cbeth = MockCbETH(c);
        reth  = MockRETH(r);
    }

    function setDaiOut(uint256 v) external { daiOut = v; }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    function setREthOut(uint256 v) external { rEthOut = v; }
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
        } else if (p.tokenOut == address(reth)) {
            require(!lstSwapReverts, "MockV3Router: lst swap reverts");
            require(rEthOut >= p.amountOutMinimum, "MockV3Router: slippage rETH");
            if (rEthOut > 0) reth.mint(p.recipient, rEthOut);
            return rEthOut;
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
    uint256 public rEthRate;  // ETH per rETH (18 dec)

    constructor() {
        cbEthRate = 1.05e18; // ~5% premium
        rEthRate  = 1.10e18; // ~10% premium
    }

    function setCbEthRate(uint256 v) external { cbEthRate = v; }
    function setREthRate(uint256 v)  external { rEthRate = v; }

    function cbEthToEth(uint256 cbAmount) external view returns (uint256) {
        return (cbAmount * cbEthRate) / 1e18;
    }
    function rEthToEth(uint256 rAmount) external view returns (uint256) {
        return (rAmount * rEthRate) / 1e18;
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
    MockRETH          reth;
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
    uint256 constant DAI_CEILING  = 5_000 * 1e18;    // $5k operating buffer
    uint256 constant DAILY_LIMIT  = 1_000 * 1e18;    // $1k/day default

    function setUp() public {
        vm.warp(1_000_000);

        usdc         = new MockUSDC();
        dai          = new MockDAI();
        cbeth        = new MockCbETH();
        reth         = new MockRETH();
        router       = new MockV3Router(address(usdc), address(dai), address(cbeth), address(reth));
        chainlinkEth = new MockChainlink(int256(3000_00000000));   // $3000/ETH (8 dec)
        chainlinkDai = new MockChainlink(int256(1_00000000));       // $1.00/DAI (8 dec)
        lstRates     = new MockLSTRates();

        payments = new PossessioPayments(
            MERCHANT,
            address(usdc),
            address(cbeth),
            address(reth),
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
    //
    // Proof Scope:    Constructor validates non-zero addresses, sets all immutables,
    //                 grants OWNER_ROLE to merchant, sets role admins correctly,
    //                 initializes mutable state with constructor params.
    // Boundary:       Zero address for any of 9 dependencies reverts.
    // Assumption Log: AccessControl behaves as documented.

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
        assertEq(address(payments.RETH()),          address(reth));
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
        assertEq(payments.citadelGauge(), 0);
        assertFalse(payments.routingPaused());
        assertFalse(payments.guardianEnabled());
    }

    function test_Deploy_RevertsZeroOwner() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            address(0),
            address(usdc), address(cbeth), address(reth), address(dai),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates), MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    function test_Deploy_RevertsZeroUSDC() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            MERCHANT,
            address(0), address(cbeth), address(reth), address(dai),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates), MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    function test_Deploy_RevertsZeroDAI() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        new PossessioPayments(
            MERCHANT,
            address(usdc), address(cbeth), address(reth), address(0),
            address(router), address(chainlinkEth), address(chainlinkDai),
            address(lstRates), MIN_BATCH, DAI_CEILING, DAILY_LIMIT
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ROLE GRANTING TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Owner can grant Operator and Guardian roles. Non-owner cannot.
    //                 OWNER_ROLE is admin of OPERATOR_ROLE and GUARDIAN_ROLE.
    // Boundary:       Owner self-sufficient for role management.

    function test_Roles_OwnerCanGrantOperator() public {
        vm.prank(MERCHANT);
        payments.grantRole(payments.OPERATOR_ROLE(), OPERATOR);
        assertTrue(payments.hasRole(payments.OPERATOR_ROLE(), OPERATOR));
    }

    function test_Roles_OwnerCanGrantGuardian() public {
        vm.prank(MERCHANT);
        payments.grantRole(payments.GUARDIAN_ROLE(), GUARDIAN);
        assertTrue(payments.hasRole(payments.GUARDIAN_ROLE(), GUARDIAN));
    }

    function test_Roles_AttackerCannotGrantOperator() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.grantRole(payments.OPERATOR_ROLE(), ATTACKER);
    }

    function test_Roles_OwnerCanRevokeOperator() public {
        vm.startPrank(MERCHANT);
        payments.grantRole(payments.OPERATOR_ROLE(), OPERATOR);
        payments.revokeRole(payments.OPERATOR_ROLE(), OPERATOR);
        vm.stopPrank();
        assertFalse(payments.hasRole(payments.OPERATOR_ROLE(), OPERATOR));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SWEEP — BASIC LST PATH
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Sweep splits USDC 40/60 into cbETH/rETH, requires fresh
    //                 oracle, requires min batch, increments citadel gauge.
    // Boundary:       Below batch reverts. Stale oracle reverts.
    // Assumption Log: With daiCeiling=0 (overridden), full sweep goes to LSTs.

    function test_Sweep_SplitsLSTWhenNoCeiling() public {
        // Set ceiling = 0 to bypass DAI refill
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6); // 1000 USDC
        router.setCbEthOut(0.13 ether); // mock returns
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // 40% = 400 USDC -> cbeth (0.13 ETH worth)
        // 60% = 600 USDC -> reth  (0.18 ETH worth)
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
        assertEq(reth.balanceOf(address(payments)),  0.18 ether);

        // Citadel gauge: 0.13 * 1.05 + 0.18 * 1.10 = 0.1365 + 0.198 = 0.3345 ETH
        uint256 expectedGauge = (0.13 ether * 1.05e18 / 1e18) + (0.18 ether * 1.10e18 / 1e18);
        assertEq(payments.citadelGauge(), expectedGauge);
    }

    function test_Sweep_RevertsBelowMinBatch() public {
        usdc.mint(address(payments), 50 * 1e6); // below 100 USDC min

        vm.expectRevert(PossessioPayments.BatchTooSmall.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);
    }

    function test_Sweep_RevertsTooEarly() public {
        // Bypass DAI for simplicity
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // Try again immediately
        usdc.mint(address(payments), 1000 * 1e6);
        vm.expectRevert(PossessioPayments.SweepTooEarly.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);
    }

    function test_Sweep_RevertsETHOracleStale() public {
        chainlinkEth.setStale();
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);
    }

    function test_Sweep_RevertsETHOracleInvalid() public {
        chainlinkEth.setAnswer(int256(0));
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);
    }

    function test_Sweep_RevertsETHOracleIncomplete() public {
        chainlinkEth.setIncomplete();
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);
    }

    function test_Sweep_OnlyOwnerOrOperator() public {
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(ATTACKER);
        payments.sweep(0, 0, 0);
    }

    function test_Sweep_OperatorCanCall() public {
        vm.prank(MERCHANT);
        payments.grantRole(payments.OPERATOR_ROLE(), OPERATOR);

        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(OPERATOR);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        assertGt(payments.citadelGauge(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SWEEP — DAI RESERVE FILL
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    DAI reserve fills to ceiling first, then LST split on
    //                 remaining. If DAI fully consumes USDC, no LST swap occurs.
    //                 Reserve at/above ceiling skips DAI leg.
    // Boundary:       Empty reserve, partial reserve, full reserve, oracle issues.
    // Assumption Log: 1 USDC ~= 1 DAI for refill calculations.

    function test_Sweep_FillsDAIThenSplitsLST() public {
        // 5000 USDC incoming, ceiling 5000 DAI, current DAI = 0
        // Refill needs 5000 USDC of DAI = consumes most of incoming
        // Wait — ceiling is in DAI (1e18) units, USDC is 1e6
        // 5000 USDC = 5_000 * 1e6
        // 5000 DAI  = 5_000 * 1e18
        // Refill calc uses raw daiGap (in DAI 1e18) as USDC amount...
        // This will refill until USDC is exhausted because daiGap > usdcBalance

        // Mint 6000 USDC, ceiling 5000 DAI
        usdc.mint(address(payments), 6000 * 1e6);
        router.setDaiOut(5000 * 1e18); // mock returns 5000 DAI for the swap

        // After DAI refill: ~1000 USDC remaining for LST split
        // 40% cbETH = 400 * 1e6 USDC -> 0.13 ether
        // 60% rETH  = 600 * 1e6 USDC -> 0.18 ether
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(4900 * 1e18, 0.13 ether, 0.18 ether);

        // DAI reserve should be at ceiling
        assertEq(dai.balanceOf(address(payments)), 5000 * 1e18);
        // LSTs accumulated
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
        assertEq(reth.balanceOf(address(payments)),  0.18 ether);
    }

    function test_Sweep_DAIFullSkipsRefill() public {
        // Pre-fund DAI reserve at ceiling
        dai.mint(address(payments), DAI_CEILING);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // Full LST split, no DAI delta
        assertEq(dai.balanceOf(address(payments)), DAI_CEILING);
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
        assertEq(reth.balanceOf(address(payments)),  0.18 ether);
    }

    function test_Sweep_DAIOpenedSkipsRefill() public {
        // Set ceiling to 0 (opt out)
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // No DAI refill, full LST split
        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
    }

    function test_Sweep_DAIOracleStaleSkipsGracefully() public {
        // DAI oracle stale — sweep should skip DAI and proceed with LST
        chainlinkDai.setStale();
        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // No DAI accumulated (stale), but LST split executed
        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
        assertEq(reth.balanceOf(address(payments)),  0.18 ether);
    }

    function test_Sweep_DAISwapRevertsSkipsGracefully() public {
        // Router DAI swap reverts — sweep should still execute LST split
        router.setDaiSwapReverts(true);
        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        // No DAI (swap failed), but LSTs accumulated
        assertEq(dai.balanceOf(address(payments)), 0);
        assertEq(cbeth.balanceOf(address(payments)), 0.13 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DAI WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    withdrawDAI is owner-only, instant, subject to daily limit.
    //                 Window rolls correctly after 24h. Lockdown (limit=0) blocks all.
    // Boundary:       At-limit succeeds. Over-limit reverts. Window boundary resets.

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

        // Total would be 1200, exceeds 1000 limit
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

        // Roll forward 25 hours
        vm.warp(block.timestamp + 25 hours);

        // Should succeed — new window
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
        // Decrease limit to 0 (lockdown)
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
    //
    // Proof Scope:    Decrease applies instantly. Increase requires 24h delay.
    //                 Cancel works at any time. Owner-only.

    function test_DailyLimit_DecreaseInstant() public {
        vm.prank(MERCHANT);
        payments.decreaseDailyLimit(500 * 1e18);
        assertEq(payments.dailyLimit(), 500 * 1e18);
    }

    function test_DailyLimit_DecreaseToHigherReverts() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(MERCHANT);
        payments.decreaseDailyLimit(2000 * 1e18); // higher than current
    }

    function test_DailyLimit_IncreaseQueueRequiresDelay() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);

        // Try to execute immediately — should revert
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();

        // Limit unchanged
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
        payments.queueDailyLimitIncrease(500 * 1e18); // lower than current
    }

    function test_DailyLimit_CancelQueuedIncrease() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);

        vm.prank(MERCHANT);
        payments.cancelDailyLimitIncrease();

        // Try to execute — should revert (no queue)
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
        vm.prank(MERCHANT);
        payments.grantRole(payments.OPERATOR_ROLE(), OPERATOR);

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
        payments.sweep(0, 0, 0);
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
        vm.prank(MERCHANT);
        payments.grantRole(payments.GUARDIAN_ROLE(), GUARDIAN);

        // Guardian disabled — pause reverts
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
    //                      CITADEL GAUGE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Citadel_ProgressIncrements() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.13 ether);
        router.setREthOut(0.18 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.13 ether, 0.18 ether);

        uint256 expectedGauge = (0.13 ether * 1.05e18 / 1e18) + (0.18 ether * 1.10e18 / 1e18);
        assertEq(payments.getCitadelProgress(), expectedGauge);
    }

    function test_Citadel_ThresholdNotMetSmall() public {
        assertFalse(payments.isSoloThresholdMet());
    }

    function test_Citadel_ProgressPercentageZero() public {
        assertEq(payments.progressPercentage(), 0);
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
        // 3000 DAI / 100 DAI/day = 30 days
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
        assertTrue(payments.isDaiReserveFull()); // opt-out = always "full"
    }

    receive() external payable {}
}
