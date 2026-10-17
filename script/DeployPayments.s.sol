// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_PAYMENTS_V1 - deploys PossessioPayments to Base mainnet.
// All 18 DeployParams are cast-verified Base mainnet values (the 4 feeds all
// validated by the certified fork test - a clean deploy proves every address).
// lstRates is the LSTExchangeRate already deployed + certified at
// 0xDDb75e974d99FcF95E241adbFD376861c47a8548.
//
// Payments needs NO liquidity pool (it uses existing V3 SwapRouter + Aerodrome
// + Morpho liquidity), so it can deploy and operate without a seeding step.
//
// owner = deployer (standing default for automated deploys).
//
// WHO DEPLOYS: the script derives the deployer from DEPLOYER_PK at runtime -
// vm.addr(pk) - and there is NO address hardcoded here. Whatever key signs
// becomes both the deployer and the OWNER_ROLE holder. That is deliberate:
// this contract is MIT and standalone (zero Possessio imports), so anyone can
// clone the repo and deploy their own instance for gas alone. A pinned
// deployer constant would revert for everyone but us and break that.
//
// OPT-IN GUARD: export EXPECTED_DEPLOYER=0x... and the script asserts the
// signing key resolves to it, reverting BEFORE spending gas. Leave it unset
// (the default) and self-deployers are unaffected. Use it for our own
// deployments so a stale or wrong key cannot silently mint a contract owned
// by the wrong address.
//
// DO NOT pass --private-key. Line ~`vm.startBroadcast(pk)` takes an explicit
// key and overrides the flag, so the flag is inert; passing a malformed or
// empty value there fails with "Failed to decode private key" before forge
// ever loads this file.
//
// POSSESSIO DEPLOYMENT ON BASE (8453) - see broadcast/ for the full record:
//   0x67247eB2108E7229331127DF1309D624d95467ca  owner 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9
//   2026-07-28. Verified live: bytecode present, sendUSDC / sendCbETH /
//   redeemMorpho all present, all 5 economic params and all 5 wired addresses
//   match the constants below.
//
// WHY THE EXITS ARE NON-NEGOTIABLE. The predecessor deployment held cbETH,
// USDC and Morpho shares with no withdrawal path for any of them - only DAI
// could leave. Value that entered its yield legs cannot come out. It is
// decommissioned and deliberately not cited anywhere in this repo; a dead
// contract listed among live ones is a false green, and its address in a doc
// is an invitation to send funds into it.
//
// STANDING RULE for any revision of this contract: no asset may be
// ACQUIRABLE without a matching WITHDRAWAL PATH. Adding a yield venue means
// adding its exit in the same change, or the venue does not ship.
//
// RUN (mainnet):
//   export DEPLOYER_PK=0x<64 hex>
//   export BASE_RPC_URL=<rpc>
//   export EXPECTED_DEPLOYER=0x<address>          # optional, recommended for us
//   forge script script/DeployPayments.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --broadcast -vvv 2>&1 | tee deploy_payments.txt

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PossessioPayments, BaseWiring} from "../src/PossessioPayments.sol";
import {deployPayments} from "../test/PaymentsDeployHelper.sol";

contract DeployPayments is Script {
    /// @notice EXPECTED_DEPLOYER was set and the signing key resolves elsewhere.
    error DeployerMismatch(address actual, address expected);

    // ---- cast-verified Base mainnet addresses: ONE source of truth, BaseWiring ----
    // (review 2026-10-17, F-8). The template pins the same library on chainid
    // 8453 (K-3), so a value edited here alone can no longer deploy on Base.
    address constant USDC             = BaseWiring.USDC;
    address constant CBETH            = BaseWiring.CBETH;
    address constant DAI              = BaseWiring.DAI;
    address constant WETH             = BaseWiring.WETH;
    address constant ROUTER           = BaseWiring.ROUTER;          // V3 SwapRouter02
    address constant AERO_ROUTER      = BaseWiring.AERO_ROUTER;
    address constant MORPHO_VAULT     = BaseWiring.MORPHO_VAULT;
    address constant CHAINLINK_CBETH  = BaseWiring.CHAINLINK_CBETH; // cbETH/ETH 18-dec
    address constant CHAINLINK_DAI    = BaseWiring.CHAINLINK_DAI;   // DAI/USD 8-dec (cast-verified)
    address constant CHAINLINK_USDC   = BaseWiring.CHAINLINK_USDC;  // USDC/USD 8-dec
    address constant CHAINLINK_ETH    = BaseWiring.CHAINLINK_ETH;   // ETH/USD 8-dec
    address constant LST_RATES        = BaseWiring.LST_RATES;       // deployed + certified

    // ---- config (units verified against contract) ----
    uint256 constant MIN_SWAP_BATCH = 100_000000;   // 100 USDC (6-dec)
    uint256 constant DAI_CEILING    = 10000e18;      // 10,000 DAI (18-dec)
    uint256 constant DAILY_LIMIT    = 50000e18;      // 50,000 DAI/24h (18-dec)
    // C-2 (audit 2026-07-14) — per-asset exit caps, USD-parity with DAILY_LIMIT:
    //   USDC:  50,000 USDC/24h covers sendUSDC + redeemMorpho's USDC output.
    //   cbETH: 20 cbETH/24h (~$50k at ~$2.5k/ETH-equivalent) covers sendCbETH.
    // Larger exits go through the 7-day emergency-withdraw timelock.
    uint256 constant USDC_DAILY_LIMIT  = 50000e6;    // 50,000 USDC/24h (6-dec)
    uint256 constant CBETH_DAILY_LIMIT = 20e18;      // 20 cbETH/24h (18-dec)

    function run() external returns (address paymentsAddr) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk); // owner = deployer (standing default)

        // Opt-in deployer assertion. Unset (address(0)) = no check, so a
        // third party deploying their own instance is never gated. Set it and
        // a wrong or stale key reverts here, before any gas is spent.
        address expected = vm.envOr("EXPECTED_DEPLOYER", address(0));
        if (expected != address(0) && deployer != expected) {
            revert DeployerMismatch(deployer, expected);
        }
        console2.log("  deployer (signing key resolves to):", deployer);

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
            dailyLimit:       DAILY_LIMIT,
            usdcDailyLimit:   USDC_DAILY_LIMIT,   // C-2
            cbEthDailyLimit:  CBETH_DAILY_LIMIT   // C-2
        });

        vm.startBroadcast(pk);
        PossessioPayments payments = deployPayments(p);
        vm.stopBroadcast();

        paymentsAddr = address(payments);

        console2.log("=== PossessioPayments DEPLOYED ===");
        console2.log("  Payments address:", paymentsAddr);
        console2.log("  owner           :", deployer);
        console2.log("  minSwapBatch    :", MIN_SWAP_BATCH);
        console2.log("  daiCeiling      :", DAI_CEILING);
        console2.log("  dailyLimit      :", DAILY_LIMIT);
        console2.log("  usdcDailyLimit  :", USDC_DAILY_LIMIT);
        console2.log("  cbEthDailyLimit :", CBETH_DAILY_LIMIT);
        console2.log("");
        console2.log("NEXT: point the console at this address, test reads,");
        console2.log("      send a small USDC amount, confirm balance shows.");
        console2.log("      (Sweep path is NOT yet fork-tested - the $1 sweep");
        console2.log("       is the live confirmation of the unproven path.)");
    }
}
