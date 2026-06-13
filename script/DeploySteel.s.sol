// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_STEEL_V1 - Step 1 of the launch sequence. STEEL must be
// deployed BEFORE the hook, because the hook constructor takes STEEL's address
// as a param (DeployParams.steel). This script deploys STEEL and prints the
// address to paste into the hook deploy / fork test STEEL_ADDR.
//
// STEEL: ERC20 + ERC20Permit + Ownable2Step. name "PLATE", symbol "STEEL",
// 1,000,000,000 * 1e18 supply minted to the deployer; deployer becomes owner.
// Constructor: constructor(address deployer).
//
// RUN (testnet first):
//   forge script script/DeploySteel.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_steel.txt
//
// The DEPLOYER (the --private-key wallet) becomes STEEL owner and holds the
// full supply. For the sender-locked CREATE3 hook deploy, this SHOULD be the
// SAME deployer the salt is mined for (0x9Ce4cB26...), so ownership and the
// deploy identity stay consistent.

pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {STEEL} from "../src/POSSESSIO_v2-6-3.sol";

contract DeploySteel is Script {
    function run() external returns (address steelAddr) {
        // The deployer is the broadcast key (vm.broadcast uses --private-key).
        // STEEL mints full supply to, and is owned by, this address.
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        STEEL steel = new STEEL(deployer);
        vm.stopBroadcast();

        steelAddr = address(steel);

        console2.log("=== STEEL DEPLOYED ===");
        console2.log("  STEEL address :", steelAddr);
        console2.log("  owner/holder  :", deployer);
        console2.log("  name          :", steel.name());     // PLATE
        console2.log("  symbol        :", steel.symbol());    // STEEL
        console2.log("  total supply  :", steel.totalSupply());
        console2.log("  deployer bal  :", steel.balanceOf(deployer));
        console2.log("");
        console2.log("NEXT: paste STEEL address into the hook DeployParams.steel");
        console2.log("      and the fork test STEEL_ADDR, then deploy the hook.");
    }
}
