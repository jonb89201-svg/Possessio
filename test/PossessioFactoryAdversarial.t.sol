// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
        POSSESSIO FACTORY - ADVERSARIAL SUITE (cold-seat)
        Weighted on Invariant 1 (factory never owner) and
        Invariant 2 (fee/deploy atomicity). Every test here is an
        ATTACK that must fail; the assertions prove it fails safely.
//////////////////////////////////////////////////////////////*/

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256, uint256, bytes32, uint8, bytes32, bytes32
    ) external {
        require(msg.sender == to, "3009: only payee may submit");
        balanceOf[from] -= value; balanceOf[to] += value;
    }
}

/// Honest template - decodes owner from constructor word 0.
contract HonestTemplate {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) {
        owner = _owner; initData = _initArgs;
    }
}

/// A template whose constructor RE-ENTERS the factory with a FULLY VALID
/// call: genuine initCode (its own creation code, passes the codehash
/// check), a funded fee (mints itself DEPLOYMENT_FEE - the mock's mint is
/// unpermissioned, test-only), a salt waiting in the pool, and a valid
/// owner. Every non-guard check passes, so nonReentrant is the ONLY thing
/// standing between the re-entry and success. The constructor records the
/// exact revert selector so the test can prove WHICH mechanism fired -
/// not merely that something reverted. If nonReentrant is ever removed,
/// the re-entry SUCCEEDS, `reentrySucceeded` reads true, and the test
/// fails loudly. This is a tripwire for the guard, not a fail-safe check.
contract ReentrantTemplate {
    address public owner;
    bool public reentrySucceeded;
    bytes4 public reentryErrorSelector;

    constructor(address _owner, bytes memory initArgs) {
        owner = _owner;
        (address f, address usdcAddr, bytes memory selfInitCode) =
            abi.decode(initArgs, (address, address, bytes));

        // Fund the fee: msg.sender of the re-entry is THIS address, and the
        // factory settles from msg.sender, so the template funds itself.
        MockUSDC(usdcAddr).mint(address(this), PossessioFactory(f).DEPLOYMENT_FEE());

        PossessioFactory.FeeAuth memory a;
        try PossessioFactory(f).deployTemplate(_owner, "", selfInitCode, a) returns (address) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryErrorSelector = bytes4(err);
        }
    }
}

