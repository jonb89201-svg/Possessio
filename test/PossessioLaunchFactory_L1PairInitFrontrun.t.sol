// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioLaunchFactory, IPoolManagerMinimal} from "../src/PossessioLaunchFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

// ============================================================================
// L-1 — LAUNCH POOL-INIT FRONT-RUN DoS (cold-seat audit, 2026-08-26)
//
// THE CHARGE THE DoD SUITE NEVER FILED
// ------------------------------------
// PossessioLaunchFactory.deployLaunch ends by calling, in the same tx,
//   poolManager.initialize({sorted(COUNCIL_TOKEN, launch), POOL_FEE,
//                            TICK_SPACING, hooks: launch}, sqrtPriceX96)
// with NO try/catch. Uniswap v4 `initialize` is PERMISSIONLESS and reverts
// PoolAlreadyInitialized if that exact pool key already has a price.
//
// The launch address is CREATE3-deterministic and PUBLICLY PREDICTABLE: the
// pre-mined salt sits in PossessioSaltPool storage (readable), its prefix is
// the factory address, so guardedSalt = keccak256(factory, salt) and
// launch = CreateX.computeCreate3Address(guardedSalt). The launch's hook
// flags are 0x8C8 (BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP |
// BEFORE_SWAP_RETURNS_DELTA) — crucially NOT BEFORE_INITIALIZE — so v4 can
// initialize a pool whose `hooks` address has NO CODE YET.
//
// => An attacker reads the next salt, computes the launch address, and calls
//    poolManager.initialize on that key FIRST (at any price). When the victim's
//    deployLaunch runs, its own initialize reverts, unwinding the WHOLE deploy
//    (fee refunded — no theft). The poisoned launch address's pool is now
//    permanently occupied, and LIFO salt ordering re-serves the same poisoned
//    salt, so the launch rail is held down. DoS-not-drain, but persistent and
//    cheap, on the public launch product.
//
// WHY THE EXISTING SUITE CANNOT SEE IT: test/PossessioLaunchFactory.t.sol's
// MockPoolManager.initialize does NOT model v4's per-key already-initialized
// revert — it re-initializes any key happily and only reverts when globally
// armed. This file supplies a v4-FAITHFUL PoolManager (per-key revert, exactly
// PoolAlreadyInitialized semantics) and files the missing charge.
//
// RED/GREEN (terminal is judge):
//   * test_L1_control_NoPreInit_Succeeds       -> honest deploy works.
//   * test_L1_finding_AttackerPreInit_DoSs     -> identical deploy, but an
//     attacker pre-initialized the predicted pool: deployLaunch REVERTS,
//     fee refunded, salt unconsumed. That revert IS the DoS.
// ============================================================================

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

contract MockUSDC_L1 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256, uint256, bytes32, uint8, bytes32, bytes32
    ) external {
        require(msg.sender == to, "3009: only payee may submit");
        balanceOf[from] -= value; balanceOf[to] += value;
    }
}

contract MockHeart_L1 {
    MockUSDC_L1 internal immutable usdc;
    uint256 public received;
    constructor(MockUSDC_L1 u) { usdc = u; }
    function isInfraSink() external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract MockCouncilToken_L1 {
    string public constant name = "POSSESSIO Council Token";
}

contract MockLaunchTemplate_L1 {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) { owner = _owner; initData = _initArgs; }
}

/// v4-FAITHFUL PoolManager: initialize reverts PoolAlreadyInitialized when the
/// exact pool key already has a price — the real Uniswap v4 semantics the
/// repo's recording mock omits.
contract FaithfulPoolManager {
    error PoolAlreadyInitialized();
    mapping(bytes32 => bool) public initialized;
    uint256 public initCount;

    function _id(IPoolManagerMinimal.PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks));
    }

    function initialize(IPoolManagerMinimal.PoolKey memory key, uint160 /*sqrtPriceX96*/)
        external
        returns (int24)
    {
        bytes32 id = _id(key);
        if (initialized[id]) revert PoolAlreadyInitialized(); // the real v4 guard
        initialized[id] = true;
        initCount += 1;
        return 42;
    }
}

