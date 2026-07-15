// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_POSSESSIOPOOL_V1 - deploys PossessioPool ("THE HEART")
// to Base mainnet (chain 8453). FOUNDATION STEP 2 of 3 (deploy/
// optimizer_pool.json: salt pool -> protocol pool -> factory, ratified order).
// One-time manual deploy; the authorized-source set is IMMUTABLE at
// construction — get it wrong and the fix is a redeploy.
//
// ─────────────────────────────────────────────────────────────────────────────
// SOURCE-SET RECONCILIATION (the three documents, read together)
// ─────────────────────────────────────────────────────────────────────────────
// Three ratified texts speak to what feeds the pool:
//
//   1. deploy/optimizer_pool.json (_business_model, step 2): "fed by exactly
//      two inflows: the auto-launch fees and x402Core. NOTHING ELSE feeds it —
//      payments is NOT a pool source, and v2.6.3 is NOT connected to it."
//   2. TODO.md "Factory → Pool wiring upgrade": the v1 factory's feeSink is
//      the LIVE Payments address, NOT this pool — the accounted
//      receiveInfraFunds() wiring lands in a LATER factory version. The pool
//      contract's own header resolves the timing: "The factory may be
//      authorized at construction even though its feeSink->receiveInfraFunds
//      upgrade lands later — authorization does not require the organ to call
//      yet, it only permits it when ready."
//   3. specs/SPEC_PossessioWhiskyMarket.md §6 + TODO.md parked whisky item:
//      the whisky market address must be KNOWN (CreateX salt mined ->
//      deterministic address) and included in the source set AT POOL DEPLOY,
//      "OR the whisky market joins a later pool deployment" (§6's own words).
//
// RECONCILED HERE:
//   · FACTORY_ADDR (the auto-launch-fee organ) — REQUIRED member. It is the
//     PREDICTED factory address (foundation step 3 hasn't run yet; see
//     PredictCreate3Addresses.s.sol). Authorized now, calls later, per (2).
//   · X402CORE_ADDR — REQUIRED member, per (1). x402Core mainnet does not
//     exist yet either; this is its pre-derived deterministic address
//     (CREATE3: sender-locked salt -> address known before deploy).
//   · WHISKY_MARKET_ADDR — OPEN, ARCHITECT RATIFIES. (1)'s "exactly two"
//     and (3)'s "must be in the set at pool deploy" genuinely conflict; §6
//     itself names the escape hatch (a later pool deployment). This script
//     does NOT decide: it refuses to run until the Architect either exports
//     WHISKY_MARKET_ADDR (include: mine the market salt first, §6) or exports
//     WHISKY_MARKET_EXCLUDED=true (ratify the two-source set; the whisky
//     market joins a future pool redeploy). Exactly one of the two — both or
//     neither refuses.
//
// FLOOR PARAMS ARE SOFT — AND A DEPLOY GATE STANDS BEFORE THIS SCRIPT. The
// pool's own header (src/PossessioPool.sol) holds three PENDING items before
// the immutable freeze: (1) fork-prove on Base, (2) calibrate CAP/FLOOR/
// PER_UNIT/HALFLIFE to real throughput+cost data, (3) cold-seat re-audit.
// The four numbers are therefore ENV-GATED, not hardcoded placeholders: this
// script refuses to run until the Architect exports the ratified,
// post-fork-calibration values. No defaults — a default would be a decision.
//
//   PINNED (verified Base-mainnet value, already hardcoded by
//   DeployPossessioFactory.s.sol / DeployPayments.s.sol):
//     - payToken   0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (Circle USDC, Base)
//
//   ENV-GATED (script REFUSES to run until each is set):
//     - FACTORY_ADDR            — predicted factory address (source #1, required)
//     - X402CORE_ADDR           — pre-derived x402Core CREATE3 address (source #2, required)
//     - WHISKY_MARKET_ADDR      — mined whisky-market CREATE3 address (source #3)
//         XOR WHISKY_MARKET_EXCLUDED=true — Architect ratifies the 2-source set
//     - OPERATOR_DEST_ADDR      — immutable operatorDestination (only draw target)
//     - TREASURY_DEST_ADDR      — immutable treasuryDestination (one-way surplus sink)
//     - POOL_OPERATIONAL_CAP    — OPERATIONAL_CAP, USDC 6-dec (calibrated, ratified)
//     - POOL_ABSOLUTE_FLOOR     — ABSOLUTE_FLOOR, USDC 6-dec (calibrated, ratified)
//     - POOL_FLOOR_PER_UNIT     — FLOOR_PER_UNIT, USDC 6-dec (calibrated, ratified)
//     - POOL_VELOCITY_HALFLIFE  — VELOCITY_HALFLIFE, seconds (calibrated, ratified)
//
// VALVE INTEGRITY: the constructor reverts if any source equals operator or
// treasury, is zero, or repeats (src/PossessioPool.sol ~:211-220). This script
// pre-checks the same conditions so a miswire fails fast with a readable
// message instead of a raw revert. (treasury == operator stays ALLOWED — the
// contract's documented intentional omission; not checked here either.)
//
// RUN (Base mainnet — after the salt pool, before the factory):
//   FACTORY_ADDR=0x... \
//   X402CORE_ADDR=0x... \
//   WHISKY_MARKET_ADDR=0x...        # or: WHISKY_MARKET_EXCLUDED=true \
//   OPERATOR_DEST_ADDR=0x... \
//   TREASURY_DEST_ADDR=0x... \
//   POOL_OPERATIONAL_CAP=... POOL_ABSOLUTE_FLOOR=... \
//   POOL_FLOOR_PER_UNIT=... POOL_VELOCITY_HALFLIFE=... \
//   forge script script/DeployPossessioPool.s.sol \
//     --rpc-url $BASE_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_possessiopool.txt

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

