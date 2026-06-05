// SPDX-License-Identifier: MIT
// BUILD-PROOF: H1SLIP_V243_OUT62b — MockAero_H1 signature aligned to IAerodromeSlipstreamRouter (tickSpacing/deadline, payable); oracle refresh + specific slippage reverts retained.
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";

// ===========================================================================
// H-1 SLIPPAGE REGRESSION SUITE
//
// Audit finding H-1 (PossessioPayments v2.4.2 audit): the automated-sweep
// slippage guards were static operator-set values that DEFAULT TO ZERO, did
// not scale with swept amount, and were trusted from forwarder performData.
// A sweep(0,0,0) — the out-of-box default — ran every leg with
// amountOutMinimum = 0, leaving the auto-sweep unprotected against sandwiching.
//
// Ratified fix (hybrid floor): each leg's effective min-out is
//   max(callerSuppliedMin, oracleFloor)
// where oracleFloor = 90% (SWEEP_SLIPPAGE_BPS = 9000) of the oracle-expected
// output. A caller can TIGHTEN but never LOOSEN below the oracle-derived floor.
//
// THESE TESTS PROVE THE FIX HAS TEETH:
//   - Against the FIXED contract: a sweep with zero/too-low caller mins still
//     reverts when a router returns less than the oracle floor -> sandwich
//     blocked -> tests GREEN.
//   - Against the OLD (vulnerable) contract: sweep(0,0,0) passed
//     amountOutMinimum = 0, the sandbagged swap succeeded, no revert -> tests
//     would be RED (proving they catch H-1).
//
// VERIFICATION PROTOCOL (run by the architect at terminal):
//   1. Point the import at the PRE-FIX contract (no oracle floor) -> expect RED.
//   2. Point the import at the FIXED PossessioPayments.sol (v2.4.3) -> expect GREEN.
//   A test that only ever ran green proves nothing. The red run is mandatory.
// ===========================================================================

// --- Minimal mocks (mirror the main suite's pattern; self-contained here) ---

contract MockUSDC_H1 {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "USDC bal");
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockDAI_H1 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockCbETH_H1 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockWETH_H1 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

// V3 router mock: enforces amountOutMinimum like the real router. This is the
// teeth — if the contract passes a high oracle-floor min, a sandbagged output
// reverts here. If the contract passes 0 (the H-1 bug), the sandbag passes.
contract MockV3Router_H1 {
    MockDAI_H1 public dai;
    MockWETH_H1 public weth;
    uint256 public daiOut;
    uint256 public wethOut;
    function setDai(address d) external { dai = MockDAI_H1(d); }
    function setWeth(address w) external { weth = MockWETH_H1(w); }
    function setDaiOut(uint256 v) external { daiOut = v; }
    function setWethOut(uint256 v) external { wethOut = v; }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256) {
        MockUSDC_H1(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenOut == address(dai)) {
            require(daiOut >= p.amountOutMinimum, "V3: slippage DAI"); // <-- the teeth
            dai.mint(p.recipient, daiOut);
            return daiOut;
        } else if (p.tokenOut == address(weth)) {
            require(wethOut >= p.amountOutMinimum, "V3: slippage WETH"); // <-- the teeth
            weth.mint(p.recipient, wethOut);
            return wethOut;
        }
        revert("V3: unknown tokenOut");
    }
}

contract MockAero_H1 {
    MockWETH_H1 public weth;
    MockCbETH_H1 public cbeth;
    uint256 public cbEthOut;
    constructor(address w, address c) { weth = MockWETH_H1(w); cbeth = MockCbETH_H1(c); }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; int24 tickSpacing; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        MockWETH_H1(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        require(cbEthOut >= p.amountOutMinimum, "Aero: slippage cbETH"); // <-- the teeth
        cbeth.mint(p.recipient, cbEthOut);
        return cbEthOut;
    }
}

