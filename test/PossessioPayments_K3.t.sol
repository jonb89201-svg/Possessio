// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";
import {
    MockUSDC_G, MockDAI_G, MockCbETH_G, MockWETH_G, MockV3Router_G, MockAerodromeRouter_G,
    MockMorphoVault_G, MockChainlink_G, MockLSTRates_G
} from "./PossessioPayments_Gauntlet.t.sol";

/// K-3 (external review, KupiaSec 2026-10-15): PossessioFactory pins the template's
/// code but not the wiring in initArgs. On Base mainnet the template now accepts
/// only the canonical wiring, so the official factory cannot deploy, and announce,
/// an Account wired to a hostile router, vault or feed.
contract PossessioPaymentsK3 is Test {
    address constant HOSTILE = address(0xBAD);

    /// The canonical wiring is read from BaseWiring (review 2026-10-17, F-8), the
    /// same library the template pins on chainid 8453. This test proves the PIN
    /// (each field is checked, a hostile value is refused, the canonical set
    /// deploys); the independent check of the VALUES is test/PaymentsFork_t.sol,
    /// which deploys against the live Base contracts from its own constants.
    function _canonical() internal pure returns (PossessioPayments.DeployParams memory) {
        return PossessioPayments.DeployParams({
            owner:            address(0xA11CE),
            usdc:             BaseWiring.USDC,
            cbeth:            BaseWiring.CBETH,
            dai:              BaseWiring.DAI,
            weth:             BaseWiring.WETH,
            router:           BaseWiring.ROUTER,
            aeroRouter:       BaseWiring.AERO_ROUTER,
            morphoVault:      BaseWiring.MORPHO_VAULT,
            chainlink:        BaseWiring.CHAINLINK_CBETH,
            chainlinkDai:     BaseWiring.CHAINLINK_DAI,
            chainlinkUsdcUsd: BaseWiring.CHAINLINK_USDC,
            chainlinkEthUsd:  BaseWiring.CHAINLINK_ETH,
            lstRates:         BaseWiring.LST_RATES,
            minSwapBatch:     100 * 1e6,
            daiCeiling:       5_000 * 1e18,
            dailyLimit:       1_000 * 1e18,
            usdcDailyLimit:   1_000 * 1e6,
            cbEthDailyLimit:  1 ether
        });
    }

    function _refused(PossessioPayments.DeployParams memory p, address want) internal {
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NonCanonicalWiring.selector, HOSTILE, want));
        deployPayments(p);
    }

    /// Every one of the 12 wiring fields is pinned on Base, before any external call.
    function test_K3_onBase_everyWiringFieldIsPinned() public {
        vm.chainId(8453);
        PossessioPayments.DeployParams memory c = _canonical();
        PossessioPayments.DeployParams memory p;
        p = _canonical(); p.usdc             = HOSTILE; _refused(p, c.usdc);
        p = _canonical(); p.cbeth            = HOSTILE; _refused(p, c.cbeth);
        p = _canonical(); p.dai              = HOSTILE; _refused(p, c.dai);
        p = _canonical(); p.weth             = HOSTILE; _refused(p, c.weth);
        p = _canonical(); p.router           = HOSTILE; _refused(p, c.router);
        p = _canonical(); p.aeroRouter       = HOSTILE; _refused(p, c.aeroRouter);
        p = _canonical(); p.morphoVault      = HOSTILE; _refused(p, c.morphoVault);
        p = _canonical(); p.chainlink        = HOSTILE; _refused(p, c.chainlink);
        p = _canonical(); p.chainlinkDai     = HOSTILE; _refused(p, c.chainlinkDai);
        p = _canonical(); p.chainlinkUsdcUsd = HOSTILE; _refused(p, c.chainlinkUsdcUsd);
        p = _canonical(); p.chainlinkEthUsd  = HOSTILE; _refused(p, c.chainlinkEthUsd);
        p = _canonical(); p.lstRates         = HOSTILE; _refused(p, c.lstRates);
    }

    /// The canonical wiring passes the pin (feed decimals mocked; the Base-fork
    /// suite deploys the same set against the live contracts).
    function test_K3_onBase_canonicalWiringDeploys() public {
        vm.chainId(8453);
        PossessioPayments.DeployParams memory c = _canonical();
        bytes memory dec = abi.encodeWithSelector(IChainlinkFeed.decimals.selector);
        vm.mockCall(c.chainlink,        dec, abi.encode(uint8(18)));
        vm.mockCall(c.chainlinkDai,     dec, abi.encode(uint8(8)));
        vm.mockCall(c.chainlinkUsdcUsd, dec, abi.encode(uint8(8)));
        vm.mockCall(c.chainlinkEthUsd,  dec, abi.encode(uint8(8)));
        PossessioPayments payments = deployPayments(c);
        assertEq(address(payments.ROUTER()), c.router);
        assertEq(address(payments.MORPHO_VAULT()), c.morphoVault);
        assertEq(address(payments.LST_RATES()), c.lstRates);
    }

    /// Off Base (tests, testnets) any non-zero wiring still deploys.
    function test_K3_offBase_mockWiringStillDeploys() public {
        assertTrue(block.chainid != 8453);
        MockUSDC_G usdc = new MockUSDC_G();
        MockDAI_G dai = new MockDAI_G();
        MockCbETH_G cbeth = new MockCbETH_G();
        MockWETH_G weth = new MockWETH_G();
        PossessioPayments.DeployParams memory p = _canonical();
        p.usdc             = address(usdc);
        p.cbeth            = address(cbeth);
        p.dai              = address(dai);
        p.weth             = address(weth);
        p.router           = address(new MockV3Router_G(address(usdc), address(dai), address(cbeth)));
        p.aeroRouter       = address(new MockAerodromeRouter_G(address(weth), address(cbeth)));
        p.morphoVault      = address(new MockMorphoVault_G(address(usdc)));
        p.chainlink        = address(new MockChainlink_G(int256(980_000_000_000_000_000), 18));
        p.chainlinkDai     = address(new MockChainlink_G(int256(500_000_000_000), 8));
        p.chainlinkUsdcUsd = address(new MockChainlink_G(int256(100_000_000), 8));
        p.chainlinkEthUsd  = address(new MockChainlink_G(int256(300_000_000_000), 8));
        p.lstRates         = address(new MockLSTRates_G());
        PossessioPayments payments = deployPayments(p);
        assertEq(address(payments.ROUTER()), p.router);
    }
}
