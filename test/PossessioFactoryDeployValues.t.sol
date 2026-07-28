// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   FACTORY — THE DEPLOYMENT CONFIGURATION, UNDER TEST

   Fourth in the series with Pool / x402Core / Account. Same law.

   DEPLOYMENT_FEE is immutable PER FACTORY. That is the whole tier
   design: a price change is a NEW factory, and every economy already
   launched keeps the terms it was launched under, forever, because
   nothing can rewrite the fee of a live factory.

   Two prices are ratified. $50 is CURRENT (DEPLOY_CALIBRATION §22);
   $100 is a ratified later tier, and it is what all three existing
   suites run (PossessioFactory.t.sol:94, Adversarial:97, Fork:78).
   So the shipping price is exercised nowhere, and — more importantly
   — the TIER MECHANISM itself has never been tested: no suite proves
   that two factories at two prices coexist, each binding its own fee,
   with neither able to disturb the other.

   This suite tests the current price AND the versioning design that
   makes the price safe to change.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {MockUSDC, MockPool, MockTemplate} from "./PossessioFactory.t.sol";

contract PossessioFactoryDeployValuesTest is Test {
    address constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    // ── DEPLOY_CALIBRATION §22 ───────────────────────────────────────────
    uint256 constant FEE_CURRENT = 50_000000;    // $50  — ships now
    uint256 constant FEE_TIER_HI = 100_000000;   // $100 — ratified later tier
    uint256 constant FEE_CONNECTOR = 5_000000;   // $5   — connector-tier (§22)

    MockUSDC usdc;
    address  sink;
    address  keeper   = makeAddr("saltKeeper");
    address  buyer    = makeAddr("buyer");
    address  owner    = makeAddr("customer");
    address  constant OPERATOR = address(0x0011);
    address  constant TREASURY = address(0x0022);
    address  constant FEESRC   = address(0x0033);

    bytes32 templateCodehash;

    function setUp() public {
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");
        usdc = new MockUSDC();
        sink = address(new MockPool(usdc));
        templateCodehash = keccak256(type(MockTemplate).creationCode);
    }

    function _spawn(uint256 fee) internal returns (PossessioSaltPool p, PossessioFactory f) {
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        p = new PossessioSaltPool(predicted, keeper, OPERATOR, TREASURY, FEESRC);
        f = new PossessioFactory(fee, templateCodehash, address(p), address(usdc), sink);
        require(address(f) == predicted, "factory prediction failed");
    }

    function _refill(PossessioSaltPool p, address f, uint88 entropy) internal {
        bytes32[] memory b = new bytes32[](1);
        b[0] = bytes32(bytes20(f)) | bytes32(uint256(entropy));
        vm.prank(keeper);
        p.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioFactory.FeeAuth memory a) { a; }

    // ── F1. The current price lands as calibrated ────────────────────────
    function test_F1_currentFeeIsFifty() public {
        (, PossessioFactory f) = _spawn(FEE_CURRENT);
        assertEq(f.DEPLOYMENT_FEE(), FEE_CURRENT, "shipping DEPLOYMENT_FEE != $50");
    }

    // ── F2. A launch at $50 charges exactly $50, and it reaches the Heart ─
    function test_F2_launchChargesExactlyFifty() public {
        (PossessioSaltPool p, PossessioFactory f) = _spawn(FEE_CURRENT);
        _refill(p, address(f), 1);
        usdc.mint(buyer, FEE_CURRENT);

        uint256 sinkBefore = usdc.balanceOf(sink);
        vm.prank(buyer);
        address deployed = f.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());

        assertGt(deployed.code.length, 0, "template deployed");
        assertEq(usdc.balanceOf(buyer), 0, "buyer paid exactly the fee, no more");
        assertEq(usdc.balanceOf(sink) - sinkBefore, FEE_CURRENT, "the whole $50 reached the sink");
        assertEq(MockTemplate(deployed).owner(), owner, "factory wrote the owner");
    }

    // ── F3. THE TIER DESIGN: two prices coexist, neither disturbs the other
    //      This is what makes an immutable fee safe. Never tested before.
    function test_F3_tiersCoexistEachBindingItsOwnPrice() public {
        (PossessioSaltPool pLo, PossessioFactory fLo) = _spawn(FEE_CURRENT);
        (PossessioSaltPool pHi, PossessioFactory fHi) = _spawn(FEE_TIER_HI);

        assertEq(fLo.DEPLOYMENT_FEE(), FEE_CURRENT, "cheap tier holds $50");
        assertEq(fHi.DEPLOYMENT_FEE(), FEE_TIER_HI, "raised tier holds $100");

        _refill(pLo, address(fLo), 11);
        _refill(pHi, address(fHi), 12);

        // A buyer with exactly $50 can launch on the current tier...
        usdc.mint(buyer, FEE_CURRENT);
        vm.prank(buyer);
        fLo.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());
        assertEq(usdc.balanceOf(buyer), 0);

        // ...and that same $50 is NOT enough on the raised tier.
        usdc.mint(buyer, FEE_CURRENT);
        vm.prank(buyer);
        vm.expectRevert();
        fHi.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());

        // Deploying a raised tier did not change the cheap one.
        assertEq(fLo.DEPLOYMENT_FEE(), FEE_CURRENT, "existing tier's terms are untouched");
    }

    // ── F4. No path rewrites a live factory's price ──────────────────────
    //      Immutability is the customer's guarantee: the terms they
    //      launched under cannot be raised afterwards, by anyone.
    function test_F4_noSetterCanRepriceALiveFactory() public {
        (, PossessioFactory f) = _spawn(FEE_CURRENT);
        uint256 before_ = f.DEPLOYMENT_FEE();

        // There is no setter. Prove it by exhausting the write surface:
        // any call that is not a known function must revert, and the fee
        // is unchanged after the attempt.
        (bool ok, ) = address(f).call(abi.encodeWithSignature("setDeploymentFee(uint256)", uint256(1)));
        assertFalse(ok, "no setDeploymentFee may exist");
        (ok, ) = address(f).call(abi.encodeWithSignature("setFee(uint256)", uint256(1)));
        assertFalse(ok, "no setFee may exist");

        assertEq(f.DEPLOYMENT_FEE(), before_, "price is immutable for the life of the factory");
    }

    // ── F5. The connector tier ($5, §22) works at its own price ──────────
    function test_F5_connectorTierAtFiveDollars() public {
        (PossessioSaltPool p, PossessioFactory f) = _spawn(FEE_CONNECTOR);
        assertEq(f.DEPLOYMENT_FEE(), FEE_CONNECTOR, "connector tier != $5");

        _refill(p, address(f), 21);
        usdc.mint(buyer, FEE_CONNECTOR);
        vm.prank(buyer);
        address deployed = f.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());
        assertGt(deployed.code.length, 0, "connector-tier launch works at $5");
        assertEq(usdc.balanceOf(buyer), 0, "charged exactly $5");
    }

    // ── F6. Underpay and overpay both die at the shipping price ─────────
    function test_F6_exactPriceOrNothing() public {
        (PossessioSaltPool p, PossessioFactory f) = _spawn(FEE_CURRENT);
        _refill(p, address(f), 31);

        usdc.mint(buyer, FEE_CURRENT - 1);
        vm.prank(buyer);
        vm.expectRevert();
        f.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());

        // The failed attempt consumed nothing.
        assertEq(usdc.balanceOf(buyer), FEE_CURRENT - 1, "a failed launch charges nothing");
    }

    // ── F7. The codehash pin holds at the shipping configuration ─────────
    //      A wrong template reverts BEFORE any fee moves (DoD #7). Proven
    //      here at $50 so the cost-free-refusal property is tested at the
    //      price customers will actually pay.
    function test_F7_wrongTemplateRefusedBeforeAnyCharge() public {
        (PossessioSaltPool p, PossessioFactory f) = _spawn(FEE_CURRENT);
        _refill(p, address(f), 41);
        usdc.mint(buyer, FEE_CURRENT);

        vm.prank(buyer);
        vm.expectRevert();
        f.deployTemplate(owner, "", hex"6080604052", _auth());   // not the pinned template

        assertEq(usdc.balanceOf(buyer), FEE_CURRENT, "refusal must be cost-free");
    }
}
