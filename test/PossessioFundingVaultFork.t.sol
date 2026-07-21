// SPDX-License-Identifier: MIT
// Fork certification for PossessioFundingVault against REAL Base mainnet USDC.
// Proves the full fund → drawForTrade → returnProceeds round-trip and exact
// exposure accounting hold against the live token (FiatTokenProxy, 6-dec, real
// transfer/transferFrom semantics), not a mock.
//
// FIX B (council, metered-feed/False-Green): with no RPC this suite SKIPS — it
// never vacuously passes. It runs + passes LIVE.
//
// RUN (just this):
//   BASE_RPC_URL="https://mainnet.base.org" \
//     forge test --match-contract PossessioFundingVaultForkTest -vvv
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";

contract PossessioFundingVaultForkTest is Test {
    PossessioFundingVault vault;
    IERC20 usdc;

    // cast-verified Base mainnet USDC (FiatTokenProxy)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address owner  = makeAddr("owner");
    address trader = makeAddr("trader");
    address rail   = makeAddr("tradeDestination");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;

    bool forked;

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        if (!forked) {
            vm.skip(true);
            return;
        }
        usdc = IERC20(USDC);
        vault = new PossessioFundingVault(
            usdc, owner, trader, rail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
    }

    /// @dev owner funds `amount` of REAL USDC into the vault (deal + approve).
    function _fund(uint256 amount) internal {
        deal(USDC, owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    function test_fork_fund_credits_realUSDC() public {
        _fund(10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(vault.available(), 10_000e6);
    }

    function test_fork_roundTrip_profit_exactAccounting() public {
        _fund(10_000e6);

        // draw 3,000 to the rail
        vm.prank(trader);
        vault.drawForTrade(1, 3_000e6);
        assertEq(usdc.balanceOf(rail), 3_000e6);
        assertEq(vault.outstanding(), 3_000e6);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6);

        // rail "sells" at a profit: simulate 3,600 back at the rail, approve, return
        deal(USDC, rail, 3_600e6);
        vm.prank(rail);
        usdc.approve(address(vault), 3_600e6);
        vm.prank(trader);
        vault.returnProceeds(1, 3_600e6);

        // exposure cleared exactly; realized +600 stayed in the vault
        assertEq(vault.outstanding(), 0);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 3_600e6);

        // owner harvests all idle capital (owner-always-can-exit, live token)
        uint256 idle = vault.available();
        vm.prank(owner);
        vault.withdraw(idle);
        assertEq(usdc.balanceOf(owner), idle);
        assertEq(vault.available(), 0);
    }

    function test_fork_roundTrip_loss_exactAccounting() public {
        _fund(10_000e6);
        vm.prank(trader);
        vault.drawForTrade(2, 3_000e6);

        // rail sells at a loss: only 2,000 comes back
        deal(USDC, rail, 2_000e6);
        vm.prank(rail);
        usdc.approve(address(vault), 2_000e6);
        vm.prank(trader);
        vault.returnProceeds(2, 2_000e6);

        assertEq(vault.outstanding(), 0);                       // full draw cleared
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 2_000e6); // net −1k realized
    }

    function test_fork_dealCompatibleWithRealUSDC() public {
        // deal() must write the FiatTokenProxy balance slot correctly for the
        // above proofs to mean anything — assert it directly.
        deal(USDC, address(this), 123_456789);
        assertEq(usdc.balanceOf(address(this)), 123_456789);
    }
}
