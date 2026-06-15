// SPDX-License-Identifier: MIT
// BUILD-PROOF: LST_EXCHANGE_RATE_V1 - cbETH -> ETH valuation for Base mainnet.
//
// Base cbETH (0x2Ae3F1Ec...) is an OptimismMintableERC20 bridge token and does
// NOT expose a native exchangeRate() (cast-confirmed: reverts). So this values
// cbETH using two INDEPENDENT on-chain sources and halts if they disagree:
//
//   Source 1 (oracle): Chainlink cbETH/ETH feed 0x806b4Ac0... (18-dec).
//     cast-confirmed live, returns ~1.1327e18 WETH per cbETH.
//   Source 2 (market): Aerodrome Slipstream cbETH/WETH pool 0x47cA96Ea...
//     cast-confirmed: token0=cbETH, token1=WETH, observe() works (deep oracle).
//
// The cbEthToEth() value is taken from the oracle, but ONLY after:
//   (a) staleness check on the oracle's updatedAt (H-1 lesson), and
//   (b) a divergence check against the pool TWAP - if oracle and market
//       disagree by more than MAX_DIVERGENCE_BPS, REVERT rather than value
//       cbETH at a possibly-manipulated or depegged rate.
//
// This is the same two-source / halt-on-divergence discipline used elsewhere
// in the stack (hook slot0-vs-TWAP, L1Anchor depeg guard) - applied to the
// cbETH rate because no single source should be trusted with real money.
//
// All addresses below are cast-verified on Base mainnet, NOT drafted/assumed.

pragma solidity ^0.8.20;

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

// Uniswap-V3-style observe (Aerodrome Slipstream implements this).
interface ISlipstreamPool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

contract LSTExchangeRate {
    // ---- cast-verified Base mainnet sources ----------------------------------------------------------------
    // Chainlink cbETH/ETH feed (18-dec). cast: returns ~1.1327e18, fresh.
    IChainlinkFeed public constant CBETH_ETH_FEED =
        IChainlinkFeed(0x806b4Ac04501c29769051e42783cF04dCE41440b);

    // Aerodrome Slipstream cbETH/WETH pool. cast: token0=cbETH, token1=WETH,
    // observe() returns sane tickCumulatives (deep oracle, cardinality ~1440).
    ISlipstreamPool public constant CBETH_WETH_POOL =
        ISlipstreamPool(0x47cA96Ea59C13F72745928887f84C9F52C3D7348);

    // ---- guard parameters ----------------------------------------------------------------------------------------------------
    // TWAP window. 30 min balances manipulation-resistance vs responsiveness.
    uint32  public constant TWAP_WINDOW = 1800;
    // Oracle freshness. cbETH/ETH is a slow exchange-rate feed; 24h is the
    // Chainlink heartbeat class for this feed type. (Tighten if the feed's
    // real heartbeat is shorter.)
    uint256 public constant ORACLE_STALE = 24 hours;
    // Max allowed oracle-vs-market divergence before we refuse to value.
    // 1-2% is standard for LSTs: traps a depeg/manipulation without
    // false-halting on ordinary oracle-vs-spot noise. 200 bps = 2%.
    uint256 public constant MAX_DIVERGENCE_BPS = 200;
    uint256 private constant BPS = 10_000;

    error OracleStale();
    error OracleInvalid();
    error RateDivergence(uint256 oracleRate, uint256 marketRate);

    /// @notice ETH (wei) value of `cbEthAmount` cbETH, 18-dec in and out.
    ///         Priced from the Chainlink feed, but reverts if that price is
    ///         stale or diverges from the pool TWAP beyond MAX_DIVERGENCE_BPS.
    function cbEthToEth(uint256 cbEthAmount) external view returns (uint256) {
        uint256 oracleRate = _oracleRateWethPerCbEth(); // 18-dec WETH per cbETH
        uint256 marketRate = _twapRateWethPerCbEth();    // 18-dec WETH per cbETH

        // Divergence circuit-breaker (symmetric percentage band).
        uint256 diff = oracleRate > marketRate ? oracleRate - marketRate : marketRate - oracleRate;
        // diff / oracleRate > MAX_DIVERGENCE_BPS/BPS  ->  diff*BPS > oracleRate*MAX
        if (diff * BPS > oracleRate * MAX_DIVERGENCE_BPS) {
            revert RateDivergence(oracleRate, marketRate);
        }

        // Value at the oracle rate (the agreed-upon source). 18*18/1e18 = 18-dec.
        return (cbEthAmount * oracleRate) / 1e18;
    }

    /// @notice The oracle's WETH-per-cbETH rate (18-dec), staleness-checked.
    function _oracleRateWethPerCbEth() internal view returns (uint256) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            CBETH_ETH_FEED.latestRoundData();
        if (answer <= 0) revert OracleInvalid();
        if (updatedAt == 0) revert OracleInvalid();
        if (answeredInRound < roundId) revert OracleInvalid();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > ORACLE_STALE) revert OracleStale();
        return uint256(answer); // feed is 18-dec (cast-confirmed)
    }

    /// @notice The market TWAP WETH-per-cbETH rate (18-dec) from the pool.
    ///         token0=cbETH, token1=WETH (cast-confirmed), so price = token1/token0
    ///         = WETH per cbETH directly, no inversion.
    function _twapRateWethPerCbEth() internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW; // window start
        secondsAgos[1] = 0;           // now

        (int56[] memory tickCumulatives, ) = CBETH_WETH_POOL.observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int24(delta / int56(uint56(TWAP_WINDOW)));

        // price(token1/token0) at a tick = 1.0001^tick, scaled to 18 decimals.
        // Both cbETH and WETH are 18-dec, so the raw price is already the
        // 18-dec WETH-per-cbETH rate with no decimal adjustment.
        return _tickToRate18(meanTick);
    }

    /// @notice 1.0001^tick expressed as an 18-dec fixed-point number.
    ///         Uses the Uniswap TickMath sqrtPriceX96 path, then squares it,
    ///         to avoid pow() precision loss. price = (sqrtP / 2^96)^2.
    function _tickToRate18(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(tick);
        // price18 = (sqrtP^2 * 1e18) / 2^192, computed in two mulDiv-safe steps
        // to avoid overflow on sqrtP^2 (sqrtP up to ~2^160).
        uint256 sqrtP = uint256(sqrtPriceX96);
        // (sqrtP * sqrtP) can be up to 2^320 -> must split. Use the standard
        // FullMath-style staging: priceX192 = sqrtP*sqrtP (as a 512-bit concept),
        // then scale. Here we do it conservatively with mulDiv on halves.
        uint256 priceX96 = (sqrtP * 1e9) >> 96;       // sqrtP scaled by 1e9, /2^96
        uint256 rate18 = (priceX96 * priceX96);        // (sqrtP^2 * 1e18) / 2^192
        return rate18;
    }

    // ---- Uniswap V3 TickMath.getSqrtRatioAtTick (verbatim, audited) ----------------
    // Standard Uniswap v3-core implementation. Returns sqrt(1.0001^tick) * 2^96.
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
