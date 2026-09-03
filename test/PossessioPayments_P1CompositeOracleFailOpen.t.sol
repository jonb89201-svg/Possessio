// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";

// ============================================================================
// P-1 — WETH-LEG ORACLE FLOOR FAILS OPEN ON COMPOSITE-FEED STALENESS
//
// Cold-seat audit finding (2026-08-26), PossessioPayments HEAD.
//
// THE CHARGE THE H-1 REGRESSION SUITE NEVER FILED
// -----------------------------------------------
// The H-1 fix floors each sweep leg at max(callerMin, 90% * oracleExpected).
// For the USDC->WETH leg the oracle-expected value comes from _usdcToEth(),
// which reads the USDC/USD and ETH/USD Chainlink feeds. Those two feeds are
// checked with a FAIL-OPEN pattern: on staleness/invalidity _usdcToEth RETURNS
// 0 (it does not revert). When it returns 0:
//
//     wethFloor = _usdcToEth(cbEthAlloc) * 9000 / 10000 = 0
//     wethMin   = max(minWethOut, 0)
//
// and sweepSlippageMinWeth (the automation-supplied minWethOut) DEFAULTS TO 0.
// So the USDC->WETH swap runs with amountOutMinimum = 0 — no slippage floor —
// exactly the H-1 condition the fix was written to close.
//
// This is reachable while the sweep still executes, because the cbETH/ETH feed
// (_validateOracle, the only feed that gates entry) is a SEPARATE feed with a
// DIFFERENT, WIDER staleness window:
//     cbETH/ETH  : ORACLE_STALE_CBETH = 90,000s (25h), and REVERTS if stale.
//     USDC/ETH   : ORACLE_STALE       =  3,600s (1h),  and RETURNS 0 if stale.
// Any moment in the 1h..25h gap where USDC/USD or ETH/USD has not refreshed but
// cbETH/ETH has -> sweep proceeds, WETH floor is 0.
//
// The entire H-1 suite re-stamps ALL FOUR feeds fresh before every sweep, so it
// can never observe this. This file files the missing charge.
//
// STATUS: FIXED at HEAD by the P-1 fail-closed guard in _sweep
//   (`if (wethFloor == 0) revert OracleStale();`). This file is now the
//   permanent regression that pins the fix.
//
// RED/GREEN PROTOCOL (terminal is the judge):
//   * test_P1_control_FreshComposite_SandbagReverts  -> the floor HAS teeth when
//     the composite feed is fresh (identical sandbag reverts). Positive control.
//   * test_P1_StaleComposite_WethLegFailsClosed      -> with ONLY USDC/USD
//     stale, the fixed contract REVERTS OracleStale before the router is reached
//     (fail-closed). Against the PRE-FIX contract wethFloor collapses to 0, the
//     sandbag is ACCEPTED and the sweep SUCCEEDS -> the expectRevert is not
//     satisfied -> RED. That red run (verified during the audit by removing the
//     guard) is what proves the regression is non-vacuous.
// ============================================================================

