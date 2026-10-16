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

    /// Re-arming the guardian hands the decision back to it.
    function test_K1_rearmedGuardianBlocksTheRelease() public {
        _K1_freezeThenLoseGuardianAndDisarm();
        vm.prank(MERCHANT);
        payments.queueFreezeRelease();
        vm.prank(MERCHANT);
        payments.enableGuardian();
        vm.warp(block.timestamp + payments.FREEZE_RELEASE_DELAY() + 1);
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.GuardianStillArmed.selector);
        payments.executeFreezeRelease();
        assertTrue(payments.withdrawalsFrozen());
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
}
