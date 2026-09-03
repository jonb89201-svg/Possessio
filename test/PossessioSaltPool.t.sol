// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
              POSSESSIO SALT POOL - DoD TEST SUITE
        Maps 1:1 to SPEC_PossessioSaltPool.md §Definition of Done.
        Cold-seat re-audit target. Every DoD item is a test below;
        DoD #5 (no money path) is proven by (a) the ETH-rejection
        test and (b) the CI grep noted at the bottom of this file.
//////////////////////////////////////////////////////////////*/

contract PossessioSaltPoolTest is Test {
    PossessioSaltPool internal pool;

    address internal constant FACTORY  = address(0xFAC);
    address internal constant KEEPER   = address(0xBEEF);
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC   = address(0x0033);

    event SaltPulled(bytes32 salt, uint256 remaining);
    event PoolRefilled(uint256 added, uint256 newDepth);

    function setUp() public {
        pool = new PossessioSaltPool(FACTORY, KEEPER, OPERATOR, TREASURY, FEESRC);
    }

    /*//////////////////////////////////////////////////////////////
                    Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev G-1: build a factory-permissioned salt (leading 20 bytes == prefix,
    ///      distinct entropy in the low 96 bits) so refillSalts accepts it.
    function _ps(address prefix, uint256 entropy) internal pure returns (bytes32) {
        // uint88 leaves byte 21 (CreateX's redeploy-protection flag) at 0x00 —
        // the only flags CreateX accepts are 0x00 / 0x01 (F-L2).
        return bytes32(bytes20(prefix)) | bytes32(uint256(uint88(entropy)));
    }

    /// F-L2 helper: a factory-prefixed salt with an explicit byte-21 flag.
    function _psFlag(address prefix, bytes1 flag, uint256 entropy) internal pure returns (bytes32) {
        return bytes32(bytes20(prefix)) | (bytes32(flag) >> 160) | bytes32(uint256(uint88(entropy)));
    }

    /*//////////////////////////////////////////////////////////////
        F-L2 (re-audit 2026-09-01) - refill rejects CreateX-invalid
        redeploy flags; keeper can drop a poisoned top salt
    //////////////////////////////////////////////////////////////*/

    /// RED on the pre-fix pool: a byte-21 = 0x02 salt passed the prefix check,
    /// sat on top of the LIFO queue, and made every deploy revert at CreateX.
    function test_FL2_refill_invalidRedeployFlag_reverts() public {
        bytes32 poison = _psFlag(FACTORY, 0x02, 1);
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = poison;
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(PossessioSaltPool.SaltRedeployFlagInvalid.selector, poison));
        pool.refillSalts(salts);
        assertEq(pool.depth(), 0);
    }

    function test_FL2_refill_acceptsBothValidFlags() public {
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = _psFlag(FACTORY, 0x00, 1);
        salts[1] = _psFlag(FACTORY, 0x01, 2);
        vm.prank(KEEPER);
        pool.refillSalts(salts);
        assertEq(pool.depth(), 2);
    }

    function test_FL2_dropTop_keeperOnly_LIFO() public {
        bytes32[] memory salts = _refill(3);
        vm.prank(FACTORY);
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        pool.dropTop();

        vm.prank(KEEPER);
        bytes32 dropped = pool.dropTop();
        assertEq(dropped, salts[2], "drops the top (LIFO) salt");
        assertEq(pool.depth(), 2);

        vm.prank(FACTORY);
        assertEq(pool.pullSalt(), salts[1], "next pull sees the salt beneath");
    }

    function test_FL2_dropTop_empty_reverts() public {
        vm.prank(KEEPER);
        vm.expectRevert(PossessioSaltPool.PoolEmpty.selector);
        pool.dropTop();
    }

    function _refill(uint256 n) internal returns (bytes32[] memory salts) {
        salts = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            salts[i] = _ps(FACTORY, uint256(keccak256(abi.encode("salt", i))));
        }
        vm.prank(KEEPER);
        pool.refillSalts(salts);
    }

    /*//////////////////////////////////////////////////////////////
        G-1 (cold-seat audit) - refill enforces factory-permissioned salts
    //////////////////////////////////////////////////////////////*/

    function test_G1_refill_nonFactoryPrefixed_reverts() public {
        bytes32 bad = bytes32(uint256(1)); // prefix is address(0), not FACTORY
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bad;
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(PossessioSaltPool.SaltNotFactoryPermissioned.selector, bad));
        pool.refillSalts(salts);
    }

    function test_G1_refill_factoryPrefixed_accepted() public {
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _ps(FACTORY, 0x1234);
        vm.prank(KEEPER);
        pool.refillSalts(salts);
        assertEq(pool.depth(), 1, "factory-prefixed salt accepted");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #1 - PULL ACCESS: any non-factory caller reverts
    //////////////////////////////////////////////////////////////*/

    function test_DoD1_pull_nonFactory_reverts() public {
        _refill(3);
        vm.prank(KEEPER); // even the keeper cannot pull
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        pool.pullSalt();
    }

    function testFuzz_DoD1_pull_anyNonFactory_reverts(address caller) public {
        vm.assume(caller != FACTORY);
        _refill(1);
        vm.prank(caller);
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        pool.pullSalt();
    }

    /*//////////////////////////////////////////////////////////////
        DoD #2 - REFILL ACCESS: any non-keeper caller reverts
    //////////////////////////////////////////////////////////////*/

    function test_DoD2_refill_nonKeeper_reverts() public {
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(1));
        vm.prank(FACTORY); // even the factory cannot refill
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        pool.refillSalts(salts);
    }

    function testFuzz_DoD2_refill_anyNonKeeper_reverts(address caller) public {
        vm.assume(caller != KEEPER);
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(1));
        vm.prank(caller);
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        pool.refillSalts(salts);
    }

    /*//////////////////////////////////////////////////////////////
        DoD #3 - EMPTY-POOL HONESTY: pull on empty reverts PoolEmpty,
        no fallback, no fabricated salt
    //////////////////////////////////////////////////////////////*/

    function test_DoD3_pull_onEmpty_reverts_PoolEmpty() public {
        assertEq(pool.depth(), 0);
        vm.prank(FACTORY);
        vm.expectRevert(PossessioSaltPool.PoolEmpty.selector);
        pool.pullSalt();
    }

    function test_DoD3_pull_afterDrain_reverts_PoolEmpty() public {
        _refill(2);
        vm.startPrank(FACTORY);
        pool.pullSalt();
        pool.pullSalt();
        // drained - next pull must revert, not fabricate
        vm.expectRevert(PossessioSaltPool.PoolEmpty.selector);
        pool.pullSalt();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        DoD #4 - KEEPER SEPARATION (fuzz): constructor reverts
        KeeperIntegrityViolation for every collision combination
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DoD4_keeper_eq_operator_reverts(address k) public {
        vm.assume(k != address(0));
        vm.expectRevert(PossessioSaltPool.KeeperIntegrityViolation.selector);
        new PossessioSaltPool(FACTORY, k, k, TREASURY, FEESRC);
    }

    function testFuzz_DoD4_keeper_eq_treasury_reverts(address k) public {
        vm.assume(k != address(0));
        vm.expectRevert(PossessioSaltPool.KeeperIntegrityViolation.selector);
        new PossessioSaltPool(FACTORY, k, OPERATOR, k, FEESRC);
    }

    function testFuzz_DoD4_keeper_eq_feeSource_reverts(address k) public {
        vm.assume(k != address(0));
        vm.expectRevert(PossessioSaltPool.KeeperIntegrityViolation.selector);
        new PossessioSaltPool(FACTORY, k, OPERATOR, TREASURY, k);
    }

    function test_DoD4_zeroFactory_reverts() public {
        vm.expectRevert(PossessioSaltPool.ZeroAddress.selector);
        new PossessioSaltPool(address(0), KEEPER, OPERATOR, TREASURY, FEESRC);
    }

    function test_DoD4_zeroKeeper_reverts() public {
        vm.expectRevert(PossessioSaltPool.ZeroAddress.selector);
        new PossessioSaltPool(FACTORY, address(0), OPERATOR, TREASURY, FEESRC);
    }

    /*//////////////////////////////////////////////////////////////
        DoD #5 - NO MONEY PATH: the contract has no receive/fallback,
        so plain ETH transfer to it reverts. (The complementary CI
        grep is documented at the bottom of this file.)
    //////////////////////////////////////////////////////////////*/

    function test_DoD5_plainEthTransfer_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(pool).call{value: 1 wei}("");
        assertFalse(ok, "contract must not accept ETH: no money path");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #6 - LIFO CORRECTNESS: pull returns the most recently
        pushed unconsumed salt; depth accurate after any sequence
    //////////////////////////////////////////////////////////////*/

    function test_DoD6_LIFO_order_and_depth() public {
        bytes32[] memory batch = _refill(3); // batch[0], [1], [2] pushed in order
        assertEq(pool.depth(), 3);

        vm.startPrank(FACTORY);
        assertEq(pool.pullSalt(), batch[2], "LIFO: last pushed pulls first");
        assertEq(pool.depth(), 2);
        assertEq(pool.pullSalt(), batch[1]);
        assertEq(pool.depth(), 1);
        vm.stopPrank();

        // interleave a second refill, LIFO must track the new top
        bytes32[] memory second = new bytes32[](1);
        second[0] = _ps(FACTORY, uint256(keccak256("second-batch")));
        vm.prank(KEEPER);
        pool.refillSalts(second);
        assertEq(pool.depth(), 2);

        vm.startPrank(FACTORY);
        assertEq(pool.pullSalt(), second[0], "LIFO: newest batch on top");
        assertEq(pool.pullSalt(), batch[0], "then the remaining original");
        vm.stopPrank();
        assertEq(pool.depth(), 0);
    }

    function testFuzz_DoD6_depth_tracks_refill_then_drain(uint8 n) public {
        vm.assume(n > 0 && n <= 64);
        _refill(n);
        assertEq(pool.depth(), n);
        vm.startPrank(FACTORY);
        for (uint256 i = 0; i < n; i++) {
            pool.pullSalt();
            assertEq(pool.depth(), n - i - 1);
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        EVENTS - emitted with correct post-state depths
    //////////////////////////////////////////////////////////////*/

    function test_events_refill_and_pull() public {
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = _ps(FACTORY, 0xA);
        salts[1] = _ps(FACTORY, 0xB);

        vm.expectEmit(false, false, false, true);
        emit PoolRefilled(2, 2);
        vm.prank(KEEPER);
        pool.refillSalts(salts);

        vm.expectEmit(false, false, false, true);
        emit SaltPulled(_ps(FACTORY, 0xB), 1); // LIFO top, remaining=1
        vm.prank(FACTORY);
        pool.pullSalt();
    }

    /*//////////////////////////////////////////////////////////////
        CHARACTERIZATION - OPEN QUESTION Q2 (documents, not decides)

        The spec zero-checks only factory/keeper. If all three
        money-destinations are zero, the Invariant-4 separation
        check is vacuous. This test CHARACTERIZES that the current
        spec-faithful build ACCEPTS such a construction - so the
        council sees the edge explicitly and can decide whether the
        constructor should also reject zero destinations.
        KNOWN LIMIT under current spec; not a pass/fail judgment.
    //////////////////////////////////////////////////////////////*/

    function test_Q2_KNOWN_LIMIT_zeroDestinations_makeSeparationVacuous() public {
        // Builds successfully under current spec - flagged for council.
        PossessioSaltPool p = new PossessioSaltPool(
            FACTORY, KEEPER, address(0), address(0), address(0)
        );
        assertEq(p.keeper(), KEEPER); // constructed; check was vacuous
    }

    /*//////////////////////////////////////////////////////////////
        CHARACTERIZATION - OPEN QUESTION Q3 (cold-seat finding)

        The constructor never checks _keeper == _factory. The spec's
        invariants require only that the keeper be money-clean, and
        the factory is not a money destination in this contract -
        so keeper==factory may be acceptable. But it concentrates
        refill AND pull in one address: that address could mine its
        own salts and consume them with no separate pulling party.
        This test CHARACTERIZES that the current spec-faithful build
        ACCEPTS keeper==factory (with no other collision), so the
        council decides deliberately instead of inheriting silence.
        KNOWN LIMIT under current spec; not a pass/fail judgment.
    //////////////////////////////////////////////////////////////*/

    function test_Q3_KNOWN_LIMIT_keeperEqualsFactory_currentlyAllowed() public {
        address dual = address(0xD0A1);
        PossessioSaltPool p = new PossessioSaltPool(
            dual, dual, OPERATOR, TREASURY, FEESRC
        );
        // One address holds both capabilities: refill AND pull.
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _ps(dual, uint256(keccak256("self-mined"))); // G-1: prefix == this pool's factory
        vm.startPrank(dual);
        p.refillSalts(salts);                    // as keeper
        assertEq(p.pullSalt(), salts[0]);        // as factory - same wallet
        vm.stopPrank();
        assertEq(p.depth(), 0); // mine-your-own, consume-your-own: allowed today
    }
}

/*//////////////////////////////////////////////////////////////
  DoD #5 complementary CI check (run in repo, not in Solidity):

    grep -nE "transfer|safeTransfer|call\{value|IERC20|payable" \
        src/PossessioSaltPool.sol

  EXPECTED: no matches in executable code (the word "value" appears
  only in comments). The contract moves only bytes32 values.
//////////////////////////////////////////////////////////////*/
