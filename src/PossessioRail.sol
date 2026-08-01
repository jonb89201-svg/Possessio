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
    /// @dev POSITIONAL TUPLE — it must track PossessioAutoTarget.Intent field for
    ///      field. Adding `ownerRef` to that struct shifted every slot after the
    ///      first and silently broke `enter()`: the decode still succeeded, it
    ///      just read the wrong fields. Nothing in the Rail's own unit suite can
    ///      catch that, because those tests drive a MockAutoTarget that declares
    ///      its own struct. If you change Intent, change this, the four
    ///      destructures below, and the mock — or the only thing that fails is a
    ///      fork test somebody may not run.
    function intents(uint256 id) external view returns (
        address user, bytes32 ownerRef, bytes32 tokenRef, uint32 chainTag, uint256 entryPrice,
        uint16 targetBps, uint16 stopBps, uint8 status, uint8 exitKind, uint256 usdcReturned
    );
}

/// @notice Uniswap V3 SwapRouter02 (no deadline) — the venue Payments already uses.
///         V2 adds `exactInput` for the ONE multi-hop shape this Rail allows
///         (USDC→WETH→token and its mirror). The path bytes are assembled inside
///         this contract, never accepted from a caller — see `_path`.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
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
    uint32  public   constant CHAIN_BASE   = 8453;
    uint32  public   constant CHAIN_SOLANA = 101;  // SPL cluster id (AutoTarget's tag)

    // ── Immutables ──────────────────────────────────────────────────────────
    IERC20       public immutable usdc;       // the vault's payToken (6-dec)
    IFundingVault public immutable vault;     // the Rail is its trader + tradeDestination
    IAutoTarget  public immutable autoTarget; // exit-authorization authority (read-only)
    address      public immutable keeper;     // bounded trigger (enter/exit)
    ISwapRouter  public immutable dexRouter;  // Base DEX (SwapRouter02)
    /// @notice The ONLY permitted intermediate hop (V2). Immutable, so the
    ///         multi-hop route can never be pointed at an unvetted middle token.
    address      public immutable weth;
    /// @notice The ONLY address a remote (Solana) leg's capital may be handed to.
    ///         Immutable — matches every other money path in this protocol.
    address      public immutable remoteAgent;
    /// @notice How long a remote leg may stay Pending before the OWNER may
    ///         release it (a dead leg must not charge `outstanding` forever).
    uint256      public immutable REMOTE_LEG_TIMEOUT;

    /// @notice Status.Pending is APPENDED so None=0/Open=1/Closed=2 keep their
    ///         numeric meaning for anything already reading this enum.
    enum Status { None, Open, Closed, Pending }
    /// @notice The route is RECORDED at entry and REPLAYED (reversed) at exit, so
    ///         a position can never be entered by one path and stranded because
    ///         the exit used another. `viaWeth` false = direct USDC/token at feeA;
    ///         true = USDC-feeA-WETH-feeB-token.
    struct Position {
        address token; uint256 usdcIn; uint256 tokenAmount; Status status;
        bool viaWeth; uint24 feeA; uint24 feeB;
        uint64 openedAt; uint256 usdcSnapshot; // remote-leg bookkeeping
    }
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
    // ── V2: the remote (Solana) leg receipts ────────────────────────────────
    event RemoteLegOpened(uint256 indexed intentId, uint256 usdcOut, address indexed agent);
    /// @param got the MEASURED balance delta returned home — never a reported figure.
    event RemoteLegSettled(uint256 indexed intentId, uint256 usdcIn, uint256 got, bool ruleResolved);
    event RemoteLegAbandoned(uint256 indexed intentId, uint256 usdcIn, uint256 recovered);
    event UsdcSweptHome(uint256 amount);

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
    // ── V2 ──────────────────────────────────────────────────────────────────
    error BadRoute();            // fee tier zero, or feeB set on a direct route
    error RouteHopIsWeth();      // viaWeth with token == WETH (that IS the direct route)
    error RemoteLegPending();    // one remote leg at a time — measurement must be unambiguous
    error PositionNotPending();
    error NothingReturned();
    error TimeoutNotElapsed();

    modifier onlyKeeper() { if (msg.sender != keeper) revert NotKeeper(); _; }
    modifier onlyOwner()  { if (msg.sender != vault.owner()) revert NotOwner(); _; }

    /// @notice Number of remote legs currently Pending. Capped at ONE by
    ///         `openRemoteLeg` so a settle's measured delta can only ever belong
    ///         to the leg being settled (see the measurement rule below).
    uint256 public pendingRemoteLegs;

    constructor(
        IERC20        _usdc,
        IFundingVault _vault,
        IAutoTarget   _autoTarget,
        address       _keeper,
        ISwapRouter   _dexRouter,
        address       _weth,
        address       _remoteAgent,
        uint256       _remoteLegTimeout
    ) {
        if (address(_usdc)       == address(0)) revert ZeroAddress();
        if (address(_vault)      == address(0)) revert ZeroAddress();
        if (address(_autoTarget) == address(0)) revert ZeroAddress();
        if (_keeper              == address(0)) revert ZeroAddress();
        if (address(_dexRouter)  == address(0)) revert ZeroAddress();
        if (_weth                == address(0)) revert ZeroAddress();
        if (_remoteAgent         == address(0)) revert ZeroAddress();
        if (_remoteLegTimeout    == 0)          revert ZeroAmount();
        usdc       = _usdc;
        vault      = _vault;
        autoTarget = _autoTarget;
        keeper     = _keeper;
        dexRouter  = _dexRouter;
        weth       = _weth;
        remoteAgent = _remoteAgent;
        REMOTE_LEG_TIMEOUT = _remoteLegTimeout;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //            V2 — THE ONLY TWO ROUTES THAT EXIST, BUILT IN CODE
    //
    //  V1 spoke only exactInputSingle, so it could reach a token ONLY if that
    //  token had a direct USDC pool. Real Base liquidity for new tokens is
    //  overwhelmingly TOKEN/WETH, which made most of the desk's intended
    //  universe unreachable (Architect's finding, ledger row 68).
    //
    //  V2 opens the universe WITHOUT opening a routing surface: the caller
    //  never supplies path bytes. It supplies a shape (`viaWeth`) and fee
    //  tiers; this contract assembles the path from its OWN immutables. So a
    //  keeper — rogue, buggy, or compromised — can choose between exactly two
    //  routes and cannot invent a third through pools nobody vetted.
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev USDC→token. `reverse` flips it to token→USDC. Path bytes are built
    ///      from immutables + the recorded route; nothing here is caller-supplied.
    function _path(address token, bool viaWeth, uint24 feeA, uint24 feeB, bool reverse)
        internal view returns (bytes memory)
    {
        if (!viaWeth) {
            return reverse
                ? abi.encodePacked(token, feeA, address(usdc))
                : abi.encodePacked(address(usdc), feeA, token);
        }
        return reverse
            ? abi.encodePacked(token, feeB, weth, feeA, address(usdc))
            : abi.encodePacked(address(usdc), feeA, weth, feeB, token);
    }

    /// @dev Swap `amountIn` of the path's first token for at least `minOut` of its
    ///      last. Single-hop uses exactInputSingle (cheaper, identical result).
    function _swap(address tokenIn, address token, bool viaWeth, uint24 feeA, uint24 feeB, bool reverse,
                   uint256 amountIn, uint256 minOut) internal returns (uint256 out)
    {
        IERC20(tokenIn).forceApprove(address(dexRouter), amountIn);
        if (!viaWeth) {
            out = dexRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: reverse ? address(usdc) : token,
                fee: feeA, recipient: address(this),
                amountIn: amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0
            }));
        } else {
            out = dexRouter.exactInput(ISwapRouter.ExactInputParams({
                path: _path(token, true, feeA, feeB, reverse),
                recipient: address(this), amountIn: amountIn, amountOutMinimum: minOut
            }));
        }
        IERC20(tokenIn).forceApprove(address(dexRouter), 0);
    }

    /// @dev Route hygiene. A zero fee tier is never a real V3 pool, and feeB is
    ///      meaningless on a direct route — reject both rather than silently
    ///      ignoring them. `viaWeth` with token == WETH is the direct route.
    function _validateRoute(address token, bool viaWeth, uint24 feeA, uint24 feeB) internal view {
        if (feeA == 0) revert BadRoute();
        if (viaWeth) {
            if (feeB == 0)      revert BadRoute();
            if (token == weth)  revert RouteHopIsWeth();
        } else {
            if (feeB != 0)      revert BadRoute();
        }
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
    /// @param viaWeth false = direct USDC/token pool at `feeA`; true = the one
    ///                permitted multi-hop, USDC-`feeA`-WETH-`feeB`-token. The path
    ///                is assembled from this contract's immutables (see `_path`) —
    ///                the keeper picks a shape, never a route.
    function enter(
        uint256 intentId, address token, uint256 size, uint256 minTokenOut,
        bool viaWeth, uint24 feeA, uint24 feeB
    )
        external onlyKeeper nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (size == 0)           revert ZeroAmount();
        if (minTokenOut == 0)    revert ZeroMinOut();
        _validateRoute(token, viaWeth, feeA, feeB);
        Position storage p = positions[intentId];
        if (p.status != Status.None) revert PositionExists();

        // ── Bind to the authored intent ─────────────────────────────────────
        (, , bytes32 tokenRef, uint32 chainTag, , , , uint8 st, , ) = autoTarget.intents(intentId);
        if (st != AT_OPEN)                                        revert IntentNotOpen();
        if (chainTag != CHAIN_BASE)                               revert WrongChain();
        if (address(uint160(uint256(tokenRef))) != token)        revert TokenMismatch();

        // ── Effects: the ROUTE IS RECORDED here, so exit cannot diverge ──────
        p.token = token; p.usdcIn = size; p.status = Status.Open;
        p.viaWeth = viaWeth; p.feeA = feeA; p.feeB = feeB;
        p.openedAt = uint64(block.timestamp);
        openByToken[token] += 1;

        // ── Interactions: draw (vault caps gate this) then buy ──────────────
        vault.drawForTrade(intentId, size);                    // USDC → this Rail
        uint256 got = _swap(address(usdc), token, viaWeth, feeA, feeB, false, size, minTokenOut);
        p.tokenAmount = got;
        emit Entered(intentId, token, size, got);
    }

    /**
     * @notice Close a position on an AUTHORIZED exit: requires AutoTarget to have
     *         resolved the intent (target or −10% stop crossed). Sells the token
     *         to USDC and returns proceeds home to the vault. The keeper cannot
     *         sell a position the rule hasn't released.
     */
    /// @dev V2: takes NO route arguments. The exit replays the entry's recorded
    ///      route in reverse, so entry and exit are mirrored STRUCTURALLY rather
    ///      than by keeper discipline. A position bought through WETH is always
    ///      sold back through WETH; it cannot be entered one way and stranded
    ///      because the exit was attempted another (Datum, ledger row 68 pt 3).
    function exit(uint256 intentId, uint256 minUsdcOut)
        external onlyKeeper nonReentrant
    {
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();
        if (minUsdcOut == 0)         revert ZeroMinOut();
        (, , , , , , , uint8 st, , ) = autoTarget.intents(intentId);
        if (st != AT_RESOLVED) revert ExitNotAuthorized();
        _closeSwapReturn(intentId, p, minUsdcOut, p.viaWeth, p.feeA, p.feeB, false);
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
    ///         V2: replays the recorded route, like `exit`.
    function ownerExit(uint256 intentId, uint256 minUsdcOut)
        external onlyOwner nonReentrant
    {
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();
        if (minUsdcOut == 0)         revert ZeroMinOut();
        _closeSwapReturn(intentId, p, minUsdcOut, p.viaWeth, p.feeA, p.feeB, true);
    }

    /**
     * @notice The owner's bail-out with an EXPLICIT route override — the only place
     *         a route may differ from the recorded one. Liquidity migrates: the fee
     *         tier a position was bought through can go thin or empty, and the
     *         human's exit hatch must not be hostage to a dead pool. Still bounded
     *         to the same two shapes (direct, or via the immutable WETH) and still
     *         hardcoded home to the vault — an override changes the VENUE, never
     *         the destination.
     */
    function ownerExitVia(uint256 intentId, uint256 minUsdcOut, bool viaWeth, uint24 feeA, uint24 feeB)
        external onlyOwner nonReentrant
    {
        Position storage p = positions[intentId];
        if (p.status != Status.Open) revert PositionNotOpen();
        if (minUsdcOut == 0)         revert ZeroMinOut();
        _validateRoute(p.token, viaWeth, feeA, feeB);
        _closeSwapReturn(intentId, p, minUsdcOut, viaWeth, feeA, feeB, true);
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

    // ═══════════════════════════════════════════════════════════════════════
    //         V2 — THE REMOTE (SOLANA) LEG: draw → pending → settle
    //
    //  One Rail is the vault's single immutable trader for BOTH chains
    //  (SPEC_RailDualLeg). A remote leg draws USDC under the SAME vault caps,
    //  hands it to ONE immutable agent, and later settles by MEASURING what
    //  came home. The Rail never bridges, routes, or picks a Solana venue, and
    //  it learns nothing about the trade — it observes only USDC.
    //
    //  THE LOAD-BEARING RULE: `settleRemoteLeg` takes NO amount. A reported
    //  figure is a trusted number, and trusting a claim instead of checking the
    //  property is exactly what bricked the V1 desk. Measure, don't trust.
    //
    //  HONEST COST, stated where the code is: between draw and settle the drawn
    //  USDC is in the agent's hands and can be lost or stolen. Nothing here
    //  prevents that. It is bounded three ways — maxPerTrade caps one leg,
    //  maxOutstanding caps total exposure, and an unsettled leg starves the next
    //  draw — and the events record it.
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Draw for a Solana-tagged intent and hand the capital to the agent.
     * @dev ONE pending leg at a time. That is not a convenience limit: settlement
     *      is a balance delta, and with two legs in flight a returning amount
     *      could not be honestly attributed to either. One leg keeps the
     *      measurement provable instead of assumed.
     */
    function openRemoteLeg(uint256 intentId, uint256 size) external onlyKeeper nonReentrant {
        if (size == 0) revert ZeroAmount();
        if (pendingRemoteLegs != 0) revert RemoteLegPending();
        Position storage p = positions[intentId];
        if (p.status != Status.None) revert PositionExists();

        (, , , uint32 chainTag, , , , uint8 st, , ) = autoTarget.intents(intentId);
        if (st != AT_OPEN)            revert IntentNotOpen();
        if (chainTag != CHAIN_SOLANA) revert WrongChain();

        // ── Effects (before any interaction) ────────────────────────────────
        p.usdcIn = size; p.status = Status.Pending;
        p.openedAt = uint64(block.timestamp);
        p.usdcSnapshot = usdc.balanceOf(address(this)); // pre-draw baseline
        pendingRemoteLegs = 1;

        // ── Interactions: draw under caps, then hand off ────────────────────
        vault.drawForTrade(intentId, size);
        usdc.safeTransfer(remoteAgent, size);
        emit RemoteLegOpened(intentId, size, remoteAgent);
    }

    /**
     * @notice Settle a returned remote leg with the MEASURED amount.
     * @dev No amount parameter, by design (see the rule above). `got` is the
     *      Rail's own USDC balance delta since the leg opened.
     *
     *      DELIBERATELY NOT GATED ON AutoTarget being Resolved. The sell already
     *      happened off-chain: by the time USDC is at the Rail, refusing to bank
     *      it would strand real capital here (this contract's `sweep` cannot move
     *      USDC), which is a worse failure than an unauthorized-looking close.
     *      The rule still governs authorization to exit on the Base leg; on the
     *      remote leg it is recorded (`ruleResolved`) rather than enforced, so the
     *      ledger shows whether the exit was rule-authorized. Architect's call to
     *      overturn (SPEC_RailDualLeg §7.3).
     */
    function settleRemoteLeg(uint256 intentId) external onlyKeeper nonReentrant {
        Position storage p = positions[intentId];
        if (p.status != Status.Pending) revert PositionNotPending();

        uint256 bal = usdc.balanceOf(address(this));
        uint256 snap = p.usdcSnapshot;
        uint256 got = bal > snap ? bal - snap : 0;
        if (got == 0) revert NothingReturned();

        (, , , , , , , uint8 st, , ) = autoTarget.intents(intentId);

        // ── Effects ─────────────────────────────────────────────────────────
        p.status = Status.Closed;
        pendingRemoteLegs = 0;

        // ── Interaction: home to the vault, nowhere else ─────────────────────
        usdc.forceApprove(address(vault), got);
        vault.returnProceeds(intentId, got);
        emit RemoteLegSettled(intentId, p.usdcIn, got, st == AT_RESOLVED);
    }

    /**
     * @notice Owner release for a remote leg that never came home. After the
     *         timeout only.
     * @dev Returns whatever DID come back (measured), not a hardcoded zero: if a
     *      partial return arrived, banking it is the difference between a recorded
     *      loss and USDC stranded at this contract forever (`sweep` refuses USDC).
     *      A truly empty leg returns 0 — the loss is real and the event says so.
     */
    function abandonRemoteLeg(uint256 intentId) external onlyOwner nonReentrant {
        Position storage p = positions[intentId];
        if (p.status != Status.Pending) revert PositionNotPending();
        if (block.timestamp <= uint256(p.openedAt) + REMOTE_LEG_TIMEOUT) revert TimeoutNotElapsed();

        uint256 bal = usdc.balanceOf(address(this));
        uint256 snap = p.usdcSnapshot;
        uint256 got = bal > snap ? bal - snap : 0;

        // ── Effects ─────────────────────────────────────────────────────────
        p.status = Status.Closed;
        pendingRemoteLegs = 0;

        // ── Interaction: release the cap charge; bank any partial return ─────
        if (got > 0) usdc.forceApprove(address(vault), got);
        vault.returnProceeds(intentId, got);
        emit RemoteLegAbandoned(intentId, p.usdcIn, got);
    }

    /**
     * @notice Send unaccounted USDC sitting at the Rail HOME to the vault.
     * @dev Closes a real hole found by this seat's exit audit (ledger row 62): the
     *      Rail's `sweep` refuses USDC unconditionally, so USDC arriving outside an
     *      atomic flow — a donation, a router refund, a late remote-leg return —
     *      had no exit at all and was lost. Direction is toward the VAULT only
     *      (whose `available()` reads raw balance, so it is credited); there is no
     *      path to a caller, so this adds no drain. Blocked while a remote leg is
     *      Pending, so it can never front-run a settle's measurement.
     */
    function sweepUsdcHome() external onlyOwner nonReentrant {
        if (pendingRemoteLegs != 0) revert RemoteLegPending();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        usdc.safeTransfer(address(vault), bal);
        emit UsdcSweptHome(bal);
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

    /// @notice The route a position was ENTERED through — the same one `exit`
    ///         replays in reverse. Readable so the keeper can quote against the
    ///         real path instead of guessing it.
    function getRoute(uint256 intentId)
        external view returns (bool viaWeth, uint24 feeA, uint24 feeB)
    {
        Position storage p = positions[intentId];
        return (p.viaWeth, p.feeA, p.feeB);
    }

    /// @notice Remote-leg bookkeeping: when it opened and the USDC baseline the
    ///         settlement delta is measured against.
    function getRemoteLeg(uint256 intentId)
        external view returns (uint64 openedAt, uint256 usdcSnapshot, uint256 releasableAt)
    {
        Position storage p = positions[intentId];
        return (p.openedAt, p.usdcSnapshot, uint256(p.openedAt) + REMOTE_LEG_TIMEOUT);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Sell the position's token → USDC and return proceeds to the vault.
    ///      CEI: mark Closed before the swap/return interactions.
    function _closeSwapReturn(
        uint256 intentId, Position storage p, uint256 minUsdcOut,
        bool viaWeth, uint24 feeA, uint24 feeB, bool byOwner
    )
        internal
    {
        address token = p.token;
        uint256 amt   = p.tokenAmount;
        uint256 usdcIn = p.usdcIn;

        // ── Effects ─────────────────────────────────────────────────────────
        p.status = Status.Closed;
        openByToken[token] -= 1;

        // ── Interactions: sell (mirror of the entry route) → return home ─────
        uint256 usdcOut = _swap(token, token, viaWeth, feeA, feeB, true, amt, minUsdcOut);

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
