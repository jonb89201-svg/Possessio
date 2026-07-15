// SPDX-License-Identifier: MIT
// BUILD-PROOF: PREDICT_CREATE3_V1 - prints the predicted addresses of the
// future organs BEFORE anything deploys, so the foundation can be wired in the
// ratified order (deploy/optimizer_pool.json steps 1-3) even though the
// dependencies point FORWARD:
//
//   · PossessioSaltPool (step 1) needs the FACTORY address (step 3) — its
//     immutable factory-only pull gate.
//   · PossessioPool (step 2) needs the FACTORY address AND every organ in its
//     immutable authorized-source set (x402Core; whisky market per SPEC
//     whisky §6 if the Architect ratifies inclusion).
//
// Two prediction modes, both OFFLINE (no RPC, no fork, no CreateX call):
//
// A) FACTORY via CREATE. script/DeployPossessioFactory.s.sol deploys with
//    plain `new`, so the address is keccak256(rlp(deployer, nonce)) —
//    vm.computeCreateAddress. NONCE DISCIPLINE IS LOAD-BEARING: the predicted
//    address only holds if the deployer key's nonce at factory-broadcast time
//    equals FACTORY_DEPLOYER_NONCE exactly. Plan every intervening tx (the
//    salt-pool and pool deploys consume nonces if the same key sends them),
//    and re-verify with `cast nonce` immediately before the factory broadcast.
//
// B) ORGANS via CREATE3 (CreateX). The address depends ONLY on (CreateX,
//    guardedSalt) — never on bytecode — so it is derivable from first
//    principles with two constants CreateX itself publishes:
//
//      guardedSalt = keccak256(abi.encodePacked(
//                        bytes32(uint256(uint160(deployer))), salt))
//        — the CreateX guard for the [sender-locked, 21st byte 0x00] branch,
//          PACKED 64 bytes, NO chainid. Verified against CreateX source in
//          MineCreate3Salt.s.sol; cross-checked 3 ways (real deploy vs
//          CreateX's own view vs this math) in PossessioSaltPoolCreate3.t.sol.
//      proxy   = keccak256(0xff ++ CREATEX ++ guardedSalt ++ PROXY_INITCODE_HASH)
//      address = keccak256(0xd6 0x94 ++ proxy ++ 0x01)
//
//    `deployer` is WHOEVER CALLS CreateX.deployCreate3 — the FACTORY for
//    organs deployed down the factory+salt rail, or an EOA for a manual
//    CreateX deploy. WHICH caller each organ uses is an Architect call; a
//    wrong deployer here silently predicts a wrong address, which is why the
//    salt layout is VALIDATED (top 20 bytes == DEPLOYER, byte 21 == 0x00)
//    and anything else refuses instead of predicting garbage.
//
//    NOTE ON MINING: organs with no hook-flag requirement (x402Core, whisky
//    market) need no mining at all — ANY sender-locked salt yields a valid
//    deterministic address; pick entropy, predict here, ratify, done. Only
//    V4 hook templates need the 0x8C8 suffix search (MineCreate3Salt.s.sol,
//    which needs an RPC for CreateX's view; this script's math is the
//    offline equivalent).
//
//   ENV (all optional — but the script REFUSES to run if NOTHING is given):
//     - FACTORY_DEPLOYER_ADDR + FACTORY_DEPLOYER_NONCE  — mode A
//     - DEPLOYER                                        — mode B's CreateX caller
//     - X402CORE_SALT                                   — mode B, x402Core
//     - WHISKY_MARKET_SALT                              — mode B, whisky market
//     - PREDICT_SALT                                    — mode B, any other organ
//
// RUN (offline; no --rpc-url, no --broadcast, nothing to sign):
//   FACTORY_DEPLOYER_ADDR=0x... FACTORY_DEPLOYER_NONCE=... \
//   DEPLOYER=0x... X402CORE_SALT=0x... WHISKY_MARKET_SALT=0x... \
//   forge script script/PredictCreate3Addresses.s.sol -vv 2>&1 | tee predict_addresses.txt

pragma solidity ^0.8.26;

import "forge-std/Script.sol";

