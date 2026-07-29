// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   THE ACCOUNT AS A LAUNCHABLE TEMPLATE — end to end

   PossessioFactory.deployTemplate appends abi.encode(owner, initArgs)
   to a codehash-pinned initCode, so a template's constructor MUST be
   (address, bytes). PossessioPayments now is.

   This proves the whole path a stranger takes from the console's
   launch rail: pinned codehash accepted, fee settled, salt consumed,
   CREATE3 deploy, owner written BY THE FACTORY, and the resulting
   Account fully configured and operable.

   It is the gate on TEMPLATE_CODEHASH, which is immutable per factory.
   Pin a hash whose template cannot actually deploy and the factory is
   bricked at a permanent address.
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";
import {MockUSDC as FactoryUSDC, MockPool} from "./PossessioFactory.t.sol";
import {MockDAI, MockCbETH, MockWETH, MockV3Router, MockAerodromeRouter,
        MockMorphoVault, MockChainlink, MockLSTRates} from "./PossessioPayments_t.sol";

contract PaymentsAsTemplateTest is Test {
    address constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    uint256 constant FEE = 50_000000;   // $50 — DEPLOY_CALIBRATION §22

    FactoryUSDC usdc;
    MockDAI dai; MockCbETH cbeth; MockWETH weth;
    MockV3Router router; MockAerodromeRouter aero; MockMorphoVault morpho;
    MockChainlink clEth; MockChainlink clDai; MockChainlink clUsdcUsd; MockChainlink clEthUsd;
    MockLSTRates lst;

    PossessioFactory factory;
    PossessioSaltPool saltPool;
    address sink;
    address keeper   = makeAddr("saltKeeper");
    address customer = makeAddr("grandma");     // the launcher: pays, signs, owns
    address constant OPERATOR = address(0x0011);
    address constant TREASURY = address(0x0022);
    address constant FEESRC   = address(0x0033);

    bytes32 templateCodehash;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");

        usdc = new FactoryUSDC();
        dai = new MockDAI(); cbeth = new MockCbETH(); weth = new MockWETH();
        router = new MockV3Router(address(usdc), address(dai), address(weth));
        aero   = new MockAerodromeRouter(address(weth), address(cbeth));
        morpho = new MockMorphoVault(address(usdc));
        clEth     = new MockChainlink(int256(980_000_000_000_000_000), 18);
        clDai     = new MockChainlink(int256(500_000_000_000), 8);
        clUsdcUsd = new MockChainlink(int256(100_000_000), 8);
        clEthUsd  = new MockChainlink(int256(300_000_000_000), 8);
        lst = new MockLSTRates();

        sink = address(new MockPool(usdc));
        templateCodehash = keccak256(type(PossessioPayments).creationCode);

        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        saltPool = new PossessioSaltPool(predictedFactory, keeper, OPERATOR, TREASURY, FEESRC);
        factory  = new PossessioFactory(FEE, templateCodehash, address(saltPool), address(usdc), sink);
        require(address(factory) == predictedFactory, "factory prediction failed");
    }

    function _refillSalt(uint88 entropy) internal {
        bytes32[] memory b = new bytes32[](1);
        b[0] = bytes32(bytes20(address(factory))) | bytes32(uint256(entropy));
        vm.prank(keeper);
        saltPool.refillSalts(b);
    }

    /// @dev The one field the launch rail actually asks a person for is the
    ///      stable reserve ceiling. Everything else is "Set for you, locked".
    function _initArgs(address encodedOwner, uint256 reserveCeiling)
        internal view returns (bytes memory)
    {
        return abi.encode(PossessioPayments.DeployParams({
            owner: encodedOwner,
            usdc: address(usdc), cbeth: address(cbeth), dai: address(dai), weth: address(weth),
            router: address(router), aeroRouter: address(aero), morphoVault: address(morpho),
            chainlink: address(clEth), chainlinkDai: address(clDai),
            chainlinkUsdcUsd: address(clUsdcUsd), chainlinkEthUsd: address(clEthUsd),
            lstRates: address(lst),
            minSwapBatch: 100_000000,
            daiCeiling: reserveCeiling,
            dailyLimit: 50_000e18,
            usdcDailyLimit: 50_000e6,
            cbEthDailyLimit: 20e18
        }));
    }

    function _auth() internal pure returns (PossessioFactory.FeeAuth memory a) { a; }

    // ── T1. The launch: one call, $50, and the customer owns an Account ──
    function test_T1_customerLaunchesAnAccountThroughTheFactory() public {
        _refillSalt(1);
        usdc.mint(customer, FEE);

        uint256 sinkBefore = usdc.balanceOf(sink);

        vm.prank(customer);
        address deployed = factory.deployTemplate(
            customer,                                   // owner, written by the factory
            _initArgs(customer, 2_280e18),              // "Reserve $2,280"
            type(PossessioPayments).creationCode,
            _auth()
        );

        PossessioPayments acct = PossessioPayments(payable(deployed));

        assertGt(deployed.code.length, 0, "Account deployed");
        assertTrue(acct.hasRole(acct.OWNER_ROLE(), customer), "customer owns it the moment it deploys");
        assertEq(usdc.balanceOf(customer), 0, "paid exactly $50, no more");
        assertEq(usdc.balanceOf(sink) - sinkBefore, FEE, "the whole fee reached the Heart");

        // the one number they chose landed
        assertEq(acct.daiCeiling(), 2_280e18, "their reserve ceiling");
        // and everything "Set for you, locked" landed too
        assertEq(acct.minSwapBatch(),    100_000000, "minSwapBatch preset");
        assertEq(acct.dailyLimit(),      50_000e18,  "dailyLimit preset");
        assertEq(acct.usdcDailyLimit(),  50_000e6,   "usdcDailyLimit preset");
        assertEq(acct.cbEthDailyLimit(), 20e18,      "cbEthDailyLimit preset");
        assertEq(acct.cbEthBps(),        5000,       "slider ships at 50/50");
        assertFalse(acct.withdrawalsFrozen(),        "exits live on arrival");
    }

    // ── T2. The factory writes the owner — a spoofed one cannot win ──────
    //      This is the guarantee the old struct-only constructor could not
    //      participate in: p.owner inside initArgs is attacker-chosen.
    function test_T2_spoofedOwnerInInitArgsIsOverridden() public {
        _refillSalt(2);
        usdc.mint(customer, FEE);
        address attacker = makeAddr("attacker");

        vm.prank(customer);
        address deployed = factory.deployTemplate(
            customer,
            _initArgs(attacker, 1_000e18),              // initArgs says the ATTACKER owns it
            type(PossessioPayments).creationCode,
            _auth()
        );

        PossessioPayments acct = PossessioPayments(payable(deployed));
        assertTrue(acct.hasRole(acct.OWNER_ROLE(), customer),  "launcher owns it");
        assertFalse(acct.hasRole(acct.OWNER_ROLE(), attacker), "SPOOFED owner must not hold the role");
    }

    // ── T3. The codehash pin is what makes "Set for you, locked" true ────
    function test_T3_alteredTemplateIsRefusedCostFree() public {
        _refillSalt(3);
        usdc.mint(customer, FEE);

        vm.prank(customer);
        vm.expectRevert();
        factory.deployTemplate(customer, _initArgs(customer, 1e18), hex"6080604052", _auth());

        assertEq(usdc.balanceOf(customer), FEE, "a refused launch charges nothing");
    }

    // ── T4. Two customers, two Accounts, neither can touch the other ─────
    function test_T4_launchesAreIndependent() public {
        address second = makeAddr("secondCustomer");
        _refillSalt(4);
        usdc.mint(customer, FEE);
        vm.prank(customer);
        address a = factory.deployTemplate(customer, _initArgs(customer, 500e18),
                                           type(PossessioPayments).creationCode, _auth());

        _refillSalt(5);
        usdc.mint(second, FEE);
        vm.prank(second);
        address b = factory.deployTemplate(second, _initArgs(second, 9_000e18),
                                           type(PossessioPayments).creationCode, _auth());

        assertTrue(a != b, "distinct addresses");
        PossessioPayments A = PossessioPayments(payable(a));
        PossessioPayments B = PossessioPayments(payable(b));

        assertEq(A.daiCeiling(), 500e18,   "each keeps their own choice");
        assertEq(B.daiCeiling(), 9_000e18, "each keeps their own choice");
        assertFalse(A.hasRole(A.OWNER_ROLE(), second),  "second cannot own the first");
        assertFalse(B.hasRole(B.OWNER_ROLE(), customer), "first cannot own the second");
    }

    // ── T5. POSSESSIO holds nothing over a launched Account ──────────────
    //      The claim the whole product rests on, asserted against a contract
    //      that was deployed BY US, through OUR factory, for a customer.
    function test_T5_possessioHasNoAuthorityOverALaunchedAccount() public {
        _refillSalt(6);
        usdc.mint(customer, FEE);
        vm.prank(customer);
        address deployed = factory.deployTemplate(customer, _initArgs(customer, 1_000e18),
                                                  type(PossessioPayments).creationCode, _auth());
        PossessioPayments acct = PossessioPayments(payable(deployed));

        assertFalse(acct.hasRole(acct.OWNER_ROLE(), address(factory)),   "factory holds nothing");
        assertFalse(acct.hasRole(acct.OWNER_ROLE(), address(this)),      "deployer holds nothing");
        assertFalse(acct.hasRole(acct.OWNER_ROLE(), sink),               "the Heart holds nothing");
        assertFalse(acct.hasRole(acct.DEFAULT_ADMIN_ROLE(), address(factory)), "no admin backdoor");

        // and nobody can grant themselves one: OWNER_ROLE administers itself
        // and DEFAULT_ADMIN_ROLE has no members, so there is no path in.
        // Hoisted: a view call in the argument position eats the cheatcodes.
        bytes32 ownerRole = acct.OWNER_ROLE();
        address fac = address(factory);
        vm.prank(fac);
        vm.expectRevert();
        acct.grantRole(ownerRole, fac);
    }
}
