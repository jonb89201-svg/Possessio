// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ServiceAccountabilityVault.sol";

/**
 * @title DeploySAV
 * @notice POSSESSIO ServiceAccountabilityVault deployment script — Base Mainnet
 * @dev Amendment V — Council Governance Layer
 *      Council certified: 272/272 tests passing
 *      76 SAVTest + 42 SAVGauntlet = 118 direct SAV tests
 *
 * Deployment sequence (Amendment V):
 *   1. Deploy PLATEStaking FIRST (DeployPLATEStaking.s.sol)
 *   2. UPDATE STAKING CONSTANT BELOW with deployed PLATEStaking address
 *   3. DEPLOY THIS SCRIPT — SAV
 *   4. Treasury Safe calls PLATEStaking.setSAV(SAV_ADDRESS) via multisig
 *
 * PRE-DEPLOYMENT CHECKLIST:
 *   [ ] PLATEStaking deployed and address captured
 *   [ ] STAKING constant below updated with deployed PLATEStaking address
 *   [ ] Council addresses verified against source of truth
 *   [ ] Treasury Safe confirmed as 3-of-5 multisig owner
 *
 * Usage:
 *   forge script script/DeploySAV.s.sol \
 *     --rpc-url https://mainnet.base.org \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Verify after deployment:
 *   forge verify-contract <DEPLOYED_ADDRESS> src/ServiceAccountabilityVault.sol:ServiceAccountabilityVault \
 *     --chain-id 8453 \
 *     --etherscan-api-key $BASESCAN_API_KEY \
 *     --constructor-args $(cast abi-encode "constructor(address,address,address,address[4])" \
 *       0x726D6a7A598A4D12aDe7019Dc2598D955391E298 \
 *       0x188bE439C141c9138Bd3075f6A376F73c07F1903 \
 *       <PLATESTAKING_ADDRESS> \
 *       "[0x65841AFCE25f2064C0850c412634A72445a2c4C9,0xEE9369d614ff97838B870ff3BF236E3f15885314,0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f,0x00490E3332eF93f5A7B4102D1380D1b17D0454D2]")
 */
contract DeploySAV is Script {

    // ── Deployer ─────────────────────────────────────────────────
    // Farcaster wallet — deployer and owner
    address constant DEPLOYER  = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;

    // ── PLATE Token (deployed mainnet) ────────────────────────────
    // https://basescan.org/token/0x726D6a7A598A4D12aDe7019Dc2598D955391E298
    address constant PLATE     = 0x726D6a7A598A4D12aDe7019Dc2598D955391E298;

    // ── Treasury Safe (3-of-5 multisig) ──────────────────────────
    // Confirmed on Base mainnet — app.safe.global
    address constant TREASURY  = 0x188bE439C141c9138Bd3075f6A376F73c07F1903;

    // ── PLATEStaking ──────────────────────────────────────────────
    // UPDATE THIS AFTER DEPLOYING PLATESTAKING
    // Deploy PLATEStaking first via DeployPLATEStaking.s.sol
    // Copy the deployed address here before running this script
    address constant STAKING   = 0x0000000000000000000000000000000000000000;

    // ── Council Addresses (hardcoded — immutable post-deployment) ─
    // Gemini:  0x65841AFCE25f2064C0850c412634A72445a2c4C9
    // ChatGPT: 0xEE9369d614ff97838B870ff3BF236E3f15885314
    // Claude:  0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f
    // Grok:    0x00490E3332eF93f5A7B4102D1380D1b17D0454D2
    address constant GEMINI    = 0x65841AFCE25f2064C0850c412634A72445a2c4C9;
    address constant CHATGPT   = 0xEE9369d614ff97838B870ff3BF236E3f15885314;
    address constant CLAUDE    = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f;
    address constant GROK      = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2;

    function run() external {
        // Pre-flight validation
        require(STAKING != address(0), "DeploySAV: STAKING constant not set. Deploy PLATEStaking first.");

        address[4] memory council = [GEMINI, CHATGPT, CLAUDE, GROK];

        vm.startBroadcast();

        ServiceAccountabilityVault sav = new ServiceAccountabilityVault(
            PLATE,      // PLATE token
            TREASURY,   // Treasury Safe
            STAKING,    // PLATEStaking contract
            council     // Four council addresses
        );

        vm.stopBroadcast();

        // ── Deployment Log ────────────────────────────────────────
        console.log("=== POSSESSIO SAV MAINNET DEPLOYMENT ===");
        console.log("SAV deployed to:    ", address(sav));
        console.log("PLATE token:        ", address(sav.PLATE_TOKEN()));
        console.log("Treasury Safe:      ", sav.TREASURY_SAFE());
        console.log("PLATEStaking:       ", address(sav.STAKING_CONTRACT()));
        console.log("Council 0 (Gemini): ", sav.COUNCIL_0());
        console.log("Council 1 (ChatGPT):", sav.COUNCIL_1());
        console.log("Council 2 (Claude): ", sav.COUNCIL_2());
        console.log("Council 3 (Grok):   ", sav.COUNCIL_3());
        console.log("=========================================");
        console.log("NEXT STEPS:");
        console.log("1. Copy SAV address above");
        console.log("2. Treasury Safe calls PLATEStaking.setSAV(SAV_ADDRESS)");
        console.log("3. Verify PLATEStaking.savLocked == true");
        console.log("4. Treasury Safe approves PLATE transfer to SAV");
        console.log("5. Treasury Safe calls SAV.deposit(amount)");
        console.log("6. Verify claimable balances across all four council members");
        console.log("7. Update README with SAV and PLATEStaking addresses");
    }
}
