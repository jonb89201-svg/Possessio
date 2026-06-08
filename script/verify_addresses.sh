#!/usr/bin/env bash
# POSSESSIO deploy-substrate verification — EXTERNAL INFRA ONLY.
# STEEL, Treasury, PLATE-v1 dropped — those come from our own deploy records,
# not Gemini's gathering. This checks only the canonical Base addresses we
# genuinely need verified, plus the contract's one hardcoded pool.
#
# Each probe is self-labeled so the output is unambiguous in one dump.
# Gemini GATHERED these; cast VERIFIES them. Any FLAG = stop, do not deploy.
#
# RUN:
#   export BASE_RPC="https://mainnet.base.org"     # or your provider URL
#   bash verify_addresses.sh
#
# Read each result against its "want:" line.

R="--rpc-url $BASE_RPC"

echo "=== 1. DAI symbol (DISCREPANCY: Gemini ...D18C41 vs Claude ...DB0Cb) ==="
echo "--- 1a Gemini's value ---  want: DAI"
cast call 0x50c5725949A6F0c72E6C4a641F24049A91D18C41 "symbol()(string)" $R
echo "--- 1b Claude's recalled value ---  want: DAI (only one of 1a/1b should be DAI)"
cast call 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb "symbol()(string)" $R

echo "=== 2. DAI decimals (Gemini value) ===  want: 18"
cast call 0x50c5725949A6F0c72E6C4a641F24049A91D18C41 "decimals()(uint8)" $R

echo "=== 3. WETH symbol/decimals ===  want: WETH / 18"
cast call 0x4200000000000000000000000000000000000006 "symbol()(string)" $R
cast call 0x4200000000000000000000000000000000000006 "decimals()(uint8)" $R

echo "=== 4. cbETH symbol/decimals ===  want: cbETH / 18"
cast call 0x2Ae3F1Ec77C0217FE618f3a7C5999D6874dEc22b "symbol()(string)" $R
cast call 0x2Ae3F1Ec77C0217FE618f3a7C5999D6874dEc22b "decimals()(uint8)" $R

echo "=== 5. Chainlink cbETH/ETH feed decimals ===  MUST be 18 (constructor revert gate)"
cast call 0xf017fc87e21c055967094b99d06bc0326444483b "decimals()(uint8)" $R

echo "=== 6. Chainlink DAI/ETH feed decimals ===  MUST be 8 (constructor revert gate)"
cast call 0x7bb6f69ae0fbf839158309503460e4b7b25867a1 "decimals()(uint8)" $R

echo "=== 7. Chainlink cbETH/ETH latestRoundData (freshness/sanity) ==="
cast call 0xf017fc87e21c055967094b99d06bc0326444483b "latestRoundData()(uint80,int256,uint256,uint256,uint80)" $R

echo "=== 8. Chainlink DAI/ETH latestRoundData (freshness/sanity) ==="
cast call 0x7bb6f69ae0fbf839158309503460e4b7b25867a1 "latestRoundData()(uint80,int256,uint256,uint256,uint80)" $R

echo "=== 9. V4 PoolManager has code ===  want: 0x + bytecode (not bare 0x)"
cast code 0x000000000004444c530000300000000022300000 $R | head -c 20; echo

echo "=== 10. V3 SwapRouter02 has code ===  want: 0x + bytecode"
cast code 0x2626664c2603316E0473a2216f9de89587979f42 $R | head -c 20; echo

echo "=== 11. Aerodrome Slipstream Router has code ===  want: 0x + bytecode"
cast code 0xbe7D1Fd1f6748bbDefC4fbaCafBb11C6Fc506d1d $R | head -c 20; echo

echo "=== 12. Hardcoded Aero cbETH/WETH pool token0 ===  want: 0x2Ae3F1Ec...dEc22b (cbETH)"
cast call 0x47cA96Ea59C13F72745928887f84C9F52C3D7348 "token0()(address)" $R
echo "=== 12b. ...token1 ===  want: 0x4200...0006 (WETH)"
cast call 0x47cA96Ea59C13F72745928887f84C9F52C3D7348 "token1()(address)" $R

echo "=== 13. V3 WETH/DAI pool fee + depth (Gemini named 0xD37f...7249) ==="
echo "--- fee ---  want: 500 (matches contract DAI_V3_FEE)"
cast call 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 "fee()(uint24)" $R
echo "--- DAI balance in pool ---  want: sizeable"
cast call 0x50c5725949A6F0c72E6C4a641F24049A91D18C41 "balanceOf(address)(uint256)" 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 $R
echo "--- WETH balance in pool ---  want: sizeable"
cast call 0x4200000000000000000000000000000000000006 "balanceOf(address)(uint256)" 0xD37f0775d5eAbe1288B16719717C2fBA369d7249 $R

echo "=== 14. Aero cbETH/WETH pool depth ==="
echo "--- cbETH balance ---  want: sizeable"
cast call 0x2Ae3F1Ec77C0217FE618f3a7C5999D6874dEc22b "balanceOf(address)(uint256)" 0x47cA96Ea59C13F72745928887f84C9F52C3D7348 $R
echo "--- WETH balance ---  want: sizeable"
cast call 0x4200000000000000000000000000000000000006 "balanceOf(address)(uint256)" 0x47cA96Ea59C13F72745928887f84C9F52C3D7348 $R

echo "=== DONE — any blank/revert/wrong-symbol/wrong-decimals = FLAG, do not deploy ==="
