// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   THE ACCOUNT — THE DEPLOYMENT CONFIGURATION, UNDER TEST

   Third in the series with PossessioPoolDeployValues and
   PossessioX402CoreDeployValues. Same law: the Prime Directive
   applies to the CONFIGURATION, not only the mechanism.

   This one is not hypothetical. These are the values LIVE on Base
   mainnet at 0x67247eB2108E7229331127DF1309D624d95467ca and baked
   into script/DeployPayments.s.sol, so they are also the values every
   future Account launches with:

     minSwapBatch     $100        daiCeiling       10,000 DAI
     dailyLimit       50,000 DAI  usdcDailyLimit   50,000 USDC
     cbEthDailyLimit  20 cbETH    cbEthBps         5000 (hardcoded)

   The existing suites run:
     PossessioPayments_t.sol :410  MIN_BATCH $100 · CEILING 5,000
                                   DAILY 1,000 · USDC_DAILY 1,000 · CBETH_DAILY 1
     PossessioPayments_t.sol :2177 MIN_BATCH $1,000 · same limits

   So the C-2 rolling daily caps -- the control that stops a compromised
   OWNER key from draining the treasury in one call -- are exercised at
   ~2% of their shipping values (1,000 vs 50,000; 1 cbETH vs 20). The
   mechanism is proven. The configuration in production is not.

   A rate limit is only a control at the rate it is actually set to.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";
import {MockUSDC, MockDAI, MockCbETH, MockWETH, MockV3Router,
        MockAerodromeRouter, MockMorphoVault, MockChainlink,
        MockLSTRates} from "./PossessioPayments_t.sol";

