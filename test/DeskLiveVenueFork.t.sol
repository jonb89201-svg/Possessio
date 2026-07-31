// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice THE VENUE QUESTION, SETTLED. Does the V2 desk actually round-trip a
///         real asset through the REAL SwapRouter02 against LIVE Base pool
///         state? Not "is there a pool", not "does a quoter answer" — does
///         Rail.enter buy and Rail.exit sell, with proceeds landing home in the
///         vault.
///
///         Scoped asset: SOL on Base (0x3119...cf82, 9 decimals). The Rail takes
///         `poolFee` as a KEEPER ARGUMENT, so no code change is needed to target
///         whichever tier holds the liquidity — this suite proves which one does
///         by executing against it.
///
///         Gated on BASE_RPC_URL (skips cleanly when unset). RUN:
///           BASE_RPC_URL=https://mainnet.base.org \
///           forge test --match-contract DeskLiveVenueForkTest -vv
interface IUSDCLike {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract DeskLiveVenueForkTest is Test {
    address internal constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant SOL    = 0x311935Cd80B76769bF2ecC9D8Ab7635b2139cf82; // 9 decimals
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

    bytes32 internal constant RECEIVE_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    uint256 internal constant FEE  = 20_000;        // $0.02
    uint256 internal constant SIZE = 100_000_000;   // $100 per trade

    PossessioAutoTarget   internal desk;
    PossessioFundingVault internal vault;
    PossessioRail         internal rail;

    address internal tollSink;
    address internal keeper;
    address internal owner;
    uint256 internal userPk;
    address internal user;
    bool    internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        (user, userPk) = makeAddrAndKey("desk-venue-user");
        keeper   = makeAddr("venue-keeper");
        tollSink = makeAddr("venue-tollsink"); // EOA: code.length 0, guard skips
        owner    = address(this);

        // V2 AutoTarget: plain-push fee to an EOA toll sink.
        desk = new PossessioAutoTarget(USDC, tollSink, keeper, FEE);

        // The prewire: the vault must be born holding the Rail's address. The
        // Rail is the NEXT-but-one CREATE from this test contract.
        address predictedRail = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new PossessioFundingVault(
            IERC20(USDC), owner, predictedRail, predictedRail,
            3_500_000_000, 10_000_000_000, 20_000_000_000
        );
        rail = new PossessioRail(
            IERC20(USDC),
            IFundingVault(address(vault)),
            IAutoTarget(address(desk)),
            keeper,
            ISwapRouter(ROUTER)
        );
        assertEq(address(rail), predictedRail, "prewire: rail landed where the vault expects");

        // Fund the vault with real USDC.
        deal(USDC, owner, 1_000_000_000);
        IUSDCLike(USDC).approve(address(vault), type(uint256).max);
        vault.fund(1_000_000_000); // $1,000

        // The intent opener pays the toll.
        deal(USDC, user, 1_000_000);
    }

    function _requireFork() internal {
        if (!forked) vm.skip(true);
    }

    function _sign(uint256 pk, address to, uint256 value, bytes32 nonce)
        internal view returns (PossessioAutoTarget.FeeAuth memory a)
    {
        a.validAfter  = 0;
        a.validBefore = type(uint256).max;
        a.nonce       = nonce;
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, vm.addr(pk), to, value, a.validAfter, a.validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IUSDCLike(USDC).DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    /// The whole question in one test: open -> buy SOL -> resolve -> sell -> home.
    function test_fork_SOL_round_trips_through_live_router() public {
        _requireFork();

        // 1. Open an intent for SOL. This is the call V1 could never make.
        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("venue-n1"));
        vm.prank(user);
        uint256 id = desk.openIntent(bytes32(uint256(uint160(SOL))), 8453, 1e18, 2500, a);
        assertEq(IUSDCLike(USDC).balanceOf(tollSink), FEE, "toll landed at the sink");

        // 2. Probe the live fill, then REPLAY the buy against a floor derived
        //    from it. Amendment VIII: minTokenOut = 1 would let this pass
        //    without ever reaching the slippage logic (a False Green). The
        //    probe/replay keeps the floor MEANINGFUL and price-independent —
        //    it never hardcodes a SOL price that would go stale.
        uint256 vaultBefore = IUSDCLike(USDC).balanceOf(address(vault));
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        rail.enter(id, SOL, SIZE, 1, 3000);
        uint256 probe = IERC20(SOL).balanceOf(address(rail));
        vm.revertToState(snap);

        uint256 floorOut = (probe * 99) / 100; // 1% below the observed fill
        vm.prank(keeper);
        rail.enter(id, SOL, SIZE, floorOut, 3000); // 0.3% tier, real floor
        uint256 solHeld = IERC20(SOL).balanceOf(address(rail));
        emit log_named_uint("SOL bought (9dp)", solHeld);
        emit log_named_uint("minTokenOut enforced", floorOut);
        emit log_named_uint("USDC spent", vaultBefore - IUSDCLike(USDC).balanceOf(address(vault)));
        assertGe(solHeld, floorOut, "fill honoured the enforced slippage floor");

        // 3. Authorise the exit through the rule engine (target crossed).
        vm.prank(keeper);
        desk.resolveIntent(id, 1.30e18); // entry 1.0, target +25% -> 1.25

        // 4. SELL against a real floor too: a USDC->SOL->USDC round trip that
        //    returns under 90% of the draw is a broken venue, not a trade.
        vm.prank(keeper);
        rail.exit(id, (SIZE * 90) / 100, 3000);
        uint256 back = IUSDCLike(USDC).balanceOf(address(vault));
        uint256 recovered = back + SIZE - vaultBefore; // proceeds credited home
        emit log_named_uint("USDC home in vault", back);
        emit log_named_uint("round-trip recovered", recovered);

        assertEq(IERC20(SOL).balanceOf(address(rail)), 0, "rail holds no SOL after exit");
        // Quantitative, not "greater than zero": two 0.3% pool fees plus real
        // slippage should cost well under 3% on this size.
        assertGe(recovered, (SIZE * 97) / 100, "round trip cost stayed under 3%");
        assertLe(recovered, (SIZE * 103) / 100, "no impossible gain: sanity bound");
        // The accounting closed, not just the token movement.
        assertEq(vault.outstanding(), 0, "vault outstanding cleared by returnProceeds");
    }

    /// The floor must REJECT, not merely be carried. Without this, the buy
    /// assertion above only proves a number was passed through.
    function test_fork_slippage_floor_rejects_an_unreachable_minimum() public {
        _requireFork();

        PossessioAutoTarget.FeeAuth memory a = _sign(userPk, address(desk), FEE, keccak256("venue-n2"));
        vm.prank(user);
        uint256 id = desk.openIntent(bytes32(uint256(uint160(SOL))), 8453, 1e18, 2500, a);

        // Observe the honest fill, roll back, then demand twice it.
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        rail.enter(id, SOL, SIZE, 1, 3000);
        uint256 probe = IERC20(SOL).balanceOf(address(rail));
        vm.revertToState(snap);

        vm.prank(keeper);
        vm.expectRevert(); // router refuses: amountOut < amountOutMinimum
        rail.enter(id, SOL, SIZE, probe * 2, 3000);

        // And the failed attempt left nothing behind.
        assertEq(IERC20(SOL).balanceOf(address(rail)), 0, "no token held after a rejected buy");
        assertEq(vault.outstanding(), 0, "no draw outstanding after a rejected buy");
    }
}
