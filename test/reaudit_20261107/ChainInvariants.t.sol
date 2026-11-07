// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  RE-AUDIT 2026-11-07: chained invariants. Do the findings combine?

    One merchant owner (OWNER) and one stolen co-owner key (THIEF), the R-1
    setting. The fuzzer drives every owner move for both keys, in any order,
    with every timelock id ever issued offered to every execute (stale and
    foreign ids included), plus kicks, takes by a thief-run taker and time
    jumps. The thief may bundle moves in one block.

    The merchant is modelled as alert but human: before time moves on, once at
    least REACT has passed since it last looked, it cancels everything it did
    not start (an EVIL grant, a revoke of OWNER, an EVIL payee, a thief-queued
    raise or emergency exit, an EVIL forwarder), re-pauses if it wants auctions
    paused, re-queues its own resume so a thief's resume id cannot mature, and
    re-proposes its payee. REACT (6 h) is far inside every 48 h / 7 d window,
    which is the v3.0.3 assumption: "visible in time to cancel it".

    Invariants (each a way the lows could chain into something worse):
      A  no theft: EVIL (the thief's own address) never receives USDC or cbETH
      B  OWNER keeps OWNER_ROLE; EVIL never gets it
      C  the automation forwarder is never the thief's (R-2 forwarder path)
      D  while the merchant wants auctions paused, no lot is kicked or taken
         (R-2 resume path, chained with a thief-run taker)
      E  every USDC exit obeys a reference leaky bucket that settles at the old
         rate when a raise applies (R-3)
      F  the thief-run taker never buys USDC below the 0.99 floor at the oracle

    Results are MEASURED in the PR body, against the review branch and against
    the two fixes together. This file needs both fixes (R-2, R-3) to pass. R-1's freeze is not an invariant here: it is proven
    on its own and breaks by construction.
*/

import "forge-std/Test.sol";
import {PaymentsV3Base} from "../v3/Base.sol";
import {PossessioPayments} from "../../src/PossessioPayments.sol";
import {MockUSDC_V3, MockCbETH_V3, MockFeed_V3} from "../v3/PaymentsV3Mocks.sol";

contract ChainHandler is Test {
    PossessioPayments pay;
    MockUSDC_V3  usdc;
    MockCbETH_V3 cbeth;
    MockFeed_V3  feedCb;
    MockFeed_V3  feedUsdc;
    MockFeed_V3  feedEth;

    address OWNER;
    address THIEF;
    address PAYEE;
    address EVIL       = makeAddr("evil");
    address EVIL_TAKER = makeAddr("evil-taker");
    address EVIL_FWD   = makeAddr("evil-forwarder");
    address GOOD_FWD;

    uint256 constant REACT  = 6 hours;
    uint256 constant WINDOW = 24 hours;
    uint256 constant ONE    = 1e18;

    bytes32[] public ids;
    uint256 lastLook;

    // merchant intent and thief-started queues (what the merchant would not recognise)
    bool public merchantWantsPause;
    bool thiefQueuedUsdcRaise;
    bool thiefQueuedCbRaise;
    bool thiefQueuedEmergencyUsdc;
    bool thiefQueuedEmergencyCb;
    bool evilForwarderPending;

    // reference USDC bucket (E)
    uint256 refSpent;
    uint256 refTs;
    uint256 refLimit;

    // ghosts
    uint256 public ghostKickWhilePaused;
    uint256 public ghostTakeWhilePaused;
    uint256 public ghostBucketOverrun;
    uint256 public ghostTakeBelowFloor;
    uint256 public calls;

    constructor(
        PossessioPayments pay_, MockUSDC_V3 usdc_, MockCbETH_V3 cbeth_,
        MockFeed_V3 feedCb_, MockFeed_V3 feedUsdc_, MockFeed_V3 feedEth_,
        address owner_, address thief_, address payee_, address goodFwd_
    ) {
        pay = pay_; usdc = usdc_; cbeth = cbeth_;
        feedCb = feedCb_; feedUsdc = feedUsdc_; feedEth = feedEth_;
        OWNER = owner_; THIEF = thief_; PAYEE = payee_; GOOD_FWD = goodFwd_;
        lastLook = block.timestamp;
        refLimit = pay.usdcDailyLimit();
        refTs = block.timestamp;
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _id(uint256 i) internal view returns (bytes32) {
        if (ids.length == 0) return bytes32(i);
        return ids[i % ids.length];
    }

    function _push(bytes32 id) internal { if (id != bytes32(0)) ids.push(id); }

    function _fresh() internal {
        feedCb.setAnswer(feedCb._answer());
        feedUsdc.setAnswer(feedUsdc._answer());
        feedEth.setAnswer(feedEth._answer());
    }

    function _refDrained(uint256 at) internal view returns (uint256) {
        uint256 elapsed = at - refTs;
        if (elapsed >= WINDOW) return 0;
        uint256 refill = (refLimit * elapsed) / WINDOW;
        return refSpent > refill ? refSpent - refill : 0;
    }

    /// A USDC exit went through: check it against the reference bucket.
    function _refSpend(uint256 amount) internal {
        uint256 s = _refDrained(block.timestamp);
        if (s + amount > refLimit) ghostBucketOverrun++;
        refSpent = s + amount;
        refTs = block.timestamp;
    }

    function _oracleCbEth(uint256 usdcAmt) internal view returns (uint256) {
        uint256 ethWei = (usdcAmt * 1e12 * uint256(feedUsdc._answer())) / uint256(feedEth._answer());
        return (ethWei * ONE) / uint256(feedCb._answer());
    }

    function _isLotUsdc(uint256 before) internal view returns (bool) {
        (uint128 u,,) = pay.lot();
        return u != 0 && before == 0;
    }

    // ── time and the merchant's look ────────────────────────────────────

    function warp(uint256 dt) external {
        calls++;
        dt = bound(dt, 1 minutes, REACT);
        if (block.timestamp + dt >= lastLook + REACT) _merchantLooks();
        vm.warp(block.timestamp + dt);
        _fresh();
    }

    function _merchantLooks() internal {
        vm.startPrank(OWNER);
        if (pay.pendingOwnerGrant(EVIL) != 0) pay.cancelOwnerGrant(EVIL);
        if (pay.pendingOwnerRevoke(OWNER) != 0) pay.cancelOwnerRevoke(OWNER);
        if (pay.payeeActiveAt(EVIL) != 0) pay.removePayee(EVIL);
        if (pay.payeeActiveAt(PAYEE) == 0) pay.proposePayee(PAYEE);
        if (thiefQueuedUsdcRaise) {
            try pay.cancelAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.USDC) {} catch {}
            thiefQueuedUsdcRaise = false;
        }
        if (thiefQueuedCbRaise) {
            try pay.cancelAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.CBETH) {} catch {}
            thiefQueuedCbRaise = false;
        }
        if (thiefQueuedEmergencyUsdc) { try pay.cancelEmergencyWithdraw(address(usdc)) {} catch {} thiefQueuedEmergencyUsdc = false; }
        if (thiefQueuedEmergencyCb)   { try pay.cancelEmergencyWithdraw(address(cbeth)) {} catch {} thiefQueuedEmergencyCb = false; }
        if (evilForwarderPending) { _push(pay.queueForwarderUpdate(GOOD_FWD)); evilForwarderPending = false; }
        if (merchantWantsPause) {
            if (!pay.auctionsPaused()) pay.pauseAuctions();
            _push(pay.queueResumeAuctions());      // replaces a thief's id where ids are bound
        }
        vm.stopPrank();
        lastLook = block.timestamp;
    }

    // ── the merchant's own moves ────────────────────────────────────────

    function m_send(uint256 amount) external {
        calls++;
        amount = bound(amount, 1e6, 12_000e6);
        vm.prank(OWNER);
        try pay.sendUSDC(amount, PAYEE) { _refSpend(amount); } catch {}
    }

    function m_raiseUsdc(uint256 mult) external {
        calls++;
        uint256 newLimit = (pay.usdcDailyLimit() * bound(mult, 101, 200)) / 100;
        vm.prank(OWNER);
        try pay.queueAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.USDC, newLimit) {
            thiefQueuedUsdcRaise = false;   // the queued raise is now the merchant's
        } catch {}
    }

    function m_executeRaiseUsdc() external {
        calls++;
        if (thiefQueuedUsdcRaise) return;   // the merchant executes only its own raise
        (uint256 newLimit,) = pay.queuedAssetLimitIncrease(uint8(PossessioPayments.DailyLimitAsset.USDC));
        vm.prank(OWNER);
        try pay.executeAssetDailyLimitIncrease(PossessioPayments.DailyLimitAsset.USDC) {
            refSpent = _refDrained(block.timestamp);   // settle at the old rate
            refTs = block.timestamp;
            refLimit = newLimit;
        } catch {}
    }

    function m_decreaseUsdc(uint256 pct) external {
        calls++;
        uint256 newLimit = (pay.usdcDailyLimit() * bound(pct, 50, 99)) / 100;
        vm.prank(OWNER);
        try pay.decreaseAssetDailyLimit(PossessioPayments.DailyLimitAsset.USDC, newLimit) {
            refLimit = newLimit;   // the contract does not settle on a decrease; neither does the reference
        } catch {}
    }

    /// The merchant's best play: pause, and queue its own resume at once, which
    /// (where ids are bound) replaces any resume id already pending.
    function m_pause() external {
        calls++;
        vm.startPrank(OWNER);
        pay.pauseAuctions();
        _push(pay.queueResumeAuctions());
        vm.stopPrank();
        merchantWantsPause = true;
    }

    function m_fund(uint256 amount) external {
        calls++;
        usdc.mint(address(pay), bound(amount, 100e6, 20_000e6));
    }

    // ── the stolen key ──────────────────────────────────────────────────

    function t_queueGrantEvil() external { calls++; vm.prank(THIEF); try pay.queueOwnerGrant(EVIL) returns (bytes32 id) { _push(id); } catch {} }
    function t_executeGrantEvil(uint256 i) external { calls++; vm.prank(THIEF); try pay.executeOwnerGrant(EVIL, _id(i)) {} catch {} }
    function t_queueRevokeOwner() external { calls++; vm.prank(THIEF); try pay.queueOwnerRevoke(OWNER) returns (bytes32 id) { _push(id); } catch {} }
    function t_executeRevokeOwner(uint256 i) external { calls++; vm.prank(THIEF); try pay.executeOwnerRevoke(OWNER, _id(i)) {} catch {} }
    function t_cancelOwnRevoke() external { calls++; vm.prank(THIEF); try pay.cancelOwnerRevoke(THIEF) {} catch {} }

    function t_proposeEvil() external { calls++; vm.prank(THIEF); try pay.proposePayee(EVIL) {} catch {} }
    function t_removePayee() external { calls++; vm.prank(THIEF); try pay.removePayee(PAYEE) {} catch {} }

    function t_sendUsdc(uint256 amount, bool toEvil) external {
        calls++;
        amount = bound(amount, 1e6, 25_000e6);
        vm.prank(THIEF);
        try pay.sendUSDC(amount, toEvil ? EVIL : PAYEE) { _refSpend(amount); } catch {}
    }

    function t_sendCbEth(uint256 amount) external {
        calls++;
        amount = bound(amount, 1e15, 10 ether);
        vm.prank(THIEF);
        try pay.sendCbETH(amount, EVIL) {} catch {}
    }

    function t_queueEmergency(uint256 amount, bool cb) external {
        calls++;
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(THIEF);
        try pay.queueEmergencyWithdraw(cb ? address(cbeth) : address(usdc), amount) {
            if (cb) thiefQueuedEmergencyCb = true; else thiefQueuedEmergencyUsdc = true;
        } catch {}
    }

    function t_executeEmergency(bool cb) external {
        calls++;
        vm.prank(THIEF);
        try pay.executeEmergencyWithdraw(cb ? address(cbeth) : address(usdc), EVIL) {} catch {}
    }

    function t_cancelEmergency(bool cb) external { calls++; vm.prank(THIEF); try pay.cancelEmergencyWithdraw(cb ? address(cbeth) : address(usdc)) {} catch {} }

    function t_queueRaise(uint256 mult, bool cb) external {
        calls++;
        PossessioPayments.DailyLimitAsset a = cb ? PossessioPayments.DailyLimitAsset.CBETH : PossessioPayments.DailyLimitAsset.USDC;
        uint256 cur = cb ? pay.cbEthDailyLimit() : pay.usdcDailyLimit();
        vm.prank(THIEF);
        try pay.queueAssetDailyLimitIncrease(a, (cur * bound(mult, 101, 200)) / 100) {
            if (cb) thiefQueuedCbRaise = true; else thiefQueuedUsdcRaise = true;
        } catch {}
    }

    function t_executeRaise(bool cb) external {
        calls++;
        PossessioPayments.DailyLimitAsset a = cb ? PossessioPayments.DailyLimitAsset.CBETH : PossessioPayments.DailyLimitAsset.USDC;
        (uint256 newLimit,) = pay.queuedAssetLimitIncrease(uint8(a));
        vm.prank(THIEF);
        try pay.executeAssetDailyLimitIncrease(a) {
            if (!cb) { refSpent = _refDrained(block.timestamp); refTs = block.timestamp; refLimit = newLimit; }
        } catch {}
    }

    function t_cancelRaise(bool cb) external {
        calls++;
        vm.prank(THIEF);
        try pay.cancelAssetDailyLimitIncrease(cb ? PossessioPayments.DailyLimitAsset.CBETH : PossessioPayments.DailyLimitAsset.USDC) {} catch {}
    }

    function t_decrease(uint256 pct) external {
        calls++;
        uint256 newLimit = (pay.usdcDailyLimit() * bound(pct, 0, 99)) / 100;
        vm.prank(THIEF);
        try pay.decreaseAssetDailyLimit(PossessioPayments.DailyLimitAsset.USDC, newLimit) { refLimit = newLimit; } catch {}
    }

    function t_queueResume() external { calls++; vm.prank(THIEF); try pay.queueResumeAuctions() returns (bytes32 id) { _push(id); } catch {} }
    function t_resume(uint256 i) external { calls++; vm.prank(THIEF); try pay.resumeAuctions(_id(i)) {} catch {} }

    function t_queueEvilForwarder() external {
        calls++;
        vm.prank(THIEF);
        try pay.queueForwarderUpdate(EVIL_FWD) returns (bytes32 id) { _push(id); evilForwarderPending = true; } catch {}
    }

    function t_executeForwarder(uint256 i) external { calls++; vm.prank(THIEF); try pay.executeForwarderUpdate(_id(i)) {} catch {} }

    /// Instant settings: make lots as large and frequent as the bounds allow.
    function t_settings(uint256 which, uint256 v) external {
        calls++;
        vm.startPrank(THIEF);
        which = which % 6;
        if (which == 0) try pay.setUsdcFloat(bound(v, 0, 1_000e6)) {} catch {}
        if (which == 1) try pay.setMaxKickUsdc(0) {} catch {}
        if (which == 2) try pay.setMinSwapBatch(bound(v, 1, 100e6)) {} catch {}
        if (which == 3) try pay.setAuctionLength(uint64(bound(v, 10 minutes, 2 hours))) {} catch {}
        if (which == 4) try pay.setKickDelay(uint64(bound(v, 1 hours, 7 days))) {} catch {}
        if (which == 5) try pay.setCbEthBps(uint16(bound(v, 1000, 9000))) {} catch {}
        vm.stopPrank();
    }

    /// The thief's bundle: resume with any id, kick, wait inside the lot (less
    /// than REACT, so the merchant has not looked), and take at whatever the
    /// curve asks, all before the merchant reacts.
    function t_resumeKickTake(uint256 i, uint256 wait) external {
        calls++;
        vm.prank(THIEF);
        try pay.resumeAuctions(_id(i)) {} catch {}
        _fresh();
        (uint128 before,,) = pay.lot();
        vm.prank(EVIL_TAKER);
        try pay.kick() {
            if (merchantWantsPause) ghostKickWhilePaused++;
        } catch {}
        (uint128 u,, uint64 endsAt) = pay.lot();
        if (u == 0 || before != 0) return;
        uint256 dt = bound(wait, 0, endsAt > block.timestamp ? endsAt - block.timestamp - 1 : 0);
        if (block.timestamp + dt >= lastLook + REACT) return;   // the merchant would look first
        vm.warp(block.timestamp + dt);
        _fresh();
        uint256 required;
        try pay.currentRequired() returns (uint256 r) { required = r; } catch { return; }
        cbeth.mint(EVIL_TAKER, required);
        vm.startPrank(EVIL_TAKER);
        cbeth.approve(address(pay), required);
        try pay.take() {
            if (merchantWantsPause) ghostTakeWhilePaused++;
            uint256 fair = _oracleCbEth(u);
            if (required * 100 < fair * 99) ghostTakeBelowFloor++;
        } catch {}
        vm.stopPrank();
    }

    function idsLength() external view returns (uint256) { return ids.length; }
}

