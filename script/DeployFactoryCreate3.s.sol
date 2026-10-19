// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_FACTORY_CREATE3_V1 — deploys PossessioFactory via CreateX
// CREATE3. SUPERSEDES script/DeployPossessioFactory.s.sol (plain `new`, nonce-based).
// The factory becomes a CREATE3 organ: address = f(anchor EOA, salt) ONLY — no nonce
// discipline, same address on every EVM chain, sender-locked to the anchor key.
//
// ANCHOR: deploy/anchor.json (phrase-derived, byte-verified). All pinned constants
// below MUST equal anchor.json; the script recomputes salt->address via CreateX's own
// view and REFUSES to deploy on any mismatch.
//
// feeSink = A (SPEC_Factory_FeeSink_A.md): feeSink is the POOL. The CREATE3 address is
// bytecode-INDEPENDENT, so this script produces the same factory address whether or not
// the council's line-211 edit has landed — which is a TRAP:
//
//   *** DO NOT BROADCAST TO MAINNET UNTIL THE LINE-211 EDIT IS IN THE SOURCE. ***
//   Deploying the un-edited factory occupies the permanent anchor address with the
//   fund-STRANDING version (safeTransfer to a pool with no sync door), and a CREATE3
//   address cannot be redeployed. The fork test's "fee credits poolBalance" assertion
//   is the gate that proves the edit is live BEFORE any mainnet broadcast.
//
// Also load-bearing (checked at POOL deploy, not here — factory-first order): the
// factory address below MUST be in Pool.authorizedSources, or every deployTemplate
// reverts NotAuthorizedSource.
//
// PRE-FLIGHT (review 2026-10-17, F-2 / F-6 / F-7): before any gas, the script runs the
// factory constructor's own checks against BOTH pools from the outside (live code, the
// isInfraSink door, this factory's PREDICTED address in the source set) and checks that
// each pool's per-launch cut clears its FLOOR_PER_UNIT dust gate. A mis-wired
// constellation fails HERE with a named error, not as an opaque CreateX revert, and
// never as a partner-less factory at the permanent address. The partner is an explicit
// yes or no (WITH_PARTNER), never a default.
//
// RUN (Base FORK first — proves everything, spends no real ETH):
//   DEPLOYER_PK=<anchor EOA key> DEPLOYMENT_FEE=50000000 TEMPLATE_CODEHASH=0x... \
//   WITH_PARTNER=true PARTNER_SINK_ADDR=0x<partner pool> PARTNER_BPS=5000 \
//   forge script script/DeployFactoryCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv
// (WITH_PARTNER=false deploys without a partner; unset refuses to run.)
// then add --broadcast ONLY after the fork constellation test is green.

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

/// The slice of PossessioPool the pre-flight reads. Declared here so the script
/// speaks the deployed pool's ABI, exactly as the factory's constructor does.
interface IPoolProbe {
    function isInfraSink() external view returns (bool);
    function isAuthorizedSource(address source) external view returns (bool);
    function FLOOR_PER_UNIT() external view returns (uint256);
    function operatorDestination() external view returns (address);
    function treasuryDestination() external view returns (address);
}

