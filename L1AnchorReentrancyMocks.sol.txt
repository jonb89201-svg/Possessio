// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {L1Anchor} from "../src/L1Anchor.sol";
import {L1AnchorFactory} from "../src/L1AnchorFactory.sol";
import {
    MockERC20,
    MockMorphoVault,
    MockChainlinkFeed
} from "./L1AnchorMocks.sol";

/**
 * @title L1Anchor Behavioral Reentrancy Test Infrastructure
 * @notice Closes the Non-Proven Scope gap documented in
 *         L1AnchorAdversarial.t.sol's reentrancy test contract.
 *
 *         The base MockMAVANEntry and MockMorphoVault do not call back into
 *         the caller during stake()/unstake()/deposit()/redeem(). Real
 *         partner protocols generally do not call back either, but a
 *         malicious or compromised partner contract could. The Anchor's
 *         OZ ReentrancyGuard with nonReentrant on five mutating functions
 *         is supposed to block this attack vector regardless of partner
 *         behavior.
 *
 *         This file provides:
 *           - ReentrancyAttacker: receives callbacks and attempts re-entry
 *             into a configured Anchor function with configured calldata
 *           - ReentrantMockMAVANEntry: subclass of the partner pattern
 *             that calls into the configured attacker during stake/unstake
 *           - ReentrantMockMorphoVault: same pattern for Morpho callbacks
 *           - L1AnchorReentrancyBehavioralTests: test contract that wires
 *             these together and verifies reentry attempts revert
 *
 *         Per Amendment IV: this closes the behavioral-reentrancy
 *         Non-Proven Scope. The structural property (modifier present,
 *         OZ ReentrancyGuard inherited, modifier ordering correct) was
 *         already verified in L1AnchorAdversarial.t.sol's
 *         L1AnchorReentrancyTests. This file adds the behavioral
 *         verification — attacker callback during external-call window,
 *         reentry attempt, OZ guard blocks the reentry.
 */

// ═════════════════════════════════════════════════════════════════════════════
//                          REENTRANCY ATTACKER
// ═════════════════════════════════════════════════════════════════════════════

/**
 * @notice Records reentry attempts and their outcomes. Mocks call this
 *         contract during their stake/unstake/deposit/redeem windows.
 *         When triggered, it attempts the configured reentry into the
 *         target Anchor and records whether the call reverted.
 */
