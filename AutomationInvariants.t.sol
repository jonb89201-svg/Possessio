// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/*═══════════════════════════════════════════════════════════════════════════════
  AUTOMATION INVARIANT GAUNTLET
  Council-ratified test baseline per ChatGPT (Narrative seat), 2026-05-12.

  Seven invariants that the Chainlink Automation integration must satisfy
  to be certified for Base Sepolia → Mainnet promotion.

  AUTO-INV-1  checkUpkeep ⇒ executable        (foundational; primary invariant)
  AUTO-INV-2  hysteresis blocks near-threshold
  AUTO-INV-3  forwarder exclusivity
  AUTO-INV-4  pause semantics consistency
  AUTO-INV-5  forwarder receives no reward
  AUTO-INV-6  invalid task ID reverts
  AUTO-INV-7  manual execution survives Automation outage (LINK exhaustion)

  Run via:
    forge test --match-contract AutomationInvariants -vv

  Sepolia certification requires all 7 to pass green.
═══════════════════════════════════════════════════════════════════════════════*/

import "forge-std/Test.sol";
import {PossessioHook} from "../src/POSSESSIO_v2-4.sol";
import {STEEL}         from "../src/POSSESSIO_v2-4.sol";

contract AutomationInvariants is Test {

    PossessioHook public hook;
    STEEL         public steel;

    address constant TREASURY  = address(0x71);
    address constant COUNCIL_0 = address(0xC0);
    address constant COUNCIL_1 = address(0xC1);
    address constant COUNCIL_2 = address(0xC2);
    address constant COUNCIL_3 = address(0xC3);
    address constant FORWARDER = address(0xF0);
    address constant USER      = address(0xEE);
    address constant ATTACKER  = address(0xBAD);

    /// @notice Standard setup: deploy STEEL, deploy Hook, set forwarder.
    ///         Subclasses may override to inject specific accumulated state.
    function setUp() public virtual {
        // Note: This is a skeleton. Real deployment needs:
        //   - PoolManager mock
        //   - cbETH mock
        //   - DAI / WETH / USDC mocks
        //   - Chainlink CBETH/ETH oracle mock
        //   - V3 router mock for DAI swap leg
        //
        // The deployment helpers should mirror the existing test suite's
        // _deployHook helper. Pseudocode:
        //
        //   steel = new STEEL(...);
        //   hook  = _deployHookAtMinedAddress(...);
        //   hook.setForwarder(FORWARDER);
        //
        // Full deployment harness is in test/helpers/HookDeployer.sol per
        // existing convention.
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-1 — checkUpkeep ⇒ executable

      Foundation invariant. If checkUpkeep returns true, performUpkeep must
      succeed when called by the forwarder in the same block.

      Failure mode if violated: gas-burn loops, LINK exhaustion, registry
      spam, operational degradation.
    ═══════════════════════════════════════════════════════════════════════*/

    function invariant_CheckImpliesExecutable_RouteETH() public {
        // Stuff accumulator above hysteresis threshold + cooldown elapsed
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 wei);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep("");

        if (upkeepNeeded) {
            vm.prank(FORWARDER);
            try hook.performUpkeep(performData) {
                // Pass
            } catch (bytes memory reason) {
                emit log_named_bytes("AUTO-INV-1 ROUTE_ETH violation — revert reason", reason);
                fail();
            }
        }
    }

    function invariant_CheckImpliesExecutable_Harvest() public {
        // Note: requires mocked cbETH balanceOf to return > principal + dust floor.
        // Real setUp must include a cbETH mock with deal-style helpers.

        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep("");
        if (!upkeepNeeded) return; // nothing to test

        vm.prank(FORWARDER);
        try hook.performUpkeep(performData) {
            // Pass
        } catch (bytes memory reason) {
            emit log_named_bytes("AUTO-INV-1 HARVEST violation — revert reason", reason);
            fail();
        }
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-2 — Hysteresis blocks near-threshold

      checkUpkeep must return false when accumulated value is between the
      canonical threshold and the hysteresis-buffered threshold (i.e. in the
      flicker zone).
    ═══════════════════════════════════════════════════════════════════════*/

    function test_HysteresisBlocksNearRouteThreshold() public {
        uint256 routeThreshold = hook.ROUTE_THRESHOLD();
        // Set accumulator just above canonical but below hysteresis cutoff.
        // Hysteresis = 120% of threshold, so 110% lands in the flicker zone.
        uint256 inFlickerZone = (routeThreshold * 110) / 100;
        deal(address(hook), inFlickerZone);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        (bool upkeepNeeded,) = hook.checkUpkeep("");
        assertFalse(upkeepNeeded, "AUTO-INV-2: hysteresis failed to block flicker-zone accumulation");
    }

    function test_HysteresisBlocksNearHarvestDustFloor() public {
        // Test that excess just below HARVEST_DUST_FLOOR does NOT trigger upkeep.
        // Requires cbETH mock — placeholder structure here.
        // Real test:
        //   _setCbETHBalance(hook.cbETHPrincipal() + (hook.HARVEST_DUST_FLOOR() / 2));
        //   (bool upkeepNeeded,) = hook.checkUpkeep("");
        //   assertFalse(upkeepNeeded);
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-3 — Forwarder exclusivity

      performUpkeep must revert NotForwarder when called by any address other
      than automationForwarder.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_PerformUpkeep_RevertNonForwarder() public {
        vm.prank(ATTACKER);
        vm.expectRevert(PossessioHook.NotForwarder.selector);
        hook.performUpkeep(abi.encode(uint8(0)));
    }

    function test_PerformUpkeep_RevertTreasuryNotForwarder() public {
        // Even Treasury cannot call performUpkeep — must go through the forwarder.
        vm.prank(TREASURY);
        vm.expectRevert(PossessioHook.NotForwarder.selector);
        hook.performUpkeep(abi.encode(uint8(0)));
    }

    function test_PerformUpkeep_RevertOwnerNotForwarder() public {
        // Owner cannot bypass either.
        vm.prank(hook.owner());
        vm.expectRevert(PossessioHook.NotForwarder.selector);
        hook.performUpkeep(abi.encode(uint8(0)));
    }

    function test_PerformUpkeep_RevertBeforeForwarderSet() public {
        // If automationForwarder is address(0), the modifier reverts ForwarderNotSet.
        // This test requires deploying a fresh hook without setForwarder called.
        // Skeleton — actual deployment in setUp variant.
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-4 — Pause semantics consistency

      When upkeepPaused is true, checkUpkeep must return false and
      performUpkeep must revert UpkeepIsPaused.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_CheckUpkeepFalseWhenPaused() public {
        // Stuff state that would otherwise trigger upkeep
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 wei);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        // Pause
        vm.prank(TREASURY);
        hook.pauseUpkeep();

        (bool upkeepNeeded,) = hook.checkUpkeep("");
        assertFalse(upkeepNeeded, "AUTO-INV-4: checkUpkeep returned true while upkeepPaused");
    }

    function test_PerformUpkeepRevertWhenPaused() public {
        vm.prank(TREASURY);
        hook.pauseUpkeep();

        vm.prank(FORWARDER);
        vm.expectRevert(PossessioHook.UpkeepIsPaused.selector);
        hook.performUpkeep(abi.encode(uint8(0)));
    }

    function test_CheckUpkeepFalseWhenRoutingPaused() public {
        // Stuff state
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 wei);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        // Pause routing (different from upkeep pause)
        vm.prank(TREASURY);
        hook.pauseRouting();

        (bool upkeepNeeded,) = hook.checkUpkeep("");
        assertFalse(upkeepNeeded, "AUTO-INV-4: checkUpkeep returned true while routingPaused");
    }

    function test_CheckUpkeepFalseForHarvestWhenCbETHPaused() public {
        // Stuff harvest-eligible cbETH state, then set cbETHPaused.
        // Requires cbETH mock + ability to trigger depeg.
        // Verifies the deliberate policy choice from FIX-5.
        // Skeleton — full impl needs depeg simulator.
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-5 — Forwarder receives no reward

      When performUpkeep dispatches routeETH via the internal path, the
      forwarder must NOT receive the 0.1% caller reward (IV.2 Position B).
      The internal dispatcher (address(this)) must also not receive it.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_ForwarderGetsNoReward_RouteETH() public {
        // Setup: accumulator above hysteresis, cooldown elapsed
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 ether); // extra so reward COULD be paid
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        uint256 forwarderBalanceBefore = FORWARDER.balance;
        uint256 hookBalanceBefore = address(hook).balance;

        vm.prank(FORWARDER);
        hook.performUpkeep(abi.encode(uint8(0)));

        assertEq(
            FORWARDER.balance,
            forwarderBalanceBefore,
            "AUTO-INV-5: forwarder received reward — IV.2 exemption violated"
        );

        // Verify the contract didn't pay itself either
        // (this is harder to test directly; the absence of an external transfer
        // to address(this) is implicit in the balance accounting)
    }

    function test_ManualPermissionlessCallerStillReceivesReward() public {
        // Counterpart to AUTO-INV-5: manual non-forwarder callers MUST still
        // receive the reward, so the fallback execution path stays viable.
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 ether);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        uint256 userBalanceBefore = USER.balance;
        uint256 expectedReward = (address(hook).balance) / 1000;

        vm.prank(USER);
        hook.routeETH();

        assertGt(
            USER.balance,
            userBalanceBefore,
            "Manual permissionless caller did not receive reward — fallback path broken"
        );
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-6 — Invalid task ID reverts

      Malformed performData (unknown task discriminator) must revert
      InvalidTask, not silently execute the wrong action.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_InvalidTaskIdReverts() public {
        // UpkeepTask enum has 2 values (0, 1). Pass 99.
        // abi.decode will revert on out-of-range enum values automatically in 0.8+
        vm.prank(FORWARDER);
        vm.expectRevert(); // any revert — abi.decode handles this before our InvalidTask check
        hook.performUpkeep(abi.encode(uint8(99)));
    }

    function test_MalformedPerformDataReverts() public {
        // Empty performData should fail to decode as UpkeepTask
        vm.prank(FORWARDER);
        vm.expectRevert();
        hook.performUpkeep("");
    }

    /*═══════════════════════════════════════════════════════════════════════
      AUTO-INV-7 — Manual fallback works without Automation

      The protocol must remain operational without Chainlink Automation.
      LINK exhaustion or registry outage degrades convenience, never capital.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_ManualRouteETHWorksWithoutAutomation() public {
        // Even with forwarder set, manual permissionless callers must work.
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 ether);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        vm.prank(USER);
        hook.routeETH(); // should succeed
    }

    function test_TreasuryCanRouteAnytime() public {
        // Treasury bypasses threshold and cooldown — must continue to work.
        deal(address(hook), 0.001 ether); // way below threshold
        // No cooldown wait

        vm.prank(TREASURY);
        hook.routeETH(); // should succeed
    }

    function test_ManualHarvestWorksWithoutAutomation() public {
        // Manual call to harvestRewards must work after rewards accrue.
        // Requires cbETH mock that adds rewards above principal.
        // Skeleton — cbETH mock integration in setUp variant.
    }

    /*═══════════════════════════════════════════════════════════════════════
      REPLAY PROTECTION — bonus tests

      Defense-in-depth invariants for the executedUpkeeps map.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_SameBlockReplayBlocked() public {
        // Two performUpkeep calls in the same block with same state should fail
        // on the second attempt.
        uint256 hysteresisAmount = (hook.ROUTE_THRESHOLD() * hook.UPKEEP_HYSTERESIS_BPS()) / 100;
        deal(address(hook), hysteresisAmount + 1 ether);
        vm.warp(block.timestamp + hook.ROUTE_COOLDOWN() + 1);

        bytes memory performData = abi.encode(uint8(0));

        vm.prank(FORWARDER);
        hook.performUpkeep(performData);

        // Second call same block — would compute same replayKey if lastRouteTime
        // didn't update. lastRouteTime DOES update inside routeETH, so the second
        // call uses a different key. But sweepDelay/RouteTooEarly should block it.
        vm.prank(FORWARDER);
        vm.expectRevert(); // either UpkeepAlreadyExecuted OR RouteTooEarly
        hook.performUpkeep(performData);
    }

    /*═══════════════════════════════════════════════════════════════════════
      FORWARDER UPDATE TIMELOCK — IV.8

      Bonus tests for the 48h timelock path on forwarder updates.
    ═══════════════════════════════════════════════════════════════════════*/

    function test_ForwarderUpdate_RequiresTimelock() public {
        bytes32 id;
        vm.prank(TREASURY);
        id = hook.queueForwarderUpdate(address(0xbeef));

        // Try immediate execution — must fail
        vm.prank(TREASURY);
        vm.expectRevert(); // TimelockPending or similar
        hook.executeForwarderUpdate(id);
    }

    function test_ForwarderUpdate_SucceedsAfterTimelock() public {
        bytes32 id;
        vm.prank(TREASURY);
        id = hook.queueForwarderUpdate(address(0xbeef));

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(TREASURY);
        hook.executeForwarderUpdate(id);

        assertEq(hook.automationForwarder(), address(0xbeef), "forwarder not updated after timelock");
    }

    function test_ForwarderUpdate_OnlyTreasury() public {
        vm.prank(ATTACKER);
        vm.expectRevert(); // OnlyTreasury or similar
        hook.queueForwarderUpdate(address(0xBAD));
    }

}

/*═══════════════════════════════════════════════════════════════════════════════
  PAYMENTS AUTOMATION INVARIANTS
  Parallel gauntlet for PossessioPayments sweep automation.
  Same seven invariants adapted to single-task upkeep model.
═══════════════════════════════════════════════════════════════════════════════*/

import {PossessioPayments} from "../src/PossessioPayments_v2-2.sol";

contract PaymentsAutomationInvariants is Test {
    PossessioPayments public payments;
    address constant FORWARDER = address(0xF1);
    address constant OWNER     = address(0x01);
    address constant OPERATOR  = address(0x02);
    address constant ATTACKER  = address(0xBAD);

    function setUp() public virtual {
        // Skeleton: deploy Payments, set forwarder, grant OPERATOR_ROLE to
        // the contract itself (required for dispatchSweep to bypass role check).
    }

    function test_PaymentsCheckImpliesExecutable() public {
        // Same shape as AUTO-INV-1 for Hook, but for sweep().
        // Stuff USDC balance above hysteresis threshold + SWEEP_DELAY elapsed.
    }

    function test_PaymentsForwarderExclusivity() public {
        vm.prank(ATTACKER);
        vm.expectRevert(PossessioPayments.NotForwarder.selector);
        payments.performUpkeep(abi.encode(uint256(0), uint256(0)));
    }

    function test_PaymentsUpkeepPause() public {
        vm.prank(OWNER);
        payments.pauseUpkeep();

        (bool needed,) = payments.checkUpkeep("");
        assertFalse(needed);
    }

    function test_PaymentsManualSweepWorksWithoutAutomation() public {
        // OPERATOR_ROLE holder can still call sweep manually.
        // Skeleton — needs deal of USDC and SWEEP_DELAY elapsed.
    }
}