contract DeployFactoryCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address  constant PAY_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base

    // ---- PINNED from deploy/anchor.json (phrase TREGUNA_..._DEE). MUST match. ----
    // RESTAGED 2026-08-26: fresh salts for the fixed-source redeploy (dry-run-
    // proven in test/StageRedeployDryRun.t.sol). TEMPLATE_CODEHASH stays env-
    // driven — REGENERATE it from the FIXED PossessioPayments with the production
    // toolchain (solc 0.8.35) before running; do not reuse a value from another compiler.
    //   MEASURED (solc 0.8.35, CI run #173, commit 7d1d7c2, via test/TemplateCodehashProbe.t.sol):
    //   TEMPLATE_CODEHASH=0x7dd017f4b4ba788b0002b78c0d933dde57a03c31a1a1f81ab5f51b329d337130
    //   STALE since f0e545e (09-01) and K-1/K-2/K-3 (2026-10-16); local 0.8.35 with K-1..K-3 is
    //   0xb5889618a1dfb32a18150da03c6314fa4eae7b220af4af33266849f5641c8582. Re-measure in CI before deploying.
    //   (local 0.8.27 control was 0x94df70b2…3e50 — DO NOT USE. See REDEPLOY_CHECKLIST_2026-08-26.md §2.)
    address constant ANCHOR_EOA        = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 constant FACTORY_SALT      = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec003b32c63f7efcd69736d863;
    address constant PREDICTED_FACTORY = 0x5509BA759ce6CdC4Fc719E38436bA33b734BF155;
    address constant SALT_POOL         = 0xb61f5200Dd46d4D6d6399aCf12c8E9bFF549a5d9; // predicted (factory arg)
    address constant POOL              = 0xD064Bb5C00798d8A523089B750a6c3350eC86797; // predicted (feeSink = A)

    error WrongChain(uint256 got);
    error KeyIsNotAnchorEOA(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error DeployedMismatch(address deployed, address predicted);
    error FeeSinkPoolNotLive(address pool);
    // Pre-flight errors (review 2026-10-17). Each names the pool it is about.
    error PartnerConfigIncomplete(address sink, uint256 bps);
    error PoolInterfaceMismatch(address pool);
    error PoolRefusesFactory(address pool, address factory);
    error CutBelowFloorUnit(address pool, uint256 cut, uint256 floorPerUnit);
    error StubPartnerDestination(address pool, address destination);

    /// The partner pool's placeholder destination while the partner has not
    /// supplied its Safe (DeployPartnerPoolCreate3.s.sol). A factory pinned to a
    /// pool that pays the stub would pay nobody: refused unless
    /// ALLOW_STUB_PARTNER=true is stated, which is for fork and staging runs only.
    address public constant PARTNER_DEST_STUB = 0x0000000000000000000000000000000000005aFE;

    function run() external returns (address factoryAddr) {
        if (block.chainid != 8453) revert WrongChain(block.chainid); // Base (fork or mainnet)

        uint256 pk               = vm.envUint("DEPLOYER_PK");
        uint256 deploymentFee    = vm.envUint("DEPLOYMENT_FEE");        // Architect's price: 50_000000 = $50 (2026-10-17), split with the partner pool when WITH_PARTNER
        bytes32 templateCodehash = vm.envBytes32("TEMPLATE_CODEHASH");  // pinned template creation-code hash
        (address partnerSink, uint256 partnerBps) = _partnerConfig();   // PARTNER SHARE, explicit yes or no

        // The broadcasting key MUST be the anchor EOA — the salt is sender-locked to it,
        // so any other caller is rejected by CreateX's guard. Fail early and readably.
        if (vm.addr(pk) != ANCHOR_EOA) revert KeyIsNotAnchorEOA(vm.addr(pk));

        // Salt layout guard: [deployer 20][0x00][entropy 11], locked to the anchor EOA.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(FACTORY_SALT)) != ANCHOR_EOA || FACTORY_SALT[20] != 0x00) revert SaltNotSenderLocked();

        // VERIFY salt -> predicted address via CreateX's own view BEFORE deploying.
        // guardedSalt = keccak256(leftpad32(deployer) ++ salt)  (MsgSender/RedeployProtection.False)
        bytes32 guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(ANCHOR_EOA))), FACTORY_SALT));
        address computed = CREATEX.computeCreate3Address(guardedSalt);
        if (computed != PREDICTED_FACTORY) revert PredictionMismatch(computed, PREDICTED_FACTORY);

        // VERIFY-BEFORE-WIRE (council brick-guard, FIX A): feeSink = POOL must be
        // LIVE before the factory deploys — the factory's constructor staticcalls
        // pool.isInfraSink() and reverts if absent. This is why the REVISED deploy
        // order is POOL -> x402Core -> factory -> saltPool (RUNBOOK §2). If the
        // pool is not live, stop here rather than let CreateX wrap the brick-guard
        // revert in an opaque failure. The same three checks the constructor makes
        // (code, door, source set) run here against the PREDICTED factory address,
        // for the fee sink and, when set, the partner's pool.
        uint256 partnerCut = (deploymentFee * partnerBps) / 10_000;
        uint256 ownCut     = deploymentFee - partnerCut;
        _requireLivePool(POOL);
        _requireCutClearsFloor(POOL, ownCut);
        if (partnerSink != address(0)) {
            _requireLivePool(partnerSink);
            _requireCutClearsFloor(partnerSink, partnerCut);
            _requirePartnerDestinationReal(partnerSink, vm.envOr("ALLOW_STUB_PARTNER", false));
        }

        // Say what is about to be frozen into the permanent address, before any gas.
        console2.log("=== PossessioFactory CREATE3 pre-flight (Base) ===");
        console2.log("  deploymentFee         :", deploymentFee);
        console2.log("  templateCodehash      :");
        console2.logBytes32(templateCodehash);
        console2.log("  feeSink = POOL (A)    :", POOL);
        console2.log("  own cut per launch    :", ownCut);
        console2.log("  partnerSink           :", partnerSink);
        console2.log("  partnerBps            :", partnerBps);
        console2.log("  partner cut per launch:", partnerCut);

        // initCode = factory creation bytecode ++ abi.encode(constructor args).
        // Constructor order: (_deploymentFee, _templateCodehash, _saltPool, _payToken, _feeSink,
        //                     _partnerSink, _partnerBps).
        // feeSink = POOL (option A). Address is independent of this bytecode.
        bytes memory initCode = abi.encodePacked(
            type(PossessioFactory).creationCode,
            abi.encode(deploymentFee, templateCodehash, SALT_POOL, PAY_TOKEN, POOL, partnerSink, partnerBps)
        );

        vm.startBroadcast(pk);
        factoryAddr = CREATEX.deployCreate3(FACTORY_SALT, initCode);
        vm.stopBroadcast();

        // HARD GATE: the deployed address is the anchor prediction, or the wave stops.
        if (factoryAddr != PREDICTED_FACTORY) revert DeployedMismatch(factoryAddr, PREDICTED_FACTORY);

        console2.log("=== PossessioFactory DEPLOYED via CREATE3 (Base) ===");
        console2.log("  factory (== anchor)  :", factoryAddr);
        console2.log("  extcodehash (RECORD as the factory front-run gate's expected):");
        console2.logBytes32(factoryAddr.codehash);
        console2.log("  saltPool (predicted) :", SALT_POOL);
        console2.log("  feeSink = POOL (A)   :", POOL);
        console2.log("  deploymentFee        :", deploymentFee);
        console2.log("  payToken (USDC)      :", PAY_TOKEN);
        console2.log("  partnerSink          :", partnerSink);
        console2.log("  partnerBps           :", partnerBps);
        console2.log("");
        console2.log("REMINDER: this deploys PossessioFactory AS COMPILED. If the line-211");
        console2.log("A-edit is not in the source, this is the fund-stranding factory at the");
        console2.log("PERMANENT anchor address. The fork test's poolBalance assertion is the gate.");
        console2.log("");
        console2.log("NEXT (verify-before-wire): deploy salt pool -> x402Core -> pool, each");
        console2.log("extcodehash-gated; the pool's authorizedSources MUST include this factory.");
    }

    /// WITH_PARTNER is an explicit yes or no (review 2026-10-17, F-2). With the
    /// old envOr defaults a typo in a variable NAME deployed a partner-less
    /// factory at the permanent CREATE3 address, silently. Now: unset refuses to
    /// run, `false` ignores the partner variables, `true` requires both of them
    /// to be set and non-zero.
    function _partnerConfig() internal view returns (address sink, uint256 bps) {
        if (!vm.envBool("WITH_PARTNER")) return (address(0), 0);
        sink = vm.envAddress("PARTNER_SINK_ADDR"); // the partner's PossessioPool
        bps  = vm.envUint("PARTNER_BPS");          // e.g. 5000 = half of each fee
        if (sink == address(0) || bps == 0) revert PartnerConfigIncomplete(sink, bps);
    }

    /// The factory constructor's own sink checks (PossessioFactory
    /// `_requireLivePool`), run from the outside against the PREDICTED factory
    /// address (review 2026-10-17, F-7). The code-length pre-check catches the
    /// EOA/undeployed case explicitly; the try/catch catches has-code-but-wrong
    /// and an explicit `false`.
    function _requireLivePool(address pool) internal view {
        if (pool.code.length == 0) revert FeeSinkPoolNotLive(pool);
        try IPoolProbe(pool).isInfraSink() returns (bool ok) {
            if (!ok) revert PoolInterfaceMismatch(pool);
        } catch {
            revert PoolInterfaceMismatch(pool);
        }
        try IPoolProbe(pool).isAuthorizedSource(PREDICTED_FACTORY) returns (bool authorized) {
            if (!authorized) revert PoolRefusesFactory(pool, PREDICTED_FACTORY);
        } catch {
            revert PoolInterfaceMismatch(pool);
        }
    }

    /// A pool counts an inflow toward its velocity floor only when the inflow is
    /// at least FLOOR_PER_UNIT (the X-H1 dust gate). A per-launch cut below that
    /// is credited but never raises the floor, so the pool's protection would
    /// not grow with launches at all. Price, split and both pools' calibration
    /// must agree before the one-shot deploy (review 2026-10-17, F-6).
    function _requireCutClearsFloor(address pool, uint256 cut) internal view {
        uint256 floorPerUnit = IPoolProbe(pool).FLOOR_PER_UNIT();
        if (cut < floorPerUnit) revert CutBelowFloorUnit(pool, cut, floorPerUnit);
    }

    /// The partner pool's two destinations must be the partner's real Safe. The
    /// stub (staging placeholder) is refused unless ALLOW_STUB_PARTNER=true is
    /// stated (`allowStub`, read once in run()); then it is logged loudly. The pin
    /// is immutable, so a factory that went out with a stub-destination partner
    /// pool could never pay the partner.
    function _requirePartnerDestinationReal(address pool, bool allowStub) internal view {
        address op = IPoolProbe(pool).operatorDestination();
        address tr = IPoolProbe(pool).treasuryDestination();
        if (op == PARTNER_DEST_STUB || tr == PARTNER_DEST_STUB) {
            if (!allowStub) revert StubPartnerDestination(pool, op == PARTNER_DEST_STUB ? op : tr);
            console2.log("  !! PARTNER POOL DESTINATION IS THE STUB (ALLOW_STUB_PARTNER=true): staging only");
        }
    }
}
