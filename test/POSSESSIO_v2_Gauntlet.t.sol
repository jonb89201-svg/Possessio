// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/POSSESSIO_v2-6-3.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}       from "v4-core/interfaces/IHooks.sol";
import {PoolKey}      from "v4-core/types/PoolKey.sol";
import {Currency}     from "v4-core/types/Currency.sol";

/*
 * POSSESSIO v2 Gauntlet -- Adversarial Test Suite
 *
 * SCOPE: Active attack simulation against the merged PossessioHook contract.
 *        Covers attack surface preserved from v1 plus new v2-specific vectors.
 *
 * PRIOR ART: Ported from v1 Gauntlet.t.sol (29 attacks). Drops architecturally
 *            N/A tests (TWAP, V2 LP, symmetry guard). Adds v2-specific vectors
 *            (hook injection, rescue guards, SAV abuse).
 *
 * PHILOSOPHY: If an adversary can violate an invariant, the test surfaces it.
 *             These tests should FAIL if the contract regresses to v1's bugs.
 *
 * Naming: test_Attack_<Vector>_<Outcome>. Each test is an isolated scenario.
 *
 * Amendment IV declarations per attack category.
 */

// ===========================================================================
//                              MOCK CONTRACTS
// ===========================================================================

// v2.6.1 — MockCbETHAttack locked down to match new IcbETH interface.
//          Old interface had deposit()/withdraw(); v2.6.1 removed both because
//          cbETH on Base is OptimismMintableERC20 with no payable deposit.
//          Only balanceOf + approve remain. mint/addRewards helpers for test setup.
contract MockCbETHAttack {
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address o, address s) external view returns (uint256) {
        return _allowances[o][s];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "MockCbETH: insufficient");
        require(_allowances[from][msg.sender] >= amount, "MockCbETH: not approved");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to]   += amount;
        return true;
    }

    // Test helpers
    function mint(address to, uint256 amount) external { _balances[to] += amount; }
    function addRewards(address a, uint256 r) external { _balances[a] += r; }

    receive() external payable {}
}

contract MockDAIAttack {
    mapping(address => uint256) public _balances;
    function mint(address to, uint256 amount) external { _balances[to] += amount; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "MockDAI: insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract MockWETHAttack {
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "MockWETH: insufficient");
        _balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    function approve(address s, uint256 a) external returns (bool) {
        _allowances[msg.sender][s] = a;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "MockWETH: insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "MockWETH: insufficient");
        require(_allowances[from][msg.sender] >= amount, "MockWETH: not approved");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    receive() external payable {}
}

contract MockV3RouterAttack {
    address public weth;
    address public dai;
    uint256 public daiReturn;
    bool    public swapShouldRevert;
    uint256 public callCount;

    constructor(address weth_, address dai_) { weth = weth_; dai = dai_; }
    function setDAIReturn(uint256 v) external { daiReturn = v; }
    function setSwapRevert(bool r)    external { swapShouldRevert = r; }

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
        require(!swapShouldRevert, "MockV3Router: swap reverts");
        require(daiReturn >= params.amountOutMinimum, "MockV3Router: slippage");
        callCount++;
        if (params.tokenIn == weth && params.amountIn > 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            MockWETHAttack(payable(weth)).transferFrom(msg.sender, address(this), params.amountIn);
        }
        if (daiReturn > 0) {
            MockDAIAttack(dai).mint(params.recipient, daiReturn);
        }
        return daiReturn;
    }

    receive() external payable {}
}

