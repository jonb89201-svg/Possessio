// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * MineHookSalt.s.sol
 *
 * Off-chain CREATE2 salt miner for PossessioHook.
 *
 * V4 hook permissions are encoded in the hook contract address's lower 14 bits.
 * PossessioHook requires:
 *   - BEFORE_ADD_LIQUIDITY      (bit 11)
 *   - BEFORE_SWAP               (bit 7)
 *   - AFTER_SWAP                (bit 6)
 *   - BEFORE_SWAP_RETURNS_DELTA (bit 3)
 *
 * Combined flag mask: 0x8C8 (binary: 100011001000)
 *
 * This script uses HookMiner from v4-periphery to find a salt that, when used
 * with CREATE2 deployment by the deployer, produces an address with the correct
 * lower bits.
 *
 * USAGE:
 *   forge script script/MineHookSalt.s.sol --rpc-url $RPC_URL
 *
 * OUTPUT:
 *   - Mined salt (bytes32)
 *   - Predicted hook address
 *   - Verification: address & 0x3FFF == 0x8C8
 *
 * Mining is off-chain compute. No transactions broadcast. No gas spent.
 * Save the salt and predicted address for use in deploy_v2.sh.
 *
 * Mining time: 5-30 minutes typical depending on CPU. Mobile-tethered may be
 * slower. The script will iterate until a matching salt is found.
 */

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PossessioHook} from "../src/POSSESSIO_v2.sol";

contract MineHookSalt is Script {

    // CREATE2 deployer constant (Foundry's standard)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external view {
        // ─────────────────────────────────────────────────────────────────
        // 1. Compute target permission flags
        // ─────────────────────────────────────────────────────────────────
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG       |
            Hooks.BEFORE_SWAP_FLAG                |
            Hooks.AFTER_SWAP_FLAG                 |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        console2.log("Target permission flags: 0x%x", flags);
        console2.log("Expected lower bits: 0x8C8");
        require(flags == 0x8C8, "Flag mask mismatch");

        // ─────────────────────────────────────────────────────────────────
        // 2. Construct PossessioHook deployment params
        // ─────────────────────────────────────────────────────────────────
        // NOTE: All addresses below are PLACEHOLDERS — replace with actual
        // deployed/configured values before running the miner.
        //
        // The constructor params are encoded into the bytecode for CREATE2
        // address derivation. Wrong params = wrong predicted address.
        //
        // Mining only needs deployer + bytecode + salt. Constructor params
        // are baked into the bytecode hash via abi.encode for CREATE2.
        // ─────────────────────────────────────────────────────────────────

        address deployer        = vm.envAddress("DEPLOYER_ADDRESS");
        address steel           = vm.envAddress("STEEL_ADDR");
        address poolManager     = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        address treasury        = vm.envAddress("TREASURY_SAFE");
        address cbETH_          = vm.envAddress("CBETH_ADDR");
        address dai             = vm.envAddress("DAI_ADDR");
        address chainlinkCbETH  = vm.envAddress("CHAINLINK_CBETH_ETH");
        address chainlinkDAI    = vm.envAddress("CHAINLINK_DAI_ETH");
        address v3Router        = vm.envAddress("V3_ROUTER");
        address weth            = 0x4200000000000000000000000000000000000006;

        address[4] memory council;
        council[0] = vm.envAddress("COUNCIL_0");  // Gemini
        council[1] = vm.envAddress("COUNCIL_1");  // ChatGPT
        council[2] = vm.envAddress("COUNCIL_2");  // Claude
        council[3] = vm.envAddress("COUNCIL_3");  // Grok

        PossessioHook.DeployParams memory params = PossessioHook.DeployParams({
            deployer:       deployer,
            steel:          steel,
            poolManager:    poolManager,
            treasury:       treasury,
            cbETH_:         cbETH_,
            dai:            dai,
            chainlinkCbETH: chainlinkCbETH,
            chainlinkDAI:   chainlinkDAI,
            v3Router:       v3Router,
            weth:           weth,
            council:        council
        });

        // ─────────────────────────────────────────────────────────────────
        // 3. Mine salt
        // ─────────────────────────────────────────────────────────────────
        bytes memory creationCode = abi.encodePacked(
            type(PossessioHook).creationCode,
            abi.encode(params)
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            creationCode,
            ""  // empty constructorArgs since they're already in creationCode
        );

        // ─────────────────────────────────────────────────────────────────
        // 4. Verify and output
        // ─────────────────────────────────────────────────────────────────
        require(
            (uint160(hookAddress) & 0x3FFF) == flags,
            "Mined address does not match required flags"
        );

        console2.log("");
        console2.log("=======================================");
        console2.log("HOOK MINING COMPLETE");
        console2.log("=======================================");
        console2.log("Predicted hook address: %s", hookAddress);
        console2.log("Mined salt: 0x%x", uint256(salt));
        console2.log("Address & 0x3FFF: 0x%x (must equal 0x8C8)", uint160(hookAddress) & 0x3FFF);
        console2.log("");
        console2.log("Use the salt and predicted address in deploy_v2.sh:");
        console2.log("  HOOK_SALT=0x%x", uint256(salt));
        console2.log("  HOOK_ADDR=%s", hookAddress);
        console2.log("=======================================");
    }
}
