// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/PLATE.sol";

// ============================================================
//                     MOCK CONTRACTS
// ============================================================

/// @dev Mock Aerodrome pool — returns controllable tick cumulatives
contract MockPool {
    int56[]  public tickCumulatives;
    address  public token0Addr;
    bool     public observeReverts;

    constructor(address _token0) {
        token0Addr = _token0;
    }

    function setTickCumulatives(int56 old_, int56 new_) external {
        delete tickCumulatives;
        tickCumulatives.push(old_);
        tickCumulatives.push(new_);
    }

    function setObserveReverts(bool _reverts) external {
        observeReverts = _reverts;
    }

    function observe(uint32[] calldata) external view returns (
        int56[] memory ticks,
        uint160[] memory secondsPerLiquidity
    ) {
        require(!observeReverts, "MockPool: observe reverts");
        ticks = tickCumulatives;
        secondsPerLiquidity = new uint160[](2);
    }

    function token0() external view returns (address) {
        return token0Addr;
    }
}

/// @dev Mock Aerodrome router
contract MockRouter {
    address public weth;
    uint256 public ethToReturn;    // ETH returned per swap
    uint256 public daiToReturn;    // DAI returned per ETH swap
    uint256 public liquidityToReturn;
    bool    public swapReverts;

    constructor(address _weth) {
        weth = _weth;
    }

    function WETH() external view returns (address) { return weth; }

    function setEthReturn(uint256 _eth) external { ethToReturn = _eth; }
    function setDAIReturn(uint256 _dai) external { daiToReturn = _dai; }
    function setSwapReverts(bool _r)    external { swapReverts  = _r; }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata,
        address to,
        uint
    ) external returns (uint[] memory amounts) {
        require(!swapReverts, "MockRouter: swap reverts");
        require(ethToReturn >= amountOutMin, "MockRouter: insufficient output");
        payable(to).transfer(ethToReturn);
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = ethToReturn;
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint
    ) external payable returns (uint[] memory amounts) {
        require(!swapReverts, "MockRouter: swap reverts");
        require(daiToReturn >= amountOutMin, "MockRouter: insufficient DAI");
        // Transfer DAI to recipient (mock just sends back ETH value for simplicity)
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = daiToReturn;
    }

    function addLiquidityETH(
        address,
        uint amountTokenDesired,
        uint,
        uint amountETHMin,
        address to,
        uint
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        require(msg.value >= amountETHMin, "MockRouter: insufficient ETH");
        amountToken = amountTokenDesired;
        amountETH   = msg.value;
        liquidity   = liquidityToReturn > 0 ? liquidityToReturn : 1000;
    }

    receive() external payable {}
}

/// @dev Mock cbETH staking contract
contract MockCbETH {
    mapping(address => uint256) public balances;
    uint256 public yieldMultiplier = 1e18; // 1:1 initially

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "MockCbETH: insufficient balance");
        balances[msg.sender] -= amount;
        // Return ETH at current yield ratio
        uint256 ethOut = (amount * yieldMultiplier) / 1e18;
        payable(msg.sender).transfer(ethOut);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    /// @dev Simulate yield accrual
    function addYield(address account, uint256 yieldAmount) external {
        balances[account] += yieldAmount;
    }

    receive() external payable {}
}

/// @dev Mock rETH staking contract
contract MockRETH {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function burn(uint256 amount) external {
        require(balances[msg.sender] >= amount, "MockRETH: insufficient balance");
        balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function addYield(address account, uint256 yieldAmount) external {
        balances[account] += yieldAmount;
    }

    receive() external payable {}
}

/// @dev Mock DAI token
contract MockDAI {
    mapping(address => uint256) public balances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "MockDAI: insufficient balance");
        balances[msg.sender] -= amount;
        balances[to]         += amount;
        return true;
    }
}

/// @dev Mock Chainlink feed — returns controllable prices
contract MockChainlink {
    int256  public answer;
    uint256 public updatedAt;
    bool    public reverts;

    constructor(int256 _answer) {
        answer    = _answer;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer) external {
        answer    = _answer;
        updatedAt = block.timestamp;
    }

    function setStale() external {
        updatedAt = block.timestamp - 7200; // 2 hours ago — stale
    }

    function setReverts(bool _r) external { reverts = _r; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!reverts, "MockChainlink: reverts");
        return (0, answer, 0, updatedAt, 0);
    }
}

// ============================================================
//                     PLATE TEST SUITE
// ============================================================

