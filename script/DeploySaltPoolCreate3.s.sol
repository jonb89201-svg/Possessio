// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_SALTPOOL_CREATE3_V1 — deploys PossessioSaltPool via CreateX
// CREATE3 to its anchor address (deploy/anchor.json). FOUNDATION step 2 (after the
// factory, per the verify-before-wire reorder). SUPERSEDES DeploySaltPool.s.sol.
//
// deploymentFeeSource = the FACTORY (keeper-separation CHECK ONLY — not a money
// route; the salt pool has no money paths). Requires the factory already deployed.
//
// RUN (Base fork first, then --broadcast):
//   DEPLOYER_PK=<anchor EOA> SALT_KEEPER_ADDR=0x.. OPERATOR_DEST_ADDR=0x.. \
//   TREASURY_DEST_ADDR=0x.. forge script script/DeploySaltPoolCreate3.s.sol \
//   --rpc-url $BASE_RPC_URL -vvv   (add --broadcast when fork-green)

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeploySaltPoolCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // ---- deploy/anchor.json (phrase TREGUNA_..._DEE) ----
    address constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00e5f3f7bbb10c509f42c757;
    address constant PREDICTED = 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6;
    address constant FACTORY   = 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd; // verify-before-wire

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error FactoryNotDeployed();
    error KeeperNotMoneyClean();
    error DeployedMismatch(address deployed, address predicted);

    function run() external returns (address saltPoolAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk       = vm.envUint("DEPLOYER_PK");
        address keeper   = vm.envAddress("SALT_KEEPER_ADDR");
        address operator = vm.envAddress("OPERATOR_DEST_ADDR");
        address treasury = vm.envAddress("TREASURY_DEST_ADDR");

        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(SALT)) != ANCHOR_EOA || SALT[20] != 0x00) revert SaltNotSenderLocked();

        bytes32 gs = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), SALT));
        if (CREATEX.computeCreate3Address(gs) != PREDICTED) revert PredictionMismatch(CREATEX.computeCreate3Address(gs), PREDICTED);

        // VERIFY-BEFORE-WIRE: the factory this pool serves must already exist.
        if (FACTORY.code.length == 0) revert FactoryNotDeployed();
        // keeper-separation pre-check (mirror of the constructor's KeeperIntegrityViolation;
        // deploymentFeeSource = FACTORY).
        if (keeper == operator || keeper == treasury || keeper == FACTORY) revert KeeperNotMoneyClean();

        // Constructor: (_factory, _keeper, _operatorDestination, _treasuryDestination, _deploymentFeeSource)
        bytes memory initCode = abi.encodePacked(
            type(PossessioSaltPool).creationCode,
            abi.encode(FACTORY, keeper, operator, treasury, FACTORY)
        );

        vm.startBroadcast(pk);
        saltPoolAddr = CREATEX.deployCreate3(SALT, initCode);
        vm.stopBroadcast();

        if (saltPoolAddr != PREDICTED) revert DeployedMismatch(saltPoolAddr, PREDICTED);

        console2.log("=== PossessioSaltPool DEPLOYED via CREATE3 (Base) ===");
        console2.log("  saltPool (== anchor):", saltPoolAddr);
        console2.log("  extcodehash (record):");
        console2.logBytes32(saltPoolAddr.codehash);
        console2.log("  factory (pull gate) :", FACTORY);
        console2.log("  keeper (compute-only):", keeper);
        console2.log("NEXT: deploy x402Core, then pool (authorizedSources must include this factory).");
    }
}
