// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {MockEIP3009USDC} from "./X402TestnetMocks.sol";

/// @notice DoD suite for PossessioAutoTarget (SPEC_AutoTarget.md §8).
///         Uses the shared MockEIP3009USDC so the same EIP-712 signing path
///         runs unchanged against real Base USDC in the fork suite.
contract PossessioAutoTargetTest is Test {
    PossessioAutoTarget internal desk;
    MockEIP3009USDC internal usdc;
    MockHeart internal heart;

    uint256 internal constant FEE = 20_000; // $0.02 in 6-dec USDC
    uint32 internal constant CHAIN = 8453; // Base (EVM rail) for these unit tests
    address internal keeper;
    bytes32 internal tokenRef; // the picked token, chain-agnostic (padded EVM addr here)

    uint256 internal userPk = 0xA11CE;
    address internal user;

    function setUp() public {
        user = vm.addr(userPk);
        keeper = makeAddr("keeper");
        tokenRef = bytes32(uint256(uint160(makeAddr("pickedToken"))));
        usdc = new MockEIP3009USDC();
        heart = new MockHeart(address(usdc));
        desk = new PossessioAutoTarget(address(usdc), address(heart), keeper, FEE);
        usdc.mint(user, 1_000_000); // $1 of fees available
    }

    /*//////////////////////////////////////////////////////////////
                        EIP-3009 SIGNING HELPER
    //////////////////////////////////////////////////////////////*/

    function _sign(uint256 pk, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (PossessioAutoTarget.FeeAuth memory a)
    {
        a.validAfter = 0;
        a.validBefore = type(uint256).max;
        a.nonce = nonce;
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                vm.addr(pk),
                to,
                value,
                a.validAfter,
                a.validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    function _open(uint16 targetBps, uint256 entryPrice, bytes32 nonce) internal returns (uint256 id) {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, nonce);
        vm.prank(user);
        id = desk.openIntent(tokenRef, CHAIN, entryPrice, targetBps, a);
    }

    /*//////////////////////////////////////////////////////////////
                        DoD #1 - OPEN AT EACH BUTTON
    //////////////////////////////////////////////////////////////*/

    function test_open_each_target_button() public {
        uint256 id10 = _open(1000, 1e18, keccak256("n1"));
        uint256 id25 = _open(2500, 1e18, keccak256("n2"));
        uint256 id50 = _open(5000, 1e18, keccak256("n3"));

        assertEq(desk.getIntent(id10).targetBps, 1000, "target +10");
        assertEq(desk.getIntent(id25).targetBps, 2500, "target +25");
        assertEq(desk.getIntent(id50).targetBps, 5000, "target +50");
        assertEq(desk.intentCount(), 3, "three intents");
    }

    function test_open_rejects_bad_target() public {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("bad"));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.BadTarget.selector, uint16(3000)));
        desk.openIntent(tokenRef, CHAIN, 1e18, 3000, a);
    }

    /*//////////////////////////////////////////////////////////////
        MULTI-CHAIN: one Base ledger records tokens from any chain
    //////////////////////////////////////////////////////////////*/

    function test_records_tokenref_and_chaintag() public {
        // a Solana mint (32-byte pubkey) tagged as Solana — recorded verbatim.
        bytes32 solMint = keccak256("So11111111111111111111111111111111111111112");
        uint32 solChain = desk.CHAIN_SOLANA(); // cache BEFORE prank (arg-eval consumes it)
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("sol"));
        vm.prank(user);
        uint256 id = desk.openIntent(solMint, solChain, 1e18, 2500, a);

        PossessioAutoTarget.Intent memory it = desk.getIntent(id);
        assertEq(it.tokenRef, solMint, "solana mint recorded verbatim");
        assertEq(uint256(it.chainTag), uint256(solChain), "chain tag = Solana");
    }

    function test_open_rejects_zero_tokenref() public {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("z1"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroTokenRef.selector);
        desk.openIntent(bytes32(0), CHAIN, 1e18, 2500, a);
    }

    function test_open_rejects_zero_chaintag() public {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("z2"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroChainTag.selector);
        desk.openIntent(tokenRef, 0, 1e18, 2500, a);
    }

    /*//////////////////////////////////////////////////////////////
              DoD #2 - STOP ALWAYS 1000, REGARDLESS OF TARGET
    //////////////////////////////////////////////////////////////*/

    function test_stop_always_ten_percent() public {
        uint256 id = _open(5000, 1e18, keccak256("n1")); // +50% target
        assertEq(desk.getIntent(id).stopBps, 1000, "stop is 10% even on +50 target");
        assertEq(desk.STOP_BPS(), 1000, "constant");
        assertEq(desk.stopPrice(id), 0.9e18, "stop price = entry*0.9");
    }

    /*//////////////////////////////////////////////////////////////
              DoD #3 - FEE SETTLES + ROUTES TO THE HEART
    //////////////////////////////////////////////////////////////*/

    function test_fee_routes_into_heart() public {
        _open(2500, 1e18, keccak256("n1"));
        assertEq(heart.received(), FEE, "Heart credited the exact fee");
        assertEq(usdc.balanceOf(address(heart)), FEE, "Heart holds the fee");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #4 - NON-CUSTODIAL: contract holds nothing after open
    //////////////////////////////////////////////////////////////*/

    function test_non_custodial_zero_balance() public {
        _open(1000, 1e18, keccak256("n1"));
        assertEq(usdc.balanceOf(address(desk)), 0, "desk holds no USDC");
        assertEq(usdc.allowance(address(desk), address(heart)), 0, "no residual allowance");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #5 - RESOLVE: target above / stop below / gap between
    //////////////////////////////////////////////////////////////*/

    function test_resolve_target_fires_above() public {
        uint256 id = _open(2500, 1e18, keccak256("n1")); // target 1.25e18
        vm.prank(keeper);
        desk.resolveIntent(id, 1.30e18);
        assertEq(uint256(desk.getIntent(id).status), uint256(PossessioAutoTarget.Status.Resolved), "resolved");
        assertEq(uint256(desk.getIntent(id).exitKind), uint256(PossessioAutoTarget.ExitKind.Target), "target hit");
    }

    function test_resolve_stop_fires_below() public {
        uint256 id = _open(5000, 1e18, keccak256("n1")); // stop 0.9e18
        vm.prank(keeper);
        desk.resolveIntent(id, 0.85e18);
        assertEq(uint256(desk.getIntent(id).exitKind), uint256(PossessioAutoTarget.ExitKind.Stop), "stop hit");
    }

    function test_resolve_reverts_between() public {
        uint256 id = _open(2500, 1e18, keccak256("n1")); // target 1.25, stop 0.9
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioAutoTarget.NotTriggered.selector, uint256(1.10e18), uint256(1.25e18), uint256(0.9e18))
        );
        desk.resolveIntent(id, 1.10e18);
    }

    function test_resolve_target_exact_boundary() public {
        uint256 id = _open(2500, 1e18, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 1.25e18); // exactly at target -> fires
        assertEq(uint256(desk.getIntent(id).exitKind), uint256(PossessioAutoTarget.ExitKind.Target), "boundary inclusive");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #6 - CANCEL by owner only; terminal-state re-entry
    //////////////////////////////////////////////////////////////*/

    function test_cancel_by_owner() public {
        uint256 id = _open(1000, 1e18, keccak256("n1"));
        vm.prank(user);
        desk.cancelIntent(id);
        assertEq(uint256(desk.getIntent(id).status), uint256(PossessioAutoTarget.Status.Cancelled), "cancelled");
    }

    function test_resolve_after_cancel_reverts() public {
        uint256 id = _open(1000, 1e18, keccak256("n1"));
        vm.prank(user);
        desk.cancelIntent(id);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotOpen.selector, id));
        desk.resolveIntent(id, 2e18);
    }

    function test_double_resolve_reverts() public {
        uint256 id = _open(1000, 1e18, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 1.2e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotOpen.selector, id));
        desk.resolveIntent(id, 1.2e18);
    }

    /*//////////////////////////////////////////////////////////////
        DoD #7 - EXECUTION CLOSE: opened -> authorized -> executed
    //////////////////////////////////////////////////////////////*/

    function test_mark_executed_closes_lifecycle() public {
        uint256 id = _open(2500, 1e18, keccak256("n1"));
        vm.prank(keeper);
        desk.resolveIntent(id, 1.30e18); // target authorized

        vm.prank(keeper);
        desk.markExecuted(id, 1_250_000); // keeper reports the off-chain swap proceeds

        PossessioAutoTarget.Intent memory it = desk.getIntent(id);
        assertEq(uint256(it.status), uint256(PossessioAutoTarget.Status.Executed), "executed terminal");
        assertEq(it.usdcReturned, 1_250_000, "proceeds recorded on-chain (receipt)");
        assertEq(uint256(it.exitKind), uint256(PossessioAutoTarget.ExitKind.Target), "exit kind preserved");
        // still non-custodial: the close moved no funds.
        assertEq(usdc.balanceOf(address(desk)), 0, "desk holds no USDC");
    }

    function test_mark_executed_requires_resolved_first() public {
        uint256 id = _open(2500, 1e18, keccak256("n1")); // still Open
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PossessioAutoTarget.IntentNotResolved.selector, id));
        desk.markExecuted(id, 1_250_000);
    }
}

/// @notice Minimal Heart stand-in: an authorized-source pull door that credits
///         `received`, exactly like PossessioPool.receiveInfraFunds pulls.
contract MockHeart {
    MockEIP3009USDC public immutable usdc;
    uint256 public received;

    constructor(address _usdc) {
        usdc = MockEIP3009USDC(_usdc);
    }

    function isInfraSink() external pure returns (bool) { return true; }

    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}
