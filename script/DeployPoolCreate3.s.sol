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
    address constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec0008105d4bea8a7e08ed2743;
    address constant PREDICTED = 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce;
    // the two authorized sources — verify-before-wire (must already be live).
    address constant FACTORY   = 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd;
    address constant X402CORE  = 0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05;

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

        // REVISED ORDER (council brick-guard, FIX A): the pool now deploys BEFORE
        // the factory (the factory's constructor verifies feeSink=this-pool is a
        // live infra-sink). So the FACTORY is NOT yet live here — bake it as its
        // PREDICTED CREATE3 address (a source is only read at runtime). Only
        // x402Core, which deploys before the pool, is liveness-verified.
        if (X402CORE.code.length == 0) revert SourceNotDeployed(X402CORE);

        address[] memory sources = new address[](2);
        sources[0] = FACTORY; // predicted CREATE3 addr; factory deploys next
        sources[1] = X402CORE;

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
        console2.log("  authorizedSources   : [factory, x402Core]");
        console2.log("  factory             :", FACTORY);
        console2.log("  x402Core            :", X402CORE);
        console2.log("FOUNDATION COMPLETE. NEXT: keeper refills the salt pool (0x8C8 hook salts).");
    }
}
