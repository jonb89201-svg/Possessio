// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_X402CORE_CREATE3_V1 — deploys PossessioX402Core via CreateX
// CREATE3 to its anchor address (deploy/anchor.json). FOUNDATION step 3 (before the
// pool, so the pool's immutable authorizedSources can point at VERIFIED live code).
//
// x402Core retains its OWN internal pool for now; its toll re-route into the Heart's
// receiveInfraFunds is a later x402Core edit. deploymentFeeSource is x402Core's own
// bound inflow source (Architect names it; valve check: != operator, != treasury).
//
// Economic params (root/dustFloor/cap/floor/perUnit/halflife) are env — DATA-GATED,
// must be CALIBRATED before the immutable freeze (SPEC §22). CREATE3 address is
// independent of them, but they freeze on deploy — supply real values, not guesses.
//
// RUN (fork first):
//   DEPLOYER_PK=<anchor EOA> X402_ROOT=0x.. X402_DUST_FLOOR=.. OPERATOR_DEST_ADDR=0x.. \
//   TREASURY_DEST_ADDR=0x.. X402_FEE_SOURCE_ADDR=0x.. X402_OP_CAP=.. X402_ABS_FLOOR=.. \
//   X402_FLOOR_PER_UNIT=.. X402_HALFLIFE=.. \
//   forge script script/DeployX402CoreCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeployX402CoreCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base

    // ---- deploy/anchor.json (phrase TREGUNA_..._DEE) ----
    address constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00ef0925278b81d5e6aa477d;
    address constant PREDICTED = 0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05;

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error DeployedMismatch(address deployed, address predicted);

    function run() external returns (address x402Addr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk        = vm.envUint("DEPLOYER_PK");
        bytes32 root      = vm.envBytes32("X402_ROOT");
        uint256 dustFloor = vm.envUint("X402_DUST_FLOOR");
        address operator  = vm.envAddress("OPERATOR_DEST_ADDR");
        address treasury  = vm.envAddress("TREASURY_DEST_ADDR");
        address feeSource = vm.envAddress("X402_FEE_SOURCE_ADDR"); // x402Core's own inflow source
        uint256 cap       = vm.envUint("X402_OP_CAP");
        uint256 absFloor  = vm.envUint("X402_ABS_FLOOR");
        uint256 perUnit   = vm.envUint("X402_FLOOR_PER_UNIT");
        uint256 halflife  = vm.envUint("X402_HALFLIFE");

        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(SALT)) != ANCHOR_EOA || SALT[20] != 0x00) revert SaltNotSenderLocked();

        bytes32 gs = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), SALT));
        if (CREATEX.computeCreate3Address(gs) != PREDICTED) revert PredictionMismatch(CREATEX.computeCreate3Address(gs), PREDICTED);

        // Constructor: (root, dustFloor, _payToken, _treasuryDestination, _operatorDestination,
        //               _deploymentFeeSource, _operationalCap, _absoluteFloor, _floorPerUnit, _velocityHalflife)
        // The contract's own valve check enforces feeSource != operator/treasury; a bad wire reverts here.
        bytes memory initCode = abi.encodePacked(
            type(PossessioX402Core).creationCode,
            abi.encode(root, dustFloor, PAY_TOKEN, treasury, operator, feeSource, cap, absFloor, perUnit, halflife)
        );

        vm.startBroadcast(pk);
        x402Addr = CREATEX.deployCreate3(SALT, initCode);
        vm.stopBroadcast();

        if (x402Addr != PREDICTED) revert DeployedMismatch(x402Addr, PREDICTED);

        console2.log("=== PossessioX402Core DEPLOYED via CREATE3 (Base) ===");
        console2.log("  x402Core (== anchor):", x402Addr);
        console2.log("  extcodehash (record):");
        console2.logBytes32(x402Addr.codehash);
        console2.log("  payToken (USDC)     :", PAY_TOKEN);
        console2.log("NEXT: deploy pool with authorizedSources = [factory, this x402Core], both verified.");
    }
}
