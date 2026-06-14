// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_HOOK_CREATE3_V1 - the real broadcast version of the
// path proven green in PossessioHookCreate3Fork.t.sol. Deploys PossessioHook
// via CreateX deployCreate3 using the mined sender-locked salt, landing at the
// mined 0x8C8 address (0x5Bc65A4a2Cc114F1dEC551c47F8375f1108e88c8).
//
// CREATE3 makes the address depend only on (deployer, salt) - so this lands at
// the SAME address on testnet as it did on the mainnet fork. STEEL must already
// be deployed (its address is baked into the init code).
//
// RUN (testnet):
//   forge script script/DeployHookCreate3.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_hook.txt
//
// The --private-key wallet MUST be the deployer the salt is locked to
// (0x9Ce4cb26...). A different sender cannot reach the mined address.

pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PossessioHook} from "../src/POSSESSIO_v2-6-3.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

contract DeployHookCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // The mined sender-locked salt (proven on the mainnet fork).
    bytes32 constant MINED_SALT = 0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9000000000000000000006cb4;
    // The address that salt produces (ends 0x8C8) - we assert we land here.
    address constant EXPECTED_HOOK = 0x5Bc65A4a2Cc114F1dEC551c47F8375f1108e88c8;

    // Deploy params (same grounded values proven in the fork test).
    address constant DEPLOYER       = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;
    address constant STEEL_ADDR     = 0x726D6a7A598A4D12aDe7019Dc2598D955391E298; // deployed Base Sepolia
    address constant POOL_MANAGER   = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Base v4 PoolManager
    address constant TREASURY_SAFE  = 0x19495180FFA00B8311c85DCF76A89CCbFB174EA0;
    address constant CBETH          = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant CL_CBETH_FEED  = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    address constant AERO_ROUTER    = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant WETH_ADDR      = 0x4200000000000000000000000000000000000006;
    address constant COUNCIL_0      = 0x65841AFCE25f2064C0850c412634A72445a2c4C9; // Gemini
    address constant COUNCIL_1      = 0xEE9369d614ff97838B870ff3BF236E3f15885314; // ChatGPT
    address constant COUNCIL_2      = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f; // Claude
    address constant COUNCIL_3      = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2; // Grok

    function _hookInitCode() internal pure returns (bytes memory) {
        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];
        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       DEPLOYER,
            steel:          STEEL_ADDR,
            poolManager:    POOL_MANAGER,
            treasury:       TREASURY_SAFE,
            cbETH_:         CBETH,
            chainlinkCbETH: CL_CBETH_FEED,
            aeroRouter:     AERO_ROUTER,
            weth:           WETH_ADDR,
            council:        council
        });
        return abi.encodePacked(type(PossessioHook).creationCode, abi.encode(p));
    }

    function run() external returns (address hook) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        require(vm.addr(pk) == DEPLOYER, "PK is not the salt-locked deployer");

        vm.startBroadcast(pk);
        hook = CREATEX.deployCreate3(MINED_SALT, _hookInitCode());
        vm.stopBroadcast();

        console2.log("=== HOOK DEPLOYED ===");
        console2.log("  hook address  :", hook);
        console2.log("  expected (8C8):", EXPECTED_HOOK);
        require(hook == EXPECTED_HOOK, "landed at unexpected address");
        require((uint160(hook) & uint160((1 << 14) - 1)) == uint160(0x8C8), "flag bits wrong");
        console2.log("  MATCH - landed at the mined 0x8C8 address");
        console2.log("");
        console2.log("NEXT: initialize the STEEL/WETH pool with this hook, then seed liquidity.");
    }
}
