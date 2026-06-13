// SPDX-License-Identifier: MIT
// BUILD-PROOF: CREATE3_MINE_V1 - CreateX CREATE3 vanity-salt miner for the
// PossessioHook 0x8C8 flag suffix. Replaces the CREATE2/HookMiner path
// (MineHookSalt.s.sol does NOT apply to CREATE3 deploys).
//
// WHY CREATE3: the deployed address depends only on (deployer, salt) -- NOT on
// the initcode/bytecode. That lets automated launches reuse one mined salt
// without re-mining per bytecode change. CreateX factory at
// 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed (same address on all chains).
//
// SALT SCHEME (CreateX permissioned, no cross-chain guard):
//   salt = [ deployer (20 bytes) ][ 0x00 (1 byte) ][ entropy (11 bytes) ]
//   - first 20 bytes == deployer  -> permissioned deploy protection (sender-lock)
//   - 21st byte      == 0x00       -> NO cross-chain redeploy protection
//   - last 11 bytes  == search space the miner varies
//
// GUARD TRANSFORMATION (verified against CreateX source, _guard branch
// "MsgSender && RedeployProtectionFlag.False"):
//   guardedSalt = keccak256(abi.encodePacked(
//                     bytes32(uint256(uint160(deployer))),  // left-padded sender
//                     salt                                   // the raw 32-byte salt
//                 ));
//   NOTE: this branch uses _efficientHash = keccak256(abi.encodePacked(a,b)),
//   i.e. PACKED, 64 bytes. It is NOT abi.encode, and it does NOT include
//   block.chainid (chainid is only in the 21st-byte==0x01 branch). Getting
//   this exactly right is the load-bearing detail -- a wrong guard makes every
//   predicted address wrong.
//
// Then the CREATE3 address is computed from the GUARDED salt via CreateX's
// exposed view: ICreateX(CREATEX).computeCreate3Address(guardedSalt).
//
// RUN (mine):
//   DEPLOYER=0x<your-deployer> forge script script/MineCreate3Salt.s.sol \
//     --fork-url $BASE_RPC_URL -vv 2>&1 | tee mine_create3.txt
// Output: MINED_SALT (sender-locked) and EXPECTED_HOOK (ends 0x8C8).

pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface ICreateX {
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract MineCreate3Salt is Script {
    // CreateX factory (identical address on every chain it's deployed to).
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Target flag suffix: beforeAddLiquidity + beforeSwap + afterSwap +
    // beforeSwapReturnsDelta == 0x8C8. V4 hook permissions occupy the LOW 14
    // BITS of the address, so the mask is 14 bits (matches the fork test's
    // ALL_HOOK_MASK = (1<<14)-1). 0x8C8 is a 12-bit value, so under the 14-bit
    // mask bits 12 and 13 must be 0 -- i.e. the low 14 bits must equal 0x08C8
    // exactly. Using a 12-bit mask here would wrongly accept addresses with
    // bit 12/13 set, which the live PoolManager (and the fork test) reject.
    uint160 constant FLAG_MASK   = uint160((1 << 14) - 1);  // low 14 bits
    uint160 constant FLAG_TARGET = 0x08C8;

    // Bound the search so a script run terminates. 0x8C8 is a 12-bit target
    // (1 in 4096), so a few tens of thousands of iterations is plenty.
    uint256 constant MAX_ITERS = 2_000_000;

    function run() external view {
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "DEPLOYER env not set");

        // Left-padded deployer, used in the guarded-salt hash (computed once).
        bytes32 senderWord = bytes32(uint256(uint160(deployer)));

        // The fixed high 21 bytes of every candidate salt:
        //   [deployer 20][0x00 1]. We vary the low 11 bytes via `entropy`.
        // Build the 21-byte prefix as a uint256 shifted into place so we can
        // OR in the 11-byte entropy cheaply.
        //   salt layout (big-endian, byte 0 = most significant):
        //   bytes 0..19  = deployer
        //   byte  20     = 0x00
        //   bytes 21..31 = entropy (11 bytes = 88 bits)
        uint256 prefix = uint256(uint160(deployer)) << 96; // deployer into top 20 bytes
        // byte 20 is 0x00 already (the 8 bits just below the deployer); entropy
        // occupies the low 88 bits.

        for (uint256 i = 0; i < MAX_ITERS; i++) {
            // entropy = i fits in 88 bits for any realistic run.
            bytes32 salt = bytes32(prefix | (i & ((uint256(1) << 88) - 1)));

            // CreateX guard for [sender-locked, 21st byte 0x00] branch:
            // guardedSalt = keccak256(abi.encodePacked(senderWord, salt))
            bytes32 guardedSalt = keccak256(abi.encodePacked(senderWord, salt));

            address predicted = ICreateX(CREATEX).computeCreate3Address(guardedSalt);

            if ((uint160(predicted) & FLAG_MASK) == FLAG_TARGET) {
                console2.log("FOUND 0x8C8 hook address");
                console2.log("  iter      :", i);
                console2.log("  deployer  :", deployer);
                console2.log("  MINED_SALT:");
                console2.logBytes32(salt);
                console2.log("  guardedSalt:");
                console2.logBytes32(guardedSalt);
                console2.log("  EXPECTED_HOOK:", predicted);
                return;
            }
        }
        revert("No 0x8C8 address found within MAX_ITERS - raise the bound");
    }
}
