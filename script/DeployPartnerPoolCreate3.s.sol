// SPDX-License-Identifier: MIT
// PARTNER POOL (2026-10-19): the security partner's PossessioPool — the same
// audited contract as the Heart, the same limits, with both destinations set to
// the partner's own Safe. The factory pins this pool's address as partnerSink
// and routes the partner's share of every launch fee into it (PARTNER SHARE,
// src/PossessioFactory.sol). Deploy order: THIS POOL before the factory, with
// the PREDICTED factory as its only authorized source.
//
// The partner's Safe is the one input only the partner can supply. KupiaSec
// supplied it on 2026-10-21 (KUPIASEC_SAFE below), and it is the default
// destination. A fork or staging run may still use the STUB destination, but
// only when ALLOW_STUB_PARTNER=true is stated explicitly. A pool whose
// destination is the stub must never be the one the mainnet factory pins: this
// script refuses the stub by default, and the factory pre-flight refuses a
// stub-destination partner pool by default as well (DeployFactoryCreate3.s.sol).
// Any other destination must be a contract (a Safe): an address without code is
// refused, so a mistyped address cannot become the pin.
//
// RUN (fork first):
//   DEPLOYER_PK=<anchor EOA> PARTNER_POOL_SALT=0x<sender-locked salt> \
//   [PARTNER_DEST_ADDR=0x<partner Safe>, default KUPIASEC_SAFE] \
//   POOL_OP_CAP=.. POOL_ABS_FLOOR=.. POOL_FLOOR_PER_UNIT=.. POOL_HALFLIFE=.. \
//   forge script script/DeployPartnerPoolCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv
// (staging only: PARTNER_DEST_ADDR=0x0000000000000000000000000000000000005aFE ALLOW_STUB_PARTNER=true)
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeployPartnerPoolCreate3 is Script {
    ICreateX constant CREATEX   = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base
    address  constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    /// The factory's predicted CREATE3 address (deploy/anchor.json): the pool's
    /// only authorized source, baked before the factory exists.
    address  constant PREDICTED_FACTORY = 0x5509BA759ce6CdC4Fc719E38436bA33b734BF155;

    /// The partner's Safe on Base, supplied by KupiaSec (Kupia Sec Enterprise) by
    /// email on 2026-10-21 and read on Base mainnet the same day: a Safe proxy whose
    /// singleton is SafeL2 1.4.1 (0x29fcB43b46531BcA003ddC8FCB67FFE91900C762),
    /// VERSION "1.4.1", 3 of 4 owners, nonce 0 (test/PartnerSafeFork.t.sol re-reads it).
    address public constant KUPIASEC_SAFE = 0xD72Ac0679B7A6Dea42457A79769fB5E4e4D3eeEb;

    /// The placeholder for staging runs. Recognisable on purpose ("5aFE"), accepted
    /// only with ALLOW_STUB_PARTNER=true.
    address public constant PARTNER_DEST_STUB = 0x0000000000000000000000000000000000005aFE;

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error DeployedMismatch(address deployed, address predicted);
    error PartnerDestinationMissing();
    error StubPartnerDestination(address stub);
    error PartnerDestinationHasNoCode(address dest);

    function run() external returns (address poolAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid); // Base (fork or mainnet)

        uint256 pk       = vm.envUint("DEPLOYER_PK");
        bytes32 salt     = vm.envBytes32("PARTNER_POOL_SALT");
        address dest     = _partnerDestination(vm.envOr("ALLOW_STUB_PARTNER", false));
        if (dest != PARTNER_DEST_STUB) _requireContract(dest);
        uint256 cap      = vm.envUint("POOL_OP_CAP");
        uint256 absFloor = vm.envUint("POOL_ABS_FLOOR");
        uint256 perUnit  = vm.envUint("POOL_FLOOR_PER_UNIT");
        uint256 halflife = vm.envUint("POOL_HALFLIFE");

        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(salt)) != ANCHOR_EOA || salt[20] != 0x00) revert SaltNotSenderLocked();

        bytes32 gs = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), salt));
        address predicted = CREATEX.computeCreate3Address(gs);

        address[] memory sources = new address[](1);
        sources[0] = PREDICTED_FACTORY; // the factory deploys after this pool and pins it

        // Same constructor as the Heart: (_payToken, _authorizedSources, _operatorDestination,
        // _treasuryDestination, _operationalCap, _absoluteFloor, _floorPerUnit, _velocityHalflife).
        // Operator and treasury are both the partner's Safe: the pool allows one address for both.
        bytes memory initCode = abi.encodePacked(
            type(PossessioPool).creationCode,
            abi.encode(PAY_TOKEN, sources, dest, dest, cap, absFloor, perUnit, halflife)
        );

        console2.log("=== Partner pool: pre-flight ===");
        console2.log("  destination (partner Safe):", dest);
        if (dest == PARTNER_DEST_STUB) console2.log("  !! DESTINATION IS THE STUB: staging only, never the mainnet factory's partnerSink");
        console2.log("  authorized source (predicted factory):", PREDICTED_FACTORY);
        console2.log("  predicted pool:", predicted);

        vm.startBroadcast(pk);
        poolAddr = CREATEX.deployCreate3(salt, initCode);
        vm.stopBroadcast();

        if (poolAddr != predicted) revert DeployedMismatch(poolAddr, predicted);

        console2.log("=== Partner pool DEPLOYED via CREATE3 (Base) ===");
        console2.log("  pool                :", poolAddr);
        console2.log("  extcodehash (record):");
        console2.logBytes32(poolAddr.codehash);
        console2.log("PARTNER_SINK_ADDR for DeployFactoryCreate3 :", poolAddr);
        console2.log("NEXT: deploy the factory with WITH_PARTNER=true PARTNER_SINK_ADDR=<this pool> PARTNER_BPS=5000.");
    }

    /// The partner's destination: KUPIASEC_SAFE unless PARTNER_DEST_ADDR overrides
    /// it. Zero is refused. The stub is refused unless ALLOW_STUB_PARTNER=true is
    /// stated (`allowStub`, read once in run()); a typo in that name refuses the
    /// stub, never admits it.
    function _partnerDestination(bool allowStub) internal view returns (address dest) {
        dest = vm.envOr("PARTNER_DEST_ADDR", KUPIASEC_SAFE);
        if (dest == address(0)) revert PartnerDestinationMissing();
        if (dest == PARTNER_DEST_STUB && !allowStub) revert StubPartnerDestination(dest);
    }

    /// A real destination is a contract (the partner's Safe). An address without
    /// code is a typo or an EOA, and the pin would be immutable: refused.
    function _requireContract(address dest) internal view {
        if (dest.code.length == 0) revert PartnerDestinationHasNoCode(dest);
    }
}
