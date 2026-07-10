// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_POSSESSIOFACTORY_V1 - deploys PossessioFactory to Base
// mainnet (chain 8453). This is the deployment-fee engine the console needs;
// deploying it is what resolves "no factory configured for chain 8453".
//
// ─────────────────────────────────────────────────────────────────────────────
// PRICE POSTURE — $1 until the pool is proven
// ─────────────────────────────────────────────────────────────────────────────
// DEPLOYMENT_FEE is immutable per-factory (no setter exists anywhere). So the
// price is versioned by DEPLOYING A NEW FACTORY, not by mutating this one. This
// v1 factory ships at ONE (1) USDC — a trivial, prove-the-rail price charged
// while the protocol-owned pool / flywheel is still unproven. When the pool is
// proven and wired (feeSink -> PossessioPool via accounted receiveInfraFunds),
// a NEW immutable factory is deployed at the ratified tier price (100 USDC, per
// test/PossessioFactoryFork.t.sol). Existing deploys keep their price; nobody's
// terms change under them. Honest versioning, not a silent bump.
//
//   PINNED (verified Base-mainnet values):
//     - DEPLOYMENT_FEE  1 USDC (1_000000, 6-dec) — interim, until pool proven
//     - payToken        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (Circle USDC, Base)
//     - feeSink         0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91 (PossessioPayments,
//                       the live shared treasury sink — plain safeTransfer target;
//                       stays Payments until the pool-wiring upgrade lands)
//
//   ENV-GATED (real blockers — script refuses to deploy until supplied):
//     - SALT_POOL_ADDR      — PossessioSaltPool address (NOT deployed yet)
//     - TEMPLATE_CODEHASH   — keccak256 of the chosen template's creation bytecode
//
// RUN (Base mainnet — only once the salt pool is deployed and the template pinned):
//   SALT_POOL_ADDR=0x... \
//   TEMPLATE_CODEHASH=0x... \
//   forge script script/DeployPossessioFactory.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_possessiofactory.txt

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";

contract DeployPossessioFactory is Script {
    // ---- PINNED: interim price + verified Base-mainnet addresses ----
    uint256 constant DEPLOYMENT_FEE = 1_000000;                                    // 1 USDC (6-dec) — until pool proven
    address constant PAY_TOKEN      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;  // USDC on Base
    address constant FEE_SINK       = 0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91;  // PossessioPayments (live sink)

    function run() external returns (address factoryAddr) {
        uint256 pk = vm.envUint("DEPLOYER_PK");

        // Real blockers: the salt pool must be deployed, and the template pinned.
        address saltPool         = vm.envAddress("SALT_POOL_ADDR");
        bytes32 templateCodehash = vm.envBytes32("TEMPLATE_CODEHASH");

        require(saltPool != address(0),         "SALT_POOL_ADDR not set - deploy PossessioSaltPool first");
        require(templateCodehash != bytes32(0), "TEMPLATE_CODEHASH not set - pin the template bytecode hash");

        vm.startBroadcast(pk);
        // Constructor order: (_deploymentFee, _templateCodehash, _saltPool, _payToken, _feeSink)
        PossessioFactory factory = new PossessioFactory(
            DEPLOYMENT_FEE,
            templateCodehash,
            saltPool,
            PAY_TOKEN,
            FEE_SINK
        );
        vm.stopBroadcast();

        factoryAddr = address(factory);

        console2.log("=== PossessioFactory DEPLOYED (Base mainnet) ===");
        console2.log("  Factory address :", factoryAddr);
        console2.log("  DEPLOYMENT_FEE  :", DEPLOYMENT_FEE, "(1 USDC - interim, until pool proven)");
        console2.log("  saltPool        :", saltPool);
        console2.log("  payToken (USDC) :", PAY_TOKEN);
        console2.log("  feeSink         :", FEE_SINK);
        console2.log("");
        console2.log("NEXT: point the console at this address (chain 8453). The $1");
        console2.log("      fee proves the deployment rail with real users. When the");
        console2.log("      pool is proven + wired, deploy a NEW factory at the tier");
        console2.log("      price - this one is immutable and keeps its $1 forever.");
    }
}