contract DeployPossessioPool is Script {
    // ---- PINNED: verified Base-mainnet USDC (same constant the factory + payments scripts pin) ----
    address constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base

    error WrongChain(uint256 got);              // foundation deploys are Base mainnet only
    error WhiskyMembershipNotRatified();        // set WHISKY_MARKET_ADDR xor WHISKY_MARKET_EXCLUDED=true
    error SourceCollidesWithDestination();      // pre-check mirror of ValveIntegrityViolation
    error SourcesMustBeDistinct();              // pre-check mirror of DuplicateSource

    function run() external returns (address poolAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PK");

        // ---- required sources (ratified: optimizer_pool.json's two inflows) ----
        address factory  = vm.envAddress("FACTORY_ADDR");
        address x402Core = vm.envAddress("X402CORE_ADDR");
        require(factory  != address(0), "FACTORY_ADDR not set - predict the factory address first (PredictCreate3Addresses)");
        require(x402Core != address(0), "X402CORE_ADDR not set - derive the x402Core CREATE3 address first");

        // ---- OPEN member: whisky market (ARCHITECT RATIFIES, this script does not decide) ----
        address whisky        = vm.envOr("WHISKY_MARKET_ADDR", address(0));
        bool whiskyExcluded   = vm.envOr("WHISKY_MARKET_EXCLUDED", false);
        if ((whisky == address(0)) == !whiskyExcluded) revert WhiskyMembershipNotRatified();

        // ---- immutable destinations ----
        address operator = vm.envAddress("OPERATOR_DEST_ADDR");
        address treasury = vm.envAddress("TREASURY_DEST_ADDR");
        require(operator != address(0), "OPERATOR_DEST_ADDR not set - ratify the infrastructure operator address");
        require(treasury != address(0), "TREASURY_DEST_ADDR not set - ratify the sovereign treasury address");

        // ---- calibrated floor params (soft until fork data; env = the ratified numbers) ----
        uint256 cap      = vm.envUint("POOL_OPERATIONAL_CAP");
        uint256 floor    = vm.envUint("POOL_ABSOLUTE_FLOOR");
        uint256 perUnit  = vm.envUint("POOL_FLOOR_PER_UNIT");
        uint256 halflife = vm.envUint("POOL_VELOCITY_HALFLIFE");
        require(cap != 0,      "POOL_OPERATIONAL_CAP not set/zero - calibrate + ratify before the immutable freeze");
        require(halflife != 0, "POOL_VELOCITY_HALFLIFE not set/zero - zero disables decay (floor never falls)");
        // ABSOLUTE_FLOOR / FLOOR_PER_UNIT may legitimately calibrate to small
        // values but never silently: envUint already reverts when unset.

        // ---- assemble the immutable source set ----
        uint256 n = whisky == address(0) ? 2 : 3;
        address[] memory sources = new address[](n);
        sources[0] = factory;
        sources[1] = x402Core;
        if (n == 3) sources[2] = whisky;

        // Pre-check mirrors of the constructor's structural guards
        // (ValveIntegrityViolation / DuplicateSource) - fail fast, readable.
        for (uint256 i = 0; i < n; ++i) {
            if (sources[i] == operator || sources[i] == treasury) revert SourceCollidesWithDestination();
            for (uint256 j = i + 1; j < n; ++j) {
                if (sources[i] == sources[j]) revert SourcesMustBeDistinct();
            }
        }

        vm.startBroadcast(pk);
        // Constructor order: (_payToken, _authorizedSources, _operatorDestination,
        //   _treasuryDestination, _operationalCap, _absoluteFloor, _floorPerUnit,
        //   _velocityHalflife)
        PossessioPool pool = new PossessioPool(
            PAY_TOKEN,
            sources,
            operator,
            treasury,
            cap,
            floor,
            perUnit,
            halflife
        );
        vm.stopBroadcast();

        poolAddr = address(pool);

        console2.log("=== PossessioPool DEPLOYED (Base mainnet) - FOUNDATION 2/3 ===");
        console2.log("  Pool address        :", poolAddr);
        console2.log("  payToken (USDC)     :", PAY_TOKEN);
        console2.log("  source[0] factory   :", factory, "(PREDICTED - step 3 must land exactly here)");
        console2.log("  source[1] x402Core  :", x402Core, "(pre-derived CREATE3)");
        if (n == 3) {
            console2.log("  source[2] whisky    :", whisky, "(mined CREATE3, SPEC whisky #6)");
        } else {
            console2.log("  source[2] whisky    : EXCLUDED (Architect-ratified 2-source set)");
        }
        console2.log("  operatorDestination :", operator);
        console2.log("  treasuryDestination :", treasury);
        console2.log("  OPERATIONAL_CAP     :", cap);
        console2.log("  ABSOLUTE_FLOOR      :", floor);
        console2.log("  FLOOR_PER_UNIT      :", perUnit);
        console2.log("  VELOCITY_HALFLIFE   :", halflife);
        console2.log("");
        console2.log("NEXT (RUNBOOK_FOUNDATION.md): deploy the factory (step 3) and VERIFY");
        console2.log("      it lands at source[0] above - the set is immutable; a miss means");
        console2.log("      this pool never hears the factory and the foundation restarts.");
        console2.log("      v1 factory fees still route to Payments (feeSink) by design; the");
        console2.log("      accounted receiveInfraFunds() wiring is the later factory upgrade.");
    }
}
