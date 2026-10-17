// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";
import {
    MockUSDC_G, MockDAI_G, MockCbETH_G, MockWETH_G, MockV3Router_G, MockAerodromeRouter_G,
    MockMorphoVault_G, MockChainlink_G, MockLSTRates_G
} from "./PossessioPayments_Gauntlet.t.sol";

/// K-1 (external review, KupiaSec 2026-10-15): the lost-guardian-key way out.
/// Its own contract: the Gauntlet contract sits at solc's 64 KB assembly limit.
contract PossessioPaymentsK1 is Test {
    PossessioPayments payments;
    MockUSDC_G        usdc;

    address MERCHANT = address(0xA11CE);
    address GUARDIAN = address(0xC1A0);
    address ATTACKER = address(0xBAD);
    address PAYEE    = address(0xD11);

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC_G();
        MockDAI_G dai = new MockDAI_G();
        MockCbETH_G cbeth = new MockCbETH_G();
        MockWETH_G weth = new MockWETH_G();
        MockV3Router_G router = new MockV3Router_G(address(usdc), address(dai), address(cbeth));
        router.setWeth(address(weth));
        payments = deployPayments(PossessioPayments.DeployParams({
            owner:            MERCHANT,
            usdc:             address(usdc),
            cbeth:            address(cbeth),
            dai:              address(dai),
            weth:             address(weth),
            router:           address(router),
            aeroRouter:       address(new MockAerodromeRouter_G(address(weth), address(cbeth))),
            morphoVault:      address(new MockMorphoVault_G(address(usdc))),
            chainlink:        address(new MockChainlink_G(int256(980_000_000_000_000_000), 18)),
            chainlinkDai:     address(new MockChainlink_G(int256(500_000_000_000), 8)),
            chainlinkUsdcUsd: address(new MockChainlink_G(int256(100_000_000), 8)),
            chainlinkEthUsd:  address(new MockChainlink_G(int256(300_000_000_000), 8)),
            lstRates:         address(new MockLSTRates_G()),
            minSwapBatch:     100 * 1e6,
            daiCeiling:       5_000 * 1e18,
            dailyLimit:       1_000 * 1e18,
            usdcDailyLimit:   1_000 * 1e6,
            cbEthDailyLimit:  1 ether
        }));
    }

    /// Seat a guardian, arm it, freeze withdrawals, then lose the guardian key:
    /// from here on GUARDIAN never acts again. Leaves the guardian disarmed.
    function _K1_freezeThenLoseGuardianAndDisarm() internal {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();
        vm.prank(GUARDIAN);
        payments.setWithdrawalsFrozen(true);
        vm.prank(MERCHANT);
        payments.queueGuardianDisable();
        vm.warp(block.timestamp + payments.GUARDIAN_DISABLE_DELAY() + 1);
        vm.prank(MERCHANT);
        payments.disableGuardian();
    }

    /// The pre-K-1 wall: after the disarm every owner path still meets the freeze.
    function test_K1_disarmAloneLeavesTheFreezeOn() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        usdc.mint(address(payments), 500 * 1e6);
        assertTrue(payments.withdrawalsFrozen(), "the disarm does not lift the freeze");
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.WithdrawalsFrozen.selector);
        payments.sendUSDC(100 * 1e6, PAYEE);
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.prank(MERCHANT);
        vm.expectRevert();                                  // the owner cannot unfreeze itself
        payments.setWithdrawalsFrozen(false);
        vm.prank(MERCHANT);
        vm.expectRevert();                                  // nor seat a new guardian (P-H1)
        payments.grantRole(gRole, MERCHANT);
    }

    function test_K1_lostGuardianKey_ownerReleasesAfterDelay() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        usdc.mint(address(payments), 500 * 1e6);
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        assertEq(payments.freezeReleaseExecuteAfter(), block.timestamp + payments.FREEZE_RELEASE_DELAY());
        vm.warp(block.timestamp + payments.FREEZE_RELEASE_DELAY() - 1);
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.FreezeReleaseNotReady.selector);
        payments.executeFreezeRelease();
        vm.warp(block.timestamp + 2);
        vm.prank(MERCHANT);
        payments.executeFreezeRelease();
        assertFalse(payments.withdrawalsFrozen(), "the release lifts the freeze");
        assertEq(payments.freezeReleaseExecuteAfter(), 0, "the queue is spent");
        vm.prank(MERCHANT);
        payments.sendUSDC(100 * 1e6, PAYEE);                // within the 24h limit
        assertEq(usdc.balanceOf(PAYEE), 100 * 1e6, "the merchant reaches the funds again");
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.FreezeReleaseNotReady.selector);
        payments.executeFreezeRelease();                    // one queue, one release
    }

    /// The stolen-owner-key case: a guardian that is still there vetoes the
    /// release, armed or not, every time it is queued.
    function test_K1_guardianVetoesRelease_evenWhileDisarmed() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        vm.prank(GUARDIAN);
        payments.cancelFreezeRelease();
        vm.warp(block.timestamp + payments.FREEZE_RELEASE_DELAY() + 1);
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.FreezeReleaseNotReady.selector);
        payments.executeFreezeRelease();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();                      // re-queuing restarts the clock
        vm.prank(GUARDIAN);
        payments.cancelFreezeRelease();
        assertTrue(payments.withdrawalsFrozen(), "the freeze held");
    }

    function test_K1_releaseNeedsTheGuardianDisarmed() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.startPrank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        payments.enableGuardian();
        vm.stopPrank();
        vm.prank(GUARDIAN);
        payments.setWithdrawalsFrozen(true);
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.GuardianStillArmed.selector);
        payments.queueFreezeRelease();
    }

    function test_K1_releaseNeedsAFreeze() public {
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.NotFrozen.selector);
        payments.queueFreezeRelease();
    }

    /// Re-arming the guardian hands the decision back to it. Since the review
    /// of 2026-10-17 (F-1) the re-arm VOIDS the queue, so the release fails as
    /// "nothing queued", not as "guardian armed": the stale queue no longer
    /// exists to be blocked. GuardianStillArmed in executeFreezeRelease stays
    /// as defence in depth.
    function test_K1_rearmedGuardianBlocksTheRelease() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        vm.prank(MERCHANT);
        payments.enableGuardian();
        vm.warp(block.timestamp + payments.FREEZE_RELEASE_DELAY() + 1);
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.FreezeReleaseNotReady.selector);
        payments.executeFreezeRelease();
        assertTrue(payments.withdrawalsFrozen());
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.GuardianStillArmed.selector);
        payments.queueFreezeRelease();                      // and it cannot be re-queued while armed
    }

    function test_K1_strangersCannotQueueCancelOrExecute() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        vm.prank(ATTACKER);
        vm.expectRevert();
        payments.queueFreezeRelease();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        vm.prank(ATTACKER);
        vm.expectRevert();
        payments.cancelFreezeRelease();
        vm.warp(block.timestamp + payments.FREEZE_RELEASE_DELAY() + 1);
        vm.prank(ATTACKER);
        vm.expectRevert();
        payments.executeFreezeRelease();
        assertTrue(payments.withdrawalsFrozen());
    }

    /// Review 2026-10-17 (F-1): a release queued while disarmed is void the
    /// moment the guardian is re-armed. Before the fix the stale queue outlived
    /// the re-arm and lifted a LATER freeze as soon as the next 7-day disarm
    /// completed, cutting K-1's stated 37-day cost to 7 days.
    function test_K1_rearmVoidsTheQueuedRelease() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        assertGt(payments.freezeReleaseExecuteAfter(), 0, "queued");
        vm.prank(MERCHANT);
        vm.expectEmit(address(payments));
        emit PossessioPayments.FreezeReleaseCancelled(MERCHANT);
        payments.enableGuardian();
        assertEq(payments.freezeReleaseExecuteAfter(), 0, "the re-arm voids the queue");
        // The guardian lifts the freeze, freezes again 40 days on (past the old
        // readyAt), and the owner disarms: only a FRESH 30-day queue may release.
        vm.prank(GUARDIAN);
        payments.setWithdrawalsFrozen(false);
        vm.warp(block.timestamp + 40 days);
        vm.prank(GUARDIAN);
        payments.setWithdrawalsFrozen(true);
        vm.prank(MERCHANT);
        payments.queueGuardianDisable();
        vm.warp(block.timestamp + payments.GUARDIAN_DISABLE_DELAY() + 1);
        vm.prank(MERCHANT);
        payments.disableGuardian();
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.FreezeReleaseNotReady.selector);
        payments.executeFreezeRelease();                    // the stale queue is gone
        assertTrue(payments.withdrawalsFrozen(), "the later freeze holds");
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();                      // the honest path still exists
        assertEq(payments.freezeReleaseExecuteAfter(), block.timestamp + payments.FREEZE_RELEASE_DELAY());
    }

    /// A re-arm with nothing queued cancels nothing and says nothing.
    function test_K1_rearmWithNoQueueCancelsNothing() public {
        bytes32 gRole = payments.GUARDIAN_ROLE();
        vm.prank(MERCHANT);
        payments.grantRole(gRole, GUARDIAN);
        vm.recordLogs();
        vm.prank(MERCHANT);
        payments.enableGuardian();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != PossessioPayments.FreezeReleaseCancelled.selector, "no phantom cancel");
        }
        assertEq(payments.freezeReleaseExecuteAfter(), 0);
        assertTrue(payments.guardianEnabled());
    }
}
