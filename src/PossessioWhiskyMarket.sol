// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IPolicyRegistry} from "base-std/interfaces/IPolicyRegistry.sol";

/**
 * @title PossessioWhiskyMarket ("The Bond") — primary English auction module
 * @notice v0.1, PROPOSED / NON-PROVEN. Cold-seat re-audit before ratification.
 *         The seat that wrote this does not certify it.
 *
 *         Tokenized ALLOCATED whisky: one B20 Asset lot token = the bottles of a
 *         release, held in a bonded warehouse. This contract runs the LIVE
 *         (Habanos-style) English auction — scheduled start, short window,
 *         anti-snipe extension — with USDC settlement, a bps fee skimmed to the
 *         one PossessioPool, and the delivery-order ref written into the B20 memo.
 *
 *         SCOPE (v0.1): PRIMARY English auctions only. Secondary member order
 *         book is the next module (SPEC §4), not in this file.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * ARCHITECT DESIGN CALLS baked in here (SPEC left open — veto any):
 *
 *  D-BID  USDC bids are ESCROWED (binding — paddle up = money committed). The
 *         market holds only the current TOP bid's USDC; every out-bid is
 *         refunded immediately. This reads DoD #5 "non-custodial" as the LOT
 *         TOKENS (SPEC §4: "never warehouses TOKENS longer than a settlement") —
 *         the whisky tokens are pulled from the seller only at settle. If you
 *         want zero USDC custody too, we switch to allowance-only bids (weaker:
 *         a winner can yank funds before settle). Escrow is the honest live-
 *         auction default.
 *  D-ARCH Membership = SPEC §3 option (a), V1-proven: gate on the shared
 *         PolicyRegistry ALLOWLIST at the market layer (isAuthorized), token
 *         layer enforces the same on transfer (defense in depth).
 *  D-BOTTLE Whole-bottle enforced: lot amount must be a whole multiple of one
 *         bottle unit (10**decimals). Token stays 6-dec; no fractional bottles.
 *  D-FAIL Fail-safe: below reserve, or a winner no longer allowlisted at settle
 *         -> NO SALE, top bid refunded, lot never left the seller.
 * ─────────────────────────────────────────────────────────────────────────────
 */
interface IPossessioPool {
    /// @notice Accounted inflow. The market approves USDC, then the pool pulls `amount`.
    function receiveInfraFunds(uint256 amount) external;
}

