// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_POOL_CREATE3_V1 — deploys PossessioPool ("The Heart") via
// CreateX CREATE3 to its anchor address (deploy/anchor.json). FOUNDATION step 4
// (last). authorizedSources is IMMUTABLE with no setter — this script bakes in the
// VERIFIED-live factory + x402Core, so the pool's inflow set points at real code,
// not a prediction. SUPERSEDES DeployPossessioPool.s.sol.
//
// feeSink=A REMINDER: the factory routes deployment fees here via receiveInfraFunds,
// which requires the factory to be in authorizedSources — it is (below). The pool's
// self-funding invariant (fee credits poolBalance, not balanceOf) is proven in
// test/ConstellationCreate3Fork.t.sol.
//
// Economic params are env — DATA-GATED, CALIBRATE before the immutable freeze.
//
// RUN (fork first):
//   DEPLOYER_PK=<anchor EOA> OPERATOR_DEST_ADDR=0x.. TREASURY_DEST_ADDR=0x.. \
//   POOL_OP_CAP=.. POOL_ABS_FLOOR=.. POOL_FLOOR_PER_UNIT=.. POOL_HALFLIFE=.. \
//   forge script script/DeployPoolCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeployPoolCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base

    // ---- deploy/anchor.json (phrase TREGUNA_..._DEE) ----
    // RESTAGED 2026-08-26: fresh CREATE3 salts for the FIXED-source redeploy
    // (P-1 / L-1 / G-1). Dry-run-proven end-to-end on a Base fork in
    // test/StageRedeployDryRun.t.sol. The month-old set is occupied and superseded.
    address constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00f954711b220e94230e12f1;
    address constant PREDICTED = 0xD064Bb5C00798d8A523089B750a6c3350eC86797;
    // the two authorized sources — baked as their PREDICTED CREATE3 addresses
    // (Pool deploys first; sources are runtime callers verified when they call).
    address constant FACTORY   = 0x5509BA759ce6CdC4Fc719E38436bA33b734BF155;
    address constant X402CORE  = 0xFba54FF0260ED18e2a48884C4FE8650D4416e022;

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error SourceNotDeployed(address src);
    error DeployedMismatch(address deployed, address predicted);

    function run() external returns (address poolAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk       = vm.envUint("DEPLOYER_PK");
        address operator = vm.envAddress("OPERATOR_DEST_ADDR");
        address treasury = vm.envAddress("TREASURY_DEST_ADDR");
        uint256 cap      = vm.envUint("POOL_OP_CAP");
        uint256 absFloor = vm.envUint("POOL_ABS_FLOOR");
        uint256 perUnit  = vm.envUint("POOL_FLOOR_PER_UNIT");
        uint256 halflife = vm.envUint("POOL_HALFLIFE");

        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(SALT)) != ANCHOR_EOA || SALT[20] != 0x00) revert SaltNotSenderLocked();

        bytes32 gs = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), SALT));
        if (CREATEX.computeCreate3Address(gs) != PREDICTED) revert PredictionMismatch(CREATEX.computeCreate3Address(gs), PREDICTED);

        // REVISED ORDER (council 2026-07-20): the pool (Heart) now deploys FIRST
        // of the constellation — before BOTH x402Core and the factory — because
        // each of those construction-verifies feeSink/heartSink = this-pool is a
        // live infra-sink (brick-guard). The pool constructor does NOT require its
        // sources live (they are runtime callers, verified when they call), so
        // BOTH sources are baked as their PREDICTED CREATE3 addresses here.
        // Order: POOL → x402Core → factory → saltPool.
        address[] memory sources = new address[](2);
        sources[0] = FACTORY;  // predicted CREATE3 addr; factory deploys after x402Core
        sources[1] = X402CORE; // predicted CREATE3 addr; x402Core deploys next, verifies THIS pool

        // Constructor: (_payToken, _authorizedSources, _operatorDestination,
        //               _treasuryDestination, _operationalCap, _absoluteFloor,
        //               _floorPerUnit, _velocityHalflife)
        // The contract's per-source valve check enforces sources != operator/treasury.
        bytes memory initCode = abi.encodePacked(
            type(PossessioPool).creationCode,
            abi.encode(PAY_TOKEN, sources, operator, treasury, cap, absFloor, perUnit, halflife)
        );

        vm.startBroadcast(pk);
        poolAddr = CREATEX.deployCreate3(SALT, initCode);
        vm.stopBroadcast();

        if (poolAddr != PREDICTED) revert DeployedMismatch(poolAddr, PREDICTED);

        console2.log("=== PossessioPool (Heart) DEPLOYED via CREATE3 (Base) ===");
        console2.log("  pool (== anchor)    :", poolAddr);
        console2.log("  extcodehash (record):");
        console2.logBytes32(poolAddr.codehash);
        console2.log("  authorizedSources   : [factory, x402Core] (both predicted; deploy after)");
        console2.log("  factory             :", FACTORY);
        console2.log("  x402Core            :", X402CORE);
        console2.log("HEART LIVE. NEXT: deploy x402Core (heartSink = this pool) -> factory -> saltPool.");
    }
}
