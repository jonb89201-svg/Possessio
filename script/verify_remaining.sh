#!/usr/bin/env bash
# POSSESSIO — verify ONLY the rate-limit-confounded addresses from round 1.
# Already CONFIRMED (do not re-probe): DAI ...DB0Cb, WETH, real cbETH (pool token0),
# Aero cbETH/WETH pool (real depth). Gemini's DAI & cbETH were HALLUCINATED (empty).
#
# This script: the unconfirmed ones — feeds, V4 mgr, V3 router, Aero router,
# and the suspect V3 WETH/DAI pool (Gemini's 0xD37f...). sleep 2 between calls so a
# public RPC won't 429. Use a provider URL if you have one (read-only, NOT a deploy key).
#
# RUN:
#   export BASE_RPC="https://mainnet.base.org"     # or provider read URL
#   bash script/verify_remaining.sh 2>&1 | tee addr_verify2.txt

R="--rpc-url $BASE_RPC"
S() { sleep 2; }

echo "=== A. Chainlink cbETH/ETH feed (Gemini 0xf017...483b) ===  decimals MUST be 18"
cast call 0xf017fc87e21c055967094b99d06bc0326444483b "decimals()(uint8)" $R; S

echo "=== B. Chainlink DAI/ETH feed (Gemini 0x7bb6...67a1) ===  decimals MUST be 8"
cast call 0x7bb6f69ae0fbf839158309503460e4b7b25867a1 "decimals()(uint8)" $R; S

echo "=== C. V4 PoolManager (Gemini 0x0000...300000) ===  want: 0x + bytecode"
cast code 0x000000000004444c530000300000000022300000 $R | head -c 20; echo; S

echo "=== D. V3 SwapRouter02 (Gemini 0x2626...9f42) ===  want: 0x + bytecode"
cast code 0x2626664c2603316E0473a2216f9de89587979f42 $R | head -c 20; echo; S

echo "=== E. Aerodrome Slipstream Router (Gemini 0xbe7D...6d1d) ===  want: 0x + bytecode"
cast code 0xbe7D1Fd1f6748bbDefC4fbaCafBb11C6Fc506d1d $R | head -c 20; echo; S

echo "=== F. V3 WETH/DAI pool (Gemini 0xD37f...7249) — SUSPECT (came back no-code rd1) ==="
echo "--- F1 fee ---  want: 500 (matches contract DAI_V3_FEE). 'no code' = WRONG POOL."
cast call 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 "fee()(uint24)" $R; S
echo "--- F2 token0 ---  (want WETH or DAI)"
cast call 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 "token0()(address)" $R; S
echo "--- F3 token1 ---"
cast call 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 "token1()(address)" $R; S
echo "--- F4 WETH depth in pool ---  want: sizeable"
cast call 0x4200000000000000000000000000000000000006 "balanceOf(address)(uint256)" 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 $R; S
echo "--- F5 DAI depth (real DAI ...DB0Cb) ---  want: sizeable"
cast call 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb "balanceOf(address)(uint256)" 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 $R

echo "=== DONE — any 'no code' on a CLEAN (non-429) run = address is WRONG, find the real one ==="
