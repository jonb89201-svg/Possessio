// SPDX-License-Identifier: MIT
// Certification fork test for PossessioPayments v3.0 (the auction sweep). Forks
// Base mainnet, where every venue the contract uses is live (3 Chainlink feeds,
// the Morpho vault, cbETH, USDC, the certified LSTExchangeRate), and deploys
// Payments against the REAL contracts. The constructor validates the 3 feed
// classes, so a clean deploy here proves the wiring is correct on mainnet.
//
// Then it measures the auction against the live market (SPEC §8.3): a kick
// depositing into the live Morpho vault, a take at par by a taker that holds
// cbETH, and the reference taker that sources cbETH on Uniswap V3 and
// Aerodrome inside the callback, scanned along the curve to find the first
// profitable moment for lots from $50 to $100k.
//
// RUN (just this):
//   BASE_RPC_URL="https://mainnet.base.org" forge test --match-contract PaymentsForkTest -vv
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
interface IVaultF {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function balanceOf(address) external view returns (uint256);
}
interface ILST { function cbEthToEth(uint256) external view returns (uint256); }
interface IFeedF { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// Uniswap V3 SwapRouter02 (no deadline field).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}
/// Aerodrome Slipstream router (tickSpacing, deadline).
interface IAeroRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; int24 tickSpacing; address recipient; uint256 deadline;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// The reference taker (SPEC §7): receives the lot, buys cbETH on the live
/// venues, delivers what is required, keeps the rest. Reverts if the market
/// does not cover the curve, which is the honest "not yet".
contract ForkTaker {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant CBETH  = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    ISwapRouter02 constant ROUTER = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);
    IAeroRouter   constant AERO   = IAeroRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    uint256 public lastSurplus;   // cbETH kept after delivering, in wei

    function possessioTake(uint256 usdcOut, uint256 cbEthRequired, bytes calldata) external {
        IERC20F(USDC).approve(address(ROUTER), usdcOut);
        uint256 wethOut = ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams({
            tokenIn: USDC, tokenOut: WETH, fee: 500, recipient: address(this),
            amountIn: usdcOut, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        IERC20F(WETH).approve(address(AERO), wethOut);
        uint256 cbOut = AERO.exactInputSingle(IAeroRouter.ExactInputSingleParams({
            tokenIn: WETH, tokenOut: CBETH, tickSpacing: 1, recipient: address(this), deadline: block.timestamp,
            amountIn: wethOut, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        require(cbOut >= cbEthRequired, "market below the curve");
        lastSurplus = cbOut - cbEthRequired;
        IERC20F(CBETH).transfer(msg.sender, cbEthRequired);
    }
    function go(address payments) external { PossessioPayments(payments).takeWithCallback(""); }
}

contract PaymentsForkTest is Test {
    PossessioPayments payments;

    // ---- cast-verified Base mainnet addresses (kept here on purpose, as the
    //      independent check of BaseWiring) ----
    address constant OWNER           = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;
    address constant USDC            = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBETH           = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant MORPHO_VAULT    = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address constant CHAINLINK_CBETH = 0x806b4Ac04501c29769051e42783cF04dCE41440b; // cbETH/ETH 18-dec
    address constant CHAINLINK_USDC  = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD 8-dec
    address constant CHAINLINK_ETH   = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD 8-dec
    address constant LST_RATES       = 0xDDb75e974d99FcF95E241adbFD376861c47a8548; // deployed + certified

    uint256 constant MIN_SWAP_BATCH    = 100_000000;   // 100 USDC
    uint256 constant USDC_FLOAT        = 10000e6;      // 10,000 USDC kept liquid
    uint256 constant USDC_DAILY_LIMIT  = 50000e6;
    uint256 constant CBETH_DAILY_LIMIT = 20e18;
    address constant NOBODY = address(0xBAD);

    bool forked;

    function _params(uint256 usdcFloat) internal pure returns (PossessioPayments.DeployParams memory) {
        address[] memory payees = new address[](1);
        payees[0] = OWNER;
        return PossessioPayments.DeployParams({
            owner: OWNER, usdc: USDC, cbeth: CBETH, morphoVault: MORPHO_VAULT,
            chainlink: CHAINLINK_CBETH, chainlinkUsdcUsd: CHAINLINK_USDC, chainlinkEthUsd: CHAINLINK_ETH,
            lstRates: LST_RATES, minSwapBatch: MIN_SWAP_BATCH, usdcFloat: usdcFloat, maxKickUsdc: 0,
            usdcDailyLimit: USDC_DAILY_LIMIT, cbEthDailyLimit: CBETH_DAILY_LIMIT, payees: payees
        });
    }

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        if (forked) payments = deployPayments(_params(USDC_FLOAT));
    }

    // ── wiring ────────────────────────────────────────────────────────────

    /// K-3: on Base the template refuses non-canonical wiring; setUp is the
    /// positive half (the canonical set deploys against the live contracts).
    function test_fork_K3_hostileVaultRefused() public {
        if (!forked) { vm.skip(true); return; }
        PossessioPayments.DeployParams memory p = _params(USDC_FLOAT);
        p.morphoVault = NOBODY;
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NonCanonicalWiring.selector, NOBODY, MORPHO_VAULT));
        deployPayments(p);
    }

    function test_deploys_against_real_mainnet_venues() public {
        if (!forked) { vm.skip(true); return; }
        assertTrue(address(payments) != address(0), "Payments did not deploy");
        assertEq(payments.minSwapBatch(), MIN_SWAP_BATCH);
        assertEq(payments.usdcFloat(), USDC_FLOAT);
        assertEq(payments.usdcDailyLimit(), USDC_DAILY_LIMIT);
        assertEq(payments.cbEthDailyLimit(), CBETH_DAILY_LIMIT);
        assertTrue(payments.isPayee(OWNER));
        console2.log("Payments deployed at:", address(payments));
    }

    function test_lstRates_wired_and_values_cbeth() public {
        if (!forked) { vm.skip(true); return; }
        uint256 oneCbEth = ILST(LST_RATES).cbEthToEth(1e18);
        assertGt(oneCbEth, 1.0e18, "cbETH valued below 1 ETH");
        assertLt(oneCbEth, 1.30e18, "cbETH valued absurdly");
        console2.log("lstRates cbEthToEth(1e18) =", oneCbEth);
    }

    // ── exits against the real tokens ─────────────────────────────────────

    function test_fork_sendUSDC_rules() public {
        if (!forked) { vm.skip(true); return; }
        deal(USDC, address(payments), 500_000000);
        uint256 before = IERC20F(USDC).balanceOf(OWNER);
        vm.prank(NOBODY);
        vm.expectRevert();
        payments.sendUSDC(100_000000, NOBODY);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, NOBODY));
        payments.sendUSDC(100_000000, NOBODY);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        payments.sendUSDC(0, OWNER);
        vm.prank(OWNER);
        payments.sendUSDC(500_000000, OWNER);
        assertEq(IERC20F(USDC).balanceOf(OWNER), before + 500_000000, "USDC not received");
    }

