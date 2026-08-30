// SPDX-License-Identifier: MIT
// SECURITY: Cork-class foreign-pool attack on the V4 hook (autonomous PROTECT sweep,
// Architect-authorized 2026-08-30). Question: beforeSwap reads the *incoming* PoolKey
// and only gates on a global `poolInitialized` bool — it does NOT assert the key is the
// canonical registered pool. Its fee logic hardcodes take(native ETH) and assumes
// currency0 == ETH. Can an attacker stand up a FOREIGN pool referencing this hook
// (currency0 != ETH) and, via beforeSwap's take/delta, drain the hook's ETH or inflate
// accumulatedETH? Red-first: the test first tries to prove the drain; the guard holds
// only if the attack cannot move the hook's ETH or its accounting.
//
// MEASURED RESULT (Base fork, 2026-08-30 — from the -vvvv trace):
//   - The attack IS reachable: beforeSwap RUNS on the foreign key (it does NOT
//     bind to the canonical pool) and DOES call take(native ETH, hook, feeETH)
//     — the hook physically pulls 0.02 ETH (2% of a 1e18 swap) into itself.
//   - BUT the whole swap then reverts with CurrencyNotSettled(): the positive
//     BeforeSwapDelta + the native-ETH take cannot be settled by a foreign
//     swapper, so the entire tx — the take included — is rolled back.
//   - Net: hook ETH unchanged, accumulatedETH unchanged, attacker gains 0.
//   => GUARD HOLDS. Safety is STRUCTURAL (V4 atomic settlement / the
//      CurrencyNotSettled invariant), NOT from beforeSwap validating the key.
//      Second layer: beforeAddLiquidity denies all external LPs, so a foreign
//      pool can never hold liquidity for a swap to settle against anyway.
//   => The one-line canonical-key binding at the top of beforeSwap
//      (if toId(key) != toId(poolKey) revert) is worthwhile DEFENSE-IN-DEPTH /
//      fail-fast, but is NOT required to prevent a drain on today's code.
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks}       from "v4-core/libraries/Hooks.sol";
import {IHooks}      from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}     from "v4-core/types/PoolKey.sol";
import {Currency}    from "v4-core/types/Currency.sol";
import {TickMath}    from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PossessioHook} from "../src/POSSESSIO_v2-6-3.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
}

