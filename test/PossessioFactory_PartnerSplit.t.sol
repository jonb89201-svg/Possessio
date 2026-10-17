// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

/*//////////////////////////////////////////////////////////////
        PARTNER SHARE (2026-10-17)
        The factory pays a security partner a fixed share of every fee
        into the partner's own PossessioPool (same contract, same limits).
        Real pools on both sides; a USDC mock that can block an address,
        as Circle can, so a refused partner payment is exercised for real
        through the pool's outbound surplus push.
//////////////////////////////////////////////////////////////*/

/// EIP-3009 USDC mock with a blocklist: a transfer from or to a blocked
/// address reverts, like a blacklisted address on Circle's USDC.
contract BlockableUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function setBlocked(address who, bool b) external { blocked[who] = b; }

    function _move(address f, address to, uint256 a) internal {
        require(!blocked[f] && !blocked[to], "blocked");
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256, uint256, bytes32, uint8, bytes32, bytes32
    ) external {
        require(msg.sender == to, "3009: only payee may submit");
        _move(from, to, value);
    }
}

/// Permissive stand-in for feeSink in constructor-guard tests, so the partner
/// checks are reached whatever the new factory's address is.
contract PermissiveSink {
    function isInfraSink() external pure returns (bool) { return true; }
    function isAuthorizedSource(address) external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256) external pure {}
}

/// Template following the ratified convention: constructor(owner, initArgs).
contract PartnerSplitTemplate {
    address public owner;
    constructor(address _owner, bytes memory) { owner = _owner; }
}