contract MockChainlink_H1 {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;
    constructor(int256 a, uint8 d) { answer = a; decimals = d; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}

contract MockLSTRates_H1 {
    function getRate() external pure returns (uint256) { return 1 ether; }
    // Contract calls LST_RATES.cbEthToEth(cbEthOut) in the gauge update after the
    // Morpho leg; must return non-zero or the sweep reverts ExchangeRateInvalid.
    // ~0.98 ETH per cbETH, consistent with the 0.98 rate used elsewhere in H-1.
    function cbEthToEth(uint256 cbEthAmount) external pure returns (uint256) {
        return (cbEthAmount * 98) / 100;
    }
}

contract MockMorpho_H1 {
    MockUSDC_H1 public usdc;
    mapping(address => uint256) public shares;   // track shares so balanceOf increases on deposit
    constructor(address u) { usdc = MockUSDC_H1(u); }
    function deposit(uint256 a, address receiver) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), a);
        // 1:1 shares for simplicity — the contract verifies via share DELTA
        // (sharesAfter > sharesBefore), so balanceOf must rise by the deposit.
        shares[receiver] += a;
        return a;
    }
    function balanceOf(address account) external view returns (uint256) { return shares[account]; }
    function convertToAssets(uint256 s) external pure returns (uint256) { return s; }
}

// ===========================================================================

