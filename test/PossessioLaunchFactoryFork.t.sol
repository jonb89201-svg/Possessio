// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioLaunchFactory, IPoolManagerMinimal} from "../src/PossessioLaunchFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
     POSSESSIO LAUNCH FACTORY - FORK SUITE (Base mainnet)
     The §10.2 fork proof: the pairing initializes on the LIVE
     Uniswap v4 PoolManager, not a mock. Skips loudly offline
     (vm.skip) — nothing passes without executing.

     WHAT THIS PROVES that the offline suite cannot:
       - the real PoolManager accepts the factory's PoolKey shape
         (address-typed key is ABI-identical to v4-core's), AND
       - the hook-address constraint is REAL: a launch address
         without valid v4 hook permission bits reverts
         HookAddressNotValid — the reason the salt pool must be
         loaded with hook-flag-mined salts (0x8C8 discipline).

     Fee routing uses a fresh in-fork heart: the LIVE Heart's
     authorizedSources is sealed at [factory, x402Core] and can
     never include a test factory — that door is already fork-
     proven for the live factory (PossessioFactoryFork). The
     unknown under test here is the PAIRING, and only the live
     PoolManager can certify it.

     Run: BASE_FORK_RPC=<url> forge test --match-contract LaunchFactoryFork
//////////////////////////////////////////////////////////////*/

interface IUSDCMintable {
    function balanceOf(address) external view returns (uint256);
}

contract ForkMockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

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

contract ForkHeart {
    ForkMockUSDC internal immutable usdc;
    uint256 public received;
    constructor(ForkMockUSDC u) { usdc = u; }
    function isInfraSink() external pure returns (bool) { return true; }
    function isAuthorizedSource(address) external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract ForkCouncilToken {
    string public constant name = "POSSESSIO Council Token (fork)";
}

/// Launch template (ratified constructor shape). After the L-1 fix the launch
/// address carries BEFORE_INITIALIZE, so the LIVE v4 PoolManager invokes
/// beforeInitialize on init — the template MUST implement it and return the
/// expected selector, or the honest init reverts. (The BEFORE_SWAP flag models
/// the owner's 2% fee engine; the real template implements that too.)
contract ForkLaunchTemplate {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) {
        owner = _owner;
        initData = _initArgs;
    }
    /// v4 calls this because the address carries BEFORE_INITIALIZE. Returning
    /// the selector authorizes the init (the factory's own, atomic, post-deploy
    /// call). An attacker's pre-init hits this on a code-less address ⇒ revert.
    function beforeInitialize(address, IPoolManagerMinimal.PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }
}

contract PossessioLaunchFactoryForkTest is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    /// CreateX CREATE3 proxy initcode hash (house constant, byte-matched
    /// in PossessioFactory.t.sol / the salt-pool suite).
    bytes32 internal constant PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// v4 Hooks: low 14 bits are permission flags. BEFORE_SWAP = 1 << 7,
    /// BEFORE_INITIALIZE = 1 << 13 (the L-1 gate). A launch address must carry
    /// BOTH: BEFORE_SWAP for the fee engine, BEFORE_INITIALIZE so v4 gates the
    /// pool init against the launch's own hook (front-run defense).
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant REQUIRED_FLAGS = BEFORE_SWAP_FLAG | BEFORE_INITIALIZE_FLAG;

    uint256 constant FEE = 50_000_000;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant PRICE = 79228162514264337593543950336; // 1:1 Q64.96

    bool internal forked;

    PossessioLaunchFactory internal factory;
    PossessioSaltPool internal pool;
    ForkMockUSDC internal usdc;
    ForkHeart internal heart;
    ForkCouncilToken internal council;

    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal custody = makeAddr("custody");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_FORK_RPC", string(""));
        forked = bytes(rpc).length > 0;
        if (!forked) return;
        vm.createSelectFork(rpc);

        usdc = new ForkMockUSDC();
        heart = new ForkHeart(usdc);
        council = new ForkCouncilToken();

        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        pool = new PossessioSaltPool(
            predictedFactory, keeper, address(0x0011), address(0x0022), address(0x0033)
        );
        factory = new PossessioLaunchFactory(
            FEE,
            keccak256(type(ForkLaunchTemplate).creationCode),
            address(pool),
            address(usdc),
            address(heart),
            address(council),
            POOL_MANAGER,
            POOL_FEE,
            TICK_SPACING
        );
        require(address(factory) == predictedFactory, "factory prediction failed");
        usdc.mint(buyer, 10 * FEE);
    }

    /*//////////////////////////////////////////////////////////////
                    CREATE3 mining (pure, no RPC)
    //////////////////////////////////////////////////////////////*/

    function _guarded(address sender, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
    }

    /// CreateX CREATE3 address, computed locally: proxy via CREATE2 from
    /// CreateX, final via CREATE from proxy at nonce 1.
    function _create3Address(bytes32 guardedSalt) internal pure returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), CREATEX_ADDR, guardedSalt, PROXY_INITCODE_HASH
                        )
                    )
                )
            )
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01)))))
        );
    }

    /// Mine a factory-locked salt whose CREATE3 address carries EXACTLY
    /// BEFORE_SWAP | BEFORE_INITIALIZE (a valid v4 hook address that v4 gates on
    /// init — the L-1 fix requirement).
    function _mineHookSalt(address f) internal pure returns (bytes32 salt) {
        for (uint256 entropy = 1; entropy < 3_000_000; entropy++) {
            bytes32 candidate = bytes32(bytes20(f)) | bytes32(entropy);
            address a = _create3Address(_guarded(f, candidate));
            if ((uint160(a) & ALL_HOOK_MASK) == REQUIRED_FLAGS) return candidate;
        }
        revert("no hook salt found in budget");
    }

    /// Mine a salt whose address has ZERO flag bits - the invalid case.
    function _mineFlaglessSalt(address f) internal pure returns (bytes32 salt) {
        for (uint256 entropy = 1; entropy < 300_000; entropy++) {
            bytes32 candidate = bytes32(bytes20(f)) | bytes32(entropy);
            address a = _create3Address(_guarded(f, candidate));
            if ((uint160(a) & ALL_HOOK_MASK) == 0) return candidate;
        }
        revert("no flagless salt found in budget");
    }

    function _refill(bytes32 salt) internal {
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        pool.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioLaunchFactory.FeeAuth memory a) {
        a;
    }

    /*//////////////////////////////////////////////////////////////
                          THE FORK PROOFS
    //////////////////////////////////////////////////////////////*/

    /// §10.2 on the real chain: the pairing initializes on the LIVE v4
    /// PoolManager. This is the assertion no mock can certify.
    function test_fork_pairInitializes_onLivePoolManager() public {
        if (!forked) { vm.skip(true); }
        bytes32 salt = _mineHookSalt(address(factory));
        address predicted = _create3Address(_guarded(address(factory), salt));
        _refill(salt);

        vm.prank(buyer);
        (address launch, IPoolManagerMinimal.PoolKey memory key) = factory.deployLaunch(
            custody, abi.encode("fork"), type(ForkLaunchTemplate).creationCode, PRICE, _auth()
        );

        assertEq(launch, predicted, "predicted == deployed on fork");
        assertEq(uint160(launch) & ALL_HOOK_MASK, REQUIRED_FLAGS, "BEFORE_SWAP | BEFORE_INITIALIZE in address");
        assertTrue(
            key.currency0 == address(council) || key.currency1 == address(council),
            "live pair contains COUNCIL_TOKEN"
        );
        assertEq(key.hooks, launch, "live pair hook is the launch");
        assertEq(heart.received(), FEE, "fee credited through the accounted door");
        assertTrue(factory.isLaunchOfFactory(launch), "registry row");
        // Non-revert of initialize on the LIVE PoolManager == the address bits,
        // key shape, fee, and tickSpacing were all validated by real v4 code.
    }

    /// The constraint is real: a launch address WITHOUT the BEFORE_INITIALIZE
    /// flag is rejected — after the L-1 fix, by the factory's own guard
    /// (LaunchHookNotInitGated), before the PoolManager is even reached — with
    /// fee refunded, salt unconsumed, nothing deployed. This is WHY the salt
    /// pool must hold correctly hook-flag-mined salts.
    function test_fork_flaglessLaunchAddress_reverts_atomically() public {
        if (!forked) { vm.skip(true); }
        bytes32 salt = _mineFlaglessSalt(address(factory));
        _refill(salt);
        uint256 balBefore = usdc.balanceOf(buyer);
        uint256 depthBefore = pool.depth();

        vm.prank(buyer);
        vm.expectRevert(); // v4 HookAddressNotValid
        factory.deployLaunch(
            custody, abi.encode("fork"), type(ForkLaunchTemplate).creationCode, PRICE, _auth()
        );

        assertEq(usdc.balanceOf(buyer), balBefore, "fee refunded");
        assertEq(heart.received(), 0, "no heart credit");
        assertEq(pool.depth(), depthBefore, "salt unconsumed");
        assertEq(factory.totalLaunches(), 0, "no registry row");
    }

    /// L-1 FIX, proven on LIVE v4: an attacker who tries to pre-initialize the
    /// pool at the predicted (still-code-less) launch address is rejected by the
    /// real Base PoolManager — v4 invokes beforeInitialize on the code-less hook
    /// and reverts. The front-run is impossible on-chain, and the honest deploy
    /// then still initializes the pool.
    function test_fork_attackerPreInit_blockedByLiveV4() public {
        if (!forked) { vm.skip(true); }
        bytes32 salt = _mineHookSalt(address(factory));
        address predicted = _create3Address(_guarded(address(factory), salt));
        _refill(salt);

        assertEq(uint160(predicted) & ALL_HOOK_MASK, REQUIRED_FLAGS, "flagged");
        assertEq(predicted.code.length, 0, "launch not deployed yet");

        (address c0, address c1) = address(council) < predicted
            ? (address(council), predicted)
            : (predicted, address(council));
        IPoolManagerMinimal.PoolKey memory key = IPoolManagerMinimal.PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: predicted
        });

        // Attacker front-runs the pairing on the LIVE PoolManager -> reverts,
        // because v4 calls beforeInitialize on the code-less predicted launch.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        IPoolManagerMinimal(POOL_MANAGER).initialize(key, PRICE);

        // The honest deploy still works: the launch is deployed (implements
        // beforeInitialize) and the factory initializes the pool.
        vm.prank(buyer);
        (address launch,) = factory.deployLaunch(
            custody, abi.encode("fork"), type(ForkLaunchTemplate).creationCode, PRICE, _auth()
        );
        assertEq(launch, predicted, "honest deploy == predicted");
        assertTrue(factory.isLaunchOfFactory(launch), "registry row");
    }

    /// Two launches, two live pools, one denominator (spec §7: one
    /// denominator = one many-outcome market).
    function test_fork_secondLaunch_secondLivePair() public {
        if (!forked) { vm.skip(true); }
        bytes32 s1 = _mineHookSalt(address(factory));
        _refill(s1);
        vm.prank(buyer);
        (address l1,) = factory.deployLaunch(
            custody, abi.encode("one"), type(ForkLaunchTemplate).creationCode, PRICE, _auth()
        );

        // Second salt: continue mining past the first hit.
        bytes32 s2;
        {
            uint256 start = uint256(uint88(uint256(s1))) + 1;
            for (uint256 entropy = start; entropy < start + 3_000_000; entropy++) {
                bytes32 candidate = bytes32(bytes20(address(factory))) | bytes32(entropy);
                address a = _create3Address(_guarded(address(factory), candidate));
                if ((uint160(a) & ALL_HOOK_MASK) == REQUIRED_FLAGS) { s2 = candidate; break; }
            }
            require(s2 != bytes32(0), "no second salt in budget");
        }
        _refill(s2);
        vm.prank(buyer);
        (address l2,) = factory.deployLaunch(
            custody, abi.encode("two"), type(ForkLaunchTemplate).creationCode, PRICE, _auth()
        );

        assertTrue(l1 != l2, "distinct launches");
        assertEq(factory.totalLaunches(), 2);
        assertEq(heart.received(), 2 * FEE, "both fees accounted");
    }
}
