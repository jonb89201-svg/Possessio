// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PossessioTestnetLaunchPool} from "../src/PossessioTestnetLaunchPool.sol";

/// @notice Deploys the testnet launch pool to Base Sepolia (84532).
///         Owner is set to the Base Account AT CONSTRUCTION — the strongest form of
///         Principle 1: the deploy key never holds a role, so nothing needs renouncing.
/// @dev Env required:
///        TESTNET_OPERATOR_ADDR  — address of the throwaway Worker dripper key
///      Env optional:
///        POOL_OWNER             — defaults to the Base Account
///        ETH_STIPEND_WEI        — defaults to 0.02 ether
///        COOLDOWN_SECS          — defaults to 12 hours
/// @dev Run (MIB: one command per block, tee'd):
///        forge script script/DeployTestnetLaunchPool.s.sol --rpc-url $BASE_SEPOLIA_RPC \
///          --broadcast -vvv | tee deploy_testnet_pool.txt
contract DeployTestnetLaunchPool is Script {
    address internal constant BASE_ACCOUNT =
        0x6cFE30CE7c4a942599252524d7a2f8A6c6A69203; // same bytes as handoff; EIP-55 casing fixed to compile

    // Circle testnet USDC on Base Sepolia — enable post-deploy from the owner:
    // setTokenStipend(0x036CbD53842c5426634e7929541eC2318f3dCF7e, 100e6)
    address internal constant BASE_SEPOLIA_USDC =
        0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        require(block.chainid == 84532, "wrong chain: Base Sepolia only");

        address operator = vm.envAddress("TESTNET_OPERATOR_ADDR");
        address owner = vm.envOr("POOL_OWNER", BASE_ACCOUNT);
        uint256 stipend = vm.envOr("ETH_STIPEND_WEI", uint256(0.02 ether));
        uint256 cooldown = vm.envOr("COOLDOWN_SECS", uint256(12 hours));

        vm.startBroadcast();
        PossessioTestnetLaunchPool pool =
            new PossessioTestnetLaunchPool(owner, operator, stipend, cooldown);
        vm.stopBroadcast();

        console2.log("PossessioTestnetLaunchPool:", address(pool));
        console2.log("  owner   :", owner);
        console2.log("  operator:", operator);
        console2.log("  stipend :", stipend);
        console2.log("  cooldown:", cooldown);
        console2.log("Point every faucet claim at the pool address above.");
        console2.log("Post-deploy (owner): setTokenStipend(USDC, 100e6) ->", BASE_SEPOLIA_USDC);
    }
}