contract PossessioFactoryAdversarialTest is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    uint256 constant FEE = 100_000_000; // 100 USDC

    MockUSDC internal usdc;
    address internal sink;
    address internal keeper   = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC   = address(0x0033);

    function setUp() public {
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");
        usdc = new MockUSDC();
        sink = makeAddr("sink");
    }

    // ---- harness --------------------------------------------------------

    function _deploy(bytes32 codehash) internal returns (PossessioSaltPool p, PossessioFactory f) {
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        p = new PossessioSaltPool(predicted, keeper, OPERATOR, TREASURY, FEESRC);
        f = new PossessioFactory(FEE, codehash, address(p), address(usdc), sink);
        require(address(f) == predicted, "prediction");
    }

    function _refill(PossessioSaltPool p, address f, uint88 e) internal returns (bytes32 salt) {
        salt = bytes32(bytes20(f)) | bytes32(uint256(e));
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        p.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioFactory.FeeAuth memory a) { a; }

    /*//////////////////////////////////////////////////////////////
        ATTACK 1 - owner override via crafted initArgs. The attacker
        packs their own address into initArgs, hoping to steer the
        template's owner. abi.encode(owner, initArgs) fixes owner in
        word 0, so initArgs can never move it.
    //////////////////////////////////////////////////////////////*/

    function test_attack_maliciousInitArgs_cannotOverrideOwner() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        _refill(p, address(f), 1);
        usdc.mint(attacker, FEE);

        address realOwner = makeAddr("realOwner");
        // attacker crafts initArgs that encode THEIR address, plus junk
        bytes memory evilArgs = abi.encode(attacker, uint256(0xdeadbeef), attacker);

        vm.prank(attacker);
        address deployed = f.deployTemplate(realOwner, evilArgs, type(HonestTemplate).creationCode, _auth());

        assertEq(HonestTemplate(deployed).owner(), realOwner, "owner must be the param, not from initArgs");
        assertTrue(HonestTemplate(deployed).owner() != attacker, "attacker must not become owner via initArgs");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 2 - owner smuggling via tampered initCode. The attacker
        appends their own constructor args to the template creation
        code, hoping the factory deploys THAT. The codehash check
        rejects any initCode that isn't the exact pinned template.
    //////////////////////////////////////////////////////////////*/

    function test_attack_tamperedInitCode_revertsOnCodehash() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        _refill(p, address(f), 1);
        usdc.mint(attacker, FEE);
        uint256 before = usdc.balanceOf(attacker);

        // template code with attacker's owner already baked in (extra bytes)
        bytes memory tampered = bytes.concat(type(HonestTemplate).creationCode, abi.encode(attacker, ""));

        vm.prank(attacker);
        vm.expectRevert(); // TemplateCodehashMismatch - before any fee/salt
        f.deployTemplate(makeAddr("o"), "", tampered, _auth());

        assertEq(usdc.balanceOf(attacker), before, "no fee pulled on tampered initCode");
        assertEq(p.depth(), 1, "no salt consumed on tampered initCode");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 3 - reentrancy through a template constructor. TIGHTENED
        (cold-seat finding): the re-entry is now FULLY VALID - genuine
        initCode, funded fee, a second salt waiting, valid owner - so
        every check EXCEPT nonReentrant would pass. The test asserts
        the exact ReentrancyGuardReentrantCall selector, proving the
        guard specifically fired. The prior version re-entered with
        initCode="" and could not distinguish the guard from the
        codehash check catching it; it would have kept passing even
        with nonReentrant deleted. This version fails if the guard is
        ever removed: the re-entry would then SUCCEED and the
        reentrySucceeded assertion trips.
    //////////////////////////////////////////////////////////////*/

    /// @dev OZ 5.x ReentrancyGuard custom error.
    bytes4 internal constant REENTRANCY_SELECTOR =
        bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function test_attack_reentrantTemplate_isBlocked() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(ReentrantTemplate).creationCode));
        // TWO salts: one for the outer deploy, one waiting so the re-entry's
        // pull would succeed if it ever got that far.
        _refill(p, address(f), 7);
        _refill(p, address(f), 8);
        usdc.mint(attacker, FEE);

        // initArgs carries everything the template needs for a valid re-entry:
        // the factory, the USDC (to self-fund the fee), and its own genuine
        // creation code (to pass the codehash check).
        bytes memory args = abi.encode(address(f), address(usdc), type(ReentrantTemplate).creationCode);

        vm.prank(attacker);
        address deployed = f.deployTemplate(makeAddr("o"), args, type(ReentrantTemplate).creationCode, _auth());

        // The guard - and specifically the guard - must have stopped it.
        assertFalse(ReentrantTemplate(deployed).reentrySucceeded(), "re-entry must not succeed");
        assertEq(
            ReentrantTemplate(deployed).reentryErrorSelector(),
            REENTRANCY_SELECTOR,
            "revert must be ReentrancyGuardReentrantCall, not an incidental check"
        );
        // And the second salt must still be there: the re-entry died at the
        // guard, BEFORE its fee settle or salt pull could execute.
        assertEq(p.depth(), 1, "re-entry consumed nothing: guard fired before fee/salt");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 4 - direct salt theft. The attacker calls the pool's
        pullSalt() directly, bypassing the factory. Factory-only.
    //////////////////////////////////////////////////////////////*/

    function test_attack_directSaltPull_reverts() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        _refill(p, address(f), 1);
        vm.prank(attacker);
        vm.expectRevert(PossessioSaltPool.UnauthorizedCall.selector);
        p.pullSalt();
        assertEq(p.depth(), 1, "salt still in the pool");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 5 - fee-failure atomicity. Attacker signs for a fee they
        cannot cover; the whole transaction must revert with no salt
        consumed and nothing in the sink.
    //////////////////////////////////////////////////////////////*/

    function test_attack_insufficientFee_fullRevert() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        _refill(p, address(f), 1);
        usdc.mint(attacker, FEE - 1); // one short

        vm.prank(attacker);
        vm.expectRevert(); // receiveWithAuthorization underflows -> whole tx reverts
        f.deployTemplate(makeAddr("o"), "", type(HonestTemplate).creationCode, _auth());

        assertEq(p.depth(), 1, "no salt consumed when fee fails");
        assertEq(usdc.balanceOf(sink), 0, "sink received nothing");
        assertEq(usdc.balanceOf(attacker), FEE - 1, "attacker balance untouched");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 6 - duplicate-salt fail-safe. If the keeper mistakenly
        loads the same salt twice, the SECOND deploy collides on the
        deterministic address and reverts, fee unwound. The pool's
        "never repeat a salt" is why this must never happen - and this
        proves the factory fails safe if it does.
    //////////////////////////////////////////////////////////////*/

    function test_attack_duplicateSalt_secondDeployReverts_feeUnwound() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        // keeper error: same salt twice
        bytes32 salt = bytes32(bytes20(address(f))) | bytes32(uint256(3));
        bytes32[] memory b = new bytes32[](2);
        b[0] = salt; b[1] = salt;
        vm.prank(keeper);
        p.refillSalts(b);

        usdc.mint(attacker, FEE * 2);

        // first deploy: ok
        vm.prank(attacker);
        f.deployTemplate(makeAddr("o1"), "", type(HonestTemplate).creationCode, _auth());
        uint256 afterFirst = usdc.balanceOf(attacker);

        // second deploy, same salt -> CreateX collision -> revert, fee unwound
        vm.prank(attacker);
        vm.expectRevert();
        f.deployTemplate(makeAddr("o2"), "", type(HonestTemplate).creationCode, _auth());
        assertEq(usdc.balanceOf(attacker), afterFirst, "second (colliding) deploy must not charge a fee");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 7 - owner set to zero. Rejected before any effect.
    //////////////////////////////////////////////////////////////*/

    function test_attack_ownerZero_reverts() public {
        (PossessioSaltPool p, PossessioFactory f) = _deploy(keccak256(type(HonestTemplate).creationCode));
        _refill(p, address(f), 1);
        usdc.mint(attacker, FEE);
        vm.prank(attacker);
        vm.expectRevert(PossessioFactory.ZeroAddress.selector);
        f.deployTemplate(address(0), "", type(HonestTemplate).creationCode, _auth());
        assertEq(p.depth(), 1, "no salt consumed");
    }

    /*//////////////////////////////////////////////////////////////
        ATTACK 8 (F1 hardening) - degenerate template codehash. A
        factory pinned to bytes32(0) or keccak256("") would let
        initCode == "" deploy args-as-code. The constructor forbids
        both, so no such factory can ever exist to be attacked.
    //////////////////////////////////////////////////////////////*/

    function test_attack_degenerateCodehash_factoryRejected() public {
        PossessioSaltPool p = new PossessioSaltPool(address(0xF), keeper, OPERATOR, TREASURY, FEESRC);

        vm.expectRevert(PossessioFactory.ZeroCodehash.selector);
        new PossessioFactory(FEE, bytes32(0), address(p), address(usdc), sink);

        vm.expectRevert(PossessioFactory.EmptyTemplateCodehash.selector);
        new PossessioFactory(FEE, keccak256(""), address(p), address(usdc), sink);
    }
}
