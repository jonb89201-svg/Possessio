// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {L1Anchor} from "../src/L1Anchor.sol";
import {L1AnchorFactory} from "../src/L1AnchorFactory.sol";
import {
    MockERC20,
    MockMAVANEntry,
    MockMorphoVault,
    MockChainlinkFeed
} from "./L1AnchorMocks.sol";

/**
 * @title L1Anchor Test Scaffolding
 * @notice Base test contract for L1Anchor.sol and L1AnchorFactory.sol suites.
 *
 *         Provides:
 *           - setUp() that deploys all mocks and a Factory
 *           - A canonical merchant address with a freshly-deployed Anchor
 *           - Funded balances for cbETH and USDC across all relevant addresses
 *           - Helper functions for common scenarios (depeg, oracle stale,
 *             partner failures, balance setups)
 *
 *         This scaffolding is shared substrate for all L1 tests.  Specific
 *         test suites (happy paths, revert paths, invariants, adversarial,
 *         fork tests) inherit from L1AnchorTestBase and add their own
 *         test functions.
 *
 *         Per Amendment IV, mock limitations carry forward.  See
 *         L1AnchorMocks.sol for the assumption log.  Tests requiring
 *         behaviors outside the mocks must extend or substitute the mocks
 *         and document substitutions in the test file.
 */
