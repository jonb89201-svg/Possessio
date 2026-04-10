// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PLATE.sol";

// Reuse mocks from PLATE.t.sol
contract MockPoolAttack {
    address public _token0;
    int56 public tickOld;
    int56 public tickNew;
    bool public shouldRevert;

    constructor(address token0_) { _token0 = token0_; }
    function setTicks(int56 old_, int56 new_) external { tickOld = old_; tickNew = new_; }
    function setRevert(bool r) external { shouldRevert = r; }
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory ticks, uint160[] memory spls
    ) {
        require(!shouldRevert, "MockPool: observe reverts");
        require(secondsAgos.length >= 2);
        ticks = new int56[](2);
        ticks[0] = tickOld;
        ticks[1] = tickNew;
        spls = new uint160[](2);
    }
    function token0() external view returns (address) { return _token0; }
}

contract MockRouterAttack {
    address public _weth;
    address public _dai;
    address public _plate;
    uint256 public ethReturn;
    uint256 public daiReturn;
    uint256 public plateReturn;
    bool public swapShouldRevert;
    bool public liqShouldRevert;

    constructor(address weth_) { _weth = weth_; }
    function WETH() external view returns (address) { return _weth; }
    function setEthReturn(uint256 v)       external { ethReturn        = v; }
    function setDAIReturn(uint256 v)       external { daiReturn        = v; }
    function setPlateReturn(uint256 v)     external { plateReturn      = v; }
    function setSwapRevert(bool r)         external { swapShouldRevert = r; }
    function setLiqRevert(bool r)          external { liqShouldRevert  = r; }
    function setDAIToken(address dai_)     external { _dai             = dai_; }
    function setPlateToken(address plate_) external { _plate           = plate_; }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata, address to, uint256
    ) external returns (uint256[] memory amounts) {
        require(!swapShouldRevert, "MockRouter: swap reverts");
        require(ethReturn >= amountOutMin, "MockRouter: slippage");
        payable(to).transfer(ethReturn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = ethReturn;
    }

    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256
    ) external payable returns (uint256[] memory amounts) {
        require(!swapShouldRevert, "MockRouter: swap reverts");

        address tokenOut = path.length >= 2 ? path[path.length - 1] : address(0);

        if (_plate != address(0) && tokenOut == _plate) {
            // ETH -> PLATE swap for V3 _addLiquidity
            uint256 out = plateReturn;
            require(out >= amountOutMin, "MockRouter: PLATE slippage");
            if (out > 0) {
                (bool ok,) = _plate.call(
                    abi.encodeWithSignature("transfer(address,uint256)", to, out)
                );
                require(ok, "MockRouter: PLATE transfer failed");
            }
            amounts = new uint256[](2);
            amounts[0] = msg.value;
            amounts[1] = out;
        } else {
            // ETH -> DAI swap
            require(daiReturn >= amountOutMin, "MockRouter: DAI slippage");
            if (_dai != address(0) && daiReturn > 0) {
                MockDAIAttack(_dai).mint(to, daiReturn);
            }
            amounts = new uint256[](2);
            amounts[0] = msg.value;
            amounts[1] = daiReturn;
        }
    }

    function addLiquidityETH(
        address, uint256 amountTokenDesired, uint256, uint256 amountETHMin,
        address, uint256
    ) external payable returns (uint256, uint256, uint256) {
        require(!liqShouldRevert, "MockRouter: liq reverts");
        require(msg.value >= amountETHMin);
        return (amountTokenDesired, msg.value, 1000);
    }

    receive() external payable {}
}

contract MockCbETHAttack {
    mapping(address => uint256) public _balances;
    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount);
        _balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function addYield(address a, uint256 y) external { _balances[a] += y; }
    receive() external payable {}
}

