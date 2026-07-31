// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

/// @notice Fork suite for PossessioAutoTarget (SPEC_AutoTarget.md §8).
///         Proves the money-path against the REAL Base USDC contract (real
///         EIP-712 domain, real receiveWithAuthorization) and a REAL-code
///         PossessioPool (the Heart): a signed per-tx fee opens an intent and
///         lands in the Heart's poolBalance, with the desk holding nothing.
///
///         Gated on BASE_RPC_URL (skips cleanly when unset, like
///         ConstellationCreate3Fork). RUN:
///           BASE_RPC_URL=https://mainnet.base.org \
///           forge test --match-contract PossessioAutoTargetForkTest -vv
interface IUSDCLike {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
}

contract PossessioAutoTargetForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base mainnet USDC

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    uint256 internal constant FEE = 20_000; // $0.02

    PossessioAutoTarget internal desk;
    PossessioPool internal heart;
    address internal tollSink; // V2 plain-push fee destination
    address internal keeper;
    uint32 internal constant CHAIN = 8453; // Base (EVM rail)
    bytes32 internal tokenRef;

    uint256 internal userPk;
    address internal user;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // skipped per-test via _requireFork
        vm.createSelectFork(rpc);
        forked = true;

        // A code-free EOA: real USDC (FiatTokenV2_2) routes signers WITH code
        // through EIP-1271, which rejects a plain ECDSA sig. makeAddrAndKey
        // gives a clean externally-owned signer.
        (user, userPk) = makeAddrAndKey("autotarget-user");
        keeper = makeAddr("keeper");
        tokenRef = bytes32(uint256(uint160(makeAddr("pickedToken"))));
        address operator = makeAddr("operator");
        address treasury = makeAddr("treasury");

        // V2: no circular wiring — the fee is a plain push to a TOLL_SINK
        // address, so the desk needs nothing from the Heart and the Heart
        // needs nothing from the desk. A real Pool is still deployed to prove
        // the constructor REJECTS it as a sink (the inverted V2 guard).
        address[] memory sources = new address[](1);
        sources[0] = makeAddr("someAuthorizedSource");
        heart = new PossessioPool(USDC, sources, operator, treasury, 1e18, 0, 0, 3600);
        tollSink = makeAddr("tollSink");
        desk = new PossessioAutoTarget(USDC, tollSink, keeper, FEE);

        deal(USDC, user, FEE); // fund the signer with real USDC on the fork
    }

    function _requireFork() internal {
        if (!forked) vm.skip(true);
    }

    function _signReal(uint256 pk, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (PossessioAutoTarget.FeeAuth memory a)
    {
        a.validAfter = 0;
        a.validBefore = type(uint256).max;
        a.nonce = nonce;
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, vm.addr(pk), to, value, a.validAfter, a.validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IUSDCLike(USDC).DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    /// @notice The whole money-path against real USDC: fee pushed to the sink.
    function test_fork_open_pushes_real_usdc_to_tollSink() public {
        _requireFork();

        uint256 sinkBefore = IUSDCLike(USDC).balanceOf(tollSink);

        PossessioAutoTarget.FeeAuth memory a = _signReal(userPk, address(desk), FEE, keccak256("fork-n1"));
        vm.prank(user);
        uint256 id = desk.openIntent(tokenRef, bytes32(0), CHAIN, 1e18, 2500, a);

        // Fee landed at the TOLL_SINK by plain push (Option B / R1 pattern).
        assertEq(IUSDCLike(USDC).balanceOf(tollSink) - sinkBefore, FEE, "real USDC reached the toll sink");

        // Non-custodial: the desk holds nothing.
        assertEq(IUSDCLike(USDC).balanceOf(address(desk)), 0, "desk holds no USDC");

        // Intent recorded with the un-removable stop.
        assertEq(desk.getIntent(id).stopBps, 1000, "stop always 10%");
        assertEq(desk.getIntent(id).user, user, "owner recorded");
    }

    /// @notice The keeper's mechanical exit fires on a real-fork intent.
    function test_fork_resolve_stop_fires() public {
        _requireFork();

        PossessioAutoTarget.FeeAuth memory a = _signReal(userPk, address(desk), FEE, keccak256("fork-n2"));
        vm.prank(user);
        uint256 id = desk.openIntent(tokenRef, bytes32(0), CHAIN, 1e18, 5000, a); // +50% target, -10% stop

        vm.prank(keeper);
        desk.resolveIntent(id, 0.80e18); // crater -> stop
        assertEq(uint256(desk.getIntent(id).exitKind), uint256(PossessioAutoTarget.ExitKind.Stop), "stop fired on fork");
    }
}
