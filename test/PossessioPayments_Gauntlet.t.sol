// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/PossessioPayments.sol";

/*
 * PossessioPayments — Gauntlet Adversarial Test Suite
 *
 * SCOPE: Active attack simulation against the Phase 2 merchant contract.
 *        Includes Gemini's six ratified findings under Codebyte Law, plus
 *        additional attack-surface tests covering reentrancy, role escalation,
 *        emergency withdrawal abuse, sweep ordering, and oracle edge cases.
 *
 * 100% cbETH ARCHITECTURE: rETH was removed after council verification that
 *           rETH on Base is a bridged OptimismMintableERC20 with no
 *           user-callable redemption path. Council-ratified single-asset model.
 *
 * PHILOSOPHY: If an adversary can violate an invariant, the test surfaces it.
 *             These tests should FAIL if the contract regresses.
 *
 * STRUCTURE: Mirrors POSSESSIO_v2_Gauntlet.t.sol — separate file from core,
 *            inline mocks (including malicious variants), Amendment IV
 *            declarations per attack category.
 */

// ═══════════════════════════════════════════════════════════════════════════
//                              MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════════════════════

contract MockUSDC_G {
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

contract MockDAI_G {
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

contract MockCbETH_G {
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

contract MockV3Router_G {
    MockUSDC_G  public usdc;
    MockDAI_G   public dai;
    MockCbETH_G public cbeth;

    uint256 public daiOut;
    uint256 public cbEthOut;
    bool    public daiSwapReverts;
    bool    public lstSwapReverts;
    bool    public consumeLessThanRequested;

    constructor(address u, address d, address c) {
        usdc = MockUSDC_G(u);
        dai  = MockDAI_G(d);
        cbeth = MockCbETH_G(c);
    }

    function setDaiOut(uint256 v) external { daiOut = v; }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    function setDaiSwapReverts(bool b) external { daiSwapReverts = b; }
    function setLstSwapReverts(bool b) external { lstSwapReverts = b; }
    function setConsumeLessThanRequested(bool b) external { consumeLessThanRequested = b; }

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
        // Adversarial mode: consume less than requested (test for dangling approval)
        uint256 toConsume = consumeLessThanRequested ? p.amountIn / 2 : p.amountIn;
        MockUSDC_G(p.tokenIn).transferFrom(msg.sender, address(this), toConsume);

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

contract MockChainlink_G {
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
    function setStale()         external { _updatedAt = block.timestamp - 7200; }
    function setReverts(bool r) external { _reverts = r; }
    function setIncomplete()    external { _answeredInRound = _roundId - 1; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!_reverts, "MockChainlink: reverts");
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
}

contract MockLSTRates_G {
    uint256 public cbEthRate;
    constructor() {
        cbEthRate = 1.05e18;
    }
    function setCbEthRate(uint256 v) external { cbEthRate = v; }
    function cbEthToEth(uint256 c) external view returns (uint256) { return (c * cbEthRate) / 1e18; }
}

/**
 * @notice MALICIOUS DAI mock — attempts re-entry into withdrawDAI via
 *         transfer hook. Used to verify nonReentrant on withdrawDAI holds
 *         even with hostile token implementation.
 */
contract MaliciousDAI {
    string public constant name = "Malicious DAI";
    string public constant symbol = "MDAI";
    uint8  public constant decimals = 18;
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    address public targetContract;
    bool    public attackArmed;
    uint256 public reentryAttempts;

    function setTarget(address t) external { targetContract = t; }
    function armAttack() external { attackArmed = true; }
    function disarmAttack() external { attackArmed = false; }

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

        if (attackArmed && targetContract != address(0)) {
            reentryAttempts++;
            (bool ok,) = targetContract.call(
                abi.encodeWithSignature("withdrawDAI(uint256,address)", 1, to)
            );
            ok; // suppress unused — we WANT the call to revert (nonReentrant)
        }
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

// ═══════════════════════════════════════════════════════════════════════════
//                  POSSESSIO PAYMENTS GAUNTLET TEST SUITE
// ═══════════════════════════════════════════════════════════════════════════

contract PossessioPaymentsGauntlet is Test {
    using stdStorage for StdStorage;

    PossessioPayments payments;
    MockUSDC_G        usdc;
    MockDAI_G         dai;
    MockCbETH_G       cbeth;
    MockV3Router_G    router;
    MockChainlink_G   chainlinkEth;
    MockChainlink_G   chainlinkDai;
    MockLSTRates_G    lstRates;

    address MERCHANT = address(0xA11CE);
    address OPERATOR = address(0xB0B);
    address GUARDIAN = address(0xC1A0);
    address ATTACKER = address(0xBAD);
    address PAYEE    = address(0xD11);

    uint256 constant MIN_BATCH    = 100 * 1e6;
    uint256 constant DAI_CEILING  = 5_000 * 1e18;
    uint256 constant DAILY_LIMIT  = 1_000 * 1e18;

    function setUp() public {
        vm.warp(1_000_000);

        usdc         = new MockUSDC_G();
        dai          = new MockDAI_G();
        cbeth        = new MockCbETH_G();
        router       = new MockV3Router_G(address(usdc), address(dai), address(cbeth));
        chainlinkEth = new MockChainlink_G(int256(3000_00000000));
        chainlinkDai = new MockChainlink_G(int256(1_00000000));
        lstRates     = new MockLSTRates_G();

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
    //                  GEMINI'S RATIFIED ADVERSARIAL FINDINGS
    // ═══════════════════════════════════════════════════════════════════════

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #1: DUST PRECISION — fuzz 50 sweeps with random USDC amounts
    //
    // Uses stdstore to reset lastSweepTime between iterations, isolating the
    // dust accumulation invariant from cooldown timing concerns.
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_SweepDustBounded(uint256 sweepAmount) public {
        sweepAmount = bound(sweepAmount, MIN_BATCH, 100_000 * 1e6);

        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        uint256 sweepCount = 50;

        for (uint256 i = 0; i < sweepCount; i++) {
            usdc.mint(address(payments), sweepAmount);

            // 100% cbETH allocation — entire amount consumed minus integer-division dust
            router.setCbEthOut(1);

            vm.prank(MERCHANT);
            payments.sweep(0, 1);

            uint256 usdcAfter = usdc.balanceOf(address(payments));
            // With 100% allocation, dust is bounded by 1 wei per sweep (integer division)
            assertLe(usdcAfter, 1, "Per-sweep dust within bound");

            // Reset cooldown via storage manipulation — isolates dust invariant
            // from cooldown timing. lastSweepTime is at slot 9 in storage layout.
            // Using stdstore for forward-compatible slot resolution.
            stdstore.target(address(payments)).sig("lastSweepTime()").checked_write(uint256(0));

            // Refresh oracle for next iteration
            chainlinkEth.setAnswer(int256(3000_00000000));
            chainlinkDai.setAnswer(int256(1_00000000));
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #2: LIQUID CAPITAL SEPARATION
    // ───────────────────────────────────────────────────────────────────────

    function test_Attack_OperatingCapitalNotHostage() public {
        dai.mint(address(payments), 5000 * 1e18);
        chainlinkEth.setStale();

        usdc.mint(address(payments), 1000 * 1e6);
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);

        // Operating capital still accessible
        vm.prank(MERCHANT);
        payments.withdrawDAI(500 * 1e18, PAYEE);

        assertEq(dai.balanceOf(PAYEE), 500 * 1e18, "DAI flows even when sweep broken");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #3a: DAILY LIMIT WINDOW BOUNDARY
    // ───────────────────────────────────────────────────────────────────────

    function test_Attack_WindowBoundaryExact() public {
        dai.mint(address(payments), 10_000 * 1e18);

        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT, PAYEE);

        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.withdrawDAI(1, PAYEE);

        vm.warp(block.timestamp + 1);
        vm.prank(MERCHANT);
        payments.withdrawDAI(DAILY_LIMIT, PAYEE);

        assertEq(dai.balanceOf(PAYEE), 2 * DAILY_LIMIT, "Two limits across boundary");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #3b: DAILY LIMIT TIMELOCK PRECISION
    // ───────────────────────────────────────────────────────────────────────

    function test_Attack_TimelockExactly24h() public {
        vm.prank(MERCHANT);
        payments.queueDailyLimitIncrease(2000 * 1e18);

        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(PossessioPayments.TimelockNotPassed.selector);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();

        vm.warp(block.timestamp + 1);
        vm.prank(MERCHANT);
        payments.executeDailyLimitIncrease();

        assertEq(payments.dailyLimit(), 2000 * 1e18, "Timelock executes at exact boundary");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #4: REENTRANCY VIA MALICIOUS ERC20
    // ───────────────────────────────────────────────────────────────────────

    function test_Attack_MaliciousTokenCannotDrain() public {
        MaliciousDAI evilDai = new MaliciousDAI();

        PossessioPayments evilPayments = new PossessioPayments(
            MERCHANT,
            address(usdc),
            address(cbeth),
            address(evilDai),
            address(router),
            address(chainlinkEth),
            address(chainlinkDai),
            address(lstRates),
            MIN_BATCH,
            DAI_CEILING,
            DAILY_LIMIT
        );

        evilDai.mint(address(evilPayments), 5000 * 1e18);
        evilDai.setTarget(address(evilPayments));
        evilDai.armAttack();

        vm.prank(MERCHANT);
        evilPayments.withdrawDAI(100 * 1e18, MERCHANT);

        assertGe(evilDai.reentryAttempts(), 1, "Re-entry was attempted");
        assertEq(evilDai.balanceOf(MERCHANT), 100 * 1e18, "Only original withdrawal");
        assertEq(evilDai.balanceOf(address(evilPayments)), 4900 * 1e18, "Reserve unchanged");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Gemini #5: REMOVED — threshold concept retired with Phase 2.1 strip.
    //   ThresholdReached event no longer exists. Spam protection invariant
    //   no longer applicable.
    // ───────────────────────────────────────────────────────────────────────

    // ═══════════════════════════════════════════════════════════════════════
    //              ROLE ESCALATION & UNAUTHORIZED ACCESS ATTACKS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_AttackerCannotPause() public {
        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        vm.prank(ATTACKER);
        payments.pauseUCR();
    }

    function test_Attack_AttackerCannotSetCeiling() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.setDaiCeiling(0);
    }

    function test_Attack_AttackerCannotWithdrawDAI() public {
        dai.mint(address(payments), 5000 * 1e18);
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.withdrawDAI(100 * 1e18, ATTACKER);
    }

    function test_Attack_AttackerCannotEmergencyWithdraw() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.queueEmergencyWithdraw(address(dai), 100 * 1e18);
    }

    function test_Attack_OperatorCannotWithdrawDAI() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        dai.mint(address(payments), 5000 * 1e18);

        vm.expectRevert();
        vm.prank(OPERATOR);
        payments.withdrawDAI(100 * 1e18, OPERATOR);
    }

    function test_Attack_OperatorCannotChangeCeiling() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.expectRevert();
        vm.prank(OPERATOR);
        payments.setDaiCeiling(0);
    }

    function test_Attack_OperatorCannotChangeDailyLimit() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.expectRevert();
        vm.prank(OPERATOR);
        payments.decreaseDailyLimit(500 * 1e18);
    }

    function test_Attack_OperatorCannotEmergencyWithdraw() public {
        bytes32 opRole = payments.OPERATOR_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(opRole, OPERATOR);

        vm.expectRevert();
        vm.prank(OPERATOR);
        payments.queueEmergencyWithdraw(address(dai), 100 * 1e18);
    }

    function test_Attack_GuardianCannotPauseWhenDisabled() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);

        vm.expectRevert(PossessioPayments.GuardianNotEnabled.selector);
        vm.prank(GUARDIAN);
        payments.guardianPause();
    }

    function test_Attack_GuardianCannotWithdrawAnything() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();

        dai.mint(address(payments), 5000 * 1e18);

        vm.expectRevert();
        vm.prank(GUARDIAN);
        payments.withdrawDAI(100 * 1e18, GUARDIAN);

        vm.expectRevert();
        vm.prank(GUARDIAN);
        payments.queueEmergencyWithdraw(address(dai), 100 * 1e18);
    }

    function test_Attack_GuardianCannotResume() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();

        vm.prank(GUARDIAN);
        payments.guardianPause();

        vm.expectRevert();
        vm.prank(GUARDIAN);
        payments.queueResumeUCR();
    }

    function test_Attack_GuardianCannotToggleGuardian() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(GUARDIAN);
        payments.disableGuardian();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     EMERGENCY WITHDRAWAL ABUSE PATHS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_EmergencyDAIBypassBlocked() public {
        dai.mint(address(payments), 5000 * 1e18);

        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(dai), 5000 * 1e18);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(PossessioPayments.DailyLimitExceeded.selector);
        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(dai), MERCHANT);

        assertEq(dai.balanceOf(address(payments)), 5000 * 1e18, "DAI not drained");
    }

    function test_Attack_EmergencyDAIPartialOk() public {
        dai.mint(address(payments), 5000 * 1e18);

        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(dai), DAILY_LIMIT);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(MERCHANT);
        payments.executeEmergencyWithdraw(address(dai), MERCHANT);

        assertEq(dai.balanceOf(MERCHANT), DAILY_LIMIT, "Partial emergency at limit succeeds");
    }

    function test_Attack_EmergencyCancelByAttacker() public {
        vm.prank(MERCHANT);
        payments.queueEmergencyWithdraw(address(dai), 100 * 1e18);

        vm.expectRevert();
        vm.prank(ATTACKER);
        payments.cancelEmergencyWithdraw(address(dai));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       SWEEP ORDERING & STATE ATTACKS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_SweepDuringPauseBlocked() public {
        usdc.mint(address(payments), 1000 * 1e6);

        vm.prank(MERCHANT);
        payments.pauseUCR();

        vm.expectRevert(PossessioPayments.RoutingPaused.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Attack_SweepCooldownBypass() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        // Try every minute for 23 hours — must all revert
        for (uint256 i = 0; i < 23; i++) {
            vm.warp(block.timestamp + 1 hours);
            usdc.mint(address(payments), 1000 * 1e6);

            vm.expectRevert(PossessioPayments.SweepTooEarly.selector);
            vm.prank(MERCHANT);
            payments.sweep(0, 0.31 ether);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   ORACLE EDGE CASE & ATTACK ATTEMPTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_OracleNegativeAnswer() public {
        chainlinkEth.setAnswer(int256(-1));
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Attack_OracleRevertsOnRead() public {
        chainlinkEth.setReverts(true);
        usdc.mint(address(payments), 1000 * 1e6);

        vm.expectRevert();
        vm.prank(MERCHANT);
        payments.sweep(0, 0);
    }

    function test_Attack_DAIOracleRevertsSkipsGracefully() public {
        chainlinkDai.setReverts(true);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        // DAI oracle reverting — sweep should skip DAI and proceed with cbETH
        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        // No DAI accumulated, but cbETH received
        assertEq(dai.balanceOf(address(payments)), 0, "DAI skipped on reverting oracle");
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether, "cbETH received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    DANGLING APPROVAL ATTACK SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_MaliciousRouterUndereconsumeNoApproval() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        // Set router to consume only half the approved amount
        router.setConsumeLessThanRequested(true);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        // Sweep will revert because of leakage check (good — defense at multiple layers)
        vm.expectRevert(PossessioPayments.LeakageDetected.selector);
        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);
    }

    function test_Attack_NoApprovalAfterSuccessfulSweep() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        uint256 allowance = usdc.allowance(address(payments), address(router));
        assertEq(allowance, 0, "No dangling approval after successful sweep");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   GUARDIAN STATE MACHINE ATTACKS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Attack_GuardianPauseWhenDisabledAfterEnable() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();

        // Guardian pauses while enabled
        vm.prank(GUARDIAN);
        payments.guardianPause();
        assertTrue(payments.routingPaused());

        // Owner disables Guardian
        vm.prank(MERCHANT);
        payments.disableGuardian();

        // Owner queues resume
        vm.prank(MERCHANT);
        bytes32 id = payments.queueResumeUCR();
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(MERCHANT);
        payments.resumeUCR(id);

        // Guardian tries to pause again — must revert (now disabled)
        vm.expectRevert(PossessioPayments.GuardianNotEnabled.selector);
        vm.prank(GUARDIAN);
        payments.guardianPause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  RECOVERY & STATE-INTEGRITY ATTACKS
    // ═══════════════════════════════════════════════════════════════════════

    function test_Recovery_FailureThenSuccess() public {
        vm.prank(MERCHANT);
        payments.setDaiCeiling(0);

        usdc.mint(address(payments), 1000 * 1e6);
        uint256 usdcBefore = usdc.balanceOf(address(payments));

        // First sweep: router fails
        router.setLstSwapReverts(true);
        router.setCbEthOut(0.31 ether);

        vm.expectRevert();
        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        // USDC unchanged — no funds lost
        uint256 usdcAfterFail = usdc.balanceOf(address(payments));
        assertEq(usdcAfterFail, usdcBefore, "USDC preserved across failed sweep");

        // Fix the condition
        router.setLstSwapReverts(false);

        vm.warp(block.timestamp + 25 hours);
        chainlinkEth.setAnswer(int256(3000_00000000));
        chainlinkDai.setAnswer(int256(1_00000000));

        vm.prank(MERCHANT);
        payments.sweep(0, 0.31 ether);

        // USDC fully consumed (minus integer-division dust)
        uint256 usdcAfterRecovery = usdc.balanceOf(address(payments));
        assertLe(usdcAfterRecovery, 1, "USDC consumed by recovery sweep");

        // cbETH received exactly once — no double-count
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether, "cbETH received once");
    }

    function test_Sequence_MultiActionStateIntegrity() public {
        // Step 1: First USDC arrives, sweep refills DAI partially
        usdc.mint(address(payments), 3000 * 1e6);
        router.setDaiOut(3000 * 1e18);
        router.setCbEthOut(0);

        vm.prank(MERCHANT);
        payments.sweep(2900 * 1e18, 0);

        assertEq(dai.balanceOf(address(payments)), 3000 * 1e18, "DAI partial refill");

        // Step 2: Merchant withdraws operating capital
        vm.warp(block.timestamp + 1 hours);
        vm.prank(MERCHANT);
        payments.withdrawDAI(500 * 1e18, PAYEE);

        assertEq(payments.dailyWithdrawn(), 500 * 1e18, "Daily counter tracks");
        assertEq(dai.balanceOf(address(payments)), 2500 * 1e18, "DAI reduced by withdrawal");

        // Step 3: More USDC arrives — second sweep
        vm.warp(block.timestamp + 25 hours);
        chainlinkEth.setAnswer(int256(3000_00000000));
        chainlinkDai.setAnswer(int256(1_00000000));
        usdc.mint(address(payments), 5000 * 1e6);

        // 2500 DAI gap to reach ceiling. With 5000 USDC incoming, ~2500 USDC for refill, 2500 USDC for cbETH
        router.setDaiOut(2500 * 1e18);
        router.setCbEthOut(0.31 ether);

        vm.prank(MERCHANT);
        payments.sweep(2400 * 1e18, 0.31 ether);

        // Final state checks
        assertEq(dai.balanceOf(address(payments)), 5000 * 1e18, "DAI at ceiling");
        assertEq(cbeth.balanceOf(address(payments)), 0.31 ether, "cbETH accumulated");

        assertEq(payments.dailyRemaining(), DAILY_LIMIT, "Window rolled, full limit available");

        uint256 expectedGauge = (0.31 ether * 1.05e18) / 1e18;
        assertEq(payments.getTreasuryGauge(), expectedGauge, "Gauge reflects cbETH holdings");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              REGULATORY FINALITY (compliance verification)
    // ═══════════════════════════════════════════════════════════════════════

    function test_OwnershipRenouncement_DeployerHasNoAuthority() public {
        address deployer = address(this);

        assertFalse(
            payments.hasRole(payments.OWNER_ROLE(), deployer),
            "Deployer must not hold OWNER_ROLE"
        );
        assertFalse(
            payments.hasRole(payments.OPERATOR_ROLE(), deployer),
            "Deployer must not hold OPERATOR_ROLE"
        );
        assertFalse(
            payments.hasRole(payments.GUARDIAN_ROLE(), deployer),
            "Deployer must not hold GUARDIAN_ROLE"
        );

        vm.expectRevert(PossessioPayments.InvalidAddress.selector);
        payments.pauseUCR();

        dai.mint(address(payments), 1000 * 1e18);
        vm.expectRevert();
        payments.withdrawDAI(100 * 1e18, deployer);

        vm.expectRevert();
        payments.setDaiCeiling(100_000 * 1e18);

        bytes32 ownerRole = payments.OWNER_ROLE();
        vm.expectRevert();
        payments.grantRole(ownerRole, deployer);
    }

    function test_NoHiddenUpgradability_NoUpgradeFunctionsExposed() public {
        bytes4 upgradeToSig          = bytes4(keccak256("upgradeTo(address)"));
        bytes4 upgradeToAndCallSig   = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
        bytes4 changeAdminSig        = bytes4(keccak256("changeAdmin(address)"));
        bytes4 setImplementationSig  = bytes4(keccak256("setImplementation(address)"));
        bytes4 initializeSig         = bytes4(keccak256("initialize()"));

        (bool ok1,) = address(payments).call(abi.encodeWithSelector(upgradeToSig, address(0x1)));
        assertFalse(ok1, "upgradeTo must not exist");

        (bool ok2,) = address(payments).call(abi.encodeWithSelector(upgradeToAndCallSig, address(0x1), ""));
        assertFalse(ok2, "upgradeToAndCall must not exist");

        (bool ok3,) = address(payments).call(abi.encodeWithSelector(changeAdminSig, address(0x1)));
        assertFalse(ok3, "changeAdmin must not exist");

        (bool ok4,) = address(payments).call(abi.encodeWithSelector(setImplementationSig, address(0x1)));
        assertFalse(ok4, "setImplementation must not exist");

        (bool ok5,) = address(payments).call(abi.encodeWithSelector(initializeSig));
        assertFalse(ok5, "initialize must not exist");
    }

    receive() external payable {}
}
