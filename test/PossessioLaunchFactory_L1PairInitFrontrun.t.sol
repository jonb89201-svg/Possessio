// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioLaunchFactory, IPoolManagerMinimal} from "../src/PossessioLaunchFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

// ============================================================================
// L-1 — LAUNCH POOL-INIT FRONT-RUN DoS  (cold-seat audit, 2026-08-26)  +  FIX
//
// FINDING: PossessioLaunchFactory.deployLaunch ends by calling, in the same tx,
//   poolManager.initialize({sorted(COUNCIL_TOKEN, launch), fee, spacing,
//                            hooks: launch}, sqrtPriceX96).
// The launch address is CREATE3-deterministic and publicly predictable (the
// pre-mined salt sits in PossessioSaltPool storage, prefix = factory). If the
// launch address does NOT carry the v4 BEFORE_INITIALIZE flag, an attacker can
// call poolManager.initialize on that key FIRST (the launch has no code yet),
// permanently occupying the pool so the victim's deployLaunch reverts. DoS.
//
// FIX (this PR): deployLaunch now requires the launch address to carry the v4
// BEFORE_INITIALIZE flag (bit 13). With the flag set, v4's `initialize` invokes
// `launch.beforeInitialize` on EVERY init of the key — so an attacker's pre-init
// against the still-code-less launch address reverts (hook call to a code-less
// address), and only the factory's own init (AFTER the launch is deployed and
// its beforeInitialize returns the expected selector) succeeds.
//
// This suite models v4 faithfully (a PoolManager that calls beforeInitialize on
// flagged hooks and reverts if that call fails or the pool is already init'd)
// and proves:
//   * test_L1fix_AttackerCannotPreInit_LegitStillWorks — the attacker's pre-init
//     reverts (code-less flagged hook), and the honest deploy then succeeds.
//   * test_L1fix_factoryRejectsUnflaggedSalt — a salt whose launch address lacks
//     the flag is refused (LaunchHookNotInitGated) — the guard is enforced.
//
// RED (pre-fix) would be: the attacker's pre-init SUCCEEDS (no flag ⇒ v4 never
// calls the hook), then deployLaunch reverts PoolAlreadyInitialized — the DoS.
// ============================================================================

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// The init-gate hook interface the launch template must implement (the L-1 fix
/// requirement). v4 calls this when the hooks address carries BEFORE_INITIALIZE.
interface IInitHook {
    function beforeInitialize(address sender, IPoolManagerMinimal.PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (bytes4);
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
    function isAuthorizedSource(address) external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract MockCouncilToken_L1 {
    string public constant name = "POSSESSIO Council Token";
}

/// Launch template that satisfies the L-1 fix contract: it implements
/// beforeInitialize returning the expected selector, so the factory's own init
/// succeeds. (An attacker init runs before this has code, so the call reverts.)
contract MockLaunchTemplate_L1 {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) { owner = _owner; initData = _initArgs; }
    function beforeInitialize(address, IPoolManagerMinimal.PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        return IInitHook.beforeInitialize.selector;
    }
}

/// v4-FAITHFUL PoolManager: reverts if the pool key is already initialized, and
/// — when the hooks address carries BEFORE_INITIALIZE — invokes the hook's
/// beforeInitialize and requires the expected selector, exactly as v4 does. A
/// call to a code-less hook (the attacker's pre-init) reverts.
contract FaithfulPoolManager {
    error PoolAlreadyInitialized();
    error HookRejectedInit();
    uint160 constant BEFORE_INITIALIZE_FLAG = uint160(1) << 13;
    mapping(bytes32 => bool) public initialized;
    uint256 public initCount;

    function _id(IPoolManagerMinimal.PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks));
    }

    function initialize(IPoolManagerMinimal.PoolKey memory key, uint160 sqrtPriceX96)
        external
        returns (int24)
    {
        bytes32 id = _id(key);
        if (initialized[id]) revert PoolAlreadyInitialized();

        // v4: if the hook opts into BEFORE_INITIALIZE, it is consulted on init
        // via a LOW-LEVEL call (as v4's Hooks.callHook does). A code-less hook
        // (the attacker's pre-init, before the launch exists) returns empty data
        // ⇒ InvalidHookResponse. A live hook must return its selector.
        if (uint160(key.hooks) & BEFORE_INITIALIZE_FLAG != 0) {
            (bool ok, bytes memory ret) = key.hooks.call(
                abi.encodeWithSelector(IInitHook.beforeInitialize.selector, msg.sender, key, sqrtPriceX96)
            );
            if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != IInitHook.beforeInitialize.selector) {
                revert HookRejectedInit();
            }
        }

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
    uint160 constant BEFORE_INITIALIZE_FLAG = uint160(1) << 13;

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

    function _guarded(address sender, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
    }

    /// Mine a factory-prefixed salt whose CREATE3 launch address DOES (want=true)
    /// or does NOT (want=false) carry the BEFORE_INITIALIZE flag.
    function _mineSalt(uint88 seed, bool want) internal view returns (bytes32 salt, address predicted) {
        uint256 e = seed;
        while (true) {
            salt = bytes32(bytes20(address(factory))) | bytes32(e);
            predicted = CREATEX.computeCreate3Address(_guarded(address(factory), salt));
            bool flagged = uint160(predicted) & BEFORE_INITIALIZE_FLAG != 0;
            if (flagged == want) return (salt, predicted);
            e++;
        }
    }

    function _refill(bytes32 salt) internal {
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        pool.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioLaunchFactory.FeeAuth memory a) { a; }

    function _keyFor(address launch) internal view returns (IPoolManagerMinimal.PoolKey memory key) {
        (address c0, address c1) = address(council) < launch
            ? (address(council), launch)
            : (launch, address(council));
        key = IPoolManagerMinimal.PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: launch
        });
    }

    // ---- THE FIX: attacker can no longer pre-init; honest deploy still works ----
    function test_L1fix_AttackerCannotPreInit_LegitStillWorks() public {
        (bytes32 salt, address predictedLaunch) = _mineSalt(0x3000, true);
        _refill(salt);

        // Launch address carries BEFORE_INITIALIZE and has no code yet.
        assertTrue(uint160(predictedLaunch) & BEFORE_INITIALIZE_FLAG != 0, "flagged address");
        assertEq(predictedLaunch.code.length, 0, "launch not deployed yet");

        // Attacker tries to occupy the pool first -> v4 calls beforeInitialize on
        // the code-less launch -> reverts. The front-run is dead.
        IPoolManagerMinimal.PoolKey memory key = _keyFor(predictedLaunch);
        vm.prank(attacker);
        vm.expectRevert(FaithfulPoolManager.HookRejectedInit.selector);
        pm.initialize(key, uint160(PRICE) + 1);
        assertEq(pm.initCount(), 0, "attacker could not initialize");

        // Honest deploy now succeeds: the launch is deployed (implements
        // beforeInitialize), the factory's flag check passes, init returns.
        vm.prank(buyer);
        (address launch,) = factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate_L1).creationCode, PRICE, _auth()
        );
        assertEq(launch, predictedLaunch, "deployed == predicted");
        assertEq(pm.initCount(), 1, "pool initialized by the factory");
        assertTrue(factory.isLaunchOfFactory(launch), "launch registered");
    }

    // ---- WHY the flag matters: an UNFLAGGED launch address IS front-runnable ----
    // (the pre-fix world). v4 never calls the hook, so the attacker's pre-init on
    // the code-less predicted address succeeds — the DoS the fix's guard prevents
    // by refusing to deploy any launch whose address lacks the flag.
    function test_L1_unflaggedAddress_wouldBeFrontRunnable() public {
        (, address predictedLaunch) = _mineSalt(0x7000, false);
        assertEq(uint160(predictedLaunch) & BEFORE_INITIALIZE_FLAG, 0, "unflagged address");
        assertEq(predictedLaunch.code.length, 0, "code-less");

        IPoolManagerMinimal.PoolKey memory key = _keyFor(predictedLaunch);
        vm.prank(attacker);
        pm.initialize(key, uint160(PRICE) + 1); // succeeds — no flag ⇒ no hook gate
        assertEq(pm.initCount(), 1, "attacker occupied an unflagged pool (front-run)");
        // The factory's LaunchHookNotInitGated guard is what stops this address
        // from ever being minted — proven in test_L1fix_factoryRejectsUnflaggedSalt.
    }

    // ---- The guard is enforced: an unflagged launch address is refused ----
    function test_L1fix_factoryRejectsUnflaggedSalt() public {
        (bytes32 salt, address predictedLaunch) = _mineSalt(0x5000, false);
        _refill(salt);
        assertEq(uint160(predictedLaunch) & BEFORE_INITIALIZE_FLAG, 0, "unflagged address");

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioLaunchFactory.LaunchHookNotInitGated.selector, predictedLaunch)
        );
        factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate_L1).creationCode, PRICE, _auth()
        );
        // Fee refunded, salt unconsumed (atomic revert).
        assertEq(usdc.balanceOf(buyer), 10 * FEE, "fee refunded");
        assertEq(pool.depth(), 1, "salt unconsumed");
    }
}
