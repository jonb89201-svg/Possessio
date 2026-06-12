// SPDX-License-Identifier: MIT
// BUILD-PROOF: FORK_VENUES_L1 - Level-1 fork test. Exercises the hook's routing
// legs (routeETH -> LP + cbETH staking) against REAL Base mainnet venues:
// real Aerodrome Slipstream router/pool, real cbETH, real Chainlink cbETH/ETH
// feed, real WETH. Does NOT exercise the real V4 PoolManager (the routing legs
// are called from EOA/Treasury, OUTSIDE the V4 unlock context, so they don't
// need it). The real-PoolManager integration + the salt-mine/CREATE2 deploy
// mechanics are proven by the actual testnet deploy, not here.
//
// PURPOSE: prove the cbETH staking economics against the REAL Aerodrome pool
// before spending a testnet deploy - catch real-vs-mock surprises (the leakage
// check, real slippage, real feed staleness) cheaply.
//
// RUN: forge test --match-contract PossessioForkTest \
//        --fork-url https://mainnet.base.org -vvv
// (Skips its body cleanly if not run against a Base-mainnet fork.)
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../src/POSSESSIO_v2-6-3.sol";

contract PossessioForkTest is Test {
    using stdStorage for StdStorage;
    // --- REAL Base mainnet addresses (cast-verified this session) ----------
    address constant REAL_WETH       = 0x4200000000000000000000000000000000000006;
    address constant REAL_CBETH      = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    // Aerodrome Slipstream SwapRouter (corrected from the wrong cF77 address;
    // BaseScan-verified, ISwapRouter ABI matches our ExactInputSingleParams).
    address constant REAL_AERO_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant REAL_AERO_POOL  = 0x47cA96Ea59C13F72745928887f84C9F52C3D7348;
    address constant REAL_CBETH_FEED = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    // V4 PoolManager - set as a param but NOT exercised in Level-1 (routing legs
    // run outside the unlock context). Real Base mainnet V4 PoolManager:
    address constant REAL_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Council placeholders (any non-zero addresses pass constructor validation)
    address constant C0 = address(0xC0);
    address constant C1 = address(0xC1);
    address constant C2 = address(0xC2);
    address constant C3 = address(0xC3);
    address constant TREASURY = address(0x7777);

    PossessioHook hook;
    bool forked;

    function setUp() public {
        // Only do real setup when running against a fork. If the active chain
        // isn't Base mainnet (chainid 8453), mark unforked and skip bodies.
        if (block.chainid != 8453) {
            forked = false;
            return;
        }
        forked = true;

        // STEEL must exist; deploy a fresh one (the hook only needs the address).
        STEEL steel = new STEEL(address(this));

        address[4] memory council = [C0, C1, C2, C3];
        PossessioHook.DeployParams memory p = PossessioHook.DeployParams({
            deployer:       address(this),
            steel:          address(steel),
            poolManager:    REAL_POOL_MANAGER,
            treasury:       TREASURY,
            cbETH_:         REAL_CBETH,
            chainlinkCbETH: REAL_CBETH_FEED,
            aeroRouter:     REAL_AERO_ROUTER,
            weth:           REAL_WETH,
            council:        council
        });
        hook = new PossessioHook(p);

        // Bypass the V4 lifecycle for routing tests (same stub the mock suite
        // uses). routeETH runs outside the unlock context, so this is valid.
        stdstore.target(address(hook)).sig("poolInitialized()").checked_write(true);
    }

    // -- Sanity: the real venues exist and answer on the fork ---------------
    function test_Fork_RealVenuesExist() public view {
        if (!forked) return;
        // Real WETH symbol
        assertEq(IERC20Metadata(REAL_WETH).symbol(), "WETH", "real WETH");
        // Real cbETH symbol
        assertEq(IERC20Metadata(REAL_CBETH).symbol(), "cbETH", "real cbETH");
        // Real Chainlink cbETH/ETH feed answers, 18-dec, positive
        (, int256 ans,,,) = IChainlinkFeed(REAL_CBETH_FEED).latestRoundData();
        assertGt(ans, 0, "real cbETH/ETH feed positive");
        assertEq(IChainlinkFeed(REAL_CBETH_FEED).decimals(), 18, "feed 18-dec");
    }

    // -- The real test: routeETH against the REAL Aerodrome cbETH swap ------
    function test_Fork_RouteETH_RealAerodromeStaking() public {
        if (!forked) return;

        // Fund the hook with real ETH to route (clearly above ROUTE_THRESHOLD
        // = 0.05 ether; use 0.06 to stay off the boundary).
        uint256 routeAmt = 0.06 ether;
        vm.deal(address(hook), routeAmt);
        // Seed accumulatedETH so routeETH has something to route.
        stdstore.target(address(hook)).sig("accumulatedETH()").checked_write(routeAmt);

        uint256 cbPrincipalBefore = hook.cbETHPrincipal();

        // Route. LP leg will likely fail (no real V4 pool initialized here -
        // that's fine, LP-fail retains ETH). The cbETH leg should swap on the
        // REAL Aerodrome pool. This is the integration we're proving.
        vm.prank(TREASURY);
        hook.routeETH();

        uint256 cbPrincipalAfter = hook.cbETHPrincipal();

        // The cbETH leg either:
        //  (a) swapped on real Aerodrome -> cbETHPrincipal increased (the win), OR
        //  (b) retained (oracle/slippage fail-closed) -> principal unchanged.
        // We ASSERT it swapped, because the whole point is proving the real
        // Aerodrome integration works. If this fails with principal unchanged,
        // the -vvv trace shows WHY (leakage check? slippage floor? feed stale?)
        // - which is exactly the real-vs-mock surprise this test exists to catch.
        assertGt(
            cbPrincipalAfter,
            cbPrincipalBefore,
            "cbETH leg must swap on REAL Aerodrome (principal increased)"
        );

        // The hook should now hold real cbETH.
        uint256 cbBal = IERC20(REAL_CBETH).balanceOf(address(hook));
        assertEq(cbBal, cbPrincipalAfter, "hook holds the real cbETH it accounted");
    }
}

// Minimal metadata interface for symbol() reads on the fork.
interface IERC20Metadata {
    function symbol() external view returns (string memory);
}
