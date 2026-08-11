// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioLaunchFactory, IPoolManagerMinimal} from "../src/PossessioLaunchFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
      POSSESSIO LAUNCH FACTORY - DoD TEST SUITE
      Maps to SPEC_CouncilToken.md §10 (DoD) + §4 (pairing):
        §10.2 PAIRING IS CONSTRUCTIVE - predicted == deployed, key
              contains COUNCIL_TOKEN, hooks == launch, key stored.
        §10.3 ATOMIC ON PAIR FAILURE - pool-init revert unwinds
              everything, caller's USDC intact, salt unconsumed.
        §10.1 PROVENANCE - fee lands in the Heart via the
              accounted door, exact, every launch.
      Real salt pool + etched canonical CreateX (no fork); mock
      EIP-3009 USDC; recording mock PoolManager. The FORK suite
      against the live Base PoolManager is OWED before deploy.
//////////////////////////////////////////////////////////////*/

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// Minimal EIP-3009 USDC mock (house pattern): receiveWithAuthorization
/// moves balance from -> to, payee-only submission enforced.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256, uint256, bytes32, uint8, bytes32, bytes32
    ) external {
        require(msg.sender == to, "3009: only payee may submit");
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// The Heart's stand-in: real pull-door shape (transferFrom), credit counter.
contract MockHeart {
    MockUSDC internal immutable usdc;
    uint256 public received;
    constructor(MockUSDC u) { usdc = u; }
    function isInfraSink() external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

/// A sink with code but no door - the demonstrated brick shape.
contract NotAHeart {
    function unrelated() external pure returns (uint256) { return 1; }
}

/// A sink that answers the marker with an explicit false.
contract FalseHeart {
    function isInfraSink() external pure returns (bool) { return false; }
}

/// Recording mock PoolManager: stores the exact key + price it was
/// initialized with; can be armed to revert (§10.3 atomicity proof).
contract MockPoolManager {
    IPoolManagerMinimal.PoolKey public lastKey;
    uint160 public lastSqrtPriceX96;
    uint256 public initCount;
    bool public revertOnInit;

    function setRevertOnInit(bool v) external { revertOnInit = v; }

    function initialize(IPoolManagerMinimal.PoolKey memory key, uint160 sqrtPriceX96)
        external
        returns (int24)
    {
        if (revertOnInit) revert("POOL_INIT_REVERT");
        lastKey = key;
        lastSqrtPriceX96 = sqrtPriceX96;
        initCount += 1;
        return 42;
    }
}

/// Launch template following the ratified convention (owner, initArgs).
contract MockLaunchTemplate {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) {
        owner = _owner;
        initData = _initArgs;
    }
}

/// Template whose constructor reverts - for the atomicity proof.
contract RevertTemplate {
    constructor(address, bytes memory) { revert("template ctor revert"); }
}

/// Stand-in council token - any live code works; the factory only needs
/// it to EXIST (sequencing guard) and to be an address to pair against.
contract MockCouncilToken {
    string public constant name = "POSSESSIO Council Token";
}

contract PossessioLaunchFactoryTest is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    ICreateX internal constant CREATEX = ICreateX(CREATEX_ADDR);
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    uint256 constant FEE = 50_000_000; // 50 USDC (current live tier's price)
    uint24 constant POOL_FEE = 3000; // 0.30% ppm
    int24 constant TICK_SPACING = 60;
    uint160 constant PRICE = 79228162514264337593543950336; // 1:1 Q64.96

    PossessioLaunchFactory internal factory;
    PossessioSaltPool internal pool;
    MockUSDC internal usdc;
    MockHeart internal heart;
    MockPoolManager internal pm;
    MockCouncilToken internal council;

    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal custody = makeAddr("custody");
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC = address(0x0033);

    bytes32 internal templateCodehash;

    function setUp() public {
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");

        usdc = new MockUSDC();
        heart = new MockHeart(usdc);
        pm = new MockPoolManager();
        council = new MockCouncilToken();
        templateCodehash = keccak256(type(MockLaunchTemplate).creationCode);

        (pool, factory) = _deployPoolAndFactory(templateCodehash);
        usdc.mint(buyer, 10 * FEE);
    }

    /*//////////////////////////////////////////////////////////////
                              Helpers
    //////////////////////////////////////////////////////////////*/

    function _deployPoolAndFactory(bytes32 codehash)
        internal
        returns (PossessioSaltPool p, PossessioLaunchFactory f)
    {
        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        p = new PossessioSaltPool(predictedFactory, keeper, OPERATOR, TREASURY, FEESRC);
        f = new PossessioLaunchFactory(
            FEE, codehash, address(p), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
        require(address(f) == predictedFactory, "factory address prediction failed");
    }

    function _refillSalt(PossessioSaltPool p, address f, uint88 entropy) internal returns (bytes32 salt) {
        salt = bytes32(bytes20(f)) | bytes32(uint256(entropy));
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        p.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioLaunchFactory.FeeAuth memory a) {
        a; // all-zero; the mock ignores signature fields
    }

    uint88 internal saltEntropy = 0x1000;

    function _launch() internal returns (address launch, IPoolManagerMinimal.PoolKey memory key) {
        _refillSalt(pool, address(factory), ++saltEntropy);
        vm.prank(buyer);
        (launch, key) = factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate).creationCode, PRICE, _auth()
        );
    }

    /*//////////////////////////////////////////////////////////////
              §10.1 PROVENANCE - fee to the Heart, accounted
    //////////////////////////////////////////////////////////////*/

    function test_fee_creditsHeart_accountedExact() public {
        uint256 before = usdc.balanceOf(buyer);
        _launch();
        assertEq(heart.received(), FEE, "Heart credit != fee");
        assertEq(usdc.balanceOf(address(heart)), FEE, "Heart balance != fee");
        assertEq(usdc.balanceOf(buyer), before - FEE, "buyer charged != fee");
        assertEq(usdc.balanceOf(address(factory)), 0, "factory must hold nothing");
    }

    function test_fee_secondLaunch_accumulates() public {
        _launch();
        _launch();
        assertEq(heart.received(), 2 * FEE, "two launches, two credits");
    }

    /*//////////////////////////////////////////////////////////////
          §10.2 PAIRING IS CONSTRUCTIVE - the market opens
    //////////////////////////////////////////////////////////////*/

    function test_pairing_keyContainsCouncilToken_sorted() public {
        (address launch, IPoolManagerMinimal.PoolKey memory key) = _launch();
        assertTrue(
            key.currency0 == address(council) || key.currency1 == address(council),
            "pair must contain COUNCIL_TOKEN"
        );
        assertTrue(
            key.currency0 == launch || key.currency1 == launch,
            "pair must contain the launch"
        );
        assertTrue(key.currency0 < key.currency1, "v4 currency ordering violated");
        assertEq(key.fee, POOL_FEE, "pool fee");
        assertEq(key.tickSpacing, TICK_SPACING, "tick spacing");
    }

    function test_pairing_hooksIsTheLaunch() public {
        (address launch, IPoolManagerMinimal.PoolKey memory key) = _launch();
        assertEq(key.hooks, launch, "the launch IS its own hook (owner's 2% engine)");
    }

    function test_pairing_initializeCalledOnce_withExactKey() public {
        (address launch,) = _launch();
        assertEq(pm.initCount(), 1, "exactly one pool init per launch");
        (address c0, address c1, uint24 f, int24 ts, address hooks) = pm.lastKey();
        assertTrue(c0 == address(council) || c1 == address(council), "PM saw the council token");
        assertTrue(c0 == launch || c1 == launch, "PM saw the launch");
        assertEq(hooks, launch, "PM saw the launch as hook");
        assertEq(f, POOL_FEE, "PM saw factory pool fee");
        assertEq(ts, TICK_SPACING, "PM saw factory tick spacing");
        assertEq(pm.lastSqrtPriceX96(), PRICE, "PM saw the caller's initial price");
    }

    /// @dev The guarded salt CreateX derives for a sender-protected salt
    ///      (house pattern, TradingDeskCreate3.t.sol:_guarded).
    function _guarded(address sender, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
    }

    function test_pairing_predictedEqualsDeployed() public {
        bytes32 salt = _refillSalt(pool, address(factory), 0xABCD);
        // Sender-locked salt: CreateX guards it with msg.sender (the factory)
        // before deriving the CREATE3 address. Predict exactly that.
        address predicted = CREATEX.computeCreate3Address(_guarded(address(factory), salt));
        vm.prank(buyer);
        (address launch,) = factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate).creationCode, PRICE, _auth()
        );
        assertEq(launch, predicted, "spec DoD 10.2: predicted == deployed");
    }

    function test_pairing_keyStoredInRegistry() public {
        (address launch, IPoolManagerMinimal.PoolKey memory key) = _launch();
        IPoolManagerMinimal.PoolKey memory stored = factory.pairKeyOf(launch);
        assertEq(stored.currency0, key.currency0);
        assertEq(stored.currency1, key.currency1);
        assertEq(stored.hooks, launch);
        assertTrue(factory.isLaunchOfFactory(launch), "registry recognition");
        assertEq(factory.totalLaunches(), 1);
        assertEq(factory.launches(0), launch);
    }

    function test_ownerWritten_neverFactory() public {
        (address launch,) = _launch();
        assertEq(MockLaunchTemplate(launch).owner(), custody, "owner is caller's custody address");
    }

    /*//////////////////////////////////////////////////////////////
        §10.3 ATOMIC ON PAIR FAILURE - never charged for nothing
    //////////////////////////////////////////////////////////////*/

    function test_atomic_poolInitReverts_unwindsAll() public {
        _refillSalt(pool, address(factory), 0x01);
        pm.setRevertOnInit(true);
        uint256 balBefore = usdc.balanceOf(buyer);
        uint256 depthBefore = pool.depth();

        vm.prank(buyer);
        vm.expectRevert(bytes("POOL_INIT_REVERT"));
        factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate).creationCode, PRICE, _auth()
        );

        assertEq(usdc.balanceOf(buyer), balBefore, "fee refunded on pair failure");
        assertEq(heart.received(), 0, "no Heart credit on pair failure");
        assertEq(pool.depth(), depthBefore, "salt unconsumed on pair failure");
        assertEq(factory.totalLaunches(), 0, "no registry row on pair failure");
    }

    function test_atomic_templateCtorReverts_unwindsAll() public {
        bytes32 badHash = keccak256(type(RevertTemplate).creationCode);
        (PossessioSaltPool p2, PossessioLaunchFactory f2) = _deployPoolAndFactory(badHash);
        _refillSalt(p2, address(f2), 0x02);
        uint256 balBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert();
        f2.deployLaunch(custody, "", type(RevertTemplate).creationCode, PRICE, _auth());

        assertEq(usdc.balanceOf(buyer), balBefore, "fee refunded on template revert");
        assertEq(pm.initCount(), 0, "no pool init on template revert");
    }

    function test_atomic_emptySaltPool_reverts_feeIntact() public {
        uint256 balBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(); // PoolEmpty() inherited unchanged
        factory.deployLaunch(
            custody, abi.encode("v3"), type(MockLaunchTemplate).creationCode, PRICE, _auth()
        );
        assertEq(usdc.balanceOf(buyer), balBefore, "fee intact on empty pool");
        assertEq(pm.initCount(), 0, "no pool init on empty pool");
    }

    /*//////////////////////////////////////////////////////////////
                  Gate order + input rejection
    //////////////////////////////////////////////////////////////*/

    function test_codehashMismatch_revertsBeforeFee() public {
        _refillSalt(pool, address(factory), 0x03);
        uint256 balBefore = usdc.balanceOf(buyer);
        bytes memory wrong = type(RevertTemplate).creationCode;

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PossessioLaunchFactory.TemplateCodehashMismatch.selector,
                keccak256(wrong),
                templateCodehash
            )
        );
        factory.deployLaunch(custody, "", wrong, PRICE, _auth());
        assertEq(usdc.balanceOf(buyer), balBefore, "codehash gate is cost-free");
    }

    function test_zeroOwner_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(PossessioLaunchFactory.ZeroAddress.selector);
        factory.deployLaunch(address(0), "", type(MockLaunchTemplate).creationCode, PRICE, _auth());
    }

    function test_factoryAsOwner_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(PossessioLaunchFactory.OwnerIsFactory.selector);
        factory.deployLaunch(
            address(factory), "", type(MockLaunchTemplate).creationCode, PRICE, _auth()
        );
    }

    function test_zeroInitialPrice_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(PossessioLaunchFactory.ZeroInitialPrice.selector);
        factory.deployLaunch(custody, "", type(MockLaunchTemplate).creationCode, 0, _auth());
    }

    /*//////////////////////////////////////////////////////////////
              Constructor guards (creed: refuse to exist wrong)
    //////////////////////////////////////////////////////////////*/

    function _ctorArgs()
        internal
        view
        returns (uint256, bytes32, address, address, address, address, address, uint24, int24)
    {
        return (
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_zeroFee_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.ZeroFee.selector);
        new PossessioLaunchFactory(
            0, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_emptyCodehash_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.EmptyTemplateCodehash.selector);
        new PossessioLaunchFactory(
            FEE, keccak256(""), address(pool), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_heartIsEOA_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.FeeSinkInterfaceMismatch.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), makeAddr("eoa"),
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_heartWrongContract_reverts() public {
        address brick = address(new NotAHeart());
        vm.expectRevert(PossessioLaunchFactory.FeeSinkInterfaceMismatch.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), brick,
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_heartExplicitFalse_reverts() public {
        address liar = address(new FalseHeart());
        vm.expectRevert(PossessioLaunchFactory.FeeSinkInterfaceMismatch.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), liar,
            address(council), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_councilTokenNotLive_reverts() public {
        // Spec §9 sequencing guard: token FIRST, factory second - a factory
        // pointed at codeless pairing target refuses to exist.
        vm.expectRevert(PossessioLaunchFactory.CouncilTokenNotLive.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            makeAddr("ghostToken"), address(pm), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_poolManagerNotLive_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.PoolManagerNotLive.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), makeAddr("ghostPM"), POOL_FEE, TICK_SPACING
        );
    }

    function test_ctor_badPoolFee_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.BadPoolFee.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), address(pm), 1_000_000, TICK_SPACING
        );
    }

    function test_ctor_badTickSpacing_reverts() public {
        vm.expectRevert(PossessioLaunchFactory.BadTickSpacing.selector);
        new PossessioLaunchFactory(
            FEE, templateCodehash, address(pool), address(usdc), address(heart),
            address(council), address(pm), POOL_FEE, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
                  Deploy-values (immutables read true)
    //////////////////////////////////////////////////////////////*/

    function test_immutables_readBack() public view {
        assertEq(factory.DEPLOYMENT_FEE(), FEE);
        assertEq(factory.templateCodehash(), templateCodehash);
        assertEq(address(factory.saltPool()), address(pool));
        assertEq(factory.heartSink(), address(heart));
        assertEq(factory.COUNCIL_TOKEN(), address(council));
        assertEq(address(factory.poolManager()), address(pm));
        assertEq(factory.POOL_FEE(), POOL_FEE);
        assertEq(factory.TICK_SPACING(), TICK_SPACING);
        assertTrue(factory.isPossessioLaunchFactory());
        assertTrue(factory.hasNoAdminAuthority());
    }
}
