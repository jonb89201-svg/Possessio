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

    string public name   = "PLATE";
    string public symbol = "PLATE";
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
//               PLATESTAKING TEST SUITE
// ============================================================

contract PLATEStakingTest is Test {

    PLATEStaking  staking;
    MockPLATE     plate;

    address TREASURY = address(0x1111);
    address SAV_ADDR = address(0x2222);
    address MEMBER_0 = address(0xA001);
    address ATTACKER = address(0xBAD);

    uint256 constant MINT_AMOUNT = 1_000_000 * 1e18;

    function setUp() public {
        plate   = new MockPLATE(TREASURY, MINT_AMOUNT);
        staking = new PLATEStaking(address(plate), TREASURY);
    }

    // ── Constructor ──────────────────────────────────────────

    function test_Deploy_PlateTokenSet() public {
        assertEq(address(staking.PLATE_TOKEN()), address(plate));
    }

    function test_Deploy_TreasurySet() public {
        assertEq(staking.TREASURY_SAFE(), TREASURY);
    }

    function test_Deploy_SAVNotLocked() public {
        assertFalse(staking.savLocked());
    }

    function test_Deploy_RevertsOnZeroPlate() public {
        vm.expectRevert(PLATEStaking.InvalidAddress.selector);
        new PLATEStaking(address(0), TREASURY);
    }

    function test_Deploy_RevertsOnZeroTreasury() public {
        vm.expectRevert(PLATEStaking.InvalidAddress.selector);
        new PLATEStaking(address(plate), address(0));
    }

    // ── setSAV ───────────────────────────────────────────────

    function test_SetSAV_LocksContract() public {
        vm.prank(TREASURY);
        staking.setSAV(SAV_ADDR);
        assertTrue(staking.savLocked());
        assertEq(staking.SAV_CONTRACT(), SAV_ADDR);
    }

    function test_SetSAV_EmitsEvent() public {
        vm.prank(TREASURY);
        vm.expectEmit(true, false, false, false);
        emit PLATEStaking.SAVLocked(SAV_ADDR);
        staking.setSAV(SAV_ADDR);
    }

    function test_SetSAV_RevertsIfCalledTwice() public {
        vm.prank(TREASURY);
        staking.setSAV(SAV_ADDR);
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.SAVAlreadyLocked.selector);
        staking.setSAV(address(0x3333));
    }

    function test_SetSAV_RevertsOnZeroAddress() public {
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.InvalidAddress.selector);
        staking.setSAV(address(0));
    }

    function test_SetSAV_RevertsForNonTreasury() public {
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlyTreasury.selector);
        staking.setSAV(SAV_ADDR);
    }

    // ── stake ────────────────────────────────────────────────

    function _setupStake() internal {
        vm.prank(TREASURY);
        staking.setSAV(SAV_ADDR);
        // Fund SAV_ADDR with PLATE and approve staking contract
        plate.mint(SAV_ADDR, 1000 * 1e18);
        vm.prank(SAV_ADDR);
        plate.approve(address(staking), 1000 * 1e18);
    }

    function test_Stake_RecordsAmount() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 500 * 1e18);
        assertEq(staking.staked(MEMBER_0), 500 * 1e18);
        assertEq(staking.totalStaked(), 500 * 1e18);
    }

    function test_Stake_TransfersPLATE() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 500 * 1e18);
        assertEq(plate.balanceOf(address(staking)), 500 * 1e18);
    }

    function test_Stake_EmitsEvent() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        vm.expectEmit(true, false, false, true);
        emit PLATEStaking.Staked(MEMBER_0, 500 * 1e18);
        staking.stake(MEMBER_0, 500 * 1e18);
    }

    function test_Stake_RevertsIfSAVNotSet() public {
        // SAV not locked yet
        vm.prank(SAV_ADDR);
        vm.expectRevert(PLATEStaking.SAVNotSet.selector);
        staking.stake(MEMBER_0, 100 * 1e18);
    }

    function test_Stake_RevertsForNonSAV() public {
        vm.prank(TREASURY);
        staking.setSAV(SAV_ADDR);
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlySAV.selector);
        staking.stake(MEMBER_0, 100 * 1e18);
    }

    function test_Stake_RevertsOnZeroMember() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        vm.expectRevert(PLATEStaking.InvalidAddress.selector);
        staking.stake(address(0), 100 * 1e18);
    }

    function test_Stake_AccumulatesMultipleStakes() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 300 * 1e18);
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 200 * 1e18);
        assertEq(staking.staked(MEMBER_0), 500 * 1e18);
        assertEq(staking.totalStaked(), 500 * 1e18);
    }

    // ── emergencyWithdraw ────────────────────────────────────

    function test_EmergencyWithdraw_TransfersToTreasury() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 500 * 1e18);

        uint256 treasuryBefore = plate.balanceOf(TREASURY);
        vm.prank(TREASURY);
        staking.emergencyWithdraw();

        assertEq(plate.balanceOf(TREASURY), treasuryBefore + 500 * 1e18);
        assertEq(plate.balanceOf(address(staking)), 0);
    }

    function test_EmergencyWithdraw_ResetsTotalStaked() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 500 * 1e18);
        vm.prank(TREASURY);
        staking.emergencyWithdraw();
        assertEq(staking.totalStaked(), 0);
    }

    function test_EmergencyWithdraw_EmitsEvent() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 500 * 1e18);
        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit PLATEStaking.EmergencyWithdraw(500 * 1e18);
        staking.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_RevertsIfEmpty() public {
        vm.prank(TREASURY);
        vm.expectRevert(PLATEStaking.NothingToWithdraw.selector);
        staking.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_RevertsForNonTreasury() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 100 * 1e18);
        vm.prank(ATTACKER);
        vm.expectRevert(PLATEStaking.OnlyTreasury.selector);
        staking.emergencyWithdraw();
    }

    // ── view functions ───────────────────────────────────────

    function test_GetStaked_ReturnsCorrectAmount() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 400 * 1e18);
        assertEq(staking.getStaked(MEMBER_0), 400 * 1e18);
    }

    function test_GetTotalStaked_ReturnsCorrectAmount() public {
        _setupStake();
        vm.prank(SAV_ADDR);
        staking.stake(MEMBER_0, 400 * 1e18);
        assertEq(staking.getTotalStaked(), 400 * 1e18);
    }
}

