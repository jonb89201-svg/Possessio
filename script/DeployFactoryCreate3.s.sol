// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_FACTORY_CREATE3_V1 — deploys PossessioFactory via CreateX
// CREATE3. SUPERSEDES script/DeployPossessioFactory.s.sol (plain `new`, nonce-based).
// The factory becomes a CREATE3 organ: address = f(anchor EOA, salt) ONLY — no nonce
// discipline, same address on every EVM chain, sender-locked to the anchor key.
//
// ANCHOR: deploy/anchor.json (phrase-derived, byte-verified). All pinned constants
// below MUST equal anchor.json; the script recomputes salt->address via CreateX's own
// view and REFUSES to deploy on any mismatch.
//
// feeSink = A (SPEC_Factory_FeeSink_A.md): feeSink is the POOL. The CREATE3 address is
// bytecode-INDEPENDENT, so this script produces the same factory address whether or not
// the council's line-211 edit has landed — which is a TRAP:
//
//   *** DO NOT BROADCAST TO MAINNET UNTIL THE LINE-211 EDIT IS IN THE SOURCE. ***
//   Deploying the un-edited factory occupies the permanent anchor address with the
//   fund-STRANDING version (safeTransfer to a pool with no sync door), and a CREATE3
//   address cannot be redeployed. The fork test's "fee credits poolBalance" assertion
//   is the gate that proves the edit is live BEFORE any mainnet broadcast.
//
// Also load-bearing (checked at POOL deploy, not here — factory-first order): the
// factory address below MUST be in Pool.authorizedSources, or every deployTemplate
// reverts NotAuthorizedSource.
//
// RUN (Base FORK first — proves everything, spends no real ETH):
//   DEPLOYER_PK=<anchor EOA key> DEPLOYMENT_FEE=1000000 TEMPLATE_CODEHASH=0x... \
//   forge script script/DeployFactoryCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv
// then add --broadcast ONLY after the fork constellation test is green.

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeployFactoryCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base

    // ---- PINNED from deploy/anchor.json (phrase TREGUNA_..._DEE). MUST match. ----
    address constant ANCHOR_EOA        = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant FACTORY_SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec008c46fdc1e030e05940087c;
    address constant PREDICTED_FACTORY = 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd;
    address constant SALT_POOL         = 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6; // predicted (factory arg)
    address constant POOL              = 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce; // predicted (feeSink = A)

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error DeployedMismatch(address deployed, address predicted);
    error FeeSinkPoolNotLive(address pool);

    function run() external returns (address factoryAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid); // Base (fork or mainnet)

        uint256 pk               = vm.envUint("DEPLOYER_PK");
        uint256 deploymentFee    = vm.envUint("DEPLOYMENT_FEE");        // Architect's price (interim 1_000000 = $1)
        bytes32 templateCodehash = vm.envBytes32("TEMPLATE_CODEHASH");  // pinned template creation-code hash

        // The broadcasting key MUST be the anchor EOA — the salt is sender-locked to it,
        // so any other caller is rejected by CreateX's guard. Fail early and readably.
        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));

        // Salt layout guard: [deployer 20][0x00][entropy 11], locked to the anchor EOA.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(FACTORY_SALT)) != ANCHOR_EOA || FACTORY_SALT[20] != 0x00) revert SaltNotSenderLocked();

        // VERIFY salt -> predicted address via CreateX's own view BEFORE deploying.
        // guardedSalt = keccak256(leftpad32(deployer) ++ salt)  (MsgSender/RedeployProtection.False)
        bytes32 guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), FACTORY_SALT));
        address computed = CREATEX.computeCreate3Address(guardedSalt);
        if (computed != PREDICTED_FACTORY) revert PredictionMismatch(computed, PREDICTED_FACTORY);

        // VERIFY-BEFORE-WIRE (council brick-guard, FIX A): feeSink = POOL must be
        // LIVE before the factory deploys — the factory's constructor staticcalls
        // pool.isInfraSink() and reverts if absent. This is why the REVISED deploy
        // order is POOL -> x402Core -> factory -> saltPool (RUNBOOK §2). If the
        // pool is not live, stop here rather than let CreateX wrap the brick-guard
        // revert in an opaque failure.
        if (POOL.code.length == 0) revert FeeSinkPoolNotLive(POOL);

        // initCode = factory creation bytecode ++ abi.encode(constructor args).
        // Constructor order: (_deploymentFee, _templateCodehash, _saltPool, _payToken, _feeSink).
        // feeSink = POOL (option A). Address is independent of this bytecode.
        bytes memory initCode = abi.encodePacked(
            type(PossessioFactory).creationCode,
            abi.encode(deploymentFee, templateCodehash, SALT_POOL, PAY_TOKEN, POOL)
        );

        vm.startBroadcast(pk);
        factoryAddr = CREATEX.deployCreate3(FACTORY_SALT, initCode);
        vm.stopBroadcast();

        // HARD GATE: the deployed address is the anchor prediction, or the wave stops.
        if (factoryAddr != PREDICTED_FACTORY) revert DeployedMismatch(factoryAddr, PREDICTED_FACTORY);

        console2.log("=== PossessioFactory DEPLOYED via CREATE3 (Base) ===");
        console2.log("  factory (== anchor)  :", factoryAddr);
        console2.log("  extcodehash (RECORD as the factory front-run gate's expected):");
        console2.logBytes32(factoryAddr.codehash);
        console2.log("  saltPool (predicted) :", SALT_POOL);
        console2.log("  feeSink = POOL (A)   :", POOL);
        console2.log("  deploymentFee        :", deploymentFee);
        console2.log("  payToken (USDC)      :", PAY_TOKEN);
        console2.log("");
        console2.log("REMINDER: this deploys PossessioFactory AS COMPILED. If the line-211");
        console2.log("A-edit is not in the source, this is the fund-stranding factory at the");
        console2.log("PERMANENT anchor address. The fork test's poolBalance assertion is the gate.");
        console2.log("");
        console2.log("NEXT (verify-before-wire): deploy salt pool -> x402Core -> pool, each");
        console2.log("extcodehash-gated; the pool's authorizedSources MUST include this factory.");
    }
}