contract L1AnchorTestBase is Test {
    // ─── Actors ────────────────────────────────────────────────────────────

    address internal merchant      = address(0xBEEF);
    address internal nonOwner      = address(0xBADD);
    address internal observer      = address(0xC0DE);

    // ─── Mock infrastructure ───────────────────────────────────────────────

    MockERC20         internal cbETH;
    MockERC20         internal usdc;
    MockMAVANEntry    internal mavan;
    MockMorphoVault   internal morpho;
    MockChainlinkFeed internal oracle;

    // ─── System under test ─────────────────────────────────────────────────

    L1AnchorFactory internal factory;
    L1Anchor        internal anchor;

    // ─── Constants for funding ─────────────────────────────────────────────

    uint256 internal constant INITIAL_CBETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_USDC_BALANCE  = 5_000_000e6;  // 5M USDC at 6 decimals

    // ═══════════════════════════════════════════════════════════════════════
    //                                  SETUP
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Deploy ERC20 mocks
        cbETH = new MockERC20("Coinbase Wrapped Staked ETH", "cbETH", 18);
        usdc  = new MockERC20("USD Coin", "USDC", 6);

        // Deploy partner protocol mocks
        mavan  = new MockMAVANEntry(cbETH);
        morpho = new MockMorphoVault(usdc);
        oracle = new MockChainlinkFeed(18);  // L1Anchor asserts decimals == 18

        // Deploy Factory with the canonical institutional endpoints
        factory = new L1AnchorFactory(
            address(morpho),
            address(mavan),
            address(cbETH),
            address(usdc),
            address(oracle)
        );

        // Merchant deploys their Anchor through the Factory
        vm.prank(merchant);
        anchor = L1Anchor(factory.deployAnchor());

        // Fund the merchant with cbETH and USDC
        cbETH.mint(merchant, INITIAL_CBETH_BALANCE);
        usdc.mint(merchant, INITIAL_USDC_BALANCE);

        // Pre-fund the partner mocks so unstake/redeem paths can deliver assets
        cbETH.mint(address(mavan), INITIAL_CBETH_BALANCE);
        usdc.mint(address(morpho), INITIAL_USDC_BALANCE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          BALANCE-FLOW HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Move cbETH from merchant into the Anchor (simulates L2 bridge
    ///         arrival). Test code typically calls this before exercising
    ///         routeToMavan().
    function _seedAnchorWithCbEth(uint256 amount) internal {
        vm.prank(merchant);
        cbETH.transfer(address(anchor), amount);
    }

    /// @notice Move USDC from merchant into the Anchor (simulates L2 bridge
    ///         arrival). Test code typically calls this before exercising
    ///         routeToMorpho().
    function _seedAnchorWithUsdc(uint256 amount) internal {
        vm.prank(merchant);
        usdc.transfer(address(anchor), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ORACLE SCENARIO HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set oracle to report a healthy 1:1 cbETH/ETH ratio.
    ///         Default state after setUp(); call this to restore after a
    ///         depeg scenario.
    function _setOracleHealthy() internal {
        oracle.setAnswer(int256(1e18));
    }

    /// @notice Drive oracle below the 97% Symmetry Guard threshold.
    ///         Should cause _checkSymmetry() to set depegPaused = true on
    ///         next routeToMavan() call.
    function _setOracleDepegged() internal {
        oracle.setAnswer(int256(0.95e18));  // 95%, below 97% threshold
    }

    /// @notice Drive oracle to a price exactly at the threshold boundary.
    ///         Useful for verifying the inequality direction in
    ///         _checkSymmetry().
    function _setOracleAtThreshold() internal {
        oracle.setAnswer(int256(0.97e18));
    }

    /// @notice Make oracle report data older than ORACLE_STALE (3600s).
    function _setOracleStale() internal {
        oracle.setStale(3600 + 1);
    }

    /// @notice Make oracle's latestRoundData() revert.
    function _setOracleReverting() internal {
        oracle.setReverts(true);
    }

    /// @notice Set negative oracle answer (real Chainlink feeds should never
    ///         return this, but we test the contract's defense against it).
    function _setOracleNegative() internal {
        oracle.setAnswer(int256(-1));
    }

    /// @notice Set zero oracle answer.
    function _setOracleZero() internal {
        oracle.setAnswer(int256(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         PARTNER FAILURE HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Force MAVAN.stake() to revert. Tests routeToMavan() failure
    ///         handling.
    function _setMavanStakeReverting() internal {
        mavan.setStakeReverts(true);
    }

    /// @notice Force MAVAN.unstake() to revert. Tests withdrawFromMavan()
    ///         and emergencyUnwind() try/catch.
    function _setMavanUnstakeReverting() internal {
        mavan.setUnstakeReverts(true);
    }

    /// @notice Force MAVAN.stake() to claim success without taking tokens.
    ///         Tests Anchor's defensive design (trust balance delta, not
    ///         return value).
    function _setMavanStakeSilentlyFailing() internal {
        mavan.setStakeSilentlyFails(true);
    }

    /// @notice Force MAVAN.unstake() to claim success without sending tokens.
    function _setMavanUnstakeSilentlyFailing() internal {
        mavan.setUnstakeSilentlyFails(true);
    }

    /// @notice Force Morpho.deposit() to revert.
    function _setMorphoDepositReverting() internal {
        morpho.setDepositReverts(true);
    }

    /// @notice Force Morpho.redeem() to revert.
    function _setMorphoRedeemReverting() internal {
        morpho.setRedeemReverts(true);
    }

    /// @notice Set Morpho share-to-asset ratio for yield-accrual tests.
    /// @param  num    Numerator (e.g., 1.05e18 for 5% appreciation)
    /// @param  denom  Denominator (typically 1e18)
    function _setMorphoSharePrice(uint256 num, uint256 denom) internal {
        morpho.setSharePrice(num, denom);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         INVARIANT-CHECK HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sum of all value the Anchor has claim to: liquid balances on
    ///         the Anchor itself plus assets held in partner protocols.
    ///         Used by Solvency Invariant tests.
    function _totalAnchorValueCbEth() internal view returns (uint256) {
        return cbETH.balanceOf(address(anchor))
             + mavan.sharesOf(address(anchor));
    }

    function _totalAnchorValueUsdc() internal view returns (uint256) {
        uint256 morphoShares = morpho.balanceOf(address(anchor));
        uint256 morphoAssets = morpho.convertToAssets(morphoShares);
        return usdc.balanceOf(address(anchor)) + morphoAssets;
    }
}
