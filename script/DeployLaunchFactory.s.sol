// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PossessioLaunchFactory} from "../src/PossessioLaunchFactory.sol";

/*//////////////////////////////////////////////////////////////
         DEPLOY: PossessioLaunchFactory (Base mainnet)
              SPEC_CouncilToken §4 / §9 sequencing

  REFUSES TO RUN until every owed value is set in env — the same
  mechanically-true posture as DeployL1AnchorFactory. Nothing here
  has a default that could deploy a wrong constellation.

  DEPLOY ORDER (§9, enforced by the contract itself):
    1. COUNCIL TOKEN — must be LIVE CODE first; the factory's
       constructor reverts CouncilTokenNotLive otherwise.
    2. HEART for this factory — NOTE WELL: the LIVE Heart
       (0xE0612f38…19ce) has authorizedSources SEALED at
       [factory, x402Core]; a NEW launch factory can NEVER feed
       it. LAUNCH_HEART_ADDR must be a pool whose authorized
       sources include THIS factory's predicted address
       (authorization-at-construction, calls-when-ready), or the
       first deployLaunch reverts — atomically, fee refunded, but
       a bricked factory at a permanent address all the same.
    3. SALT POOL for this factory — sender-locked to the
       PREDICTED launch-factory address; the live pool is locked
       to the live PossessioFactory and cannot serve this one.
       Salts must be 0x8C8-style HOOK-FLAG mined: the launch IS
       its own v4 hook, so its address must carry valid hook
       permission bits or PoolManager.initialize reverts
       HookAddressNotValid on every launch.
    4. THIS SCRIPT.

  ENV (all required, no defaults):
    DEPLOYER_PK           deployer key
    COUNCIL_TOKEN_ADDR    live council token (step 1)
    LAUNCH_HEART_ADDR     pool with this factory in sources (2)
    LAUNCH_SALT_POOL_ADDR salt pool locked to predicted factory (3)
    TEMPLATE_CODEHASH     keccak256 of the frozen launch template
                          base creation bytecode
    DEPLOYMENT_FEE        USDC 6-dec (e.g. 50000000)
    POOL_FEE_PPM          v4 LP fee ppm (e.g. 3000)
    TICK_SPACING          v4 tick spacing (e.g. 60)

  PINNED (Base mainnet, source-verified in this repo):
    USDC         0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    POOL_MANAGER 0x498581fF718922c3f8e6A244956aF099B2652b2b
//////////////////////////////////////////////////////////////*/

contract DeployLaunchFactory is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address councilToken = vm.envAddress("COUNCIL_TOKEN_ADDR");
        address heart = vm.envAddress("LAUNCH_HEART_ADDR");
        address saltPool = vm.envAddress("LAUNCH_SALT_POOL_ADDR");
        bytes32 templateCodehash = vm.envBytes32("TEMPLATE_CODEHASH");
        uint256 fee = vm.envUint("DEPLOYMENT_FEE");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE_PPM"));
        int24 tickSpacing = int24(int256(vm.envInt("TICK_SPACING")));

        vm.startBroadcast(pk);
        PossessioLaunchFactory f = new PossessioLaunchFactory(
            fee, templateCodehash, saltPool, USDC, heart,
            councilToken, POOL_MANAGER, poolFee, tickSpacing
        );
        vm.stopBroadcast();

        // Deploy-values read-back: the chain, not the broadcast log, is the record.
        require(f.DEPLOYMENT_FEE() == fee, "readback: fee");
        require(f.templateCodehash() == templateCodehash, "readback: codehash");
        require(address(f.saltPool()) == saltPool, "readback: saltPool");
        require(f.heartSink() == heart, "readback: heart");
        require(f.COUNCIL_TOKEN() == councilToken, "readback: councilToken");
        require(address(f.poolManager()) == POOL_MANAGER, "readback: poolManager");
        require(f.POOL_FEE() == poolFee, "readback: poolFee");
        require(f.TICK_SPACING() == tickSpacing, "readback: tickSpacing");
        require(f.isPossessioLaunchFactory(), "readback: identity");

        console2.log("PossessioLaunchFactory:", address(f));
        console2.log("  councilToken:", councilToken);
        console2.log("  heart:", heart);
        console2.log("  saltPool:", saltPool);
        console2.log("  fee (USDC 6dec):", fee);
    }
}
