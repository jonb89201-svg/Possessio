// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PLATEStaking.sol";
import "../src/ServiceAccountabilityVault.sol";

// ============================================================
//                     MOCK PLATE TOKEN
// ============================================================

contract MockPLATE {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    string public name    = "PLATE";
    string public symbol  = "PLATE";
    uint8  public decimals = 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address recipient, uint256 amount) {
        balanceOf[recipient] = amount;
        totalSupply = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

// ============================================================
//               SAV GAUNTLET — ADVERSARIAL SUITE
// ============================================================

contract SAVGauntlet is Test {

    PLATEStaking               staking;
    ServiceAccountabilityVault sav;
    MockPLATE                  plate;

    address TREASURY = address(0x1111);
    address C0       = address(0xA001);
    address C1       = address(0xA002);
    address C2       = address(0xA003);
    address C3       = address(0xA004);
    address ATTACKER = address(0xBAD0);

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DEPOSIT = 1_000_000 * 1e18;
    uint256 constant SHARE   = DEPOSIT / 4;

    bytes32 constant HASH_A = keccak256("proposal_a");
    bytes32 constant HASH_B = keccak256("proposal_b");

    function setUp() public {
        plate   = new MockPLATE(TREASURY, 100_000_000 * 1e18);
        staking = new PLATEStaking(address(plate), TREASURY);

        address[4] memory council = [C0, C1, C2, C3];
        sav = new ServiceAccountabilityVault(
            address(plate),
            TREASURY,
            address(staking),
            council
        );

        vm.prank(TREASURY);
        staking.setSAV(address(sav));

        vm.prank(TREASURY);
        plate.approve(address(sav), type(uint256).max);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(TREASURY);
        sav.deposit(amount);
    }

    function _propose(bytes32 hash) internal {
        vm.prank(C0);
        sav.proposeInvent(hash);
    }

    function _approveThree(bytes32 hash) internal {
        vm.prank(C0); sav.approveInvent(hash);
        vm.prank(C1); sav.approveInvent(hash);
        vm.prank(C2); sav.approveInvent(hash);
    }

    // ── Attack 1: Governance Griefing ────────────────────────
    // A council member approves then drains claimable before
    // invent() executes. Known design property — tested here
    // to confirm behavior and document it explicitly.

    function test_Gauntlet_GovernanceGriefing_BurnAfterApproval() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);

        // C0 drains entire claimable after approving
        vm.prank(C0);
        sav.burn(SHARE);

        // invent() must revert — C0 has no balance
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.InsufficientClaimable.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_GovernanceGriefing_StakeAfterApproval() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);

        vm.prank(C0);
        sav.stake(SHARE);

        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.InsufficientClaimable.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_GovernanceGriefing_PartialDrainBlocksFullInvent() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);

        // C0 burns half — full DEPOSIT invent now blocked
        vm.prank(C0);
        sav.burn(SHARE / 2);

        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.InsufficientClaimable.selector);
        sav.invent(DEPOSIT, HASH_A, "");

        // Smaller invent still succeeds — deductEach = SHARE/2
        vm.prank(TREASURY);
        sav.invent(DEPOSIT / 2, HASH_A, "");
    }

    // ── Attack 2: Unauthorized Access ────────────────────────

    function test_Gauntlet_Unauthorized_Deposit() public {
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.deposit(1000 * 1e18);
    }

    function test_Gauntlet_Unauthorized_Burn() public {
        _deposit(DEPOSIT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.burn(100 * 1e18);
    }

    function test_Gauntlet_Unauthorized_Stake() public {
        _deposit(DEPOSIT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.stake(100 * 1e18);
    }

    function test_Gauntlet_Unauthorized_Pause() public {
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.pause();
    }

    function test_Gauntlet_Unauthorized_Unpause() public {
        vm.prank(TREASURY); sav.pause();
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.unpause();
    }

    function test_Gauntlet_Unauthorized_Slash() public {
        _deposit(DEPOSIT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.slash();
    }

    function test_Gauntlet_Unauthorized_Invent() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_CouncilCannotSelfExecuteInvent() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_StakingDirectCallBlocked() public {
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlySAV.selector);
        staking.stake(C0, 100 * 1e18);
    }

    function test_Gauntlet_TreasuryCannotBypassSAVToStake() public {
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.OnlySAV.selector);
        staking.stake(C0, 100 * 1e18);
    }

    // ── Attack 3: Proposal Manipulation ──────────────────────

    function test_Gauntlet_DoubleApproval() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.AlreadyApproved.selector);
        sav.approveInvent(HASH_A);
    }

    function test_Gauntlet_ApproveExpiredProposal() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        vm.warp(block.timestamp + 31 days);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ProposalExpired.selector);
        sav.approveInvent(HASH_A);
    }

    function test_Gauntlet_ExecuteWithInsufficientApprovals() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ThresholdNotMet.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_ExecuteNonExistentProposal() public {
        _deposit(DEPOSIT);
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ProposalNotFound.selector);
        sav.invent(DEPOSIT, HASH_B, "");
    }

    function test_Gauntlet_DoubleExecution() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(TREASURY);
        sav.invent(DEPOSIT, HASH_A, "");
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ProposalAlreadyExecuted.selector);
        sav.invent(DEPOSIT, HASH_A, "");
    }

    function test_Gauntlet_ReproposalWhileActive() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        vm.prank(C1);
        vm.expectRevert(ServiceAccountabilityVault.ProposalStillActive.selector);
        sav.proposeInvent(HASH_A);
    }

    function test_Gauntlet_ApproveAfterExecution() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(TREASURY);
        sav.invent(100 * 1e18, HASH_A, "");
        vm.prank(C3);
        vm.expectRevert(ServiceAccountabilityVault.ProposalAlreadyExecuted.selector);
        sav.approveInvent(HASH_A);
    }

    // ── Attack 4: Slash and Pause State ──────────────────────

    function test_Gauntlet_SlashBlocksAllSubsequentActions() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(TREASURY); sav.slash();

        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.deposit(DEPOSIT);

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.burn(1);

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.stake(1);

        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.invent(DEPOSIT, HASH_A, "");

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.proposeInvent(HASH_B);
    }

    function test_Gauntlet_SlashIsIrreversible() public {
        _deposit(DEPOSIT);
        vm.prank(TREASURY); sav.slash();
        assertTrue(sav.slashed());
        // Confirm permanently inert
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.deposit(DEPOSIT);
        assertTrue(sav.slashed());
    }

    function test_Gauntlet_PauseBlocksSpend() public {
        _deposit(DEPOSIT);
        vm.prank(TREASURY); sav.pause();

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.burn(100 * 1e18);

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.stake(100 * 1e18);

        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.proposeInvent(HASH_A);
    }

    // ── Attack 5: Edge Case Amounts ───────────────────────────

    function test_Gauntlet_BurnZeroAmountReverts() public {
        _deposit(DEPOSIT);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ZeroAmount.selector);
        sav.burn(0);
    }

    function test_Gauntlet_StakeZeroAmountReverts() public {
        _deposit(DEPOSIT);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ZeroAmount.selector);
        sav.stake(0);
    }

    function test_Gauntlet_InventZeroAmountReverts() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ZeroAmount.selector);
        sav.invent(0, HASH_A, "");
    }

    function test_Gauntlet_BurnExactClaimable() public {
        _deposit(DEPOSIT);
        vm.prank(C0);
        sav.burn(SHARE);
        assertEq(sav.claimable(C0), 0);
    }

    function test_Gauntlet_BurnOneWeiOverClaimable() public {
        _deposit(DEPOSIT);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ExceedsClaimable.selector);
        sav.burn(SHARE + 1);
    }

    function test_Gauntlet_InventExceedsTotalClaimable() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.InsufficientClaimable.selector);
        sav.invent(DEPOSIT * 2, HASH_A, "");
    }

    // ── Attack 6: SAV Lock Manipulation ──────────────────────

    function test_Gauntlet_SetSAVTwiceBlocked() public {
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.SAVAlreadyLocked.selector);
        staking.setSAV(address(0x9999));
    }

    function test_Gauntlet_SetSAVToZeroAddressBlocked() public {
        PLATEStaking freshStaking = new PLATEStaking(address(plate), TREASURY);
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.InvalidAddress.selector);
        freshStaking.setSAV(address(0));
    }

    function test_Gauntlet_NonTreasurySetSAVBlocked() public {
        PLATEStaking freshStaking = new PLATEStaking(address(plate), TREASURY);
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlyTreasury.selector);
        freshStaking.setSAV(address(sav));
    }

    // ── Attack 7: Emergency Withdraw ─────────────────────────

    function test_Gauntlet_EmergencyWithdrawStaleMappingDocumented() public {
        _deposit(DEPOSIT);
        vm.prank(C0); sav.stake(100 * 1e18);

        vm.prank(TREASURY);
        staking.emergencyWithdraw();

        // totalStaked reset to 0 — authoritative signal
        assertEq(staking.totalStaked(), 0);
        // staked[C0] is stale — documented behavior, not a bug
        assertEq(staking.getStaked(C0), 100 * 1e18);
    }

    function test_Gauntlet_EmergencyWithdrawEmptyReverts() public {
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.NothingToWithdraw.selector);
        staking.emergencyWithdraw();
    }

    function test_Gauntlet_NonTreasuryEmergencyWithdrawBlocked() public {
        _deposit(DEPOSIT);
        vm.prank(C0); sav.stake(100 * 1e18);
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlyTreasury.selector);
        staking.emergencyWithdraw();
    }

    // ── Attack 8: Accounting Integrity ───────────────────────

    function test_Gauntlet_ClaimableNeverGoesNegative() public {
        _deposit(DEPOSIT);
        vm.prank(C0); sav.burn(SHARE);
        assertEq(sav.claimable(C0), 0);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ExceedsClaimable.selector);
        sav.burn(1);
    }

    function test_Gauntlet_MultipleDepositsAccumulate() public {
        _deposit(DEPOSIT);
        _deposit(DEPOSIT);
        _deposit(DEPOSIT);
        assertEq(sav.claimable(C0), SHARE * 3);
        assertEq(sav.claimable(C1), SHARE * 3);
        assertEq(sav.claimable(C2), SHARE * 3);
        assertEq(sav.claimable(C3), SHARE * 3);
    }

    function test_Gauntlet_InventDeductionIsExact() public {
        _deposit(DEPOSIT);
        _propose(HASH_A);
        _approveThree(HASH_A);

        uint256 inventAmount = 400 * 1e18;
        uint256 deductEach   = inventAmount / 4;

        vm.prank(TREASURY);
        sav.invent(inventAmount, HASH_A, "");

        assertEq(sav.claimable(C0), SHARE - deductEach);
        assertEq(sav.claimable(C1), SHARE - deductEach);
        assertEq(sav.claimable(C2), SHARE - deductEach);
        assertEq(sav.claimable(C3), SHARE - deductEach);
    }

    function test_Gauntlet_SlashZeroesAllClaimable() public {
        _deposit(DEPOSIT);
        vm.prank(C0); sav.burn(100 * 1e18);
        vm.prank(TREASURY); sav.slash();
        assertEq(sav.claimable(C0), 0);
        assertEq(sav.claimable(C1), 0);
        assertEq(sav.claimable(C2), 0);
        assertEq(sav.claimable(C3), 0);
    }

    // ── Attack 9: Full Cycle Stress Tests ────────────────────

    function test_Gauntlet_FullCycleUnderPressure() public {
        _deposit(DEPOSIT);

        vm.prank(C0); sav.burn(50 * 1e18);
        vm.prank(C1); sav.stake(50 * 1e18);
        vm.prank(C2); sav.burn(25 * 1e18);
        vm.prank(C3); sav.stake(25 * 1e18);

        _propose(HASH_A);
        _approveThree(HASH_A);

        uint256 inventAmount = 200 * 1e18;
        uint256 deductEach   = inventAmount / 4;

        assertGe(sav.claimable(C0), deductEach);
        assertGe(sav.claimable(C1), deductEach);
        assertGe(sav.claimable(C2), deductEach);
        assertGe(sav.claimable(C3), deductEach);

        uint256 treasuryBefore = plate.balanceOf(TREASURY);
        vm.prank(TREASURY);
        sav.invent(inventAmount, HASH_A, "");

        assertEq(plate.balanceOf(TREASURY), treasuryBefore + inventAmount);
    }

    function test_Gauntlet_PauseUnpauseDoesNotCorruptState() public {
        _deposit(DEPOSIT);
        vm.prank(C0); sav.burn(100 * 1e18);

        vm.prank(TREASURY); sav.pause();
        assertEq(sav.claimable(C0), SHARE - 100 * 1e18);

        vm.prank(TREASURY); sav.unpause();
        vm.prank(C0); sav.burn(100 * 1e18);
        assertEq(sav.claimable(C0), SHARE - 200 * 1e18);
    }

    function test_Gauntlet_TwoSimultaneousProposals() public {
        _deposit(DEPOSIT);

        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);

        vm.prank(C0); sav.proposeInvent(HASH_B);
        vm.prank(C0); sav.approveInvent(HASH_B);
        vm.prank(C1); sav.approveInvent(HASH_B);
        vm.prank(C2); sav.approveInvent(HASH_B);

        vm.prank(TREASURY);
        sav.invent(100 * 1e18, HASH_A, "");

        vm.prank(TREASURY);
        sav.invent(100 * 1e18, HASH_B, "");

        (,, bool execA) = sav.getProposalStatus(HASH_A);
        (,, bool execB) = sav.getProposalStatus(HASH_B);
        assertTrue(execA);
        assertTrue(execB);
    }
}