contract ChainInvariants is PaymentsV3Base {
    ChainHandler h;
    address THIEF    = makeAddr("thief-co-owner");
    address GOOD_FWD = makeAddr("good-forwarder");
    address EVIL     = makeAddr("evil");
    address EVIL_FWD = makeAddr("evil-forwarder");

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        bytes32 id = pay.queueOwnerGrant(THIEF);
        vm.warp(block.timestamp + pay.TIMELOCK() + 1);
        pay.executeOwnerGrant(THIEF, id);
        pay.setForwarder(GOOD_FWD);
        vm.stopPrank();
        _freshFeeds();
        _fund(50_000e6);
        cbeth.mint(address(pay), 10 ether);

        h = new ChainHandler(pay, usdc, cbeth, feedCb, feedUsdc, feedEth, OWNER, THIEF, PAYEE, GOOD_FWD);
        // The key was stolen a while ago: the thief has banked two resume ids
        // that matured before the merchant noticed. Every id is offered to every
        // execute from here on.
        h.t_queueResume();
        h.t_queueResume();
        vm.warp(block.timestamp + pay.TIMELOCK() + 1);
        _freshFeeds();
        targetContract(address(h));
        excludeSender(address(pay));
    }

    // Teeth: each chain these invariants catch has a directed proof that passes
    // on 73fa334 (test/reaudit_20261107/PoC_ReAudit20261107.t.sol, PR 202):
    // C by test_POC_R2_forwarderUpdate_skipsItsTimelock, D by
    // test_POC_CHAIN_pauseUndoneAndLotSold, E by
    // test_POC_R3_limitIncrease_refillsThePastAtTheNewRate. On 73fa334 the
    // campaign itself breaks C and D (MEASURED, PR body).

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_A_noTheft() public view {
        assertEq(usdc.balanceOf(EVIL), 0, "A: USDC reached the thief");
        assertEq(cbeth.balanceOf(EVIL), 0, "A: cbETH reached the thief");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_B_ownership() public view {
        assertTrue(pay.hasRole(pay.OWNER_ROLE(), OWNER), "B: merchant lost the owner role");
        assertFalse(pay.hasRole(pay.OWNER_ROLE(), EVIL), "B: thief seated a new owner");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_C_forwarder() public view {
        assertTrue(pay.automationForwarder() != EVIL_FWD, "C: thief's forwarder installed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_D_pauseHolds() public view {
        assertEq(h.ghostKickWhilePaused(), 0, "D: a lot was kicked while the merchant wanted a pause");
        assertEq(h.ghostTakeWhilePaused(), 0, "D: a lot was taken while the merchant wanted a pause");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_E_bucket() public view {
        assertEq(h.ghostBucketOverrun(), 0, "E: a USDC exit overran the settled bucket");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 400
    function invariant_F_floor() public view {
        assertEq(h.ghostTakeBelowFloor(), 0, "F: the thief's taker paid below the 0.99 floor");
    }
}