contract MockUSDC_P1 {
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

contract MockDAI_P1 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockCbETH_P1 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockWETH_P1 {
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

// V3 router mock: enforces amountOutMinimum exactly like the real router.
// If the contract passes a real oracle floor, a sandbag reverts here.
// If the contract passes 0 (the fail-open), the sandbag is accepted.
contract MockV3Router_P1 {
    MockDAI_P1 public dai;
    MockWETH_P1 public weth;
    uint256 public daiOut;
    uint256 public wethOut;
    function setDai(address d) external { dai = MockDAI_P1(d); }
    function setWeth(address w) external { weth = MockWETH_P1(w); }
    function setDaiOut(uint256 v) external { daiOut = v; }
    function setWethOut(uint256 v) external { wethOut = v; }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256) {
        MockUSDC_P1(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenOut == address(dai)) {
            require(daiOut >= p.amountOutMinimum, "V3: slippage DAI");
            dai.mint(p.recipient, daiOut);
            return daiOut;
        } else if (p.tokenOut == address(weth)) {
            require(wethOut >= p.amountOutMinimum, "V3: slippage WETH"); // the teeth
            weth.mint(p.recipient, wethOut);
            return wethOut;
        }
        revert("V3: unknown tokenOut");
    }
}

contract MockAero_P1 {
    MockWETH_P1 public weth;
    MockCbETH_P1 public cbeth;
    uint256 public cbEthOut;
    constructor(address w, address c) { weth = MockWETH_P1(w); cbeth = MockCbETH_P1(c); }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; int24 tickSpacing; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        MockWETH_P1(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        require(cbEthOut >= p.amountOutMinimum, "Aero: slippage cbETH");
        cbeth.mint(p.recipient, cbEthOut);
        return cbEthOut;
    }
}

contract MockChainlink_P1 {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;
    constructor(int256 a, uint8 d) { answer = a; decimals = d; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}

contract MockLSTRates_P1 {
    function getRate() external pure returns (uint256) { return 1 ether; }
    function cbEthToEth(uint256 cbEthAmount) external pure returns (uint256) {
        return (cbEthAmount * 98) / 100;
    }
}

contract MockMorpho_P1 {
    MockUSDC_P1 public usdc;
    mapping(address => uint256) public shares;
    constructor(address u) { usdc = MockUSDC_P1(u); }
    function deposit(uint256 a, address receiver) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), a);
        shares[receiver] += a;
        return a;
    }
    function balanceOf(address account) external view returns (uint256) { return shares[account]; }
    function convertToAssets(uint256 s) external pure returns (uint256) { return s; }
}

// ============================================================================

