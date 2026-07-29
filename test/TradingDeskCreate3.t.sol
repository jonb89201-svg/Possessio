// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
   TRADING DESK — CREATE3 prewire proof (OFFLINE)

   The vault's `trader` and `tradeDestination` are IMMUTABLE and must
   equal the Rail. The Rail needs the vault address at construction.
   The cycle is broken the "ship prewired" way: PREDICT the Rail's
   CREATE3 address, deploy the vault pointed at it, then deploy the
   Rail into that exact slot. Get the prediction wrong and the vault
   trusts a Rail that never lands there — a permanently bricked,
   immutable pair. This test proves the scripted deploy reproduces a
   correctly cross-wired desk through the REAL CreateX.

   Runs WITHOUT a fork: CreateX is vm.etch'd from the pinned fixture
   (same technique + codehash notarization as ConstellationCreate3Fork).
   A CREATE3 address depends only on (deployer, guarded salt, proxy
   init-code hash) — never on constructor args — so the placeholder
   wiring here does not change the address; the prewire is real.
//////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

contract DeskUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @dev Minimal live infra-sink: satisfies AutoTarget's feeSink brick-guard.
contract MockInfraPool {
    function isInfraSink() external pure returns (bool) { return true; }
}

contract TradingDeskCreate3Test is Test {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    bytes32  internal constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    // A sender-locking EOA for the Rail salt (any EOA; here the anchor EOA).
    address internal constant DESK_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;

    address internal owner     = makeAddr("vaultOwner");
    address internal keeper    = makeAddr("keeper");
    address internal dexRouter = makeAddr("dexRouter");

    uint256 constant MAX_PER_TRADE   = 3_500e6;
    uint256 constant MAX_OUTSTANDING = 10_000e6;
    uint256 constant DAILY_DRAW_CAP  = 20_000e6;
    uint256 constant PER_TX_FEE      = 20_000;  // $0.02 — ratified 2026-07-28,
                                                //   matches AutoTarget's own suites
                                                //   and the R1 toll scale (SPEC_AutoTarget §7.2)

    DeskUSDC      usdc;
    MockInfraPool pool;

    function setUp() public {
        bytes memory code = vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex"));
        vm.etch(address(CREATEX), code);
        assertEq(address(CREATEX).codehash, CANONICAL_RUNTIME_CODEHASH,
            "etched fixture is NOT canonical CreateX");
        usdc = new DeskUSDC();
        pool = new MockInfraPool();
    }

    /// @dev CreateX msg.sender-protected salt: [20 bytes deployer][0x00][11 bytes entropy].
    function _saltFor(address eoa, uint88 entropy) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(eoa)) << 96) | uint256(entropy));
    }

    /// @dev The guarded salt CreateX derives for a sender-protected salt (mirrors
    ///      DeployPoolCreate3.s.sol), used to compute the CREATE3 address up front.
    function _guarded(address eoa, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(eoa))), salt));
    }

    function _railInit(address vault, address at) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(PossessioRail).creationCode,
            abi.encode(address(usdc), vault, at, keeper, dexRouter)
        );
    }

    // ── the deploy the operator will run, proven end-to-end ──────────────────
    function test_deskDeploy_prewires_vaultRailAutoTarget() public {
        // 1. AutoTarget V2 — feeSink is a plain TOLL_SINK address (the ctor
        //    now REJECTS an accounted pool: a plain push there would strand).
        PossessioAutoTarget at = new PossessioAutoTarget(address(usdc), makeAddr("tollSink"), keeper, PER_TX_FEE);

        // 2. Predict the Rail's CREATE3 address BEFORE the vault exists.
        bytes32 salt = _saltFor(DESK_EOA, uint88(0x1234));
        address predictedRail = CREATEX.computeCreate3Address(_guarded(DESK_EOA, salt));

        // 3. Vault, immutably prewired to the predicted Rail (trader + dest).
        PossessioFundingVault vault = new PossessioFundingVault(
            IERC20(address(usdc)), owner, predictedRail, predictedRail,
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );

        // 4. Deploy the Rail into the predicted slot via the real CreateX.
        vm.prank(DESK_EOA);
        address rail = CREATEX.deployCreate3(salt, _railInit(address(vault), address(at)));

        // ── prewire: the Rail MUST land where the vault was told ─────────────
        assertEq(rail, predictedRail, "Rail did not land at predicted address (prewire would brick)");
        assertEq(vault.trader(), rail,           "vault.trader != Rail");
        assertEq(vault.tradeDestination(), rail,  "vault.tradeDestination != Rail");
        assertEq(vault.owner(), owner,            "vault.owner");

        // ── wiring: the Rail points back at the exact organs ─────────────────
        assertEq(address(PossessioRail(rail).vault()), address(vault),   "rail.vault");
        assertEq(address(PossessioRail(rail).autoTarget()), address(at), "rail.autoTarget");
        assertEq(address(PossessioRail(rail).usdc()), address(usdc),     "rail.usdc");
        assertEq(PossessioRail(rail).keeper(), keeper,                   "rail.keeper");
        assertEq(at.feeSink(), makeAddr("tollSink"),                    "autoTarget.feeSink");
        assertGt(rail.code.length, 0, "rail no code");
    }

    // A prewire built against the WRONG Rail address is observably broken before
    // launch — the vault.trader() will not equal the Rail that actually deploys.
    // This is exactly the mismatch the deploy script's prediction guard blocks.
    function test_prewireMismatch_isObservablePreLaunch() public {
        PossessioAutoTarget at = new PossessioAutoTarget(address(usdc), makeAddr("tollSink"), keeper, PER_TX_FEE);

        bytes32 salt = _saltFor(DESK_EOA, uint88(0x1234));
        address predictedRail = CREATEX.computeCreate3Address(_guarded(DESK_EOA, salt));

        // vault mistakenly pinned to the wrong address
        PossessioFundingVault badVault = new PossessioFundingVault(
            IERC20(address(usdc)), owner, address(0xBAD), address(0xBAD),
            MAX_PER_TRADE, MAX_OUTSTANDING, DAILY_DRAW_CAP
        );

        vm.prank(DESK_EOA);
        address rail = CREATEX.deployCreate3(salt, _railInit(address(badVault), address(at)));

        assertEq(rail, predictedRail);
        assertTrue(badVault.trader() != rail, "a prewire mismatch must be detectable before shipping");
    }
}
