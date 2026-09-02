// SPDX-License-Identifier: MIT
// DoD suite for PossessioRail (SPEC_RailAndKeeper.md §8).
// Deploy order note: the vault's `trader`/`tradeDestination` are immutable and
// must equal the Rail — so we PREDICT the Rail's CREATE address, deploy the vault
// pointed at it, then deploy the Rail into that slot (the "ship prewired" pattern).
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin","USDC") {}
    function decimals() public pure override returns (uint8){ return 6; }
    function mint(address to, uint256 a) external { _mint(to,a); }
}
contract MockToken is ERC20 {
    constructor() ERC20("Meme","MEME") {}
    function mint(address to, uint256 a) external { _mint(to,a); }
}
/// @dev Honeypot: the buy (a plain `transfer` from the router to the Rail)
///      succeeds, but every SELL — the router pulling via `transferFrom` — reverts.
///      Models a token that can be bought but never sold, the case `abandon` exists for.
contract HoneypotToken is ERC20 {
    constructor() ERC20("Honeypot","HONEY") {}
    function mint(address to, uint256 a) external { _mint(to,a); }
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("HONEYPOT: no sell");
    }
}

/// @dev AutoTarget stand-in: exposes the flattened `intents` getter the Rail
///      reads. Test controls token/chainTag/status. Status: 1=Open,2=Resolved.
contract MockAutoTarget {
    struct I { address user; bytes32 ownerRef; bytes32 tokenRef; uint32 chainTag; uint256 entryPrice; uint16 targetBps; uint16 stopBps; uint8 status; uint8 exitKind; uint256 usdcReturned; }
    mapping(uint256 => I) internal _i;
    function setIntent(uint256 id, address token, uint32 chainTag, uint8 status) external {
        _i[id] = I(address(0), bytes32(0), bytes32(uint256(uint160(token))), chainTag, 1e18, 2500, 1000, status, 0, 0);
    }
    function setStatus(uint256 id, uint8 status) external { _i[id].status = status; }
    function intents(uint256 id) external view returns (address,bytes32,bytes32,uint32,uint256,uint16,uint16,uint8,uint8,uint256) {
        I memory x = _i[id]; return (x.user,x.ownerRef,x.tokenRef,x.chainTag,x.entryPrice,x.targetBps,x.stopBps,x.status,x.exitKind,x.usdcReturned);
    }
}

