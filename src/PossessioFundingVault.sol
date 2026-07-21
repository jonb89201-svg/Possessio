// SPDX-License-Identifier: MIT
// BUILD-PROOF: FUNDING_VAULT_V1 — the trader's hard-capped, sovereign capital source.
// Spec: SPEC_FundingVault.md (Code Integrity seat, 2026-07-20).
//
// The risk boundary that makes a sovereign trader safe to launch: the operator
// funds a vault they own; the desk draws trading capital ONLY within immutable
// hard caps; the operator can ALWAYS withdraw. Every dollar the trader can ever
// touch is bounded, on-chain, and auditable.
pragma solidity ^0.8.24;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  PossessioFundingVault
 * @notice The trader's hard-capped, closed-loop, sovereign capital source. Ships
 *         as a bundle with the AutoTarget desk: the desk decides and triggers;
 *         this vault sources and bounds the capital. Neither ships alone.
 *
 *         CLOSED-LOOP CUSTODY (Architect ruling, SPEC_FundingVault §3):
 *           The `trader` is a sandbox, not a wallet-spender. It is hardcoded to
 *           this vault as its ONLY source of funds — it can never reach the
 *           operator's main wallet. The operator sends capital TO the vault;
 *           `drawForTrade` releases it (within caps) to `tradeDestination` (the
 *           execution rail); on sell, proceeds route BACK via `returnProceeds`.
 *           The operator's main wallet only ever touches `fund` (deposit) and
 *           `withdraw` (harvest). Worst case is bounded to what's in the vault.
 *
 *         TWO ROLES, IMMUTABLE (no admin sprawl):
 *           owner  = the operator's passkey Base Account — fund, withdraw (to
 *                    self only), pause. Sovereign; can always exit.
 *           trader = the desk + keeper — drawForTrade, returnProceeds. Bounded.
 *
 *         THREE HARD CAPS (a draw must satisfy ALL three):
 *           maxPerTrade    — most USDC a single draw can pull.
 *           maxOutstanding — most USDC out in open trades at once (concurrency).
 *           dailyDrawCap   — most USDC drawn per rolling 24h window (rate).
 *           The vault balance is the absolute ceiling on top of these.
 *
 *         ASYMMETRIC CAP ADJUSTMENT (Payments C-2 pattern): the owner may LOWER
 *         any cap instantly (tighten risk now) but RAISING one is delayed behind
 *         LIMIT_DELAY (24h) — a compromised owner key cannot instantly widen the
 *         blast radius.
 *
 *         NON-CUSTODIAL: recipients are hardcoded (withdraw -> owner; draw ->
 *         tradeDestination). No arbitrary-recipient path exists anywhere. This
 *         contract has no upgrade path and no post-deploy authority for anyone
 *         but the two constructor-fixed roles, each bounded as above.
 */
