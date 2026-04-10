// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PLATE.sol";

/**
 * @title DeployMainnet
 * @notice POSSESSIO PLATE deployment script — Base Mainnet
 * @dev Council certified: 104/104 tests passing
 *      Built entirely on mobile — 13 days — ~$300
 *      First protocol built and deployed entirely from a smartphone
 *
 * Usage:
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url https://mainnet.base.org \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Verify after deployment:
 *   forge verify-contract <DEPLOYED_ADDRESS> src/PLATE.sol:PLATE \
 *     --chain-id 8453 \
 *     --etherscan-api-key $BASESCAN_API_KEY
 */
contract DeployMainnet is Script {

    // ── Deployer ─────────────────────────────────────────────────
    // Farcaster wallet — deployer and owner
    address constant DEPLOYER  = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;

    // ── Treasury Safe (3-of-5 multisig) ──────────────────────────
    // Confirmed on Base mainnet — app.safe.global
    address constant TREASURY  = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    // ── Aerodrome Router (Base Mainnet) ───────────────────────────
    // Verified: https://basescan.org/address/0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
    address constant ROUTER    = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // ── Token Addresses (Base Mainnet) ────────────────────────────
    // cbETH: https://basescan.org/token/0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22
    address constant CBETH     = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

    // wstETH: planned post-launch Lido integration

    // rETH: https://basescan.org/token/0xb6fe221fe9eef5aba221c348ba20a1bf5e73624c
    address constant RETH      = 0xB6fe221Fe9EEF5aBa221c348bA20A1Bf5e73624c;

    // DAI: https://basescan.org/token/0x50c5725949a6f0c72e6c4a641f24049a917db0cb
    address constant DAI       = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;

    // ── Chainlink Price Feeds (Base Mainnet) ──────────────────────
    // cbETH/ETH: https://data.chain.link/feeds/base/base/cbeth-eth
    address constant CL_CBETH  = 0x806b4Ac04501c29769051e42783cF04dCE41440b;

    // DAI/USD: https://data.chain.link/feeds/base/base/dai-usd
    address constant CL_DAI    = 0x591e79239a7d679378eC8c847e5038150364C78F;

    // ── LP Pool ───────────────────────────────────────────────────
    // Aerodrome PLATE/ETH pool
    // Will be created on first liquidity add
    // Using treasury as temp placeholder
    address constant TEMP_LP   = TREASURY;

    // ── Reference Price ───────────────────────────────────────────
    // 1,000,000 PLATE per ETH (bootstrap price)
    // Matches test suite configuration
    uint256 constant INIT_REF  = 1_000_000 * 1e18;

    function run() external {
        vm.startBroadcast();

        PLATE plate = new PLATE(
            TEMP_LP,    // liquidityPool (temp — update via timelock after LP created)
            ROUTER,     // aerodromeRouter
            CBETH,      // cbETH
            RETH,       // rETH
            DAI,        // stablecoin target
            CL_CBETH,   // Chainlink cbETH/ETH feed
            CL_DAI,     // Chainlink DAI/USD feed
            INIT_REF    // reference price
        );

        vm.stopBroadcast();

        // ── Deployment Log ────────────────────────────────────────
        console.log("=== POSSESSIO PLATE MAINNET DEPLOYMENT ===");
        console.log("PLATE deployed to:", address(plate));
        console.log("Owner:            ", plate.owner());
        console.log("Treasury:         ", TREASURY);
        console.log("Router:           ", ROUTER);
        console.log("Total supply:     ", plate.totalSupply());
        console.log("==========================================");
        console.log("NEXT STEPS:");
        console.log("1. Create PLATE/ETH pool on Aerodrome");
        console.log("2. Update liquidityPool via timelock");
        console.log("3. Seed initial liquidity ($100)");
        console.log("4. Update README with mainnet address");
        console.log("5. Announce on Farcaster");
    }
}