/// @dev DEX stand-in: pulls amountIn from the caller, sends a test-set `nextOut`
///      of tokenOut from its own (pre-funded) reserve to the recipient.
contract MockSwapRouter {
    uint256 public nextOut;
    function setOut(uint256 o) external { nextOut = o; }
    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 out = nextOut;
        require(out >= p.amountOutMinimum, "slippage");
        IERC20(p.tokenOut).transfer(p.recipient, out);
        return out;
    }
    /// @dev Multi-hop mock: the Rail builds the path, so the mock only needs the
    ///      ends — first 20 bytes tokenIn, last 20 bytes tokenOut. Records the
    ///      exact path bytes so tests can assert the ROUTE the Rail assembled.
    bytes public lastPath;
    function exactInput(ISwapRouter.ExactInputParams calldata p) external returns (uint256) {
        lastPath = p.path;
        address tIn;  address tOut;
        bytes memory path = p.path;
        require(path.length >= 43, "bad path");
        assembly {
            tIn := shr(96, mload(add(path, 32)))
            tOut := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        IERC20(tIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 out = nextOut;
        require(out >= p.amountOutMinimum, "slippage");
        IERC20(tOut).transfer(p.recipient, out);
        return out;
    }
}

contract PossessioRailTest is Test {
    uint256 internal constant MIN_SETTLE_BPS = 0; // R-H1 floor OFF here: this suite proves pre-existing behaviour; the floor is proven in PossessioRailAdversarial
    MockUSDC usdc; MockToken token; MockToken weth; MockSwapRouter router; MockAutoTarget at;
    address remoteAgent = makeAddr("remoteAgent");
    uint256 constant REMOTE_TIMEOUT = 24 hours;
    PossessioFundingVault vault; PossessioRail rail;

    address owner  = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address rando  = makeAddr("rando");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;
    uint24  constant FEE = 3000;

    function setUp() public {
        usdc = new MockUSDC(); token = new MockToken(); weth = new MockToken(); router = new MockSwapRouter(); at = new MockAutoTarget();
        // predict the Rail's address (next-next CREATE) and pin the vault to it
        uint256 n = vm.getNonce(address(this));
        address predictedRail = vm.computeCreateAddress(address(this), n + 1);
        vault = new PossessioFundingVault(IERC20(address(usdc)), owner, predictedRail, predictedRail, MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP);
        rail  = new PossessioRail(IERC20(address(usdc)), IFundingVault(address(vault)), IAutoTarget(address(at)), keeper, ISwapRouter(address(router)), address(weth), remoteAgent, REMOTE_TIMEOUT, MIN_SETTLE_BPS);
        vm.prank(owner); rail.setRouteAllowed(address(token), false, FEE, 0, true);   // R-H1 route whitelist
        assertEq(address(rail), predictedRail, "prewire prediction");
        // fund the vault; pre-fund the router with both sides so it can pay out
        usdc.mint(owner, 10_000e6);
        vm.startPrank(owner); usdc.approve(address(vault), 10_000e6); vault.fund(10_000e6); vm.stopPrank();
        token.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    function _openIntent(uint256 id, uint8 status) internal { at.setIntent(id, address(token), 8453, status); }

    // ─────────────────────────── enter ─────────────────────────────────────

    function test_enter_drawsWithinCaps_andBuys() public {
        _openIntent(1, 1); // Open
        router.setOut(500e18); // 3,000 USDC -> 500 MEME
        vm.prank(keeper);
        rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);

        (address t, uint256 usdcIn, uint256 tokenAmt, PossessioRail.Status st) = rail.getPosition(1);
        assertEq(t, address(token)); assertEq(usdcIn, 3_000e6); assertEq(tokenAmt, 500e18);
        assertEq(uint8(st), uint8(PossessioRail.Status.Open));
        assertEq(vault.outstanding(), 3_000e6);              // vault drew exactly
        assertEq(usdc.balanceOf(address(vault)), 7_000e6);   // USDC left the vault
        assertEq(token.balanceOf(address(rail)), 500e18);    // Rail holds the position
    }

    function test_enter_onlyKeeper() public {
        _openIntent(1, 1);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotKeeper.selector);
        rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
    }

    function test_enter_overPerTradeCap_reverts_noPosition() public {
        _openIntent(1, 1);
        vm.prank(keeper);
        vm.expectRevert(PossessioFundingVault.PerTradeCapExceeded.selector); // the vault's cap bites
        rail.enter(1, address(token), MAX_PER_TRADE + 1, 1e18, false, FEE, 0);
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.None));
        assertEq(vault.outstanding(), 0);
    }

    function test_enter_wrongChain_reverts() public {
        at.setIntent(1, address(token), 101, 1); // Solana-tagged
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.WrongChain.selector);
        rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
    }

    function test_enter_tokenMismatch_reverts() public {
        _openIntent(1, 1); // intent authored for `token`
        MockToken other = new MockToken();
        vm.prank(owner); rail.setRouteAllowed(address(other), false, FEE, 0, true);   // R-H1
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.TokenMismatch.selector);
        rail.enter(1, address(other), 3_000e6, 1e18, false, FEE, 0);
    }

    function test_enter_intentNotOpen_reverts() public {
        _openIntent(1, 2); // already Resolved, not Open
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.IntentNotOpen.selector);
        rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
    }

    function test_enter_reuseId_reverts() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 1_000e6, 1e18, false, FEE, 0);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.PositionExists.selector);
        rail.enter(1, address(token), 1_000e6, 1e18, false, FEE, 0);
    }

    // ─────────────────── exit — rule-gated + round-trip ────────────────────

    function test_exit_blockedUntilResolved() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        // intent still Open -> exit must be refused
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.ExitNotAuthorized.selector);
        rail.exit(1, 1);
    }

    function test_exit_profit_returnsToVault_pnlPositive() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        at.setStatus(1, 2); // AutoTarget authorizes the exit (target/stop crossed)
        router.setOut(3_600e6); // 500 MEME -> 3,600 USDC (profit)
        vm.expectEmit(true, false, false, true, address(rail));
        emit PossessioRail.Exited(1, 3_600e6, int256(600e6));
        vm.prank(keeper); rail.exit(1, 1);

        assertEq(vault.outstanding(), 0);                          // exposure cleared
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 3_600e6); // war chest grew
        assertEq(token.balanceOf(address(rail)), 0);              // token sold
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.Closed));
    }

    function test_exit_loss_returnsToVault_pnlNegative() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        at.setStatus(1, 2);
        router.setOut(2_000e6); // sold at a loss
        vm.expectEmit(true, false, false, true, address(rail));
        emit PossessioRail.Exited(1, 2_000e6, -int256(1_000e6));
        vm.prank(keeper); rail.exit(1, 1);
        assertEq(vault.outstanding(), 0);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 2_000e6);
    }

    function test_exit_onlyKeeper() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        at.setStatus(1, 2);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotKeeper.selector);
        rail.exit(1, 1);
    }

    function test_exit_terminal_cannotReExit() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        at.setStatus(1, 2); router.setOut(3_600e6);
        vm.prank(keeper); rail.exit(1, 1);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.PositionNotOpen.selector);
        rail.exit(1, 1);
    }

    // ─────────────────────────── ownerExit ─────────────────────────────────

    function test_ownerExit_closesWithoutResolution() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        // intent STILL Open (no keeper resolution) — the owner can still bail
        router.setOut(2_500e6);
        vm.expectEmit(true, false, false, true, address(rail));
        emit PossessioRail.OwnerExited(1, 2_500e6, -int256(500e6));
        vm.prank(owner); rail.ownerExit(1, 1);
        assertEq(vault.outstanding(), 0);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6 + 2_500e6);
    }

    function test_ownerExit_onlyOwner() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.ownerExit(1, 1);
    }

    // ─────────────────────────── sweep ─────────────────────────────────────

    function test_sweep_rescuesStrayToken_ownerOnly() public {
        MockToken stray = new MockToken(); stray.mint(address(rail), 42e18);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.sweep(address(stray));
        vm.prank(owner); rail.sweep(address(stray));
        assertEq(stray.balanceOf(owner), 42e18);
    }

    function test_sweep_cannotTakeUSDC() public {
        vm.prank(owner);
        vm.expectRevert(PossessioRail.ProtectedToken.selector);
        rail.sweep(address(usdc));
    }

    function test_sweep_blockedWhileTokenBacksOpenPosition() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        // the position token is live — sweeping it would strip the exit inventory
        assertEq(rail.openByToken(address(token)), 1);
        vm.prank(owner);
        vm.expectRevert(PossessioRail.TokenBacksOpenPosition.selector);
        rail.sweep(address(token));
        // after a clean exit the guard releases
        at.setStatus(1, 2); router.setOut(3_600e6);
        vm.prank(keeper); rail.exit(1, 1);
        assertEq(rail.openByToken(address(token)), 0);
        vm.prank(owner); rail.sweep(address(token)); // no revert
    }

    // ─────────────── abandon — the un-sellable (honeypot) escape ─────────────

    /// @dev Sets up an Open position in a token that cannot be sold, and returns
    ///      the honeypot handle. 3,000 USDC drawn -> 500 HONEY bought.
    function _openHoneypot(uint256 id) internal returns (HoneypotToken hp) {
        hp = new HoneypotToken();
        hp.mint(address(router), 1_000_000e18); // router can pay out the buy
        at.setIntent(id, address(hp), 8453, 1);  // Open, Base-tagged
        router.setOut(500e18);
        vm.prank(owner); rail.setRouteAllowed(address(hp), false, FEE, 0, true);   // R-H1
        vm.prank(keeper); rail.enter(id, address(hp), 3_000e6, 1e18, false, FEE, 0);
    }

    function test_ownerExit_revertsOnHoneypot_provingTheTrap() public {
        _openHoneypot(1);
        // The documented "always force-close" bail runs the mandatory swap, which
        // the honeypot blocks — so ownerExit CANNOT close it. This is why abandon exists.
        vm.prank(owner);
        vm.expectRevert(bytes("HONEYPOT: no sell"));
        rail.ownerExit(1, 1);
        assertEq(vault.outstanding(), 3_000e6); // still stuck without abandon
    }

    function test_abandon_closesUnsellablePosition_clearsOutstanding() public {
        HoneypotToken hp = _openHoneypot(1);
        assertEq(vault.outstanding(), 3_000e6);
        assertEq(rail.openByToken(address(hp)), 1);

        vm.expectEmit(true, true, false, true, address(rail));
        emit PossessioRail.Abandoned(1, address(hp), 500e18);
        vm.prank(owner); rail.abandon(1);

        // exposure cleared WITHOUT any swap or USDC movement
        assertEq(vault.outstanding(), 0);
        assertEq(rail.openByToken(address(hp)), 0);
        (, , , PossessioRail.Status st) = rail.getPosition(1);
        assertEq(uint8(st), uint8(PossessioRail.Status.Closed));
        assertEq(usdc.balanceOf(address(vault)), 7_000e6); // no proceeds returned; loss realized
        // vault can draw again against the freed cap
        assertEq(vault.maxOutstanding() - vault.outstanding(), MAX_OUTSTANDING);
    }

    function test_abandon_onlyOwner() public {
        _openHoneypot(1);
        vm.prank(keeper);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.abandon(1);
        vm.prank(rando);
        vm.expectRevert(PossessioRail.NotOwner.selector);
        rail.abandon(1);
    }

    function test_abandon_requiresOpenPosition() public {
        _openHoneypot(1);
        vm.prank(owner); rail.abandon(1);
        vm.prank(owner);
        vm.expectRevert(PossessioRail.PositionNotOpen.selector);
        rail.abandon(1); // already Closed
    }

    function test_abandon_cannotAbandonAfterCleanExit() public {
        _openIntent(1, 1); router.setOut(500e18);
        vm.prank(keeper); rail.enter(1, address(token), 3_000e6, 1e18, false, FEE, 0);
        at.setStatus(1, 2); router.setOut(3_600e6);
        vm.prank(keeper); rail.exit(1, 1);
        vm.prank(owner);
        vm.expectRevert(PossessioRail.PositionNotOpen.selector);
        rail.abandon(1);
    }

    function test_abandon_thenSweepRecoversDeadToken() public {
        HoneypotToken hp = _openHoneypot(1);
        vm.prank(owner); rail.abandon(1);
        // the worthless token is now sweepable (position Closed, guard released)
        assertEq(rail.openByToken(address(hp)), 0);
        uint256 stuck = hp.balanceOf(address(rail));
        assertEq(stuck, 500e18);
        vm.prank(owner); rail.sweep(address(hp));
        assertEq(hp.balanceOf(owner), stuck);
    }
}
