// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";
import {MockEIP3009USDC, MockInfraSink, NotAnInfraSink} from "./X402TestnetMocks.sol";

/// @notice ADVERSARIAL gauntlet for PossessioX402Core — the attacker-driven
///         complement to the DoD proof suite (PossessioX402CoreTestnet.t.sol).
///         Brings x402Core to parity with its gauntleted siblings (Factory,
///         Pool, SAV, AutoTarget, Guard). Every money-path gate is probed by
///         someone trying to break it: settleCall front-run/spoof, the
///         self-funding valve (one-way), fee-source authorization, and the
///         channel registry. Offline (MockEIP3009USDC); no RPC.
contract PossessioX402CoreGauntletTest is Test {
    uint256 constant OPERATIONAL_CAP = 100_000000; // 100 USDC
    uint256 constant VELOCITY_HALFLIFE = 3600;
    uint256 constant ABSOLUTE_FLOOR = 10_000000; // 10 USDC
    uint256 constant FLOOR_PER_UNIT = 1_000000;
    uint256 constant DUST_FLOOR = 1_000000;

    bytes32 constant RECEIVE_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    PossessioX402Core internal core;
    MockEIP3009USDC internal usdc;
    MockInfraSink internal heart; // stands in for the Heart (surplus sink)

    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal feeSource = makeAddr("feeSource");
    address internal seller = makeAddr("seller");
    address internal attacker = makeAddr("attacker");

    uint256 internal buyerPk = 0xB0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0;
    address internal buyer;

    bytes32 internal constant SECRET_A = keccak256("x402-gauntlet-leaf-A");
    bytes32 internal constant SECRET_B = keccak256("x402-gauntlet-leaf-B");
    address internal spare = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

    bytes32 internal channelId = keccak256("x402-gauntlet-channel");
    uint256 internal saltCounter;

    function setUp() public {
        buyer = vm.addr(buyerPk);
        usdc = new MockEIP3009USDC();
        heart = new MockInfraSink(address(usdc));

        bytes32 leafA = HandshakeLib.hashLeaf(SECRET_A, buyer);
        bytes32 leafB = HandshakeLib.hashLeaf(SECRET_B, spare);
        bytes32 root = HandshakeLib.hashNode(leafA, leafB);

        core = new PossessioX402Core({
            root: root,
            dustFloor: DUST_FLOOR,
            _payToken: address(usdc),
            _heartSink: address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: feeSource,
            _operationalCap: OPERATIONAL_CAP,
            _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT,
            _velocityHalflife: VELOCITY_HALFLIFE
        });

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.prank(buyer);
        core.register(SECRET_A, proof);

        vm.prank(seller);
        core.setBasePrice(channelId, 1000_000000); // 1000 USDC

        usdc.mint(buyer, 100_000_000000);
        usdc.mint(feeSource, 10_000_000000);
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNING HELPERS
    //////////////////////////////////////////////////////////////*/

    struct Auth {
        bytes32 salt;
        uint256 value;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// A correctly-quoted, correctly-committed, buyer-signed authorization.
    function _validAuth() internal returns (Auth memory a) {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        a.value = basePrice + (basePrice * tollBps) / 10_000;
        a.salt = bytes32(++saltCounter);
        a.nonce = keccak256(abi.encode(seller, channelId, a.value, a.salt));
        a = _sign(a);
    }

    /// Sign whatever (value, nonce, salt) are already set — lets a test tamper.
    function _sign(Auth memory a) internal view returns (Auth memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(RECEIVE_TYPEHASH, buyer, address(core), a.value, uint256(0), type(uint256).max, a.nonce))
            )
        );
        (a.v, a.r, a.s) = vm.sign(buyerPk, digest);
        return a;
    }

    function _settle(address caller, address sellerArg, bytes32 chan, Auth memory a) internal {
        core.settleCall(caller, sellerArg, chan, a.salt, a.value, 0, type(uint256).max, a.nonce, a.v, a.r, a.s);
    }

    /*//////////////////////////////////////////////////////////////
        settleCall — IDENTITY / CHANNEL / PRICE GATES
    //////////////////////////////////////////////////////////////*/

    function test_unregisteredCaller_cannotSettle() public {
        Auth memory a = _validAuth();
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.CallerNotRegistered.selector, attacker));
        _settle(attacker, seller, channelId, a); // attacker is not registered
    }

    function test_unpricedChannel_reverts() public {
        bytes32 ghost = keccak256("never-priced");
        Auth memory a = _validAuth();
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.ChannelNotPriced.selector, ghost));
        _settle(buyer, seller, ghost, a);
    }

    function test_sellerSubstitution_reverts() public {
        Auth memory a = _validAuth();
        // attacker submits a valid buyer auth but names THEMSELVES as seller,
        // trying to redirect the netToSeller payout.
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.SellerMismatch.selector, channelId, attacker, seller));
        _settle(buyer, attacker, channelId, a);
    }

    /*//////////////////////////////////////////////////////////////
        settleCall — PRICE BINDING (no underpay / overpay)
    //////////////////////////////////////////////////////////////*/

    function test_underpay_reverts() public {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        uint256 expected = basePrice + (basePrice * tollBps) / 10_000;

        Auth memory a;
        a.value = expected - 1; // underpay by 1 wei
        a.salt = bytes32(++saltCounter);
        a.nonce = keccak256(abi.encode(seller, channelId, a.value, a.salt));
        a = _sign(a);

        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.AmountMismatch.selector, expected - 1, expected));
        _settle(buyer, seller, channelId, a);
    }

    function test_overpay_reverts() public {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        uint256 expected = basePrice + (basePrice * tollBps) / 10_000;

        Auth memory a;
        a.value = expected + 1_000000; // overpay
        a.salt = bytes32(++saltCounter);
        a.nonce = keccak256(abi.encode(seller, channelId, a.value, a.salt));
        a = _sign(a);

        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.AmountMismatch.selector, expected + 1_000000, expected));
        _settle(buyer, seller, channelId, a);
    }

    /*//////////////////////////////////////////////////////////////
        settleCall — NONCE COMMITMENT (the front-run defense)
    //////////////////////////////////////////////////////////////*/

    function test_nonceCommitmentMismatch_reverts() public {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        uint256 value = basePrice + (basePrice * tollBps) / 10_000;

        Auth memory a;
        a.value = value; // correct value (passes AmountMismatch)
        a.salt = bytes32(uint256(0xABCD)); // settleCall recomputes with THIS salt
        // ...but the signed nonce committed to a DIFFERENT salt -> mismatch.
        a.nonce = keccak256(abi.encode(seller, channelId, value, bytes32(uint256(0x9999))));
        a = _sign(a);

        bytes32 expectedCommit = keccak256(abi.encode(seller, channelId, value, a.salt));
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.NonceCommitmentMismatch.selector, a.nonce, expectedCommit));
        _settle(buyer, seller, channelId, a);
    }

    /*//////////////////////////////////////////////////////////////
        settleCall — FRONT-RUN IS HARMLESS (the core x402 property)
    //////////////////////////////////////////////////////////////*/

    function test_frontRun_thirdPartySubmitter_gainsNothing() public {
        Auth memory a = _validAuth();
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 toll = a.value - basePrice;

        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 poolBefore = core.operationalPoolBalance();

        // A random attacker submits the buyer's valid auth. Permissionless by
        // design — and it CHANGES NOTHING: funds route to the registered seller
        // and the pool regardless of who calls. The submitter nets zero.
        vm.prank(attacker);
        _settle(buyer, seller, channelId, a);

        assertEq(usdc.balanceOf(seller), sellerBefore + basePrice, "seller must net basePrice");
        assertEq(core.operationalPoolBalance(), poolBefore + toll, "toll must feed the pool");
        assertEq(usdc.balanceOf(attacker), 0, "front-runner gained nothing");
    }

    function test_replay_secondSettleReverts() public {
        Auth memory a = _validAuth();
        _settle(buyer, seller, channelId, a);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _settle(buyer, seller, channelId, a);
    }

    /*//////////////////////////////////////////////////////////////
        THE SELF-FUNDING VALVE — deploymentFee inflow
    //////////////////////////////////////////////////////////////*/

    function test_unauthorizedDeploymentFeeSource_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.NotDeploymentFeeSource.selector, attacker));
        core.receiveDeploymentFee(1_000000);
    }

    function test_deploymentFee_zeroAmount_reverts() public {
        vm.prank(feeSource);
        vm.expectRevert(PossessioX402Core.InsufficientOperationalFunds.selector);
        core.receiveDeploymentFee(0);
    }

    function test_deploymentFee_overCap_routesToHeart() public {
        vm.prank(feeSource);
        usdc.approve(address(core), type(uint256).max);
        uint256 heartBefore = heart.received();

        // push MORE than the cap in one shot; the excess must route one-way
        // INTO THE HEART via the accounted door (not a raw treasury transfer).
        vm.prank(feeSource);
        core.receiveDeploymentFee(OPERATIONAL_CAP + 30_000000);

        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool capped exactly");
        assertEq(heart.received(), heartBefore + 30_000000, "surplus routed one-way into the Heart");
        assertEq(usdc.balanceOf(address(heart)), 30_000000, "Heart holds the surplus USDC");
    }

    /*//////////////////////////////////////////////////////////////
        THE VALVE — operator draw (theft-of-purpose disproven)
    //////////////////////////////////////////////////////////////*/

    function _fillPool(uint256 amount) internal {
        vm.prank(feeSource);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(feeSource);
        core.receiveDeploymentFee(amount);
    }

    function test_nonOperator_cannotDraw() public {
        _fillPool(50_000000);
        vm.prank(attacker);
        vm.expectRevert(PossessioX402Core.UnauthorizedCall.selector);
        core.settleOperationalCosts(1_000000);
    }

    function test_operatorCannotDrainBelowFloor() public {
        _fillPool(50_000000);
        uint256 floor = core.getRunningMinimumFloor();
        uint256 drawable = 50_000000 - floor;
        // ask for one wei more than the drawable surplus.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.ExceedsDrawableSurplus.selector, drawable + 1, drawable));
        core.settleOperationalCosts(drawable + 1);
    }

    function test_operatorCannotDrawFromEmptyPool() public {
        // pool below the floor -> nothing drawable, ever.
        vm.prank(operator);
        vm.expectRevert(PossessioX402Core.InsufficientOperationalFunds.selector);
        core.settleOperationalCosts(1);
    }

    function test_operatorDrawSurplus_succeeds_thenFloorHolds() public {
        _fillPool(50_000000);
        uint256 floor = core.getRunningMinimumFloor();
        uint256 drawable = 50_000000 - floor;

        vm.prank(operator);
        core.settleOperationalCosts(drawable); // draw ALL surplus — allowed
        assertEq(core.operationalPoolBalance(), floor, "pool sits exactly at floor");

        // now the floor is the hard wall: not one wei more.
        vm.prank(operator);
        vm.expectRevert(PossessioX402Core.InsufficientOperationalFunds.selector);
        core.settleOperationalCosts(1);
    }

    /*//////////////////////////////////////////////////////////////
        CHANNEL REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_channelHijack_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.ChannelNotOwnedByCaller.selector, channelId, seller));
        core.setBasePrice(channelId, 1); // attacker cannot reprice the seller's channel
    }

    function test_repriceMidFlight_staleAuthReverts() public {
        // buyer signs at the current price...
        Auth memory a = _validAuth();
        // ...seller reprices UP before it settles.
        vm.prank(seller);
        core.setBasePrice(channelId, 2000_000000);
        // the stale auth can no longer settle — it reverts, never overcharges.
        uint256 newExpected = 2000_000000 + (2000_000000 * core.totalFeeBps(buyer, channelId)) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(PossessioX402Core.AmountMismatch.selector, a.value, newExpected));
        _settle(buyer, seller, channelId, a);
    }

    /*//////////////////////////////////////////////////////////////
        CONSTRUCTOR VALVE INTEGRITY (fee source can't be a destination)
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejects_feeSourceEqualsOperator() public {
        bytes32 root = HandshakeLib.hashNode(
            HandshakeLib.hashLeaf(SECRET_A, buyer), HandshakeLib.hashLeaf(SECRET_B, spare)
        );
        vm.expectRevert(PossessioX402Core.ValveIntegrityViolation.selector);
        new PossessioX402Core({
            root: root,
            dustFloor: DUST_FLOOR,
            _payToken: address(usdc),
            _heartSink: address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: operator, // == operator -> ingress could feed egress
            _operationalCap: OPERATIONAL_CAP,
            _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT,
            _velocityHalflife: VELOCITY_HALFLIFE
        });
    }

    function test_constructor_rejects_feeSourceEqualsHeart() public {
        bytes32 root = HandshakeLib.hashNode(
            HandshakeLib.hashLeaf(SECRET_A, buyer), HandshakeLib.hashLeaf(SECRET_B, spare)
        );
        // feeSource == heartSink would wire the inbound fee path to an outbound
        // destination — same valve violation, now against the Heart.
        vm.expectRevert(PossessioX402Core.ValveIntegrityViolation.selector);
        new PossessioX402Core({
            root: root,
            dustFloor: DUST_FLOOR,
            _payToken: address(usdc),
            _heartSink: address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: address(heart),
            _operationalCap: OPERATIONAL_CAP,
            _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT,
            _velocityHalflife: VELOCITY_HALFLIFE
        });
    }

    /*//////////////////////////////////////////////////////////////
        HEART BRICK-GUARD (heartSink must be a live infra-sink)
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejects_heartSink_EOA() public {
        // An EOA (no code) — the code-length pre-check reverts.
        address eoa = makeAddr("eoaHeart");
        bytes32 root = HandshakeLib.hashNode(
            HandshakeLib.hashLeaf(SECRET_A, buyer), HandshakeLib.hashLeaf(SECRET_B, spare)
        );
        vm.expectRevert(PossessioX402Core.FeeSinkInterfaceMismatch.selector);
        new PossessioX402Core({
            root: root, dustFloor: DUST_FLOOR, _payToken: address(usdc),
            _heartSink: eoa, _operatorDestination: operator, _deploymentFeeSource: feeSource,
            _operationalCap: OPERATIONAL_CAP, _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT, _velocityHalflife: VELOCITY_HALFLIFE
        });
    }

    function test_constructor_rejects_heartSink_wrongContract() public {
        // Real code, but no isInfraSink() marker — the try/catch reverts.
        address wrong = address(new NotAnInfraSink());
        bytes32 root = HandshakeLib.hashNode(
            HandshakeLib.hashLeaf(SECRET_A, buyer), HandshakeLib.hashLeaf(SECRET_B, spare)
        );
        vm.expectRevert(PossessioX402Core.FeeSinkInterfaceMismatch.selector);
        new PossessioX402Core({
            root: root, dustFloor: DUST_FLOOR, _payToken: address(usdc),
            _heartSink: wrong, _operatorDestination: operator, _deploymentFeeSource: feeSource,
            _operationalCap: OPERATIONAL_CAP, _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT, _velocityHalflife: VELOCITY_HALFLIFE
        });
    }

    function test_constructor_accepts_realInfraSink() public {
        // The positive control — a live infra-sink constructs cleanly.
        bytes32 root = HandshakeLib.hashNode(
            HandshakeLib.hashLeaf(SECRET_A, buyer), HandshakeLib.hashLeaf(SECRET_B, spare)
        );
        PossessioX402Core ok = new PossessioX402Core({
            root: root, dustFloor: DUST_FLOOR, _payToken: address(usdc),
            _heartSink: address(heart), _operatorDestination: operator, _deploymentFeeSource: feeSource,
            _operationalCap: OPERATIONAL_CAP, _absoluteFloor: ABSOLUTE_FLOOR,
            _floorPerUnit: FLOOR_PER_UNIT, _velocityHalflife: VELOCITY_HALFLIFE
        });
        assertEq(ok.heartSink(), address(heart), "heartSink wired");
    }

    /*//////////////////////////////////////////////////////////////
        settleCall surplus routes into the Heart (not treasury)
    //////////////////////////////////////////////////////////////*/

    function test_settleCall_surplusOverCap_routesToHeart() public {
        // Fill the operating pool to the cap via deployment fee first, so the
        // next settleCall's toll is pure surplus routed to the Heart.
        vm.prank(feeSource);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(feeSource);
        core.receiveDeploymentFee(OPERATIONAL_CAP); // pool at cap, heart untouched
        assertEq(heart.received(), 0, "no surplus yet");

        // one real settlement; pool is at cap, so its whole toll is surplus.
        Auth memory a = _validAuth();
        _settle(buyer, seller, channelId, a);

        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool stays at cap");
        assertGt(heart.received(), 0, "settleCall toll surplus routed into the Heart");
    }
}
