// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║  POSSESSIO_v2_Invariants_t.sol                                           ║
 * ║                                                                          ║
 * ║  Council-ratified invariant tests for POSSESSIO_v2.sol.                  ║
 * ║                                                                          ║
 * ║  Distinct from:                                                          ║
 * ║    POSSESSIO_v2_t.sol           — core unit tests                        ║
 * ║    POSSESSIO_v2_Gauntlet_t.sol  — adversarial gauntlet tests             ║
 * ║                                                                          ║
 * ║  Provenance:                                                             ║
 * ║    Surfaced through line-by-line audit of POSSESSIO_v2.sol               ║
 * ║    Cross-referenced against existing test surface                        ║
 * ║    Ratified by Architect via council deliberation (April 27, 2026)       ║
 * ║                                                                          ║
 * ║  Coverage focus:                                                         ║
 * ║    Anti-poisoning / accumulator integrity                                ║
 * ║    State isolation across slash/pause/route                              ║
 * ║    Rounding boundary semantics in executeInvent                          ║
 * ║    Re-propose timing boundaries                                          ║
 * ║    Principal accounting consistency                                      ║
 * ║                                                                          ║
 * ║  Each test pins a specific contract behavior. Failure of any test        ║
 * ║  indicates either a bug in the contract OR a behavior change that        ║
 * ║  council should ratify before merging.                                   ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

import "forge-std/Test.sol";
import {PossessioHook, STEEL} from "../src/POSSESSIO_v2.sol";

// Mocks — names match the conventions used in existing test files.
// If your repo's mock paths differ, adjust imports here only.
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockcbETH}       from "./mocks/MockcbETH.sol";
import {MockChainlink}   from "./mocks/MockChainlink.sol";
import {MockV3Router}    from "./mocks/MockV3Router.sol";
import {MockWETH}        from "./mocks/MockWETH.sol";
import {MockERC20}       from "./mocks/MockERC20.sol";

