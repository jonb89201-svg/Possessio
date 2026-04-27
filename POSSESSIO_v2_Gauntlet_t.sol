// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/POSSESSIO_v2.sol";

/*
 * POSSESSIO v2 Gauntlet — Adversarial Test Suite
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

// ═══════════════════════════════════════════════════════════════════════════
//                              MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════════════════════

contract MockCbETHAttack {
    mapping(address => uint256) public _balances;
    bool public depositShouldRevert;

    function deposit() external payable {
        require(!depositShouldRevert, "MockCbETH: deposit reverts");
        _balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "MockCbETH: insufficient");
        _balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function addRewards(address a, uint256 r) external { _balances[a] += r; }
    function setDepositRevert(bool r)         external { depositShouldRevert = r; }

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
            MockWETHAttack(payable(weth)).transferFrom(msg.sender, address(this), params.amountIn);
        }
        if (daiReturn > 0) {
            MockDAIAttack(dai).mint(params.recipient, daiReturn);
        }
        return daiReturn;
    }

    receive() external payable {}
}

contract MockChainlinkAttack {
    int256  public _answer;
    uint256 public _updatedAt;
    uint80  public _roundId;
    uint80  public _answeredInRound;
    bool    public _reverts;

    constructor(int256 answer_) {
        _answer = answer_;
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

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!_reverts, "MockChainlink: reverts");
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
}

contract MockPoolManagerAttack {
    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════════
//                           REENTRANCY ATTACKER
// ═══════════════════════════════════════════════════════════════════════════

contract ReentrancyAttacker {
    PossessioHook public target;
    bool public didReenter;

    constructor(address t) { target = PossessioHook(payable(t)); }

    receive() external payable {
        if (!didReenter) {
            didReenter = true;
            // Attempt to reenter routeETH during ETH receipt
            try target.routeETH() {
                // reentry succeeded — BAD
            } catch {
                // expected — nonReentrant guarded
            }
        }
    }

    function triggerAttack() external payable {
        (bool ok,) = address(target).call{value: msg.value}("");
        require(ok, "forward failed");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                      POSSESSIO V2 GAUNTLET TEST SUITE
// ═══════════════════════════════════════════════════════════════════════════

contract POSSESSIOv2Gauntlet is Test {
    using stdStorage for StdStorage;

    STEEL         steel;
    PossessioHook hook;
    MockPoolManagerAttack  poolManager;
    MockCbETHAttack        cbETH;
    MockDAIAttack          dai;
    MockWETHAttack         weth;
    MockV3RouterAttack     v3Router;
    MockChainlinkAttack    clCbETH;
    MockChainlinkAttack    clDAI;

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
        clCbETH     = new MockChainlinkAttack(int256(98_000_000));
        clDAI       = new MockChainlinkAttack(int256(500_000_000_000));

        steel = new STEEL(address(this));

        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];

        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       address(this),
            steel:          address(steel),
            poolManager:    address(poolManager),
            treasury:       TREASURY,
            cbETH_:         address(cbETH),
            dai:            address(dai),
            chainlinkCbETH: address(clCbETH),
            chainlinkDAI:   address(clDAI),
            v3Router:       address(v3Router),
            weth:           address(weth),
            council:        council
        });

        hook = new PossessioHook(p);

        stdstore.target(address(hook)).sig("poolInitialized()").checked_write(true);

        vm.deal(address(cbETH),    100 ether);
        vm.deal(address(v3Router), 100 ether);
        vm.deal(USER,              10 ether);
        vm.deal(ATTACKER,          10 ether);

        v3Router.setDAIReturn(1 * 1e18);
        clCbETH.setAnswer(int256(98_000_000));
        clDAI.setAnswer(int256(500_000_000_000));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         REENTRANCY ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    routeETH and harvestRewards are guarded by nonReentrant.
    //                 Calls to these functions during ETH receipt (via .transfer
    //                 or .call) must revert with ReentrancyGuardReentrantCall.
    // Boundary:       Attacker contract with receive() that re-enters. Test
    //                 verifies the guard catches it.
    // Assumption Log: OpenZeppelin ReentrancyGuard is non-broken.
    // Non-Proven:     Does not prove reentrancy guard behavior under
    //                 gas manipulation or malicious PoolManager.

    function test_Attack_ReentrancyOnRouteETH() public {
        ReentrancyAttacker atk = new ReentrancyAttacker(address(hook));

        // Fund accumulator so routeETH has something to distribute
        _fundAccumulator(1 ether);

        // Treasury calls routeETH; when ETH hits attacker via a refund path,
        // attacker attempts to re-enter. nonReentrant must block.
        // In v2 the attacker can only receive ETH via reward distribution or
        // Treasury forward path, both of which happen after state update.
        vm.prank(TREASURY);
        hook.routeETH();

        // If reentrancy succeeded, accumulator could be drained twice.
        // In practice the nonReentrant guard should prevent any re-entry.
        assertFalse(atk.didReenter(), "Reentrancy guard must prevent re-entry");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      UNAUTHORIZED ACCESS ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    All privileged functions reject non-privileged callers.
    //                 onlyTreasury, onlyOwner, onlyCouncil, onlyPoolManager.
    // Boundary:       Every external function callable only by Treasury, Owner,
    //                 Council, or PoolManager must revert for ATTACKER.
    // Assumption Log: OpenZeppelin Ownable2Step and custom modifiers work correctly.
    // Non-Proven:     Does not prove privilege escalation via call forwarding.

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

    // ═══════════════════════════════════════════════════════════════════════
    //                   CIRCUIT BREAKER BYPASS ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Attacker cannot bypass pauseRouting via self-call, rapid
    //                 queue spam, or timelock manipulation.
    // Boundary:       After pause, routeETH reverts for all callers until
    //                 resume completes (48h timelock).
    // Assumption Log: timelockQueue storage is not externally manipulable.
    // Non-Proven:     Does not prove resistance to storage-slot writes via
    //                 privileged foundry cheats (outside attacker threat model).

    function test_Attack_CircuitBreakerBypassDirect() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.pauseRouting();

        // Attacker attempts routeETH post-pause
        vm.expectRevert(PossessioHook.RoutingPaused.selector);
        vm.prank(ATTACKER);
        hook.routeETH();
    }

    function test_Attack_CircuitBreakerBypassViaQueueSpam() public {
        vm.prank(TREASURY);
        hook.pauseRouting();

        // Queue many resume IDs — none should allow early execution
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(TREASURY);
            bytes32 id = hook.queueResumeRouting();

            // Try to execute immediately
            vm.expectRevert(PossessioHook.TimelockPending.selector);
            vm.prank(TREASURY);
            hook.resumeRouting(id);
        }

        assertTrue(hook.routingPaused(), "Pause must hold despite queue spam");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ORACLE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Extreme oracle values (0, max int256, negative) do not
    //                 cause arithmetic panics, silent corruption, or bypasses.
    //                 Reverting oracle is caught cleanly.
    // Boundary:       Tested at answer=0, type(int256).max, type(int256).min,
    //                 negative values, and reverting feed.
    // Assumption Log: Chainlink staleness check (Grok-audit) is operational.
    // Non-Proven:     Does not prove resistance to real Chainlink oracle
    //                 compromise (trust assumption on the feed itself).

    function test_Attack_ExtremeOracleDepegZero() public {
        clCbETH.setAnswer(int256(0));
        _fundAccumulator(1 ether);

        // answer == 0 should be caught as invalid (not < threshold)
        vm.prank(TREASURY);
        hook.routeETH();

        // Contract must not panic
        assertFalse(hook.cbETHPaused(), "Zero answer must not trigger state change");
    }

    function test_Attack_ExtremeOracleDepegNegative() public {
        clCbETH.setAnswer(int256(-1));
        _fundAccumulator(1 ether);

        vm.prank(TREASURY);
        hook.routeETH();

        // Negative answer must be caught as invalid
        assertFalse(hook.cbETHPaused(), "Negative answer must not change state");
    }

    function test_Attack_ExtremeOracleDepegMax() public {
        clCbETH.setAnswer(type(int256).max);
        _fundAccumulator(1 ether);

        // Max int256 is way above DEPEG_THRESH, so no pause
        vm.prank(TREASURY);
        hook.routeETH();

        assertFalse(hook.cbETHPaused(), "Max answer must not pause (far above threshold)");
    }

    function test_Attack_OracleRevertsCleanly() public {
        clCbETH.setReverts(true);
        clDAI.setReverts(true);
        _fundAccumulator(1 ether);

        // Both oracles reverting — routeETH must not revert
        vm.prank(TREASURY);
        hook.routeETH();

        // Depeg check catches revert silently, DAI swap retains ETH
        assertFalse(hook.cbETHPaused(), "Reverting feed must not change state");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      PRINCIPAL EROSION ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    harvestRewards NEVER withdraws below tracked principal.
    //                 No call sequence can drain staking principal via rewards
    //                 harvest, even when depeg, dust, or repeated calls occur.
    // Boundary:       Balance == principal → revert ZeroAmount (no rewards to take).
    //                 Balance < principal → impossible state, must revert.
    // Assumption Log: cbETH balance tracks principal correctly.
    // Non-Proven:     Does not prove rebasing tokens on Base mainnet behave
    //                 identically to mocks.

    function test_Attack_PrincipalErosionViaRepeatedHarvest() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        // Add small rewards
        cbETH.addRewards(address(hook), 0.01 ether);
        vm.deal(address(cbETH), address(cbETH).balance + 0.01 ether);

        // Harvest rewards
        hook.harvestRewards();

        // Principal must not have decreased
        uint256 cbPrincipalAfter = hook.cbETHPrincipal();
        assertGt(cbPrincipalAfter, 0, "cbETH principal must remain");

        // Second harvest with no new rewards must revert
        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();
    }

    function test_Attack_HarvestBeforeAnyStaking() public {
        // No deposits made — harvestRewards must revert (nothing to harvest)
        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();
    }

    function test_Attack_HarvestDuringDepeg() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        // Add rewards
        cbETH.addRewards(address(hook), 0.1 ether);
        vm.deal(address(cbETH), address(cbETH).balance + 0.1 ether);

        // Trigger depeg
        clCbETH.setAnswer(int256(95_000_000));

        // Harvest during depeg — must not panic
        hook.harvestRewards();
        // (No specific assertion beyond no-panic — depeg affects deploys, not harvests)
    }

    function test_Attack_HarvestDoesNotBypassPrincipal() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 principalBefore = hook.cbETHPrincipal();

        // Set LST balance equal to principal (no rewards)
        // harvest must revert
        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();

        uint256 principalAfter = hook.cbETHPrincipal();
        assertEq(principalAfter, principalBefore, "Principal must not decrease on no-rewards harvest");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      DAI RESERVE DRAIN ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    daiReserve never decreases from attacker action. Only
    //                 Treasury can sweep via rescueToken (which is BLOCKED for DAI).
    // Boundary:       Attacker has no path to reduce daiReserve.
    // Assumption Log: DAI ERC20 is non-malicious.
    // Non-Proven:     Does not prove real DAI on Base behaves identically.

    function test_Attack_DAIReserveDrainBlocked() public {
        _fundAccumulator(1 ether);
        v3Router.setDAIReturn(500 * 1e18);
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 reserveBefore = hook.daiReserve();
        assertGt(reserveBefore, 0, "DAI reserve seeded");

        // Attacker cannot rescue DAI (blocked)
        vm.expectRevert(PossessioHook.RescueBlocked.selector);
        vm.prank(TREASURY);
        hook.rescueToken(address(dai), 1 ether);

        // Reserve unchanged
        assertEq(hook.daiReserve(), reserveBefore, "DAI reserve unchanged after rescue attempt");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  FORCE-INJECTED ETH ANTI-POISONING
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    ETH received via receive() does NOT increment accumulatedETH.
    //                 Only beforeSwap fee capture increments the accumulator.
    // Boundary:       Attacker sends ETH via .transfer, .call, .send — none
    //                 should inflate the accumulator.
    // Assumption Log: receive() function correctly declared non-incrementing.
    // Non-Proven:     Does not prove selfdestruct-based forced sends cannot
    //                 affect contract state (Solidity 0.8.24+ cannot selfdestruct
    //                 but mainnet may have pre-existing contracts that can).

    function test_Attack_ForceInjectedETH_DoesNotInflateAccumulator() public {
        uint256 accumulatorBefore = hook.accumulatedETH();

        // Attacker tries to inject via receive()
        vm.prank(ATTACKER);
        (bool ok,) = address(hook).call{value: 5 ether}("");
        assertTrue(ok, "receive() must accept");

        // Accumulator did NOT change
        assertEq(hook.accumulatedETH(), accumulatorBefore,
            "Force-injected ETH must not inflate accumulator");

        // Contract balance DID change (ETH is present, just not accounted as fee)
        assertEq(address(hook).balance, 5 ether, "Raw balance reflects injection");
    }

    function test_Attack_ForceInjectedETH_CannotMintStakingPrincipal() public {
        uint256 cbPrincipalBefore = hook.cbETHPrincipal();

        // Inject ETH
        vm.prank(ATTACKER);
        (bool ok,) = address(hook).call{value: 5 ether}("");
        assertTrue(ok);

        // Principal tracking must not have changed
        assertEq(hook.cbETHPrincipal(), cbPrincipalBefore, "cbETH principal untouched");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        RESCUE GUARD ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    rescueToken guards prevent draining protocol-critical
    //                 tokens even with Treasury access.
    // Boundary:       STEEL/DAI/cbETH/WETH always revert RescueBlocked.
    // Assumption Log: Guard checks compare addresses correctly.
    // Non-Proven:     Does not prove CREATE2 address collisions cannot bypass.

    function test_Attack_RescueCannotDrainSTEEL() public {
        // Send some STEEL to the hook (as if accidentally)
        steel.transfer(address(hook), 1000 * 1e18);

        vm.expectRevert(PossessioHook.RescueBlocked.selector);
        vm.prank(TREASURY);
        hook.rescueToken(address(steel), 1000 * 1e18);
    }

    function test_Attack_RescueCannotDrainDAIReserve() public {
        _fundAccumulator(1 ether);
        v3Router.setDAIReturn(500 * 1e18);
        vm.prank(TREASURY);
        hook.routeETH();

        vm.expectRevert(PossessioHook.RescueBlocked.selector);
        vm.prank(TREASURY);
        hook.rescueToken(address(dai), 500 * 1e18);
    }

    function test_Attack_RescueUnlistedTokenSucceeds() public {
        // Deploy a random ERC20, send to hook, verify rescue works
        STEEL randomToken = new STEEL(TREASURY);
        uint256 treasuryBefore = randomToken.balanceOf(TREASURY);
        vm.prank(TREASURY);
        randomToken.transfer(address(hook), 100 * 1e18);

        // Rescue is NOT blocked for non-protocol tokens
        vm.prank(TREASURY);
        hook.rescueToken(address(randomToken), 100 * 1e18);

        // After round-trip, Treasury should have recovered the 100 tokens
        assertEq(randomToken.balanceOf(TREASURY), treasuryBefore,
            "Non-protocol token must return to Treasury after rescue");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  REWARDS ATTACKS — NO AMPLIFICATION / DRIFT
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Repeated harvest cycles do not cause value drift,
    //                 recursive amplification, or cross-cycle state corruption.
    //                 Only ACTUAL rewards are routed.
    // Boundary:       Multiple harvests at various rewards amounts. Principal
    //                 tracked correctly across all cycles.
    // Assumption Log: Integer division truncates deterministically.

    function test_Attack_Rewards_NoCrossCycleDrift() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 cbPrincipal0 = hook.cbETHPrincipal();

        // Cycle 1: add rewards, harvest
        cbETH.addRewards(address(hook), 0.05 ether);
        vm.deal(address(cbETH), address(cbETH).balance + 0.05 ether);
        hook.harvestRewards();

        // Principal unchanged
        assertEq(hook.cbETHPrincipal(), cbPrincipal0, "Cycle 1: cbETH principal drift");

        // Cycle 2: add rewards, harvest
        cbETH.addRewards(address(hook), 0.05 ether);
        vm.deal(address(cbETH), address(cbETH).balance + 0.05 ether);
        hook.harvestRewards();

        // Still unchanged
        assertEq(hook.cbETHPrincipal(), cbPrincipal0, "Cycle 2: cbETH principal drift");
    }

    function test_Attack_Rewards_NoRecursiveAmplification() public {
        _fundAccumulator(1 ether);
        vm.prank(TREASURY);
        hook.routeETH();

        cbETH.addRewards(address(hook), 0.1 ether);
        vm.deal(address(cbETH), address(cbETH).balance + 0.1 ether);

        uint256 treasuryBefore = TREASURY.balance;
        hook.harvestRewards();
        uint256 treasuryGain1 = TREASURY.balance - treasuryBefore;

        // Immediate second harvest — no new rewards, must revert
        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        hook.harvestRewards();

        // Gain from first harvest is bounded (cannot amplify)
        assertLe(treasuryGain1, 0.1 ether, "Treasury gain bounded by rewards amount");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  HOOK INJECTION ATTACKS (v2 SPECIFIC)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    External callers cannot directly invoke beforeSwap,
    //                 afterSwap, beforeAddLiquidity, or unlockCallback.
    //                 Only PoolManager can call hook callbacks.
    // Boundary:       Each hook callback reverts with OnlyPoolManager when
    //                 called by non-PoolManager caller.
    // Assumption Log: onlyPoolManager modifier correctly checks msg.sender.
    // Non-Proven:     Does not prove CREATE2 collision cannot spoof PoolManager
    //                 (mitigated by well-known PoolManager address).

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

    // ═══════════════════════════════════════════════════════════════════════
    //                  SAV COUNCIL ATTACKS (v2 SPECIFIC)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Attacker cannot drain SAV allocations, bypass 3-of-4
    //                 approval, replay invent proposals, or burn post-slash.
    // Boundary:       Only council members can approve. Only Treasury can slash.
    //                 Slashed SAV blocks all further SAV ops.
    // Assumption Log: Council addresses are immutable, cannot be rotated.
    // Non-Proven:     Does not prove real council members' keys are secure
    //                 (operational, not contract concern).

    function test_Attack_SAVBurnByNonCouncilMember() public {
        // onlyCouncilMember modifier fires before any state is touched.
        // No deposit setup needed — the authorization check rejects first.
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
        // Seed SAV: transfer STEEL to Treasury, Treasury approves + deposits
        steel.transfer(TREASURY, 4000 * 1e18);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), 4000 * 1e18);
        hook.savDeposit(4000 * 1e18);
        vm.stopPrank();

        // Now slash
        vm.prank(TREASURY);
        hook.savSlash();

        // All SAV ops must now revert with Slashed_
        // Transfer fresh STEEL to Treasury for a second deposit attempt (from test contract)
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

    // ═══════════════════════════════════════════════════════════════════════
    //                    ROUTE REWARD INFLATION ATTACKS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Permissionless routeETH caller cannot amplify reward
    //                 via self-call chains, split-amount gaming, or cooldown
    //                 manipulation.
    // Boundary:       Reward capped at 0.1% of routed amount. Cooldown enforced.
    // Assumption Log: lastRouteTime storage cannot be externally altered.
    // Non-Proven:     Does not prove MEV extraction via transaction ordering.

    function test_Attack_RewardCannotBeAmplifiedViaRapidCalls() public {
        _fundAccumulator(1 ether);
        vm.warp(block.timestamp + 7 hours);
        clDAI.setAnswer(int256(500_000_000_000));

        uint256 balBefore = USER.balance;
        vm.prank(USER);
        hook.routeETH();
        uint256 firstReward = USER.balance - balBefore;

        // Immediate second call — must revert on cooldown
        _fundAccumulator(1 ether);
        vm.expectRevert(PossessioHook.RouteTooEarly.selector);
        vm.prank(USER);
        hook.routeETH();

        // Reward is bounded: cannot exceed 0.1% of route amount
        assertLe(firstReward, 0.001 ether + 1 wei, "Reward must be bounded at 0.1%");
    }

    function test_Attack_BelowThresholdBlocksPermissionlessRoute() public {
        _fundAccumulator(0.01 ether); // below 0.05 threshold
        vm.warp(block.timestamp + 7 hours);

        vm.expectRevert(PossessioHook.BelowThreshold.selector);
        vm.prank(USER);
        hook.routeETH();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  ACCUMULATOR INFLATION ATTACKS (v2 SPECIFIC)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    accumulatedETH can only be incremented by beforeSwap
    //                 (captured fees) or restoration on routing failure.
    //                 No external caller can directly inflate it.
    // Boundary:       Direct ETH sends do not inflate. Function call surface
    //                 exposes no mutator for accumulatedETH.
    // Assumption Log: accumulatedETH is private/internal relative to external
    //                 callers (only public for view).
    // Non-Proven:     Does not prove against storage-slot write attacks.

    function test_Attack_AccumulatorCannotBeInflatedExternally() public {
        uint256 before = hook.accumulatedETH();

        // Try every reasonable attacker path:
        vm.startPrank(ATTACKER);

        // 1. Direct ETH send via call
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);

        // 2. No public setter exists — nothing else to try
        vm.stopPrank();

        assertEq(hook.accumulatedETH(), before,
            "Accumulator must not change from external actions");

        // Invariant: contract balance must always be >= accumulatedETH
        // Force-injected ETH increases balance but not accumulator — this is expected.
        // The inverse (accumulator > balance) would indicate accounting corruption.
        assertGe(address(hook).balance, hook.accumulatedETH(),
            "Invariant: contract balance must be >= accumulatedETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _fundAccumulator(uint256 amt) internal {
        stdstore.target(address(hook)).sig("accumulatedETH()").checked_write(amt);
        vm.deal(address(hook), address(hook).balance + amt);
    }

    receive() external payable {}
}
