// SPDX-License-Identifier: MIT
// BUILD-PROOF: RAIL_V1 — the swap+custody engine that closes the Base trader loop.
// Spec: SPEC_RailAndKeeper.md (Code Integrity seat, 2026-07-21).
pragma solidity ^0.8.24;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The FundingVault surface the Rail drives. The Rail is the vault's
///         immutable `trader` AND `tradeDestination` — it draws capital in and
///         returns proceeds home. (Both are set at the vault's construction, so
///         the vault↔Rail cycle is broken at deploy by CREATE-address prediction:
///         predict the Rail address, deploy the vault with trader==dest==that
///         address, then deploy the Rail at it. The "ship prewired" pattern.)
interface IFundingVault {
    function drawForTrade(uint256 intentId, uint256 amount) external;
    function returnProceeds(uint256 intentId, uint256 amount) external;
    function owner() external view returns (address);
}

/// @notice AutoTarget — the exit-authorization authority. The Rail only READS it
///         (the `intents` public getter, flattened). The keeper calls
///         resolveIntent/markExecuted on AutoTarget directly — the Rail never
///         writes to it, which keeps deploy order acyclic and needs no keeper
///         role on AutoTarget for the Rail. Status: None=0, Open=1, Resolved=2.
interface IAutoTarget {
    function intents(uint256 id) external view returns (
        address user, bytes32 tokenRef, uint32 chainTag, uint256 entryPrice,
        uint16 targetBps, uint16 stopBps, uint8 status, uint8 exitKind, uint256 usdcReturned
    );
}

/// @notice Uniswap V3 SwapRouter02 (no deadline) — the venue Payments already uses.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/**
 * @title  PossessioRail
 * @notice The hand of the Base trader: buys the token when capital is drawn,
 *         holds it for the life of the position, and sells it ONLY when the
 *         AutoTarget rule (target or the un-removable −10% stop) has fired —
 *         proceeds hardcoded home to the FundingVault. Driven by a bounded
 *         keeper; the operator can always force-close (ownerExit).
 *
 *         SAFETY MODEL (a rogue/broken keeper is bounded four ways):
 *           1. draws are gated by the VAULT's caps (per-trade/outstanding/daily);
 *           2. sells are gated by AutoTarget's ExitAuthorized (Resolved status);
 *           3. proceeds are hardcoded to vault.returnProceeds (never elsewhere);
 *           4. buys are gated to the exact coin the human authored (tokenRef).
 *         The one custodial window — token held between enter and exit — is the
 *         deliberate cost of the vault sandbox (SPEC §6.2); the token can only
 *         ever be sold-to-vault or owner-exited.
 */