contract PossessioWhiskyMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable USDC;                 // settlement currency (6-dec on Base)
    IPossessioPool public immutable POOL;         // the one bloodstream — fee sink
    IPolicyRegistry public immutable POLICY;      // B20 policy registry singleton
    uint64 public immutable MEMBERSHIP_POLICY_ID; // shared KYC/jurisdiction ALLOWLIST
    address public immutable HOLDING_COMPANY;     // sole lister (owner-of-record entity)
    uint16 public immutable FEE_BPS;              // settlement fee, immutable (calibrate pre-freeze)
    uint256 public immutable ANTI_SNIPE_WINDOW;   // a bid within this of end extends the clock
    uint256 public immutable ANTI_SNIPE_EXTENSION;// by this many seconds
    uint256 public immutable MIN_INCREMENT_BPS;   // each bid must beat the last by >= this

    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Auction {
        address lotToken;      // B20 Asset lot token
        uint256 amount;        // whole-bottle multiple (bottles * 10**decimals)
        uint256 reserve;       // min USDC to sell
        uint64  endTime;       // extends on anti-snipe
        address seller;        // == HOLDING_COMPANY at list; kept explicit
        address highBidder;
        uint256 highBid;       // escrowed USDC held by this contract
        bytes32 deliveryRef;   // written to the B20 memo on settle
        bool    settled;
    }

    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuctionListed(uint256 indexed id, address indexed lotToken, uint256 amount, uint256 reserve, uint64 endTime, bytes32 deliveryRef);
    event BidPlaced(uint256 indexed id, address indexed bidder, uint256 amount, uint64 newEndTime);
    event Refunded(uint256 indexed id, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed id, address indexed winner, uint256 price, uint256 fee);
    event AuctionFailed(uint256 indexed id, string reason);
    event FeeToPool(uint256 indexed id, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotHoldingCompany();
    error NotMember(address who);
    error ZeroAddress();
    error BadFee();
    error PolicyMissing();
    error NotWholeBottle();
    error BadWindow();
    error AuctionNotFound();
    error AuctionEnded();
    error AuctionLive();
    error AlreadySettled();
    error BidTooLow(uint256 min);
    error ReserveTooLowForFee();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address usdc,
        address pool,
        address policyRegistry,
        uint64 membershipPolicyId,
        address holdingCompany,
        uint16 feeBps,
        uint256 antiSnipeWindow,
        uint256 antiSnipeExtension,
        uint256 minIncrementBps
    ) {
        if (usdc == address(0) || pool == address(0) || policyRegistry == address(0) || holdingCompany == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps >= BPS) revert BadFee();
        // SPEC §2 CRITICAL: a non-existent ALLOWLIST denies everyone. Validate at write time.
        if (!IPolicyRegistry(policyRegistry).policyExists(membershipPolicyId)) revert PolicyMissing();
        if (antiSnipeExtension == 0 && antiSnipeWindow != 0) revert BadWindow();

        USDC = IERC20(usdc);
        POOL = IPossessioPool(pool);
        POLICY = IPolicyRegistry(policyRegistry);
        MEMBERSHIP_POLICY_ID = membershipPolicyId;
        HOLDING_COMPANY = holdingCompany;
        FEE_BPS = feeBps;
        ANTI_SNIPE_WINDOW = antiSnipeWindow;
        ANTI_SNIPE_EXTENSION = antiSnipeExtension;
        MIN_INCREMENT_BPS = minIncrementBps;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHoldingCo() {
        if (msg.sender != HOLDING_COMPANY) revert NotHoldingCompany();
        _;
    }

    function _requireMember(address who) internal view {
        if (!POLICY.isAuthorized(MEMBERSHIP_POLICY_ID, who)) revert NotMember(who);
    }

    /*//////////////////////////////////////////////////////////////
                          LIST (holding co)
    //////////////////////////////////////////////////////////////*/

    /// @notice List a lot for a live English auction. The holding company keeps
    ///         the lot tokens and grants this market an allowance of `amount`;
    ///         they are pulled to the winner only at settle (non-custodial).
    /// @dev Reserve must exceed the fee it will owe, so the seller can never net
    ///      negative. Whole-bottle enforced against the token's own decimals.
    function listAuction(
        address lotToken,
        uint256 amount,
        uint256 reserve,
        uint64 startTime,
        uint64 duration,
        bytes32 deliveryRef
    ) external onlyHoldingCo returns (uint256 id) {
        if (lotToken == address(0)) revert ZeroAddress();
        if (duration == 0) revert BadWindow();

        uint256 oneBottle = 10 ** uint256(IB20(lotToken).decimals());
        if (amount == 0 || amount % oneBottle != 0) revert NotWholeBottle();

        // reserve must cover the fee it would owe (seller nets >= 0 on a reserve sale)
        if (reserve == 0 || (reserve * FEE_BPS) / BPS >= reserve) revert ReserveTooLowForFee();

        uint64 start = startTime < uint64(block.timestamp) ? uint64(block.timestamp) : startTime;
        uint64 end = start + duration;

        id = nextAuctionId++;
        auctions[id] = Auction({
            lotToken: lotToken,
            amount: amount,
            reserve: reserve,
            endTime: end,
            seller: HOLDING_COMPANY,
            highBidder: address(0),
            highBid: 0,
            deliveryRef: deliveryRef,
            settled: false
        });

        emit AuctionListed(id, lotToken, amount, reserve, end, deliveryRef);
    }

    /*//////////////////////////////////////////////////////////////
                                 BID
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a binding bid. USDC is escrowed here; the prior top bidder
    ///         is refunded in the same tx. A bid in the anti-snipe window extends
    ///         the clock — the "going once, going twice" of a live sale.
    function bid(uint256 id, uint256 amount) external nonReentrant {
        Auction storage a = auctions[id];
        if (a.lotToken == address(0)) revert AuctionNotFound();
        if (block.timestamp >= a.endTime) revert AuctionEnded();
        _requireMember(msg.sender);

        uint256 floor = a.highBid == 0
            ? a.reserve
            : a.highBid + (a.highBid * MIN_INCREMENT_BPS) / BPS + 1;
        if (amount < floor) revert BidTooLow(floor);

        // effects: record new top, remember who to refund
        address prevBidder = a.highBidder;
        uint256 prevBid = a.highBid;
        a.highBidder = msg.sender;
        a.highBid = amount;

        // anti-snipe: extend if inside the window
        if (ANTI_SNIPE_WINDOW != 0 && a.endTime - block.timestamp <= ANTI_SNIPE_WINDOW) {
            a.endTime = uint64(block.timestamp) + uint64(ANTI_SNIPE_EXTENSION);
        }

        // interactions: pull the new bid, refund the old one (CEI: state already updated)
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        if (prevBidder != address(0)) {
            USDC.safeTransfer(prevBidder, prevBid);
            emit Refunded(id, prevBidder, prevBid);
        }

        emit BidPlaced(id, msg.sender, amount, a.endTime);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle after the clock runs out. Anyone may call. Sale only if the
    ///         top bid met reserve AND the winner is still a member; otherwise the
    ///         top bid is refunded and the lot never moved (fail-safe).
    function settle(uint256 id) external nonReentrant {
        Auction storage a = auctions[id];
        if (a.lotToken == address(0)) revert AuctionNotFound();
        if (a.settled) revert AlreadySettled();
        if (block.timestamp < a.endTime) revert AuctionLive();

        a.settled = true; // effects before interactions

        // no bids, or under reserve -> no sale
        if (a.highBidder == address(0) || a.highBid < a.reserve) {
            if (a.highBidder != address(0)) {
                USDC.safeTransfer(a.highBidder, a.highBid);
                emit Refunded(id, a.highBidder, a.highBid);
            }
            emit AuctionFailed(id, "no-sale");
            return;
        }

        // winner must still be allowlisted (fail-safe on a mid-auction revocation)
        if (!POLICY.isAuthorized(MEMBERSHIP_POLICY_ID, a.highBidder)) {
            USDC.safeTransfer(a.highBidder, a.highBid);
            emit Refunded(id, a.highBidder, a.highBid);
            emit AuctionFailed(id, "winner-blocked");
            return;
        }

        uint256 price = a.highBid;
        uint256 fee = (price * FEE_BPS) / BPS;
        uint256 sellerNet = price - fee;

        // fee -> the one pool via the ACCOUNTED door (approve + pull)
        if (fee > 0) {
            USDC.forceApprove(address(POOL), fee);
            POOL.receiveInfraFunds(fee);
            emit FeeToPool(id, fee);
        }
        // seller proceeds
        USDC.safeTransfer(a.seller, sellerNet);

        // deliver the lot to the winner, delivery-order ref in the memo.
        // seller must have kept an allowance to this market; token layer also
        // enforces membership on both legs (defense in depth).
        IB20(a.lotToken).transferFromWithMemo(a.seller, a.highBidder, a.amount, a.deliveryRef);

        emit AuctionSettled(id, a.highBidder, price, fee);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function isMember(address who) external view returns (bool) {
        return POLICY.isAuthorized(MEMBERSHIP_POLICY_ID, who);
    }

    function timeLeft(uint256 id) external view returns (uint256) {
        uint64 end = auctions[id].endTime;
        return block.timestamp >= end ? 0 : end - block.timestamp;
    }
}