contract PossessioPaymentsP1Test is Test {
    PossessioPayments payments;
    MockUSDC_P1 usdc;
    MockDAI_P1 dai;
    MockCbETH_P1 cbeth;
    MockWETH_P1 weth;
    MockV3Router_P1 router;
    MockAero_P1 aero;
    MockMorpho_P1 morpho;
    MockChainlink_P1 clEth;
    MockChainlink_P1 clDai;
    MockChainlink_P1 clUsdcUsd;
    MockChainlink_P1 clEthUsd;
    MockLSTRates_P1 lst;

    address constant MERCHANT = address(0xBEEF);
    uint256 constant MIN_BATCH = 10 * 1e6;
    uint256 constant DAI_CEILING = 2280 * 1e18;
    uint256 constant DAILY_LIMIT = 1000 * 1e18;
    uint256 constant USDC_DAILY_LIMIT  = 1_000 * 1e6;
    uint256 constant CBETH_DAILY_LIMIT = 1 ether;

    function setUp() public {
        vm.warp(1_000_000);
        usdc  = new MockUSDC_P1();
        dai   = new MockDAI_P1();
        cbeth = new MockCbETH_P1();
        weth  = new MockWETH_P1();
        router = new MockV3Router_P1();
        router.setDai(address(dai));
        router.setWeth(address(weth));
        aero   = new MockAero_P1(address(weth), address(cbeth));
        morpho = new MockMorpho_P1(address(usdc));

        clEth     = new MockChainlink_P1(int256(980_000_000_000_000_000), 18); // cbETH/ETH 0.98
        clDai     = new MockChainlink_P1(int256(500_000_000_000), 8);
        clUsdcUsd = new MockChainlink_P1(int256(100_000_000), 8);              // $1.00
        clEthUsd  = new MockChainlink_P1(int256(300_000_000_000), 8);          // $3000
        lst       = new MockLSTRates_P1();

        payments = deployPayments(PossessioPayments.DeployParams({
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
            dailyLimit:       DAILY_LIMIT,
            usdcDailyLimit:   USDC_DAILY_LIMIT,
            cbEthDailyLimit:  CBETH_DAILY_LIMIT
        }));
    }

    // Shared sandbag setup. The DAI leg is deliberately sandbagged below its
    // (oracle-free, peg-derived) floor so it fails inside the sweep's try/catch
    // and is swallowed, letting the full 1000 USDC reach the split -> 500 USDC
    // to the cbETH (WETH) leg. The WETH output 0.05 ETH is far below the fresh
    // oracle floor (~0.15 ETH for 500 USDC at $3000), so a live floor rejects it.
    function _armSandbag() internal {
        usdc.mint(address(payments), 1000 * 1e6);
        router.setDaiOut(500 * 1e18);   // < 900e18 DAI floor -> try/catch swallows
        router.setWethOut(0.05 ether);  // << 0.15 ETH fresh WETH floor (sandbag)
        aero.setCbEthOut(0.05 ether);   // above the WETH->cbETH floor (uses fresh cbETH feed)
        vm.warp(block.timestamp + 7 days);
    }

    // -----------------------------------------------------------------------
    // POSITIVE CONTROL — floor has teeth when the composite feed is FRESH.
    // -----------------------------------------------------------------------
    function test_P1_control_FreshComposite_SandbagReverts() public {
        _armSandbag();
        // All four feeds fresh (the H-1 suite's world).
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);

        vm.prank(MERCHANT);
        vm.expectRevert("V3: slippage WETH"); // fresh floor (~0.15 ETH) rejects 0.05
        payments.sweep(0, 0, 0);
    }

    // -----------------------------------------------------------------------
    // THE P-1 REGRESSION — composite feed STALE (only USDC/USD), cbETH/ETH FRESH.
    //
    // FIXED behaviour (HEAD): the WETH-leg floor is fail-closed, so a stale
    // composite feed collapses wethFloor to 0 and the sweep REVERTS OracleStale
    // BEFORE the router is reached — the sandbagged swap can never execute.
    //
    // PRE-FIX behaviour: wethFloor == 0 -> wethMin == 0 -> the mock router
    // ACCEPTS the 0.05-ETH sandbag and the sweep SUCCEEDS -> this expectRevert
    // is not satisfied -> RED. That red run is what proves the test has teeth.
    // (Verified during the audit: temporarily removing the `if (wethFloor == 0)
    //  revert` guard flips this test to a failing/no-revert state.)
    // -----------------------------------------------------------------------
    function test_P1_StaleComposite_WethLegFailsClosed() public {
        _armSandbag();
        // cbETH/ETH, DAI, ETH/USD fresh — sweep entry (_validateOracle) passes.
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
        // USDC/USD stale by just over the 1h window -> _usdcToEth returns 0
        // -> wethFloor == 0 -> (fixed) revert OracleStale.
        // P-H2 (re-audit 2026-09-01): USDC/USD is a 24h-heartbeat feed. A 8-hour-old
        // round is NORMAL and must pass the composite guard — the sweep then meets
        // the armed sandbag at the router, which is the proof the guard let it
        // through (pre-fix, ORACLE_STALE=3600 reverted OracleStale ~96% of each day).
        clUsdcUsd.setUpdatedAt(block.timestamp - 8 hours);
        vm.prank(MERCHANT);
        vm.expectRevert(bytes("V3: slippage WETH"));
        payments.sweep(0, 0, 0);

        // Beyond heartbeat + slack the guard still fails closed.
        clUsdcUsd.setUpdatedAt(block.timestamp - (payments.ORACLE_STALE_STABLE() + 1));

        // Sanity: cbETH/ETH is comfortably inside its own 25h window, so the
        // sweep is NOT blocked by _validateOracle — the ONLY thing that stops it
        // is the P-1 fail-closed WETH-floor guard, not the cbETH gate.
        assertLt(
            block.timestamp - clEth.updatedAt(),
            payments.ORACLE_STALE_CBETH(),
            "cbETH feed must be fresh so the block is the WETH-floor guard, not the cbETH gate"
        );

        vm.prank(MERCHANT);
        // Fail-closed: stale composite feed blocks the sweep rather than running
        // the WETH leg with a collapsed (zero) slippage floor.
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        payments.sweep(0, 0, 0);
    }
}