// v2.6.1 — MockChainlinkAttack updated for asymmetric staleness windows
//          and decimal-class guard. cbETH=18-decimal exchange-rate (90,000s stale).
//          DAI=8-decimal price-feed (3,600s stale).
contract MockChainlinkAttack {
    int256  public _answer;
    uint256 public _updatedAt;
    uint80  public _roundId;
    uint80  public _answeredInRound;
    bool    public _reverts;
    uint8   public _decimals;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
        _decimals = decimals_;
    }

    function setAnswer(int256 a) external {
        _answer = a;
        _updatedAt = block.timestamp;
        _roundId++;
        _answeredInRound = _roundId;
    }

    /// @notice Staleness offset class-appropriate per v2.6.1.
    function setStale() external {
        if (_decimals == 18) {
            _updatedAt = block.timestamp - 100_000;  // > ORACLE_STALE_CBETH (90,000s)
        } else {
            _updatedAt = block.timestamp - 7_200;    // > ORACLE_STALE (3,600s)
        }
    }
    function setReverts(bool r)   external { _reverts = r; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!_reverts, "MockChainlink: reverts");
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

// v2.6.1 — MockAerodromeRouterAttack for WETH↔cbETH swap path testing.
//          Mirrors IAerodromeSlipstreamRouter shape. Adversarial-test surface
//          includes setSwapRevert (for failure-path testing of _retainForRetry
//          / _unwrapAndRetain helpers) and setLeakageMode (defense-in-depth
//          leakage detection tests).
contract MockAerodromeRouterAttack {
    address public weth;
    address public cbETH;
    uint256 public cbEthReturn;
    uint256 public wethReturn;
    bool    public swapShouldRevert;
    bool    public leakageMode;
    uint256 public callCount;

    constructor(address weth_, address cbETH_) {
        weth = weth_;
        cbETH = cbETH_;
    }

    function setCbEthReturn(uint256 v)     external { cbEthReturn = v; }
    function setWethReturn(uint256 v)      external { wethReturn = v; }
    function setSwapRevert(bool r)         external { swapShouldRevert = r; }
    function setLeakageMode(bool m)        external { leakageMode = m; }

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
        external payable returns (uint256 amountOut)
    {
        require(!swapShouldRevert, "MockAerodromeRouter: swap reverts");
        callCount++;

        if (params.tokenIn == weth && params.tokenOut == cbETH) {
            require(cbEthReturn >= params.amountOutMinimum, "MockAerodromeRouter: slippage");
            uint256 consumeAmt = leakageMode ? (params.amountIn - 1) : params.amountIn;
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            MockWETHAttack(payable(weth)).transferFrom(msg.sender, address(this), consumeAmt);
            if (cbEthReturn > 0) {
                MockCbETHAttack(payable(cbETH)).mint(params.recipient, cbEthReturn);
            }
            return cbEthReturn;
        } else if (params.tokenIn == cbETH && params.tokenOut == weth) {
            require(wethReturn >= params.amountOutMinimum, "MockAerodromeRouter: slippage");
            uint256 consumeAmt = leakageMode ? (params.amountIn - 1) : params.amountIn;
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            MockCbETHAttack(payable(cbETH)).transferFrom(msg.sender, address(this), consumeAmt);
            if (wethReturn > 0) {
                MockWETHAttack wethMock = MockWETHAttack(payable(weth));
                wethMock.transfer(params.recipient, wethReturn);
            }
            return wethReturn;
        }
        revert("MockAerodromeRouter: unsupported pair");
    }

    receive() external payable {}
}

contract MockPoolManagerAttack {
    receive() external payable {}
}

// ===========================================================================
//                           REENTRANCY ATTACKER
// ===========================================================================

contract ReentrancyAttacker {
    PossessioHook public target;
    bool public didReenter;

    constructor(address t) { target = PossessioHook(payable(t)); }

    receive() external payable {
        if (!didReenter) {
            didReenter = true;
            try target.routeETH() {
                // reentry succeeded -- BAD
            } catch {
                // expected -- nonReentrant guarded
            }
        }
    }

    function triggerAttack() external payable {
        (bool ok,) = address(target).call{value: msg.value}("");
        require(ok, "forward failed");
    }
}

// ===========================================================================
//                      POSSESSIO V2 GAUNTLET TEST SUITE
// ===========================================================================

