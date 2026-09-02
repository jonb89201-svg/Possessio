// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

import {PossessioLaunchTemplate} from "../src/PossessioLaunchTemplate.sol";

/// @dev Minimal ERC20 mock standing in for the council token.
contract MockCouncilToken {
    string public name = "COUNCIL"; string public symbol = "COUNCIL"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @dev Etched onto PossessioLaunchTemplate.FACTORY so beforeInitialize's live
///      reads (COUNCIL_TOKEN, poolManager) resolve exactly like the real
///      PossessioLaunchFactory would - immutables baked into runtime code
///      survive vm.etch, so the constant address becomes a real, working
///      "factory" for every purpose this template ever calls on it.
contract MockLaunchFactory {
    address public immutable COUNCIL_TOKEN;
    address public immutable poolManager;
    constructor(address council_, address pm_) { COUNCIL_TOKEN = council_; poolManager = pm_; }
}

/// @dev Attempts to add liquidity directly (bypassing the template's owner
///      gate) to prove the POL gate (beforeAddLiquidity) rejects it.
contract ExternalLPAttacker {
    function attempt(IPoolManager pm, PoolKey memory key) external {
        pm.unlock(abi.encode(key));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        IPoolManager(msg.sender).modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e6, salt: bytes32(0)}),
            ""
        );
        return "";
    }
}

