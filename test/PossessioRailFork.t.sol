// SPDX-License-Identifier: MIT
// Fork certification for PossessioRail against REAL Base USDC + a REAL Uniswap V3
// pool. Proves the full money-path: draw from a real FundingVault → real swap
// USDC→token → (rule resolves) → real swap token→USDC → returnProceeds home →
// the Rail nets to zero. Uses the deep USDC/WETH 0.05% pool as the swap venue —
// the "token" is a stand-in; the point is real venues, not a mock.
//
// FIX B (council): with no RPC this suite SKIPS; it runs + passes LIVE.
//   BASE_RPC_URL="https://mainnet.base.org" forge test --match-contract PossessioRailForkTest -vvv
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";
import {MockAutoTarget} from "./PossessioRail.t.sol";

contract PossessioRailForkTest is Test {
    uint256 internal constant MIN_SETTLE_BPS = 0; // R-H1 floor OFF here: this suite proves pre-existing behaviour; the floor is proven in PossessioRailAdversarial
    // cast-verified Base mainnet
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006; // the swap "token"
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap V3 SwapRouter02
    uint24  constant FEE    = 500; // USDC/WETH 0.05% pool (deep)
    address constant REMOTE_AGENT = address(0xA6E47); // stand-in agent (dual-leg fork proof)

    MockAutoTarget at;
    PossessioFundingVault vault;
    PossessioRail rail;

    address owner  = makeAddr("owner");
    address keeper = makeAddr("keeper");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;

    bool forked;

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) { vm.createSelectFork(rpc); } catch {}
        forked = (block.chainid == 8453);
        if (!forked) { vm.skip(true); return; }

        at = new MockAutoTarget();
        uint256 n = vm.getNonce(address(this));
        address predictedRail = vm.computeCreateAddress(address(this), n + 1);
        vault = new PossessioFundingVault(IERC20(USDC), owner, predictedRail, predictedRail, MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP);
        rail  = new PossessioRail(IERC20(USDC), IFundingVault(address(vault)), IAutoTarget(address(at)), keeper, ISwapRouter(ROUTER), WETH, REMOTE_AGENT, 24 hours, MIN_SETTLE_BPS);
        vm.prank(owner); rail.setRouteAllowed(WETH, false, FEE, 0, true);   // R-H1 route whitelist
        require(address(rail) == predictedRail, "prewire");

        deal(USDC, owner, 10_000e6);
        vm.startPrank(owner); IERC20(USDC).approve(address(vault), 10_000e6); vault.fund(10_000e6); vm.stopPrank();
    }

    function test_fork_fullRoundTrip_realUSDC_realDEX() public {
        at.setIntent(1, WETH, 8453, 1); // authored, Open

        // ENTER — draw 1,000 USDC, real swap USDC→WETH
        vm.prank(keeper);
        rail.enter(1, WETH, 1_000e6, 1, false, FEE, 0); // loose minOut; deep pool

        (, uint256 usdcIn, uint256 wethAmt, PossessioRail.Status st) = rail.getPosition(1);
        assertEq(usdcIn, 1_000e6);
        assertGt(wethAmt, 0, "bought WETH");
        assertEq(uint8(st), uint8(PossessioRail.Status.Open));
        assertEq(vault.outstanding(), 1_000e6);
        assertEq(IERC20(WETH).balanceOf(address(rail)), wethAmt, "Rail holds the position");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 9_000e6);

        // RESOLVE (keeper authorized the exit) then EXIT — real swap WETH→USDC → home
        at.setStatus(1, 2);
        vm.prank(keeper);
        rail.exit(1, 1);

        assertEq(vault.outstanding(), 0, "exposure cleared");
        assertEq(IERC20(WETH).balanceOf(address(rail)), 0, "token sold");
        assertEq(IERC20(USDC).balanceOf(address(rail)), 0, "nothing stranded at the rail");
        // vault got the proceeds back (round-trip loses ~2x0.05% fee + slippage,
        // so it lands near — not above — 9,000 + ~1,000; just assert it grew back)
        uint256 vaultUsdc = IERC20(USDC).balanceOf(address(vault));
        assertGt(vaultUsdc, 9_000e6, "proceeds returned to the vault");
        (, , , PossessioRail.Status st2) = rail.getPosition(1);
        assertEq(uint8(st2), uint8(PossessioRail.Status.Closed));
    }

    function test_fork_ownerExit_realDEX() public {
        at.setIntent(2, WETH, 8453, 1); // Open, never resolved
        vm.prank(keeper);
        rail.enter(2, WETH, 1_000e6, 1, false, FEE, 0);
        // keeper never resolves — owner force-closes through the real DEX
        vm.prank(owner);
        rail.ownerExit(2, 1);
        assertEq(vault.outstanding(), 0);
        assertEq(IERC20(WETH).balanceOf(address(rail)), 0);
        assertGt(IERC20(USDC).balanceOf(address(vault)), 9_000e6);
    }
}
