// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {L1Anchor} from "../src/L1Anchor.sol";
import {L1AnchorFactory} from "../src/L1AnchorFactory.sol";
import {
    MockERC20,
    MockMAVANEntry,
    MockMorphoVault,
    MockChainlinkFeed
} from "./L1AnchorMocks.sol";

/**
 * @title L1AnchorFactory Test Suite
 * @notice Tests for the Factory contract specifically — distinct from
 *         L1Anchor tests because the Factory's invariants are about
 *         deployment behavior, registry integrity, and Identity Primitive
 *         surface rather than about merchant capital routing.
 *
 *         Test categories:
 *           1. Construction (zero-address rejection, immutable assignment)
 *           2. deployAnchor() behavior (open access, MERCHANT_OWNER
 *              assignment, endpoint propagation, Identity Primitive
 *              trust chain)
 *           3. Registry behavior (append-only, per-merchant isolation,
 *              isAnchorOfFactory mapping accuracy)
 *           4. View functions (totalAnchors, anchorCountOf, getAnchorsOf,
 *              getAnchorsPage pagination)
 *           5. Identity Primitive surface (factoryVersion,
 *              anchorTemplateVersion, hasNoAdminAuthority,
 *              hasNoUpgradePath, isNonMoneyTransmitter)
 *           6. Negative invariants (Factory has no admin paths,
 *              cannot accept ETH)
 */
