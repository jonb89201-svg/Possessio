// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_PAYMENTS_V1 - deploys PossessioPayments to Base mainnet.
// The DeployParams addresses are cast-verified Base mainnet values, read from
// BaseWiring (the feeds are validated by the fork suite; a clean deploy proves
// every address).
// lstRates is the LSTExchangeRate already deployed + certified at
// 0xDDb75e974d99FcF95E241adbFD376861c47a8548.
//
// Payments needs NO liquidity pool: the auction needs no venue of its own and
// the Morpho leg uses the live vault, so it deploys and operates without a
// seeding step.
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
    // v3.0: seven addresses (the routers, WETH and DAI left with the swap sweep);
    // v3.0.1: eight, with the sequencer uptime feed (cold-seat audit 2026-10-18, G-1).
    address constant USDC             = BaseWiring.USDC;
    address constant CBETH            = BaseWiring.CBETH;
    address constant MORPHO_VAULT     = BaseWiring.MORPHO_VAULT;
    address constant CHAINLINK_CBETH  = BaseWiring.CHAINLINK_CBETH; // cbETH/ETH 18-dec
    address constant CHAINLINK_USDC   = BaseWiring.CHAINLINK_USDC;  // USDC/USD 8-dec
    address constant CHAINLINK_ETH    = BaseWiring.CHAINLINK_ETH;   // ETH/USD 8-dec
    address constant CHAINLINK_SEQ    = BaseWiring.CHAINLINK_SEQUENCER; // L2 Sequencer Uptime Status Feed, 0-dec
    address constant LST_RATES        = BaseWiring.LST_RATES;       // deployed + certified

    // ---- config (units verified against contract) ----
    uint256 constant MIN_SWAP_BATCH = 100_000000;   // 100 USDC above the float before a kick (6-dec)
    uint256 constant USDC_FLOAT     = 10000e6;       // 10,000 USDC kept liquid, never auctioned (v3.0; was the DAI ceiling)
    uint256 constant MAX_KICK_USDC  = 0;             // no cap per kick; the owner can set one later
    // C-2 (audit 2026-07-14) — per-asset exit caps:
    //   USDC:  50,000 USDC/24h covers sendUSDC + redeemMorpho's USDC output.
    //   cbETH: 20 cbETH/24h (~$50k at ~$2.5k/ETH-equivalent) covers sendCbETH.
    // Larger exits go through the 7-day emergency-withdraw timelock, to a payee.
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

        // v3.0: the payees active at deployment. The deployer (the owner) is
        // the first; the console's launch flow collects the merchant's others.
        // An empty list is refused by the constructor (NoPayees).
        address[] memory payees = new address[](1);
        payees[0] = deployer;

        // Field order MUST match the struct exactly.
        PossessioPayments.DeployParams memory p = PossessioPayments.DeployParams({
            owner:            deployer,
            usdc:             USDC,
            cbeth:            CBETH,
            morphoVault:      MORPHO_VAULT,
            chainlink:        CHAINLINK_CBETH,
            chainlinkUsdcUsd: CHAINLINK_USDC,
            chainlinkEthUsd:  CHAINLINK_ETH,
            sequencerUptime:  CHAINLINK_SEQ,
            lstRates:         LST_RATES,
            minSwapBatch:     MIN_SWAP_BATCH,
            usdcFloat:        USDC_FLOAT,
            maxKickUsdc:      MAX_KICK_USDC,
            usdcDailyLimit:   USDC_DAILY_LIMIT,   // C-2
            cbEthDailyLimit:  CBETH_DAILY_LIMIT,  // C-2
            payees:           payees
        });

        vm.startBroadcast(pk);
        PossessioPayments payments = deployPayments(p);
        vm.stopBroadcast();

        paymentsAddr = address(payments);

        console2.log("=== PossessioPayments DEPLOYED ===");
        console2.log("  Payments address:", paymentsAddr);
        console2.log("  owner           :", deployer);
        console2.log("  minSwapBatch    :", MIN_SWAP_BATCH);
        console2.log("  usdcFloat       :", USDC_FLOAT);
        console2.log("  maxKickUsdc     :", MAX_KICK_USDC);
        console2.log("  usdcDailyLimit  :", USDC_DAILY_LIMIT);
        console2.log("  cbEthDailyLimit :", CBETH_DAILY_LIMIT);
        console2.log("  payee[0]        :", deployer);
        console2.log("");
        console2.log("NEXT: point the console at this address, test reads,");
        console2.log("      send a small USDC amount, confirm balance shows,");
        console2.log("      then kick() once the float is covered and watch the lot.");
    }
}
