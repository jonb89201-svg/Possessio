// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PossessioPayments, BaseWiring} from "../../src/PossessioPayments.sol";
import {deployPayments} from "../PaymentsDeployHelper.sol";
import {MockUSDC_V3, MockCbETH_V3, MockFeed_V3, MockLST_V3, MockVault_V3, HonestTaker_V3, ReentrantTaker_V3} from "./PaymentsV3Mocks.sol";

/// Shared fixture for the v3.0 suites: mocks at ETH = $3,000, USDC = $1,
/// cbETH/ETH = 1.05, a $1,000 float, a $100 batch, one payee.
contract PaymentsV3Base is Test {
    MockUSDC_V3  usdc;
    MockCbETH_V3 cbeth;
    MockFeed_V3  feedCb;
    MockFeed_V3  feedUsdc;
    MockFeed_V3  feedEth;
    MockLST_V3   lst;
    MockVault_V3 vault;
    PossessioPayments pay;

    address OWNER    = makeAddr("owner");
    address PAYEE    = makeAddr("payee");
    address KEEPER   = makeAddr("keeper");
    address TAKER    = makeAddr("taker");
    address STRANGER = makeAddr("stranger");

    uint256 constant FLOAT = 1_000e6;
    uint256 constant BATCH = 100e6;
    uint256 constant USDC_LIMIT  = 10_000e6;
    uint256 constant CBETH_LIMIT = 5 ether;
    uint256 constant ONE = 1e18;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc     = new MockUSDC_V3();
        cbeth    = new MockCbETH_V3();
        feedCb   = new MockFeed_V3(1.05e18, 18);
        feedUsdc = new MockFeed_V3(1e8, 8);
        feedEth  = new MockFeed_V3(3000e8, 8);
        lst      = new MockLST_V3();
        vault    = new MockVault_V3(address(usdc));
        pay      = deployPayments(_params());
    }

    function _params() internal view returns (PossessioPayments.DeployParams memory p) {
        address[] memory payees = new address[](1);
        payees[0] = PAYEE;
        p = PossessioPayments.DeployParams({
            owner:            OWNER,
            usdc:             address(usdc),
            cbeth:            address(cbeth),
            morphoVault:      address(vault),
            chainlink:        address(feedCb),
            chainlinkUsdcUsd: address(feedUsdc),
            chainlinkEthUsd:  address(feedEth),
            lstRates:         address(lst),
            minSwapBatch:     BATCH,
            usdcFloat:        FLOAT,
            maxKickUsdc:      0,
            usdcDailyLimit:   USDC_LIMIT,
            cbEthDailyLimit:  CBETH_LIMIT,
            payees:           payees
        });
    }

    function _fund(uint256 amt) internal { usdc.mint(address(pay), amt); }

    /// Re-stamp the feeds at the current time with their current answers. On
    /// Base the ETH/USD feed updates every 30 to 330 s, so a test that warps
    /// past the 1 h window must refresh it, as the chain would have.
    function _freshFeeds() internal {
        feedCb.setAnswer(feedCb._answer());
        feedUsdc.setAnswer(feedUsdc._answer());
        feedEth.setAnswer(feedEth._answer());
    }

    function _warpFresh(uint256 ts) internal { vm.warp(ts); _freshFeeds(); }

    function _kick() internal { vm.prank(KEEPER); pay.kick(); }

    /// Fund above the float and kick: a lot of (amt * cbEthBps / 10000) USDC.
    function _fundAndKick(uint256 amtAboveFloat) internal {
        _fund(FLOAT + amtAboveFloat);
        _kick();
    }

    function _lot() internal view returns (uint256 usdcLot, uint256 startedAt, uint256 endsAt) {
        (uint128 u, uint64 s, uint64 e) = pay.lot();
        return (u, s, e);
    }

    function _warpTo(uint256 t) internal {
        (, uint256 startedAt,) = _lot();
        vm.warp(startedAt + t);
    }

    /// The oracle cbETH amount for `usdcAmt`, mirroring the contract's path.
    function _oracleCbEth(uint256 usdcAmt) internal view returns (uint256) {
        uint256 ethWei = (usdcAmt * 1e12 * uint256(feedUsdc._answer())) / uint256(feedEth._answer());
        return (ethWei * ONE) / uint256(feedCb._answer());
    }

    function _ceilMul(uint256 a, uint256 m) internal pure returns (uint256) {
        return (a * m + ONE - 1) / ONE;
    }

    /// Mint and approve exactly what the lot requires now, then take as `who`.
    function _take(address who) internal returns (uint256 required) {
        _freshFeeds();
        required = pay.currentRequired();
        cbeth.mint(who, required);
        vm.startPrank(who);
        cbeth.approve(address(pay), required);
        pay.take();
        vm.stopPrank();
    }

    function _owner() internal { vm.prank(OWNER); }
}
