// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";

/*//////////////////////////////////////////////////////////////
        POSSESSIO SALT POOL - CREATE3 INTEGRATION (OFFLINE)

  Proves the real end-to-end flow WITHOUT a fork / RPC:
    keeper refills a sender-locked salt -> factory pulls it ->
    factory calls the REAL CreateX.deployCreate3 with that salt ->
    the contract lands at the deterministic CREATE3 address.

  CreateX is NEVER compiled here - it pins itself to solc =0.8.23,
  which cannot coexist with this repo's ^0.8.26 in one build graph.
  You never deploy CreateX anyway; you call the canonical deployment.
  So we talk to it through a minimal local interface and, for offline
  runs, vm.etch its runtime bytecode at the canonical address (see
  test/fixtures/README.md). A CREATE3 address depends only on
  (factory address, guarded salt, proxy init-code hash), never on
  CreateX's bytecode, so this matches mainnet. Cross-checked 3 ways.
//////////////////////////////////////////////////////////////*/

/// Minimal interface - only what this test calls. Declared at ^0.8.26 so the
/// CreateX source (pinned =0.8.23) never enters the build graph.
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// Trivial payload the factory deploys through the pulled salt.
contract Deployed {
    uint256 public constant MAGIC = 42;
}

contract PossessioSaltPoolCreate3Test is Test {
    // Canonical CreateX address (identical on every chain it is deployed to).
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // CreateX's CREATE3 proxy init-code hash - a public constant baked into
    // CreateX itself. Used for the independent address computation below.
    bytes32 constant PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    // Canonical CreateX deployed-runtime codehash, published by CreateX itself
    // (README: "keccak256 hash ... of the deployed runtime bytecode is ...").
    // The etch fixture is pinned to this: if the hex is corrupted, swapped, or
    // a wrong compiler build, setUp reverts instead of etching bytecode that is
    // not CreateX - closing the "false green against non-CreateX bytes" gap.
    bytes32 constant CANONICAL_RUNTIME_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    PossessioSaltPool internal pool;

    address internal factory;
    address internal constant KEEPER   = address(0xBEEF);
    address internal constant OPERATOR = address(0x0011);
    address internal constant TREASURY = address(0x0022);
    address internal constant FEESRC   = address(0x0033);

    function setUp() public {
        // Etch the real CreateX runtime at its canonical address - no fork.
        bytes memory code = vm.parseBytes(vm.readFile("test/fixtures/createx.runtime.hex"));
        vm.etch(address(CREATEX), code);

        // NOTARIZE the fixture: the etched code MUST be canonical CreateX. If it
        // is not, fail loudly here rather than passing every test below against
        // bytecode that only pretends to be CreateX.
        assertEq(
            address(CREATEX).codehash,
            CANONICAL_RUNTIME_CODEHASH,
            "etched fixture is NOT canonical CreateX (corrupted/wrong-version hex)"
        );

        factory = makeAddr("factory");
        pool = new PossessioSaltPool(factory, KEEPER, OPERATOR, TREASURY, FEESRC);
    }

    /// Build a CreateX sender-locked salt: [deployer(20)][0x00(1)][entropy(11)].
    function _senderLockedSalt(address deployer, uint88 entropy) internal pure returns (bytes32) {
        return bytes32(bytes20(deployer)) | bytes32(uint256(entropy));
    }

    /// CreateX sender-lock guard transform (mirrors MineCreate3Salt.s.sol,
    /// itself verified against CreateX source).
    function _guarded(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }

    /// Independent CREATE3 address computation from first principles.
    function _create3(bytes32 guardedSalt) internal pure returns (address) {
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(
                hex"ff", address(CREATEX), guardedSalt, PROXY_INITCODE_HASH
            ))))
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01"))))
        );
    }

    /*//////////////////////////////////////////////////////////////
        The full flow: pool dispenses the salt, factory deploys with
        it, contract lands at the deterministic CREATE3 address.
    //////////////////////////////////////////////////////////////*/

    function test_poolSalt_deploysAtDeterministicCreate3Address() public {
        bytes32 salt = _senderLockedSalt(factory, 0xABCDEF);

        // keeper stocks the pool
        bytes32[] memory batch = new bytes32[](1);
        batch[0] = salt;
        vm.prank(KEEPER);
        pool.refillSalts(batch);

        vm.startPrank(factory);
        bytes32 pulled = pool.pullSalt();          // factory pulls from the pool
        assertEq(pulled, salt, "pool returned the stocked salt");

        address deployed = CREATEX.deployCreate3(pulled, type(Deployed).creationCode);
        vm.stopPrank();

        // 1. real deployment actually produced code
        assertGt(deployed.code.length, 0, "no code at deployed address");
        assertEq(Deployed(deployed).MAGIC(), 42, "wrong payload deployed");

        // 2. matches CreateX's own view over the guarded salt
        bytes32 gs = _guarded(factory, salt);
        assertEq(deployed, CREATEX.computeCreate3Address(gs), "CreateX view disagrees");

        // 3. matches an independent from-scratch CREATE3 computation
        assertEq(deployed, _create3(gs), "independent CREATE3 math disagrees");
    }

    /*//////////////////////////////////////////////////////////////
        Sender-lock: the landing address is bound to the factory. A
        different deployer's guard yields a different address, so a
        pulled salt cannot be redirected to someone else's address.
    //////////////////////////////////////////////////////////////*/

    function test_senderLock_bindsAddressToFactory() public {
        bytes32 salt = _senderLockedSalt(factory, 0x1234);
        address other = makeAddr("other");

        address boundToFactory = _create3(_guarded(factory, salt));
        address boundToOther   = _create3(_guarded(other,   salt));

        assertTrue(boundToFactory != boundToOther, "same salt must not share an address across deployers");
    }

    /*//////////////////////////////////////////////////////////////
        No-double-deploy: a second deploy to the same CREATE3 address
        reverts (the proxy slot is consumed). The pool's job is to
        never hand the same salt out twice (LIFO pop); this shows why
        that matters - the second attempt cannot succeed.
    //////////////////////////////////////////////////////////////*/

    function test_secondDeploy_sameSalt_reverts() public {
        bytes32 salt = _senderLockedSalt(factory, 0x777);
        bytes32[] memory batch = new bytes32[](2);
        batch[0] = salt;
        batch[1] = salt; // deliberately duplicated to force the collision
        vm.prank(KEEPER);
        pool.refillSalts(batch);

        vm.startPrank(factory);
        pool.pullSalt();
        CREATEX.deployCreate3(salt, type(Deployed).creationCode); // first: ok
        pool.pullSalt();
        vm.expectRevert(); // second CREATE3 to the same address must fail
        CREATEX.deployCreate3(salt, type(Deployed).creationCode);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        Fork-gated notarization: confirm the pinned codehash matches
        LIVE CreateX on Base. Runs only when BASE_RPC_URL is set; it
        verifies the pinned constant against mainnet and is NOT
        load-bearing for the offline suite's green.
    //////////////////////////////////////////////////////////////*/

    function test_fork_pinnedCodehashMatchesLiveCreateX() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(
            address(CREATEX).codehash,
            CANONICAL_RUNTIME_CODEHASH,
            "pinned codehash does not match live CreateX on Base"
        );
    }
}
