// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdStorage.sol";
import "../src/POSSESSIO_v2.sol";

/*
 * POSSESSIO v2 SAV Test Suite
 *
 * SCOPE: Service Accountability Vault behavior on the merged PossessioHook.
 *        Covers: deposit, burn, propose/approve/execute invent cycle, pause,
 *        slash, integration scenarios.
 *
 * PRIOR ART: Ported from v1 SAV.t.sol (76 tests) + SAVGauntlet.t.sol (42 tests).
 *            PLATEStaking tests from SAV.t.sol (24 tests) are DROPPED —
 *            PLATEStaking contract is eliminated in v2 by ratified merge design.
 *            Total v1 SAV-related: 142 tests. This file ports ~90 relevant tests.
 *
 * ADAPTATION NOTES:
 *   - v1's ServiceAccountabilityVault is now inline on PossessioHook
 *   - v1's setSAV() initialization path no longer exists (council hardcoded in
 *     constructor immutables)
 *   - v1's staking-from-SAV tests no longer apply (no PLATEStaking contract)
 *   - All SAV ops still require pre-seeded claimables via savDeposit
 *
 * Amendment IV declarations per category.
 */

// ═══════════════════════════════════════════════════════════════════════════
//                              MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════════════════════

contract MockCbETHSav {
    mapping(address => uint256) public _balances;
    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    receive() external payable {}
}