contract PossessioLaunchFactoryL1Test is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    ICreateX internal constant CREATEX = ICreateX(CREATEX_ADDR);
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    uint256 constant FEE = 50_000_000;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant PRICE = 79228162514264337593543950336; // 1:1 Q64.96

    PossessioLaunchFactory internal factory;
    PossessioSaltPool internal pool;
    MockUSDC_L1 internal usdc;
    MockHeart_L1 internal heart;
    FaithfulPoolManager internal pm;
    MockCouncilToken_L1 internal council;

    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal custody = makeAddr("custody");
    address internal attacker = makeAddr("attacker");
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC = address(0x0033);

    bytes32 internal templateCodehash;

    function setUp() public {
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");

        usdc = new MockUSDC_L1();
        heart = new MockHeart_L1(usdc);
        pm = new FaithfulPoolManager();
        council = new MockCouncilToken_L1();
        templateCodehash = keccak256(type(MockLaunchTemplate_L1).creationCode);

        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        pool = new PossessioSaltPool(predictedFactory, keeper, OPERATOR, TREASURY, FEESRC);
        factory = new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
        require(address(factory) == predictedFactory, "factory prediction failed");

        usdc.mint(buyer, 10 * FEE);
    }

    function _refillSalt(uint88 entropy) internal returns (bytes32 salt) {
        salt = bytes32(bytes20(address(factory))) | bytes32(uint256(entropy));
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        pool.refillSalts(b);
    }

    function _guarded(address sender, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
    }

    function _auth() internal pure returns (PossessioLaunchFactory.FeeAuth memory a) { a; }

    /// Rebuild the exact key the factory will construct for a predicted launch.
    function _keyFor(address launch) internal view returns (IPoolManagerMinimal.PoolKey memory key) {
        (address c0, address c1) = address(council) < launch
            ? (address(council), launch)
            : (launch, address(council));
        key = IPoolManagerMinimal.PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: launch
        });
    }

    // ---- CONTROL: honest deploy against the faithful PM succeeds ----
    function test_L1_control_NoPreInit_Succeeds() public {
        _refillSalt(0x1111);
        vm.prank(buyer);
        (address launch,) = factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate_L1).creationCode, PRICE, _auth()
        );
        assertEq(pm.initCount(), 1, "pool initialized once");
        assertTrue(factory.isLaunchOfFactory(launch), "launch registered");
    }

    // ---- FINDING: attacker pre-initializes the predicted pool -> DoS ----
    function test_L1_finding_AttackerPreInit_DoSs() public {
        bytes32 salt = _refillSalt(0x2222);

        // Anyone can read the pending salt from PossessioSaltPool storage and
        // compute the CREATE3 launch address the factory WILL deploy to.
        address predictedLaunch = CREATEX.computeCreate3Address(_guarded(address(factory), salt));

        // The launch has NO code yet; its hook flags (0x8C8) exclude
        // BEFORE_INITIALIZE, so v4 initialize does not call the hook and
        // succeeds against the codeless address.
        assertEq(predictedLaunch.code.length, 0, "launch not deployed yet");
        IPoolManagerMinimal.PoolKey memory key = _keyFor(predictedLaunch);

        // Attacker front-runs: initialize the launch's pool first, any price.
        vm.prank(attacker);
        pm.initialize(key, uint160(PRICE) + 1);
        assertEq(pm.initCount(), 1, "attacker occupied the pool");

        // Victim's honest deploy now reverts at the pairing step: the whole tx
        // unwinds (CREATE3 deploy included), fee refunded, salt unconsumed.
        uint256 balBefore = usdc.balanceOf(buyer);
        uint256 depthBefore = pool.depth();

        vm.prank(buyer);
        vm.expectRevert(FaithfulPoolManager.PoolAlreadyInitialized.selector);
        factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate_L1).creationCode, PRICE, _auth()
        );

        assertEq(usdc.balanceOf(buyer), balBefore, "fee refunded (no theft) ...");
        assertEq(heart.received(), 0, "... no Heart credit ...");
        assertEq(pool.depth(), depthBefore, "... salt not consumed (LIFO re-serves the poisoned salt)");
        assertEq(predictedLaunch.code.length, 0, "launch never deployed - DoS");
        assertFalse(factory.isLaunchOfFactory(predictedLaunch), "no launch registered - DoS");
    }
}
