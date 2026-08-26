// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioPool} from "../src/PossessioPool.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";

// ============================================================================
// CONSTELLATION REDEPLOY — DRY RUN (Base mainnet fork)
//
// Proves the FULL redeploy end-to-end BEFORE a wei of mainnet gas: fresh
// CREATE3 salts -> predicted addresses -> deploy POOL -> x402Core -> factory ->
// saltPool in RUNBOOK order from the FIXED source, with the fixed-Payments
// codehash pinned into the factory, then asserts every immutable wire is
// consistent. Impersonates the anchor deployer (no key needed on a fork).
//
// Skips cleanly without BASE_RPC_URL.
//
// NOTE ON THE CODEHASH: TEMPLATE_CODEHASH is keccak256(type(PossessioPayments)
// .creationCode), which is TOOLCHAIN-DEPENDENT (solc version / settings). This
// dry-run computes and pins it with THIS environment's compiler and proves the
// factory pins exactly the fixed-Payments code. At mainnet deploy time, RE-
// GENERATE TEMPLATE_CODEHASH with the production toolchain (the live contracts
// are solc 0.8.35) and pass it as the factory's env arg — do not hardcode the
// value this test logs.
// ============================================================================

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract StageRedeployDryRun is Test {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC

    // Anchor deployer (deploy/anchor.json). Salts are sender-locked to it.
    address constant ANCHOR = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;

    // FRESH salts (ANCHOR ++ 0x00 ++ 11-byte entropy) — distinct from the
    // month-old occupied set, generated 2026-08-26 for the fixed-source redeploy.
    bytes32 constant SALT_POOL     = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00f954711b220e94230e12f1;
    bytes32 constant SALT_X402     = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00a3f42727cffd80f349d0a0;
    bytes32 constant SALT_FACTORY  = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec003b32c63f7efcd69736d863;
    bytes32 constant SALT_SALTPOOL = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00554b55a2dc800801b2e2b0;

    // Placeholder ECONOMIC params for the dry run (distinct addresses satisfy the
    // valve/keeper-separation checks). The mainnet run supplies the real,
    // calibrated values via the deploy scripts' env vars — these are NOT final.
    address constant OPERATOR = address(0xA11CE);
    address constant TREASURY = address(0xB0B);
    address constant KEEPER   = address(0xC0FFEE);
    address constant FEESRC   = address(0xD00D); // x402Core's own inflow source
    uint256 constant CAP = 100_000e6;
    uint256 constant ABS_FLOOR = 10_000e6;
    uint256 constant PER_UNIT = 1e6;
    uint256 constant HALFLIFE = 7 days;
    uint256 constant DEPLOY_FEE = 1_000000; // $1 interim
    uint256 constant REG_FEE = 1_000000;
    bytes32 constant X402_ROOT = keccak256("dry-run-root");
    uint256 constant DUST_FLOOR = 1e6;

    bool internal forked;

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
            forked = true;
        } catch {
            forked = false;
        }
    }

    function _guarded(bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR))), salt));
    }

    function _predict(bytes32 salt) internal view returns (address) {
        return CREATEX.computeCreate3Address(_guarded(salt));
    }

    function test_dryRun_constellationDeploysAndWires() public {
        if (!forked) { vm.skip(true); }

        // 1. Predictions (independent of code — pure f(deployer, salt)).
        address pPool  = _predict(SALT_POOL);
        address pX402  = _predict(SALT_X402);
        address pFac   = _predict(SALT_FACTORY);
        address pSalt  = _predict(SALT_SALTPOOL);

        // 2. The pinned template codehash = the FIXED PossessioPayments code.
        bytes32 templateCodehash = keccak256(type(PossessioPayments).creationCode);

        // 3. Every anchor address must be free on the current fork (old set is
        //    occupied; fresh salts must not collide with anything live).
        assertEq(pPool.code.length, 0, "pool addr occupied");
        assertEq(pX402.code.length, 0, "x402 addr occupied");
        assertEq(pFac.code.length,  0, "factory addr occupied");
        assertEq(pSalt.code.length, 0, "saltpool addr occupied");

        vm.startPrank(ANCHOR); // impersonate the anchor EOA (CreateX sender-lock)

        // 4. POOL first (Heart). Sources = predicted [factory, x402Core].
        address[] memory sources = new address[](2);
        sources[0] = pFac;
        sources[1] = pX402;
        address pool = CREATEX.deployCreate3(
            SALT_POOL,
            abi.encodePacked(
                type(PossessioPool).creationCode,
                abi.encode(USDC, sources, OPERATOR, TREASURY, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE)
            )
        );
        assertEq(pool, pPool, "pool != predicted");

        // 5. x402Core (heartSink = pool; brick-guards pool.isInfraSink()).
        address x402 = CREATEX.deployCreate3(
            SALT_X402,
            abi.encodePacked(
                type(PossessioX402Core).creationCode,
                abi.encode(X402_ROOT, DUST_FLOOR, USDC, pool, OPERATOR, FEESRC, CAP, ABS_FLOOR, PER_UNIT, HALFLIFE, REG_FEE)
            )
        );
        assertEq(x402, pX402, "x402 != predicted");

        // 6. factory (feeSink = pool; saltPool = predicted; codehash = fixed Payments).
        address factory = CREATEX.deployCreate3(
            SALT_FACTORY,
            abi.encodePacked(
                type(PossessioFactory).creationCode,
                abi.encode(DEPLOY_FEE, templateCodehash, pSalt, USDC, pool)
            )
        );
        assertEq(factory, pFac, "factory != predicted");

        // 7. saltPool (factory = the now-live factory; feeSource = factory).
        address saltpool = CREATEX.deployCreate3(
            SALT_SALTPOOL,
            abi.encodePacked(
                type(PossessioSaltPool).creationCode,
                abi.encode(factory, KEEPER, OPERATOR, TREASURY, factory)
            )
        );
        assertEq(saltpool, pSalt, "saltpool != predicted");

        vm.stopPrank();

        // 8. WIRING — every immutable cross-reference is consistent.
        assertTrue(PossessioPool(pool).isAuthorizedSource(factory), "pool !authorize factory");
        assertTrue(PossessioPool(pool).isAuthorizedSource(x402), "pool !authorize x402");
        assertEq(PossessioX402Core(x402).heartSink(), pool, "x402.heartSink != pool");
        assertEq(PossessioFactory(factory).feeSink(), pool, "factory.feeSink != pool");
        assertEq(address(PossessioFactory(factory).saltPool()), saltpool, "factory.saltPool != saltpool");
        assertEq(PossessioFactory(factory).templateCodehash(), templateCodehash, "factory codehash != fixed Payments");
        assertEq(PossessioSaltPool(saltpool).factory(), factory, "saltpool.factory != factory");
        assertEq(PossessioSaltPool(saltpool).keeper(), KEEPER, "saltpool.keeper");

        // 9. The pinned codehash IS the fixed PossessioPayments code (the P-1 fix
        //    rides in it): re-derive and compare.
        assertEq(templateCodehash, keccak256(type(PossessioPayments).creationCode), "codehash drift");

        // 10. Emit the staged parameter set for the deploy scripts.
        emit log_string("=== STAGED REDEPLOY SET (bake into script constants) ===");
        emit log_named_address("ANCHOR_EOA", ANCHOR);
        emit log_named_bytes32("SALT_POOL    ", SALT_POOL);
        emit log_named_address("  -> pool    ", pool);
        emit log_named_bytes32("SALT_X402    ", SALT_X402);
        emit log_named_address("  -> x402Core", x402);
        emit log_named_bytes32("SALT_FACTORY ", SALT_FACTORY);
        emit log_named_address("  -> factory ", factory);
        emit log_named_bytes32("SALT_SALTPOOL", SALT_SALTPOOL);
        emit log_named_address("  -> saltPool", saltpool);
        emit log_named_bytes32("TEMPLATE_CODEHASH (THIS toolchain; regen with prod solc)", templateCodehash);
    }
}