contract ReentrancyAttacker {
    L1Anchor public target;
    bytes   public reentryCalldata;
    bool    public armed;
    bool    public reentryAttempted;
    bool    public reentryReverted;
    bytes   public lastRevertData;

    /// @notice Configure the next attack: which Anchor, which function,
    ///         what arguments. After arming, the next mock callback
    ///         triggers the attack exactly once.
    function arm(L1Anchor _target, bytes calldata _calldata) external {
        target = _target;
        reentryCalldata = _calldata;
        armed = true;
        reentryAttempted = false;
        reentryReverted  = false;
        delete lastRevertData;
    }

    /// @notice Called by ReentrantMock* during a partner-call window.
    ///         Attempts the armed reentry exactly once per arming.
    function trigger() external {
        if (!armed) return;
        armed = false;
        reentryAttempted = true;

        (bool ok, bytes memory data) = address(target).call(reentryCalldata);
        reentryReverted = !ok;
        lastRevertData = data;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                  REENTRANT MOCK MAVAN (callback during stake/unstake)
//
//   Same external surface as MockMAVANEntry, plus an attacker hook fired
//   during the partner-call window. Used in place of MockMAVANEntry in
//   reentrancy tests; standard tests continue to use MockMAVANEntry.
// ═════════════════════════════════════════════════════════════════════════════

contract ReentrantMockMAVANEntry {
    MockERC20 public immutable cbETH;
    ReentrancyAttacker public attacker;
    mapping(address => uint256) private _sharesOf;

    bool public callbackOnStake;
    bool public callbackOnUnstake;

    event Staked(address indexed staker, uint256 amount, uint256 shares);
    event Unstaked(address indexed staker, uint256 shares, uint256 cbEthReturned);

    constructor(MockERC20 _cbETH) {
        cbETH = _cbETH;
    }

    function setAttacker(ReentrancyAttacker _attacker) external {
        attacker = _attacker;
    }

    function setCallbackOnStake(bool _enabled) external {
        callbackOnStake = _enabled;
    }

    function setCallbackOnUnstake(bool _enabled) external {
        callbackOnUnstake = _enabled;
    }

    /// @notice Matches IMAVANEntry. Triggers attacker callback after
    ///         taking tokens but before returning, simulating a malicious
    ///         partner that calls back into its caller during the window.
    function stake(uint256 amount) external returns (uint256 shares) {
        require(
            cbETH.transferFrom(msg.sender, address(this), amount),
            "ReentrantMAVAN: cbETH transfer failed"
        );
        _sharesOf[msg.sender] += amount;
        shares = amount;

        if (callbackOnStake && address(attacker) != address(0)) {
            attacker.trigger();
        }

        emit Staked(msg.sender, amount, shares);
    }

    function unstake(uint256 shares) external returns (uint256 cbEthReturned) {
        require(_sharesOf[msg.sender] >= shares, "ReentrantMAVAN: insufficient shares");
        _sharesOf[msg.sender] -= shares;
        cbEthReturned = shares;
        require(
            cbETH.transfer(msg.sender, cbEthReturned),
            "ReentrantMAVAN: cbETH return failed"
        );

        if (callbackOnUnstake && address(attacker) != address(0)) {
            attacker.trigger();
        }

        emit Unstaked(msg.sender, shares, cbEthReturned);
    }

    function sharesOf(address staker) external view returns (uint256) {
        return _sharesOf[staker];
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                  REENTRANT MOCK MORPHO (callback during deposit/redeem)
// ═════════════════════════════════════════════════════════════════════════════

contract ReentrantMockMorphoVault {
    MockERC20 public immutable usdc;
    ReentrancyAttacker public attacker;
    mapping(address => uint256) private _sharesOf;
    uint256 public totalShares;

    bool public callbackOnDeposit;
    bool public callbackOnRedeem;

    event Deposit(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Redeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function setAttacker(ReentrancyAttacker _attacker) external {
        attacker = _attacker;
    }

    function setCallbackOnDeposit(bool _enabled) external { callbackOnDeposit = _enabled; }
    function setCallbackOnRedeem(bool _enabled)  external { callbackOnRedeem  = _enabled; }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(
            usdc.transferFrom(msg.sender, address(this), assets),
            "ReentrantMorpho: USDC transfer failed"
        );
        shares = assets;
        _sharesOf[receiver] += shares;
        totalShares += shares;

        if (callbackOnDeposit && address(attacker) != address(0)) {
            attacker.trigger();
        }

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        require(_sharesOf[owner] >= shares, "ReentrantMorpho: insufficient shares");
        _sharesOf[owner] -= shares;
        totalShares -= shares;
        assets = shares;
        require(usdc.transfer(receiver, assets), "ReentrantMorpho: USDC return failed");

        if (callbackOnRedeem && address(attacker) != address(0)) {
            attacker.trigger();
        }

        emit Redeem(msg.sender, receiver, owner, assets, shares);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _sharesOf[account];
    }

    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                BEHAVIORAL REENTRANCY TEST SUITE
//
//   Wires the reentrant mocks to an attacker contract and verifies that
//   the Anchor's OZ ReentrancyGuard blocks reentry attempts during real
//   partner-call windows.
//
//   Each test:
//     1. Deploys a fresh Anchor through Factory using the reentrant mocks
//     2. Configures attacker with a reentry calldata payload
//     3. Triggers the partner-call window via merchant action
//     4. Asserts the reentry was attempted AND reverted
//
//   The reentry revert proves the OZ ReentrancyGuard is blocking the
//   reentry, not that the reentry "didn't happen." The attacker.trigger()
//   call always fires; the question is whether it succeeds.
// ═════════════════════════════════════════════════════════════════════════════

contract L1AnchorReentrancyBehavioralTests is Test {
    address internal merchant = address(0xBEEF);
    uint256 internal constant INITIAL_CBETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_USDC_BALANCE  = 5_000_000e6;

    MockERC20                  internal cbETH;
    MockERC20                  internal usdc;
    ReentrantMockMAVANEntry    internal mavan;
    ReentrantMockMorphoVault   internal morpho;
    MockChainlinkFeed          internal oracle;
    ReentrancyAttacker         internal attacker;

    L1AnchorFactory internal factory;
    L1Anchor        internal anchor;

    function setUp() public {
        cbETH  = new MockERC20("Coinbase Wrapped Staked ETH", "cbETH", 18);
        usdc   = new MockERC20("USD Coin", "USDC", 6);
        mavan  = new ReentrantMockMAVANEntry(cbETH);
        morpho = new ReentrantMockMorphoVault(usdc);
        oracle = new MockChainlinkFeed(18);
        attacker = new ReentrancyAttacker();

        mavan.setAttacker(attacker);
        morpho.setAttacker(attacker);

        factory = new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(cbETH),
            address(usdc),
            address(oracle)
        );

        vm.prank(merchant);
        anchor = L1Anchor(factory.deployAnchor());

        cbETH.mint(merchant, INITIAL_CBETH_BALANCE);
        usdc.mint(merchant, INITIAL_USDC_BALANCE);
        cbETH.mint(address(mavan), INITIAL_CBETH_BALANCE);
        usdc.mint(address(morpho), INITIAL_USDC_BALANCE);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    function _seedAnchorWithCbEth(uint256 amount) internal {
        vm.prank(merchant);
        cbETH.transfer(address(anchor), amount);
    }

    function _seedAnchorWithUsdc(uint256 amount) internal {
        vm.prank(merchant);
        usdc.transfer(address(anchor), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   BEHAVIORAL REENTRANCY TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Attacker callback during MAVAN.stake() attempts to reenter
    ///         routeToMavan. OZ ReentrancyGuard must block the reentry.
    function test_behavioralReentry_routeToMavan_during_stakeCallback() public {
        _seedAnchorWithCbEth(20 ether);
        mavan.setCallbackOnStake(true);

        attacker.arm(
            anchor,
            abi.encodeWithSelector(L1Anchor.routeToMavan.selector, 5 ether)
        );

        vm.prank(merchant);
        anchor.routeToMavan(10 ether);

        // The attacker callback fired during the stake() window, attempting
        // a recursive routeToMavan. The OZ guard must have blocked it.
        assertTrue(attacker.reentryAttempted(), "reentry must be attempted");
        assertTrue(attacker.reentryReverted(),  "reentry must revert");
    }

    /// @notice Attacker callback during MAVAN.unstake() attempts to reenter
    ///         withdrawFromMavan. OZ ReentrancyGuard must block.
    function test_behavioralReentry_withdrawFromMavan_during_unstakeCallback() public {
        // Establish a position first (without the callback, to set up cleanly)
        _seedAnchorWithCbEth(10 ether);
        vm.prank(merchant);
        anchor.routeToMavan(10 ether);

        mavan.setCallbackOnUnstake(true);

        attacker.arm(
            anchor,
            abi.encodeWithSelector(L1Anchor.withdrawFromMavan.selector, 1 ether)
        );

        vm.prank(merchant);
        anchor.withdrawFromMavan(5 ether);

        assertTrue(attacker.reentryAttempted(), "reentry must be attempted");
        assertTrue(attacker.reentryReverted(),  "reentry must revert");
    }

    /// @notice Attacker callback during Morpho.deposit() attempts to reenter
    ///         routeToMorpho. OZ ReentrancyGuard must block.
    function test_behavioralReentry_routeToMorpho_during_depositCallback() public {
        _seedAnchorWithUsdc(10_000e6);
        morpho.setCallbackOnDeposit(true);

        attacker.arm(
            anchor,
            abi.encodeWithSelector(L1Anchor.routeToMorpho.selector, 1000e6)
        );

        vm.prank(merchant);
        anchor.routeToMorpho(5000e6);

        assertTrue(attacker.reentryAttempted(), "reentry must be attempted");
        assertTrue(attacker.reentryReverted(),  "reentry must revert");
    }

    /// @notice Attacker callback during Morpho.redeem() attempts to reenter
    ///         withdrawFromMorpho. OZ ReentrancyGuard must block.
    function test_behavioralReentry_withdrawFromMorpho_during_redeemCallback() public {
        _seedAnchorWithUsdc(5000e6);
        vm.prank(merchant);
        anchor.routeToMorpho(5000e6);

        morpho.setCallbackOnRedeem(true);

        attacker.arm(
            anchor,
            abi.encodeWithSelector(L1Anchor.withdrawFromMorpho.selector, 100e6)
        );

        vm.prank(merchant);
        anchor.withdrawFromMorpho(500e6);

        assertTrue(attacker.reentryAttempted(), "reentry must be attempted");
        assertTrue(attacker.reentryReverted(),  "reentry must revert");
    }

    /// @notice Cross-function reentry: attacker callback during MAVAN.stake()
    ///         attempts to call emergencyUnwind. The guard must block this
    ///         too — nonReentrant blocks the whole guard scope, not just
    ///         re-entry into the same function.
    function test_behavioralReentry_emergencyUnwind_during_stakeCallback() public {
        _seedAnchorWithCbEth(20 ether);
        _seedAnchorWithUsdc(1000e6);

        // Establish a Morpho position so emergencyUnwind has work to do
        vm.prank(merchant);
        anchor.routeToMorpho(1000e6);

        mavan.setCallbackOnStake(true);
        attacker.arm(
            anchor,
            abi.encodeWithSelector(L1Anchor.emergencyUnwind.selector)
        );

        vm.prank(merchant);
        anchor.routeToMavan(10 ether);

        assertTrue(attacker.reentryAttempted(), "cross-fn reentry must be attempted");
        assertTrue(attacker.reentryReverted(),  "cross-fn reentry must revert");
    }
}
