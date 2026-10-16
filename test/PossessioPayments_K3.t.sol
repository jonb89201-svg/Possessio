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

    function _canonical() internal pure returns (PossessioPayments.DeployParams memory) {
        return PossessioPayments.DeployParams({
            owner:            address(0xA11CE),
            usdc:             0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            cbeth:            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22,
            dai:              0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb,
            weth:             0x4200000000000000000000000000000000000006,
            router:           0x2626664c2603336E57B271c5C0b26F421741e481,
            aeroRouter:       0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5,
            morphoVault:      0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100,
            chainlink:        0x806b4Ac04501c29769051e42783cF04dCE41440b,
            chainlinkDai:     0x591e79239a7d679378eC8c847e5038150364C78F,
            chainlinkUsdcUsd: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B,
            chainlinkEthUsd:  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            lstRates:         0xDDb75e974d99FcF95E241adbFD376861c47a8548,
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