contract PossessioLaunchTemplateTest is Test {
    address public constant FACTORY = 0x00000000000000000000000000000000facaDE01;
    // Exact match required over the full 14-bit hook-flag window: PoolManager's
    // isValidHookAddress additionally rejects a delta-return flag (e.g. bit 2,
    // AFTER_SWAP_RETURNS_DELTA) set without its paired action flag, so matching
    // only our 5 desired bits and leaving the rest to chance is not enough.
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant HOOK_FLAG_MASK =
        uint160(1 << 13) | uint160(1 << 11) | uint160(1 << 7) | uint160(1 << 6) | uint160(1 << 3);

    PoolManager manager;
    PoolSwapTest swapRouter;
    MockCouncilToken council;
    PossessioLaunchTemplate template;
    PoolKey key;
    bool councilIsCurrency0;

    /// v4-core wraps every reverting hook call in CustomRevert.WrappedError
    /// (target, the calling function's selector, the raw inner revert data,
    /// Hooks.HookCallFailed.selector) - match that shape rather than the raw
    /// custom error to assert on the actual inner reason.
    function _wrapped(bytes4 calledSelector, bytes memory innerReason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(template), calledSelector, innerReason, abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    address owner = makeAddr("owner");
    address trader = makeAddr("trader");
    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        council = new MockCouncilToken();

        MockLaunchFactory mockFactory = new MockLaunchFactory(address(council), address(manager));
        vm.etch(FACTORY, address(mockFactory).code);
        // Immutables are inlined as literal values in runtime code, so etching
        // preserves them - confirm rather than assume.
        assertEq(MockLaunchFactory(FACTORY).COUNCIL_TOKEN(), address(council));
        assertEq(MockLaunchFactory(FACTORY).poolManager(), address(manager));

        // Mine a nonce for this test contract's own CREATE deploys such that
        // the NEXT deploy lands at an address carrying the exact v4 hook
        // permission bits this template requires (beforeInitialize |
        // beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta).
        bytes memory initArgs = abi.encode("Launch Coin", "LAUNCH", INITIAL_SUPPLY);
        address predicted;
        uint64 n = vm.getNonce(address(this));
        while (true) {
            predicted = vm.computeCreateAddress(address(this), n);
            if (uint160(predicted) & ALL_HOOK_MASK == HOOK_FLAG_MASK) break;
            unchecked { ++n; }
        }
        vm.setNonce(address(this), n); // skip straight to the mined nonce, no deploys spent finding it
        template = new PossessioLaunchTemplate(owner, initArgs);
        require(address(template) == predicted, "hook address prediction failed");
        assertEq(uint160(address(template)) & ALL_HOOK_MASK, HOOK_FLAG_MASK);

        (address c0, address c1) = address(council) < address(template)
            ? (address(council), address(template))
            : (address(template), address(council));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(template))
        });
        councilIsCurrency0 = (c0 == address(council));
    }

    function _seedLiquidity(uint256 amountCouncil, uint256 amountLaunch) internal {
        council.mint(owner, amountCouncil);
        vm.startPrank(owner);
        council.approve(address(template), amountCouncil);
        template.approve(address(template), amountLaunch);
        template.addLiquidity(amountCouncil, amountLaunch);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    F-H5 CLOSE: beforeInitialize gating
    //////////////////////////////////////////////////////////////*/

    function test_beforeInitialize_wrongSender_reverts() public {
        vm.expectRevert(_wrapped(
            template.beforeInitialize.selector,
            abi.encodeWithSelector(PossessioLaunchTemplate.NotFactory.selector, address(this))
        ));
        manager.initialize(key, 79228162514264337593543950336); // SQRT_PRICE_1_1
    }

    /// The concrete F-H5 attack: a third party (NOT the factory) tries to open
    /// a DIFFERENT pool hooked to this same launch, paired against something
    /// other than the council token (here, itself as a stand-in for "WETH").
    function test_beforeInitialize_wrongPair_reverts() public {
        MockCouncilToken notCouncil = new MockCouncilToken();
        (address c0, address c1) = address(notCouncil) < address(template)
            ? (address(notCouncil), address(template))
            : (address(template), address(notCouncil));
        PoolKey memory rogueKey = PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(template))
        });
        vm.prank(FACTORY);
        vm.expectRevert(_wrapped(
            template.beforeInitialize.selector,
            abi.encodeWithSelector(
                PossessioLaunchTemplate.WrongPair.selector, Currency.unwrap(rogueKey.currency0), Currency.unwrap(rogueKey.currency1)
            )
        ));
        manager.initialize(rogueKey, 79228162514264337593543950336);
    }

    function test_beforeInitialize_rightSenderRightPair_succeeds() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        assertTrue(template.poolInitialized());
        assertEq(template.council(), address(council));
    }

    function test_beforeInitialize_cannotFireTwice() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        vm.prank(FACTORY);
        // A distinct fee tier is still a distinct, uninitialized key in v4 -
        // the guard must still refuse it; only PoolManager's own "already
        // initialized" check would stop a literal key repeat.
        PoolKey memory secondTierKey = PoolKey({
            currency0: key.currency0, currency1: key.currency1,
            fee: 500, tickSpacing: 10, hooks: key.hooks
        });
        vm.expectRevert(_wrapped(template.beforeInitialize.selector, abi.encodeWithSelector(PossessioLaunchTemplate.AlreadyInitialized.selector)));
        manager.initialize(secondTierKey, 79228162514264337593543950336);
    }

    /*//////////////////////////////////////////////////////////////
                    POL GATE (spec §5.2)
    //////////////////////////////////////////////////////////////*/

    function test_externalLiquidityAttempt_reverts() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        ExternalLPAttacker attacker = new ExternalLPAttacker();
        vm.expectRevert(_wrapped(
            template.beforeAddLiquidity.selector,
            abi.encodeWithSelector(PossessioLaunchTemplate.ExternalLiquidityDenied.selector)
        ));
        attacker.attempt(IPoolManager(address(manager)), key);
    }

    function test_ownerAddLiquidity_succeeds() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        _seedLiquidity(1_000e18, 1_000e18);
        assertEq(council.balanceOf(address(manager)), 1_000e18);
    }

    function test_ownerRemoveLiquidity_proceedsToRecipient() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        _seedLiquidity(100_000e18, 100_000e18);

        uint256 councilBefore = council.balanceOf(owner);
        uint256 launchBefore = template.balanceOf(owner);

        vm.prank(owner);
        template.removeLiquidity(1_000e18, owner);

        assertGt(council.balanceOf(owner), councilBefore, "owner must receive council proceeds");
        assertGt(template.balanceOf(owner), launchBefore, "owner must receive launch-token proceeds");
    }

    function test_nonOwnerCannotAddOrRemoveLiquidity() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        vm.expectRevert(PossessioLaunchTemplate.NotOwner.selector);
        vm.prank(trader);
        template.addLiquidity(1, 1);
        vm.expectRevert(PossessioLaunchTemplate.NotOwner.selector);
        vm.prank(trader);
        template.removeLiquidity(1, trader);
    }

    /*//////////////////////////////////////////////////////////////
        FEE CAPTURE - direction + magnitude, proven against a REAL
        local PoolManager + REAL swap (not asserted algebraically).
    //////////////////////////////////////////////////////////////*/

    /// Council token specified directly: no price conversion, fee is exactly
    /// 2% of the specified amount.
    function test_feeCapture_councilSpecifiedDirectly() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336); // price = 1
        _seedLiquidity(1_000_000e18, 1_000_000e18);

        uint256 swapAmount = 1_000e18;
        council.mint(trader, swapAmount);
        vm.prank(trader);
        council.approve(address(swapRouter), swapAmount);

        bool zeroForOne = councilIsCurrency0; // spend council: zeroForOne iff council is currency0
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 expectedFee = (swapAmount * 200) / 10_000;
        assertEq(template.accumulatedCouncilFees(), expectedFee, "direct fee must be exactly 2% of the council amount");
    }

    /// Launch token specified: requires the price conversion. Empirically
    /// proves the multiply-vs-divide direction at a non-1:1 price (SQRT_PRICE
    /// s.t. price = currency1/currency0 = 0.5, verified numerically), rather
    /// than trusting the algebra alone.
    function test_feeCapture_launchSpecified_priceConversionDirection() public {
        uint160 sqrtPriceX96 = 56022770974786139918731938227; // price(currency1/currency0) ~= 0.5
        vm.prank(FACTORY);
        manager.initialize(key, sqrtPriceX96);
        // Small relative to owner's INITIAL_SUPPLY: at a non-1:1 price one side
        // of this seed is fully consumed (getLiquidityForAmounts bounds by the
        // more constraining side) - leave plenty of launch-token balance for
        // the trader transfer below regardless of which side that is.
        _seedLiquidity(100_000e18, 100_000e18);

        uint256 swapAmount = 1_000e18;
        vm.prank(owner);
        template.transfer(trader, swapAmount);
        vm.prank(trader);
        template.approve(address(swapRouter), swapAmount);

        bool zeroForOne = !councilIsCurrency0; // spend launch: zeroForOne iff launch is currency0
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // price(currency1/currency0) ~= 0.5, verified in Python against this
        // exact sqrtPriceX96 (see PossessioLaunchTemplate.sol's beforeSwap
        // comment for the derivation):
        //   councilIsCurrency0 == true  (launch=currency1) -> councilEquiv = launchAmt / price = launchAmt * 2
        //   councilIsCurrency0 == false (launch=currency0) -> councilEquiv = launchAmt * price = launchAmt * 0.5
        uint256 expectedCouncilEquiv = councilIsCurrency0 ? swapAmount * 2 : swapAmount / 2;
        uint256 expectedFee = (expectedCouncilEquiv * 200) / 10_000;
        assertApproxEqRel(template.accumulatedCouncilFees(), expectedFee, 0.001e18,
            "converted fee must match the price-derived council-equivalent within rounding");
    }

    /*//////////////////////////////////////////////////////////////
                    OWNER SURFACE
    //////////////////////////////////////////////////////////////*/

    function test_claimFees_onlyOwner_andZeroesAccumulator() public {
        vm.prank(FACTORY);
        manager.initialize(key, 79228162514264337593543950336);
        _seedLiquidity(1_000_000e18, 1_000_000e18);

        uint256 swapAmount = 1_000e18;
        council.mint(trader, swapAmount);
        vm.prank(trader);
        council.approve(address(swapRouter), swapAmount);
        bool zeroForOne = councilIsCurrency0;
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.expectRevert(PossessioLaunchTemplate.NotOwner.selector);
        vm.prank(trader);
        template.claimFees();

        uint256 before = council.balanceOf(owner);
        uint256 accumulated = template.accumulatedCouncilFees();
        vm.prank(owner);
        template.claimFees();
        assertEq(council.balanceOf(owner) - before, accumulated);
        assertEq(template.accumulatedCouncilFees(), 0);

        vm.expectRevert(PossessioLaunchTemplate.NothingToClaim.selector);
        vm.prank(owner);
        template.claimFees();
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(trader);
        vm.expectRevert(PossessioLaunchTemplate.NotOwner.selector);
        template.transferOwnership(newOwner);

        vm.prank(owner);
        template.transferOwnership(newOwner);
        assertEq(template.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(PossessioLaunchTemplate.NotOwner.selector);
        template.claimFees();
    }

    /*//////////////////////////////////////////////////////////////
                    HOOK FLAG DISCIPLINE
    //////////////////////////////////////////////////////////////*/

    function test_getHookPermissions_matchesMinedFlagClass() public view {
        (
            bool beforeInit, bool afterInit,
            bool beforeAddLiq, bool afterAddLiq,
            bool beforeRemoveLiq, bool afterRemoveLiq,
            bool beforeSwap_, bool afterSwap_,
            bool beforeDonate, bool afterDonate,
            bool beforeSwapDelta, bool afterSwapDelta,
            bool afterAddLiqDelta, bool afterRemoveLiqDelta
        ) = template.getHookPermissions();
        assertTrue(beforeInit); assertFalse(afterInit);
        assertTrue(beforeAddLiq); assertFalse(afterAddLiq);
        assertFalse(beforeRemoveLiq); assertFalse(afterRemoveLiq);
        assertTrue(beforeSwap_); assertTrue(afterSwap_);
        assertFalse(beforeDonate); assertFalse(afterDonate);
        assertTrue(beforeSwapDelta); assertFalse(afterSwapDelta);
        assertFalse(afterAddLiqDelta); assertFalse(afterRemoveLiqDelta);
    }
}
