// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioX402Core} from "../src/PossessioX402Core.sol";
import {HandshakeLib} from "../src/libraries/HandshakeLib.sol";
import {MockEIP3009USDC, MockInfraSink, NotAnInfraSink} from "./X402TestnetMocks.sol";

/// @notice WO 2026-07-06: fork-prove the DoD items that need no real economics,
///         at the RATIFIED TESTNET PLACEHOLDER values (NOT production - #22 open):
///         cap=100e6, halflife=3600, absFloor=10e6, floorPerUnit=1e6, dustFloor=1e6.
///
///         DUAL MODE, same assertions:
///           - OFFLINE (default): MockEIP3009USDC (test/X402TestnetMocks.sol),
///             faithful to the FiatTokenV2 semantics the core leans on. Runs in
///             the network-blocked sandbox.
///           - FORK: set X402_FORK_RPC=<Base Sepolia RPC> and every test runs
///             against the REAL test USDC 0x036CbD53842c5426634e7929541eC2318f3dCF7e
///             (verified live 2026-07-06: symbol USDC / 6 dec / version "2" /
///             authorizationState present). Buyer funding via forge deal().
///
///         TEST MERKLE ROOT (declared, not accidental): two-leaf HandshakeLib
///         tree - leafA = hashLeaf(secret, buyer) live, leafB spare; the
///         buyer's proof is [leafB]. Single-leaf is structurally unusable
///         (register() rejects empty proofs), so two is the minimum - and the
///         spare doubles as the rotation path. Same construction as the
///         deploy script (script/DeployX402Testnet.s.sol).
///
///   RUN (offline):  forge test --match-contract X402TestnetProof -vv
///   RUN (fork):     X402_FORK_RPC=$BASE_SEPOLIA_RPC_URL \
///                     forge test --match-contract X402TestnetProof -vv \
///                     2>&1 | tee x402_testnet_fork.txt
contract X402TestnetProofTest is Test {
    // ---- ratified testnet placeholders (WO 2026-07-06) ----
    uint256 constant OPERATIONAL_CAP   = 100_000000;
    uint256 constant VELOCITY_HALFLIFE = 3600;
    uint256 constant ABSOLUTE_FLOOR    = 10_000000;
    uint256 constant FLOOR_PER_UNIT    = 1_000000;
    uint256 constant DUST_FLOOR        = 1_000000;

    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    PossessioX402Core internal core;
    address internal usdc;
    MockInfraSink internal heart; // stands in for the Heart (surplus sink)
    bool internal forkMode;

    // three DISTINCT parties (WO rule; line-345 guard needs feeSource distinct)
    address internal treasury  = makeAddr("treasury_test");
    address internal operator  = makeAddr("operator_test");
    address internal feeSource = makeAddr("feeSource_test");

    // buyer signs EIP-3009 -> needs a known private key
    uint256 internal buyerPk = 0xB0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0;
    address internal buyer;
    address internal seller = makeAddr("seller_test");

    bytes32 internal constant SECRET_A = keccak256("x402-testnet-leaf-A");
    bytes32 internal constant SECRET_B = keccak256("x402-testnet-leaf-B");
    address internal spare = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
    bytes32 internal leafB;

    bytes32 internal channelId = keccak256("x402-testnet-channel-0");
    uint256 internal saltCounter;

    /// @dev Constant warp base for the decay tests - ahead of any real chain
    ///      timestamp so fork mode also warps forward (2033-05-18).
    uint256 internal constant T1 = 2_000_000_000;

    function setUp() public {
        string memory rpc = vm.envOr("X402_FORK_RPC", string(""));
        forkMode = bytes(rpc).length > 0;
        buyer = vm.addr(buyerPk);

        if (forkMode) {
            vm.createSelectFork(rpc);
            usdc = vm.envOr("X402_USDC", USDC_BASE_SEPOLIA);
        } else {
            usdc = address(new MockEIP3009USDC());
        }

        // declared two-leaf test tree (see header)
        bytes32 leafA = HandshakeLib.hashLeaf(SECRET_A, buyer);
        leafB = HandshakeLib.hashLeaf(SECRET_B, spare);
        bytes32 root = HandshakeLib.hashNode(leafA, leafB);

        heart = new MockInfraSink(usdc);

        core = new PossessioX402Core({
            root:                 root,
            dustFloor:            DUST_FLOOR,
            _payToken:            usdc,
            _heartSink:           address(heart),
            _operatorDestination: operator,
            _deploymentFeeSource: feeSource,
            _operationalCap:      OPERATIONAL_CAP,
            _absoluteFloor:       ABSOLUTE_FLOOR,
            _floorPerUnit:        FLOOR_PER_UNIT,
            _velocityHalflife:    VELOCITY_HALFLIFE
        });

        // register the buyer (proof = [leafB])
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.prank(buyer);
        core.register(SECRET_A, proof);

        // seller claims the channel
        vm.prank(seller);
        core.setBasePrice(channelId, 1000_000000); // 1000 USDC default; tests reprice as needed

        _fund(buyer, 100_000_000000);   // 100k USDC - covers every sequence below
        _fund(feeSource, 10_000_000000);
    }

    function _fund(address who, uint256 amount) internal {
        if (forkMode) {
            // deal() locates the FiatToken proxy's balance slot via stdStorage.
            // If that ever fails on a token upgrade, pre-fund buyer (vm.addr of
            // buyerPk, logged below) + feeSource with faucet USDC and set
            // X402_SKIP_DEAL=1 to run against real balances.
            if (vm.envOr("X402_SKIP_DEAL", false)) return;
            deal(usdc, who, amount);
        } else {
            MockEIP3009USDC(usdc).mint(who, amount);
        }
    }

    function _bal(address who) internal view returns (uint256) {
        (, bytes memory d) = usdc.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return abi.decode(d, (uint256));
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, bytes memory d) = usdc.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        return abi.decode(d, (bytes32));
    }

    struct Auth {
        bytes32 salt;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @dev Build + sign one buyer authorization for the current quote.
    ///      nonce = the commitment keccak256(abi.encode(seller, channelId,
    ///      value, salt)) - exactly what settleCall recomputes.
    function _signedAuth() internal returns (Auth memory a) {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 tollBps = core.totalFeeBps(buyer, channelId);
        a.value = basePrice + (basePrice * tollBps) / 10_000;
        a.salt = bytes32(++saltCounter);
        a.nonce = keccak256(abi.encode(seller, channelId, a.value, a.salt));
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 3600;

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            _domainSeparator(),
            keccak256(abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                buyer, address(core), a.value, a.validAfter, a.validBefore, a.nonce
            ))
        ));
        (a.v, a.r, a.s) = vm.sign(buyerPk, digest);
    }

    function _settle(Auth memory a) internal {
        core.settleCall(
            buyer, seller, channelId, a.salt, a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s
        );
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #1
    //////////////////////////////////////////////////////////////*/

    /// DoD #1: settleCall settles a valid EIP-3009 auth; seller nets EXACTLY
    /// basePrice; the toll (value - basePrice) accrues to the operating pool.
    function test_DoD1_settleNetsBasePrice_tollToPool() public {
        uint256 basePrice = core.channelBasePrice(channelId);
        uint256 sellerBefore = _bal(seller);
        uint256 poolBefore = core.operationalPoolBalance();

        Auth memory a = _signedAuth();
        uint256 toll = a.value - basePrice;
        assertEq(core.totalFeeBps(buyer, channelId), 200, "honest path = BASE_FEE_BPS");
        _settle(a);

        assertEq(_bal(seller) - sellerBefore, basePrice, "seller nets exactly basePrice");
        assertEq(core.operationalPoolBalance() - poolBefore, toll, "toll accrues to pool");
        assertEq(_bal(address(core)), core.operationalPoolBalance(), "contract holds exactly the pool");
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #9
    //////////////////////////////////////////////////////////////*/

    /// DoD #9: the same signed authorization cannot settle twice - the token's
    /// nonce burn rejects the replay (mock and real USDC use the same revert
    /// semantics: "authorization is used or canceled").
    function test_DoD9_replayReverts() public {
        Auth memory a = _signedAuth();
        _settle(a);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _settle(a);
    }

    /*//////////////////////////////////////////////////////////////
                              DoD #13 / #14
    //////////////////////////////////////////////////////////////*/

    /// DoD #13: toll accrues to operationalPoolBalance up to OPERATIONAL_CAP
    /// EXACTLY; the balance never exceeds the cap. At the ratified placeholder
    /// numbers this is visible in five settles: basePrice 1000 USDC x 2% toll
    /// = 20 USDC/settle; 5 settles fill the 100 USDC cap exactly.
    function test_DoD13_poolFillsToCapExactly() public {
        for (uint256 i = 0; i < 5; i++) {
            _settle(_signedAuth());
            assertLe(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool never exceeds cap");
        }
        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "5 x 20 USDC toll = cap, exactly");
        assertEq(heart.received(), 0, "nothing routed to the Heart before the cap");
    }

    /// DoD #14: a settlement pushing the pool over the cap routes the EXACT
    /// overflow INTO THE HEART (receiveInfraFunds), atomically, in the same tx -
    /// never more, never less. (The 6th settle at the placeholder numbers.)
    function test_DoD14_exactSurplusRoutesToHeart() public {
        for (uint256 i = 0; i < 5; i++) _settle(_signedAuth());
        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP);

        uint256 basePrice = core.channelBasePrice(channelId);
        Auth memory a = _signedAuth();
        uint256 toll = a.value - basePrice; // pool is AT cap -> entire toll is surplus

        vm.expectEmit(false, false, false, true, address(core));
        emit PossessioX402Core.HeartSurplusRouted(toll);
        _settle(a);

        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool pinned at cap");
        assertEq(heart.received(), toll, "Heart got the exact overflow");
    }

    /// DoD #14 (fuzz leg): for ANY basePrice in a sane band, once the pool is
    /// at cap the Heart receives exactly the toll of every further settle.
    function testFuzz_DoD14_surplusIsExact(uint96 rawBase) public {
        uint256 basePrice = bound(uint256(rawBase), 10_000000, 5_000_000000); // 10..5000 USDC
        vm.prank(seller);
        core.setBasePrice(channelId, basePrice);

        // fill to cap with however many settles it takes (toll = 2% each)
        while (core.operationalPoolBalance() < OPERATIONAL_CAP) {
            _settle(_signedAuth());
        }
        uint256 heartBefore = heart.received();

        Auth memory a = _signedAuth();
        uint256 toll = a.value - basePrice;
        _settle(a);

        assertEq(core.operationalPoolBalance(), OPERATIONAL_CAP, "pool never exceeds cap");
        assertEq(heart.received() - heartBefore, toll, "exact overflow, never more or less");
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #17
    //////////////////////////////////////////////////////////////*/

    /// DoD #17: settleOperationalCosts releases AT MOST (pool - floor); a
    /// request one wei above reverts ExceedsDrawableSurplus; the pool can
    /// never be drawn below the floor. With zero velocity the floor IS the
    /// 10 USDC ABSOLUTE_FLOOR - the placeholder makes the wall visible.
    function test_DoD17_flooredDrawRefusesOverWithdraw() public {
        // fund the pool via the bound inflow only - no settles, so velocity
        // stays 0 and the floor sits exactly at ABSOLUTE_FLOOR.
        vm.startPrank(feeSource);
        (bool ok,) = usdc.call(abi.encodeWithSignature("approve(address,uint256)", address(core), 50_000000));
        require(ok, "approve failed");
        core.receiveDeploymentFee(50_000000);
        vm.stopPrank();

        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR, "zero velocity -> floor = absolute floor");
        uint256 drawable = core.drawableSurplus();
        assertEq(drawable, 40_000000, "50 in - 10 floor = 40 drawable");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(
            PossessioX402Core.ExceedsDrawableSurplus.selector, drawable + 1, drawable
        ));
        core.settleOperationalCosts(drawable + 1);

        vm.prank(operator);
        core.settleOperationalCosts(drawable);
        assertEq(_bal(operator), drawable, "operator received exactly the surplus");
        assertEq(core.operationalPoolBalance(), ABSOLUTE_FLOOR, "pool rests ON the floor");

        vm.prank(operator);
        vm.expectRevert(PossessioX402Core.InsufficientOperationalFunds.selector);
        core.settleOperationalCosts(1); // the floor is a wall, not a suggestion
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #18
    //////////////////////////////////////////////////////////////*/

    /// DoD #18: the floor derives ONLY from decayed settlement velocity +
    /// immutable params. No operator call sequence lowers it: draws move the
    /// POOL, never the FLOOR, and there is no setter to reach for.
    function test_DoD18_operatorCannotLowerFloor() public {
        // 8 settles at one timestamp -> velocity 8 -> floor = 10 + 8*1 = 18 USDC
        for (uint256 i = 0; i < 8; i++) _settle(_signedAuth());
        uint256 floorBefore = core.getRunningMinimumFloor();
        assertEq(floorBefore, ABSOLUTE_FLOOR + 8 * FLOOR_PER_UNIT, "traffic up -> floor up, 1 USDC per unit");

        // operator exhausts every move it has, repeatedly
        for (uint256 i = 0; i < 3; i++) {
            uint256 drawable = core.drawableSurplus();
            if (drawable > 0) {
                vm.prank(operator);
                core.settleOperationalCosts(drawable);
            }
            assertEq(core.getRunningMinimumFloor(), floorBefore, "no operator sequence moves the floor");
        }
        assertGe(core.operationalPoolBalance(), 0);
        assertEq(core.getRunningMinimumFloor(), floorBefore, "floor unchanged at same timestamp");
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #19
    //////////////////////////////////////////////////////////////*/

    /// DoD #19: decay halves velocity once per VELOCITY_HALFLIFE. warp 3600,
    /// watch the floor halve its velocity term; past ~128 half-lives it is 0.
    /// (Full-window warps -> exact integer halving; the partial-window
    /// interpolation direction is DoD #26's oracle test, not re-proven here.)
    function test_DoD19_decayHalvesPerHalflife() public {
        // NOTE: warp targets are CONSTANTS off T1 (same pattern as
        // PossessioX402CoreDecay.t.sol's T0). Under via-ir the optimizer may
        // sink a `block.timestamp` local to its use sites and re-read it
        // across vm.warp, so timestamp-derived warp targets are unreliable.
        vm.warp(T1);
        for (uint256 i = 0; i < 8; i++) _settle(_signedAuth());
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR + 8 * FLOOR_PER_UNIT); // 18 USDC

        vm.warp(T1 + VELOCITY_HALFLIFE); // +1 halflife: 8 -> 4
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR + 4 * FLOOR_PER_UNIT, "one halflife halves");

        vm.warp(T1 + 2 * VELOCITY_HALFLIFE); // +2: 8 -> 2
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR + 2 * FLOOR_PER_UNIT, "two halflives quarter");

        vm.warp(T1 + 128 * VELOCITY_HALFLIFE); // >= 128 halvings -> 0
        assertEq(core.getRunningMinimumFloor(), ABSOLUTE_FLOOR, "fully decayed -> absolute floor only");
    }

    /// DoD #19 (fuzz leg): decayed velocity never exceeds its pre-decay value
    /// and is monotonically non-increasing with elapsed time.
    function testFuzz_DoD19_decayMonotone(uint32 dt1, uint32 dt2) public {
        vm.warp(T1); // constant warp base - see DoD19 note
        for (uint256 i = 0; i < 8; i++) _settle(_signedAuth());
        uint256 f0 = core.getRunningMinimumFloor();

        uint256 a = bound(uint256(dt1), 0, 200 * VELOCITY_HALFLIFE);
        uint256 b = bound(uint256(dt2), a, 201 * VELOCITY_HALFLIFE);

        vm.warp(T1 + a);
        uint256 fa = core.getRunningMinimumFloor();
        vm.warp(T1 + b);
        uint256 fb = core.getRunningMinimumFloor();

        assertLe(fa, f0, "decay never raises the floor");
        assertLe(fb, fa, "monotone non-increasing over time");
        assertGe(fb, ABSOLUTE_FLOOR, "never below the absolute floor");
    }

    /*//////////////////////////////////////////////////////////////
                                DoD #23
    //////////////////////////////////////////////////////////////*/

    /// DoD #23: constructor reverts ValveIntegrityViolation when the inbound
    /// fee path collides with EITHER outbound destination; zero addresses
    /// revert ZeroAddress; treasury==operator stays an ALLOWED shape (the
    /// header's intentional omission - both are outbound).
    function test_DoD23_valveIntegrityStructural() public {
        bytes32 root = keccak256("any");
        address H = address(heart); // a live infra-sink so the valve/zero checks are reached

        // feeSource == operator -> valve violation
        vm.expectRevert(PossessioX402Core.ValveIntegrityViolation.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, H, operator, operator,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);

        // feeSource == heartSink -> valve violation (inbound == outbound Heart)
        vm.expectRevert(PossessioX402Core.ValveIntegrityViolation.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, H, operator, H,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);

        vm.expectRevert(PossessioX402Core.ZeroAddress.selector);
        new PossessioX402Core(root, DUST_FLOOR, address(0), H, operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);
        vm.expectRevert(PossessioX402Core.ZeroAddress.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, address(0), operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);
        vm.expectRevert(PossessioX402Core.ZeroAddress.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, H, address(0), feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);
        vm.expectRevert(PossessioX402Core.ZeroAddress.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, H, operator, address(0),
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);

        // intentional-omission shape: both outbound to one address - ALLOWED
        // (heartSink == operator; the Heart is still a valid infra-sink).
        PossessioX402Core merged = new PossessioX402Core(root, DUST_FLOOR, usdc,
            H, H, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);
        assertEq(merged.heartSink(), merged.operatorDestination(), "heartSink==operator is by design");
    }

    /// DoD #24 (council 2026-07-20): constructor reverts FeeSinkInterfaceMismatch
    /// when heartSink is not a live infra-sink — an EOA (no code) or a real
    /// contract missing the isInfraSink() marker. Mirrors the factory brick-guard;
    /// makes the critical surplus-into-Heart push un-brickable by construction.
    function test_DoD24_heartBrickGuard() public {
        bytes32 root = keccak256("any");

        // EOA heartSink -> no code -> pre-check reverts.
        vm.expectRevert(PossessioX402Core.FeeSinkInterfaceMismatch.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, makeAddr("eoa"), operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);

        // real contract, no isInfraSink() marker -> try/catch reverts.
        address wrong = address(new NotAnInfraSink());
        vm.expectRevert(PossessioX402Core.FeeSinkInterfaceMismatch.selector);
        new PossessioX402Core(root, DUST_FLOOR, usdc, wrong, operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);

        // the live infra-sink constructs cleanly (positive control).
        new PossessioX402Core(root, DUST_FLOOR, usdc, address(heart), operator, feeSource,
            OPERATIONAL_CAP, ABSOLUTE_FLOOR, FLOOR_PER_UNIT, VELOCITY_HALFLIFE);
    }
}