contract PredictCreate3Addresses is Script {
    // Canonical CreateX (identical address on every chain it is deployed to).
    // Pinned + notarized against the live Base deployment by
    // test/PossessioSaltPoolCreate3.t.sol (CANONICAL_RUNTIME_CODEHASH check).
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // CreateX's CREATE3 proxy init-code hash — a public constant baked into
    // CreateX itself (same pin as PossessioSaltPoolCreate3.t.sol, where it is
    // proven against a real deployCreate3 call).
    bytes32 constant PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    error NothingToPredict();                    // no mode-A and no mode-B input given
    error SaltNotSenderLockedToDeployer(bytes32 salt); // wrong guard branch -> wrong address; refuse
    error DeployerRequiredForSalts();            // a salt was given but DEPLOYER was not

    /// CreateX sender-lock guard transform ([sender-locked, 0x00] branch —
    /// PACKED, 64 bytes, no chainid). Mirrors MineCreate3Salt.s.sol.
    function _guarded(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }

    /// CREATE3 address from first principles (mirrors the 3-way-cross-checked
    /// math in PossessioSaltPoolCreate3.t.sol).
    function _create3(bytes32 guardedSalt) internal pure returns (address) {
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(
                hex"ff", CREATEX, guardedSalt, PROXY_INITCODE_HASH
            ))))
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01"))))
        );
    }

    /// Validate the salt encodes the CreateX sender-lock layout for
    /// `deployer`: [deployer (20 bytes)][0x00 (1 byte)][entropy (11 bytes)].
    /// Any other layout selects a DIFFERENT CreateX guard branch and the
    /// prediction above would be silently wrong — refuse instead.
    function _requireSenderLocked(address deployer, bytes32 salt) internal pure {
        // Truncation to the TOP 20 bytes is the point: that is where the
        // sender-lock layout puts the deployer.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(salt)) != deployer || salt[20] != 0x00) {
            revert SaltNotSenderLockedToDeployer(salt);
        }
    }

    function _predictOne(string memory label, address deployer, bytes32 salt) internal pure {
        _requireSenderLocked(deployer, salt);
        bytes32 gs = _guarded(deployer, salt);
        console2.log(label);
        console2.log("  salt        :");
        console2.logBytes32(salt);
        console2.log("  guardedSalt :");
        console2.logBytes32(gs);
        console2.log("  PREDICTED   :", _create3(gs));
        console2.log("");
    }

    function run() external view {
        bool predictedAnything;

        // ---- MODE A: the factory, via plain CREATE (deployer + nonce) ----
        address facDeployer = vm.envOr("FACTORY_DEPLOYER_ADDR", address(0));
        if (facDeployer != address(0)) {
            uint256 facNonce = vm.envUint("FACTORY_DEPLOYER_NONCE"); // reverts if unset - no silent nonce-0 guess
            address predictedFactory = vm.computeCreateAddress(facDeployer, facNonce);
            console2.log("FACTORY (CREATE: keccak256(rlp(deployer, nonce)))");
            console2.log("  deployer    :", facDeployer);
            console2.log("  nonce       :", facNonce);
            console2.log("  PREDICTED   :", predictedFactory);
            console2.log("  -> this is FACTORY_ADDR for DeploySaltPool + DeployPossessioPool.");
            console2.log("     HOLDS ONLY IF the deployer's nonce is exactly the above when");
            console2.log("     the factory broadcasts - `cast nonce` immediately before.");
            console2.log("");
            predictedAnything = true;
        }

        // ---- MODE B: CREATE3 organs (address = f(CreateX caller, salt) only) ----
        bytes32 x402Salt   = vm.envOr("X402CORE_SALT",      bytes32(0));
        bytes32 whiskySalt = vm.envOr("WHISKY_MARKET_SALT", bytes32(0));
        bytes32 extraSalt  = vm.envOr("PREDICT_SALT",       bytes32(0));

        if (x402Salt != bytes32(0) || whiskySalt != bytes32(0) || extraSalt != bytes32(0)) {
            address deployer = vm.envOr("DEPLOYER", address(0));
            if (deployer == address(0)) revert DeployerRequiredForSalts();
            console2.log("CREATE3 deployer (the CreateX.deployCreate3 CALLER - factory or EOA):", deployer);
            console2.log("");

            if (x402Salt != bytes32(0))   _predictOne("PossessioX402Core -> X402CORE_ADDR",        deployer, x402Salt);
            if (whiskySalt != bytes32(0)) _predictOne("PossessioWhiskyMarket -> WHISKY_MARKET_ADDR", deployer, whiskySalt);
            if (extraSalt != bytes32(0))  _predictOne("PREDICT_SALT (generic organ)",               deployer, extraSalt);
            predictedAnything = true;
        }

        if (!predictedAnything) revert NothingToPredict();

        console2.log("Feed the predicted addresses to RUNBOOK_FOUNDATION.md: FACTORY_ADDR into");
        console2.log("DeploySaltPool + DeployPossessioPool; X402CORE_ADDR / WHISKY_MARKET_ADDR");
        console2.log("into the pool's immutable source set. Predictions are pure math - nothing");
        console2.log("was deployed, signed, or broadcast by this script.");
    }
}
