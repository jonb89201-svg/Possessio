// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioWhiskyMarket} from "../src/PossessioWhiskyMarket.sol";

/*//////////////////////////////////////////////////////////////
                              MOCKS
//////////////////////////////////////////////////////////////*/

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Only the surface whisky calls: receiveInfraFunds pulls approved USDC.
///      Optionally re-enters settle() to prove the nonReentrant/settled guards.
contract MockPool {
    IERC20 public immutable usdc;
    uint256 public totalReceived;
    bool public reenter;
    address public market;
    uint256 public reenterId;

    constructor(address _usdc) { usdc = IERC20(_usdc); }
    function arm(address _market, uint256 _id) external { reenter = true; market = _market; reenterId = _id; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
        if (reenter) { PossessioWhiskyMarket(market).settle(reenterId); } // must be blocked
    }
}

/// @dev IPolicyRegistry surface whisky calls: policyExists + isAuthorized.
contract MockPolicy {
    mapping(uint64 => bool) public exists;
    mapping(uint64 => mapping(address => bool)) public auth;
    function setExists(uint64 id, bool e) external { exists[id] = e; }
    function setAuth(uint64 id, address a, bool v) external { auth[id][a] = v; }
    function policyExists(uint64 id) external view returns (bool) { return exists[id]; }
    function isAuthorized(uint64 id, address a) external view returns (bool) { return auth[id][a]; }
}

