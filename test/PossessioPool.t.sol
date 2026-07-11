// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

/// @notice Plain 6-decimal USDC mock. The pool only touches
///         safeTransfer/safeTransferFrom (SafeERC20) — no EIP-3009, no
///         permit. `blockedTo` lets a single destination be forced to fail
///         (returns false) so SafeERC20 reverts — used to prove atomicity.
contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public blockedTo;

    function setBlockedTo(address a) external {
        blockedTo = a;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _xfer(msg.sender, to, amt);
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= amt, "allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - amt;
        return _xfer(f, to, amt);
    }

    function _xfer(address f, address to, uint256 amt) internal returns (bool) {
        if (to == blockedTo) return false; // SafeERC20 reads false as failure -> revert
        require(balanceOf[f] >= amt, "balance");
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract PossessioPoolTest is Test {
    MockUSDC usdc;
    PossessioPool pool;

    address operator;
    address treasury;
    address srcA;
    address srcB;
    address outsider;

    uint256 constant CAP = 1_000e6;
    uint256 constant FLOOR = 100e6;
    uint256 constant HALFLIFE = 1 days;

    function setUp() public {
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");
        srcA = makeAddr("srcA");
        srcB = makeAddr("srcB");
        outsider = makeAddr("outsider");
        usdc = new MockUSDC();
        // Standard pool: floorPerUnit = 0 so the floor is a flat ABSOLUTE_FLOOR
        // for the inflow/draw tests; velocity is exercised in its own tests.
        address[] memory srcs = new address[](2);
        srcs[0] = srcA;
        srcs[1] = srcB;
        pool = new PossessioPool(address(usdc), srcs, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
        usdc.mint(srcA, 1_000_000e6);
        usdc.mint(srcB, 1_000_000e6);
        vm.prank(srcA);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(srcB);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _deployPool(uint256 cap, uint256 floor, uint256 perUnit, uint256 halflife)
        internal
        returns (PossessioPool p)
    {
        address[] memory srcs = new address[](2);
        srcs[0] = srcA;
        srcs[1] = srcB;
        p = new PossessioPool(address(usdc), srcs, operator, treasury, cap, floor, perUnit, halflife);
        vm.prank(srcA);
        usdc.approve(address(p), type(uint256).max);
        vm.prank(srcB);
        usdc.approve(address(p), type(uint256).max);
    }

    // ---- DoD #1: BOUND INFLOW -------------------------------------------
    function test_dod1_rejectsUnauthorizedSource() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, outsider));
        pool.receiveInfraFunds(1e6);
    }

    function test_dod1_creditsAuthorizedSource() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(50e6);
        assertEq(pool.poolBalance(), 50e6);
    }

    function test_dod1_zeroAmountReverts() public {
        vm.prank(srcA);
        vm.expectRevert(PossessioPool.ZeroAmount.selector);
        pool.receiveInfraFunds(0);
    }

    // ---- DoD #2: MULTI-SOURCE FUNGIBLE ----------------------------------
    function test_dod2_multiSourceOneBalance() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(50e6);
        vm.prank(srcB);
        pool.receiveInfraFunds(30e6);
        assertEq(pool.poolBalance(), 80e6);
    }

    // ---- DoD #3: POOL FILL / CAP ----------------------------------------
    function test_dod3_fillsToCapExactly() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(CAP);
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(treasury), 0);
        // one more unit -> surplus 1 out, balance stays capped
        vm.prank(srcB);
        pool.receiveInfraFunds(1);
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(treasury), 1);
    }

    // ---- DoD #4: ONE-WAY SURPLUS (concrete + fuzz) ----------------------
    function test_dod4_surplusExact() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(CAP + 250e6);
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(treasury), 250e6);
    }

    function testFuzz_dod4_surplusIsExactOverflow(uint256 amt) public {
        amt = bound(amt, CAP + 1, 900_000e6);
        vm.prank(srcA);
        pool.receiveInfraFunds(amt);
        assertEq(pool.poolBalance(), CAP);
        assertEq(usdc.balanceOf(treasury), amt - CAP);
    }

    // ---- DoD #5: FLOORED DRAW -------------------------------------------
    function test_dod5_operatorDrawsSurplusOnly() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(500e6); // balance 500, floor 100 -> surplus 400
        assertEq(pool.drawableSurplus(), 400e6);

        // over-surplus reverts
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.ExceedsDrawableSurplus.selector, 401e6, 400e6));
        pool.settleOperationalCosts(401e6);

        // exact surplus ok
        vm.prank(operator);
        pool.settleOperationalCosts(400e6);
        assertEq(pool.poolBalance(), FLOOR);
        assertEq(usdc.balanceOf(operator), 400e6);

        // now at floor: any draw reverts
        vm.prank(operator);
        vm.expectRevert(PossessioPool.InsufficientOperationalFunds.selector);
        pool.settleOperationalCosts(1);
    }

    function test_dod5_onlyOperatorCanDraw() public {
        vm.prank(srcA);
        pool.receiveInfraFunds(500e6);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, outsider));
        pool.settleOperationalCosts(10e6);
    }

    // ---- DoD #6: UNGAMEABLE FLOOR ---------------------------------------
    function test_dod6_floorRisesWithVelocity_operatorCannotLower() public {
        PossessioPool p = _deployPool(100_000e6, FLOOR, 10e6, HALFLIFE);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(srcA);
            p.receiveInfraFunds(1_000e6);
        }
        // 3 inflow events (no time passed) -> 3 velocity units -> floor +30e6
        assertEq(p.getRunningMinimumFloor(), FLOOR + 30e6);

        uint256 floorBefore = p.getRunningMinimumFloor();
        vm.prank(operator);
        p.settleOperationalCosts(100e6); // draw surplus
        // drawing does not touch velocity/floor
        assertEq(p.getRunningMinimumFloor(), floorBefore);
    }

    // ---- DoD #7: DECAY CORRECTNESS -------------------------------------
    function test_dod7_floorDecaysMonotonicToBaseline() public {
        PossessioPool p = _deployPool(100_000e6, FLOOR, 10e6, HALFLIFE);
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(srcA);
            p.receiveInfraFunds(1_000e6);
        }
        uint256 f0 = p.getRunningMinimumFloor(); // 100 + 4*10 = 140
        assertEq(f0, FLOOR + 40e6);

        vm.warp(block.timestamp + HALFLIFE); // one half-life -> ~half velocity
        uint256 f1 = p.getRunningMinimumFloor();
        assertLt(f1, f0);
        assertGe(f1, FLOOR);

        vm.warp(block.timestamp + 200 * HALFLIFE); // fully decayed
        assertEq(p.getRunningMinimumFloor(), FLOOR);
    }

    function testFuzz_dod7_decayNeverBelowBaselineNorAboveStart(uint256 dt) public {
        PossessioPool p = _deployPool(100_000e6, FLOOR, 10e6, HALFLIFE);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(srcA);
            p.receiveInfraFunds(1_000e6);
        }
        uint256 start = p.getRunningMinimumFloor();
        dt = bound(dt, 0, 3650 days);
        vm.warp(block.timestamp + dt);
        uint256 f = p.getRunningMinimumFloor();
        assertGe(f, FLOOR); // never below the immutable baseline
        assertLe(f, start); // never above the pre-decay value
    }

    // ---- DoD #8: VALVE INTEGRITY (constructor) -------------------------
    function test_dod8_ctorRevertsSourceEqualsOperator() public {
        address[] memory s = new address[](1);
        s[0] = operator;
        vm.expectRevert(PossessioPool.ValveIntegrityViolation.selector);
        new PossessioPool(address(usdc), s, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
    }

    function test_dod8_ctorRevertsSourceEqualsTreasury() public {
        address[] memory s = new address[](1);
        s[0] = treasury;
        vm.expectRevert(PossessioPool.ValveIntegrityViolation.selector);
        new PossessioPool(address(usdc), s, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
    }

    function test_dod8_ctorRevertsDuplicateSource() public {
        address[] memory s = new address[](2);
        s[0] = srcA;
        s[1] = srcA;
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.DuplicateSource.selector, srcA));
        new PossessioPool(address(usdc), s, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
    }

    function test_dod8_ctorRevertsEmptySet() public {
        address[] memory s = new address[](0);
        vm.expectRevert(PossessioPool.EmptySourceSet.selector);
        new PossessioPool(address(usdc), s, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
    }

    function test_dod8_ctorRevertsZeroAddresses() public {
        address[] memory s = new address[](1);
        s[0] = srcA;
        vm.expectRevert(PossessioPool.ZeroAddress.selector);
        new PossessioPool(address(0), s, operator, treasury, CAP, FLOOR, 0, HALFLIFE);
        vm.expectRevert(PossessioPool.ZeroAddress.selector);
        new PossessioPool(address(usdc), s, address(0), treasury, CAP, FLOOR, 0, HALFLIFE);
        vm.expectRevert(PossessioPool.ZeroAddress.selector);
        new PossessioPool(address(usdc), s, operator, address(0), CAP, FLOOR, 0, HALFLIFE);
    }

    // ---- DoD #9: VALVE-BY-OMISSION ------------------------------------
    function test_dod9_treasuryAndOperatorCannotFeedIn() public {
        // Both are structurally barred from the source set (ctor), so even
        // with infinite allowance there is no path to raise poolBalance.
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, treasury));
        pool.receiveInfraFunds(1e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PossessioPool.NotAuthorizedSource.selector, operator));
        pool.receiveInfraFunds(1e6);
    }

    // ---- DoD #11: USDC ONLY / NO ETH ----------------------------------
    function test_dod11_rejectsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1}("");
        assertFalse(ok); // no receive(), no fallback(), not payable
    }

    // ---- DoD #13: ATOMICITY -------------------------------------------
    function test_dod13_surplusTransferFailureUnwindsWholeTx() public {
        usdc.setBlockedTo(treasury); // force the surplus push to fail
        uint256 srcBalBefore = usdc.balanceOf(srcA);
        vm.prank(srcA);
        vm.expectRevert(); // SafeERC20 surfaces the failed transfer
        pool.receiveInfraFunds(CAP + 100e6);
        // full unwind: no balance credited, source not debited, treasury untouched
        assertEq(pool.poolBalance(), 0);
        assertEq(usdc.balanceOf(srcA), srcBalBefore);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ---- DoD #14: CODE-MATCHES-CLAIM (raw transfers not credited) ------
    function test_dod14_rawTransferNotCredited() public {
        vm.prank(srcA);
        usdc.transfer(address(pool), 500e6); // direct transfer, bypassing the door
        assertEq(usdc.balanceOf(address(pool)), 500e6); // tokens are there
        assertEq(pool.poolBalance(), 0); // but NOT credited — no sync door
    }

    function test_dod14_authorizedSourceCount() public view {
        assertEq(pool.authorizedSourceCount(), 2);
    }
}