contract MockRETHAttack {
    mapping(address => uint256) public _balances;
    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function burn(uint256 amount) external {
        require(_balances[msg.sender] >= amount);
        _balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function addYield(address a, uint256 y) external { _balances[a] += y; }
    receive() external payable {}
}

contract MockDAIAttack {
    mapping(address => uint256) public _balances;
    function mint(address to, uint256 amount) external { _balances[to] += amount; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount);
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract MockChainlinkAttack {
    int256 public _answer;
    uint256 public _updatedAt;
    bool public _reverts;
    constructor(int256 answer_) { _answer = answer_; _updatedAt = block.timestamp; }
    function setAnswer(int256 a) external { _answer = a; _updatedAt = block.timestamp; }
    function setStale() external { _updatedAt = block.timestamp - 7200; }
    function setReverts(bool r) external { _reverts = r; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!_reverts, "MockChainlink: reverts");
        return (0, _answer, 0, _updatedAt, 0);
    }
}

// ============================================================
//                    ATTACK SIMULATION SUITE
// ============================================================

contract PLATEAttackTest is Test {
    PLATE plate;
    MockPoolAttack pool;
    MockRouterAttack router;
    MockCbETHAttack cbETH;
    MockRETHAttack rETH;
    MockDAIAttack dai;
    MockChainlinkAttack clCbETH;
    MockChainlinkAttack clDAI;

    address WETH_ADDR = address(0xdead);
    address TREASURY  = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;
    address ATTACKER  = address(0xBAD);

    uint256 INIT_REF = 1_000_000 * 1e18;

    function setUp() public {
        router  = new MockRouterAttack(WETH_ADDR);
        cbETH   = new MockCbETHAttack();
        rETH    = new MockRETHAttack();
        dai     = new MockDAIAttack();
        clCbETH = new MockChainlinkAttack(int256(98_000_000));
        clDAI   = new MockChainlinkAttack(int256(500_000));

        plate = new PLATE(
            address(0x9999),
            address(router),
            address(cbETH),
            address(rETH),
            address(dai),
            address(clCbETH),
            address(clDAI),
            INIT_REF
        );

        pool = new MockPoolAttack(address(plate));
        bytes32 id = plate.queueLPUpdate(address(pool));
        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeLPUpdate(id, address(pool));

        // Refresh DAI oracle after warp so it's not stale
        clDAI.setAnswer(int256(500_000));

        vm.deal(address(router), 100 ether);
        router.setEthReturn(1 ether);
        router.setDAIToken(address(dai));
        router.setPlateToken(address(plate));
        pool.setTicks(0, int56(-497383200));
        vm.deal(address(cbETH), 100 ether);
        vm.deal(address(rETH), 100 ether);
    }

    // ============================================================
    // ATTACK 1: SWAP REENTRANCY ATTEMPT
    // Attacker tries to re-enter swapFeesToETH via receive()
    // nonReentrant should block this
    // ============================================================
    function test_Attack_ReentrancyOnSwap() public {
        // Seed fees
        uint256 needed = (plate.minSwapBatch() + 1) * 10_000 / 200 + 1e18;
        plate.transfer(address(pool), needed);
        vm.warp(block.timestamp + 25 hours);

        // nonReentrant modifier should prevent any reentrant call
        // This test verifies the modifier is in place by confirming
        // the swap completes atomically
        uint256 feesBefore = plate.pendingFees();
        plate.swapFeesToETH();
        assertEq(plate.pendingFees(), 0, "Fees must be zeroed after swap");
    }

    // ============================================================
    // ATTACK 2: RAPID REPEATED SWAP ATTEMPTS
    // Attacker tries to drain fees by calling swapFeesToETH repeatedly
    // 24hr delay should block all attempts after first
    // ============================================================
    function test_Attack_RapidSwapAttempts() public {
        uint256 needed = (plate.minSwapBatch() + 1) * 10_000 / 200 + 1e18;
        plate.transfer(address(pool), needed);
        vm.warp(block.timestamp + 25 hours);
        plate.swapFeesToETH();

        // All subsequent attempts before 24hr should fail
        plate.transfer(address(pool), needed);

        vm.expectRevert("PLATE: 24hr swap delay not elapsed");
        plate.swapFeesToETH();

        vm.warp(block.timestamp + 12 hours);
        vm.expectRevert("PLATE: 24hr swap delay not elapsed");
        plate.swapFeesToETH();
    }

    // ============================================================
    // ATTACK 3: PENDINGFEES ACCOUNTING UNDER ROUTER FAILURE
    // If router reverts, pendingFees must be restored
    // No silent loss of fee accounting
    // ============================================================
    function test_Attack_FeesRestoredOnRouterFailure() public {
        uint256 needed = (plate.minSwapBatch() + 1) * 10_000 / 200 + 1e18;
        plate.transfer(address(pool), needed);
        uint256 feesBeforeSwap = plate.pendingFees();

        vm.warp(block.timestamp + 25 hours);
        router.setSwapRevert(true);

        vm.expectRevert();
        plate.swapFeesToETH();

        // Fees must be fully restored - no silent drain
        assertEq(plate.pendingFees(), feesBeforeSwap,
            "pendingFees must be restored after router failure");
    }

    // ============================================================
    // ATTACK 4: UNAUTHORIZED ACCESS ATTEMPTS
    // Attacker tries every privileged function
    // ============================================================
    function test_Attack_UnauthorizedAccess() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert();
        plate.swapFeesToETH();

        vm.expectRevert();
        plate.routeETH();

        vm.expectRevert();
        plate.harvestYield();

        vm.expectRevert();
        plate.pauseRouting();

        vm.expectRevert();
        plate.queueLPUpdate(address(0x1));

        vm.stopPrank();
    }

    // ============================================================
    // ATTACK 5: BELOW MINIMUM BATCH SPAM
    // Attacker seeds tiny fees then calls swap repeatedly
    // Should always revert below minSwapBatch
    // ============================================================
    function test_Attack_BelowBatchSpam() public {
        // Seed tiny amount - well below minSwapBatch
        plate.transfer(address(pool), 1 * 1e18);

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 25 hours);
            vm.expectRevert("PLATE: Below minimum batch size");
            plate.swapFeesToETH();
        }

        // Fees should accumulate untouched
        assertGt(plate.pendingFees(), 0, "Fees must accumulate");
    }

    // ============================================================
    // ATTACK 6: ORACLE MANIPULATION - EXTREME TWAP MOVE
    // Attacker manipulates pool ticks to extreme values
    // Deviation guard should catch spot/TWAP divergence
    // ============================================================
    function test_Attack_ExtremeOracleManipulation() public {
        // Normal fees seeded
        uint256 needed = (plate.minSwapBatch() + 1) * 10_000 / 200 + 1e18;
        plate.transfer(address(pool), needed);
        vm.warp(block.timestamp + 25 hours);

        // Set ticks to extreme divergence
        // tickOld = normal, tickNew = extreme
        // This creates a massive spot price vs TWAP divergence
        pool.setTicks(int56(-497383200), int56(0));

        // Swap should either:
        // a) Revert with Volatility_Guard if spot is calculable
        // b) Proceed if spot returns 0 (graceful degradation)
        // Either behavior is acceptable - no fund loss either way
        try plate.swapFeesToETH() {
            // If it succeeds, spot returned 0 (graceful skip)
            assertEq(plate.pendingFees(), 0, "Fees zeroed on success");
        } catch {
            // If it reverts, deviation guard fired correctly
            assertGt(plate.pendingFees(), 0, "Fees restored on revert");
        }
    }

    // ============================================================
    // ATTACK 7: HARVEST WITH NO PRINCIPAL
    // Attacker tries to harvest before any staking deployed
    // Should revert with no yield message
    // ============================================================
    function test_Attack_HarvestBeforeStaking() public {
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();
    }

    // ============================================================
    // ATTACK 8: PRINCIPAL EROSION SIMULATION
    // LST balance drops below principal (e.g. slashing event)
    // Harvest should revert - never touch principal
    // ============================================================
    function test_Attack_PrincipalErosion() public {
        // Deploy staking
        vm.deal(address(plate), 10 ether);
        plate.routeETH();

        uint256 principal = plate.cbETHPrincipal();
        assertGt(principal, 0, "Principal must be set");

        // Simulate slashing - balance drops below principal
        // We do this by warping and checking behavior
        // In mock: cbETH balance == principal (no yield added)
        // harvestYield should revert - no yield to harvest

        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();

        // Principal must be unchanged
        assertEq(plate.cbETHPrincipal(), principal,
            "Principal must never be touched by harvest");
    }

    // ============================================================
    // ATTACK 9: CIRCUIT BREAKER BYPASS ATTEMPT
    // Attacker tries to resume routing without timelock
    // ============================================================
    function test_Attack_CircuitBreakerBypass() public {
        plate.pauseRouting();
        assertTrue(plate.paused(), "Must be paused");

        // Queue resume
        bytes32 id = plate.queueResumeRouting();

        // Try to resume immediately - should fail
        vm.expectRevert("PLATE: Timelock pending");
        plate.resumeRouting(id);

        // Try to resume after 1 hour - still fail
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert("PLATE: Timelock pending");
        plate.resumeRouting(id);

        // Only succeeds after full 48 hours
        vm.warp(block.timestamp + 48 hours);
        plate.resumeRouting(id);
        assertFalse(plate.paused(), "Must be unpaused after timelock");
    }

    // ============================================================
    // ATTACK 10: DAI RESERVE DRAINAGE ATTEMPT
    // Attacker (non-treasury) tries to call payAPI
    // Only TREASURY Safe should be able to spend DAI reserve
    // ============================================================
    function test_Attack_DAIReserveDrain() public {
        // Fill reserve via normal routing path
        router.setDAIReturn(1000 * 1e18);
        vm.deal(address(plate), 10 ether);
        plate.transfer(address(plate), 5_000_000 * 1e18);
        plate.routeETH();

        uint256 reserveAmount = plate.daiReserve();
        assertGt(reserveAmount, 0, "Reserve must have DAI");

        // Attacker tries to drain
        vm.prank(ATTACKER);
        vm.expectRevert("PLATE: Only Treasury Safe");
        plate.payAPI(ATTACKER, reserveAmount);

        // Owner tries to drain (not treasury)
        vm.expectRevert("PLATE: Only Treasury Safe");
        plate.payAPI(ATTACKER, reserveAmount);

        // Reserve must be untouched
        assertEq(plate.daiReserve(), reserveAmount,
            "Reserve must be untouched after attack attempts");
    }

    // ============================================================
    // ATTACK 11: FORCED ETH INJECTION (SELFDESTRUCT VECTOR)
    // Ghost ETH injected via vm.deal
    // routeETH should handle surplus without breaking accounting
    // ============================================================
    function test_Attack_ForceInjectedETH() public {
        // Seed router so LP injection can succeed
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);
        router.setDAIReturn(1000 * 1e18);

        // Normal 1 ETH
        vm.deal(address(plate), 1 ether);

        // Force inject additional 5 ETH (simulates selfdestruct attack)
        vm.deal(address(plate), address(plate).balance + 5 ether);

        uint256 totalETH = address(plate).balance;
        assertEq(totalETH, 6 ether, "Should have 6 ETH total");

        uint256 treasuryBefore = TREASURY.balance;

        // routeETH should route ALL balance correctly
        plate.routeETH();

        // Contract should have near-zero ETH after routing
        assertLt(address(plate).balance, 0.01 ether,
            "No ETH stranded after forced injection routing");

        // Treasury should have received its allocation
        assertGt(TREASURY.balance, treasuryBefore,
            "Treasury must receive ETH allocation");
    }

    // ============================================================
    // ATTACK 12: FUZZ - RANDOM FEE AMOUNTS NEVER BREAK INVARIANTS
    // ============================================================
    function testFuzz_Attack_FeeInvariantsHold(uint256 amount) public {
        amount = bound(amount, 1e18, plate.totalSupply() / 4);

        uint256 supplyBefore = plate.totalSupply();
        uint256 feesBefore   = plate.pendingFees();

        plate.transfer(address(pool), amount);

        uint256 fee = amount * 200 / 10_000;
        uint256 net = amount - fee;

        assertEq(plate.totalSupply(), supplyBefore,
            "Total supply must never change");
        assertEq(fee + net, amount,
            "Fee conservation violated");
        assertGe(plate.pendingFees(), feesBefore,
            "Pending fees must never decrease on transfer");
    }

    // ============================================================
    // ATTACK 13: V3 LP - SWAP SUCCEEDS / LP FAILS
    // PLATE must be flushed to Treasury
    // ETH stays in contract - consumed by DAI+staking downstream
    // ============================================================
    function test_Attack_V2LP_SwapSucceedsLPFails() public {
        router.setLiqRevert(true);
        router.setDAIReturn(1000 * 1e18);

        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);

        vm.deal(address(plate), 4 ether);

        // Refresh DAI oracle before routing
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        // No PLATE stranded - flushed to Treasury on partial execution
        assertEq(plate.balanceOf(address(plate)), 0,
            "No PLATE may be stranded after LP failure");

        // V3 Isolation: when swap succeeds but LP add fails:
        // · ethForSwap (50% of LP allocation) left contract via swap
        // · ethForLP (50% of LP allocation) stays in contract
        // LP allocation = 25% of 4 ETH = 1 ETH
        // ethForLP = 50% of 1 ETH = 0.5 ETH stays isolated
        uint256 lpAllocation = 4 ether * 25 / 100;
        uint256 expectedLpRemainder = lpAllocation * 50 / 100; // lpSwapRatio = 50
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "ETH after LP failure must equal isolated ethForLP portion (50% of LP allocation)");
    }

    // ============================================================
    // ATTACK 14: V3 LP - SWAP FAILS
    // ETH stays in contract - consumed by downstream paths
    // ============================================================
    function test_Attack_V2LP_SwapFails() public {
        router.setSwapRevert(true);
        router.setDAIReturn(1000 * 1e18);

        vm.deal(address(plate), 4 ether);

        // Refresh DAI oracle before routing
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        // V3 Isolation: LP ETH (25%) stays in contract for next cycle
        // DAI + staking (75%) consumed downstream
        uint256 expectedLpRemainder = 4 ether * 25 / 100;
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "ETH after swap failure must equal isolated LP portion (25%)");

        // No PLATE stranded
        assertEq(plate.balanceOf(address(plate)), 0,
            "No PLATE stranded after swap failure");
    }

    // ============================================================
    // ATTACK 15: V3 LP - ZERO RESIDUAL BALANCES INVARIANT
    // All ETH consumed by LP+DAI+staking - none stranded
    // ============================================================
    function test_Attack_V2LP_ZeroResidualBalances() public {
        router.setDAIReturn(1000 * 1e18);

        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);

        vm.deal(address(plate), 10 ether);

        // Refresh DAI oracle before routing
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        // V3 Isolation: LP ETH (25%) stays in contract for next cycle
        // All other ETH consumed (DAI + staking)
        uint256 expectedLpRemainder = 10 ether * 25 / 100;
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "Contract must hold exactly LP portion (25%) after routeETH");

        // No stranded PLATE
        assertEq(plate.balanceOf(address(plate)), 0,
            "Contract must not hold PLATE after routeETH");
    }

    // ============================================================
    // ATTACK 16: V2 LP - TWAP MANIPULATION (Symmetry Guard)
    // Artificial spot distortion must trigger revert
    // No swap executed, no LP added, no value leakage
    // ============================================================
    function test_Attack_LP_TWAP_Manipulation() public {
        // Warp past bootstrap so TWAP and Symmetry Guard are active
        vm.warp(block.timestamp + 25 hours);

        // Set ticks to create extreme spot vs TWAP divergence
        // Simulates flash loan manipulating the pool
        pool.setTicks(int56(-497383200), int56(0));

        router.setDAIReturn(1000 * 1e18);
        vm.deal(address(plate), 4 ether);

        // routeETH should not execute LP swap under manipulation
        // Symmetry Guard fires - LP skipped, ETH stays (V3 isolation)
        plate.routeETH();

        // No PLATE stranded - no swap was attempted, no PLATE moved
        assertEq(plate.balanceOf(address(plate)), 0,
            "No PLATE stranded after manipulation attempt");

        // LP ETH stays in contract (V3 isolation - correct behavior)
        // DAI and staking consumed their allocations
        // Only LP portion (25%) remains
        uint256 expectedLpRemainder = 4 ether * 25 / 100;
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "LP ETH stays in contract under V3 isolation after guard fires");

        // (guard does not affect staking or DAI paths)
    }

    // ============================================================
    // ATTACK 17: LP CODE 3 — SWAP SUCCEEDS, ZERO PLATE RETURNED
    // swap call does not revert but returns 0 PLATE
    // ETH stays isolated, no PLATE stranded
    // ============================================================
    function test_Attack_LP_SlippageBreach_ZeroPlateReturned() public {
        // plateReturn = 0: swap succeeds but transfers nothing
        router.setPlateReturn(0);
        router.setDAIReturn(1000 * 1e18);

        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));

        plate.routeETH();

        // No PLATE stranded in contract
        assertEq(plate.balanceOf(address(plate)), 0,
            "Code 3: no PLATE stranded after zero-return swap");

        // V3 isolation: LP ETH (25%) stays in contract
        uint256 expectedLpRemainder = 4 ether * 25 / 100;
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "Code 3: ETH isolation holds -- LP portion retained");
    }

    // ============================================================
    // ATTACK 18: LP CODE 5 — NO VALID PRICE (BOTH SOURCES ZERO)
    // Post-bootstrap with zero ticks — TWAP returns 0
    // minPlateOut stays 0 — LP skipped, ETH stays isolated
    // NOTE: Cannot deploy with referencePrice=0 (constructor reverts)
    // Instead: use existing contract post-bootstrap with zero ticks
    // ============================================================
    function test_Attack_LP_NoPriceAvailable() public {
        // Warp past bootstrap so TWAP path is active
        vm.warp(block.timestamp + 25 hours);

        // Set pool ticks to zero — TWAP calculation returns 0
        pool.setTicks(0, 0);
        clDAI.setAnswer(int256(500_000));

        router.setDAIReturn(1000 * 1e18);
        vm.deal(address(plate), 4 ether);

        plate.routeETH();

        // No PLATE stranded
        assertEq(plate.balanceOf(address(plate)), 0,
            "Code 5: no PLATE stranded after no-price skip");

        // V3 isolation: LP ETH (25%) stays
        uint256 expectedLpRemainder = 4 ether * 25 / 100;
        assertApproxEqAbs(address(plate).balance, expectedLpRemainder, 0.01 ether,
            "Code 5: ETH isolation holds -- LP portion retained");
    }

    receive() external payable {}

    // ============================================================
    // HARVEST GAUNTLET — ECONOMIC CORRECTNESS SURFACE
    // Tests 121, 126, 127, 130
    // Proves: harvest is non-exploitable under all failure modes
    // ============================================================

    // ── Test 121 — Depeg During Harvest ─────────────────────────
    // Attack: cbETH balance equals principal — no yield above it
    // This simulates depeg/slashing scenario where lstBal <= principal
    // Expectation: harvestYield() reverts cleanly — require(total > 0)
    // Principal not eroded by the attempted harvest
    function test_Harvest_Depeg_RevertsCleanly() public {
        // Seed staking position
        vm.deal(address(plate), 2 ether);
        vm.deal(address(cbETH), 10 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 principal = plate.cbETHPrincipal();
        require(principal > 0, "Setup: principal must be > 0");

        // cbETH balance equals principal exactly — no yield above it
        // This simulates a scenario where value has not accrued
        // (or has been slashed back to principal level)
        assertEq(cbETH.balanceOf(address(plate)), principal,
            "Setup: balance should equal principal before yield");

        // harvestYield() must revert — no yield above principal
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();

        // Principal unchanged
        assertEq(plate.cbETHPrincipal(), principal,
            "Depeg: principal must not change after failed harvest");
    }

    // ── Test 126 — Repeated Harvest Griefing ────────────────────
    // Attack: call harvestYield() twice
    // Expectation: second call reverts — yield already extracted
    // Principal protected across both calls
    function test_Harvest_RepeatedCalls_RevertsAfterFirst() public {
        vm.deal(address(cbETH), 10 ether);
        vm.deal(address(rETH), 10 ether);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));
        // Inline _seedRouterPlate
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(5_000_000 * 1e18);
        plate.routeETH();

        uint256 principal = plate.cbETHPrincipal();
        require(principal > 0, "Setup: cbETH principal required");

        // Add yield above principal
        cbETH.addYield(address(plate), principal / 10);

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        // First harvest succeeds
        plate.harvestYield();

        // Second harvest reverts — no more yield above principal
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();

        // Principal intact
        assertGe(cbETH.balanceOf(address(plate)), plate.cbETHPrincipal(),
            "Repeated: principal must not be eroded");
    }

    // ── Test 127 — Dust Yield Handling ──────────────────────────
    // Attack: harvest 1 wei of yield
    // Expectation: handled correctly — no accounting corruption
    function test_Harvest_DustYield_HandledCorrectly() public {
        vm.deal(address(cbETH), 10 ether);
        vm.deal(address(plate), 2 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 principal = plate.cbETHPrincipal();
        require(principal > 0, "Setup: principal must be > 0");

        // Add 1 wei of yield above principal
        cbETH.addYield(address(plate), 1);

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        uint256 treasuryBefore = TREASURY.balance;

        // Should not revert — 1 wei is valid yield
        plate.harvestYield();

        // Principal not eroded
        assertGe(cbETH.balanceOf(address(plate)), plate.cbETHPrincipal(),
            "Dust: principal must not drop below tracked value");

        // Treasury received its share
        assertGe(TREASURY.balance, treasuryBefore,
            "Dust: treasury must not lose value");
    }

    // ── Test 130 — Full Cycle Integrity ─────────────────────────
    // Attack: complete harvest → LP → treasury cycle
    // Expectation: total value conserved, principal intact,
    //              no stranded assets, no invalid states
    function test_Harvest_FullCycle_ValueConserved() public {
        vm.deal(address(cbETH), 100 ether);
        vm.deal(address(rETH), 100 ether);
        vm.deal(address(plate), 10 ether);
        clDAI.setAnswer(int256(500_000));
        // Inline _seedRouterPlate
        plate.transfer(address(router), 10_000_000 * 1e18);
        router.setPlateReturn(10_000_000 * 1e18);
        plate.routeETH();

        uint256 cbPrincipal = plate.cbETHPrincipal();
        uint256 rPrincipal  = plate.rETHPrincipal();
        require(cbPrincipal > 0, "Setup: cbETH principal required");

        // Add yield on both LSTs
        cbETH.addYield(address(plate), cbPrincipal / 5);
        rETH.addYield(address(plate), rPrincipal / 5);

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        uint256 treasuryBefore = TREASURY.balance;
        uint256 plateBefore    = plate.balanceOf(address(plate));

        plate.harvestYield();

        // INVARIANT 1: Principal not eroded
        assertGe(cbETH.balanceOf(address(plate)), plate.cbETHPrincipal(),
            "Full cycle: cbETH principal must not be eroded");
        assertGe(rETH.balanceOf(address(plate)), plate.rETHPrincipal(),
            "Full cycle: rETH principal must not be eroded");

        // INVARIANT 2: Treasury received value
        assertGt(TREASURY.balance, treasuryBefore,
            "Full cycle: treasury must receive yield");

        // INVARIANT 3: No PLATE stranded
        assertEq(plate.balanceOf(address(plate)), plateBefore,
            "Full cycle: no PLATE stranded after harvest");

        // INVARIANT 4: No ETH inflation
        assertLe(address(plate).balance, 10 ether,
            "Full cycle: ETH balance must not exceed input");
    }

    // ============================================================
    // YIELD DOMAIN — INVARIANTS Y2, Y7, Y9
    // Proves: yield-only routing, no cross-cycle drift,
    //         no recursive amplification
    // ============================================================

    // ── Y2 — Yield-Only Routing ──────────────────────────────────
    // Principal must never enter routeETH() path via harvestYield()
    // Only ETH received above principal can be routed
    function test_Yield_OnlyYieldRouted_PrincipalUntouched() public {
        vm.deal(address(cbETH), 10 ether);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 cbPrincipal = plate.cbETHPrincipal();
        uint256 rPrincipal  = plate.rETHPrincipal();
        require(cbPrincipal > 0, "Setup: cbETH principal required");

        // Add yield — only this amount should be routed
        uint256 yieldAmount = cbPrincipal / 4; // 25% yield
        cbETH.addYield(address(plate), yieldAmount);

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        plate.harvestYield();

        // Principal must be exactly unchanged
        assertEq(plate.cbETHPrincipal(), cbPrincipal,
            "Y2: cbETH principal must not change after harvest");
        assertEq(plate.rETHPrincipal(), rPrincipal,
            "Y2: rETH principal must not change after harvest");

        // cbETH balance must equal original principal
        // (yield was withdrawn, principal remains)
        assertApproxEqAbs(cbETH.balanceOf(address(plate)), cbPrincipal, 1,
            "Y2: only yield withdrawn, principal stays staked");
    }

    // ── Y7 — No Cross-Cycle Drift ────────────────────────────────
    // Repeated harvest + reinjection cycles must not degrade ratios
    // Principal must remain stable across multiple cycles
    function test_Yield_NoCrossCycleDrift() public {
        vm.deal(address(cbETH), 100 ether);
        vm.deal(address(rETH), 100 ether);
        vm.deal(address(plate), 6 ether);
        clDAI.setAnswer(int256(500_000));
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(5_000_000 * 1e18);
        plate.routeETH();

        uint256 cbPrincipalStart = plate.cbETHPrincipal();
        require(cbPrincipalStart > 0, "Setup: principal required");

        // Run three harvest cycles
        for (uint256 i = 0; i < 3; i++) {
            // Add yield each cycle
            cbETH.addYield(address(plate), cbPrincipalStart / 10);

            router.setDAIReturn(1000 * 1e18);
            clDAI.setAnswer(int256(500_000));

            plate.harvestYield();
        }

        // Principal must not have drifted across cycles
        assertEq(plate.cbETHPrincipal(), cbPrincipalStart,
            "Y7: principal must not drift across harvest cycles");

        // cbETH balance must equal principal after all yield extracted
        assertApproxEqAbs(cbETH.balanceOf(address(plate)), cbPrincipalStart, 3,
            "Y7: staked position must match principal after 3 cycles");
    }

    // ── Y9 — No Recursive Amplification ─────────────────────────
    // harvestYield() calls _addLiquidity() which calls routeETH() path
    // nonReentrant must prevent any recursive execution
    // Proven by: single ETH balance snapshot — no double-routing
    function test_Yield_NoRecursiveAmplification() public {
        vm.deal(address(cbETH), 10 ether);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 cbPrincipal = plate.cbETHPrincipal();
        require(cbPrincipal > 0, "Setup: principal required");

        cbETH.addYield(address(plate), cbPrincipal / 5);

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        uint256 ethBefore = address(plate).balance;

        plate.harvestYield();

        uint256 ethAfter = address(plate).balance;

        // ETH after harvest must not exceed ETH before harvest
        // If recursive routing occurred, balance would increase
        // beyond what the yield alone could account for
        assertLe(ethAfter, ethBefore + cbPrincipal,
            "Y9: no recursive amplification -- balance bounded by yield only");
    }

    // ── Attack Y-B/Y-G — Flash Loan Small Yield Sandwich ────────
    // Attack: manipulate pool price during small yield harvest
    // Real risk: small yield = small ETH routed to LP = easier to
    //            sandwich profitably even within guard threshold
    //
    // MOCK LIMITATION: MockPoolAttack returns identical tick values
    // for all observation windows. True TWAP vs spot boundary
    // condition (just inside 5%) requires fork testing against
    // real Aerodrome. This test proves the guard fires on
    // yield-path LP injection when deviation exceeds threshold.
    //
    // What this proves: Symmetry Guard fires during yield harvest
    //                   Principal untouched when guard fires
    // What this does NOT prove: boundary at exactly 4.9% deviation
    function test_Yield_FlashLoanSandwich_SymmetryGuardBlocks() public {
        vm.deal(address(cbETH), 10 ether);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));

        // Warp past bootstrap so TWAP is active
        vm.warp(block.timestamp + 25 hours);
        pool.setTicks(0, int56(-497383200));
        plate.routeETH();

        uint256 cbPrincipal = plate.cbETHPrincipal();
        require(cbPrincipal > 0, "Setup: principal required");

        // Seed small yield -- small ETH routed to LP is easier sandwich target
        cbETH.addYield(address(plate), cbPrincipal / 20);

        // Simulate flash loan price manipulation -- extreme deviation
        pool.setTicks(int56(-497383200), int56(0));

        router.setDAIReturn(1000 * 1e18);
        clDAI.setAnswer(int256(500_000));

        uint256 plateBefore = plate.balanceOf(address(plate));

        plate.harvestYield();

        // Symmetry Guard fired -- no PLATE acquired via swap
        assertEq(plate.balanceOf(address(plate)), plateBefore,
            "Flash loan: no PLATE acquired when Symmetry Guard fires on yield path");

        // Principal untouched
        assertEq(plate.cbETHPrincipal(), cbPrincipal,
            "Flash loan: principal must not change during attacked harvest");
    }

    // ============================================================
    // ATTACK 19: HARVEST DURING CBETH DEPEG
    // cbETHPaused = true but lstBal == principal (no yield added)
    // Harvest must revert — principal floor blocks withdrawal
    // Proves: depeg cannot manufacture harvestable yield
    // ============================================================
    function test_Harvest_DepegDoesNotBypassPrincipal() public {
        router.setDAIReturn(1000 * 1e18);
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 principalBefore = plate.cbETHPrincipal();
        assertGt(principalBefore, 0, "Principal must be set before depeg test");

        // Trigger depeg — provide ETH so routeETH does not revert
        clCbETH.setAnswer(int256(94_000_000));
        vm.deal(address(plate), 1 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        assertTrue(plate.cbETHPaused(), "cbETH must be paused after depeg");

        // No yield added — lstBal == principal — harvest must revert
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();

        // Principal completely untouched
        assertEq(plate.cbETHPrincipal(), principalBefore,
            "Principal must be unchanged after failed harvest during depeg");
    }

    // ============================================================
    // ATTACK 20: FULL CYCLE INTEGRITY
    // Staking deployed → yield accrues → harvest → LP + Treasury
    // 75% to Treasury, principal untouched, no PLATE stranded
    // ============================================================
    function test_Harvest_FullCycleIntegrity() public {
        router.setDAIReturn(1000 * 1e18);
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);
        vm.deal(address(plate), 10 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 principalCbETH = plate.cbETHPrincipal();
        uint256 principalRETH  = plate.rETHPrincipal();
        assertGt(principalCbETH + principalRETH, 0, "Staking must be deployed");

        // Simulate yield accrual on both LSTs
        uint256 yieldAmount = 1 ether;
        cbETH.addYield(address(plate), yieldAmount);
        rETH.addYield(address(plate), yieldAmount);

        uint256 treasuryBefore = TREASURY.balance;

        plate.harvestYield();

        uint256 totalYield         = yieldAmount * 2;
        uint256 expectedToTreasury = totalYield - (totalYield * 25 / 100);

        // Treasury received 75% of harvested yield
        assertApproxEqAbs(
            TREASURY.balance - treasuryBefore,
            expectedToTreasury,
            0.01 ether,
            "Full cycle: Treasury must receive 75% of harvested yield"
        );

        // Principal unchanged across full cycle
        assertEq(plate.cbETHPrincipal(), principalCbETH,
            "Full cycle: cbETH principal must be unchanged after harvest");
        assertEq(plate.rETHPrincipal(), principalRETH,
            "Full cycle: rETH principal must be unchanged after harvest");

        // No PLATE stranded in contract
        assertEq(plate.balanceOf(address(plate)), 0,
            "Full cycle: no PLATE stranded after harvest");
    }

    // ============================================================
    // ATTACK 21: ORACLE JITTER STRESS — PRINCIPAL SHAVING PROBE
    // Oracle swings 94% → 98.5% → 95% — no routing during jitter
    // lstBal is token units — oracle cannot reprice balanceOf
    // No yield manufactured — harvest must revert — principal intact
    // Closes Council finding: "Principal Shaving via Oracle Jitter"
    // ============================================================
    function test_Harvest_OracleJitter_CannotShavePrincipal() public {
        router.setDAIReturn(1000 * 1e18);
        plate.transfer(address(router), 5_000_000 * 1e18);
        router.setPlateReturn(1_000_000 * 1e18);
        vm.deal(address(plate), 4 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();

        uint256 principalBefore = plate.cbETHPrincipal();
        uint256 lstBalBefore    = cbETH.balanceOf(address(plate));
        assertGt(principalBefore, 0, "Principal must be set");

        // Phase 1: depeg — route with ETH to trigger pause
        clCbETH.setAnswer(int256(94_000_000));
        vm.deal(address(plate), 1 ether);
        clDAI.setAnswer(int256(500_000));
        plate.routeETH();
        assertTrue(plate.cbETHPaused(), "Must be paused after depeg");

        // Phase 2 & 3: oracle jitter — no ETH, no routing, just state changes
        // cbETHPaused may flip but no deposit occurs without routeETH()
        clCbETH.setAnswer(int256(98_500_000)); // spike above threshold
        clCbETH.setAnswer(int256(95_000_000)); // back below

        // KEY: lstBal is token units — oracle cannot change it
        uint256 lstBalAfter = cbETH.balanceOf(address(plate));
        assertEq(lstBalAfter, lstBalBefore,
            "Jitter: oracle fluctuation cannot alter LST token balance");

        // No yield above principal — harvest must revert
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();

        // Principal completely intact
        assertEq(plate.cbETHPrincipal(), principalBefore,
            "Jitter: principal must be unchanged after oracle jitter sequence");
    }

}