/// Minimal ERC20 satisfying IERC20Minimal (transfer/transferFrom/balanceOf) for V4 settle/take.
contract MockToken {
    string public name = "MOCK"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract PossessioHook_ForeignPoolAttack is Test {
    // ---- Base mainnet fixtures (from PossessioHookCreate3Fork.t.sol) ----
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant DEPLOYER = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;
    bytes32 constant MINED_SALT = 0x9ce4cb26a5f7b50826b07eb8b2c065f0bb37a6c9000000000000000000006cb4;
    address constant EXPECTED_HOOK = 0x5Bc65A4a2Cc114F1dEC551c47F8375f1108e88c8;
    address constant STEEL_ADDR    = 0x726D6a7A598A4D12aDe7019Dc2598D955391E298;
    address constant TREASURY_SAFE = 0x19495180FFA00B8311c85DCF76A89CCbFB174EA0;
    address constant CBETH         = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant CL_CBETH_FEED = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    address constant AERO_ROUTER   = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant WETH_ADDR     = 0x4200000000000000000000000000000000000006;
    address constant COUNCIL_0 = 0x65841AFCE25f2064C0850c412634A72445a2c4C9;
    address constant COUNCIL_1 = 0xEE9369d614ff97838B870ff3BF236E3f15885314;
    address constant COUNCIL_2 = 0xbd4d550E57faf40Ed828b4D8f9642C99A50e2D4f;
    address constant COUNCIL_3 = 0x00490E3332eF93f5A7B4102D1380D1b17D0454D2;

    PossessioHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    address attacker = address(0xA77ACC);
    bool forked;

    function _hookInitCode() internal pure returns (bytes memory) {
        address[4] memory council = [COUNCIL_0, COUNCIL_1, COUNCIL_2, COUNCIL_3];
        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer: DEPLOYER, steel: STEEL_ADDR, poolManager: address(POOL_MANAGER),
            treasury: TREASURY_SAFE, cbETH_: CBETH, chainlinkCbETH: CL_CBETH_FEED,
            aeroRouter: AERO_ROUTER, weth: WETH_ADDR, council: council
        });
        return abi.encodePacked(type(PossessioHook).creationCode, abi.encode(p));
    }

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) { vm.createSelectFork(rpc); } catch {}
        forked = (block.chainid == 8453);
        if (!forked) return;

        vm.prank(DEPLOYER);
        hook = PossessioHook(payable(CREATEX.deployCreate3(MINED_SALT, _hookInitCode())));
        assertEq(address(hook), EXPECTED_HOOK, "hook addr");

        // Register + initialize the canonical WETH/STEEL pool so poolInitialized == true
        // (beforeSwap reverts PoolNotRegistered otherwise — this models the live state).
        PoolKey memory canonical = PoolKey({
            currency0: Currency.wrap(WETH_ADDR), currency1: Currency.wrap(STEEL_ADDR),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        vm.prank(DEPLOYER);
        hook.registerPool(canonical);
        POOL_MANAGER.initialize(canonical, 4101540277851273819802995017366077);

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        lpRouter   = new PoolModifyLiquidityTest(POOL_MANAGER);
    }

    // Build a FOREIGN pool: two worthless mock tokens (neither native ETH nor WETH),
    // pointed at the canonical hook. Maximal currency-mismatch vs the hook's take(ETH).
    function _foreignKey() internal returns (PoolKey memory key, MockToken c0, MockToken c1) {
        MockToken a = new MockToken();
        MockToken b = new MockToken();
        (c0, c1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(c0)), currency1: Currency.wrap(address(c1)),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Non-vacuity controls: prove foreign pools CAN be created and that the
    // liquidity lockout is real (so a passing attack test isn't vacuous).
    // ─────────────────────────────────────────────────────────────────────────
    function test_control_foreignPool_canBeInitialized() public {
        if (!forked) { vm.skip(true); return; }
        (PoolKey memory key,,) = _foreignKey();
        // No beforeInitialize declared → PoolManager should accept the foreign pool.
        POOL_MANAGER.initialize(key, uint160(79228162514264337593543950336)); // 2^96, price 1:1
    }

    function test_control_foreignPool_externalLiquidityDenied() public {
        if (!forked) { vm.skip(true); return; }
        (PoolKey memory key, MockToken c0, MockToken c1) = _foreignKey();
        POOL_MANAGER.initialize(key, uint160(79228162514264337593543950336));
        c0.mint(attacker, 1e24); c1.mint(attacker, 1e24);
        vm.startPrank(attacker);
        c0.approve(address(lpRouter), type(uint256).max);
        c1.approve(address(lpRouter), type(uint256).max);
        // beforeAddLiquidity: sender != address(this) => ExternalLiquidityDenied.
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE ATTACK — red-first. Try to make a foreign-pool swap move the hook's ETH
    // or inflate accumulatedETH. Give the attack every advantage: fund PoolManager
    // AND the hook with native ETH so a take(address(0)) has something to grab.
    // ─────────────────────────────────────────────────────────────────────────
    function test_attack_foreignPoolSwap_cannotDrainHookOrInflateAccounting() public {
        if (!forked) { vm.skip(true); return; }
        (PoolKey memory key, MockToken c0,) = _foreignKey();
        POOL_MANAGER.initialize(key, uint160(79228162514264337593543950336));

        // Adversarially generous: real ETH sitting in both the PoolManager and the hook.
        vm.deal(address(POOL_MANAGER), 100 ether);
        vm.deal(address(hook), 10 ether);
        c0.mint(attacker, 1e24);

        uint256 hookEthBefore = address(hook).balance;
        uint256 accBefore     = hook.accumulatedETH();

        vm.startPrank(attacker);
        c0.approve(address(swapRouter), type(uint256).max);
        // Swap through the foreign pool. beforeSwap fires and attempts take(ETH)+delta.
        bool swapReverted;
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e18),           // exact-in 1 token
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (BalanceDelta) {
            swapReverted = false; // swap completed — check nothing was extracted
        } catch (bytes memory reason) {
            swapReverted = true;
            console2.log("foreign-pool swap reverted (bytes below) - beforeSwap take rolled back:");
            console2.logBytes(reason);
        }
        vm.stopPrank();

        uint256 hookEthAfter = address(hook).balance;
        uint256 accAfter     = hook.accumulatedETH();

        // NON-VACUITY: the foreign swap must genuinely fail to settle. If it had
        // completed, the state assertions below would be the real safety proof;
        // since it reverts, we ALSO assert it reverted, so "no drain" is never a
        // silent no-op. beforeSwap runs at the top of manager.swap (before the
        // liquidity math that reverts), so its take() was attempted and rolled back.
        assertTrue(swapReverted, "expected foreign swap to be unsettleable (no liquidity possible)");

        // SAFETY (green) assertions — the guard holds iff ALL hold:
        assertEq(hookEthAfter, hookEthBefore, "DRAIN: hook native ETH changed via foreign pool");
        assertEq(accAfter, accBefore, "PHANTOM FEE: accumulatedETH inflated via foreign pool");
        // Attacker gained no native ETH from the hook.
        assertEq(attacker.balance, 0, "attacker extracted native ETH");
    }
}
