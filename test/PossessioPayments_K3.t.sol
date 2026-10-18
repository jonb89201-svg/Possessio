// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";
import {MockUSDC_V3, MockCbETH_V3, MockFeed_V3, MockLST_V3, MockVault_V3} from "./v3/PaymentsV3Mocks.sol";

/// K-3 (external review, KupiaSec 2026-10-15): PossessioFactory pins the template's
/// code but not the wiring in initArgs. On Base mainnet the template accepts only
/// the canonical wiring, so the official factory cannot deploy, and announce, an
/// Account wired to a hostile vault or feed. v3.0: seven addresses (the routers,
/// WETH and DAI left with the swap sweep); v3.0.1: eight, with the sequencer
/// uptime feed (cold-seat audit 2026-10-18, G-1).
contract PossessioPaymentsK3 is Test {
    address constant HOSTILE = address(0xBAD);

    /// The canonical wiring is read from BaseWiring (review 2026-10-17, F-8), the
    /// same library the template pins on chainid 8453. This test proves the PIN
    /// (each field is checked, a hostile value is refused, the canonical set
    /// deploys); the independent check of the VALUES is test/PaymentsFork_t.sol,
    /// which deploys against the live Base contracts from its own constants.
    function _canonical() internal pure returns (PossessioPayments.DeployParams memory) {
        address[] memory payees = new address[](1);
        payees[0] = address(0xA11CE);
        return PossessioPayments.DeployParams({
            owner:            address(0xA11CE),
            usdc:             BaseWiring.USDC,
            cbeth:            BaseWiring.CBETH,
            morphoVault:      BaseWiring.MORPHO_VAULT,
            chainlink:        BaseWiring.CHAINLINK_CBETH,
            chainlinkUsdcUsd: BaseWiring.CHAINLINK_USDC,
            chainlinkEthUsd:  BaseWiring.CHAINLINK_ETH,
            sequencerUptime:  BaseWiring.CHAINLINK_SEQUENCER,
            lstRates:         BaseWiring.LST_RATES,
            minSwapBatch:     100 * 1e6,
            usdcFloat:        1_000 * 1e6,
            maxKickUsdc:      0,
            usdcDailyLimit:   1_000 * 1e6,
            cbEthDailyLimit:  1 ether,
            payees:           payees
        });
    }

    function _refused(PossessioPayments.DeployParams memory p, address want) internal {
        vm.expectRevert(abi.encodeWithSelector(PossessioPayments.NonCanonicalWiring.selector, HOSTILE, want));
        deployPayments(p);
    }

    /// Every one of the 8 wiring fields is pinned on Base, before any external call.
    function test_K3_onBase_everyWiringFieldIsPinned() public {
        vm.chainId(8453);
        PossessioPayments.DeployParams memory c = _canonical();
        PossessioPayments.DeployParams memory p;
        p = _canonical(); p.usdc             = HOSTILE; _refused(p, c.usdc);
        p = _canonical(); p.cbeth            = HOSTILE; _refused(p, c.cbeth);
        p = _canonical(); p.morphoVault      = HOSTILE; _refused(p, c.morphoVault);
        p = _canonical(); p.chainlink        = HOSTILE; _refused(p, c.chainlink);
        p = _canonical(); p.chainlinkUsdcUsd = HOSTILE; _refused(p, c.chainlinkUsdcUsd);
        p = _canonical(); p.chainlinkEthUsd  = HOSTILE; _refused(p, c.chainlinkEthUsd);
        p = _canonical(); p.sequencerUptime  = HOSTILE; _refused(p, c.sequencerUptime);
        p = _canonical(); p.lstRates         = HOSTILE; _refused(p, c.lstRates);
    }

    /// The canonical wiring passes the pin (feed decimals mocked; the Base-fork
    /// suite deploys the same set against the live contracts).
    function test_K3_onBase_canonicalWiringDeploys() public {
        vm.chainId(8453);
        PossessioPayments.DeployParams memory c = _canonical();
        bytes memory dec = abi.encodeWithSelector(IChainlinkFeed.decimals.selector);
        vm.mockCall(c.chainlink,        dec, abi.encode(uint8(18)));
        vm.mockCall(c.chainlinkUsdcUsd, dec, abi.encode(uint8(8)));
        vm.mockCall(c.chainlinkEthUsd,  dec, abi.encode(uint8(8)));
        vm.mockCall(c.sequencerUptime,  dec, abi.encode(uint8(0)));
        PossessioPayments payments = deployPayments(c);
        assertEq(address(payments.MORPHO_VAULT()), c.morphoVault);
        assertEq(address(payments.SEQUENCER_UPTIME()), c.sequencerUptime);
        assertEq(address(payments.LST_RATES()), c.lstRates);
        assertEq(address(payments.CHAINLINK_ETH_USD()), c.chainlinkEthUsd);
    }

    /// Off Base (tests, testnets) any non-zero wiring still deploys.
    function test_K3_offBase_mockWiringStillDeploys() public {
        assertTrue(block.chainid != 8453);
        MockUSDC_V3 usdc = new MockUSDC_V3();
        PossessioPayments.DeployParams memory p = _canonical();
        p.usdc             = address(usdc);
        p.cbeth            = address(new MockCbETH_V3());
        p.morphoVault      = address(new MockVault_V3(address(usdc)));
        p.chainlink        = address(new MockFeed_V3(int256(980_000_000_000_000_000), 18));
        p.chainlinkUsdcUsd = address(new MockFeed_V3(int256(100_000_000), 8));
        p.chainlinkEthUsd  = address(new MockFeed_V3(int256(300_000_000_000), 8));
        p.sequencerUptime  = address(new MockFeed_V3(0, 0));
        p.lstRates         = address(new MockLST_V3());
        PossessioPayments payments = deployPayments(p);
        assertEq(address(payments.MORPHO_VAULT()), p.morphoVault);
    }
}
