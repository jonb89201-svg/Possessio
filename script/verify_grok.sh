#!/usr/bin/env bash
# POSSESSIO — ONE-RUN verification. Grok's plausible addresses + on-chain pool/feed
# derivation. No model is trusted; cast + on-chain factory/registry are the arbiter.
# sleep 2 between calls to dodge public-RPC 429.
#
# RUN:
#   export BASE_RPC="https://mainnet.base.org"
#   bash script/verify_grok.sh 2>&1 | tee grok_verify.txt

R="--rpc-url $BASE_RPC"
S() { sleep 2; }
WETH=0x4200000000000000000000000000000000000006
DAI=0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb     # CONFIRMED real DAI

echo "############ PART 1: Grok's plausible addresses (probe for code) ############"

echo "=== 1. Chainlink cbETH/ETH feed (0x806b...440b) === want: code + decimals 18"
cast code 0x806b4Ac04501c29769051e42783cF04dCE41440b $R | head -c 14; echo; S
cast call 0x806b4Ac04501c29769051e42783cF04dCE41440b "decimals()(uint8)" $R; S

echo "=== 3. V4 PoolManager (0x498581ff...2b2b) === want: code"
cast code 0x498581ff718922c3f8e6a244956af099b2652b2b $R | head -c 14; echo; S

echo "=== 4. V3 SwapRouter02 HEAD-TO-HEAD ==="
echo "--- 4a Grok 0x2626664c2603336E57B271c5C0b26F421741e481 --- want: code"
cast code 0x2626664c2603336E57B271c5C0b26F421741e481 $R | head -c 14; echo; S
echo "--- 4b Gemini 0x2626664c2603316E0473a2216f9de89587979f42 --- want: code"
cast code 0x2626664c2603316E0473a2216f9de89587979f42 $R | head -c 14; echo; S

echo "=== 5. Aerodrome Slipstream Router (0xcF77a3Ba...4E43) === want: code"
cast code 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43 $R | head -c 14; echo; S

echo "############ PART 2: WETH/DAI pool — DERIVED from factory (on-chain truth) ############"
echo "=== 6a factory has code? (0x3312...FDfD) ==="
cast code 0x33128a8fC17869897dcE68Ed026d694621f6FDfD $R | head -c 14; echo; S
echo "=== 6b getPool(WETH,DAI,500) -> real pool (0x000...0 = no fee-500 pool exists) ==="
POOL=$(cast call 0x33128a8fC17869897dcE68Ed026d694621f6FDfD "getPool(address,address,uint24)(address)" $WETH $DAI 500 $R); S
echo "   derived pool: $POOL"
echo "=== 6c also try fee 100 and 3000 in case 500 pool doesn't exist ==="
echo "--- fee 100 ---"
cast call 0x33128a8fC17869897dcE68Ed026d694621f6FDfD "getPool(address,address,uint24)(address)" $WETH $DAI 100 $R; S
echo "--- fee 3000 ---"
cast call 0x33128a8fC17869897dcE68Ed026d694621f6FDfD "getPool(address,address,uint24)(address)" $WETH $DAI 3000 $R; S

echo "=== 6d if POOL is non-zero, verify it (fee/tokens/depth) ==="
if [ "$POOL" != "0x0000000000000000000000000000000000000000" ] && [ -n "$POOL" ]; then
  cast call $POOL "fee()(uint24)" $R; S
  cast call $POOL "token0()(address)" $R; S
  cast call $POOL "token1()(address)" $R; S
  echo "--- WETH depth ---"; cast call $WETH "balanceOf(address)(uint256)" $POOL $R; S
  echo "--- DAI depth  ---"; cast call $DAI "balanceOf(address)(uint256)" $POOL $R; S
else
  echo "   POOL is zero/empty — no fee-500 WETH/DAI pool. Check 6c fee tiers."
fi

echo "############ PART 3: DAI/ETH feed — NO MODEL. Derive intent on-chain. ############"
echo "=== 7. Chainlink Feed Registry on Base (if deployed) — query DAI/ETH directly ==="
echo "    Chainlink Feed Registry (mainnet pattern) — try the Base registry if it exists."
echo "    DAI denom = 0x0000000000000000000000000000000000000000 (ETH) per CL convention."
echo "    NOTE: Base may NOT have the Feed Registry deployed. If this reverts, the"
echo "    DAI/ETH feed must come from data.chain.link/base page directly (human/web)."
REG=0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf   # CL Feed Registry (Eth mainnet addr; Base may differ/absent)
cast code $REG $R | head -c 14; echo "   <- if 0x, registry not at this addr on Base"; S

echo "############ SUMMARY ############"
echo "CONFIRMED already: WETH, DAI(...DB0Cb), Aero pool(0x47cA96...), cbETH(pool token0)."
echo "This run resolves: cbETH/ETH feed, V4 mgr, V3 router(4a/4b), Aero router, WETH/DAI pool(derived)."
echo "DAI/ETH feed: get from data.chain.link Base page directly, then cast decimals()==8."
echo "Any 'no code'/0x000 = wrong/absent. Code+right decimals/fee = real."
