// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PLATE.sol";

/**
 * @title Deploy
 * @notice POSSESSIO PLATE deployment script
 * @dev Base Sepolia testnet deployment
 *      Council certified: 104/104 tests passing
 *      March 2026 — First protocol built entirely on mobile
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url https://sepolia.base.org \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {

    // ── Deployer ─────────────────────────────────────────────────
    // Farcaster wallet — deployer and owner
    address constant DEPLOYER = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;

    // ── Treasury Safe ────────────────────────────────────────────
    // Mainnet Safe address used for Sepolia too
    address constant TREASURY = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    // ── Aerodrome Router (Base Sepolia) ──────────────────────────
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // ── DAI Testnet (Base Sepolia) ───────────────────────────────
    address constant DAI = 0x819FfeCD4e64f193e959944Bcd57eeDC7755e17a;

    // ── Stub addresses for testnet ───────────────────────────────
    // cbETH and rETH don't exist on Base Sepolia
    // Using stub addresses — staking paths won't execute
    // This is acceptable for testnet deployment validation
    address constant CBETH   = address(0x1); // stub
    address constant WSTETH  = address(0);   // wstETH stub (zero = disabled)
    address constant RETH    = address(0x2); // stub

    // ── Chainlink feeds (stubs for testnet) ──────────────────────
    // Real feeds don't exist on Base Sepolia
    // Contract will gracefully fall back on zero address feeds
    address constant CL_CBETH = address(0); // stub
    address constant CL_DAI   = address(0); // stub

    // ── LP Pool ──────────────────────────────────────────────────
    // Will be set via timelock after deployment
    // Using treasury as temp LP placeholder
    address constant TEMP_LP = TREASURY;

    // ── Reference Price ──────────────────────────────────────────
    // 1,000,000 PLATE per ETH (bootstrap price)
    // Matches test suite configuration
    uint256 constant INIT_REF = 1_000_000 * 1e18;

    function run() external {
        vm.startBroadcast();

        PLATE plate = new PLATE(
            TEMP_LP,    // liquidityPool (temp — update via timelock)
            ROUTER,     // aerodromeRouter
            CBETH,      // cbETH (stub on testnet)
            WSTETH,     // wstETH (zero = disabled)
            RETH,       // rETH (stub on testnet)
            DAI,        // stablecoin target
            CL_CBETH,   // Chainlink cbETH feed (zero on testnet)
            CL_DAI,     // Chainlink DAI feed (zero on testnet)
            INIT_REF    // reference price
        );

        vm.stopBroadcast();

        // Log deployment
        console.log("PLATE deployed to:", address(plate));
        console.log("Treasury:", TREASURY);
        console.log("Router:", ROUTER);
        console.log("Total supply:", plate.totalSupply());
        console.log("Owner:", plate.owner());
    }
}
