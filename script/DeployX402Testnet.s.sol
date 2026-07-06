// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_X402_TESTNET_V1 - deploys PossessioX402Core to Base
// Sepolia with the RATIFIED TESTNET PLACEHOLDER constructor values (WO
// 2026-07-06). These numbers are chosen so the machine's behavior is VISIBLE
// in a single fork test - they are explicitly NOT production economics.
// DoD #22 (real calibration) is a separate pre-mainnet-freeze gate and stays
// OPEN regardless of this deploy.
//
// DEPLOYMENT_FEE is deliberately NOT wired here - it lives on the FACTORY,
// not on x402Core (flagged in the WO so it doesn't get added by mistake).
//
// USDC = Base Sepolia test USDC 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
// verified live on-chain 2026-07-06 (repo seat, Base MCP eth_call):
// symbol()="USDC", decimals()=6, version()="2" (FiatTokenV2 EIP-712 domain),
// authorizationState(address,bytes32) answers => EIP-3009 present.
//
// THE THREE ADDRESS ARGS must be THREE DISTINCT addresses you control. The
// constructor's valve-integrity check (PossessioX402Core.sol line 345)
// reverts ValveIntegrityViolation if deploymentFeeSource equals operator OR
// treasury - this script pre-checks the same condition so a miswire fails
// fast with a readable message instead of a raw revert.
//
// TEST MERKLE ROOT (declared, per the WO, so registration behavior in the
// fork test is understood - not accidental): a TWO-LEAF HandshakeLib tree.
//   leafA = hashLeaf(X402_TEST_SECRET,   X402_TEST_BUYER)   <- the live leaf
//   leafB = hashLeaf(X402_TEST_SECRET_B, X402_TEST_BUYER_B) <- spare leaf
//   root  = hashNode(leafA, leafB)        (sorted-pair sha256, HandshakeLib)
// Two leaves because SymmetryGuardCore.register() rejects empty proofs
// (BadAuthData for proof.length == 0), so a root==leaf single-leaf tree is
// structurally unusable. The buyer's proof is exactly [leafB]; the spare
// leaf doubles as the rotation path (DoD #7). Registration on this deploy
// is therefore gated to the two keys you supply - permissive for testing,
// but known and enumerable, never open.
//
// RUN (Base Sepolia, Architect terminal):
//   TREASURY_TEST=0x... OPERATOR_TEST=0x... FEESOURCE_TEST=0x... \
//   X402_TEST_SECRET=0x... X402_TEST_BUYER=0x... \
//   X402_TEST_SECRET_B=0x... X402_TEST_BUYER_B=0x... \
//   forge script script/DeployX402Testnet.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_x402_testnet.txt

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";

contract DeployX402Testnet is Script {
    // ---- chain constant (verified live - see header) ----
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // ---- RATIFIED TESTNET PLACEHOLDERS (WO 2026-07-06 - NOT production, #22 open) ----
    uint256 constant OPERATIONAL_CAP   = 100_000000; // 100 USDC - a few settles overflow it: the sweep is VISIBLE
    uint256 constant VELOCITY_HALFLIFE = 3600;       // 1 hour - warp 3600, watch the floor halve
    uint256 constant ABSOLUTE_FLOOR    = 10_000000;  // 10 USDC - the hard baseline (DoD #17's wall)
    uint256 constant FLOOR_PER_UNIT    = 1_000000;   // 1 USDC per unit of decayed velocity - legible per-call
    uint256 constant DUST_FLOOR        = 1_000000;   // 1 USDC - SymmetryGuardCore dust threshold (parent arg)

    error TestnetAddressesMustBeDistinct(); // pre-check mirror of ValveIntegrityViolation + WO's 3-distinct rule

    function run() external returns (address core) {
        address treasury  = vm.envAddress("TREASURY_TEST");
        address operator  = vm.envAddress("OPERATOR_TEST");
        address feeSource = vm.envAddress("FEESOURCE_TEST");

        // WO rule: three DISTINCT controlled addresses. Constructor line 345
        // only forbids feeSource collisions (treasury==operator is an allowed
        // shape by design), but on testnet we want three distinct so every
        // flow is separately visible in balances - enforce all three here.
        if (treasury == operator || feeSource == operator || feeSource == treasury) {
            revert TestnetAddressesMustBeDistinct();
        }

        // Declared two-leaf test tree (see header). Computed on the spot from
        // env so the root can never silently drift from the leaves you hold.
        bytes32 leafA = HandshakeLib.hashLeaf(vm.envBytes32("X402_TEST_SECRET"),   vm.envAddress("X402_TEST_BUYER"));
        bytes32 leafB = HandshakeLib.hashLeaf(vm.envBytes32("X402_TEST_SECRET_B"), vm.envAddress("X402_TEST_BUYER_B"));
        bytes32 root  = HandshakeLib.hashNode(leafA, leafB);

        vm.startBroadcast();
        core = address(new PossessioX402Core({
            root:                 root,
            dustFloor:            DUST_FLOOR,
            _payToken:            USDC_BASE_SEPOLIA,
            _treasuryDestination: treasury,
            _operatorDestination: operator,
            _deploymentFeeSource: feeSource,
            _operationalCap:      OPERATIONAL_CAP,
            _absoluteFloor:       ABSOLUTE_FLOOR,
            _floorPerUnit:        FLOOR_PER_UNIT,
            _velocityHalflife:    VELOCITY_HALFLIFE
        }));
        vm.stopBroadcast();

        console2.log("PossessioX402Core (TESTNET, placeholder economics):", core);
        console2.log("  USDC (Base Sepolia, verified):", USDC_BASE_SEPOLIA);
        console2.log("  treasury :", treasury);
        console2.log("  operator :", operator);
        console2.log("  feeSource:", feeSource);
        console2.log("  HANDSHAKE_ROOT (two-leaf test tree):");
        console2.logBytes32(root);
        console2.log("  leafA (live buyer leaf):");
        console2.logBytes32(leafA);
        console2.log("  leafB (spare / rotation leaf = buyer's proof):");
        console2.logBytes32(leafB);
        console2.log("  register(secret, [leafB]) from X402_TEST_BUYER to activate.");
    }
}
