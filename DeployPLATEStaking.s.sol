// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PLATEStaking.sol";

/**
 * @title DeployPLATEStaking
 * @notice POSSESSIO PLATEStaking deployment script — Base Mainnet
 * @dev Amendment V — Council Staking Layer
 *      Council certified: 272/272 tests passing
 *      24 PLATEStakingTest + 76 SAVTest + 42 SAVGauntlet = 142 direct tests
 *
 * Deployment sequence (Amendment V):
 *   1. DEPLOY THIS SCRIPT FIRST — PLATEStaking
 *   2. Deploy SAV (DeploySAV.s.sol) with this contract's address
 *   3. Treasury Safe calls PLATEStaking.setSAV(SAV_ADDRESS) via multisig
 *
 * Usage:
 *   forge script script/DeployPLATEStaking.s.sol \
 *     --rpc-url https://mainnet.base.org \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Verify after deployment:
 *   forge verify-contract <DEPLOYED_ADDRESS> src/PLATEStaking.sol:PLATEStaking \
 *     --chain-id 8453 \
 *     --etherscan-api-key $BASESCAN_API_KEY \
 *     --constructor-args $(cast abi-encode "constructor(address,address)" \
 *       0x726D6a7A598A4D12aDe7019Dc2598D955391E298 \
 *       0x188bE439C141c9138Bd3075f6A376F73c07F1903)
 */
contract DeployPLATEStaking is Script {

    // ── Deployer ─────────────────────────────────────────────────
    // Farcaster wallet — deployer and owner
    address constant DEPLOYER  = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;

    // ── PLATE Token (deployed mainnet) ────────────────────────────
    // https://basescan.org/token/0x726D6a7A598A4D12aDe7019Dc2598D955391E298
    address constant PLATE     = 0x726D6a7A598A4D12aDe7019Dc2598D955391E298;

    // ── Treasury Safe (3-of-5 multisig) ──────────────────────────
    // Confirmed on Base mainnet — app.safe.global
    address constant TREASURY  = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    function run() external {
        vm.startBroadcast();

        PLATEStaking staking = new PLATEStaking(
            PLATE,      // PLATE token address
            TREASURY    // Treasury Safe
        );

        vm.stopBroadcast();

        // ── Deployment Log ────────────────────────────────────────
        console.log("=== POSSESSIO PLATESTAKING MAINNET DEPLOYMENT ===");
        console.log("PLATEStaking deployed to:", address(staking));
        console.log("PLATE token:            ", address(staking.PLATE_TOKEN()));
        console.log("Treasury Safe:          ", staking.TREASURY_SAFE());
        console.log("SAV_CONTRACT (pending): ", staking.SAV_CONTRACT());
        console.log("savLocked:              ", staking.savLocked());
        console.log("==============================================");
        console.log("NEXT STEPS:");
        console.log("1. Copy PLATEStaking address above");
        console.log("2. Update DeploySAV.s.sol STAKING constant");
        console.log("3. Deploy SAV via DeploySAV.s.sol");
        console.log("4. Treasury Safe calls setSAV() via multisig");
        console.log("5. Verify savLocked == true after setSAV call");
    }
}
