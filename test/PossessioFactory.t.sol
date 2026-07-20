// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
        POSSESSIO FACTORY - DoD TEST SUITE
        Maps 1:1 to SPEC_PossessioFactory.md section 6.
        Real salt pool + etched canonical CreateX (no fork); mock
        EIP-3009 USDC; template follows the ratified constructor
        convention (address owner, bytes initArgs).
//////////////////////////////////////////////////////////////*/

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// Minimal EIP-3009 USDC mock: receiveWithAuthorization moves balance
/// from -> to and enforces the front-run-closure property (only the
/// payee can submit). ERC20 transfer/balanceOf for the sink forward.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    // approve + transferFrom: needed once the factory routes the fee via the pool's
    // receiveInfraFunds pull door (option A) instead of a raw safeTransfer push.
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

/// Minimal pool standing in for the feeSink: mirrors the real receiveInfraFunds
/// pull door (transferFrom), so the factory's option-A fee route is exercised.
/// (Permissive — the authorizedSources enforcement is the real pool's DoD.)
contract MockPool {
    MockUSDC internal immutable usdc;
    uint256 public received;
    constructor(MockUSDC u) { usdc = u; }
    function isInfraSink() external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

/// Template following the ratified convention: constructor(owner, initArgs).
contract MockTemplate {
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

contract PossessioFactoryTest is Test {
    address internal constant CREATEX_ADDR = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    ICreateX internal constant CREATEX = ICreateX(CREATEX_ADDR);
    bytes32 constant PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    uint256 constant FEE = 100_000_000; // 100 USDC, 6 decimals (ratified tier price)

    PossessioFactory internal factory;
    PossessioSaltPool internal pool;
    MockUSDC internal usdc;

    address internal sink;
    address internal keeper   = makeAddr("keeper");
    address internal buyer    = makeAddr("buyer");
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC   = address(0x0033);

    bytes32 internal templateCodehash;

    function setUp() public {
        // Canonical CreateX etched at its address (same guard as the salt pool suite).
        vm.etch(CREATEX_ADDR, vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex")));
        assertEq(CREATEX_ADDR.codehash, CANONICAL_RUNTIME_CODEHASH, "etched CreateX not canonical");

        usdc = new MockUSDC();
        sink = address(new MockPool(usdc)); // feeSink is now a pull-door pool (option A)
        templateCodehash = keccak256(type(MockTemplate).creationCode);

        // Salt pool is sender-locked to the factory, whose address must be known
        // at pool construction. Predict it: the factory is the next CREATE after
        // the pool from this test contract.
        (pool, factory) = _deployPoolAndFactory(templateCodehash);
    }

    /*//////////////////////////////////////////////////////////////
                              Helpers
    //////////////////////////////////////////////////////////////*/

    function _deployPoolAndFactory(bytes32 codehash)
        internal
        returns (PossessioSaltPool p, PossessioFactory f)
    {
        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        p = new PossessioSaltPool(predictedFactory, keeper, OPERATOR, TREASURY, FEESRC);
        f = new PossessioFactory(FEE, codehash, address(p), address(usdc), sink);
        require(address(f) == predictedFactory, "factory address prediction failed");
    }

    /// Refill the pool with one sender-locked salt for `f`.
    function _refillSalt(PossessioSaltPool p, address f, uint88 entropy) internal returns (bytes32 salt) {
        salt = bytes32(bytes20(f)) | bytes32(uint256(entropy));
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        p.refillSalts(b);
    }

    function _auth() internal pure returns (PossessioFactory.FeeAuth memory a) {
        a; // all-zero; the mock ignores the signature fields
    }

    function _guarded(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }

    function _create3(bytes32 guardedSalt) internal pure returns (address) {
        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", CREATEX_ADDR, guardedSalt, PROXY_INITCODE_HASH
        )))));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    /*//////////////////////////////////////////////////////////////
        DoD #1 / #8 - ownership lands at owner; factory NEVER owner
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DoD1_ownerLands_factoryNeverOwner(address owner) public {
        vm.assume(owner != address(0) && owner != address(factory));
        _refillSalt(pool, address(factory), 1);
        usdc.mint(buyer, FEE);

        vm.prank(buyer);
        address deployed = factory.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());

        // DoD #8: on-chain owner == exactly what was requested.
        assertEq(MockTemplate(deployed).owner(), owner, "owner must land at requested owner");
        // DoD #1: the factory is never the owner.
        assertTrue(MockTemplate(deployed).owner() != address(factory), "factory must never be owner");
    }

    function test_DoD1_ownerCannotBeFactory_reverts() public {
        _refillSalt(pool, address(factory), 1);
        usdc.mint(buyer, FEE);
        vm.prank(buyer);
        vm.expectRevert(PossessioFactory.OwnerIsFactory.selector);
        factory.deployTemplate(address(factory), "", type(MockTemplate).creationCode, _auth());
    }

    /*//////////////////////////////////////////////////////////////
        DoD #2 - atomicity: every failure stage leaves the fee UNCHARGED
        (balance-diff proof, not just "it reverts")
    //////////////////////////////////////////////////////////////*/

    function test_DoD2_emptyPool_feeUncharged() public {
        usdc.mint(buyer, FEE); // no salt refilled -> pool empty
        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(PossessioSaltPool.PoolEmpty.selector);
        factory.deployTemplate(makeAddr("o"), "", type(MockTemplate).creationCode, _auth());
        assertEq(usdc.balanceOf(buyer), before, "empty pool: fee must be unwound");
        assertEq(usdc.balanceOf(sink), 0, "empty pool: sink must receive nothing");
    }

    function test_DoD2_and_DoD7_codehashMismatch_feeUncharged_saltUntouched() public {
        _refillSalt(pool, address(factory), 1);
        usdc.mint(buyer, FEE);
        uint256 before = usdc.balanceOf(buyer);
        bytes memory wrongCode = hex"60016001"; // not the pinned template

        vm.prank(buyer);
        vm.expectRevert(); // TemplateCodehashMismatch, before any state change
        factory.deployTemplate(makeAddr("o"), "", wrongCode, _auth());

        assertEq(usdc.balanceOf(buyer), before, "codehash mismatch: fee never pulled");
        assertEq(pool.depth(), 1, "codehash mismatch: salt not consumed");
    }

    function test_DoD2_templateConstructorRevert_feeAndSaltUnwound() public {
        // A second factory pinned to the reverting template.
        (PossessioSaltPool p2, PossessioFactory f2) =
            _deployPoolAndFactory(keccak256(type(RevertTemplate).creationCode));
        _refillSalt(p2, address(f2), 9);
        usdc.mint(buyer, FEE);
        uint256 before = usdc.balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(); // CreateX bubbles the failed contract creation
        f2.deployTemplate(makeAddr("o"), "", type(RevertTemplate).creationCode, _auth());

        assertEq(usdc.balanceOf(buyer), before, "template revert: fee unwound");
        assertEq(p2.depth(), 1, "template revert: salt unwound (pull rolled back)");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #4 - address determinism, three-way cross-check
    //////////////////////////////////////////////////////////////*/

    function test_DoD4_addressDeterminism_threeWay() public {
        bytes32 salt = _refillSalt(pool, address(factory), 0xABCDEF);
        usdc.mint(buyer, FEE);

        vm.prank(buyer);
        address deployed = factory.deployTemplate(makeAddr("o"), "", type(MockTemplate).creationCode, _auth());

        bytes32 gs = _guarded(address(factory), salt);
        assertEq(deployed, CREATEX.computeCreate3Address(gs), "CreateX view disagrees");
        assertEq(deployed, _create3(gs), "independent CREATE3 math disagrees");
        assertGt(deployed.code.length, 0, "no code deployed");
    }

    /*//////////////////////////////////////////////////////////////
        DoD #5 - fee accounting: single asset, single sink, exact fee
    //////////////////////////////////////////////////////////////*/

    function test_DoD5_feeAccounting_singleSink_exactFee() public {
        _refillSalt(pool, address(factory), 1);
        usdc.mint(buyer, FEE);
        uint256 sinkBefore = usdc.balanceOf(sink);

        vm.prank(buyer);
        factory.deployTemplate(makeAddr("o"), "", type(MockTemplate).creationCode, _auth());

        assertEq(usdc.balanceOf(sink), sinkBefore + FEE, "sink credited exactly the fee");
        // option A: the fee was ROUTED through receiveInfraFunds (accounted), not
        // pushed to a passive address — proves the pull door fired, not a strand.
        assertEq(MockPool(sink).received(), FEE, "fee credited via receiveInfraFunds (A)");
        assertEq(usdc.balanceOf(address(factory)), 0, "factory holds no USDC after settle");
        assertEq(usdc.balanceOf(buyer), 0, "buyer charged exactly the fee, no more");
        assertEq(factory.DEPLOYMENT_FEE(), FEE, "immutable fee is the tier price");
    }

    /*//////////////////////////////////////////////////////////////
        Event - emitted with (owner, deployed, fee)
    //////////////////////////////////////////////////////////////*/

    function test_event_templateDeployed() public {
        bytes32 salt = _refillSalt(pool, address(factory), 5);
        usdc.mint(buyer, FEE);
        address owner = makeAddr("owner");
        address expected = _create3(_guarded(address(factory), salt));

        vm.expectEmit(true, true, false, true);
        emit PossessioFactory.TemplateDeployed(owner, expected, FEE);
        vm.prank(buyer);
        factory.deployTemplate(owner, "", type(MockTemplate).creationCode, _auth());
    }

    /*//////////////////////////////////////////////////////////////
        DoD #3 - empty-pool honesty inherited (PoolEmpty propagates)
    //////////////////////////////////////////////////////////////*/

    function test_DoD3_emptyPool_propagatesPoolEmpty() public {
        usdc.mint(buyer, FEE);
        vm.prank(buyer);
        vm.expectRevert(PossessioSaltPool.PoolEmpty.selector);
        factory.deployTemplate(makeAddr("o"), "", type(MockTemplate).creationCode, _auth());
    }
}

/*//////////////////////////////////////////////////////////////
  DoD #6 complementary CI check (price immutability; run in repo):

    grep -nE "DEPLOYMENT_FEE" src/PossessioFactory.sol

  EXPECTED: DEPLOYMENT_FEE is `immutable`, assigned ONCE in the
  constructor, and read-only everywhere else. No setter, no function
  that writes it post-construction.
//////////////////////////////////////////////////////////////*/