contract PossessioFundingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Delay before a cap RAISE takes effect. Decreases are instant.
    uint256 public constant LIMIT_DELAY = 24 hours;

    /// @notice Rolling window for the daily draw cap.
    uint256 public constant WINDOW_SIZE = 24 hours;

    /// @notice The three adjustable caps, addressed by this enum for the
    ///         asymmetric decrease/queue-raise machinery.
    enum Cap { PerTrade, Outstanding, DailyDraw }

    /// @notice A trade's lifecycle. NONE -> OPEN (drawForTrade) -> CLOSED
    ///         (returnProceeds). An intentId is consumed permanently: it can
    ///         never be re-drawn once closed, keeping the receipt ledger clean.
    enum TradeStatus { None, Open, Closed }

    // ═══════════════════════════════════════════════════════════════════════
    //                              IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The settlement asset (USDC on Base — 6-decimal). The only token
    ///         this vault ever meters: USDC out (draw) and USDC in (return).
    IERC20  public immutable payToken;

    /// @notice The operator's passkey Base Account. Sovereign role. `withdraw`
    ///         is hardcoded to send here; can always exit.
    address public immutable owner;

    /// @notice The desk + keeper. Bounded role. Only address that can draw.
    address public immutable trader;

    /// @notice Hardcoded recipient of every `drawForTrade` (the execution rail;
    ///         = the owner's Base Account under the ratified Option A). Also the
    ///         approved source `returnProceeds` pulls from. No setter exists.
    address public immutable tradeDestination;

    // ═══════════════════════════════════════════════════════════════════════
    //                            MUTABLE STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The three caps. Initialized at construction; adjustable per the
    ///         asymmetric rules (lower instant, raise behind LIMIT_DELAY).
    uint256 public maxPerTrade;
    uint256 public maxOutstanding;
    uint256 public dailyDrawCap;

    /// @notice Σdrawn(open) − Σreturned-as-cleared. The exact USDC currently out
    ///         in open trades. `withdraw` can never pull the balance below this.
    uint256 public outstanding;

    /// @notice Rolling-window accounting for the daily draw cap (Payments C-2).
    uint256 public windowStart;
    uint256 public dailyDrawn;

    /// @notice When true, `drawForTrade` is frozen. `withdraw` is NOT — the
    ///         owner can always exit (invariant §5.1).
    bool    public paused;

    /// @notice A queued cap raise, per cap. executeAfter == 0 means none queued.
    struct QueuedRaise { uint256 newValue; uint256 executeAfter; }
    mapping(Cap => QueuedRaise) public queuedRaise;

    /// @notice Per-intent trade record — the receipt row the transactions page
    ///         renders. `drawn` is the original draw (the exposure this trade
    ///         cleared on close); `returned` is the proceeds that came back.
    struct Trade { uint256 drawn; uint256 returned; TradeStatus status; }
    mapping(uint256 => Trade) internal _trades;

    // ═══════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event TradeFunded(uint256 indexed intentId, uint256 amount);
    event TradeClosed(uint256 indexed intentId, uint256 drawn, uint256 returned, int256 pnl);
    event CapChanged(Cap indexed cap, uint256 newValue);
    event CapIncreaseQueued(Cap indexed cap, uint256 newValue, uint256 executeAfter);
    event CapIncreaseCancelled(Cap indexed cap);
    event Paused(bool status);

    // ═══════════════════════════════════════════════════════════════════════
    //                                ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotOwner();
    error NotTrader();
    error ZeroAddress();
    error ZeroAmount();
    error IsPaused();
    error PerTradeCapExceeded();
    error OutstandingCapExceeded();
    error DailyCapExceeded();
    error InsufficientAvailable();
    error ExceedsAvailable();
    error TradeAlreadyOpen();
    error TradeNotOpen();
    error InvalidCap();
    error NoIncreaseQueued();
    error TimelockNotPassed();

    // ═══════════════════════════════════════════════════════════════════════
    //                               MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner()  { if (msg.sender != owner)  revert NotOwner();  _; }
    modifier onlyTrader() { if (msg.sender != trader) revert NotTrader(); _; }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @param _payToken          USDC (the only metered asset).
    /// @param _owner             operator's passkey Base Account (sovereign).
    /// @param _trader            desk + keeper (bounded spender).
    /// @param _tradeDestination  hardcoded draw recipient / return source.
    /// @param _maxPerTrade       initial per-trade cap.
    /// @param _maxOutstanding    initial concurrent-exposure cap.
    /// @param _dailyDrawCap      initial rolling-24h draw cap.
    constructor(
        IERC20  _payToken,
        address _owner,
        address _trader,
        address _tradeDestination,
        uint256 _maxPerTrade,
        uint256 _maxOutstanding,
        uint256 _dailyDrawCap
    ) {
        if (address(_payToken)  == address(0)) revert ZeroAddress();
        if (_owner              == address(0)) revert ZeroAddress();
        if (_trader             == address(0)) revert ZeroAddress();
        if (_tradeDestination   == address(0)) revert ZeroAddress();
        if (_maxPerTrade    == 0)              revert ZeroAmount();
        if (_maxOutstanding == 0)              revert ZeroAmount();
        if (_dailyDrawCap   == 0)              revert ZeroAmount();

        payToken         = _payToken;
        owner            = _owner;
        trader           = _trader;
        tradeDestination = _tradeDestination;

        maxPerTrade    = _maxPerTrade;
        maxOutstanding = _maxOutstanding;
        dailyDrawCap   = _dailyDrawCap;

        windowStart = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         OWNER — SOVEREIGN SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC into the vault. Anyone may fund (top-ups are
     *         harmless — only the owner ever withdraws), so this is not
     *         owner-gated; the caller must have approved `amount` to this vault.
     */
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        payToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /**
     * @notice Withdraw idle capital to the owner (hardcoded recipient). Owner
     *         can ALWAYS exit — available even while trades are outstanding and
     *         even while paused. Bounded only by the vault's idle balance
     *         (`available()`): capital already out in open trades physically
     *         sits at `tradeDestination`, not here, so it is inherently
     *         un-withdrawable until `returnProceeds` brings it home. The owner
     *         can reclaim EVERY idle dollar the vault holds (§5.1).
     */
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > available()) revert ExceedsAvailable();
        payToken.safeTransfer(owner, amount);
        emit Withdrawn(owner, amount);
    }

    /**
     * @notice Freeze `drawForTrade`. Does NOT freeze `withdraw`.
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    /**
     * @notice Resume `drawForTrade`.
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    OWNER — ASYMMETRIC CAP ADJUSTMENT
    //             (lower instant · raise behind LIMIT_DELAY — C-2)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Lower a cap. Applies immediately — tightening risk is always
     *         instant. `newValue` must be strictly below the current value.
     */
    function decreaseCap(Cap cap, uint256 newValue) external onlyOwner {
        if (newValue == 0)               revert ZeroAmount();
        if (newValue >= _capValue(cap))  revert InvalidCap(); // must be lower
        _setCap(cap, newValue);
        emit CapChanged(cap, newValue);
    }

    /**
     * @notice Queue a cap raise. Takes effect only after LIMIT_DELAY (24h). A
     *         compromised owner key cannot raise a cap and immediately drain.
     *         `newValue` must be strictly above the current value.
     */
    function queueCapIncrease(Cap cap, uint256 newValue) external onlyOwner {
        if (newValue <= _capValue(cap)) revert InvalidCap(); // must be higher
        queuedRaise[cap] = QueuedRaise({
            newValue:     newValue,
            executeAfter: block.timestamp + LIMIT_DELAY
        });
        emit CapIncreaseQueued(cap, newValue, block.timestamp + LIMIT_DELAY);
    }

    /**
     * @notice Execute a queued cap raise after LIMIT_DELAY has elapsed.
     */
    function executeCapIncrease(Cap cap) external onlyOwner {
        QueuedRaise memory q = queuedRaise[cap];
        if (q.executeAfter == 0)              revert NoIncreaseQueued();
        // LIMIT_DELAY is 24 hours; a validator's ~12s window is immaterial against 86,400s.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < q.executeAfter) revert TimelockNotPassed();
        _setCap(cap, q.newValue);
        delete queuedRaise[cap];
        emit CapChanged(cap, q.newValue);
    }

    /**
     * @notice Cancel a queued cap raise. Applies immediately (tightening).
     */
    function cancelCapIncrease(Cap cap) external onlyOwner {
        if (queuedRaise[cap].executeAfter == 0) revert NoIncreaseQueued();
        delete queuedRaise[cap];
        emit CapIncreaseCancelled(cap);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        TRADER — BOUNDED SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Release trading capital to `tradeDestination`, within ALL three
     *         caps and the vault balance. Frozen while paused.
     *
     *         Checks (all must pass):
     *           amount ≤ maxPerTrade
     *           outstanding + amount ≤ maxOutstanding
     *           dailyDrawn + amount ≤ dailyDrawCap  (rolling 24h)
     *           amount ≤ available()                (idle USDC physically here)
     *
     *         CEI: exposure, daily-window, and the trade record all commit
     *         BEFORE the USDC leaves (reentrancy-safe, §5.6). `intentId` is
     *         single-use — a reused id reverts.
     */
    function drawForTrade(uint256 intentId, uint256 amount)
        external onlyTrader nonReentrant
    {
        if (paused)      revert IsPaused();
        if (amount == 0) revert ZeroAmount();

        Trade storage t = _trades[intentId];
        if (t.status != TradeStatus.None) revert TradeAlreadyOpen();

        // ── Checks: all three caps + the idle-balance ceiling ───────────────
        if (amount > maxPerTrade)                     revert PerTradeCapExceeded();
        if (outstanding + amount > maxOutstanding)    revert OutstandingCapExceeded();
        if (amount > available())                     revert InsufficientAvailable();
        _consumeDailyDraw(amount); // reverts DailyCapExceeded on breach

        // ── Effects (before interaction) ────────────────────────────────────
        outstanding += amount;
        t.drawn  = amount;
        t.status = TradeStatus.Open;

        // ── Interaction ─────────────────────────────────────────────────────
        payToken.safeTransfer(tradeDestination, amount);
        emit TradeFunded(intentId, amount);
    }

    /**
     * @notice Close a trade: pull `amount` proceeds back from `tradeDestination`
     *         (which must have approved this vault) and clear the exposure. The
     *         trade clears exactly its ORIGINAL draw from `outstanding` — never
     *         more, never less (§5.4) — regardless of whether it returned a
     *         profit or a loss. Realized P&L = amount − drawn stays in the vault
     *         (self-growing war chest); the owner harvests via `withdraw`.
     *
     *         `amount` may be anything (profit, loss, or zero total loss):
     *         returning USDC INTO the vault is always safe and never feeds an
     *         exit path (§5.7). No cap gates a return.
     */
    function returnProceeds(uint256 intentId, uint256 amount)
        external onlyTrader nonReentrant
    {
        Trade storage t = _trades[intentId];
        if (t.status != TradeStatus.Open) revert TradeNotOpen();

        uint256 drawn = t.drawn;

        // ── Effects (before interaction) ────────────────────────────────────
        outstanding -= drawn;          // clears exactly the original draw
        t.returned = amount;
        t.status   = TradeStatus.Closed;

        // ── Interaction ─────────────────────────────────────────────────────
        if (amount > 0) {
            payToken.safeTransferFrom(tradeDestination, address(this), amount);
        }

        // USDC amounts (6-dec) are bounded by total supply (~1e16), far below
        // int256 max (~5.7e76) — neither cast can truncate. Informational only.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 pnl = int256(amount) - int256(drawn);
        emit TradeClosed(intentId, drawn, amount, pnl);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                                VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Idle capital physically held by the vault and free to draw or
    ///         withdraw. Because `drawForTrade` transfers USDC OUT to the rail,
    ///         the vault's token balance already nets out at-rail (outstanding)
    ///         capital — idle == balanceOf(vault). (Reconciliation of the spec's
    ///         `balance − outstanding`, which double-counts under the ratified
    ///         physical-transfer custody model; see SPEC_FundingVault §4 note.)
    function available() public view returns (uint256) {
        return payToken.balanceOf(address(this));
    }

    /// @notice USDC still drawable in the current rolling window, accounting for
    ///         a window that has already elapsed (which resets the counter).
    function drawableToday() external view returns (uint256) {
        uint256 drawnThisWindow = dailyDrawn;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= windowStart + WINDOW_SIZE) {
            drawnThisWindow = 0; // a draw right now would first roll the window
        }
        return dailyDrawCap > drawnThisWindow ? dailyDrawCap - drawnThisWindow : 0;
    }

    /// @notice The per-intent trade record (the receipt row).
    function getTrade(uint256 intentId)
        external view returns (uint256 drawn, uint256 returned, TradeStatus status)
    {
        Trade storage t = _trades[intentId];
        return (t.drawn, t.returned, t.status);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                               INTERNALS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Roll the rolling window if 24h elapsed, then consume `amount`
    ///         against the daily cap. Mirrors Payments' _consumeUsdcDailyLimit.
    function _consumeDailyDraw(uint256 amount) internal {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= windowStart + WINDOW_SIZE) {
            windowStart = block.timestamp;
            dailyDrawn  = 0;
        }
        if (dailyDrawn + amount > dailyDrawCap) revert DailyCapExceeded();
        dailyDrawn += amount;
    }

    function _capValue(Cap cap) internal view returns (uint256) {
        if (cap == Cap.PerTrade)    return maxPerTrade;
        if (cap == Cap.Outstanding) return maxOutstanding;
        return dailyDrawCap; // Cap.DailyDraw
    }

    function _setCap(Cap cap, uint256 v) internal {
        if (cap == Cap.PerTrade)         maxPerTrade    = v;
        else if (cap == Cap.Outstanding) maxOutstanding = v;
        else                             dailyDrawCap   = v; // Cap.DailyDraw
    }
}
