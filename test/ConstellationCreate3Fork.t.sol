// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

/*//////////////////////////////////////////////////////////////
      CONSTELLATION — CREATE3 anchor + wiring proof (OFFLINE)

  Deploys the whole foundation (factory -> salt pool -> x402Core ->
  pool) through the REAL CreateX, pranked as the anchor EOA, using
  the phrase-derived salts from deploy/anchor.json — and asserts
  each organ lands at its predicted anchor address with the immutable
  cross-wiring intact (option A: factory.feeSink == pool, pool's
  authorizedSources == [factory, x402Core]).

  Runs WITHOUT a fork: CreateX is vm.etch'd from the pinned fixture
  (same technique + notarization as PossessioSaltPoolCreate3.t.sol).
  A CREATE3 address depends only on (deployer, guarded salt, proxy
  init-code hash) — never on the organ bytecode or economic params —
  so placeholder caps/floors here do NOT change the addresses; only
  the wiring addresses are real.

  Pinned values MUST equal deploy/anchor.json (fs_permissions only
  allows test/fixtures, so we pin rather than vm.readFile). The whole
  point of the test is that the deploy REPRODUCES these addresses.
//////////////////////////////////////////////////////////////*/

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
}

/// Minimal ERC20 for the self-funding door test (SafeERC20-compatible: returns true).
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract ConstellationCreate3ForkTest is Test {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    bytes32  internal constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    address  internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ---- deploy/anchor.json (phrase TREGUNA_..._DEE). MUST match. ----
    address internal constant ANCHOR_EOA = 0xed5c1F69E9778A2243f9E5aF663C9A18e03261eC;
    bytes32 internal constant FACTORY_SALT  = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec008c46fdc1e030e05940087c;
    address internal constant FACTORY_ADDR  = 0x0DD06656cb9a38730a7177792C357E48cEdb49Bd;
    bytes32 internal constant SALTPOOL_SALT = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00e5f3f7bbb10c509f42c757;
    address internal constant SALTPOOL_ADDR = 0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6;
    bytes32 internal constant X402CORE_SALT = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec00ef0925278b81d5e6aa477d;
    address internal constant X402CORE_ADDR = 0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05;
    bytes32 internal constant POOL_SALT     = 0xed5c1f69e9778a2243f9e5af663c9a18e03261ec0008105d4bea8a7e08ed2743;
    address internal constant POOL_ADDR     = 0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce;

    // ---- test-only wiring destinations (distinct, non-zero; real values are
    //      deploy-time env — the passkey Base Account. They do NOT affect the
    //      CREATE3 addresses, so placeholders are correct here). ----
    address internal constant OPERATOR    = address(0x0FE90a704);
    address internal constant TREASURY    = address(0x7EA5017111);
    address internal constant KEEPER      = address(0xBEEF);
    address internal constant X402_FEESRC = address(0xF00D5C);

    // placeholder economics (do NOT affect addresses)
    uint256 internal constant CAP = 100_000e6;
    uint256 internal constant FLOOR = 1_000e6;
    uint256 internal constant FPU = 10e6;
    uint256 internal constant HL = 7 days;

    function setUp() public {
        bytes memory code = vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex"));
        vm.etch(address(CREATEX), code);
        assertEq(address(CREATEX).codehash, CANONICAL_RUNTIME_CODEHASH,
            "etched fixture is NOT canonical CreateX");
    }

    function _deploy(bytes32 salt, bytes memory initCode) internal returns (address) {
        vm.prank(ANCHOR_EOA);
        return CREATEX.deployCreate3(salt, initCode);
    }

    /// Deploy the foundation in the REVISED order (council brick-guard, FIX A):
    /// the factory's constructor now verifies feeSink (the pool) is a LIVE
    /// infra-sink, so the POOL must land BEFORE the factory. CREATE3 addresses
    /// are deterministic, so the pool bakes the PREDICTED factory address as a
    /// source (read only at runtime) without the factory existing yet.
    /// Order: x402Core -> POOL -> factory -> salt pool.
    function _deployConstellation() internal returns (address factory, address saltpool, address x402, address pool) {
        // 1. X402CORE — a pool source; independent of the other organs.
        x402 = _deploy(X402CORE_SALT, abi.encodePacked(
            type(PossessioX402Core).creationCode,
            abi.encode(keccak256("ROOT"), uint256(1e6), USDC, TREASURY, OPERATOR, X402_FEESRC, CAP, FLOOR, FPU, HL)
        ));
        assertEq(x402, X402CORE_ADDR, "x402core != anchor");

        // 2. POOL — sources = [PREDICTED factory, live x402Core]. The factory
        //    address is the deterministic CREATE3 constant; only read at runtime.
        address[] memory sources = new address[](2);
        sources[0] = FACTORY_ADDR;
        sources[1] = x402;
        pool = _deploy(POOL_SALT, abi.encodePacked(
            type(PossessioPool).creationCode,
            abi.encode(USDC, sources, OPERATOR, TREASURY, CAP, FLOOR, FPU, HL)
        ));
        assertEq(pool, POOL_ADDR, "pool != anchor");

        // 3. FACTORY — feeSink = LIVE pool (brick-guard passes), saltPool = predicted.
        factory = _deploy(FACTORY_SALT, abi.encodePacked(
            type(PossessioFactory).creationCode,
            abi.encode(uint256(1e6), keccak256("TEMPLATE"), SALTPOOL_ADDR, USDC, pool)
        ));
        assertEq(factory, FACTORY_ADDR, "factory != anchor");

        // 4. SALT POOL — factory = live factory; deploymentFeeSource = factory (check-only).
        saltpool = _deploy(SALTPOOL_SALT, abi.encodePacked(
            type(PossessioSaltPool).creationCode,
            abi.encode(factory, KEEPER, OPERATOR, TREASURY, factory)
        ));
        assertEq(saltpool, SALTPOOL_ADDR, "saltpool != anchor");
    }

    // ============ CORE GATE: deploys at anchor addresses + wiring ============
    function test_constellation_lands_at_anchor_and_wires() public {
        (address factory, address saltpool, address x402, address pool) = _deployConstellation();

        // all four have live code
        assertGt(factory.code.length, 0, "factory no code");
        assertGt(saltpool.code.length, 0, "saltpool no code");
        assertGt(x402.code.length, 0, "x402 no code");
        assertGt(pool.code.length, 0, "pool no code");

        // immutable cross-wiring resolves
        assertEq(PossessioSaltPool(saltpool).factory(), factory, "saltpool.factory != factory");
        assertEq(address(PossessioFactory(factory).saltPool()), saltpool, "factory.saltPool != saltpool");
        assertEq(PossessioFactory(factory).feeSink(), pool, "factory.feeSink != pool (A)");
        assertTrue(PossessioPool(pool).isAuthorizedSource(factory), "pool does not authorize factory");
        assertTrue(PossessioPool(pool).isAuthorizedSource(x402), "pool does not authorize x402core");
    }

    // ============ SELF-FUNDING DOOR: authorized source credits poolBalance ============
    // Proves the money reaches poolBalance (drawable), not just balanceOf (stranded).
    // NOTE: this drives the POOL door directly (pranked as the factory). The full
    // factory.deployTemplate -> receiveInfraFunds path (the line-211 A-edit) is a
    // factory-DoD test to add once the council lands that edit + a template is pinned.
    function test_selfFunding_authorizedSource_creditsPoolBalance() public {
        (address factory,, , address pool) = _deployConstellation();

        MockUSDC m = new MockUSDC();
        vm.etch(USDC, address(m).code); // real USDC has no code offline; mock stands in

        uint256 fee = 1e6;
        MockUSDC(USDC).mint(factory, fee);
        vm.startPrank(factory);
        MockUSDC(USDC).approve(pool, fee);
        PossessioPool(pool).receiveInfraFunds(fee);
        vm.stopPrank();

        assertEq(PossessioPool(pool).poolBalance(), fee, "fee not credited to poolBalance (stranded!)");

        // a non-authorized caller cannot feed the pool
        address intruder = address(0xDEAD);
        MockUSDC(USDC).mint(intruder, fee);
        vm.startPrank(intruder);
        MockUSDC(USDC).approve(pool, fee);
        vm.expectRevert(); // NotAuthorizedSource
        PossessioPool(pool).receiveInfraFunds(fee);
        vm.stopPrank();
    }

    // ============ FORK-GATED: notarize the CreateX fixture vs live Base ============
    function test_fork_fixtureMatchesLiveCreateX() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        assertEq(address(CREATEX).codehash, CANONICAL_RUNTIME_CODEHASH,
            "pinned CreateX codehash does not match live Base");
    }
}