    function test_fork_sendCbETH_rules() public {
        if (!forked) { vm.skip(true); return; }
        deal(CBETH, address(payments), 2 ether);
        uint256 before = IERC20F(CBETH).balanceOf(OWNER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, NOBODY));
        payments.sendCbETH(1 ether, NOBODY);
        vm.prank(OWNER);
        payments.sendCbETH(2 ether, OWNER);
        assertEq(IERC20F(CBETH).balanceOf(OWNER), before + 2 ether, "cbETH not received");
    }

    function _seedMorphoShares(uint256 usdcAmount) internal returns (uint256 shares) {
        deal(USDC, address(payments), usdcAmount);
        vm.startPrank(address(payments));
        IERC20F(USDC).approve(MORPHO_VAULT, usdcAmount);
        shares = IVaultF(MORPHO_VAULT).deposit(usdcAmount, address(payments));
        vm.stopPrank();
    }

    function test_fork_redeemMorpho_rules() public {
        if (!forked) { vm.skip(true); return; }
        uint256 shares = _seedMorphoShares(300_000000);
        assertGt(shares, 0, "no shares seeded");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NotAPayee.selector, NOBODY));
        payments.redeemMorpho(shares, NOBODY);
        vm.prank(OWNER);
        vm.expectRevert(PossessioPayments.ZeroAmount.selector);
        payments.redeemMorpho(0, OWNER);
        uint256 before = IERC20F(USDC).balanceOf(OWNER);
        vm.prank(OWNER);
        uint256 out = payments.redeemMorpho(shares, OWNER);
        assertGt(out, 0, "no USDC out");
        assertEq(IERC20F(USDC).balanceOf(OWNER), before + out, "USDC not received by owner");
    }

    // ── the auction against the live market ───────────────────────────────

    /// The oracle amount for `usdc`, computed from the live feeds the way the
    /// contract does, for the logs.
    function _oracleCbEth(uint256 usdc) internal view returns (uint256) {
        (, int256 usdcUsd,,,) = IFeedF(CHAINLINK_USDC).latestRoundData();
        (, int256 ethUsd,,,)  = IFeedF(CHAINLINK_ETH).latestRoundData();
        (, int256 cbPerEth,,,) = IFeedF(CHAINLINK_CBETH).latestRoundData();
        uint256 ethWei = (usdc * 1e12 * uint256(usdcUsd)) / uint256(ethUsd);
        return (ethWei * 1e18) / uint256(cbPerEth);
    }

    function test_fork_kick_depositsIntoLiveMorphoAndOpensALot() public {
        if (!forked) { vm.skip(true); return; }
        deal(USDC, address(payments), USDC_FLOAT + 2_000e6);
        assertTrue(payments.canKick(), "feeds fresh at the fork block");
        uint256 g = gasleft();
        payments.kick();
        g = g - gasleft();
        (uint128 lotUsdc, uint64 startedAt, uint64 endsAt) = payments.lot();
        assertEq(uint256(lotUsdc), 1_000e6, "half the kick is the lot");
        assertEq(uint256(endsAt - startedAt), 30 minutes);
        assertGt(IVaultF(MORPHO_VAULT).balanceOf(address(payments)), 0, "live Morpho shares");
        assertEq(payments.morphoDepositedPrincipal(), 1_000e6);
        assertEq(IERC20F(USDC).balanceOf(address(payments)), USDC_FLOAT + 1_000e6, "float plus the lot");
        console2.log("MEASURED kick gas:", g);
        console2.log("MEASURED oracle cbETH for the $1,000 lot (wei):", _oracleCbEth(1_000e6));
    }

    function test_fork_take_atPar_byATakerHoldingCbEth() public {
        if (!forked) { vm.skip(true); return; }
        deal(USDC, address(payments), USDC_FLOAT + 2_000e6);
        payments.kick();
        (, uint64 startedAt,) = payments.lot();
        vm.warp(uint256(startedAt) + 810);                  // par
        uint256 required = payments.currentRequired();
        assertEq(required, _oracleCbEth(1_000e6), "par is the oracle amount");
        address taker = makeAddr("taker");
        deal(CBETH, taker, required);
        vm.startPrank(taker);
        IERC20F(CBETH).approve(address(payments), required);
        uint256 g = gasleft();
        payments.take();
        g = g - gasleft();
        vm.stopPrank();
        assertEq(IERC20F(USDC).balanceOf(taker), 1_000e6, "the lot");
        assertEq(IERC20F(CBETH).balanceOf(address(payments)), required, "the cbETH");
        console2.log("MEASURED take gas:", g);
        console2.log("MEASURED required at par (wei):", required);
    }

    /// The measurement (SPEC §8.3): for lots from $50 to $100k, the reference
    /// taker sourcing cbETH on Uniswap V3 and Aerodrome is tried every 30 s
    /// from the par point on; the first success is the first moment the live
    /// market covers the curve. Logged as the multiplier (1e18 = oracle) and
    /// the taker's surplus.
    function test_fork_referenceTaker_firstProfitableMoment() public {
        if (!forked) { vm.skip(true); return; }
        uint256[5] memory lots = [uint256(50e6), 500e6, 5_000e6, 50_000e6, 100_000e6];
        uint256 forkTime = vm.getBlockTimestamp();
        for (uint256 i = 0; i < lots.length; i++) {
            vm.warp(forkTime);                           // a static fork: rewind so the feeds stay within their windows
            PossessioPayments p = deployPayments(_params(0));
            vm.prank(OWNER);
            p.setMinSwapBatch(1);
            deal(USDC, address(p), lots[i] * 2);          // half goes to Morpho, half is the lot
            p.kick();
            (uint128 lotUsdc, uint64 startedAt,) = p.lot();
            assertEq(uint256(lotUsdc), lots[i]);
            ForkTaker taker = new ForkTaker();
            bool filled; uint256 tFill; uint256 mFill; uint256 reqFill;
            for (uint256 t = 810; t < 1800; t += 30) {
                vm.warp(uint256(startedAt) + t);
                uint256 m = p.currentMultiplier();
                uint256 req = p.currentRequired();
                (bool ok,) = address(taker).call(abi.encodeWithSelector(ForkTaker.go.selector, address(p)));
                if (ok) { filled = true; tFill = t; mFill = m; reqFill = req; break; }
            }
            console2.log("---- lot (USDC, 6-dec):", lots[i]);
            if (filled) {
                console2.log("  MEASURED first fill at t (s):", tFill);
                console2.log("  MEASURED multiplier at fill (1e18 = oracle):", mFill);
                console2.log("  MEASURED cbETH delivered (wei):", reqFill);
                console2.log("  MEASURED taker surplus (wei):", taker.lastSurplus());
                assertEq(IERC20F(USDC).balanceOf(address(taker)), 0, "the taker spent the lot on cbETH");
                assertEq(IERC20F(CBETH).balanceOf(address(p)), reqFill, "delivered");
            } else {
                console2.log("  MEASURED: no fill down to the floor (market more than 1% above the oracle, or venue too thin)");
            }
        }
    }
}
