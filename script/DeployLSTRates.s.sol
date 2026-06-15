// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_LST_RATES_V1 - deploys LSTExchangeRate, whose address
// fills the `lstRates` slot in PossessioPayments' DeployParams. No constructor
// args: the cbETH/ETH feed (0x806b4Ac0...) and Aerodrome cbETH/WETH pool
// (0x47cA96Ea...) are `constant` in the contract, both cast-verified on Base.
//
// Must be deployed BEFORE Payments (Payments' constructor reverts on a zero
// lstRates address), same dependency ordering as STEEL -> hook.
//
// RUN (Base mainnet for the real address; Sepolia would value against feeds
// that may not exist there, so this one belongs on mainnet where its sources
// live):
//   forge script script/DeployLSTRates.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_lstrates.txt

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LSTExchangeRate} from "../src/LSTExchangeRate.sol";

contract DeployLSTRates is Script {
    function run() external returns (address lstRates) {
        uint256 pk = vm.envUint("DEPLOYER_PK");

        vm.startBroadcast(pk);
        LSTExchangeRate rates = new LSTExchangeRate();
        vm.stopBroadcast();

        lstRates = address(rates);

        console2.log("=== LSTExchangeRate DEPLOYED ===");
        console2.log("  lstRates address:", lstRates);
        console2.log("");
        console2.log("NEXT: paste this into PossessioPayments DeployParams.lstRates,");
        console2.log("      then run the Payments fork test / deploy.");
    }
}