/// @dev IB20 surface whisky calls: decimals + transferFromWithMemo. Tracks the
///      last delivery so we can assert amount + memo (delivery-order ref).
contract MockB20 {
    uint8 internal immutable _dec;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;
    bytes32 public lastMemo;
    uint256 public transferCount;

    constructor(uint8 d) { _dec = d; }
    function decimals() external view returns (uint8) { return _dec; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt; return true;
    }
    function transferFromWithMemo(address from, address to, uint256 amt, bytes32 memo) external returns (bool) {
        require(allowance[from][msg.sender] >= amt, "B20: allowance");
        require(balanceOf[from] >= amt, "B20: balance");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        lastFrom = from; lastTo = to; lastAmount = amt; lastMemo = memo; transferCount++;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
                             GAUNTLET
//////////////////////////////////////////////////////////////*/

/// @notice FIRST test coverage for PossessioWhiskyMarket (was ZERO — the single
///         largest untested surface in the repo, 313 LOC). Adversarial: access
///         control, membership fail-safes, whole-bottle enforcement, escrow/refund
///         accounting, anti-snipe, settle atomicity, reentrancy, and the fee/seller/
///         lot split. Not a freeze certificate — a first gauntlet the contract asked
///         for ("PROPOSED / NON-PROVEN. Cold-seat re-audit before ratification.").
contract PossessioWhiskyMarketGauntlet is Test {
    MockUSDC   usdc;
    MockPool   pool;
    MockPolicy policy;
    MockB20    lot;
    PossessioWhiskyMarket mkt;

    address constant HOLDING = address(0x110D);
    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant CAROL   = address(0xCA401); // non-member

    uint64  constant PID = 1;
    uint16  constant FEE_BPS = 250;        // 2.5%
    uint256 constant WINDOW = 300;         // anti-snipe window (s)
    uint256 constant EXT    = 600;         // anti-snipe extension (s)
    uint256 constant MIN_INC = 500;        // 5% min increment
    uint256 constant BPS = 10_000;

    uint256 constant ONE_BOTTLE = 1e6;     // 6-dec token
    uint256 constant LOT_AMT = 10 * ONE_BOTTLE; // 10 bottles
    uint256 constant RESERVE = 1_000e6;    // 1000 USDC
    bytes32 constant DELIVERY = keccak256("DO-2026-001");

    function setUp() public {
        usdc   = new MockUSDC();
        pool   = new MockPool(address(usdc));
        policy = new MockPolicy();
        lot    = new MockB20(6);

        policy.setExists(PID, true);
        policy.setAuth(PID, HOLDING, true);
        policy.setAuth(PID, ALICE, true);
        policy.setAuth(PID, BOB, true);
        // CAROL intentionally not authorized

        mkt = new PossessioWhiskyMarket(
            address(usdc), address(pool), address(policy),
            PID, HOLDING, FEE_BPS, WINDOW, EXT, MIN_INC
        );

        // seller (holding co) holds the lot + grants the market an allowance
        lot.mint(HOLDING, LOT_AMT);
        vm.prank(HOLDING);
        lot.approve(address(mkt), LOT_AMT);

        // fund bidders + approve the market to pull USDC
        for (uint256 i; i < 2; i++) {
            address b = i == 0 ? ALICE : BOB;
            usdc.mint(b, 100_000e6);
            vm.prank(b);
            usdc.approve(address(mkt), type(uint256).max);
        }
        usdc.mint(CAROL, 100_000e6);
        vm.prank(CAROL);
        usdc.approve(address(mkt), type(uint256).max);
    }

    function _list() internal returns (uint256 id) {
        vm.prank(HOLDING);
        id = mkt.listAuction(address(lot), LOT_AMT, RESERVE, uint64(block.timestamp), 1000, DELIVERY);
    }

    // ============================ LIST: ACCESS + VALIDATION ============================
    function test_list_only_holding_company() public {
        vm.prank(ALICE);
        vm.expectRevert(PossessioWhiskyMarket.NotHoldingCompany.selector);
        mkt.listAuction(address(lot), LOT_AMT, RESERVE, uint64(block.timestamp), 1000, DELIVERY);
    }
    function test_list_whole_bottle_enforced() public {
        vm.prank(HOLDING);
        vm.expectRevert(PossessioWhiskyMarket.NotWholeBottle.selector);
        mkt.listAuction(address(lot), LOT_AMT + 1, RESERVE, uint64(block.timestamp), 1000, DELIVERY);
    }
    function test_list_zero_amount_reverts() public {
        vm.prank(HOLDING);
        vm.expectRevert(PossessioWhiskyMarket.NotWholeBottle.selector);
        mkt.listAuction(address(lot), 0, RESERVE, uint64(block.timestamp), 1000, DELIVERY);
    }
    function test_list_zero_duration_reverts() public {
        vm.prank(HOLDING);
        vm.expectRevert(PossessioWhiskyMarket.BadWindow.selector);
        mkt.listAuction(address(lot), LOT_AMT, RESERVE, uint64(block.timestamp), 0, DELIVERY);
    }
    // NOTE (finding): ReserveTooLowForFee's fee-coverage half — (reserve*FEE_BPS)/BPS
    // >= reserve — is unreachable for any valid FEE_BPS (< BPS, enforced in the ctor).
    // So the "reserve must exceed the fee it owes" guarantee is really just reserve!=0.
    // A 1-wei reserve passes (fee rounds to 0). Documented, not a revert we can force
    // for a nonzero reserve.
    function test_list_zero_reserve_reverts() public {
        vm.prank(HOLDING);
        vm.expectRevert(PossessioWhiskyMarket.ReserveTooLowForFee.selector);
        mkt.listAuction(address(lot), LOT_AMT, 0, uint64(block.timestamp), 1000, DELIVERY);
    }

    // ============================ BID: MEMBERSHIP + FLOORS ============================
    function test_bid_non_member_reverts() public {
        uint256 id = _list();
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(PossessioWhiskyMarket.NotMember.selector, CAROL));
        mkt.bid(id, RESERVE);
    }
    function test_bid_below_reserve_reverts() public {
        uint256 id = _list();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PossessioWhiskyMarket.BidTooLow.selector, RESERVE));
        mkt.bid(id, RESERVE - 1);
    }
    function test_bid_below_increment_reverts() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        uint256 floor = RESERVE + (RESERVE * MIN_INC) / BPS + 1;
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PossessioWhiskyMarket.BidTooLow.selector, floor));
        mkt.bid(id, floor - 1);
    }
    function test_bid_not_found_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(PossessioWhiskyMarket.AuctionNotFound.selector);
        mkt.bid(999, RESERVE);
    }
    function test_bid_after_end_reverts() public {
        uint256 id = _list();
        vm.warp(block.timestamp + 1001);
        vm.prank(ALICE);
        vm.expectRevert(PossessioWhiskyMarket.AuctionEnded.selector);
        mkt.bid(id, RESERVE);
    }

    // ============================ ESCROW + REFUND ACCOUNTING ============================
    function test_bid_escrows_and_refunds_previous_exactly() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        assertEq(usdc.balanceOf(address(mkt)), RESERVE, "market escrows the top bid");

        uint256 aliceBefore = usdc.balanceOf(ALICE);
        uint256 topBid = RESERVE + (RESERVE * MIN_INC) / BPS + 1;
        vm.prank(BOB);
        mkt.bid(id, topBid);

        // prior top bidder refunded EXACTLY their bid; contract now holds only the new top
        assertEq(usdc.balanceOf(ALICE), aliceBefore + RESERVE, "outbid refunds prior bidder exactly");
        assertEq(usdc.balanceOf(address(mkt)), topBid, "market holds only the current top bid");
    }

    // ============================ ANTI-SNIPE ============================
    function test_antisnipe_extends_inside_window() public {
        uint256 id = _list();
        (,,, uint64 endBefore,,,,,) = mkt.auctions(id);
        vm.warp(uint256(endBefore) - 100); // inside the 300s window
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        (,,, uint64 endAfter,,,,,) = mkt.auctions(id);
        assertEq(endAfter, uint64(block.timestamp) + uint64(EXT), "clock extends by the extension");
        assertGt(endAfter, endBefore, "anti-snipe pushed the end out");
    }
    function test_antisnipe_no_extend_outside_window() public {
        uint256 id = _list();
        (,,, uint64 endBefore,,,,,) = mkt.auctions(id);
        vm.warp(block.timestamp + 100); // well outside the window
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        (,,, uint64 endAfter,,,,,) = mkt.auctions(id);
        assertEq(endAfter, endBefore, "no extension outside the anti-snipe window");
    }

    // ============================ SETTLE: TIMING + IDEMPOTENCE ============================
    function test_settle_before_end_reverts() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        vm.expectRevert(PossessioWhiskyMarket.AuctionLive.selector);
        mkt.settle(id);
    }
    function test_settle_twice_reverts() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        vm.warp(block.timestamp + 1001);
        mkt.settle(id);
        vm.expectRevert(PossessioWhiskyMarket.AlreadySettled.selector);
        mkt.settle(id);
    }

    // ============================ SETTLE: FAIL-SAFES (no sale) ============================
    function test_settle_no_bids_fails_safe() public {
        uint256 id = _list();
        vm.warp(block.timestamp + 1001);
        mkt.settle(id);
        assertEq(lot.transferCount(), 0, "no bids => lot never moves");
        assertEq(usdc.balanceOf(address(mkt)), 0, "no escrow held");
        (,,,,,,,, bool settled) = mkt.auctions(id);
        assertTrue(settled, "auction marked settled even on no-sale");
    }
    function test_settle_winner_blocked_refunds_no_lot_no_fee() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        // ALICE de-allowlisted before settle (mid-auction revocation)
        policy.setAuth(PID, ALICE, false);
        vm.warp(block.timestamp + 1001);

        uint256 aliceBefore = usdc.balanceOf(ALICE);
        mkt.settle(id);

        assertEq(usdc.balanceOf(ALICE), aliceBefore + RESERVE, "blocked winner fully refunded");
        assertEq(lot.transferCount(), 0, "lot never delivered to a blocked winner");
        assertEq(pool.totalReceived(), 0, "no fee to pool on a failed sale");
    }

    // ============================ SETTLE: HAPPY PATH SPLIT ============================
    function test_settle_splits_fee_seller_and_delivers_lot() public {
        uint256 id = _list();
        uint256 price = RESERVE;
        vm.prank(ALICE);
        mkt.bid(id, price);
        vm.warp(block.timestamp + 1001);

        uint256 sellerBefore = usdc.balanceOf(HOLDING);
        mkt.settle(id);

        uint256 fee = (price * FEE_BPS) / BPS;
        assertEq(pool.totalReceived(), fee, "exact fee routed to the pool (accounted door)");
        assertEq(usdc.balanceOf(HOLDING), sellerBefore + (price - fee), "seller nets price - fee");
        assertEq(usdc.balanceOf(address(mkt)), 0, "no USDC stranded in the market");

        // lot delivered to the winner with the delivery-order ref in the memo
        assertEq(lot.transferCount(), 1, "lot delivered exactly once");
        assertEq(lot.lastTo(), ALICE, "lot to the winner");
        assertEq(lot.lastFrom(), HOLDING, "lot pulled from the seller");
        assertEq(lot.lastAmount(), LOT_AMT, "full lot amount delivered");
        assertEq(lot.lastMemo(), DELIVERY, "delivery-order ref written to the B20 memo");
        assertEq(lot.balanceOf(ALICE), LOT_AMT, "winner holds the bottles");
    }

    function test_settle_permissionless_anyone_can_call() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        vm.warp(block.timestamp + 1001);
        // a random non-member settles — settle is permissionless by design
        vm.prank(CAROL);
        mkt.settle(id);
        assertEq(lot.lastTo(), ALICE, "settle by a third party still delivers to the real winner");
    }

    // ============================ SETTLE: ATOMICITY ============================
    // If lot delivery fails (seller revoked the market's allowance after winning),
    // the WHOLE settle reverts — no fee-to-pool, no seller payout, no half-state.
    function test_settle_atomic_when_lot_delivery_fails() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        vm.warp(block.timestamp + 1001);

        // seller yanks the lot allowance -> transferFromWithMemo will revert
        vm.prank(HOLDING);
        lot.approve(address(mkt), 0);

        vm.expectRevert(bytes("B20: allowance"));
        mkt.settle(id);

        // nothing moved: escrow intact, no fee, not settled
        assertEq(usdc.balanceOf(address(mkt)), RESERVE, "escrow intact after reverted settle");
        assertEq(pool.totalReceived(), 0, "no fee moved");
        (,,,,,,,, bool settled) = mkt.auctions(id);
        assertFalse(settled, "settled flag rolled back with the revert");
    }

    // ============================ SETTLE: REENTRANCY ============================
    // A malicious pool re-entering settle() during receiveInfraFunds cannot
    // double-settle: the nonReentrant guard reverts the whole tx.
    function test_settle_reentrancy_blocked() public {
        uint256 id = _list();
        vm.prank(ALICE);
        mkt.bid(id, RESERVE);
        vm.warp(block.timestamp + 1001);
        pool.arm(address(mkt), id); // re-enter settle(id) on fee receipt
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        mkt.settle(id);
    }

    // ============================ FUZZ: BID MONOTONICITY ============================
    function testFuzz_accepted_bids_strictly_increase(uint256 b1, uint256 b2) public {
        uint256 id = _list();
        b1 = bound(b1, RESERVE, 50_000e6);
        uint256 floor2 = b1 + (b1 * MIN_INC) / BPS + 1;
        b2 = bound(b2, floor2, 100_000e6);

        vm.prank(ALICE);
        mkt.bid(id, b1);
        (,,,,, address hb1, uint256 hbid1,,) = mkt.auctions(id);
        assertEq(hb1, ALICE); assertEq(hbid1, b1);

        vm.prank(BOB);
        mkt.bid(id, b2);
        (,,,,, address hb2, uint256 hbid2,,) = mkt.auctions(id);
        assertEq(hb2, BOB, "new top bidder recorded");
        assertGt(hbid2, hbid1, "accepted bid strictly beats the prior top");
        assertEq(usdc.balanceOf(address(mkt)), b2, "only the current top is escrowed");
    }
}