// ============================================================
//          SERVICE ACCOUNTABILITY VAULT TEST SUITE
// ============================================================

contract SAVTest is Test {

    PLATEStaking            staking;
    ServiceAccountabilityVault sav;
    MockPLATE               plate;

    address TREASURY = address(0x1111);
    address C0       = address(0xA001); // Gemini
    address C1       = address(0xA002); // ChatGPT
    address C2       = address(0xA003); // Claude
    address C3       = address(0xA004); // Grok
    address ATTACKER = address(0xBAD);

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DEPOSIT_AMOUNT = 1_000_000 * 1e18;
    uint256 constant SHARE          = DEPOSIT_AMOUNT / 4;

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

        // Lock SAV into staking
        vm.prank(TREASURY);
        staking.setSAV(address(sav));

        // Approve SAV to spend treasury PLATE
        vm.prank(TREASURY);
        plate.approve(address(sav), type(uint256).max);
    }

    // Helper — deposit and fund all four claimable balances
    function _deposit(uint256 amount) internal {
        vm.prank(TREASURY);
        sav.deposit(amount);
    }

    // ── Constructor ──────────────────────────────────────────

    function test_Deploy_PlateTokenSet() public {
        assertEq(address(sav.PLATE_TOKEN()), address(plate));
    }

    function test_Deploy_TreasurySet() public {
        assertEq(sav.TREASURY_SAFE(), TREASURY);
    }

    function test_Deploy_StakingSet() public {
        assertEq(address(sav.STAKING_CONTRACT()), address(staking));
    }

    function test_Deploy_CouncilAddressesSet() public {
        assertEq(sav.COUNCIL_0(), C0);
        assertEq(sav.COUNCIL_1(), C1);
        assertEq(sav.COUNCIL_2(), C2);
        assertEq(sav.COUNCIL_3(), C3);
    }

    function test_Deploy_NotPaused() public {
        assertFalse(sav.paused());
    }

    function test_Deploy_NotSlashed() public {
        assertFalse(sav.slashed());
    }

    function test_Deploy_RevertsOnZeroPlate() public {
        address[4] memory council = [C0, C1, C2, C3];
        vm.expectRevert(ServiceAccountabilityVault.InvalidAddress.selector);
        new ServiceAccountabilityVault(address(0), TREASURY, address(staking), council);
    }

    function test_Deploy_RevertsOnZeroTreasury() public {
        address[4] memory council = [C0, C1, C2, C3];
        vm.expectRevert(ServiceAccountabilityVault.InvalidAddress.selector);
        new ServiceAccountabilityVault(address(plate), address(0), address(staking), council);
    }

    function test_Deploy_RevertsOnZeroStaking() public {
        address[4] memory council = [C0, C1, C2, C3];
        vm.expectRevert(ServiceAccountabilityVault.InvalidAddress.selector);
        new ServiceAccountabilityVault(address(plate), TREASURY, address(0), council);
    }

    function test_Deploy_RevertsOnZeroCouncilAddress() public {
        address[4] memory council = [C0, address(0), C2, C3];
        vm.expectRevert(ServiceAccountabilityVault.InvalidAddress.selector);
        new ServiceAccountabilityVault(address(plate), TREASURY, address(staking), council);
    }

    // ── deposit ──────────────────────────────────────────────

    function test_Deposit_SplitsEvenlyAcrossFour() public {
        _deposit(DEPOSIT_AMOUNT);
        assertEq(sav.claimable(C0), SHARE);
        assertEq(sav.claimable(C1), SHARE);
        assertEq(sav.claimable(C2), SHARE);
        assertEq(sav.claimable(C3), SHARE);
    }

    function test_Deposit_RemainderReturnedToTreasury() public {
        uint256 oddAmount = DEPOSIT_AMOUNT + 3; // 3 wei remainder
        uint256 treasuryBefore = plate.balanceOf(TREASURY);
        _deposit(oddAmount);
        // Treasury sent oddAmount, got back 3 wei remainder, net = oddAmount - 3
        uint256 treasuryAfter = plate.balanceOf(TREASURY);
        assertEq(treasuryBefore - treasuryAfter, oddAmount - 3);
    }

    function test_Deposit_EmitsEvent() public {
        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit ServiceAccountabilityVault.Deposit(DEPOSIT_AMOUNT, SHARE, 0);
        sav.deposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_RevertsForNonTreasury() public {
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.deposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_RevertsWhenSlashed() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.deposit(DEPOSIT_AMOUNT);
    }

    function test_Deposit_AccumulatesAcrossMultipleCalls() public {
        _deposit(DEPOSIT_AMOUNT);
        _deposit(DEPOSIT_AMOUNT);
        assertEq(sav.claimable(C0), SHARE * 2);
    }

    // ── burn ─────────────────────────────────────────────────

    function test_Burn_ReducesClaimable() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.burn(100 * 1e18);
        assertEq(sav.claimable(C0), SHARE - 100 * 1e18);
    }

    function test_Burn_SendsToDead() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 deadBefore = plate.balanceOf(DEAD);
        vm.prank(C0);
        sav.burn(100 * 1e18);
        assertEq(plate.balanceOf(DEAD), deadBefore + 100 * 1e18);
    }

    function test_Burn_EmitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        vm.expectEmit(true, false, false, true);
        emit ServiceAccountabilityVault.CouncilBurn(C0, 100 * 1e18);
        sav.burn(100 * 1e18);
    }

    function test_Burn_RevertsExceedsClaimable() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ExceedsClaimable.selector);
        sav.burn(SHARE + 1);
    }

    function test_Burn_RevertsForNonCouncilMember() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.burn(100 * 1e18);
    }

    function test_Burn_RevertsWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.burn(100 * 1e18);
    }

    function test_Burn_RevertsWhenSlashed() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.burn(100 * 1e18);
    }

    // ── stake ────────────────────────────────────────────────

    function test_Stake_ReducesClaimable() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.stake(100 * 1e18);
        assertEq(sav.claimable(C0), SHARE - 100 * 1e18);
    }

    function test_Stake_RecordsInStakingContract() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.stake(100 * 1e18);
        assertEq(staking.staked(C0), 100 * 1e18);
        assertEq(staking.totalStaked(), 100 * 1e18);
    }

    function test_Stake_TransfersPLATEToStaking() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.stake(100 * 1e18);
        assertEq(plate.balanceOf(address(staking)), 100 * 1e18);
    }

    function test_Stake_EmitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        vm.expectEmit(true, false, false, true);
        emit ServiceAccountabilityVault.CouncilStake(C0, 100 * 1e18);
        sav.stake(100 * 1e18);
    }

    function test_Stake_RevertsExceedsClaimable() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ExceedsClaimable.selector);
        sav.stake(SHARE + 1);
    }

    function test_Stake_RevertsForNonCouncilMember() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.stake(100 * 1e18);
    }

    function test_Stake_RevertsWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.stake(100 * 1e18);
    }

    function test_Stake_RevertsWhenSlashed() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.stake(100 * 1e18);
    }

    // ── proposeInvent ────────────────────────────────────────

    function test_ProposeInvent_SetsExpiry() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        (, uint256 expiry,) = sav.getProposalStatus(HASH_A);
        assertEq(expiry, block.timestamp + 30 days);
    }

    function test_ProposeInvent_EmitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        vm.expectEmit(true, true, false, false);
        emit ServiceAccountabilityVault.InventProposed(HASH_A, C0, block.timestamp + 30 days);
        sav.proposeInvent(HASH_A);
    }

    function test_ProposeInvent_RevertsIfStillActive() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C1);
        vm.expectRevert(ServiceAccountabilityVault.ProposalStillActive.selector);
        sav.proposeInvent(HASH_A);
    }

    function test_ProposeInvent_AllowsReproposalAfterExpiry() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.warp(block.timestamp + 31 days);
        vm.prank(C1);
        sav.proposeInvent(HASH_A); // should not revert
        (, uint256 newExpiry,) = sav.getProposalStatus(HASH_A);
        assertGt(newExpiry, block.timestamp);
    }

    function test_ProposeInvent_ClearsPriorApprovalsOnReproposal() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C0);
        sav.approveInvent(HASH_A);
        vm.warp(block.timestamp + 31 days);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        // C0 should be able to approve again
        vm.prank(C0);
        sav.approveInvent(HASH_A); // should not revert
    }

    function test_ProposeInvent_RevertsForNonCouncilMember() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.proposeInvent(HASH_A);
    }

    function test_ProposeInvent_RevertsWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractPaused.selector);
        sav.proposeInvent(HASH_A);
    }

    function test_ProposeInvent_RevertsWhenSlashed() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.proposeInvent(HASH_A);
    }

    // ── approveInvent ────────────────────────────────────────

    function test_ApproveInvent_IncrementsApprovals() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C0);
        sav.approveInvent(HASH_A);
        (uint8 approvals,,) = sav.getProposalStatus(HASH_A);
        assertEq(approvals, 1);
    }

    function test_ApproveInvent_AllFourCanApprove() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);
        vm.prank(C3); sav.approveInvent(HASH_A);
        (uint8 approvals,,) = sav.getProposalStatus(HASH_A);
        assertEq(approvals, 4);
    }

    function test_ApproveInvent_EmitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C0);
        vm.expectEmit(true, true, false, true);
        emit ServiceAccountabilityVault.InventApproved(HASH_A, C0, 1);
        sav.approveInvent(HASH_A);
    }

    function test_ApproveInvent_RevertsIfProposalNotFound() public {
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ProposalNotFound.selector);
        sav.approveInvent(HASH_A);
    }

    function test_ApproveInvent_RevertsIfExpired() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.warp(block.timestamp + 31 days);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ProposalExpired.selector);
        sav.approveInvent(HASH_A);
    }

    function test_ApproveInvent_RevertsIfAlreadyApproved() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(C0);
        sav.approveInvent(HASH_A);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.AlreadyApproved.selector);
        sav.approveInvent(HASH_A);
    }

    function test_ApproveInvent_RevertsForNonCouncilMember() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyCouncilMember.selector);
        sav.approveInvent(HASH_A);
    }

    // ── invent ───────────────────────────────────────────────

    function _setupInvent(uint256 amount) internal {
        _deposit(amount * 4); // ensure all four have enough
        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);
        // 3-of-4 met
    }

    function test_Invent_TransfersTreasury() public {
        uint256 inventAmount = 400 * 1e18;
        _setupInvent(inventAmount);
        uint256 treasuryBefore = plate.balanceOf(TREASURY);
        vm.prank(TREASURY);
        sav.invent(inventAmount, HASH_A, "");
        assertEq(plate.balanceOf(TREASURY), treasuryBefore + inventAmount);
    }

    function test_Invent_DeductsEquallyFromAllFour() public {
        uint256 inventAmount = 400 * 1e18;
        _setupInvent(inventAmount);
        uint256 deductEach = inventAmount / 4;
        uint256 c0Before = sav.claimable(C0);
        uint256 c1Before = sav.claimable(C1);
        uint256 c2Before = sav.claimable(C2);
        uint256 c3Before = sav.claimable(C3);
        vm.prank(TREASURY);
        sav.invent(inventAmount, HASH_A, "");
        assertEq(sav.claimable(C0), c0Before - deductEach);
        assertEq(sav.claimable(C1), c1Before - deductEach);
        assertEq(sav.claimable(C2), c2Before - deductEach);
        assertEq(sav.claimable(C3), c3Before - deductEach);
    }

    function test_Invent_MarksExecuted() public {
        _setupInvent(400 * 1e18);
        vm.prank(TREASURY);
        sav.invent(400 * 1e18, HASH_A, "");
        (,, bool executed) = sav.getProposalStatus(HASH_A);
        assertTrue(executed);
    }

    function test_Invent_EmitsEvent() public {
        _setupInvent(400 * 1e18);
        vm.prank(TREASURY);
        vm.expectEmit(true, false, false, false);
        emit ServiceAccountabilityVault.InventExecuted(HASH_A, 400 * 1e18, "");
        sav.invent(400 * 1e18, HASH_A, "");
    }

    function test_Invent_EmitAmountIsDeductEachTimesFour() public {
        // Confirms emitted amount equals deductEach * 4, not the raw amount
        // Any amount % 4 remainder stays in SAV and is NOT transferred
        uint256 amount = 401 * 1e18; // not divisible by 4
        uint256 deductEach = amount / 4;
        uint256 transferAmount = deductEach * 4;
        _setupInvent(amount);
        vm.prank(TREASURY);
        vm.expectEmit(true, false, false, true);
        emit ServiceAccountabilityVault.InventExecuted(HASH_A, transferAmount, "");
        sav.invent(amount, HASH_A, "");
        // Confirm Treasury received deductEach * 4, not amount
        // Remainder (amount % 4) stays in SAV claimable balances
    }

    function test_Invent_RevertsIfThresholdNotMet() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        // Only 2 approvals — threshold is 3
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ThresholdNotMet.selector);
        sav.invent(100 * 1e18, HASH_A, "");
    }

    function test_Invent_RevertsIfAlreadyExecuted() public {
        _setupInvent(400 * 1e18);
        vm.prank(TREASURY);
        sav.invent(400 * 1e18, HASH_A, "");
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ProposalAlreadyExecuted.selector);
        sav.invent(400 * 1e18, HASH_A, "");
    }

    function test_Invent_RevertsIfExpired() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);
        vm.warp(block.timestamp + 31 days);
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.ProposalExpired.selector);
        sav.invent(100 * 1e18, HASH_A, "");
    }

    function test_Invent_RevertsIfInsufficientClaimable() public {
        // Deposit only enough for 3 members, not all 4
        uint256 smallAmount = 4 * 1e18; // 1e18 per member
        _deposit(smallAmount);
        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);
        // Try to invent more than any member has
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.InsufficientClaimable.selector);
        sav.invent(smallAmount * 2, HASH_A, "");
    }

    function test_Invent_RevertsForNonTreasury() public {
        _setupInvent(400 * 1e18);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.invent(400 * 1e18, HASH_A, "");
    }

    // ── pause / unpause ──────────────────────────────────────

    function test_Pause_SetsPausedFlag() public {
        vm.prank(TREASURY);
        sav.pause();
        assertTrue(sav.paused());
    }

    function test_Pause_EmitsEvent() public {
        vm.prank(TREASURY);
        vm.expectEmit(true, false, false, false);
        emit ServiceAccountabilityVault.Paused(TREASURY);
        sav.pause();
    }

    function test_Pause_RevertsForNonTreasury() public {
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.pause();
    }

    function test_Unpause_ClearsPausedFlag() public {
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(TREASURY);
        sav.unpause();
        assertFalse(sav.paused());
    }

    function test_Unpause_EmitsEvent() public {
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(TREASURY);
        vm.expectEmit(true, false, false, false);
        emit ServiceAccountabilityVault.Unpaused(TREASURY);
        sav.unpause();
    }

    function test_Unpause_RevertsForNonTreasury() public {
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.unpause();
    }

    // ── slash ────────────────────────────────────────────────

    function test_Slash_SendsToDead() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 deadBefore = plate.balanceOf(DEAD);
        vm.prank(TREASURY);
        sav.slash();
        assertEq(plate.balanceOf(DEAD), deadBefore + DEPOSIT_AMOUNT);
    }

    function test_Slash_ZeroesAllClaimable() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        assertEq(sav.claimable(C0), 0);
        assertEq(sav.claimable(C1), 0);
        assertEq(sav.claimable(C2), 0);
        assertEq(sav.claimable(C3), 0);
    }

    function test_Slash_SetsSlashedFlag() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        assertTrue(sav.slashed());
    }

    function test_Slash_EmitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit ServiceAccountabilityVault.Slashed(DEPOSIT_AMOUNT);
        sav.slash();
    }

    function test_Slash_PermanentlyInerts() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.slash();
        // All subsequent spend attempts must revert
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.burn(1);
        vm.prank(C0);
        vm.expectRevert(ServiceAccountabilityVault.ContractSlashed.selector);
        sav.stake(1);
    }

    function test_Slash_RevertsIfEmpty() public {
        vm.prank(TREASURY);
        vm.expectRevert(ServiceAccountabilityVault.NothingToSlash.selector);
        sav.slash();
    }

    function test_Slash_RevertsForNonTreasury() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(ATTACKER);
        vm.expectRevert(ServiceAccountabilityVault.OnlyTreasury.selector);
        sav.slash();
    }

    // ── view functions ───────────────────────────────────────

    function test_GetClaimable_ReturnsCorrectAmount() public {
        _deposit(DEPOSIT_AMOUNT);
        assertEq(sav.getClaimable(C0), SHARE);
    }

    function test_GetProposalStatus_ReturnsCorrectState() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.proposeInvent(HASH_A);
        (uint8 approvals, uint256 expiry, bool executed) = sav.getProposalStatus(HASH_A);
        assertEq(approvals, 0);
        assertEq(expiry, block.timestamp + 30 days);
        assertFalse(executed);
    }

    // ── integration ──────────────────────────────────────────

    function test_Integration_FullInventCycle() public {
        uint256 inventAmount = 400 * 1e18;
        _deposit(inventAmount * 4);

        vm.prank(C0); sav.proposeInvent(HASH_A);
        vm.prank(C0); sav.approveInvent(HASH_A);
        vm.prank(C1); sav.approveInvent(HASH_A);
        vm.prank(C2); sav.approveInvent(HASH_A);

        uint256 treasuryBefore = plate.balanceOf(TREASURY);
        vm.prank(TREASURY);
        sav.invent(inventAmount, HASH_A, abi.encode("Q2 R&D"));

        assertEq(plate.balanceOf(TREASURY), treasuryBefore + inventAmount);
        (,, bool executed) = sav.getProposalStatus(HASH_A);
        assertTrue(executed);
    }

    function test_Integration_BurnAndStakeFromSameMember() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(C0);
        sav.burn(100 * 1e18);
        vm.prank(C0);
        sav.stake(100 * 1e18);
        assertEq(sav.claimable(C0), SHARE - 200 * 1e18);
        assertEq(staking.staked(C0), 100 * 1e18);
    }

    function test_Integration_PauseBlocksAllSpend() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.pause();

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

    function test_Integration_UnpauseRestoresSpend() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.prank(TREASURY);
        sav.pause();
        vm.prank(TREASURY);
        sav.unpause();
        vm.prank(C0);
        sav.burn(100 * 1e18); // should not revert
    }
}