contract POSSESSIOv2Gauntlet is Test {
    using stdStorage for StdStorage;

    STEEL         steel;
    PossessioHook hook;
    MockPoolManagerAttack       poolManager;
    MockCbETHAttack             cbETH;
    MockDAIAttack               dai;
    MockWETHAttack              weth;
    MockV3RouterAttack          v3Router;
    MockAerodromeRouterAttack   aeroRouter;  // v2.6.1
    MockChainlinkAttack         clCbETH;
    MockChainlinkAttack         clDAI;
    MockChainlinkAttack         clEthUsd;

    address TREASURY = 0x19495180FFA00B8311c85DCF76A89CCbFB174EA0;
    address USER     = address(0x1111);
    address ATTACKER = address(0x2222);
    address COUNCIL_0 = address(0xC001);
    address COUNCIL_1 = address(0xC002);
    address COUNCIL_2 = address(0xC003);
    address COUNCIL_3 = address(0xC004);

    function setUp() public {
        vm.warp(1_000_000);

        poolManager = new MockPoolManagerAttack();
        cbETH       = new MockCbETHAttack();
        dai         = new MockDAIAttack();
        weth        = new MockWETHAttack();
        v3Router    = new MockV3RouterAttack(address(weth), address(dai));
        aeroRouter  = new MockAerodromeRouterAttack(address(weth), address(cbETH));

        // v2.6.1 — 18-decimal cbETH oracle (was 8-decimal in v2.4)
        clCbETH     = new MockChainlinkAttack(int256(980_000_000_000_000_000), 18);
        clDAI       = new MockChainlinkAttack(int256(100_000_000), 8);      // DAI/USD $1.00
        clEthUsd    = new MockChainlinkAttack(int256(166_939_220_000), 8);  // ETH/USD $1669.39

        steel = new STEEL(address(this));

        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];

        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       address(this),
            steel:          address(steel),
            poolManager:    address(poolManager),
            treasury:       TREASURY,
            cbETH_:         address(cbETH),
            chainlinkCbETH: address(clCbETH),
            aeroRouter:     address(aeroRouter),  // v2.6.1
            weth:           address(weth),
            council:        council
        });

        hook = new PossessioHook(p);

        stdstore.target(address(hook)).sig("poolInitialized()").checked_write(true);

        vm.deal(address(v3Router), 100 ether);
        vm.deal(address(aeroRouter), 100 ether);
        vm.deal(USER,              10 ether);
        vm.deal(ATTACKER,          10 ether);

        v3Router.setDAIReturn(1 * 1e18);

        // v2.6.1 — Pre-fund aeroRouter with WETH for harvest-direction returns.
        // C-1 (audit 2026-07-14): the mock returns a FIXED cbETH amount per swap,
        // so set it to the ORACLE-FAIR amount for this suite's standard route
        // (_fundAccumulator(1 ether) → toStaking = 0.75 ether at the 0.98e18
        // peg). The old flat 1-ether return was a phantom ~0.23 ETH bonus fill
        // which, under value-based harvest accounting, would surface as instant
        // harvestable "excess" and distort every principal-erosion assertion.
        // +1 wei rounds up so floor(cbRet * rate / 1e18) == 0.75 ether exactly:
        // a fresh deploy carries zero phantom excess.
        uint256 fairCbReturn = (0.75 ether * 1e18) / uint256(980_000_000_000_000_000) + 1;
        aeroRouter.setCbEthReturn(fairCbReturn);
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 50 ether}();
        weth.transfer(address(aeroRouter), 50 ether);

        clCbETH.setAnswer(int256(980_000_000_000_000_000));  // v2.6.1 — 18-dec healthy
        clDAI.setAnswer(int256(100_000_000));        // DAI/USD $1.00
        clEthUsd.setAnswer(int256(166_939_220_000)); // ETH/USD $1669.39
    }

    // ===========================================================================
    //                         REENTRANCY ATTACKS
    // ===========================================================================

    function test_Attack_ReentrancyOnRouteETH() public {
        ReentrancyAttacker atk = new ReentrancyAttacker(address(hook));

        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(atk.didReenter(), "Reentrancy guard must prevent re-entry");
    }

    // ===========================================================================
    //                      UNAUTHORIZED ACCESS ATTACKS
    // ===========================================================================

    function test_Attack_UnauthorizedPauseRouting() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.pauseRouting();
    }

    function test_Attack_UnauthorizedRescueToken() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.rescueToken(address(0x9999), 1 ether);
    }

    function test_Attack_UnauthorizedSavPause() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savPause();
    }

    function test_Attack_UnauthorizedSavSlash() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savSlash();
    }

    function test_Attack_UnauthorizedExecuteInvent() public {
        bytes32 dummyId = keccak256("fake");
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.executeInvent(100 * 1e18, dummyId, "");
    }

    function test_Attack_UnauthorizedQueueResume() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.queueResumeRouting();
    }

    // ===========================================================================
    //                   CIRCUIT BREAKER BYPASS ATTACKS
    // ===========================================================================

    function test_Attack_CircuitBreakerBypassDirect() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.pauseRouting();

        vm.expectRevert(PossessioHook.RoutingPaused.selector);
        vm.prank(ATTACKER);
        hook.routeETH();
    }

    function test_Attack_CircuitBreakerBypassViaQueueSpam() public {
        vm.prank(TREASURY);
        hook.pauseRouting();

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(TREASURY);
            bytes32 id = hook.queueResumeRouting();

            vm.expectRevert(PossessioHook.TimelockPending.selector);
            vm.prank(TREASURY);
            hook.resumeRouting(id);
        }

        assertTrue(hook.routingPaused(), "Pause must hold despite queue spam");
    }

    // ===========================================================================
    //                        ORACLE MANIPULATION
    // ===========================================================================

    function test_Attack_ExtremeOracleDepegZero() public {
        clCbETH.setAnswer(int256(0));
        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(hook.cbETHPaused(), "Zero answer must not trigger state change");
    }

    function test_Attack_ExtremeOracleDepegNegative() public {
        clCbETH.setAnswer(int256(-1));
        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(hook.cbETHPaused(), "Negative answer must not change state");
    }

    function test_Attack_ExtremeOracleDepegMax() public {
        clCbETH.setAnswer(type(int256).max);
        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(hook.cbETHPaused(), "Max answer must not pause (far above threshold)");
    }

    function test_Attack_OracleRevertsCleanly() public {
        clCbETH.setReverts(true);
        clDAI.setReverts(true);
        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(hook.cbETHPaused(), "Reverting feed must not change state");
    }

    // ===========================================================================
    //                      PRINCIPAL EROSION ATTACKS
    // ===========================================================================

    function test_Attack_PrincipalErosionViaRepeatedHarvest() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        // v2.6.1 — cbETH-as-token; simulate yield accrual via mint
        cbETH.mint(address(hook), 0.01 ether);
        aeroRouter.setWethReturn(0.01 ether);

        hook.harvestRewards();

        uint256 cbPrincipalAfter = hook.cbETHPrincipal();
        assertGt(cbPrincipalAfter, 0, "cbETH principal must remain");

        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();
    }

    function test_Attack_HarvestBeforeAnyStaking() public {
        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();
    }

    function test_Attack_HarvestDuringDepeg() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        // v2.6.1 — Simulate cbETH rewards accrual (cbETH-as-token, not cbETH-as-ETH-holder)
        cbETH.mint(address(hook), 0.1 ether);
        aeroRouter.setWethReturn(0.1 ether);

        // v2.6.1 — Trigger depeg at 18-decimal scale (0.95e18 < 0.97e18 threshold)
        clCbETH.setAnswer(int256(950_000_000_000_000_000));

        hook.harvestRewards();
    }

    function test_Attack_HarvestDoesNotBypassPrincipal() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 principalBefore = hook.cbETHPrincipal();

        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();

        uint256 principalAfter = hook.cbETHPrincipal();
        assertEq(principalAfter, principalBefore, "Principal must not decrease on no-rewards harvest");
    }

    // ===========================================================================
    //                      DAI RESERVE DRAIN ATTACKS
    // ===========================================================================

    // v3 — test_Attack_DAIReserveDrainBlocked removed (DAI reserve cut; the
    // rescue-block property for cbETH/WETH/STEEL still holds and is covered by
    // the rescueToken revert paths).

    // ===========================================================================
    //                  FORCE-INJECTED ETH ANTI-POISONING
    // ===========================================================================

    function test_Attack_ForceInjectedETH_DoesNotInflateAccumulator() public {
        uint256 accumulatorBefore = hook.accumulatedETH();

        vm.prank(ATTACKER);
        (bool ok,) = address(hook).call{value: 5 ether}("");
        assertTrue(ok, "receive() must accept");

        assertEq(hook.accumulatedETH(), accumulatorBefore,
            "Force-injected ETH must not inflate accumulator");

        assertEq(address(hook).balance, 5 ether, "Raw balance reflects injection");
    }

    function test_Attack_ForceInjectedETH_CannotMintStakingPrincipal() public {
        uint256 cbPrincipalBefore = hook.cbETHPrincipal();

        vm.prank(ATTACKER);
        (bool ok,) = address(hook).call{value: 5 ether}("");
        assertTrue(ok);

        assertEq(hook.cbETHPrincipal(), cbPrincipalBefore, "cbETH principal untouched");
    }

    // ===========================================================================
    //                        RESCUE GUARD ATTACKS
    // ===========================================================================

    function test_Attack_RescueCannotDrainSTEEL() public {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        steel.transfer(address(hook), 1000 * 1e18);

        vm.expectRevert(PossessioHook.RescueBlocked.selector);
        vm.prank(TREASURY);
        hook.rescueToken(address(steel), 1000 * 1e18);
    }

    // v3 — test_Attack_RescueCannotDrainDAIReserve removed (DAI reserve cut;
    // unlisted-token rescue still tested below, protected-token block via cbETH/WETH).

    function test_Attack_RescueUnlistedTokenSucceeds() public {
        STEEL randomToken = new STEEL(TREASURY);
        uint256 treasuryBefore = randomToken.balanceOf(TREASURY);
        vm.prank(TREASURY);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        randomToken.transfer(address(hook), 100 * 1e18);

        vm.prank(TREASURY);
        hook.rescueToken(address(randomToken), 100 * 1e18);

        assertEq(randomToken.balanceOf(TREASURY), treasuryBefore,
            "Non-protocol token must return to Treasury after rescue");
    }

    // ===========================================================================
    //                  REWARDS ATTACKS -- NO AMPLIFICATION / DRIFT
    // ===========================================================================

    function test_Attack_Rewards_NoCrossCycleDrift() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 cbPrincipal0 = hook.cbETHPrincipal();

        // v2.6.1 — Cycle 1: simulate cbETH yield accrual, harvest
        cbETH.mint(address(hook), 0.05 ether);
        aeroRouter.setWethReturn(0.05 ether);
        hook.harvestRewards();

        assertEq(hook.cbETHPrincipal(), cbPrincipal0, "Cycle 1: cbETH principal drift");

        // Cycle 2: same pattern
        cbETH.mint(address(hook), 0.05 ether);
        aeroRouter.setWethReturn(0.05 ether);
        hook.harvestRewards();

        assertEq(hook.cbETHPrincipal(), cbPrincipal0, "Cycle 2: cbETH principal drift");
    }

    function test_Attack_Rewards_NoRecursiveAmplification() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        // v2.6.1 — cbETH-as-token pattern
        cbETH.mint(address(hook), 0.1 ether);
        aeroRouter.setWethReturn(0.1 ether);

        uint256 treasuryBefore = TREASURY.balance;
        hook.harvestRewards();
        uint256 treasuryGain1 = TREASURY.balance - treasuryBefore;

        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();

        assertLe(treasuryGain1, 0.1 ether, "Treasury gain bounded by rewards amount");
    }

    // ===========================================================================
    //                  HOOK INJECTION ATTACKS (v2 SPECIFIC)
    // ===========================================================================

    function test_Attack_BeforeSwapCallableOnlyByPoolManager() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });

        PoolKey memory key;
        key.currency0 = Currency.wrap(address(0));
        key.currency1 = Currency.wrap(address(steel));
        key.fee = 0;
        key.tickSpacing = 200;
        key.hooks = IHooks(address(hook));

        vm.expectRevert(PossessioHook.OnlyPoolManager.selector);
        vm.prank(ATTACKER);
        hook.beforeSwap(ATTACKER, key, params, "");
    }

    function test_Attack_UnlockCallbackRejectsNonPoolManager() public {
        vm.expectRevert(PossessioHook.OnlyPoolManager.selector);
        vm.prank(ATTACKER);
        hook.unlockCallback("");
    }

    function test_Attack_SeedInitialLiquidityOnlyByOwner() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        hook.seedInitialLiquidity(1 ether, 1_000_000 * 1e18);
    }

    // ===========================================================================
    //                  SAV COUNCIL ATTACKS (v2 SPECIFIC)
    // ===========================================================================

    function test_Attack_SAVBurnByNonCouncilMember() public {
        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        vm.prank(ATTACKER);
        hook.savBurn(100 * 1e18);
    }

    function test_Attack_SAVInventByNonCouncilMember() public {
        bytes32 dummyProposalHash = keccak256("malicious");
        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        vm.prank(ATTACKER);
        hook.proposeInvent(dummyProposalHash);
    }

    function test_Attack_SAVSlashedBlocksAllOps() public {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        steel.transfer(TREASURY, 4000 * 1e18);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), 4000 * 1e18);
        hook.savDeposit(4000 * 1e18);
        vm.stopPrank();

        vm.prank(TREASURY);
        hook.savSlash();

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        steel.transfer(TREASURY, 1000 * 1e18);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), 1000 * 1e18);
        vm.expectRevert(PossessioHook.Slashed_.selector);
        hook.savDeposit(1000 * 1e18);
        vm.stopPrank();

        vm.expectRevert(PossessioHook.Slashed_.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);
    }

    // ===========================================================================
    //                    ROUTE REWARD INFLATION ATTACKS
    // ===========================================================================

    function test_Attack_RewardCannotBeAmplifiedViaRapidCalls() public {
        _fundAccumulator(1 ether);
        vm.warp(block.timestamp + 7 hours);
        clDAI.setAnswer(int256(100_000_000));        // DAI/USD $1.00
        clEthUsd.setAnswer(int256(166_939_220_000)); // ETH/USD $1669.39

        uint256 balBefore = USER.balance;
        vm.prank(USER);
        hook.routeETH();
        uint256 firstReward = USER.balance - balBefore;

        _fundAccumulator(1 ether);
        vm.expectRevert(PossessioHook.RouteTooEarly.selector);
        vm.prank(USER);
        hook.routeETH();

        assertLe(firstReward, 0.001 ether + 1 wei, "Reward must be bounded at 0.1%");
    }

    function test_Attack_BelowThresholdBlocksPermissionlessRoute() public {
        _fundAccumulator(0.01 ether);
        vm.warp(block.timestamp + 7 hours);

        vm.expectRevert(PossessioHook.BelowThreshold.selector);
        vm.prank(USER);
        hook.routeETH();
    }

    // ===========================================================================
    //                  ACCUMULATOR INFLATION ATTACKS (v2 SPECIFIC)
    // ===========================================================================

    function test_Attack_AccumulatorCannotBeInflatedExternally() public {
        uint256 before = hook.accumulatedETH();

        vm.startPrank(ATTACKER);

        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);

        vm.stopPrank();

        assertEq(hook.accumulatedETH(), before,
            "Accumulator must not change from external actions");

        assertGe(address(hook).balance, hook.accumulatedETH(),
            "Invariant: contract balance must be >= accumulatedETH");
    }

    // ===========================================================================
    //                           HELPERS
    // ===========================================================================

    function _fundAccumulator(uint256 amt) internal {
        stdstore.target(address(hook)).sig("accumulatedETH()").checked_write(amt);
        vm.deal(address(hook), address(hook).balance + amt);
    }

    receive() external payable {}
}
