// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; // TODO[CONFIRM]: match foundry.toml (v4-core may pin 0.8.26)

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

// TODO[CONFIRM]: import path/name must match the repo. The contract file is
// POSSESSIO_v2-6-3.sol; the contract is PossessioHook.
import {PossessioHook} from "../src/POSSESSIO_v2-6-3.sol";

// Canonical CreateX factory (same address on Base mainnet).
// If NOT on CreateX (Solady / custom), this interface is the ONE swap point.
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract PossessioHookCreate3ForkTest is Test {
    // =========================================================================
    // CONFIG - the only lines that change. Everything below is real test logic.
    // =========================================================================

    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // Base mainnet v4 PoolManager (BaseScan-verified this session).
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // ---- ARCHITECT-ONLY FILLS (from the mining run / deploy config) ----------
    // The identity the salt is sender-locked to - the SAME wallet that fires
    // deployCreate3 on mainnet.
    address constant DEPLOYER = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9; // architect deployer

    // The mined raw salt: first 20 bytes == DEPLOYER, 21st byte 0x00,
    // last 11 bytes the mined entropy. From MineCreate3Salt.s.sol.
    bytes32 constant MINED_SALT = 0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9000000000000000000006cb4; // mined iter 27828

    // The address the miner says that salt produces (must end 0x8C8).
    address constant EXPECTED_HOOK = 0x5Bc65A4a2Cc114F1dEC551c47F8375f1108e88c8; // ends 0x8C8

    // ---- Constructor args for _hookInitCode (the real 9-field DeployParams) ---
    // Venue addresses are cast-verified Base mainnet values from this session.
    // STEEL and the council seats are deploy-config; fill before running.
    address constant STEEL_ADDR     = 0x726D6a7A598A4D12aDe7019Dc2598D955391E298; // deployed Base Sepolia
    address constant TREASURY_SAFE  = 0x19495180FFA00B8311c85DCF76A89CCbFB174EA0; // V2 Treasury Safe
    address constant CBETH          = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22; // real cbETH
    address constant CL_CBETH_FEED  = 0x806b4Ac04501c29769051e42783cF04dCE41440b; // cbETH/ETH feed
    address constant AERO_ROUTER    = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5; // CORRECTED Slipstream router
    address constant WETH_ADDR      = 0x4200000000000000000000000000000000000006; // WETH predeploy
    address constant COUNCIL_0      = 0x65841AFCE25f2064C0850c412634A72445a2c4C9; // Gemini
    address constant COUNCIL_1      = 0xEE9369d614ff97838B870ff3BF236E3f15885314; // ChatGPT
    address constant COUNCIL_2      = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f; // Claude
    address constant COUNCIL_3      = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2; // Grok

    // The four declared flags -> low 14 bits must equal 0x8C8.
    uint160 constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1); // low 14 permission bits

    bool internal forked;

    function setUp() public {
        // Skip cleanly without BASE_RPC_URL — same discipline as the other
        // fork suites (PossessioFactoryFork, PaymentsFork, LSTExchangeRateFork).
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        if (!forked) return;

        // This test is meaningless if the architect-only fills are blank.
        require(address(POOL_MANAGER) != address(0), "set POOL_MANAGER");
        require(DEPLOYER != address(0), "set DEPLOYER");
        require(EXPECTED_HOOK != address(0), "set EXPECTED_HOOK");
        require(STEEL_ADDR != address(0), "set STEEL_ADDR");
    }

    // CREATE3 makes the ADDRESS bytecode-independent, but the deploy still needs
    // the REAL creation code + constructor args. This encodes the actual 9-field
    // DeployParams struct (deployer, steel, poolManager, treasury, cbETH,
    // chainlinkCbETH, aeroRouter, weth, council[4]) - matching the real
    // constructor. A wrong shape here deploys a different contract and the test
    // is meaningless even if it "passes".
    function _hookInitCode() internal pure returns (bytes memory) {
        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];
        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       DEPLOYER,
            steel:          STEEL_ADDR,
            poolManager:    address(POOL_MANAGER),
            treasury:       TREASURY_SAFE,
            cbETH_:         CBETH,
            chainlinkCbETH: CL_CBETH_FEED,
            aeroRouter:     AERO_ROUTER,
            weth:           WETH_ADDR,
            council:        council
        });
        return abi.encodePacked(type(PossessioHook).creationCode, abi.encode(p));
    }

    // 1. The real mine-and-deploy pipeline lands at the flagged address.
    function test_create3_deploys_to_mined_0x8C8_address() public {
        if (!forked) return;
        vm.prank(DEPLOYER);
        address deployed = CREATEX.deployCreate3(MINED_SALT, _hookInitCode());

        assertEq(deployed, EXPECTED_HOOK, "deployed != mined prediction");
        assertEq(uint160(deployed) & ALL_HOOK_MASK, EXPECTED_FLAGS, "flag bits wrong");
        assertEq(uint160(deployed) & ALL_HOOK_MASK, uint160(0x8C8), "suffix != 0x8C8");
    }

    // 2. SENDER-LOCK - the same salt from a DIFFERENT sender must NOT reach the
    //    mined address. Catches the "app fires from a different wallet than the
    //    one mined-for" False Green.
    function test_wrong_sender_cannot_reach_mined_address() public {
        if (!forked) return;
        address wrongSender = address(0xBEEF);
        vm.assume(wrongSender != DEPLOYER);

        vm.prank(wrongSender);
        try CREATEX.deployCreate3(MINED_SALT, _hookInitCode()) returns (address other) {
            assertTrue(other != EXPECTED_HOOK, "wrong sender reached the mined address");
        } catch {
            // revert is also an acceptable outcome - the binding held.
        }
    }

    // 3. The LIVE PoolManager accepts the hook. initialize() runs
    //    Hooks.validateHookPermissions internally; if the address bits did not
    //    match the hook's declared permissions, this reverts.
    function test_live_poolManager_accepts_hook() public {
        if (!forked) return;
        vm.prank(DEPLOYER);
        address hook = CREATEX.deployCreate3(MINED_SALT, _hookInitCode());

        // Pool params (computed from V1 launch ratio: 400M STEEL : $250 ETH,
        // ETH=$1675 -> 0.14925 WETH : 400M STEEL). Token ordering confirmed:
        // WETH 0x4200.. < STEEL 0x726D.. so WETH is currency0, STEEL currency1.
        // MAINNET: recompute sqrtPriceX96 with the live ETH price at deploy time.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH_ADDR),  // token0 (lower address)
            currency1: Currency.wrap(STEEL_ADDR), // token1
            fee: 3000,                            // 0.30% standard volatile-pair tier
            tickSpacing: 60,                      // pairs with 0.30%
            hooks: IHooks(hook)
        });
        // sqrt(STEEL/WETH) * 2^96 = sqrt(400000000 / 0.14925373) * 2^96
        uint160 sqrtPriceX96 = 4101540277851273819802995017366077;
        POOL_MANAGER.initialize(key, sqrtPriceX96);
        // no revert == live PoolManager validated the hook's address bits
    }

    // 4. TODO - runtime behavior on forked state. DO NOT fake these green:
    //    - swap exercising beforeSwap/afterSwap + 2% L.A.T.E. return-delta
    //    - cbETH staking leg against the LIVE Aerodrome pool (already proven in
    //      POSSESSIO_v2_Fork.t.sol; can be folded in here post-deploy)
    //    - H-1 slippage floor: max(callerMin, oracleFloor) per leg
    //    - staleness guard reverts on a stale feed
    //    NOTE: the ETH->DAI cross-rate is GONE (DAI leg cut). Do not re-add it.
    //    Leaving these stubbed is honest; a faked pass is the exact False Green
    //    this file exists to kill.
}