contract PossessioRail is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── AutoTarget status codes (mirror its Status enum) ────────────────────
    uint8   internal constant AT_OPEN     = 1;
    uint8   internal constant AT_RESOLVED = 2;
    uint32  public   constant CHAIN_BASE  = 8453;

    // ── Immutables ──────────────────────────────────────────────────────────
    IERC20       public immutable usdc;       // the vault's payToken (6-dec)
    IFundingVault public immutable vault;     // the Rail is its trader + tradeDestination
    IAutoTarget  public immutable autoTarget; // exit-authorization authority (read-only)
    address      public immutable keeper;     // bounded trigger (enter/exit)
    ISwapRouter  public immutable dexRouter;  // Base DEX (SwapRouter02)

    enum Status { None, Open, Closed }
    struct Position { address token; uint256 usdcIn; uint256 tokenAmount; Status status; }
    /// @notice Per-intent position. intentId is the shared id across vault + AutoTarget.
    mapping(uint256 => Position) public positions;
    /// @notice Count of currently-Open positions holding a given token. Guards
    ///         `sweep` from stripping inventory that backs a live position (a
    ///         count, since more than one intent can hold the same token).
    mapping(address => uint256) public openByToken;

    // ── Events (the money-path receipts) ────────────────────────────────────
    event Entered(uint256 indexed intentId, address indexed token, uint256 usdcIn, uint256 tokenOut);
    event Exited(uint256 indexed intentId, uint256 usdcOut, int256 pnl);
    event OwnerExited(uint256 indexed intentId, uint256 usdcOut, int256 pnl);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event Abandoned(uint256 indexed intentId, address indexed token, uint256 tokenAmount);

    // ── Errors ──────────────────────────────────────────────────────────────
    error NotKeeper();
    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinOut();
    error PositionExists();
    error PositionNotOpen();
    error IntentNotOpen();
    error WrongChain();
    error TokenMismatch();
    error ExitNotAuthorized();
    error ProtectedToken();
    error TokenBacksOpenPosition();

    modifier onlyKeeper() { if (msg.sender != keeper) revert NotKeeper(); _; }

    constructor(
        IERC20        _usdc,
        IFundingVault _vault,
        IAutoTarget   _autoTarget,
        address       _keeper,
        ISwapRouter   _dexRouter
    ) {
        if (address(_usdc)       == address(0)) revert ZeroAddress();
        if (address(_vault)      == address(0)) revert ZeroAddress();
        if (address(_autoTarget) == address(0)) revert ZeroAddress();
        if (_keeper              == address(0)) revert ZeroAddress();
        if (address(_dexRouter)  == address(0)) revert ZeroAddress();
        usdc       = _usdc;
        vault      = _vault;
        autoTarget = _autoTarget;
        keeper     = _keeper;
        dexRouter  = _dexRouter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          KEEPER — ENTRY / EXIT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a position: draw `size` USDC from the vault (within its caps)
     *         and swap it to `token` on the DEX. Gated to the exact coin the human
     *         authored on AutoTarget (a Base-tagged, still-Open intent).
     * @param intentId   shared id (vault + AutoTarget + this Rail)
     * @param token      the Base ERC20 to buy (must match the intent's tokenRef)
     * @param size       USDC to draw (6-dec; the vault's caps are the hard bound)
     * @param minTokenOut slippage bound on the buy (keeper's quote; must be > 0)
     * @param poolFee    V3 pool fee tier for the USDC/token pool
     */
    function enter(uint256 intentId, address token, uint256 size, uint256 minTokenOut, uint24 poolFee)
        external onlyKeeper nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (size == 0)           revert ZeroAmount();
        if (minTokenOut == 0)    revert ZeroMinOut();
        Position storage p = positions[intentId];
        if (p.status != Status.None) revert PositionExists();

        // ── Bind to the authored intent ─────────────────────────────────────
        (, bytes32 tokenRef, uint32 chainTag, , , , uint8 st, , ) = autoTarget.intents(intentId);
        if (st != AT_OPEN)                                        revert IntentNotOpen();
        if (chainTag != CHAIN_BASE)                               revert WrongChain();
        if (address(uint160(uint256(tokenRef))) != token)        revert TokenMismatch();

        // ── Effects ─────────────────────────────────────────────────────────
        p.token = token; p.usdcIn = size; p.status = Status.Open;
        openByToken[token] += 1;

        // ── Interactions: draw (vault caps gate this) then buy ──────────────
        vault.drawForTrade(intentId, size);                    // USDC → this Rail
        usdc.forceApprove(address(dexRouter), size);
        uint256 got = dexRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc), tokenOut: token, fee: poolFee, recipient: address(this),
            amountIn: size, amountOutMinimum: minTokenOut, sqrtPriceLimitX96: 0
        }));
        usdc.forceApprove(address(dexRouter), 0);
        p.tokenAmount = got;
        emit Entered(intentId, token, size, got);
    }

    /**
     * @notice Close a position on an AUTHORIZED exit: requires AutoTarget to have
     *         resolved the intent (target or −10% stop crossed). Sells the token
     *         to USDC and returns proceeds home to the vault. The keeper cannot
     *         sell a position the rule hasn't released.
     */
    function exit(uint256 intentId, uint256 minUsdcOut, uint24 poolFee)
        external onlyKeeper nonReentrant
    {
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();
        if (minUsdcOut == 0)         revert ZeroMinOut();
        (, , , , , , uint8 st, , ) = autoTarget.intents(intentId);
        if (st != AT_RESOLVED) revert ExitNotAuthorized();
        _closeSwapReturn(intentId, p, minUsdcOut, poolFee, false);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       OWNER — THE UN-REMOVABLE BAIL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice The operator force-closes an open position via the DEX — no keeper,
     *         no AutoTarget resolution needed. The human's manual exit hatch
     *         (SPEC §5.7; realizes AutoTarget F2). Same sell→return path, so it
     *         needs a sellable token; for a token that CANNOT be sold (honeypot /
     *         zero-liquidity rug) use `abandon` instead, which closes without a swap.
     */
    function ownerExit(uint256 intentId, uint256 minUsdcOut, uint24 poolFee)
        external nonReentrant
    {
        if (msg.sender != vault.owner()) revert NotOwner();
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();
        if (minUsdcOut == 0)         revert ZeroMinOut();
        _closeSwapReturn(intentId, p, minUsdcOut, poolFee, true);
    }

    /**
     * @notice Owner escape hatch for a position whose token cannot be sold — a
     *         honeypot that blocks the sell, or a zero-liquidity rug — where both
     *         `exit` and `ownerExit` revert on the mandatory swap and the draw is
     *         otherwise stranded in the vault's `outstanding` forever, permanently
     *         consuming the outstanding cap. Closes the position WITHOUT a swap and
     *         clears the exposure via a zero-proceeds return (the vault's
     *         `returnProceeds` moves no USDC when amount == 0). The drawn capital is
     *         already lost in the rug; this only stops the dead position from
     *         ratcheting the cap. The now-worthless token stays in the Rail and is
     *         `sweep`-able once the position is Closed.
     */
    function abandon(uint256 intentId) external nonReentrant {
        if (msg.sender != vault.owner()) revert NotOwner();
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();

        // ── Effects (before interaction) ────────────────────────────────────
        p.status = Status.Closed;
        openByToken[p.token] -= 1;

        // ── Interaction: zero-proceeds return clears vault `outstanding` ─────
        vault.returnProceeds(intentId, 0);
        emit Abandoned(intentId, p.token, p.tokenAmount);
    }

    /**
     * @notice Rescue a non-position token mistakenly sent to the Rail. Owner-only,
     *         to the owner. Never USDC (mid-flow), and never a token that currently
     *         backs an Open position — sweeping that would strip the inventory the
     *         position needs to exit. Close (`exit`/`ownerExit`/`abandon`) first.
     */
    function sweep(address token) external nonReentrant {
        address owner_ = vault.owner();
        if (msg.sender != owner_)        revert NotOwner();
        if (token == address(usdc))      revert ProtectedToken();
        if (openByToken[token] != 0)     revert TokenBacksOpenPosition();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner_, bal);
        emit Swept(token, owner_, bal);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function getPosition(uint256 intentId)
        external view returns (address token, uint256 usdcIn, uint256 tokenAmount, Status status)
    {
        Position storage p = positions[intentId];
        return (p.token, p.usdcIn, p.tokenAmount, p.status);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Sell the position's token → USDC and return proceeds to the vault.
    ///      CEI: mark Closed before the swap/return interactions.
    function _closeSwapReturn(uint256 intentId, Position storage p, uint256 minUsdcOut, uint24 poolFee, bool byOwner)
        internal
    {
        address token = p.token;
        uint256 amt   = p.tokenAmount;
        uint256 usdcIn = p.usdcIn;

        // ── Effects ─────────────────────────────────────────────────────────
        p.status = Status.Closed;
        openByToken[token] -= 1;

        // ── Interactions: sell → return home ────────────────────────────────
        IERC20(token).forceApprove(address(dexRouter), amt);
        uint256 usdcOut = dexRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: token, tokenOut: address(usdc), fee: poolFee, recipient: address(this),
            amountIn: amt, amountOutMinimum: minUsdcOut, sqrtPriceLimitX96: 0
        }));
        IERC20(token).forceApprove(address(dexRouter), 0);

        usdc.forceApprove(address(vault), usdcOut);          // vault pulls from the Rail (tradeDestination)
        vault.returnProceeds(intentId, usdcOut);

        // USDC amounts (6-dec) are bounded by total supply (~1e16), far below
        // int256 max — neither cast can truncate. Informational only.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 pnl = int256(usdcOut) - int256(usdcIn);
        if (byOwner) emit OwnerExited(intentId, usdcOut, pnl);
        else         emit Exited(intentId, usdcOut, pnl);
    }
}