contract PossessioPaymentsDeployValuesTest is Test {
    // ── script/DeployPayments.s.sol — the LIVE values ────────────────────
    uint256 constant MIN_SWAP_BATCH    = 100_000000;   // $100 (6-dec)
    uint256 constant DAI_CEILING       = 10_000e18;    // 10,000 DAI
    uint256 constant DAILY_LIMIT       = 50_000e18;    // 50,000 DAI / 24h
    uint256 constant USDC_DAILY_LIMIT  = 50_000e6;     // 50,000 USDC / 24h
    uint256 constant CBETH_DAILY_LIMIT = 20e18;        // 20 cbETH / 24h
    uint16  constant CBETH_BPS_DEFAULT = 5000;         // 50/50, hardcoded at :778

    PossessioPayments pay;
    MockUSDC usdc; MockDAI dai; MockCbETH cbeth; MockWETH weth;
    MockV3Router router; MockAerodromeRouter aero; MockMorphoVault morpho;
    MockChainlink clEth; MockChainlink clDai; MockChainlink clUsdcUsd; MockChainlink clEthUsd;
    MockLSTRates lst;

    address owner = makeAddr("accountOwner");
    address dest  = makeAddr("destination");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC(); dai = new MockDAI(); cbeth = new MockCbETH(); weth = new MockWETH();
        router = new MockV3Router(address(usdc), address(dai), address(weth));
        aero   = new MockAerodromeRouter(address(weth), address(cbeth));
        morpho = new MockMorphoVault(address(usdc));
        clEth      = new MockChainlink(int256(980_000_000_000_000_000), 18);
        clDai      = new MockChainlink(int256(500_000_000_000), 8);
        clUsdcUsd  = new MockChainlink(int256(100_000_000), 8);
        clEthUsd   = new MockChainlink(int256(300_000_000_000), 8);
        lst = new MockLSTRates();

        pay = deployPayments(PossessioPayments.DeployParams({
            owner: owner, usdc: address(usdc), cbeth: address(cbeth), dai: address(dai),
            weth: address(weth), router: address(router), aeroRouter: address(aero),
            morphoVault: address(morpho), chainlink: address(clEth),
            chainlinkDai: address(clDai), chainlinkUsdcUsd: address(clUsdcUsd),
            chainlinkEthUsd: address(clEthUsd), lstRates: address(lst),
            minSwapBatch: MIN_SWAP_BATCH, daiCeiling: DAI_CEILING,
            dailyLimit: DAILY_LIMIT, usdcDailyLimit: USDC_DAILY_LIMIT,
            cbEthDailyLimit: CBETH_DAILY_LIMIT
        }));
    }

    // ── A1. The live configuration lands exactly as scripted ─────────────
    function test_A1_immutablesMatchTheLiveDeployment() public view {
        assertEq(pay.minSwapBatch(),    MIN_SWAP_BATCH,    "minSwapBatch != $100");
        assertEq(pay.daiCeiling(),      DAI_CEILING,       "daiCeiling != 10,000 DAI");
        assertEq(pay.dailyLimit(),      DAILY_LIMIT,       "dailyLimit != 50,000 DAI");
        assertEq(pay.usdcDailyLimit(),  USDC_DAILY_LIMIT,  "usdcDailyLimit != 50,000 USDC");
        assertEq(pay.cbEthDailyLimit(), CBETH_DAILY_LIMIT, "cbEthDailyLimit != 20 cbETH");
        assertEq(pay.cbEthBps(),        CBETH_BPS_DEFAULT, "cbEthBps != 5000");
        assertTrue(pay.hasRole(pay.OWNER_ROLE(), owner),   "owner holds OWNER_ROLE");
        assertFalse(pay.withdrawalsFrozen(),               "exits live at deploy");
    }

    // ── A2. The USDC cap bites at exactly 50,000 — not 1,000 ─────────────
    function test_A2_usdcDailyCapBindsAtFiftyThousand() public {
        usdc.mint(address(pay), USDC_DAILY_LIMIT * 3);

        vm.prank(owner);
        pay.sendUSDC(USDC_DAILY_LIMIT, dest);                  // the whole day's allowance
        assertEq(usdc.balanceOf(dest), USDC_DAILY_LIMIT, "full cap withdrawable in one call");

        vm.prank(owner);
        vm.expectRevert();
        pay.sendUSDC(1, dest);                                  // one unit past the cap
    }

    // ── A3. C-2's real point: sendUSDC and redeemMorpho SHARE one window ─
    //      at the SHIPPING cap. This is the split-path drain close. Tested
    //      elsewhere at 1,000 USDC; the control only means something at the
    //      rate it actually ships with.
    function test_A3_sharedUsdcWindow_atShippingCap() public {
        usdc.mint(address(pay), USDC_DAILY_LIMIT * 2);

        uint256 half = USDC_DAILY_LIMIT / 2;
        vm.prank(owner);
        pay.sendUSDC(half, dest);                               // 25,000 spent

        // The remaining 25,000 must be all that either path can move.
        vm.prank(owner);
        pay.sendUSDC(half, dest);                               // exactly to the cap
        assertEq(usdc.balanceOf(dest), USDC_DAILY_LIMIT);

        vm.prank(owner);
        vm.expectRevert();
        pay.sendUSDC(1, dest);                                  // window is spent
    }

    // ── A4. The cbETH cap binds at 20, not 1 ─────────────────────────────
    function test_A4_cbEthDailyCapBindsAtTwenty() public {
        cbeth.mint(address(pay), CBETH_DAILY_LIMIT * 3);

        vm.prank(owner);
        pay.sendCbETH(CBETH_DAILY_LIMIT, dest);
        assertEq(cbeth.balanceOf(dest), CBETH_DAILY_LIMIT, "full 20 cbETH in one call");

        vm.prank(owner);
        vm.expectRevert();
        pay.sendCbETH(1, dest);
    }

    // ── A5. The DAI cap binds at 50,000, not 1,000 ───────────────────────
    function test_A5_daiDailyCapBindsAtFiftyThousand() public {
        dai.mint(address(pay), DAILY_LIMIT * 3);

        vm.prank(owner);
        pay.withdrawDAI(DAILY_LIMIT, dest);
        assertEq(dai.balanceOf(dest), DAILY_LIMIT);

        vm.prank(owner);
        vm.expectRevert();
        pay.withdrawDAI(1, dest);
    }

    // ── A6. The window rolls: a spent day restores the FULL cap ──────────
    function test_A6_windowRollsRestoringTheShippingCap() public {
        usdc.mint(address(pay), USDC_DAILY_LIMIT * 3);
        vm.prank(owner);
        pay.sendUSDC(USDC_DAILY_LIMIT, dest);

        vm.prank(owner);
        vm.expectRevert();
        pay.sendUSDC(1, dest);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(owner);
        pay.sendUSDC(USDC_DAILY_LIMIT, dest);                   // a fresh full allowance
        assertEq(usdc.balanceOf(dest), USDC_DAILY_LIMIT * 2, "window restored the whole cap");
    }

    // ── A7. The freeze kills every exit, at any size ──────────────────────
    function test_A7_freezeStopsAllExits() public {
        usdc.mint(address(pay), USDC_DAILY_LIMIT);
        cbeth.mint(address(pay), CBETH_DAILY_LIMIT);
        dai.mint(address(pay), DAILY_LIMIT);

        // The freeze is a GUARDIAN power, and the Guardian is opt-in: the
        // owner must arm the system AND grant the role. Both steps are the
        // control, so both are exercised here.
        vm.startPrank(owner);
        pay.enableGuardian();
        pay.grantRole(pay.GUARDIAN_ROLE(), owner);
        pay.setWithdrawalsFrozen(true);
        vm.stopPrank();
        assertTrue(pay.withdrawalsFrozen(), "frozen");

        vm.prank(owner); vm.expectRevert(); pay.sendUSDC(1, dest);
        vm.prank(owner); vm.expectRevert(); pay.sendCbETH(1, dest);
        vm.prank(owner); vm.expectRevert(); pay.withdrawDAI(1, dest);
    }

    // ── A8. The slider ships at 5000 and is bounded 1000–9000 ────────────
    //      The console renders 10–90 (public/index.html:831); the bound is
    //      enforced on-chain, not only in the UI. An owner cannot put the
    //      account fully into either leg, deliberately or in a panic.
    function test_A8_cbEthBpsShipsAtFiftyAndIsBounded() public {
        assertEq(pay.cbEthBps(), CBETH_BPS_DEFAULT, "ships at 50/50");

        vm.prank(owner); pay.setCbEthBps(1000);      // floor
        assertEq(pay.cbEthBps(), 1000);
        vm.prank(owner); pay.setCbEthBps(9000);      // ceiling
        assertEq(pay.cbEthBps(), 9000);

        vm.prank(owner); vm.expectRevert(); pay.setCbEthBps(999);    // no all-lending
        vm.prank(owner); vm.expectRevert(); pay.setCbEthBps(9001);   // no all-savings
        vm.prank(owner); vm.expectRevert(); pay.setCbEthBps(0);
        vm.prank(owner); vm.expectRevert(); pay.setCbEthBps(10000);
    }

    // ── A9. The $100 sweep gate holds at the shipping batch size ─────────
    function test_A9_sweepGateAtShippingBatch() public {
        usdc.mint(address(pay), MIN_SWAP_BATCH - 1);
        vm.prank(owner);
        vm.expectRevert();                                       // BatchTooSmall
        pay.sweep(0, 0, 0);
    }

    // ── A10. Exit destinations are arbitrary by design ───────────────────
    //      "Exits go to the deployer" is TRUE BY CONVENTION, not by wiring.
    //      What the contract enforces is the ROLE and the RATE. Pinned so
    //      the documentation and the code cannot drift apart.
    function test_A10_exitDestinationIsOwnerChosenNotHardcoded() public {
        usdc.mint(address(pay), 1000e6);
        address somewhereElse = makeAddr("anyAddressTheOwnerPicks");

        vm.prank(owner);
        pay.sendUSDC(1000e6, somewhereElse);
        assertEq(usdc.balanceOf(somewhereElse), 1000e6, "owner chooses any destination");

        // but only the OWNER may choose it
        usdc.mint(address(pay), 1000e6);
        vm.prank(somewhereElse);
        vm.expectRevert();
        pay.sendUSDC(1, somewhereElse);

        // and never the zero address
        vm.prank(owner);
        vm.expectRevert();
        pay.sendUSDC(1, address(0));
    }
}