contract PossessioFactoryPartnerSplitTest is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    uint256 constant FEE = 50_000_000; // $50, 6 decimals
    uint256 constant HALF = 5_000;     // 50% in basis points

    // Pool limits: identical for both pools ("the same withdraw limits").
    uint256 constant CAP = 40_000_000;
    uint256 constant FLOOR = 20_000_000;
    uint256 constant FPU = 1_000_000;
    uint256 constant HL = 1 days;

    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal ourOperator = makeAddr("ourOperator");
    address internal ourTreasury = makeAddr("ourTreasury");
    address internal partnerSafe = makeAddr("partnerSafe"); // operator AND treasury, as the Pool allows

    BlockableUSDC internal usdc;
    PossessioPool internal ourPool;
    PossessioPool internal partnerPool;
    PossessioSaltPool internal saltPool;
    PossessioFactory internal factory;
    bytes32 internal codehash;
    address internal permissive;

    function setUp() public {
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");
        usdc = new BlockableUSDC();
        codehash = keccak256(type(PartnerSplitTemplate).creationCode);
        (ourPool, partnerPool, saltPool, factory) = _constellation(FEE, HALF);
        permissive = address(new PermissiveSink());
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// Both pools bake the factory's predicted address into their source set,
    /// the same deploy order as production: pools first, then the factory.
    function _constellation(uint256 fee, uint256 bps)
        internal
        returns (PossessioPool ours, PossessioPool partner, PossessioSaltPool sp, PossessioFactory f)
    {
        uint256 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 3);
        address[] memory sources = new address[](1);
        sources[0] = predicted;
        ours = new PossessioPool(address(usdc), sources, ourOperator, ourTreasury, CAP, FLOOR, FPU, HL);
        partner = new PossessioPool(address(usdc), sources, partnerSafe, partnerSafe, CAP, FLOOR, FPU, HL);
        sp = new PossessioSaltPool(predicted, keeper, ourOperator, ourTreasury, makeAddr("feesrc"));
        f = new PossessioFactory(fee, codehash, address(sp), address(usdc), address(ours),
            bps == 0 ? address(0) : address(partner), bps);
        require(address(f) == predicted, "factory prediction failed");
    }

    /// One salt for `f` and the fee in the buyer's wallet.
    function _prepare(PossessioSaltPool sp, PossessioFactory f, uint88 entropy) internal {
        bytes32[] memory b = new bytes32[](1);
        b[0] = bytes32(bytes20(address(f))) | bytes32(uint256(entropy));
        vm.prank(keeper);
        sp.refillSalts(b);
        usdc.mint(buyer, f.DEPLOYMENT_FEE());
    }

    function _deploy(PossessioFactory f) internal returns (address deployed) {
        address merchant = makeAddr("merchant");
        PossessioFactory.FeeAuth memory a;
        vm.prank(buyer);
        deployed = f.deployTemplate(merchant, "", type(PartnerSplitTemplate).creationCode, a);
    }

    function _launch(PossessioSaltPool sp, PossessioFactory f, uint88 entropy) internal returns (address) {
        _prepare(sp, f, entropy);
        return _deploy(f);
    }

    function _held(PossessioPool p, address dest) internal view returns (uint256) {
        return usdc.balanceOf(address(p)) + usdc.balanceOf(dest);
    }

    /*//////////////////////////////////////////////////////////////
                        The split itself
    //////////////////////////////////////////////////////////////*/

    function test_split_halfToEachPool() public {
        _launch(saltPool, factory, 1);
        assertEq(usdc.balanceOf(address(ourPool)), FEE / 2, "our pool: half");
        assertEq(usdc.balanceOf(address(partnerPool)), FEE / 2, "partner pool: half");
        assertEq(partnerPool.poolBalance(), FEE / 2, "partner pool accounted it");
        assertEq(usdc.balanceOf(address(factory)), 0, "factory keeps nothing");
        assertEq(factory.partnerOwed(), 0, "nothing held");
        assertEq(usdc.allowance(address(factory), address(partnerPool)), 0, "no dangling approval");
    }

    function test_split_oddUnitGoesToOurPool() public {
        (PossessioPool ours, PossessioPool partner, PossessioSaltPool sp, PossessioFactory f) =
            _constellation(FEE + 1, HALF);
        _launch(sp, f, 2);
        assertEq(usdc.balanceOf(address(partner)), FEE / 2, "partner cut rounds down");
        assertEq(usdc.balanceOf(address(ours)), FEE / 2 + 1, "odd unit stays with our pool");
    }

    function test_split_sameLimitsBothPools() public view {
        assertEq(partnerPool.OPERATIONAL_CAP(), ourPool.OPERATIONAL_CAP(), "cap");
        assertEq(partnerPool.ABSOLUTE_FLOOR(), ourPool.ABSOLUTE_FLOOR(), "floor");
        assertEq(partnerPool.FLOOR_PER_UNIT(), ourPool.FLOOR_PER_UNIT(), "floor per unit");
        assertEq(partnerPool.VELOCITY_HALFLIFE(), ourPool.VELOCITY_HALFLIFE(), "half-life");
        assertEq(factory.partnerSink(), address(partnerPool), "partner pool pinned");
        assertEq(factory.PARTNER_BPS(), HALF, "share pinned");
    }

    function testFuzz_split_conserves(uint256 fee, uint256 bps) public {
        fee = bound(fee, 1_000_000, 1_000_000_000_000);
        bps = bound(bps, 1, 5_000);
        (PossessioPool ours, PossessioPool partner, PossessioSaltPool sp, PossessioFactory f) =
            _constellation(fee, bps);
        _launch(sp, f, 3);
        uint256 cut = (fee * bps) / 10_000;
        assertEq(_held(partner, partnerSafe), cut, "partner gets exactly its share");
        assertEq(_held(ours, ourTreasury), fee - cut, "our pool gets the rest");
        assertGe(fee - cut, cut, "our side never below the partner's");
        assertEq(usdc.balanceOf(address(f)), 0, "factory keeps nothing");
    }

    function test_noPartner_allToOurPool() public {
        (PossessioPool ours,, PossessioSaltPool sp, PossessioFactory f) = _constellation(FEE, 0);
        _launch(sp, f, 4);
        assertEq(_held(ours, ourTreasury), FEE, "no partner: whole fee to our pool");
        assertEq(f.partnerSink(), address(0), "no partner pinned");
        vm.expectRevert(PossessioFactory.NothingOwed.selector);
        f.flushPartner();
    }

    /*//////////////////////////////////////////////////////////////
                A refused partner payment never blocks a launch
    //////////////////////////////////////////////////////////////*/

    /// Fill the partner pool to its cap, then block the partner's address: the
    /// next partner payment overflows the cap, the pool's surplus push reverts,
    /// and the pool refuses the whole payment.
    function _refusePartner() internal {
        _launch(saltPool, factory, 10); // 25 into the partner pool
        _launch(saltPool, factory, 11); // 50 -> capped at 40, 10 pushed to partnerSafe
        assertEq(partnerPool.poolBalance(), CAP, "partner pool at its cap");
        usdc.setBlocked(partnerSafe, true);
    }

    function test_refused_launchSucceeds_cutHeld() public {
        _refusePartner();
        uint256 ourBefore = _held(ourPool, ourTreasury);

        _prepare(saltPool, factory, 12);
        address merchant = makeAddr("merchant");
        PossessioFactory.FeeAuth memory a;
        vm.expectEmit(address(factory));
        emit PossessioFactory.PartnerPaymentDeferred(FEE / 2, FEE / 2);
        vm.prank(buyer);
        address deployed = factory.deployTemplate(merchant, "", type(PartnerSplitTemplate).creationCode, a);

        assertTrue(deployed.code.length > 0, "the launch went through");
        assertEq(_held(ourPool, ourTreasury) - ourBefore, FEE / 2, "our half arrived as usual");
        assertEq(factory.partnerOwed(), FEE / 2, "partner's half is held");
        assertEq(usdc.balanceOf(address(factory)), FEE / 2, "and the factory holds exactly that");
        assertEq(usdc.allowance(address(factory), address(partnerPool)), 0, "approval cleared");
    }

    function test_refused_cutsAccumulate() public {
        _refusePartner();
        _launch(saltPool, factory, 12);
        _launch(saltPool, factory, 13);
        assertEq(factory.partnerOwed(), FEE, "two halves held");
        assertEq(usdc.balanceOf(address(factory)), factory.partnerOwed(), "held == balance");
    }

    function test_flush_deliversAfterUnblock_toPartnerOnly() public {
        _refusePartner();
        _launch(saltPool, factory, 12);
        usdc.setBlocked(partnerSafe, false);
        uint256 partnerBefore = _held(partnerPool, partnerSafe);
        uint256 ourBefore = _held(ourPool, ourTreasury);

        vm.prank(makeAddr("anyone"));
        uint256 sent = factory.flushPartner();

        assertEq(sent, FEE / 2, "flushed the held cut");
        assertEq(_held(partnerPool, partnerSafe) - partnerBefore, FEE / 2, "it reached the partner");
        assertEq(_held(ourPool, ourTreasury), ourBefore, "none of it went to our side");
        assertEq(factory.partnerOwed(), 0, "nothing left held");
        assertEq(usdc.balanceOf(address(factory)), 0, "factory empty");

        vm.expectRevert(PossessioFactory.NothingOwed.selector);
        factory.flushPartner(); // a second flush cannot pay twice
    }

    function test_flush_stillBlocked_revertsAndKeepsHolding() public {
        _refusePartner();
        _launch(saltPool, factory, 12);
        vm.expectRevert();
        factory.flushPartner();
        assertEq(factory.partnerOwed(), FEE / 2, "still held");
        assertEq(usdc.balanceOf(address(factory)), FEE / 2, "funds still here");
    }

    function test_flush_nothingOwed_reverts() public {
        vm.expectRevert(PossessioFactory.NothingOwed.selector);
        factory.flushPartner();
    }

    /*//////////////////////////////////////////////////////////////
                        Constructor guards
    //////////////////////////////////////////////////////////////*/

    /// The permissive feeSink is created in setUp, so the constructor below is
    /// the first call after each test's expectRevert.
    function _newFactory(uint256 fee, address partner, uint256 bps) internal returns (PossessioFactory) {
        return new PossessioFactory(fee, codehash, address(saltPool), address(usdc), permissive, partner, bps);
    }

    function test_ctor_shareAboveHalf_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PossessioFactory.PartnerShareTooHigh.selector, uint256(5_001)));
        _newFactory(FEE, address(partnerPool), 5_001);
    }

    function test_ctor_sinkWithoutShare_reverts() public {
        vm.expectRevert(PossessioFactory.PartnerConfigInvalid.selector);
        _newFactory(FEE, address(partnerPool), 0);
    }

    function test_ctor_shareWithoutSink_reverts() public {
        vm.expectRevert(PossessioFactory.PartnerConfigInvalid.selector);
        _newFactory(FEE, address(0), HALF);
    }

    function test_ctor_partnerIsFeeSink_reverts() public {
        vm.expectRevert(PossessioFactory.PartnerConfigInvalid.selector);
        _newFactory(FEE, permissive, HALF);
    }

    function test_ctor_validPartner_deploys() public {
        // Positive control for the guards above: a well-formed partner config
        // builds (the permissive sink accepts any source, so it can stand in).
        address second = address(new PermissiveSink());
        PossessioFactory f = _newFactory(FEE, second, HALF);
        assertEq(f.partnerSink(), second);
        assertEq(f.PARTNER_BPS(), HALF);
    }

    function test_ctor_shareRoundsToZero_reverts() public {
        vm.expectRevert(PossessioFactory.PartnerConfigInvalid.selector);
        _newFactory(1, address(partnerPool), 1);
    }

    function test_ctor_partnerEOA_reverts() public {
        vm.expectRevert(PossessioFactory.PartnerSinkInterfaceMismatch.selector);
        _newFactory(FEE, makeAddr("partnerEOA"), HALF);
    }

    function test_ctor_partnerPoolNotAcceptingThisFactory_reverts() public {
        // partnerPool's source set holds only the setUp factory, not this new one.
        vm.expectRevert(PossessioFactory.PartnerSinkSourceNotAuthorized.selector);
        _newFactory(FEE, address(partnerPool), HALF);
    }
}
