// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PossessioPayments.sol";
import {deployPayments} from "./PaymentsDeployHelper.sol";

// ============================================================================
// CORPUS REGRESSION LOCK — PossessioPayments vs the audit-fix corpus
//
// These tests pin defenses that PossessioPayments ALREADY has, so a future
// refactor cannot silently drop them. Each maps to a class in the council's
// audit-fix corpus (scout-model/data/audit_fix_corpus.md) — real bugs other
// protocols had to fix. The hardening report
// (Possessio-AI-Council-Sandbox/audits/POSSESSIO_hardening_vs_corpus_20260831.md)
// found POSSESSIO protected across all 16; its follow-up #1 was "turn the
// protected rows into green-invariant tests." This file is that lock.
//
//   AF-2  — Fee-split floors must sum back to the input (no stranded dust).
//           POSSESSIO fix-by-construction: morphoAlloc = usdcAfterDai - cbEthAlloc
//           (remainder to the last leg). Doppler's D-1 is the unpatched twin.
//   AF-8  — Unbounded config parameter. setCbEthBps is bounded to [1000, 9000].
//   AF-14 — Oracle used without staleness/validity validation. _validateOracle
//           reverts on a stale or non-positive cbETH/ETH feed. (The composite
//           USDC/ETH fail-closed leg is locked separately in
//           PossessioPayments_P1CompositeOracleFailOpen.t.sol.)
//
// RED/GREEN: every assertion here is non-vacuous — removing the corresponding
// guard flips it. AF-8 loses its revert; AF-2's drain-to-zero breaks the moment
// the remainder stops being credited to a leg; AF-14 stops reverting.
//
// Terminal is the judge (Codebyte Law). MEASURED: these run against the real
// PossessioPayments bytecode via deployPayments, no stubbing of the unit under
// test. Local solc 0.8.27 (the 0.8.35 CI file is separate).
// ============================================================================