contract L1AnchorFactoryTest is Test {
    // ─── Actors ────────────────────────────────────────────────────────────

    address internal merchantAlice = address(0xA11CE);
    address internal merchantBob   = address(0xB0B);
    address internal observer      = address(0xC0DE);

    // ─── Mock infrastructure ───────────────────────────────────────────────

    MockERC20         internal cbETH;
    MockERC20         internal usdc;
    MockMAVANEntry    internal mavan;
    MockMorphoVault   internal morpho;
    MockChainlinkFeed internal oracle;

    // ─── System under test ─────────────────────────────────────────────────

    L1AnchorFactory internal factory;

    // ═══════════════════════════════════════════════════════════════════════
    //                                  SETUP
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public {
        cbETH  = new MockERC20("Coinbase Wrapped Staked ETH", "cbETH", 18);
        usdc   = new MockERC20("USD Coin", "USDC", 6);
        mavan  = new MockMAVANEntry(cbETH);
        morpho = new MockMorphoVault(usdc);
        oracle = new MockChainlinkFeed(18);

        factory = new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(cbETH),
            address(usdc),
            address(oracle)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       1. CONSTRUCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_rejectsZeroMorphoVault() public {
        vm.expectRevert(L1AnchorFactory.ZeroAddress.selector);
        new L1AnchorFactory(
            address(0),
            address(mavan),
            address(cbETH),
            address(usdc),
            address(oracle)
        );
    }

    function test_constructor_rejectsZeroMavanEntry() public {
        vm.expectRevert(L1AnchorFactory.ZeroAddress.selector);
        new L1AnchorFactory(
            address(morpho),
            address(0),
            address(cbETH),
            address(usdc),
            address(oracle)
        );
    }

    function test_constructor_rejectsZeroCbEth() public {
        vm.expectRevert(L1AnchorFactory.ZeroAddress.selector);
        new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(0),
            address(usdc),
            address(oracle)
        );
    }

    function test_constructor_rejectsZeroUsdc() public {
        vm.expectRevert(L1AnchorFactory.ZeroAddress.selector);
        new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(cbETH),
            address(0),
            address(oracle)
        );
    }

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(L1AnchorFactory.ZeroAddress.selector);
        new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(cbETH),
            address(usdc),
            address(0)
        );
    }

    function test_constructor_assignsImmutables() public view {
        assertEq(factory.BITWISE_MORPHO_VAULT(), address(morpho));
        assertEq(factory.MAVAN_ENTRY(),          address(mavan));
        assertEq(factory.CBETH(),                address(cbETH));
        assertEq(factory.USDC(),                 address(usdc));
        assertEq(factory.CBETH_ETH_ORACLE(),     address(oracle));
    }

    function test_constructor_initializesRegistryEmpty() public view {
        assertEq(factory.totalAnchors(), 0);
        assertEq(factory.anchorCountOf(merchantAlice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       2. deployAnchor() BEHAVIOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_deployAnchor_returnsValidAddress() public {
        vm.prank(merchantAlice);
        address anchorAddr = factory.deployAnchor();
        assertTrue(anchorAddr != address(0));
        assertTrue(anchorAddr.code.length > 0);
    }

    function test_deployAnchor_setsCallerAsMerchantOwner() public {
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());
        assertEq(anchor.MERCHANT_OWNER(), merchantAlice);
    }

    function test_deployAnchor_setsFactoryAsTrustAnchor() public {
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());
        assertEq(anchor.FACTORY(),         address(factory));
        assertEq(anchor.factoryDeployer(), address(factory));
    }

    function test_deployAnchor_propagatesInstitutionalEndpoints() public {
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());
        assertEq(anchor.BITWISE_MORPHO_VAULT(),       address(morpho));
        assertEq(anchor.MAVAN_ENTRY(),                address(mavan));
        assertEq(address(anchor.CBETH()),             address(cbETH));
        assertEq(address(anchor.USDC()),              address(usdc));
        assertEq(address(anchor.CBETH_ETH_ORACLE()),  address(oracle));
    }

    function test_deployAnchor_recordsDeploymentTimestamp() public {
        vm.warp(1_700_000_000);
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());
        assertEq(anchor.DEPLOYED_AT(), 1_700_000_000);
    }

    function test_deployAnchor_openAccess_anyAddressCanCall() public {
        // Three different addresses, three successful deployments
        vm.prank(merchantAlice);
        address anchorA = factory.deployAnchor();

        vm.prank(merchantBob);
        address anchorB = factory.deployAnchor();

        vm.prank(observer);
        address anchorC = factory.deployAnchor();

        assertTrue(anchorA != anchorB);
        assertTrue(anchorB != anchorC);
        assertTrue(anchorA != anchorC);
    }

    function test_deployAnchor_emitsAnchorCreatedEvent() public {
        vm.warp(1_700_000_000);
        vm.recordLogs();

        vm.prank(merchantAlice);
        address anchorAddr = factory.deployAnchor();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AnchorCreated(address,address,uint256,uint256)");

        bool found = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].emitter == address(factory)) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), merchantAlice);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), anchorAddr);

                (uint256 anchorIndex, uint256 timestamp) =
                    abi.decode(logs[i].data, (uint256, uint256));
                assertEq(anchorIndex, 0);
                assertEq(timestamp,   1_700_000_000);

                found = true;
                break;
            }
        }
        assertTrue(found, "AnchorCreated event not emitted");
    }

    function test_deployAnchor_eachAnchorIsUniqueContract() public {
        vm.prank(merchantAlice);
        address anchorA = factory.deployAnchor();

        vm.prank(merchantAlice);
        address anchorB = factory.deployAnchor();

        // Same merchant, two distinct Anchor contracts
        assertTrue(anchorA != anchorB);
        assertEq(L1Anchor(anchorA).MERCHANT_OWNER(), merchantAlice);
        assertEq(L1Anchor(anchorB).MERCHANT_OWNER(), merchantAlice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      3. REGISTRY BEHAVIOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_registry_appendsOnDeployment() public {
        vm.prank(merchantAlice);
        address anchorA = factory.deployAnchor();
        assertEq(factory.totalAnchors(), 1);
        assertEq(factory.deployedAnchors(0), anchorA);

        vm.prank(merchantBob);
        address anchorB = factory.deployAnchor();
        assertEq(factory.totalAnchors(), 2);
        assertEq(factory.deployedAnchors(1), anchorB);
    }

    function test_registry_perMerchantIsolation() public {
        vm.prank(merchantAlice);
        address aliceAnchor1 = factory.deployAnchor();

        vm.prank(merchantBob);
        address bobAnchor1 = factory.deployAnchor();

        vm.prank(merchantAlice);
        address aliceAnchor2 = factory.deployAnchor();

        // Alice's list contains only Alice's Anchors
        assertEq(factory.anchorCountOf(merchantAlice), 2);
        address[] memory aliceList = factory.getAnchorsOf(merchantAlice);
        assertEq(aliceList.length, 2);
        assertEq(aliceList[0], aliceAnchor1);
        assertEq(aliceList[1], aliceAnchor2);

        // Bob's list contains only Bob's Anchor
        assertEq(factory.anchorCountOf(merchantBob), 1);
        address[] memory bobList = factory.getAnchorsOf(merchantBob);
        assertEq(bobList.length, 1);
        assertEq(bobList[0], bobAnchor1);
    }

    function test_registry_isAnchorOfFactoryFlagSet() public {
        vm.prank(merchantAlice);
        address anchorAddr = factory.deployAnchor();

        assertTrue(factory.isAnchorOfFactory(anchorAddr));
        assertFalse(factory.isAnchorOfFactory(address(0xDEAD)));
        assertFalse(factory.isAnchorOfFactory(address(factory)));
        assertFalse(factory.isAnchorOfFactory(merchantAlice));
    }

    function test_registry_observerWithNoDeploymentsHasEmptyList() public {
        vm.prank(merchantAlice);
        factory.deployAnchor();

        assertEq(factory.anchorCountOf(observer), 0);
        address[] memory observerList = factory.getAnchorsOf(observer);
        assertEq(observerList.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      4. VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function test_view_totalAnchors_growsWithDeployments() public {
        assertEq(factory.totalAnchors(), 0);

        vm.prank(merchantAlice);
        factory.deployAnchor();
        assertEq(factory.totalAnchors(), 1);

        vm.prank(merchantBob);
        factory.deployAnchor();
        assertEq(factory.totalAnchors(), 2);

        vm.prank(merchantAlice);
        factory.deployAnchor();
        assertEq(factory.totalAnchors(), 3);
    }

    function test_view_getAnchorsPage_returnsRequestedSlice() public {
        // Deploy 5 Anchors across multiple merchants
        address[] memory expected = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            address m = address(uint160(0x1000 + i));
            vm.prank(m);
            expected[i] = factory.deployAnchor();
        }

        // Page covering middle three
        address[] memory page = factory.getAnchorsPage(1, 3);
        assertEq(page.length, 3);
        assertEq(page[0], expected[1]);
        assertEq(page[1], expected[2]);
        assertEq(page[2], expected[3]);
    }

    function test_view_getAnchorsPage_truncatesAtRegistryEnd() public {
        for (uint256 i = 0; i < 3; ++i) {
            address m = address(uint160(0x1000 + i));
            vm.prank(m);
            factory.deployAnchor();
        }

        // Request 10 from index 1 — only 2 remain
        address[] memory page = factory.getAnchorsPage(1, 10);
        assertEq(page.length, 2);
    }

    function test_view_getAnchorsPage_returnsEmptyOnOutOfBoundsStart() public {
        vm.prank(merchantAlice);
        factory.deployAnchor();

        address[] memory page = factory.getAnchorsPage(5, 10);
        assertEq(page.length, 0);
    }

    function test_view_getAnchorsPage_returnsEmptyOnEmptyRegistry() public view {
        address[] memory page = factory.getAnchorsPage(0, 10);
        assertEq(page.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  5. IDENTITY PRIMITIVE SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    function test_identity_isPossessioAnchorFactory() public view {
        assertTrue(factory.isPossessioAnchorFactory());
    }

    function test_identity_factoryVersionString() public view {
        assertEq(factory.factoryVersion(), "1.0.0");
    }

    function test_identity_anchorTemplateVersionString() public view {
        assertEq(factory.anchorTemplateVersion(), "1.0.0");
    }

    function test_identity_assertsNoAdminAuthority() public view {
        assertTrue(factory.hasNoAdminAuthority());
    }

    function test_identity_assertsNoUpgradePath() public view {
        assertTrue(factory.hasNoUpgradePath());
    }

    function test_identity_assertsNonMoneyTransmitter() public view {
        assertTrue(factory.isNonMoneyTransmitter());
    }

    function test_identity_anchorMatchesFactoryTemplateVersion() public {
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());

        // Anchor's version equals Factory's declared template version.
        // Recognition logic uses this match to verify Anchor authenticity.
        assertEq(anchor.anchorVersion(), factory.anchorTemplateVersion());
    }

    function test_identity_trustChain_factoryDeployerMatchesFactory() public {
        vm.prank(merchantAlice);
        L1Anchor anchor = L1Anchor(factory.deployAnchor());

        // Core trust chain: Anchor.factoryDeployer() returns Factory address.
        // External recognition logic verifies this matches an audited
        // canonical Factory address.
        assertEq(anchor.factoryDeployer(), address(factory));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      6. NEGATIVE INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The Factory has no payable functions and no receive/fallback.
    ///         Sending ETH must revert. Mechanically enforced
    ///         non-money-transmitter posture.
    function test_negative_factoryRejectsEth() public {
        vm.deal(merchantAlice, 1 ether);
        vm.prank(merchantAlice);
        (bool ok, ) = address(factory).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(factory).balance, 0);
    }

    /// @notice The Factory has no admin or owner role; no function should
    ///         allow anyone to mutate the institutional endpoint addresses
    ///         after deployment. Verified by absence: the contract has no
    ///         setter functions; this test confirms the immutables remain
    ///         unchanged after multiple deployments.
    function test_negative_immutablesUnchangedAfterDeployments() public {
        address morphoBefore = factory.BITWISE_MORPHO_VAULT();
        address mavanBefore  = factory.MAVAN_ENTRY();
        address cbethBefore  = factory.CBETH();
        address usdcBefore   = factory.USDC();
        address oracleBefore = factory.CBETH_ETH_ORACLE();

        for (uint256 i = 0; i < 5; ++i) {
            address m = address(uint160(0x2000 + i));
            vm.prank(m);
            factory.deployAnchor();
        }

        assertEq(factory.BITWISE_MORPHO_VAULT(), morphoBefore);
        assertEq(factory.MAVAN_ENTRY(),          mavanBefore);
        assertEq(factory.CBETH(),                cbethBefore);
        assertEq(factory.USDC(),                 usdcBefore);
        assertEq(factory.CBETH_ETH_ORACLE(),     oracleBefore);
    }

    /// @notice The Factory cannot be coerced into deploying an Anchor
    ///         pointing to non-canonical institutional endpoints. The
    ///         endpoints are immutable from the merchant's perspective —
    ///         this is verified structurally by the Factory's interface
    ///         (deployAnchor takes no endpoint parameters) and behaviorally
    ///         by every deployed Anchor returning the same endpoints.
    function test_negative_allDeployedAnchorsShareSameEndpoints() public {
        address[] memory deployers = new address[](3);
        deployers[0] = merchantAlice;
        deployers[1] = merchantBob;
        deployers[2] = observer;

        L1Anchor[] memory anchors = new L1Anchor[](3);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(deployers[i]);
            anchors[i] = L1Anchor(factory.deployAnchor());
        }

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(anchors[i].BITWISE_MORPHO_VAULT(),       address(morpho));
            assertEq(anchors[i].MAVAN_ENTRY(),                address(mavan));
            assertEq(address(anchors[i].CBETH()),             address(cbETH));
            assertEq(address(anchors[i].USDC()),              address(usdc));
            assertEq(address(anchors[i].CBETH_ETH_ORACLE()),  address(oracle));
        }
    }
}