contract PossessioPaymentsH1SlippageTest is Test {
    PossessioPayments payments;
    MockUSDC_H1 usdc;
    MockDAI_H1 dai;
    MockCbETH_H1 cbeth;
    MockWETH_H1 weth;
    MockV3Router_H1 router;
    MockAero_H1 aero;
    MockMorpho_H1 morpho;
    MockChainlink_H1 clEth;
    MockChainlink_H1 clDai;
    MockChainlink_H1 clUsdcUsd;
    MockChainlink_H1 clEthUsd;
    MockLSTRates_H1 lst;

    address constant MERCHANT = address(0xBEEF);
    uint256 constant MIN_BATCH = 10 * 1e6;
    uint256 constant DAI_CEILING = 2280 * 1e18;
    uint256 constant DAILY_LIMIT = 1000 * 1e18;

    // Oracle config (mirrors main suite healthy values):
    //   ETH/USD = $3000 (8-dec), USDC/USD = $1.00 (8-dec)
    //   cbETH/ETH = 0.98e18 (18-dec exchange rate)
    // So _usdcToEth(N usdc) ~= N/3000 ETH; oracle floor = 90% of that.

    function setUp() public {
        vm.warp(1_000_000);
        usdc  = new MockUSDC_H1();
        dai   = new MockDAI_H1();
        cbeth = new MockCbETH_H1();
        weth  = new MockWETH_H1();
        router = new MockV3Router_H1();
        router.setDai(address(dai));
        router.setWeth(address(weth));
        aero   = new MockAero_H1(address(weth), address(cbeth));
        morpho = new MockMorpho_H1(address(usdc));

        clEth     = new MockChainlink_H1(int256(980_000_000_000_000_000), 18); // cbETH/ETH 0.98
        clDai     = new MockChainlink_H1(int256(500_000_000_000), 8);          // DAI/ETH
        clUsdcUsd = new MockChainlink_H1(int256(100_000_000), 8);              // $1.00
        clEthUsd  = new MockChainlink_H1(int256(300_000_000_000), 8);          // $3000
        lst       = new MockLSTRates_H1();

        payments = new PossessioPayments(PossessioPayments.DeployParams({
            owner:            MERCHANT,
            usdc:             address(usdc),
            cbeth:            address(cbeth),
            dai:              address(dai),
            weth:             address(weth),
            router:           address(router),
            aeroRouter:       address(aero),
            morphoVault:      address(morpho),
            chainlink:        address(clEth),
            chainlinkDai:     address(clDai),
            chainlinkUsdcUsd: address(clUsdcUsd),
            chainlinkEthUsd:  address(clEthUsd),
            lstRates:         address(lst),
            minSwapBatch:     MIN_BATCH,
            daiCeiling:       DAI_CEILING,
            dailyLimit:       DAILY_LIMIT
        }));
    }

    // -----------------------------------------------------------------------
    // CORE H-1 REGRESSION TESTS
    // -----------------------------------------------------------------------

    /// @notice THE H-1 TEST. With zero caller-supplied mins (the vulnerable
    ///         default), a router that sandbags the WETH leg below the 90%
    ///         oracle floor MUST cause the sweep to revert. Against the OLD
    ///         contract this passed (min was 0); against the FIXED contract the
    ///         oracle floor forces amountOutMinimum high enough that the mock
    ///         router's slippage require() fires.
    function test_H1_ZeroCallerMin_SandbaggedWeth_Reverts() public {
        // 1000 USDC accumulated, default 50/50 split -> ~500 USDC to cbETH leg.
        usdc.mint(address(payments), 1000 * 1e6);

        // Oracle-expected ETH for 500 USDC at $3000 ~= 0.1667 ETH; floor = 90%
        // ~= 0.15 ETH. Sandbag the router to return far less: 0.05 ETH.
        router.setDaiOut(500 * 1e18);   // DAI leg healthy
        router.setWethOut(0.05 ether);  // WETH leg sandbagged below floor
        aero.setCbEthOut(0.05 ether);

        // Caller supplies ZERO mins — the H-1 default. Fixed contract floors it.
        vm.warp(block.timestamp + 7 days);
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
        vm.prank(MERCHANT);
        // Assert the SLIPPAGE revert specifically — not a bare expectRevert that
        // a stale oracle could satisfy. This proves the floor fired, not freshness.
        vm.expectRevert("V3: slippage WETH");
        payments.sweep(0, 0, 0);
    }

    /// @notice With zero caller mins and a router delivering AT/ABOVE the oracle
    ///         floor, the sweep succeeds. Confirms the floor isn't over-tight —
    ///         honest swaps still clear.
    function test_H1_ZeroCallerMin_HonestRouter_Succeeds() public {
        usdc.mint(address(payments), 1000 * 1e6);

        router.setDaiOut(500 * 1e18);
        router.setWethOut(0.16 ether);  // ~= oracle-expected, above 90% floor
        aero.setCbEthOut(0.16 ether);

        vm.warp(block.timestamp + 7 days);

        // Re-stamp ALL oracle feeds to the post-warp time. The H-1 fix added
        // oracle reads on the slippage-floor path (_validateOracle for cbETH/ETH,
        // _usdcToEth for USDC/USD + ETH/USD), so an honest sweep now requires
        // every feed fresh. Warping 7 days to clear the sweep cooldown leaves
        // them stale; refresh before sweeping or the contract (correctly) reverts
        // OracleStale before the floor is ever exercised.
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);

        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0); // should NOT revert
    }

    /// @notice A caller-supplied min ABOVE the oracle floor is honored (caller
    ///         can tighten). Router just below the tighter caller min reverts.
    function test_H1_CallerMinTighterThanFloor_IsHonored() public {
        usdc.mint(address(payments), 1000 * 1e6);

        router.setDaiOut(500 * 1e18);
        router.setWethOut(0.16 ether);  // above oracle floor...
        aero.setCbEthOut(0.16 ether);

        // ...but caller demands 0.20 ETH on the WETH leg, tighter than floor.
        vm.warp(block.timestamp + 7 days);
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
        vm.prank(MERCHANT);
        // 0.16 < caller's 0.20 -> WETH slippage require fires (not staleness).
        vm.expectRevert("V3: slippage WETH");
        payments.sweep(0, 0.20 ether, 0);
    }

    /// @notice The scaling property: the floor must grow with the swept amount.
    ///         A larger accumulated balance with the same sandbag ratio still
    ///         reverts — proving the floor is amount-scaled, not a static value
    ///         that a big sweep outgrows (the second half of H-1).
    function test_H1_FloorScalesWithSweptAmount() public {
        // 10x the balance — H-1's "exposure scales up with success" case.
        usdc.mint(address(payments), 10_000 * 1e6);

        router.setDaiOut(5000 * 1e18);
        router.setWethOut(0.5 ether);   // sandbagged: ~1.5 ETH expected, 90% ~1.35
        aero.setCbEthOut(0.5 ether);

        vm.warp(block.timestamp + 7 days);
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
        vm.prank(MERCHANT);
        // scaled floor catches the proportionally-large sandbag on the WETH leg.
        vm.expectRevert("V3: slippage WETH");
        payments.sweep(0, 0, 0);
    }
}