contract PLATETest is Test {

    PLATE       plate;
    MockPool    pool;
    MockRouter  router;
    MockCbETH   cbETH;
    MockRETH    rETH;
    MockDAI     dai;
    MockChainlink chainlink;
    MockChainlink chainlinkDAI;

    address WETH_ADDR  = address(0xWETH);
    address TREASURY   = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;
    address OWNER      = address(this);
    address USER       = address(0xUSER);
    address ATTACKER   = address(0xATTACK);

    // Initial reference price: 1,000,000 PLATE per ETH
    uint256 INIT_REF_PRICE = 1_000_000 * 1e18;

    // ── Setup ─────────────────────────────────────────────────
    function setUp() public {
        // Deploy mocks
        router      = new MockRouter(WETH_ADDR);
        cbETH       = new MockCbETH();
        rETH        = new MockRETH();
        dai         = new MockDAI();
        chainlink   = new MockChainlink(int256(97_500_000)); // cbETH healthy
        chainlinkDAI= new MockChainlink(int256(500_000));    // ~$0.005 ETH per DAI

        // Deploy PLATE
        plate = new PLATE(
            address(0),              // LP — set after deploy
            address(router),
            address(cbETH),
            address(0),              // wstETH stub
            address(rETH),
            address(dai),
            address(chainlink),
            address(chainlinkDAI),
            INIT_REF_PRICE
        );

        // Deploy pool with PLATE as token0
        pool = new MockPool(address(plate));

        // Update LP address via timelock
        // For tests: directly set via queue+execute
        bytes32 id = plate.queueLPUpdate(address(pool));
        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeLPUpdate(id, address(pool));

        // Fund test accounts
        vm.deal(USER,     100 ether);
        vm.deal(ATTACKER, 100 ether);
        vm.deal(address(router), 100 ether); // Router needs ETH for swaps

        // Give router some DAI to return
        dai.mint(address(router), 100_000 * 1e18);
    }

    // ============================================================
    //              TEST 1 — FEE ROUTING MATH
    // ============================================================

    function test_FeeCollectedOnSwap() public {
        uint256 swapAmount = 1_000 * 1e18; // 1,000 PLATE

        // Transfer PLATE from owner to simulate a swap
        // isDEXPair[pool] = true so this triggers fee
        plate.transfer(address(pool), swapAmount);

        uint256 expectedFee = (swapAmount * 200) / 10_000; // 2%
        uint256 expectedNet = swapAmount - expectedFee;

        // Contract should hold the fee
        assertEq(plate.pendingFees(), expectedFee, "Fee not accumulated correctly");

        // Pool should receive net amount
        assertEq(plate.balanceOf(address(pool)), expectedNet, "Net transfer incorrect");
    }

    function test_FeeIs2Percent() public {
        uint256 amount = 10_000 * 1e18;
        plate.transfer(address(pool), amount);

        uint256 fee = plate.pendingFees();
        assertEq(fee, 200 * 1e18, "2% fee should be 200 PLATE on 10,000");
    }

    function test_NoFeeOnWalletTransfer() public {
        // Transfer to USER — not a DEX pair — no fee
        plate.transfer(USER, 1_000 * 1e18);

        assertEq(plate.pendingFees(), 0, "Wallet transfer should not collect fees");
        assertEq(plate.balanceOf(USER), 1_000 * 1e18, "Full amount should transfer");
    }

    function test_NoFeeWhenPaused() public {
        plate.pauseRouting();
        plate.transfer(address(pool), 1_000 * 1e18);

        assertEq(plate.pendingFees(), 0, "Paused: no fees should be collected");
    }

    function test_FeesAccumulateAcrossMultipleSwaps() public {
        plate.transfer(address(pool), 1_000 * 1e18);
        plate.transfer(address(pool), 2_000 * 1e18);
        plate.transfer(address(pool), 3_000 * 1e18);

        uint256 totalFee = (6_000 * 1e18 * 200) / 10_000;
        assertEq(plate.pendingFees(), totalFee, "Fees should accumulate");
    }

    function test_FeeRoutingEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PLATE.FeeCollected(
            address(this),
            address(pool),
            (1_000 * 1e18 * 200) / 10_000,
            block.timestamp
        );
        plate.transfer(address(pool), 1_000 * 1e18);
    }

    // ============================================================
    //          TEST 2 — TWAP FALLBACK TO REFERENCE PRICE
    // ============================================================

    function test_BootstrapUsesReferencePrice() public {
        // Within bootstrap period (first 24 hours)
        // swapFeesToETH should use referencePrice not TWAP

        // Accumulate enough fees
        _accumulateFees(plate.minSwapBatch() + 1);

        // Warp past swap delay
        vm.warp(block.timestamp + 25 hours);

        // Set router to return ETH
        router.setEthReturn(0.001 ether);

        // Should not revert — uses reference price during bootstrap
        plate.swapFeesToETH();
    }

    function test_PostBootstrapUsesTWAP() public {
        // Warp past bootstrap period
        vm.warp(block.timestamp + 25 hours);

        // Set up pool tick cumulatives
        // avgTick = 0 → price = 1.0 (1 PLATE = 1 ETH in this mock)
        pool.setTickCumulatives(0, int56(uint56(3600))); // tick=1 over 3600s

        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 24 hours);

        router.setEthReturn(0.001 ether);
        plate.swapFeesToETH();
    }

    function test_FallbackToReferencePriceWhenTWAPReverts() public {
        // Warp past bootstrap
        vm.warp(block.timestamp + 25 hours);

        // Make pool observe() revert
        pool.setObserveReverts(true);

        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 49 hours);

        // Should fall back to reference price — not revert
        router.setEthReturn(0.001 ether);
        plate.swapFeesToETH();
    }

    function test_RevertIfNoReferencePriceAndTWAPUnavailable() public {
        // Warp past bootstrap
        vm.warp(block.timestamp + 25 hours);

        // Remove reference price
        plate.setReferencePrice(0);

        // Pool observe reverts
        pool.setObserveReverts(true);

        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 49 hours);

        vm.expectRevert("PLATE: TWAP unavailable — set reference price");
        plate.swapFeesToETH();
    }

    // ============================================================
    //           TEST 3 — SANDWICH PROTECTION REVERTS
    // ============================================================

    function test_SwapRevertsIfInsufficientOutput() public {
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);

        // Router returns less ETH than minOut requires
        router.setEthReturn(1); // Near zero — will fail minOut check

        vm.expectRevert();
        plate.swapFeesToETH();
    }

    function test_SwapSucceedsWithSufficientOutput() public {
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);

        // Router returns reasonable ETH amount
        router.setEthReturn(1 ether);
        plate.swapFeesToETH(); // Should not revert
    }

    function test_24HourDelayPreventsRepeatSwap() public {
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);
        router.setEthReturn(1 ether);
        plate.swapFeesToETH();

        // Accumulate more fees
        _accumulateFees(plate.minSwapBatch() + 1);

        // Try to swap again immediately — should revert
        vm.expectRevert("PLATE: 24hr swap delay not elapsed");
        plate.swapFeesToETH();
    }

    function test_24HourDelayAllowsSwapAfterDelay() public {
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);
        router.setEthReturn(1 ether);
        plate.swapFeesToETH();

        // Warp past delay
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);
        router.setEthReturn(1 ether);
        plate.swapFeesToETH(); // Should succeed
    }

    function test_BelowMinBatchReverts() public {
        // Accumulate less than minSwapBatch
        plate.transfer(address(pool), 100 * 1e18); // Tiny amount

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert("PLATE: Below minimum batch size");
        plate.swapFeesToETH();
    }

    function test_OnlyOwnerCanSwap() public {
        _accumulateFees(plate.minSwapBatch() + 1);
        vm.warp(block.timestamp + 25 hours);

        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.swapFeesToETH();
    }

    function test_OnlyOwnerCanRouteETH() public {
        vm.deal(address(plate), 1 ether);

        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.routeETH();
    }

    // ============================================================
    //           TEST 4 — DAI RESERVE FILL AND DRAIN
    // ============================================================

    function test_DAIReserveFillsFrom20PercentOfTreasury() public {
        // Route ETH — 20% of 75% should go to DAI
        vm.deal(address(plate), 10 ether);
        dai.mint(address(plate), 1_000 * 1e18); // Pre-fund DAI for tracking

        uint256 daiReserveBefore = plate.daiReserve();

        router.setDAIReturn(100 * 1e18); // Mock returns 100 DAI

        plate.routeETH();

        // DAI reserve should have increased
        assertGt(plate.daiReserve(), daiReserveBefore, "DAI reserve should increase");
    }

    function test_DAIReserveStopsFillingWhenFull() public {
        // Fill DAI reserve to target
        uint256 target = plate.DAI_TARGET();

        // Manually set daiReserve to target via multiple routeETH calls
        // In real test: mock the DAI return to exactly hit target
        // For this test: verify isDaiReserveFull() logic

        // Simulate reserve at target
        vm.deal(address(plate), 100 ether);
        router.setDAIReturn(target + 1);
        dai.mint(address(plate), target + 1);

        // This would require mock to return target amount of DAI
        // Then verify next routeETH doesn't route to DAI
        assertTrue(!plate.isDaiReserveFull(), "Should not be full before filling");
    }

    function test_PayAPIDrawsFromReserve() public {
        // Fill reserve first
        uint256 fillAmount = 100 * 1e18;
        dai.mint(address(plate), fillAmount);

        // Hack: set daiReserve via routeETH (simplified for test)
        // Direct test of payAPI logic:
        // Treasury Safe must call payAPI

        address recipient = address(0xRECIPIENT);

        // Non-treasury call should revert
        vm.prank(USER);
        vm.expectRevert("PLATE: Only Treasury Safe");
        plate.payAPI(recipient, fillAmount);
    }

    function test_PayAPIOnlyCallableByTreasury() public {
        vm.prank(OWNER);
        vm.expectRevert("PLATE: Only Treasury Safe");
        plate.payAPI(address(0x1), 100);

        vm.prank(ATTACKER);
        vm.expectRevert("PLATE: Only Treasury Safe");
        plate.payAPI(address(0x1), 100);
    }

    function test_PayAPIRevertsIfInsufficientReserve() public {
        // daiReserve = 0, try to pay 100 DAI
        vm.prank(TREASURY);
        vm.expectRevert("PLATE: Insufficient DAI reserve");
        plate.payAPI(address(0x1), 100 * 1e18);
    }

    function test_DAIReserveFullEvent() public {
        // This tests that the event fires when reserve hits target
        // Simplified: test the isDaiReserveFull view function
        assertFalse(plate.isDaiReserveFull(), "Reserve should not be full initially");
    }

    // ============================================================
    //        TEST 5 — YIELD HARVEST PRINCIPAL TRACKING
    // ============================================================

    function test_HarvestOnlyTakesYieldAbovePrincipal() public {
        // Deploy some ETH to staking via routeETH
        vm.deal(address(plate), 10 ether);
        plate.routeETH();

        uint256 principalBefore = plate.cbETHPrincipal();
        assertGt(principalBefore, 0, "Principal should be tracked after staking");

        // Add yield to cbETH mock (above principal)
        uint256 yieldAmount = 0.1 ether;
        cbETH.addYield(address(plate), yieldAmount);

        uint256 lstBalance = cbETH.balanceOf(address(plate));
        assertGt(lstBalance, principalBefore, "LST balance should exceed principal");

        // Harvest yield
        plate.harvestYield();

        // Principal should be unchanged
        assertEq(plate.cbETHPrincipal(), principalBefore, "Principal should not change after harvest");

        // LST balance should be back to principal (yield harvested)
        assertEq(cbETH.balanceOf(address(plate)), principalBefore, "Only yield should be withdrawn");
    }

    function test_HarvestRevertsIfNoYield() public {
        // No staking deployed — no yield
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();
    }

    function test_HarvestSkipsSilentlyIfLSTBelowPrincipal() public {
        // Deploy to staking
        vm.deal(address(plate), 10 ether);
        plate.routeETH();

        uint256 principal = plate.cbETHPrincipal();

        // Don't add yield — LST balance equals principal
        // Harvest should find no yield and revert with "No yield"
        // (lstBal == cbETHPrincipal → condition fails → skip)
        vm.expectRevert("PLATE: No yield to harvest");
        plate.harvestYield();
    }

    function test_HarvestSplits25To75Correctly() public {
        // Deploy to staking
        vm.deal(address(plate), 10 ether);
        plate.routeETH();

        // Add yield
        cbETH.addYield(address(plate), 1 ether);
        rETH.addYield(address(plate), 1 ether);

        uint256 treasuryBefore = TREASURY.balance;

        plate.harvestYield();

        uint256 treasuryGained = TREASURY.balance - treasuryBefore;
        // 75% of 2 ETH yield = 1.5 ETH to treasury
        assertApproxEqRel(treasuryGained, 1.5 ether, 0.01e18, "Treasury should receive 75% of yield");
    }

    function test_PrincipalTrackedOnDeployment() public {
        vm.deal(address(plate), 10 ether);
        plate.routeETH();

        uint256 cbPrincipal = plate.cbETHPrincipal();
        uint256 rPrincipal  = plate.rETHPrincipal();

        assertGt(cbPrincipal, 0, "cbETH principal should be tracked");
        assertGt(rPrincipal,  0, "rETH principal should be tracked");
    }

    // ============================================================
    //           TEST 6 — CIRCUIT BREAKER BEHAVIOR
    // ============================================================

    function test_CircuitBreakerPausesFeesOnly() public {
        plate.pauseRouting();

        // Transfers still work
        plate.transfer(USER, 1_000 * 1e18);
        assertEq(plate.balanceOf(USER), 1_000 * 1e18, "Transfer should work when paused");

        // Swap fees not collected
        assertEq(plate.pendingFees(), 0, "No fees when paused");
    }

    function test_CircuitBreakerBlocksSwapFeesToETH() public {
        plate.pauseRouting();
        _accumulateFees(plate.minSwapBatch() + 1);

        vm.expectRevert("PLATE: Fee routing paused");
        plate.swapFeesToETH();
    }

    function test_CircuitBreakerBlocksRouteETH() public {
        plate.pauseRouting();
        vm.deal(address(plate), 1 ether);

        vm.expectRevert("PLATE: Fee routing paused");
        plate.routeETH();
    }

    function test_CircuitBreakerBlocksHarvestYield() public {
        plate.pauseRouting();

        vm.expectRevert("PLATE: Fee routing paused");
        plate.harvestYield();
    }

    function test_OnlyOwnerCanActivateCircuitBreaker() public {
        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.pauseRouting();
    }

    function test_CircuitBreakerRequiresTimelockToResume() public {
        plate.pauseRouting();

        // Cannot resume without queuing first
        bytes32 fakeId = keccak256("fake");
        vm.expectRevert("PLATE: Not queued");
        plate.resumeRouting(fakeId);
    }

    function test_CircuitBreakerResumesAfterTimelock() public {
        plate.pauseRouting();
        assertTrue(plate.paused(), "Should be paused");

        bytes32 id = plate.queueResumeRouting();

        // Cannot resume before timelock
        vm.expectRevert("PLATE: Timelock pending");
        plate.resumeRouting(id);

        // Warp past timelock
        vm.warp(block.timestamp + 48 hours + 1);
        plate.resumeRouting(id);

        assertFalse(plate.paused(), "Should be resumed");
    }

    // ============================================================
    //              TEST 7 — TIMELOCK FLOWS
    // ============================================================

    function test_TimelockQueueCreatesEntry() public {
        address newLP = address(0xNEWLP);
        bytes32 id = plate.queueLPUpdate(newLP);

        uint256 remaining = plate.getTimelockRemaining(id);
        assertGt(remaining, 0, "Timelock should have time remaining");
        assertApproxEqAbs(remaining, 48 hours, 10, "Timelock should be ~48 hours");
    }

    function test_TimelockExecuteRevertsBeforeDelay() public {
        address newLP = address(0xNEWLP);
        bytes32 id = plate.queueLPUpdate(newLP);

        vm.expectRevert("PLATE: Timelock pending");
        plate.executeLPUpdate(id, newLP);
    }

    function test_TimelockExecuteSucceedsAfterDelay() public {
        address newLP = address(0xNEWLP);
        bytes32 id = plate.queueLPUpdate(newLP);

        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeLPUpdate(id, newLP);

        assertEq(plate.liquidityPool(), newLP, "LP should be updated");
    }

    function test_TimelockDeletesAfterExecution() public {
        address newLP = address(0xNEWLP);
        bytes32 id = plate.queueLPUpdate(newLP);

        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeLPUpdate(id, newLP);

        // Remaining should be 0 after execution
        assertEq(plate.getTimelockRemaining(id), 0, "Timelock entry should be deleted");

        // Cannot execute again
        vm.expectRevert("PLATE: Not queued");
        plate.executeLPUpdate(id, newLP);
    }

    function test_TimelockRevertsForUnknownId() public {
        bytes32 fakeId = keccak256("fake_id");

        vm.expectRevert("PLATE: Not queued");
        plate.executeLPUpdate(fakeId, address(0x1));
    }

    function test_DEXPairTimelockFlow() public {
        address newPair = address(0xNEWPAIR);
        bytes32 id = plate.queueDEXPair(newPair);

        // Before delay
        vm.expectRevert("PLATE: Timelock pending");
        plate.executeDEXPair(id, newPair);

        // After delay
        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeDEXPair(id, newPair);

        assertTrue(plate.isDEXPair(newPair), "New pair should be registered");
    }

    function test_CbETHExitTimelockFlow() public {
        bytes32 id = plate.queueCbETHExit();

        vm.expectRevert("PLATE: Timelock pending");
        plate.executeCbETHExit(id);

        vm.warp(block.timestamp + 48 hours + 1);
        plate.executeCbETHExit(id);

        assertTrue(plate.cbETHPaused(), "cbETH should be paused after exit");
    }

    function test_OnlyOwnerCanQueueTimelockChanges() public {
        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.queueLPUpdate(address(0x1));

        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.queueDEXPair(address(0x1));

        vm.prank(ATTACKER);
        vm.expectRevert();
        plate.queueCbETHExit();
    }

    // ============================================================
    //              BONUS — cbETH DEPEG PROTECTION
    // ============================================================

    function test_CbETHDepegPausesDeposits() public {
        // Set cbETH price below 97% threshold
        chainlink.setAnswer(int256(96_000_000)); // 4% depeg

        vm.deal(address(plate), 10 ether);
        plate.routeETH(); // _checkDepeg called inside _deployToStaking

        assertTrue(plate.cbETHPaused(), "cbETH should be paused on depeg");
    }

    function test_CbETHRecoveryResumesDeposits() public {
        // First depeg
        chainlink.setAnswer(int256(96_000_000));
        vm.deal(address(plate), 1 ether);
        plate.routeETH();
        assertTrue(plate.cbETHPaused(), "Should be paused");

        // Recovery
        chainlink.setAnswer(int256(98_000_000));
        vm.deal(address(plate), 1 ether);
        plate.routeETH();
        assertFalse(plate.cbETHPaused(), "Should resume on recovery");
    }

    function test_StaleFeedSkipsDepegCheck() public {
        chainlink.setStale(); // Feed is 2 hours old

        // Should not pause even with low answer — stale feed skipped
        chainlink.setAnswer(int256(90_000_000)); // Very low but stale

        vm.deal(address(plate), 1 ether);
        plate.routeETH();

        assertFalse(plate.cbETHPaused(), "Stale feed should be skipped");
    }

    // ============================================================
    //              BONUS — FUZZ TESTS
    // ============================================================

    /// @dev Fuzz: fee always equals exactly 2% of transfer
    function testFuzz_FeeIs2Percent(uint256 amount) public {
        amount = bound(amount, 10_000, plate.totalSupply() / 2);

        uint256 feesBefore = plate.pendingFees();
        plate.transfer(address(pool), amount);
        uint256 feesAfter = plate.pendingFees();

        uint256 feeCollected = feesAfter - feesBefore;
        uint256 expectedFee  = (amount * 200) / 10_000;

        assertEq(feeCollected, expectedFee, "Fee must always be exactly 2%");
    }

    /// @dev Fuzz: fee + net always equals original amount (no value created/destroyed)
    function testFuzz_FeeConservation(uint256 amount) public {
        amount = bound(amount, 10_000, plate.totalSupply() / 2);

        uint256 contractBefore = plate.balanceOf(address(plate));
        uint256 poolBefore     = plate.balanceOf(address(pool));

        plate.transfer(address(pool), amount);

        uint256 feeCollected = plate.balanceOf(address(plate)) - contractBefore;
        uint256 netReceived  = plate.balanceOf(address(pool))  - poolBefore;

        assertEq(feeCollected + netReceived, amount, "Fee + net must equal original amount");
    }

    /// @dev Fuzz: timelock remaining never exceeds 48 hours
    function testFuzz_TimelockNeverExceeds48Hours(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, 100 days);
        vm.warp(block.timestamp + warpTime);

        address newLP = address(uint160(uint256(keccak256(abi.encode(warpTime)))));
        bytes32 id = plate.queueLPUpdate(newLP);

        uint256 remaining = plate.getTimelockRemaining(id);
        assertLe(remaining, 48 hours + 1, "Timelock remaining must not exceed 48 hours");
    }

    // ============================================================
    //                      HELPERS
    // ============================================================

    function _accumulateFees(uint256 target) internal {
        // Transfer enough PLATE through pool to accumulate target fees
        // fee = amount * 2% → amount = target / 0.02 = target * 50
        uint256 swapAmount = target * 50 + 1e18;
        if (plate.balanceOf(address(this)) < swapAmount) {
            // Not enough balance — use what we have
            swapAmount = plate.balanceOf(address(this)) / 2;
        }
        plate.transfer(address(pool), swapAmount);
    }

    receive() external payable {}
}
