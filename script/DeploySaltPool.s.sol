// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_SALTPOOL_V1 - deploys PossessioSaltPool to Base mainnet
// (chain 8453). FOUNDATION STEP 1 of 3 (deploy/optimizer_pool.json: salt pool
// -> protocol pool -> factory, ratified order). One-time manual deploy.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE CHICKEN-AND-EGG, STATED HONESTLY
// ─────────────────────────────────────────────────────────────────────────────
// PossessioSaltPool's constructor takes `_factory` — the ONLY address ever
// permitted to pull salts — and it is immutable. But the factory is FOUNDATION
// STEP 3: it does not exist yet when this runs. So FACTORY_ADDR here must be
// the PREDICTED factory address, computed BEFORE this deploy:
//
//   script/DeployPossessioFactory.s.sol deploys via plain `new` (CREATE), so
//   predicted factory = keccak256(rlp(deployer, nonce)) — derive it with
//   script/PredictCreate3Addresses.s.sol (FACTORY_DEPLOYER_ADDR +
//   FACTORY_DEPLOYER_NONCE) or `cast compute-address`.
//
// THIS MAKES NONCE DISCIPLINE LOAD-BEARING: between predicting the factory
// address and broadcasting the factory deploy, the factory-deployer key must
// send EXACTLY the transactions the runbook plans, or the factory lands at a
// different address and this salt pool is bricked (pullSalt is factory-only,
// immutable, no setter). RUNBOOK_FOUNDATION.md carries the hard verification
// gate: after the factory broadcasts, its address MUST equal FACTORY_ADDR or
// the foundation restarts from step 1.
//
// KEEPER SEPARATION (Invariant 4, enforced by the constructor): the keeper is
// a compute-only wallet — it mines salts off-chain and refills the queue,
// nothing else. The constructor reverts KeeperIntegrityViolation if the keeper
// equals ANY of the three money-destination addresses. This script pre-checks
// the same condition (plus zero-checks the destinations, closing the
// contract's flagged Q2 gap at the DEPLOY layer: a zero destination would make
// the separation check vacuously satisfiable) so a miswire fails fast with a
// readable message instead of a raw revert.
//
//   ENV-GATED (script REFUSES to run until every one is set):
//     - FACTORY_ADDR         — PREDICTED PossessioFactory address (step 3);
//                              from PredictCreate3Addresses.s.sol
//     - SALT_KEEPER_ADDR     — compute-only mining wallet. Fresh key, never a
//                              money destination anywhere in the protocol
//     - OPERATOR_DEST_ADDR   — pool operatorDestination (money address; used
//                              here ONLY for the keeper-separation check)
//     - TREASURY_DEST_ADDR   — pool treasuryDestination (same: check only)
//     - FEE_SOURCE_ADDR      — deploymentFeeSource (same: check only). The
//                              natural value is FACTORY_ADDR itself (the
//                              factory is what pushes deploy fees, mirroring
//                              x402Core's deploymentFeeSource) — OPEN, the
//                              Architect ratifies the value they export
//
//   Nothing is hardcoded: this contract touches no tokens and no public
//   endpoints — every constructor arg is a protocol address that does not
//   exist yet or is not ratified yet.
//
// RUN (Base mainnet — only after the factory address is predicted):
//   FACTORY_ADDR=0x... \
//   SALT_KEEPER_ADDR=0x... \
//   OPERATOR_DEST_ADDR=0x... \
//   TREASURY_DEST_ADDR=0x... \
//   FEE_SOURCE_ADDR=0x... \
//   forge script script/DeploySaltPool.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_saltpool.txt

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

contract DeploySaltPool is Script {
    error KeeperMustBeMoneyClean();      // pre-check mirror of KeeperIntegrityViolation
    error MoneyDestinationIsZero();      // Q2 closed at the deploy layer: no vacuous separation check
    error WrongChain(uint256 got);       // foundation deploys are Base mainnet only

    function run() external returns (address saltPoolAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PK");

        // Real blockers — vm.envAddress reverts if unset; the requires make
        // each gate explicit and readable.
        address factory   = vm.envAddress("FACTORY_ADDR");
        address keeper    = vm.envAddress("SALT_KEEPER_ADDR");
        address operator  = vm.envAddress("OPERATOR_DEST_ADDR");
        address treasury  = vm.envAddress("TREASURY_DEST_ADDR");
        address feeSource = vm.envAddress("FEE_SOURCE_ADDR");

        require(factory != address(0), "FACTORY_ADDR not set - predict the factory address first (PredictCreate3Addresses)");
        require(keeper  != address(0), "SALT_KEEPER_ADDR not set - generate the compute-only keeper wallet");

        // Q2 closed here (contract flags it, built-to-spec doesn't check): if
        // any money destination were zero, the keeper-separation check below
        // would be trivially satisfiable. Refuse.
        if (operator == address(0) || treasury == address(0) || feeSource == address(0)) {
            revert MoneyDestinationIsZero();
        }

        // Pre-check mirror of the constructor's KeeperIntegrityViolation so a
        // miswire fails fast with a readable message.
        if (keeper == operator || keeper == treasury || keeper == feeSource) {
            revert KeeperMustBeMoneyClean();
        }

        vm.startBroadcast(pk);
        // Constructor order: (_factory, _keeper, _operatorDestination,
        //                     _treasuryDestination, _deploymentFeeSource)
        PossessioSaltPool saltPool = new PossessioSaltPool(
            factory,
            keeper,
            operator,
            treasury,
            feeSource
        );
        vm.stopBroadcast();

        saltPoolAddr = address(saltPool);

        console2.log("=== PossessioSaltPool DEPLOYED (Base mainnet) - FOUNDATION 1/3 ===");
        console2.log("  SaltPool address :", saltPoolAddr);
        console2.log("  factory (PREDICTED - immutable pull gate):", factory);
        console2.log("  keeper (compute-only)                    :", keeper);
        console2.log("  depth (starts empty; keeper refills)     :", saltPool.depth());
        console2.log("");
        console2.log("NEXT (RUNBOOK_FOUNDATION.md): deploy PossessioPool (step 2), then");
        console2.log("      the factory (step 3). HARD GATE: the factory MUST land at the");
        console2.log("      predicted address above - nonce discipline on the factory");
        console2.log("      deployer until then. Keeper refill (mined 0x8C8 salts, sender-");
        console2.log("      locked to the factory) is required before the first paid deploy.");
    }
}