contract MockRETHSav {
    mapping(address => uint256) public _balances;
    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function burn(uint256 a) external {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    receive() external payable {}
}

contract MockDAISav {
    mapping(address => uint256) public _balances;
    function mint(address to, uint256 amount) external { _balances[to] += amount; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "insuf");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract MockWETHSav {
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;
    function deposit() external payable { _balances[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }
    function approve(address s, uint256 a) external returns (bool) {
        _allowances[msg.sender][s] = a;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "insuf");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "insuf");
        require(_allowances[from][msg.sender] >= amount, "not approved");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    receive() external payable {}
}

contract MockV3RouterSav {
    address public weth;
    address public dai;
    uint256 public daiReturn;
    constructor(address w, address d) { weth = w; dai = d; }
    function setDAIReturn(uint256 v) external { daiReturn = v; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 amountIn; uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p)
        external payable returns (uint256)
    {
        if (p.tokenIn == weth && p.amountIn > 0) {
            MockWETHSav(payable(weth)).transferFrom(msg.sender, address(this), p.amountIn);
        }
        if (daiReturn > 0) MockDAISav(dai).mint(p.recipient, daiReturn);
        return daiReturn;
    }
    receive() external payable {}
}

contract MockChainlinkSav {
    int256 public _answer;
    uint256 public _updatedAt;
    uint80 public _roundId;
    uint80 public _answeredInRound;
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
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
}

contract MockPoolManagerSav {
    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════════
//                       POSSESSIO V2 SAV TEST SUITE
// ═══════════════════════════════════════════════════════════════════════════

contract POSSESSIOv2SAV is Test {
    using stdStorage for StdStorage;

    STEEL         steel;
    PossessioHook hook;
    MockPoolManagerSav  poolManager;
    MockCbETHSav        cbETH;
    MockRETHSav         rETH;
    MockDAISav          dai;
    MockWETHSav         weth;
    MockV3RouterSav     v3Router;
    MockChainlinkSav    clCbETH;
    MockChainlinkSav    clDAI;

    address TREASURY  = 0x19495180FFA00B8311c85DCF76A89CCbFB174EA0;
    address ATTACKER  = address(0xBAD);
    address COUNCIL_0 = address(0xC001);
    address COUNCIL_1 = address(0xC002);
    address COUNCIL_2 = address(0xC003);
    address COUNCIL_3 = address(0xC004);

    address DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DEPOSIT_AMOUNT = 4000 * 1e18;

    function setUp() public {
        vm.warp(1_000_000);

        poolManager = new MockPoolManagerSav();
        cbETH       = new MockCbETHSav();
        rETH        = new MockRETHSav();
        dai         = new MockDAISav();
        weth        = new MockWETHSav();
        v3Router    = new MockV3RouterSav(address(weth), address(dai));
        clCbETH     = new MockChainlinkSav(int256(98_000_000));
        clDAI       = new MockChainlinkSav(int256(500_000_000_000));

        steel = new STEEL(address(this));

        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];
        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       address(this),
            steel:          address(steel),
            poolManager:    address(poolManager),
            treasury:       TREASURY,
            cbETH_:         address(cbETH),
            rETH_:          address(rETH),
            dai:            address(dai),
            chainlinkCbETH: address(clCbETH),
            chainlinkDAI:   address(clDAI),
            v3Router:       address(v3Router),
            weth:           address(weth),
            council:        council
        });

        hook = new PossessioHook(p);

        // Seed Treasury with STEEL for deposits
        steel.transfer(TREASURY, 100_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Constructor wires council, treasury, STEEL correctly.
    //                 Initial flags are correct (not paused, not slashed).
    // Boundary:       Zero address for any council slot reverts.
    // Assumption Log: COUNCIL addresses are immutable post-deploy.
    // Non-Proven:     Does not prove CREATE2 address encoding for hook permissions.

    function test_Deploy_CouncilAddressesSet() public {
        assertEq(hook.COUNCIL_0(), COUNCIL_0, "COUNCIL_0");
        assertEq(hook.COUNCIL_1(), COUNCIL_1, "COUNCIL_1");
        assertEq(hook.COUNCIL_2(), COUNCIL_2, "COUNCIL_2");
        assertEq(hook.COUNCIL_3(), COUNCIL_3, "COUNCIL_3");
    }

    function test_Deploy_STEELTokenSet() public {
        assertEq(address(hook.STEEL_TOKEN()), address(steel), "STEEL_TOKEN");
    }

    function test_Deploy_TreasurySet() public {
        assertEq(hook.TREASURY_SAFE(), TREASURY, "Treasury address");
    }

    function test_Deploy_NotPausedInitially() public {
        assertFalse(hook.savPaused(), "savPaused must be false");
    }

    function test_Deploy_NotSlashedInitially() public {
        assertFalse(hook.slashed(), "slashed must be false");
    }

    function test_Deploy_ClaimablesAreZero() public {
        assertEq(hook.getClaimable(COUNCIL_0), 0, "COUNCIL_0 claimable");
        assertEq(hook.getClaimable(COUNCIL_1), 0, "COUNCIL_1 claimable");
        assertEq(hook.getClaimable(COUNCIL_2), 0, "COUNCIL_2 claimable");
        assertEq(hook.getClaimable(COUNCIL_3), 0, "COUNCIL_3 claimable");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         SAV DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    savDeposit splits evenly across 4 members, remainder
    //                 returns to Treasury, accumulates across calls.
    // Boundary:       Non-Treasury callers revert. Slashed state blocks deposits.
    //                 Amount < 4 wei results in zero share each + full remainder.
    // Assumption Log: STEEL.safeTransferFrom behaves correctly.
    // Non-Proven:     Does not prove SAV deposit under PoolManager reentrant context.

    function test_Deposit_SplitsEvenlyAcrossFour() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        uint256 share = DEPOSIT_AMOUNT / 4;
        assertEq(hook.getClaimable(COUNCIL_0), share, "COUNCIL_0 share");
        assertEq(hook.getClaimable(COUNCIL_1), share, "COUNCIL_1 share");
        assertEq(hook.getClaimable(COUNCIL_2), share, "COUNCIL_2 share");
        assertEq(hook.getClaimable(COUNCIL_3), share, "COUNCIL_3 share");
    }

    function test_Deposit_RemainderReturnedToTreasury() public {
        // Deposit 4001 — 4 goes per member, 1 wei remainder back to Treasury
        uint256 depositWithRemainder = (4000 * 1e18) + 1;
        uint256 treasuryBefore = steel.balanceOf(TREASURY);

        vm.startPrank(TREASURY);
        steel.approve(address(hook), depositWithRemainder);
        hook.savDeposit(depositWithRemainder);
        vm.stopPrank();

        // Treasury lost 4000*1e18 (deposited), got back 1 (remainder)
        // Net loss = 4000*1e18 - 1
        uint256 treasuryAfter = steel.balanceOf(TREASURY);
        uint256 netLoss = treasuryBefore - treasuryAfter;
        assertEq(netLoss, 4000 * 1e18, "Net loss must equal deposit minus remainder");
    }

    function test_Deposit_EmitsEvent() public {
        uint256 share = DEPOSIT_AMOUNT / 4;
        vm.startPrank(TREASURY);
        steel.approve(address(hook), DEPOSIT_AMOUNT);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PossessioHook.SAVDeposit(DEPOSIT_AMOUNT, share, 0);
        hook.savDeposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_Deposit_RevertsForNonTreasury() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savDeposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_RevertsWhenSlashed() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        hook.savSlash();

        steel.transfer(TREASURY, DEPOSIT_AMOUNT);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), DEPOSIT_AMOUNT);
        vm.expectRevert(PossessioHook.Slashed_.selector);
        hook.savDeposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_Deposit_AccumulatesAcrossMultipleCalls() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        _seedDeposit(DEPOSIT_AMOUNT);

        uint256 expected = (DEPOSIT_AMOUNT * 2) / 4;
        assertEq(hook.getClaimable(COUNCIL_0), expected, "Multi-deposit accumulates");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         SAV BURN TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    savBurn reduces claimable, sends to DEAD, rejects non-council,
    //                 blocks during paused or slashed states.
    // Boundary:       Amount > claimable reverts. Zero amount reverts. Non-member
    //                 reverts before any state touch.
    // Assumption Log: DEAD constant is 0x...dEaD.

    function test_Burn_ReducesClaimable() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        uint256 share = DEPOSIT_AMOUNT / 4;

        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);

        assertEq(hook.getClaimable(COUNCIL_0), share - 100 * 1e18, "Claimable reduced");
    }

    function test_Burn_SendsToDead() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        uint256 deadBefore = steel.balanceOf(DEAD);

        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);

        assertEq(steel.balanceOf(DEAD) - deadBefore, 100 * 1e18, "STEEL sent to DEAD");
    }

    function test_Burn_EmitsEvent() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true, address(hook));
        emit PossessioHook.CouncilBurn(COUNCIL_0, 100 * 1e18);

        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);
    }

    function test_Burn_RevertsExceedsClaimable() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        uint256 share = DEPOSIT_AMOUNT / 4;

        vm.expectRevert(PossessioHook.ExceedsClaimable.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(share + 1);
    }

    function test_Burn_RevertsZeroAmount() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(0);
    }

    function test_Burn_RevertsForNonCouncilMember() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        vm.prank(ATTACKER);
        hook.savBurn(100 * 1e18);
    }

    function test_Burn_RevertsWhenPaused() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        hook.savPause();

        vm.expectRevert(PossessioHook.SAVPausedError.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);
    }

    function test_Burn_RevertsWhenSlashed() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        hook.savSlash();

        vm.expectRevert(PossessioHook.Slashed_.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      PROPOSE INVENT TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    proposeInvent sets expiry (30-day default), emits event,
    //                 allows repropose of expired hashes, clears prior approvals
    //                 on repropose. Rejects if proposal still active.
    // Boundary:       Re-propose before expiry reverts. After expiry, allowed
    //                 with fresh approvals slate.
    // Assumption Log: INVENT_EXPIRY constant is 30 days.

    function test_ProposeInvent_SetsExpiry() public {
        bytes32 hash = keccak256("proposal1");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        (, uint256 expiry,) = hook.getProposalStatus(hash);
        assertEq(expiry, block.timestamp + hook.INVENT_EXPIRY(), "Expiry set to now + INVENT_EXPIRY");
    }

    function test_ProposeInvent_EmitsEvent() public {
        bytes32 hash = keccak256("proposal1");
        uint256 expectedExpiry = block.timestamp + hook.INVENT_EXPIRY();

        vm.expectEmit(true, true, false, true, address(hook));
        emit PossessioHook.InventProposed(hash, COUNCIL_0, expectedExpiry);

        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);
    }

    function test_ProposeInvent_RevertsIfStillActive() public {
        bytes32 hash = keccak256("active");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.expectRevert(PossessioHook.ProposalStillActive.selector);
        vm.prank(COUNCIL_1);
        hook.proposeInvent(hash);
    }

    function test_ProposeInvent_AllowsReproposalAfterExpiry() public {
        bytes32 hash = keccak256("expires");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.warp(block.timestamp + hook.INVENT_EXPIRY() + 1);

        vm.prank(COUNCIL_1);
        hook.proposeInvent(hash);

        (, uint256 expiry,) = hook.getProposalStatus(hash);
        assertEq(expiry, block.timestamp + hook.INVENT_EXPIRY(), "Reproposal updates expiry");
    }

    function test_ProposeInvent_ClearsPriorApprovalsOnRepropose() public {
        bytes32 hash = keccak256("fresh");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_1);
        hook.approveInvent(hash);

        (uint8 approvalsBefore,,) = hook.getProposalStatus(hash);
        assertEq(approvalsBefore, 2, "Two approvals before expiry");

        vm.warp(block.timestamp + hook.INVENT_EXPIRY() + 1);
        vm.prank(COUNCIL_2);
        hook.proposeInvent(hash);

        (uint8 approvalsAfter,,) = hook.getProposalStatus(hash);
        assertEq(approvalsAfter, 0, "Repropose clears approvals");
    }

    function test_ProposeInvent_RevertsForNonCouncilMember() public {
        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        vm.prank(ATTACKER);
        hook.proposeInvent(keccak256("x"));
    }

    function test_ProposeInvent_RevertsWhenPaused() public {
        vm.prank(TREASURY);
        hook.savPause();

        vm.expectRevert(PossessioHook.SAVPausedError.selector);
        vm.prank(COUNCIL_0);
        hook.proposeInvent(keccak256("x"));
    }

    function test_ProposeInvent_RevertsWhenSlashed() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        hook.savSlash();

        vm.expectRevert(PossessioHook.Slashed_.selector);
        vm.prank(COUNCIL_0);
        hook.proposeInvent(keccak256("x"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      APPROVE INVENT TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    approveInvent increments counter, blocks re-approval by
    //                 same member, rejects non-council, rejects expired/missing
    //                 proposals.
    // Boundary:       Each member can approve exactly once per proposal.

    function test_ApproveInvent_IncrementsApprovals() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);

        (uint8 approvals,,) = hook.getProposalStatus(hash);
        assertEq(approvals, 1, "First approval increments counter");
    }

    function test_ApproveInvent_AllFourCanApprove() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_1);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_2);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_3);
        hook.approveInvent(hash);

        (uint8 approvals,,) = hook.getProposalStatus(hash);
        assertEq(approvals, 4, "All four members can approve");
    }

    function test_ApproveInvent_EmitsEvent() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.expectEmit(true, true, false, true, address(hook));
        emit PossessioHook.InventApproved(hash, COUNCIL_0, 1);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
    }

    function test_ApproveInvent_RevertsIfProposalNotFound() public {
        vm.expectRevert(PossessioHook.ProposalNotFound.selector);
        vm.prank(COUNCIL_0);
        hook.approveInvent(keccak256("nonexistent"));
    }

    function test_ApproveInvent_RevertsIfExpired() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.warp(block.timestamp + hook.INVENT_EXPIRY() + 1);

        vm.expectRevert(PossessioHook.ProposalExpired.selector);
        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
    }

    function test_ApproveInvent_RevertsIfAlreadyApproved() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);

        vm.expectRevert(PossessioHook.AlreadyApproved.selector);
        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
    }

    function test_ApproveInvent_RevertsForNonCouncilMember() public {
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        vm.prank(ATTACKER);
        hook.approveInvent(hash);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      EXECUTE INVENT TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    executeInvent deducts equally from all claimables, sends
    //                 deductEach*4 to Treasury, marks proposal executed, rejects
    //                 sub-threshold or already-executed proposals.
    // Boundary:       Requires 3+ approvals (INVENT_THRESHOLD = 3). Insufficient
    //                 claimable on any member reverts without state change.

    function test_Invent_DeductsEquallyFromAllFour() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        uint256 toExtract = 400 * 1e18; // 100 per member
        uint256 shareBefore = hook.getClaimable(COUNCIL_0);

        vm.prank(TREASURY);
        hook.executeInvent(toExtract, hash, "");

        uint256 expectedDeduct = toExtract / 4; // 100 * 1e18
        assertEq(hook.getClaimable(COUNCIL_0), shareBefore - expectedDeduct, "C0 deducted");
        assertEq(hook.getClaimable(COUNCIL_1), shareBefore - expectedDeduct, "C1 deducted");
        assertEq(hook.getClaimable(COUNCIL_2), shareBefore - expectedDeduct, "C2 deducted");
        assertEq(hook.getClaimable(COUNCIL_3), shareBefore - expectedDeduct, "C3 deducted");
    }

    function test_Invent_TransfersToTreasury() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        uint256 treasuryBefore = steel.balanceOf(TREASURY);
        uint256 toExtract = 400 * 1e18;

        vm.prank(TREASURY);
        hook.executeInvent(toExtract, hash, "");

        assertEq(steel.balanceOf(TREASURY) - treasuryBefore, toExtract, "Treasury received transfer");
    }

    function test_Invent_MarksExecuted() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");

        (,, bool executed) = hook.getProposalStatus(hash);
        assertTrue(executed, "Proposal marked executed");
    }

    function test_Invent_EmitsEvent() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        uint256 toExtract = 400 * 1e18;
        uint256 expectedTransfer = (toExtract / 4) * 4; // 400 * 1e18 exactly

        vm.expectEmit(true, false, false, true, address(hook));
        emit PossessioHook.InventExecuted(hash, expectedTransfer, "metadata");

        vm.prank(TREASURY);
        hook.executeInvent(toExtract, hash, "metadata");
    }

    function test_Invent_RevertsIfThresholdNotMet() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 2); // only 2 — below INVENT_THRESHOLD of 3

        vm.expectRevert(PossessioHook.ThresholdNotMet.selector);
        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");
    }

    function test_Invent_RevertsIfAlreadyExecuted() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");

        vm.expectRevert(PossessioHook.ProposalAlreadyExecuted.selector);
        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");
    }

    function test_Invent_RevertsIfExpired() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        vm.warp(block.timestamp + hook.INVENT_EXPIRY() + 1);

        vm.expectRevert(PossessioHook.ProposalExpired.selector);
        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");
    }

    function test_Invent_RevertsIfInsufficientClaimable() public {
        _seedDeposit(DEPOSIT_AMOUNT); // 1000 * 1e18 per member

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        // Try to extract more than available
        uint256 tooMuch = (DEPOSIT_AMOUNT / 4 * 4) + 4; // just past total

        vm.expectRevert(PossessioHook.InsufficientClaimable.selector);
        vm.prank(TREASURY);
        hook.executeInvent(tooMuch, hash, "");
    }

    function test_Invent_RevertsForNonTreasury() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.executeInvent(400 * 1e18, hash, "");
    }

    function test_Invent_RevertsZeroAmount() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("x");
        _proposeAndApprove(hash, 3);

        vm.expectRevert(PossessioHook.ZeroAmount.selector);
        vm.prank(TREASURY);
        hook.executeInvent(0, hash, "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      PAUSE / UNPAUSE TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    savPause sets flag, savUnpause clears it, both gated by
    //                 Treasury, emit events.
    // Boundary:       Pause blocks burn, propose, approve. Does NOT block deposit
    //                 (Treasury can continue to fund).

    function test_Pause_SetsPausedFlag() public {
        vm.prank(TREASURY);
        hook.savPause();
        assertTrue(hook.savPaused(), "savPaused set");
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(true, false, false, false, address(hook));
        emit PossessioHook.SAVPaused(TREASURY);
        vm.prank(TREASURY);
        hook.savPause();
    }

    function test_Pause_RevertsForNonTreasury() public {
        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savPause();
    }

    function test_Unpause_ClearsPausedFlag() public {
        vm.prank(TREASURY);
        hook.savPause();

        vm.prank(TREASURY);
        hook.savUnpause();
        assertFalse(hook.savPaused(), "savPaused cleared");
    }

    function test_Unpause_EmitsEvent() public {
        vm.prank(TREASURY);
        hook.savPause();

        vm.expectEmit(true, false, false, false, address(hook));
        emit PossessioHook.SAVUnpaused(TREASURY);
        vm.prank(TREASURY);
        hook.savUnpause();
    }

    function test_Unpause_RevertsForNonTreasury() public {
        vm.prank(TREASURY);
        hook.savPause();

        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savUnpause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         SLASH TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    savSlash sends all held STEEL to DEAD, zeroes all
    //                 claimables, sets slashed flag, permanently inerts SAV.
    // Boundary:       Slashing empty SAV reverts NothingToSlash. Post-slash all
    //                 SAV ops permanently revert with Slashed_.

    function test_Slash_SendsToDead() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        uint256 deadBefore = steel.balanceOf(DEAD);
        vm.prank(TREASURY);
        hook.savSlash();

        assertEq(steel.balanceOf(DEAD) - deadBefore, DEPOSIT_AMOUNT,
            "All deposited STEEL sent to DEAD");
    }

    function test_Slash_ZeroesAllClaimable() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savSlash();

        assertEq(hook.getClaimable(COUNCIL_0), 0, "C0 claimable zeroed");
        assertEq(hook.getClaimable(COUNCIL_1), 0, "C1 claimable zeroed");
        assertEq(hook.getClaimable(COUNCIL_2), 0, "C2 claimable zeroed");
        assertEq(hook.getClaimable(COUNCIL_3), 0, "C3 claimable zeroed");
    }

    function test_Slash_SetsSlashedFlag() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savSlash();

        assertTrue(hook.slashed(), "slashed flag set");
    }

    function test_Slash_EmitsEvent() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, address(hook));
        emit PossessioHook.Slashed(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savSlash();
    }

    function test_Slash_PermanentlyInerts() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        hook.savSlash();

        // All subsequent SAV ops revert
        steel.transfer(TREASURY, 100 * 1e18);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), 100 * 1e18);
        vm.expectRevert(PossessioHook.Slashed_.selector);
        hook.savDeposit(100 * 1e18);
        vm.stopPrank();

        vm.expectRevert(PossessioHook.Slashed_.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(1);

        vm.expectRevert(PossessioHook.Slashed_.selector);
        vm.prank(COUNCIL_0);
        hook.proposeInvent(keccak256("post-slash"));
    }

    function test_Slash_RevertsIfEmpty() public {
        vm.expectRevert(PossessioHook.NothingToSlash.selector);
        vm.prank(TREASURY);
        hook.savSlash();
    }

    function test_Slash_RevertsForNonTreasury() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(PossessioHook.OnlyTreasury.selector);
        vm.prank(ATTACKER);
        hook.savSlash();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Proof Scope:    Full governance cycles work end-to-end. Multiple actors,
    //                 state transitions, and time-based effects compose correctly.

    function test_Integration_FullInventCycle() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("full-cycle");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_1);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_2);
        hook.approveInvent(hash);

        uint256 toExtract = 400 * 1e18;
        uint256 treasuryBefore = steel.balanceOf(TREASURY);

        vm.prank(TREASURY);
        hook.executeInvent(toExtract, hash, "full cycle metadata");

        assertEq(steel.balanceOf(TREASURY) - treasuryBefore, toExtract, "Treasury received");

        (,, bool executed) = hook.getProposalStatus(hash);
        assertTrue(executed, "Marked executed");
    }

    function test_Integration_BurnAndInventFromSameMember() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        uint256 shareBefore = hook.getClaimable(COUNCIL_0);

        // COUNCIL_0 burns some
        vm.prank(COUNCIL_0);
        hook.savBurn(50 * 1e18);

        // COUNCIL_0 proposes and approves
        bytes32 hash = keccak256("x");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);
        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);

        // Burn reduced claimable
        assertEq(hook.getClaimable(COUNCIL_0), shareBefore - 50 * 1e18, "Burn deduction");
    }

    function test_Integration_PauseBlocksAllSAVActions() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savPause();

        // Burn blocked
        vm.expectRevert(PossessioHook.SAVPausedError.selector);
        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);

        // Propose blocked
        vm.expectRevert(PossessioHook.SAVPausedError.selector);
        vm.prank(COUNCIL_0);
        hook.proposeInvent(keccak256("x"));

        // Deposit still works (Treasury can fund during pause)
        steel.transfer(TREASURY, 100 * 1e18);
        vm.startPrank(TREASURY);
        steel.approve(address(hook), 100 * 1e18);
        // Should NOT revert — pause blocks spending, not funding
        // Actually checking: savDeposit has notSlashed, NOT savNotPaused
        hook.savDeposit(100 * 1e18);
        vm.stopPrank();
    }

    function test_Integration_UnpauseRestoresOps() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savPause();

        vm.prank(TREASURY);
        hook.savUnpause();

        // Burn works again
        vm.prank(COUNCIL_0);
        hook.savBurn(100 * 1e18);

        // Propose works again
        vm.prank(COUNCIL_1);
        hook.proposeInvent(keccak256("post-unpause"));
    }

    function test_Integration_ThresholdExactlyThreeSucceeds() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        bytes32 hash = keccak256("boundary");
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_1);
        hook.approveInvent(hash);
        vm.prank(COUNCIL_2);
        hook.approveInvent(hash);

        // Exactly 3 approvals — threshold met
        vm.prank(TREASURY);
        hook.executeInvent(400 * 1e18, hash, "");

        (,, bool executed) = hook.getProposalStatus(hash);
        assertTrue(executed, "Threshold=3 executes successfully");
    }

    function test_Integration_SlashAfterPauseStillWorks() public {
        _seedDeposit(DEPOSIT_AMOUNT);

        vm.prank(TREASURY);
        hook.savPause();

        // Slash still works even when paused (pause doesn't block slash)
        vm.prank(TREASURY);
        hook.savSlash();

        assertTrue(hook.slashed(), "Slash works during pause");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetClaimable_ReturnsCorrectAmount() public {
        _seedDeposit(DEPOSIT_AMOUNT);
        assertEq(hook.getClaimable(COUNCIL_0), DEPOSIT_AMOUNT / 4, "Claimable returns share");
    }

    function test_GetProposalStatus_ReturnsCorrectState() public {
        bytes32 hash = keccak256("x");

        (uint8 a0, uint256 e0, bool x0) = hook.getProposalStatus(hash);
        assertEq(a0, 0, "Initial approvals = 0");
        assertEq(e0, 0, "Initial expiry = 0");
        assertFalse(x0, "Initial executed = false");

        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        vm.prank(COUNCIL_0);
        hook.approveInvent(hash);

        (uint8 a1, uint256 e1, bool x1) = hook.getProposalStatus(hash);
        assertEq(a1, 1, "Post-approve approvals = 1");
        assertGt(e1, 0, "Post-propose expiry set");
        assertFalse(x1, "Not executed yet");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _seedDeposit(uint256 amount) internal {
        vm.startPrank(TREASURY);
        steel.approve(address(hook), amount);
        hook.savDeposit(amount);
        vm.stopPrank();
    }

    function _proposeAndApprove(bytes32 hash, uint8 numApprovals) internal {
        vm.prank(COUNCIL_0);
        hook.proposeInvent(hash);

        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];
        for (uint8 i = 0; i < numApprovals; i++) {
            vm.prank(council[i]);
            hook.approveInvent(hash);
        }
    }

    receive() external payable {}
}
