// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {MockEIP3009USDC} from "./X402TestnetMocks.sol";

/// @notice Adversarial suite for PossessioAutoTarget (SPEC_AutoTarget.md §8).
///         Every invariant probed by an attacker: authority boundaries, the
///         un-removable stop, fee atomicity, front-run closure, rogue keeper.
contract PossessioAutoTargetAdversarialTest is Test {
    PossessioAutoTarget internal desk;
    MockEIP3009USDC internal usdc;
    GoodHeart internal heart;

    uint256 internal constant FEE = 20_000;
    address internal keeper;
    uint32 internal constant CHAIN = 8453; // Base (EVM rail)
    bytes32 internal tokenRef;
    address internal attacker;

    uint256 internal userPk = 0xA11CE;
    address internal user;

    function setUp() public {
        user = vm.addr(userPk);
        keeper = makeAddr("keeper");
        tokenRef = bytes32(uint256(uint160(makeAddr("pickedToken"))));
        attacker = makeAddr("attacker");
        usdc = new MockEIP3009USDC();
        heart = new GoodHeart(address(usdc));
        desk = new PossessioAutoTarget(address(usdc), address(heart), keeper, FEE);
        usdc.mint(user, 1_000_000);
    }

    function _sign(uint256 pk, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (PossessioAutoTarget.FeeAuth memory a)
    {
        a.validAfter = 0;
        a.validBefore = type(uint256).max;
        a.nonce = nonce;
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), vm.addr(pk), to, value, a.validAfter, a.validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    function _open(uint16 targetBps, bytes32 nonce) internal returns (uint256 id) {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, nonce);
        vm.prank(user);
        id = desk.openIntent(tokenRef, CHAIN, 1e18, targetBps, a);
    }

    /*//////////////////////////////////////////////////////////////
                    AUTHORITY BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_non_keeper_cannot_resolve() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.NotKeeper.selector, attacker));
        desk.resolveIntent(id, 2e18);
    }

    function test_user_cannot_resolve_own_intent() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(user); // even the owner cannot self-authorize an exit
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.NotKeeper.selector, user));
        desk.resolveIntent(id, 2e18);
    }

    function test_non_owner_cannot_cancel() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.NotIntentOwner.selector, attacker));
        desk.cancelIntent(id);
    }

    function test_keeper_cannot_cancel() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(keeper); // keeper has trigger authority, NOT cancel authority
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.NotIntentOwner.selector, keeper));
        desk.cancelIntent(id);
    }

    /*//////////////////////////////////////////////////////////////
            INVARIANT 1 - STOP IS UN-REMOVABLE (even on +50%)
    //////////////////////////////////////////////////////////////*/

    function test_fifty_target_still_stops_at_ten() public {
        uint256 id = _open(5000, keccak256("n1")); // +50% target
        // price craters to -12% -> the always-on stop MUST fire
        vm.prank(keeper);
        desk.resolveIntent(id, 0.88e18);
        assertEq(uint256(desk.getIntent(id).exitKind), uint256(PossessioAutoTarget.ExitKind.Stop), "stop fires under +50 target");
        assertEq(desk.getIntent(id).stopBps, 1000, "stop bps un-touched");
    }

    function test_no_target_bypasses_stop_math() public {
        // A price just above stop but far below target must NOT resolve.
        uint256 id = _open(5000, keccak256("n1")); // target 1.5, stop 0.9
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioAutoTarget.NotTriggered.selector, uint256(0.95e18), uint256(1.5e18), uint256(0.9e18))
        );
        desk.resolveIntent(id, 0.95e18);
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 3 - FEE ATOMICITY: a reverting Heart unwinds the open
    //////////////////////////////////////////////////////////////*/

    function test_reverting_heart_unwinds_open_user_not_charged() public {
        RevertingHeart bad = new RevertingHeart();
        PossessioAutoTarget badDesk = new PossessioAutoTarget(address(usdc), address(bad), keeper, FEE);
        uint256 balBefore = usdc.balanceOf(user);

        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(badDesk), FEE, keccak256("n1"));
        vm.prank(user);
        vm.expectRevert(bytes("Heart down"));
        badDesk.openIntent(tokenRef, CHAIN, 1e18, 2500, a);

        // Fee unwound: the whole tx reverted, so the EIP-3009 settle rolled back.
        assertEq(usdc.balanceOf(user), balBefore, "user not charged on failed open");
        assertEq(badDesk.intentCount(), 0, "no intent recorded");
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 4 - FRONT-RUN-CLOSED: auth bound to `to == desk`
    //////////////////////////////////////////////////////////////*/

    function test_auth_signed_for_desk_cannot_settle_elsewhere() public {
        // User signs an auth with to == desk. The attacker tries to replay it
        // through a DIFFERENT contract (to == attackerDesk) - signature covers
        // `to`, so it fails the EIP-712 recover.
        PossessioAutoTarget attackerDesk = new PossessioAutoTarget(address(usdc), address(heart), keeper, FEE);
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("n1"));
        vm.prank(attacker);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        attackerDesk.openIntent(tokenRef, CHAIN, 1e18, 2500, a); // to would be attackerDesk, sig was for desk
    }

    function test_nonce_replay_burns() public {
        _open(2500, keccak256("dup"));
        // same nonce again -> EIP-3009 marks it used
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("dup"));
        vm.prank(user);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        desk.openIntent(tokenRef, CHAIN, 1e18, 2500, a);
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 5 - ROGUE KEEPER MOVES NO FUNDS
    //////////////////////////////////////////////////////////////*/

    function test_rogue_keeper_cannot_drain() public {
        _open(2500, keccak256("n1"));
        // The contract holds zero traded token and zero USDC (fee already swept).
        // The keeper's ONLY power is resolveIntent -> an event. Assert no fund
        // surface exists: balances are zero and no transfer path is keeper-gated.
        assertEq(usdc.balanceOf(address(desk)), 0, "no USDC to drain");
        // keeper resolving just emits; it cannot specify a recipient or amount.
        uint256 id = 1;
        vm.prank(keeper);
        desk.resolveIntent(id, 2e18);
        assertEq(usdc.balanceOf(address(desk)), 0, "still zero after resolve");
        assertEq(usdc.balanceOf(keeper), 0, "keeper gained nothing");
    }

    /*//////////////////////////////////////////////////////////////
        TERMINAL-STATE + UNKNOWN-INTENT HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_resolve_unknown_intent_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotOpen.selector, uint256(999)));
        desk.resolveIntent(999, 2e18);
    }

    function test_cancel_unknown_intent_reverts() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.UnknownIntent.selector, uint256(999)));
        desk.cancelIntent(999);
    }

    function test_cancel_after_resolve_reverts() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 2e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotOpen.selector, id));
        desk.cancelIntent(id);
    }

    /*//////////////////////////////////////////////////////////////
        EXECUTION-CLOSE AUTHORITY + LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_non_keeper_cannot_mark_executed() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 2e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.NotKeeper.selector, attacker));
        desk.markExecuted(id, 999);
    }

    function test_cannot_mark_open_intent() public {
        uint256 id = _open(2500, keccak256("n1")); // Open, not Resolved
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotResolved.selector, id));
        desk.markExecuted(id, 999);
    }

    function test_double_mark_executed_reverts() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 2e18);
        vm.prank(keeper);
        desk.markExecuted(id, 999);
        vm.prank(keeper); // Executed is terminal
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotResolved.selector, id));
        desk.markExecuted(id, 999);
    }

    function test_cannot_mark_cancelled_intent() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(user);
        desk.cancelIntent(id);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotResolved.selector, id));
        desk.markExecuted(id, 999);
    }

    function test_cannot_cancel_after_executed() public {
        uint256 id = _open(2500, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 2e18);
        vm.prank(keeper);
        desk.markExecuted(id, 999);
        vm.prank(user); // Executed is terminal - the human can no longer cancel
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotOpen.selector, id));
        desk.cancelIntent(id);
    }

    /*//////////////////////////////////////////////////////////////
        CONSTRUCTOR GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejects_zero() public {
        vm.expectRevert(PossessioAutoTarget.ZeroAddress.selector);
        new PossessioAutoTarget(address(0), address(heart), keeper, FEE);
        vm.expectRevert(PossessioAutoTarget.ZeroAddress.selector);
        new PossessioAutoTarget(address(usdc), address(0), keeper, FEE);
        vm.expectRevert(PossessioAutoTarget.ZeroAddress.selector);
        new PossessioAutoTarget(address(usdc), address(heart), address(0), FEE);
        vm.expectRevert(PossessioAutoTarget.ZeroFee.selector);
        new PossessioAutoTarget(address(usdc), address(heart), keeper, 0);
    }
}

contract GoodHeart {
    MockEIP3009USDC public immutable usdc;
    uint256 public received;

    constructor(address _usdc) {
        usdc = MockEIP3009USDC(_usdc);
    }

    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract RevertingHeart {
    function receiveInfraFunds(uint256) external pure {
        revert("Heart down");
    }
}
