// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
   FORK CERTIFICATION -- PossessioRail V2 against LIVE Base.

   This is the test the desk did not have, and its absence is why the
   broadcast was held: V1 could only reach a token through a DIRECT USDC
   pool, and real Base liquidity for new coins is overwhelmingly
   TOKEN/WETH. So the proof that matters is a round trip through a coin
   that has NO usable direct USDC pool -- bought and sold through the one
   permitted hop, on the real Uniswap V3 router, with real USDC.

   Coin under test: DEGEN (0x4ed4...efed), whose depth on Base is its
   DEGEN/WETH 1% pool. Under V1 this coin was untradeable by the desk.

   Also fork-proves the remote (Solana) leg's money path with real USDC:
   draw -> hand to agent -> agent returns a DIFFERENT amount -> settle
   credits the MEASURED figure.

   Runs only with a Base RPC (BASE_RPC_URL or --fork-url); skips otherwise.
//////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";
import {MockAutoTarget} from "./PossessioRail.t.sol";

interface IUSDCLike { function balanceOf(address) external view returns (uint256); }

contract PossessioRailV2ForkTest is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant DEGEN  = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed; // WETH-paired
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap V3 SwapRouter02

    uint24 constant FEE_USDC_WETH  = 500;   // deep USDC/WETH 0.05%
    uint24 constant FEE_WETH_DEGEN = 10000; // DEGEN/WETH 1%

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;
    uint256 constant REMOTE_TIMEOUT  = 24 hours;

    address owner       = makeAddr("owner");
    address keeper      = makeAddr("keeper");
    address remoteAgent = makeAddr("remoteAgent");

    PossessioFundingVault vault;
    PossessioRail rail;
    MockAutoTarget at;
    bool forked;

    function setUp() public {
        forked = (block.chainid == 8453);
        if (!forked) { vm.skip(true); return; }

        at = new MockAutoTarget();
        uint256 n = vm.getNonce(address(this));
        address predictedRail = vm.computeCreateAddress(address(this), n + 1);
        vault = new PossessioFundingVault(
            IERC20(USDC), owner, predictedRail, predictedRail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );
        rail = new PossessioRail(
            IERC20(USDC), IFundingVault(address(vault)), IAutoTarget(address(at)),
            keeper, ISwapRouter(ROUTER), WETH, remoteAgent, REMOTE_TIMEOUT
        );
        require(address(rail) == predictedRail, "prewire");

        deal(USDC, owner, 20_000e6);
        vm.startPrank(owner);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.fund(20_000e6);
        vm.stopPrank();
    }

    function _requireFork() internal view { require(forked, "fork only"); }

    /// THE PROOF THAT UNBLOCKS THE UNIVERSE: a real WETH-paired coin, bought and
    /// sold through the one permitted hop, on the live router.
    function test_fork_v2_multiHop_realWethPairedCoin_roundTrip() public {
        _requireFork();
        at.setIntent(1, DEGEN, 8453, 1); // authored, Open

        uint256 vaultStart = IERC20(USDC).balanceOf(address(vault));

        // ENTER: USDC -> WETH -> DEGEN, path assembled by the Rail
        vm.prank(keeper);
        rail.enter(1, DEGEN, 1_000e6, 1, true, FEE_USDC_WETH, FEE_WETH_DEGEN);

        (, uint256 usdcIn, uint256 got, PossessioRail.Status st) = rail.getPosition(1);
        assertEq(usdcIn, 1_000e6, "drew 1,000 real USDC");
        assertGt(got, 0, "bought real DEGEN through the WETH hop");
        assertEq(uint8(st), uint8(PossessioRail.Status.Open), "open");
        assertEq(IERC20(DEGEN).balanceOf(address(rail)), got, "rail holds the real position");
        assertEq(IERC20(USDC).balanceOf(address(rail)), 0, "no USDC dust left mid-position");
        emit log_named_uint("DEGEN bought for 1,000 USDC", got);

        // EXIT: the rule resolves, and the exit replays the route reversed
        at.setIntent(1, DEGEN, 8453, 2); // Resolved
        vm.prank(keeper);
        rail.exit(1, 1); // no route args: DEGEN -> WETH -> USDC

        uint256 vaultEnd = IERC20(USDC).balanceOf(address(vault));
        assertEq(IERC20(DEGEN).balanceOf(address(rail)), 0, "position fully sold");
        assertEq(IERC20(USDC).balanceOf(address(rail)), 0, "rail nets to zero");
        assertEq(vault.outstanding(), 0, "exposure cleared");
        assertGt(vaultEnd, vaultStart - 1_000e6, "proceeds came home");
        emit log_named_uint("USDC home after round trip", vaultEnd + 1_000e6 - vaultStart);

        // Round-trip cost is real slippage + two pool fees, not a contract bug:
        // assert it is within a sane band rather than pretending it is free.
        uint256 recovered = vaultEnd + 1_000e6 - vaultStart; // == usdcOut
        assertGt(recovered, 900e6, "round trip kept >90% (two hops, 1.05% in fees)");
        assertLt(recovered, 1_100e6, "and did not mint value");
    }

    /// A direct-route position still works on the live router (regression: the
    /// V1 shape must keep functioning inside V2).
    function test_fork_v2_directRoute_stillWorks_weth() public {
        _requireFork();
        at.setIntent(2, WETH, 8453, 1);

        vm.prank(keeper);
        rail.enter(2, WETH, 1_000e6, 1, false, FEE_USDC_WETH, 0);
        (, , uint256 got, ) = rail.getPosition(2);
        assertGt(got, 0, "bought WETH direct");

        at.setIntent(2, WETH, 8453, 2);
        vm.prank(keeper);
        rail.exit(2, 1);
        assertEq(IERC20(WETH).balanceOf(address(rail)), 0, "sold");
        assertEq(vault.outstanding(), 0, "cleared");
    }

    /// The remote leg's money path, with real USDC: the agent returns an amount
    /// nobody reported and the vault is credited with the MEASURED delta.
    function test_fork_v2_remoteLeg_settlesTheMeasuredAmount() public {
        _requireFork();
        at.setIntent(3, address(0), 101, 1); // Solana-tagged, Open

        vm.prank(keeper);
        rail.openRemoteLeg(3, 1_000e6);
        assertEq(IERC20(USDC).balanceOf(remoteAgent), 1_000e6, "real USDC handed to the agent");
        assertEq(vault.outstanding(), 1_000e6, "charged against the caps");

        // the off-chain leg made 4.2% and sends home a figure the Rail was never told
        deal(USDC, remoteAgent, 1_042e6);
        vm.prank(remoteAgent);
        IERC20(USDC).transfer(address(rail), 1_042e6);

        uint256 vaultBefore = IERC20(USDC).balanceOf(address(vault));
        vm.prank(keeper);
        rail.settleRemoteLeg(3);

        assertEq(IERC20(USDC).balanceOf(address(vault)) - vaultBefore, 1_042e6, "credited the measurement");
        assertEq(vault.outstanding(), 0, "exposure cleared");
        assertEq(IERC20(USDC).balanceOf(address(rail)), 0, "rail nets to zero");
    }
}
