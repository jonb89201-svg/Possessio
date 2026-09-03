// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {IAutoTarget} from "../src/PossessioRail.sol";
import {MockEIP3009USDC} from "./X402TestnetMocks.sol";

/// @notice DoD suite for PossessioAutoTarget (SPEC_AutoTarget.md §8).
///         Uses the shared MockEIP3009USDC so the same EIP-712 signing path
///         runs unchanged against real Base USDC in the fork suite.
contract PossessioAutoTargetTest is Test {
    PossessioAutoTarget internal desk;
    MockEIP3009USDC internal usdc;
    MockHeart internal heart;      // kept: proves V2 REJECTS an accounted pool as sink
    address internal tollSink;     // V2: the fee's plain-push destination

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
        tollSink = makeAddr("tollSink");
        desk = new PossessioAutoTarget(address(usdc), tollSink, keeper, FEE);
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
        id = desk.openIntent(tokenRef, bytes32(0), CHAIN, entryPrice, targetBps, a);
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
        desk.openIntent(tokenRef, bytes32(0), CHAIN, 1e18, 3000, a);
    }

    /*//////////////////////////////////////////////////////////////
        MULTI-CHAIN: one Base ledger records tokens from any chain
    //////////////////////////////////////////////////////////////*/

    /// A holder's Solana pubkey. Without it a Solana intent is unservable: the
    /// keeper derives the associated token account from (owner, mint), so an
    /// intent naming a mint but no owner names an account that cannot be found.
    bytes32 constant SOL_OWNER = keccak256("ARjf4vUNiU8cW6xXfBfiL8ibc5qC4pYim5mLxbe6uog5");

    function test_records_tokenref_and_chaintag() public {
        // a Solana mint (32-byte pubkey) tagged as Solana — recorded verbatim.
        bytes32 solMint = keccak256("So11111111111111111111111111111111111111112");
        uint32 solChain = desk.CHAIN_SOLANA(); // cache BEFORE prank (arg-eval consumes it)
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("sol"));
        vm.prank(user);
        uint256 id = desk.openIntent(solMint, SOL_OWNER, solChain, 1e18, 2500, a);

        PossessioAutoTarget.Intent memory it = desk.getIntent(id);
        assertEq(it.tokenRef, solMint, "solana mint recorded verbatim");
        assertEq(uint256(it.chainTag), uint256(solChain), "chain tag = Solana");
        assertEq(it.ownerRef, SOL_OWNER, "solana HOLDER recorded verbatim");
    }

    function test_open_rejects_zero_tokenref() public {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("z1"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroTokenRef.selector);
        desk.openIntent(bytes32(0), bytes32(0), CHAIN, 1e18, 2500, a);
    }

    function test_open_rejects_zero_chaintag() public {
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("z2"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroChainTag.selector);
        desk.openIntent(tokenRef, bytes32(0), 0, 1e18, 2500, a);
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
              DoD #3 - FEE SETTLES + PUSHES TO THE TOLL SINK (V2)
    //////////////////////////////////////////////////////////////*/

    function test_fee_pushes_to_tollSink() public {
        _open(2500, 1e18, keccak256("n1"));
        assertEq(usdc.balanceOf(tollSink), FEE, "toll sink holds the exact fee (plain push)");
    }

    /// V2 guard, inverted from V1: an accounted-pull pool (isInfraSink()==true)
    /// is REJECTED as the sink — a plain push there is uncredited dead weight.
    /// Any EOA or plain contract is accepted.
    function test_constructor_rejects_accountedPool_acceptsAnythingElse() public {
        vm.expectRevert(PossessioAutoTarget.TollSinkIsAccountedPool.selector);
        new PossessioAutoTarget(address(usdc), address(heart), keeper, FEE);
        // an EOA sink constructs fine…
        new PossessioAutoTarget(address(usdc), makeAddr("eoaSink"), keeper, FEE);
        // …and so does a plain contract without the pool marker (the mock token).
        new PossessioAutoTarget(address(usdc), address(usdc), keeper, FEE);
    }

    /// REGRESSION, measured on Base mainnet at block 49366683: the ratified
    /// operator `0x6cFE30CE…A69203` — an ERC-1967 proxy, i.e. a smart-contract
    /// wallet — COULD NOT BE DEPLOYED AGAINST. Its `isInfraSink()` probe does
    /// not revert; it SUCCEEDS and returns empty. Solidity's try/catch catches a
    /// revert but NOT a return-data decode failure, so the empty return bubbled
    /// uncaught and reverted the constructor with no revert data — the failure
    /// did not even name itself. The guard was written to exclude accounted
    /// pools and silently excluded every sink shaped like a modern operator
    /// wallet. The low-level staticcall keeps the intent and drops the class.
    function test_constructor_accepts_smartWalletSink() public {
        MockSmartWallet wallet = new MockSmartWallet();

        // First prove the mock reproduces the mainnet shape. Without this the
        // test could pass against a fixture that reverts, which is the case
        // that already worked — a green proving nothing.
        (bool ok, bytes memory ret) =
            address(wallet).staticcall(abi.encodeWithSignature("isInfraSink()"));
        assertTrue(ok, "probe must SUCCEED, not revert - that is the entire case");
        assertEq(ret.length, 0, "and must return EMPTY data");

        PossessioAutoTarget d =
            new PossessioAutoTarget(address(usdc), address(wallet), keeper, FEE);
        assertEq(d.feeSink(), address(wallet), "smart-wallet sink accepted");
    }

    /*//////////////////////////////////////////////////////////////
        THE RAIL'S VIEW OF THIS CONTRACT — positional tuple alignment
    //////////////////////////////////////////////////////////////*/

    /// REGRESSION. `IAutoTarget.intents()` is a POSITIONAL tuple and the Rail
    /// destructures it by slot. Adding `ownerRef` to Intent shifted every field
    /// after the first, and the ABI decoder does NOT revert when the callee
    /// returns MORE words than the caller declares — it silently reads the
    /// wrong ones. `Rail.enter()` then failed downstream on TokenMismatch, far
    /// from the cause.
    ///
    /// Nothing in the Rail's own suite could catch it: those tests drive a
    /// MockAutoTarget that declares its own struct, so mock and interface drift
    /// together and stay consistent with each other while both diverge from the
    /// real contract. Only a test binding the REAL interface to the REAL
    /// contract sees it. This is that test, at unit speed — the alternative was
    /// a fork test somebody may not run.
    function test_railInterface_tupleAlignsWithIntentStruct() public {
        uint256 id = _open(2500, 1e18, keccak256("railView"));

        // The Rail's interface, imported from PossessioRail.sol — not restated.
        (
            address user_, bytes32 ownerRef_, bytes32 tokenRef_, uint32 chainTag_,
            uint256 entryPrice_, uint16 targetBps_, uint16 stopBps_,
            uint8 status_, uint8 exitKind_, uint256 usdcReturned_
        ) = IAutoTarget(address(desk)).intents(id);

        PossessioAutoTarget.Intent memory it = desk.getIntent(id);

        assertEq(user_, it.user, "slot 0 user");
        assertEq(ownerRef_, it.ownerRef, "slot 1 ownerRef");
        assertEq(tokenRef_, it.tokenRef, "slot 2 tokenRef");
        assertEq(uint256(chainTag_), uint256(it.chainTag), "slot 3 chainTag");
        assertEq(entryPrice_, it.entryPrice, "slot 4 entryPrice");
        assertEq(uint256(targetBps_), uint256(it.targetBps), "slot 5 targetBps");
        assertEq(uint256(stopBps_), uint256(it.stopBps), "slot 6 stopBps");
        assertEq(uint256(status_), uint256(it.status), "slot 7 status");
        assertEq(uint256(exitKind_), uint256(it.exitKind), "slot 8 exitKind");
        assertEq(usdcReturned_, it.usdcReturned, "slot 9 usdcReturned");

        // The two the Rail actually gates on. If these drift, enter() binds to
        // the wrong token or refuses the right chain.
        assertEq(tokenRef_, bytes32(uint256(uint160(address(uint160(uint256(tokenRef)))))), "tokenRef readable as a token");
        assertEq(uint256(chainTag_), uint256(CHAIN), "chainTag is the authored chain");
        assertEq(uint256(status_), 1, "status reads as Open, not a shifted field");
    }

    /*//////////////////////////////////////////////////////////////
          ownerRef - the holder a Solana intent cannot be served without
    //////////////////////////////////////////////////////////////*/

    /// The keeper derives ONE associated token account per ruled position, from
    /// (owner, mint). A Solana intent naming a mint but no owner names an
    /// account that cannot be found, so it is refused at the door rather than
    /// recorded as a rule nothing can ever act on.
    function test_open_rejects_solana_intent_without_ownerRef() public {
        uint32 solChain = desk.CHAIN_SOLANA();
        PossessioAutoTarget.FeeAuth memory a =
            _sign(userPk, address(desk), FEE, keccak256("noOwner"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroOwnerRef.selector);
        desk.openIntent(keccak256("someMint"), bytes32(0), solChain, 1e18, 2500, a);
    }

    /// On Base the EVM `user` already IS the holder, so ownerRef is meaningless
    /// there and must stay optional - the guard is scoped to CHAIN_SOLANA only.
    function test_open_allows_base_intent_without_ownerRef() public {
        uint256 id = _open(2500, 1e18, keccak256("baseNoOwner"));
        assertEq(desk.getIntent(id).ownerRef, bytes32(0), "base intents carry no ownerRef");
    }

    /// The fee is charged BEFORE the intent is recorded, so a refused intent
    /// must not leave the caller poorer. Proves the ZeroOwnerRef revert unwinds
    /// the EIP-3009 settle with it.
    function test_rejected_solana_intent_refunds_nothing_and_charges_nothing() public {
        uint256 before = usdc.balanceOf(user);
        uint32 solChain = desk.CHAIN_SOLANA();
        PossessioAutoTarget.FeeAuth memory a =
            _sign(userPk, address(desk), FEE, keccak256("noOwner2"));
        vm.prank(user);
        vm.expectRevert(PossessioAutoTarget.ZeroOwnerRef.selector);
        desk.openIntent(keccak256("someMint"), bytes32(0), solChain, 1e18, 2500, a);
        assertEq(usdc.balanceOf(user), before, "a refused open costs the caller nothing");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #4 - NON-CUSTODIAL: contract holds nothing after open
    //////////////////////////////////////////////////////////////*/

    function test_non_custodial_zero_balance() public {
        _open(1000, 1e18, keccak256("n1"));
        assertEq(usdc.balanceOf(address(desk)), 0, "desk holds no USDC");
        assertEq(usdc.allowance(address(desk), tollSink), 0, "no allowance exists at all (plain push, no approve)");
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
    function isAuthorizedSource(address) external pure returns (bool) { return true; }

    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}


/// @notice A smart-contract wallet, ERC-1967-proxy shaped. An unknown selector
///         reaches the fallback, which returns SUCCESS with EMPTY data instead
///         of reverting. This is the Base Account's measured behaviour on Base
///         mainnet, and it is precisely what the V1 try/catch probe could not
///         survive.
contract MockSmartWallet {
    fallback() external payable {}
    receive() external payable {}
}