contract MockUSDC_CR {
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

contract MockDAI_CR {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockCbETH_CR {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract MockWETH_CR {
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

// V3 router mock: consumes EXACTLY amountIn (so the contract's leakage checks
// pass) and mints a fixed, generous output that clears any oracle floor.
contract MockV3Router_CR {
    MockDAI_CR public dai;
    MockWETH_CR public weth;
    uint256 public daiOut;
    uint256 public wethOut;
    function setDai(address d) external { dai = MockDAI_CR(d); }
    function setWeth(address w) external { weth = MockWETH_CR(w); }
    function setDaiOut(uint256 v) external { daiOut = v; }
    function setWethOut(uint256 v) external { wethOut = v; }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256) {
        MockUSDC_CR(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenOut == address(dai)) {
            require(daiOut >= p.amountOutMinimum, "V3: slippage DAI");
            dai.mint(p.recipient, daiOut);
            return daiOut;
        } else if (p.tokenOut == address(weth)) {
            require(wethOut >= p.amountOutMinimum, "V3: slippage WETH");
            weth.mint(p.recipient, wethOut);
            return wethOut;
        }
        revert("V3: unknown tokenOut");
    }
}

contract MockAero_CR {
    MockWETH_CR public weth;
    MockCbETH_CR public cbeth;
    uint256 public cbEthOut;
    constructor(address w, address c) { weth = MockWETH_CR(w); cbeth = MockCbETH_CR(c); }
    function setCbEthOut(uint256 v) external { cbEthOut = v; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; int24 tickSpacing; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        MockWETH_CR(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        require(cbEthOut >= p.amountOutMinimum, "Aero: slippage cbETH");
        cbeth.mint(p.recipient, cbEthOut);
        return cbEthOut;
    }
}

contract MockChainlink_CR {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;
    constructor(int256 a, uint8 d) { answer = a; decimals = d; updatedAt = block.timestamp; }
    function setAnswer(int256 a) external { answer = a; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}

contract MockLSTRates_CR {
    function getRate() external pure returns (uint256) { return 1 ether; }
    function cbEthToEth(uint256 cbEthAmount) external pure returns (uint256) {
        return (cbEthAmount * 98) / 100;
    }
}

// Morpho vault mock: shares minted == USDC deposited (1:1), so the shares
// balance directly reports how much USDC the Morpho leg actually received.
contract MockMorpho_CR {
    MockUSDC_CR public usdc;
    mapping(address => uint256) public shares;
    constructor(address u) { usdc = MockUSDC_CR(u); }
    function deposit(uint256 a, address receiver) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), a);
        shares[receiver] += a;
        return a;
    }
    function balanceOf(address account) external view returns (uint256) { return shares[account]; }
    function convertToAssets(uint256 s) external pure returns (uint256) { return s; }
}

// ============================================================================

contract PossessioPaymentsCorpusRegressionTest is Test {
    PossessioPayments payments;
    MockUSDC_CR usdc;
    MockDAI_CR dai;
    MockCbETH_CR cbeth;
    MockWETH_CR weth;
    MockV3Router_CR router;
    MockAero_CR aero;
    MockMorpho_CR morpho;
    MockChainlink_CR clEth;
    MockChainlink_CR clDai;
    MockChainlink_CR clUsdcUsd;
    MockChainlink_CR clEthUsd;
    MockLSTRates_CR lst;

    address constant MERCHANT = address(0xBEEF);
    uint256 constant MIN_BATCH = 10 * 1e6;

    function setUp() public {
        vm.warp(1_000_000);
        usdc  = new MockUSDC_CR();
        dai   = new MockDAI_CR();
        cbeth = new MockCbETH_CR();
        weth  = new MockWETH_CR();
        router = new MockV3Router_CR();
        router.setDai(address(dai));
        router.setWeth(address(weth));
        aero   = new MockAero_CR(address(weth), address(cbeth));
        morpho = new MockMorpho_CR(address(usdc));

        clEth     = new MockChainlink_CR(int256(980_000_000_000_000_000), 18); // cbETH/ETH 0.98 (18-dec)
        clDai     = new MockChainlink_CR(int256(100_000_000), 8);              // DAI/USD $1.00 (8-dec)
        clUsdcUsd = new MockChainlink_CR(int256(100_000_000), 8);              // USDC/USD $1.00
        clEthUsd  = new MockChainlink_CR(int256(300_000_000_000), 8);          // ETH/USD $3000
        lst       = new MockLSTRates_CR();

        // daiCeiling = 0 → opts out of the DAI leg entirely, so usdcAfterDai
        // equals the full USDC balance and the AF-2 split runs on the whole
        // amount (isolates the split conservation under test). Generous exit
        // limits so nothing else gates the sweep.
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
            daiCeiling:       0,
            dailyLimit:       type(uint128).max,
            usdcDailyLimit:   type(uint128).max,
            cbEthDailyLimit:  type(uint128).max
        }));
    }

    function _freshOracles() internal {
        clEth.setUpdatedAt(block.timestamp);
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
    }

    // Generous, fixed swap outputs that clear the H-1 oracle floors for any
    // fuzzed input in the tested range. The router/aero still consume EXACTLY
    // the USDC/WETH amountIn, so the contract's leakage checks stay meaningful.
    function _armSuccessfulLegs() internal {
        router.setWethOut(1e24); // >> any WETH floor for inputs <= 500k USDC
        aero.setCbEthOut(1e24);  // >> any cbETH floor for wethOut = 1e24
    }

    // -----------------------------------------------------------------------
    // AF-2 — fee-split conservation: after a sweep the ENTIRE input is split
    // between the two legs with NO USDC stranded, for EVERY bps in [1000,9000]
    // and every input size. The remainder of the integer division lands in the
    // Morpho leg by construction (last-bucket-gets-remainder).
    // -----------------------------------------------------------------------
    function testFuzz_AF2_splitConservesInput_noDust(uint16 bpsSeed, uint256 amtSeed) public {
        uint16 bps = uint16(1000 + (bpsSeed % 8001)); // [1000, 9000]
        // [MIN_BATCH, 500_000 USDC] — bounded so the fixed mock outputs clear floors.
        uint256 amt = MIN_BATCH + (amtSeed % (500_000 * 1e6 - MIN_BATCH + 1));

        vm.prank(MERCHANT);
        payments.setCbEthBps(bps);

        usdc.mint(address(payments), amt);
        _armSuccessfulLegs();
        _freshOracles();
        vm.warp(block.timestamp + 7 days);
        _freshOracles();

        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);

        uint256 cbEthAlloc = (amt * bps) / 10000;
        uint256 morphoAlloc = amt - cbEthAlloc;

        // Conservation: the contract's USDC is fully consumed — Σ pieces == input,
        // nothing stranded. This is the AF-2 assertion (Doppler D-1's unpatched twin).
        assertEq(usdc.balanceOf(address(payments)), 0, "AF-2: USDC dust stranded after split");

        // The Morpho leg received EXACTLY the remainder (the last bucket), proving
        // the integer-division residue is credited, not lost.
        assertEq(morpho.shares(address(payments)), morphoAlloc, "AF-2: remainder not credited to Morpho leg");

        // Sanity on the identity itself.
        assertEq(cbEthAlloc + morphoAlloc, amt, "AF-2: split legs do not sum to input");
    }

    // Deterministic worst-case: an input+bps chosen so cbEthAlloc truncates with
    // a large remainder. The residue must still be swept into Morpho (no dust).
    function test_AF2_truncatingSplit_remainderToMorpho() public {
        uint16 bps = 3333; // 33.33% → guaranteed truncation
        uint256 amt = 10_000_001; // 10.000001 USDC, odd tail to force a remainder

        vm.prank(MERCHANT);
        payments.setCbEthBps(bps);

        usdc.mint(address(payments), amt);
        _armSuccessfulLegs();
        vm.warp(block.timestamp + 7 days);
        _freshOracles();

        uint256 cbEthAlloc = (amt * bps) / 10000; // floors
        uint256 morphoAlloc = amt - cbEthAlloc;
        // Confirm this case actually truncates (otherwise it wouldn't test the residue path).
        assertTrue((amt * bps) % 10000 != 0, "test setup: chosen amt/bps do not truncate");

        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);

        assertEq(usdc.balanceOf(address(payments)), 0, "AF-2: truncation left dust");
        assertEq(morpho.shares(address(payments)), morphoAlloc, "AF-2: truncation remainder not in Morpho leg");
    }

    // -----------------------------------------------------------------------
    // AF-8 — setCbEthBps is bounded to [1000, 9000]. Neither leg can be zeroed
    // by a config call; max+/min- revert InvalidBpsRange.
    // -----------------------------------------------------------------------
    function test_AF8_setCbEthBps_belowMin_reverts() public {
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        payments.setCbEthBps(999);
    }

    function test_AF8_setCbEthBps_aboveMax_reverts() public {
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        payments.setCbEthBps(9001);
    }

    function test_AF8_setCbEthBps_zero_reverts() public {
        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
        payments.setCbEthBps(0);
    }

    function test_AF8_setCbEthBps_boundariesAccepted() public {
        vm.startPrank(MERCHANT);
        payments.setCbEthBps(1000);
        assertEq(payments.cbEthBps(), 1000, "AF-8: min boundary rejected");
        payments.setCbEthBps(9000);
        assertEq(payments.cbEthBps(), 9000, "AF-8: max boundary rejected");
        payments.setCbEthBps(5000);
        assertEq(payments.cbEthBps(), 5000, "AF-8: mid value rejected");
        vm.stopPrank();
    }

    function testFuzz_AF8_setCbEthBps_bound(uint16 bps) public {
        vm.prank(MERCHANT);
        if (bps < 1000 || bps > 9000) {
            vm.expectRevert(PossessioPayments.InvalidBpsRange.selector);
            payments.setCbEthBps(bps);
        } else {
            payments.setCbEthBps(bps);
            assertEq(payments.cbEthBps(), bps, "AF-8: in-range value not stored");
        }
    }

    // -----------------------------------------------------------------------
    // AF-14 — the cbETH/ETH oracle is validated at sweep entry. A stale or
    // non-positive feed reverts before any swap. (The composite USDC/ETH
    // fail-closed floor is locked in PossessioPayments_P1CompositeOracleFailOpen.)
    // -----------------------------------------------------------------------
    function test_AF14_staleCbEthFeed_revertsSweep() public {
        usdc.mint(address(payments), 1000 * 1e6);
        _armSuccessfulLegs();
        vm.warp(block.timestamp + 7 days);
        // All feeds fresh EXCEPT cbETH/ETH, staled just past its window.
        clDai.setUpdatedAt(block.timestamp);
        clUsdcUsd.setUpdatedAt(block.timestamp);
        clEthUsd.setUpdatedAt(block.timestamp);
        clEth.setUpdatedAt(block.timestamp - (payments.ORACLE_STALE_CBETH() + 1));

        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.OracleStale.selector);
        payments.sweep(0, 0, 0);
    }

    function test_AF14_nonPositiveCbEthAnswer_revertsSweep() public {
        usdc.mint(address(payments), 1000 * 1e6);
        _armSuccessfulLegs();
        vm.warp(block.timestamp + 7 days);
        _freshOracles();
        clEth.setAnswer(0); // non-positive exchange rate

        vm.prank(MERCHANT);
        vm.expectRevert(PossessioPayments.OracleInvalid.selector);
        payments.sweep(0, 0, 0);
    }

    // Positive control: with all feeds fresh and legs armed, the sweep SUCCEEDS.
    // Guarantees the AF-14 reverts above are caused by the staleness, not by an
    // unrelated failure in the harness.
    function test_AF14_control_freshFeeds_sweepSucceeds() public {
        usdc.mint(address(payments), 1000 * 1e6);
        _armSuccessfulLegs();
        vm.warp(block.timestamp + 7 days);
        _freshOracles();

        vm.prank(MERCHANT);
        payments.sweep(0, 0, 0);

        assertEq(usdc.balanceOf(address(payments)), 0, "control: sweep did not consume USDC");
    }
}
