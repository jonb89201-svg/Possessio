// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_PAYMENTS_V1 - deploys PossessioPayments to Base mainnet.
// All 16 DeployParams are cast-verified Base mainnet values (the 4 feeds all
// validated by the certified fork test - a clean deploy proves every address).
// lstRates is the LSTExchangeRate already deployed + certified at
// 0xDDb75e974d99FcF95E241adbFD376861c47a8548.
//
// Payments needs NO liquidity pool (it uses existing V3 SwapRouter + Aerodrome
// + Morpho liquidity), so it can deploy and operate without a seeding step.
//
// owner = deployer (standing default for automated deploys).
//
// RUN (mainnet):
//   forge script script/DeployPayments.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_payments.txt

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";

contract DeployPayments is Script {
    // ---- cast-verified Base mainnet addresses ----
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBETH            = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant DAI              = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ROUTER          = 0x2626664c2603336E57B271c5C0b26F421741e481; // V3 SwapRouter02
    address constant AERO_ROUTER     = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant MORPHO_VAULT     = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address constant CHAINLINK_CBETH = 0x806b4Ac04501c29769051e42783cF04dCE41440b; // cbETH/ETH 18-dec
    address constant CHAINLINK_DAI   = 0x591e79239a7d679378eC8c847e5038150364C78F; // DAI/USD 8-dec (cast-verified)
    address constant CHAINLINK_USDC  = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD 8-dec
    address constant CHAINLINK_ETH   = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD 8-dec
    address constant LST_RATES        = 0xDDb75e974d99FcF95E241adbFD376861c47a8548; // deployed + certified

    // ---- config (units verified against contract) ----
    uint256 constant MIN_SWAP_BATCH = 100_000000;   // 100 USDC (6-dec)
    uint256 constant DAI_CEILING    = 10000e18;      // 10,000 DAI (18-dec)
    uint256 constant DAILY_LIMIT    = 50000e18;      // 50,000 DAI/24h (18-dec)

    function run() external returns (address paymentsAddr) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk); // owner = deployer (standing default)

        // Field order MUST match the struct exactly.
        PossessioPayments.DeployParams memory p = PossessioPayments.DeployParams({
            owner:            deployer,
            usdc:             USDC,
            cbeth:            CBETH,
            dai:              DAI,
            weth:             WETH,
            router:           ROUTER,
            aeroRouter:       AERO_ROUTER,
            morphoVault:      MORPHO_VAULT,
            chainlink:        CHAINLINK_CBETH,
            chainlinkDai:     CHAINLINK_DAI,
            chainlinkUsdcUsd: CHAINLINK_USDC,
            chainlinkEthUsd:  CHAINLINK_ETH,
            lstRates:         LST_RATES,
            minSwapBatch:     MIN_SWAP_BATCH,
            daiCeiling:       DAI_CEILING,
            dailyLimit:       DAILY_LIMIT
        });

        vm.startBroadcast(pk);
        PossessioPayments payments = new PossessioPayments(p);
        vm.stopBroadcast();

        paymentsAddr = address(payments);

        console2.log("=== PossessioPayments DEPLOYED ===");
        console2.log("  Payments address:", paymentsAddr);
        console2.log("  owner           :", deployer);
        console2.log("  minSwapBatch    :", MIN_SWAP_BATCH);
        console2.log("  daiCeiling      :", DAI_CEILING);
        console2.log("  dailyLimit      :", DAILY_LIMIT);
        console2.log("");
        console2.log("NEXT: point the console at this address, test reads,");
        console2.log("      send a small USDC amount, confirm balance shows.");
        console2.log("      (Sweep path is NOT yet fork-tested - the $1 sweep");
        console2.log("       is the live confirmation of the unproven path.)");
    }
}