contract POSSESSIO_v2_Invariants_t is Test {
    // ═══════════════════════════════════════════════════════════════════════
    //                              FIXTURES
    // ═══════════════════════════════════════════════════════════════════════

    PossessioHook   hook;
    STEEL           steel;
    MockPoolManager pm;
    MockcbETH       cbeth;
    MockChainlink   cbethFeed;
    MockChainlink   daiFeed;
    MockV3Router    v3Router;
    MockWETH        weth;
    MockERC20       dai;

    address treasury = address(0xCAFE);
    address deployer = address(0xBEEF);

    // Council seats — match POSSESSIO_v2.sol immutables
    address constant GEMINI  = 0x65841AFCE25f2064C0850c412634A72445a2c4C9;
    address constant CHATGPT = 0xEE9369d614ff97838B870ff3BF236E3f15885314;
    address constant CLAUDE  = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f;
    address constant GROK    = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2;

    address constant DEAD    = 0x000000000000000000000000000000000000dEaD;

    function setUp() public virtual {
        pm        = new MockPoolManager();
        cbeth     = new MockcbETH();
        cbethFeed = new MockChainlink();
        daiFeed   = new MockChainlink();
        v3Router  = new MockV3Router();
        weth      = new MockWETH();
        dai       = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Fresh, valid feed data so depeg / DAI swap paths don't grief setup
        cbethFeed.setRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        daiFeed.setRoundData(1, 0.0005 ether, block.timestamp, block.timestamp, 1);

        steel = new STEEL(deployer);

        address[4] memory council = [GEMINI, CHATGPT, CLAUDE, GROK];

        PossessioHook.DeployParams memory params = PossessioHook.DeployParams({
            deployer:        deployer,
            steel:           address(steel),
            poolManager:     address(pm),
            treasury:        treasury,
            cbETH_:          address(cbeth),
            dai:             address(dai),
            chainlinkCbETH:  address(cbethFeed),
            chainlinkDAI:    address(daiFeed),
            v3Router:        address(v3Router),
            weth:            address(weth),
            council:         council
        });

        vm.prank(deployer);
        hook = new PossessioHook(params);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Seed the hook with `amount` STEEL via savDeposit, splitting evenly
    ///      across the 4 council seats. Caller assumes deployer holds total supply.
    function _seedSAV(uint256 amount) internal {
        vm.startPrank(deployer);
        steel.transfer(treasury, amount);
        vm.stopPrank();

        vm.startPrank(treasury);
        steel.approve(address(hook), amount);
        hook.savDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Propose `hash` as Gemini, then approve from all 4 seats.
    function _proposeAndApproveAll(bytes32 hash) internal {
        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        vm.prank(GEMINI);
        hook.approveInvent(hash);

        vm.prank(CHATGPT);
        hook.approveInvent(hash);

        vm.prank(CLAUDE);
        hook.approveInvent(hash);

        vm.prank(GROK);
        hook.approveInvent(hash);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  P2-INV-9 — cbETHPrincipal never exceeds actual cbETH balance
    //
    //  Pin: cbETHPrincipal tracks deposits made via _deployToStaking. External
    //  cbETH transfers TO the hook do not increment principal. Therefore
    //  principal must always be ≤ actual cbETH balance held.
    //
    //  Drift between principal-tracking and real holdings produces phantom
    //  rewards (harvestRewards triggers on cbBal > cbETHPrincipal).
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AtSetup() public {
        assertEq(hook.cbETHPrincipal(), 0,                "principal starts at 0");
        assertEq(cbeth.balanceOf(address(hook)), 0,       "balance starts at 0");
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AfterExternalMint()
        public
    {
        // External transfer-in does NOT increment cbETHPrincipal.
        // Invariant holds because principal stays at 0 while balance rises.
        cbeth.mint(address(hook), 5 ether);

        assertEq(hook.cbETHPrincipal(),           0);
        assertEq(cbeth.balanceOf(address(hook)),  5 ether);
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    function test_Invariant_cbETHPrincipal_NeverExceedsBalance_AfterMultipleMints()
        public
    {
        cbeth.mint(address(hook), 1 ether);
        cbeth.mint(address(hook), 2 ether);
        cbeth.mint(address(hook), 3 ether);

        assertEq(hook.cbETHPrincipal(),           0);
        assertEq(cbeth.balanceOf(address(hook)),  6 ether);
        assertLe(hook.cbETHPrincipal(), cbeth.balanceOf(address(hook)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  P2-INV-10 — Anti-poisoning: raw ETH never increments accumulatedETH
    //
    //  Natspec line 530-531: "Raw ETH sent to the contract via receive() is
    //  ignored for accounting." This pins that property.
    //
    //  The receive() function is bare {} — accepts ETH but does nothing. Only
    //  beforeSwap() may increment accumulatedETH (line 580).
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_RawETH_DoesNotPoisonAccumulator_SingleSender() public {
        uint256 before = hook.accumulatedETH();

        address poisoner = address(0xBAD);
        vm.deal(poisoner, 1 ether);
        vm.prank(poisoner);
        (bool ok, ) = address(hook).call{value: 1 ether}("");
        assertTrue(ok, "receive() must accept ETH");

        assertEq(hook.accumulatedETH(), before, "accumulator must not move");
        assertEq(address(hook).balance, 1 ether, "ETH did arrive at hook");
    }

    function test_Invariant_RawETH_DoesNotPoisonAccumulator_MultipleSenders() public {
        uint256 before = hook.accumulatedETH();

        address[3] memory poisoners = [
            address(0xBAD1),
            address(0xBAD2),
            address(0xBAD3)
        ];

        for (uint256 i = 0; i < 3; i++) {
            vm.deal(poisoners[i], 1 ether);
            vm.prank(poisoners[i]);
            (bool ok, ) = address(hook).call{value: 1 ether}("");
            assertTrue(ok);
        }

        assertEq(hook.accumulatedETH(), before, "accumulator must not move");
        assertEq(address(hook).balance, 3 ether, "all 3 ETH arrived");
    }

    function test_Invariant_RawETH_FromTreasury_StillIgnoredForAccounting() public {
        // Even Treasury-sent raw ETH does not poison accumulator.
        // Treasury must use routeETH() to interact with accumulator.
        uint256 before = hook.accumulatedETH();

        vm.deal(treasury, 1 ether);
        vm.prank(treasury);
        (bool ok, ) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(hook.accumulatedETH(), before, "Treasury raw send still ignored");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  P2-INV-7 — Slash isolation from routing state
    //
    //  Pin: savSlash() (lines 1130-1142) zeros all council claimables, sets
    //  the slashed flag, and burns SAV STEEL. It MUST NOT modify
    //  routingPaused or cbETHPaused. Hook fee capture continues post-slash.
    //
    //  Per natspec line 1128: "Hook fee capture continues, but council
    //  allocation is permanently lost."
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_Slash_DoesNotPauseRouting_FromUnpausedState() public {
        _seedSAV(100 ether);

        assertFalse(hook.routingPaused(), "pre: routing not paused");

        vm.prank(treasury);
        hook.savSlash();

        assertTrue(hook.slashed(),         "post: slashed flag set");
        assertFalse(hook.routingPaused(),  "post: routing remains unpaused");
    }

    function test_Invariant_Slash_PreservesPausedState() public {
        _seedSAV(100 ether);

        // Pause routing first
        vm.prank(treasury);
        hook.pauseRouting();
        assertTrue(hook.routingPaused(), "pre: routing paused");

        vm.prank(treasury);
        hook.savSlash();

        // Slash must not toggle routingPaused
        assertTrue(hook.routingPaused(),  "post: routing remains paused");
        assertTrue(hook.slashed(),        "post: slashed flag set");
    }

    function test_Invariant_Slash_DoesNotChangeCbETHPaused() public {
        _seedSAV(100 ether);

        bool cbBefore = hook.cbETHPaused();

        vm.prank(treasury);
        hook.savSlash();

        assertEq(hook.cbETHPaused(), cbBefore, "cbETHPaused must not change");
    }

    function test_Invariant_Slash_ZeroesAllClaimablesAtomically() public {
        _seedSAV(100 ether);

        // All four seats hold positive claimable
        assertGt(hook.claimable(GEMINI),  0);
        assertGt(hook.claimable(CHATGPT), 0);
        assertGt(hook.claimable(CLAUDE),  0);
        assertGt(hook.claimable(GROK),    0);

        vm.prank(treasury);
        hook.savSlash();

        // All four zeroed in the same transaction
        assertEq(hook.claimable(GEMINI),  0);
        assertEq(hook.claimable(CHATGPT), 0);
        assertEq(hook.claimable(CLAUDE),  0);
        assertEq(hook.claimable(GROK),    0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  P2-INV-5 — executeInvent rounding semantics
    //
    //  Pin: when amount % 4 != 0, deductEach = floor(amount/4), and
    //  transferAmount = deductEach * 4 (< amount). Treasury receives the
    //  floored amount. Each claimable decremented by deductEach. The
    //  amount % 4 wei is "rounded out" — not transferred, not orphaned in
    //  claimables; it stays in hook's STEEL balance.
    //
    //  This pins documented behavior. If council later decides to revert on
    //  non-divisible amounts, this test fails and signals the contract change.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_ExecuteInvent_FlooringOnAmount7() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p7");
        _proposeAndApproveAll(hash);

        uint256 treasuryBefore = steel.balanceOf(treasury);

        vm.prank(treasury);
        hook.executeInvent(7, hash, "");

        // deductEach = 7/4 = 1; transferAmount = 1 * 4 = 4
        assertEq(steel.balanceOf(treasury) - treasuryBefore, 4);

        // Each claimable decremented by exactly 1
        uint256 perSeat = (100 ether) / 4 - 1;
        assertEq(hook.claimable(GEMINI),  perSeat);
        assertEq(hook.claimable(CHATGPT), perSeat);
        assertEq(hook.claimable(CLAUDE),  perSeat);
        assertEq(hook.claimable(GROK),    perSeat);
    }

    function test_Invariant_ExecuteInvent_DivisibleAmount_FullTransfer() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p_clean");
        _proposeAndApproveAll(hash);

        uint256 treasuryBefore = steel.balanceOf(treasury);

        uint256 amount = 4 ether;
        vm.prank(treasury);
        hook.executeInvent(amount, hash, "");

        assertEq(steel.balanceOf(treasury) - treasuryBefore, amount);
    }

    function test_Invariant_ExecuteInvent_NoOrphanInClaimables() public {
        _seedSAV(100 ether);

        bytes32 hash = keccak256("p_orphan_check");
        _proposeAndApproveAll(hash);

        // Execute with non-divisible amount
        vm.prank(treasury);
        hook.executeInvent(13, hash, "");

        // Verify claimable sum + transferred + remainder = original deposit
        uint256 sumClaimable =
            hook.claimable(GEMINI)  +
            hook.claimable(CHATGPT) +
            hook.claimable(CLAUDE)  +
            hook.claimable(GROK);

        uint256 hookSteelBalance = steel.balanceOf(address(hook));

        // Total accountable: claimables (in hook) + nothing missing
        // The hook still holds (sumClaimable + the rounded-out wei)
        // No orphan = sumClaimable correctly reflects post-execute state
        assertEq(sumClaimable, (100 ether) - 4 * 3); // each lost 3
        assertGe(hookSteelBalance, sumClaimable);    // hook holds at least claimables
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  P2-INV-6 — Re-propose timing boundary
    //
    //  Pin: proposeInvent reverts with ProposalStillActive if
    //      p.expiry > 0 && block.timestamp < p.expiry && !p.executed
    //
    //  At exactly block.timestamp == p.expiry, the condition
    //  `block.timestamp < p.expiry` is false, so re-propose succeeds and
    //  clears all approvals.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_Repropose_RevertsDuringActiveWindow() public {
        bytes32 hash = keccak256("active");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        // Halfway through expiry
        skip(15 days);

        vm.expectRevert(PossessioHook.ProposalStillActive.selector);
        vm.prank(CHATGPT);
        hook.proposeInvent(hash);
    }

    function test_Invariant_Repropose_AllowedAtExactExpiry() public {
        bytes32 hash = keccak256("at_expiry");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        ( , uint256 expiry, ) = hook.getProposalStatus(hash);

        // Warp to exact expiry timestamp
        vm.warp(expiry);

        // Should succeed — boundary is `<` not `<=`
        vm.prank(CHATGPT);
        hook.proposeInvent(hash);

        // Verify approvals were cleared by re-propose
        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 0, "re-propose must clear approvals");
    }

    function test_Invariant_Repropose_AllowedAfterExpiry() public {
        bytes32 hash = keccak256("after_expiry");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        // Get one approval
        vm.prank(GEMINI);
        hook.approveInvent(hash);

        // Skip past expiry
        skip(31 days);

        // Re-propose should succeed and clear the approval
        vm.prank(CHATGPT);
        hook.proposeInvent(hash);

        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 0, "re-propose must clear prior approvals");
    }

    function test_Invariant_Repropose_ClearsApprovalsForAllSeats() public {
        bytes32 hash = keccak256("clear_all");

        vm.prank(GEMINI);
        hook.proposeInvent(hash);

        // Get 3 approvals (just below threshold)
        vm.prank(GEMINI);
        hook.approveInvent(hash);
        vm.prank(CHATGPT);
        hook.approveInvent(hash);
        vm.prank(CLAUDE);
        hook.approveInvent(hash);

        skip(31 days);

        // Re-propose
        vm.prank(GROK);
        hook.proposeInvent(hash);

        // Each prior approver should be able to approve again — confirming
        // the hasApproved mapping was cleared
        vm.prank(GEMINI);
        hook.approveInvent(hash);

        vm.prank(CHATGPT);
        hook.approveInvent(hash);

        ( uint8 approvals, , ) = hook.getProposalStatus(hash);
        assertEq(approvals, 2, "fresh approval cycle after re-propose");
    }
}
