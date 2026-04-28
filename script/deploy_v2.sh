#!/bin/bash
# ============================================================
# POSSESSIO V2 (PLATE/STEEL) DEPLOYMENT RUNBOOK
# Mobile Nomad Standard | Codespaces + Foundry | MIB Rule 1
# ============================================================
# This is a RUNBOOK, not an automated script.
#
# Each step is a separate cast send command. Run one at a time.
# Wait for confirmation. Verify output. Run next.
#
# Architect can step through this manually OR run as script if
# all variables are pre-set and confidence is high. Recommended:
# step through manually for first deployment.
#
# DEPLOYMENT BUDGET: ~$130 in ETH. Rough gas estimates per step:
#   Step 1 (deploy STEEL):        ~$3-8
#   Step 2 (mine hook):           $0 (off-chain compute)
#   Step 3 (deploy hook):         ~$5-15
#   Step 4 (initialize pool):     ~$1-3
#   Step 5 (register pool):       ~$0.50-1
#   Step 6 (approve STEEL):       ~$0.30-0.50
#   Step 7 (unwrap WETH):         ~$0.30-0.50
#   Step 8 (seed liquidity):      ~$2-5
#   Total estimated:              ~$12-33
#   Buffer:                       ~$95-118 (for retries, MEV, congestion)
#
# PRE-DEPLOYMENT CHECKLIST:
#   [ ] V2 contracts certified (272+ tests passing, 0 failures)
#   [ ] PFG v1.5.0-rev2 dry-run passed against V4 calibration target
#   [ ] sqrtPriceX96 value verified by Gemini's seat for 360M/0.11 ETH ratio
#   [ ] WETH balance: ≥ 0.11 WETH in deployer wallet
#   [ ] ETH balance: ≥ $130 worth in deployer wallet (for gas)
#   [ ] Treasury Safe deployed and confirmed
#   [ ] Council member addresses confirmed and stored
#   [ ] All required addresses in env (cbETH, DAI, oracles, V3 router)
#
# ============================================================

set -euo pipefail

# ============================================================
# REQUIRED ENVIRONMENT VARIABLES
# ============================================================
: "${RPC_URL:?Set Base mainnet RPC (private RPC strongly recommended)}"
: "${DEPLOYER_PK:?Set deployer private key}"
: "${DEPLOYER_ADDRESS:?Set deployer address}"
: "${TREASURY_SAFE:?Set Treasury Safe address}"
: "${COUNCIL_0:?Set Gemini council address}"
: "${COUNCIL_1:?Set ChatGPT council address}"
: "${COUNCIL_2:?Set Claude council address}"
: "${COUNCIL_3:?Set Grok council address}"
: "${SQRT_PRICE_X96:?Set sqrtPriceX96 (verified by Gemini for 360M/0.11 ETH ratio)}"

# ============================================================
# VERIFIED ADDRESSES (Base mainnet)
# ============================================================
POOL_MANAGER="0x498581fF718922c3f8e6A244956aF099B2652b2b"
WETH="0x4200000000000000000000000000000000000006"
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

# These need verification before running — placeholder addresses
# from V1 architecture. Confirm each is current on Base mainnet.
CBETH_ADDR="${CBETH_ADDR:-0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22}"  # Coinbase cbETH on Base
DAI_ADDR="${DAI_ADDR:-0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb}"      # DAI on Base
CHAINLINK_CBETH_ETH="${CHAINLINK_CBETH_ETH:-0x806b4Ac04501c29769051e42783cF04dCE41440b}"  # cbETH/ETH feed
CHAINLINK_DAI_ETH="${CHAINLINK_DAI_ETH:-0xD1092a65338d049DB68D7Be6bD89d17a0929945e}"      # DAI/ETH feed
V3_ROUTER="${V3_ROUTER:-0x2626664c2603336E57B271c5C0b26F421741e481}"   # Uniswap V3 SwapRouter on Base

# Pool parameters
POOL_FEE=0
POOL_TICK_SPACING=200
ETH_AMOUNT="110000000000000000"   # 0.11 ETH in wei
STEEL_AMOUNT="360000000000000000000000000"  # 360M STEEL × 10^18

# ============================================================
# STEP 1: DEPLOY STEEL TOKEN
# ============================================================
# STEEL is a clean ERC20Permit token. Constructor mints 1B
# tokens (TOTAL_SUPPLY) to deployer. Deploy first because the
# hook constructor needs the STEEL address.
#
# Run this command:
#
# forge create src/POSSESSIO_v2.sol:STEEL \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK \
#     --broadcast
#
# Save the deployed address as STEEL_ADDR for subsequent steps.
# Verify with:
#
# cast call $STEEL_ADDR "totalSupply()(uint256)" --rpc-url $RPC_URL
# # Expected: 1000000000000000000000000000 (1B × 10^18)
#
# cast call $STEEL_ADDR "balanceOf(address)(uint256)" $DEPLOYER_ADDRESS \
#     --rpc-url $RPC_URL
# # Expected: same as totalSupply (deployer has all tokens)

echo "[STEP 1] Deploy STEEL token"
echo "  Run: forge create src/POSSESSIO_v2.sol:STEEL"
echo "  Then export STEEL_ADDR=<deployed address>"
echo ""

# Uncomment after manual deployment:
# : "${STEEL_ADDR:?Set deployed STEEL address from Step 1}"

# ============================================================
# STEP 2: MINE HOOK SALT (off-chain)
# ============================================================
# CREATE2 salt mining for PossessioHook address with required
# permission bits (0x8C8 in lower 14 bits).
#
# This is off-chain compute. No transactions, no gas. Mining
# typically takes 5-30 minutes on standard CPU.
#
# Set environment for the miner script:
#
# export DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS
# export STEEL_ADDR=$STEEL_ADDR
# export TREASURY_SAFE=$TREASURY_SAFE
# export CBETH_ADDR=$CBETH_ADDR
# export DAI_ADDR=$DAI_ADDR
# export CHAINLINK_CBETH_ETH=$CHAINLINK_CBETH_ETH
# export CHAINLINK_DAI_ETH=$CHAINLINK_DAI_ETH
# export V3_ROUTER=$V3_ROUTER
# export COUNCIL_0=$COUNCIL_0
# export COUNCIL_1=$COUNCIL_1
# export COUNCIL_2=$COUNCIL_2
# export COUNCIL_3=$COUNCIL_3
#
# Then run:
#
# forge script script/MineHookSalt.s.sol --rpc-url $RPC_URL
#
# Save output as:
# export HOOK_SALT=<mined salt>
# export HOOK_ADDR=<predicted address>

echo "[STEP 2] Mine hook salt"
echo "  Run: forge script script/MineHookSalt.s.sol"
echo "  Then export HOOK_SALT=<mined> and HOOK_ADDR=<predicted>"
echo ""

# ============================================================
# STEP 3: DEPLOY POSSESSIO HOOK VIA CREATE2
# ============================================================
# Deploy PossessioHook using CREATE2 with mined salt. The
# resulting address must match HOOK_ADDR (predicted from miner).
#
# Foundry's CREATE2 deployer is at:
#   0x4e59b44847b379578588920cA78FbF26c0B4956C
#
# It accepts salt-prepended bytecode. Cast send pattern:
#
# Construct deployment data:
# 1. Encode constructor params as DeployParams struct
# 2. Concatenate: salt + creationCode + abi.encode(constructorArgs)
# 3. Send to CREATE2 deployer
#
# Easier path: use forge create with --salt flag if your Foundry
# version supports it. Otherwise use the cast send pattern below.
#
# Construct DeployParams:
# DEPLOY_PARAMS=$(cast abi-encode \
#     "f((address,address,address,address,address,address,address,address,address,address,address[4]))" \
#     "($DEPLOYER_ADDRESS,$STEEL_ADDR,$POOL_MANAGER,$TREASURY_SAFE,$CBETH_ADDR,$DAI_ADDR,$CHAINLINK_CBETH_ETH,$CHAINLINK_DAI_ETH,$V3_ROUTER,$WETH,[$COUNCIL_0,$COUNCIL_1,$COUNCIL_2,$COUNCIL_3])")
#
# Deploy via forge create with salt (cleanest path):
#
# forge create src/POSSESSIO_v2.sol:PossessioHook \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK \
#     --salt $HOOK_SALT \
#     --constructor-args "($DEPLOYER_ADDRESS,$STEEL_ADDR,$POOL_MANAGER,$TREASURY_SAFE,$CBETH_ADDR,$DAI_ADDR,$CHAINLINK_CBETH_ETH,$CHAINLINK_DAI_ETH,$V3_ROUTER,$WETH,[$COUNCIL_0,$COUNCIL_1,$COUNCIL_2,$COUNCIL_3])" \
#     --broadcast
#
# Verify deployed address matches predicted:
# cast call $HOOK_ADDR "POOL_MANAGER()(address)" --rpc-url $RPC_URL
# # Expected: $POOL_MANAGER
#
# Verify hook permission bits:
# echo "obase=16; $(cast --to-dec $HOOK_ADDR) % $(echo \"obase=10; $(cast --to-dec 0x3FFF)\" | bc)" | bc
# # Expected: 8C8

echo "[STEP 3] Deploy PossessioHook via CREATE2"
echo "  Run: forge create with --salt \$HOOK_SALT"
echo "  Verify deployed address == \$HOOK_ADDR"
echo ""

# ============================================================
# STEP 4: INITIALIZE V4 POOL
# ============================================================
# PoolManager.initialize creates the pool at the specified
# sqrtPriceX96. Anyone can call initialize, but the hook must
# match what's encoded in the address bits.
#
# PoolKey for ETH/STEEL:
#   currency0:    0x0000000000000000000000000000000000000000  (native ETH)
#   currency1:    $STEEL_ADDR
#   fee:          0  (Sovereign Fee — hook captures via beforeSwap)
#   tickSpacing:  200
#   hooks:        $HOOK_ADDR
#
# Run:
#
# cast send $POOL_MANAGER \
#     "initialize((address,address,uint24,int24,address),uint160)" \
#     "(0x0000000000000000000000000000000000000000,$STEEL_ADDR,$POOL_FEE,$POOL_TICK_SPACING,$HOOK_ADDR)" \
#     "$SQRT_PRICE_X96" \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK
#
# Verify pool exists by reading slot0:
#
# POOL_KEY_ENCODED=$(cast abi-encode \
#     "f((address,address,uint24,int24,address))" \
#     "(0x0000000000000000000000000000000000000000,$STEEL_ADDR,$POOL_FEE,$POOL_TICK_SPACING,$HOOK_ADDR)")
# POOL_ID=$(cast keccak "0x${POOL_KEY_ENCODED:10}")
#
# cast call 0xa3c0c9b65bad0b08107aa264b0f3db444b867a71 \
#     "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
#     $POOL_ID --rpc-url $RPC_URL
# # Expected: sqrtPriceX96 matches what we set

echo "[STEP 4] Initialize V4 pool with verified sqrtPriceX96"
echo "  PoolKey: (0x0, \$STEEL_ADDR, 0, 200, \$HOOK_ADDR)"
echo "  sqrtPriceX96: \$SQRT_PRICE_X96"
echo ""

# ============================================================
# STEP 5: REGISTER POOL IN HOOK
# ============================================================
# PossessioHook.registerPool stores the PoolKey in hook state.
# Hook checks that key.hooks == address(this). One-time only
# (poolInitialized flag prevents re-registration).
#
# Run:
#
# cast send $HOOK_ADDR \
#     "registerPool((address,address,uint24,int24,address))" \
#     "(0x0000000000000000000000000000000000000000,$STEEL_ADDR,$POOL_FEE,$POOL_TICK_SPACING,$HOOK_ADDR)" \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK
#
# Verify:
#
# cast call $HOOK_ADDR "poolInitialized()(bool)" --rpc-url $RPC_URL
# # Expected: true

echo "[STEP 5] Register pool in hook"
echo "  Run: cast send registerPool(PoolKey)"
echo "  Verify: poolInitialized() returns true"
echo ""

# ============================================================
# STEP 6: APPROVE HOOK TO SPEND STEEL
# ============================================================
# seedInitialLiquidity uses safeTransferFrom to pull STEEL from
# deployer. Approval required.
#
# Run:
#
# cast send $STEEL_ADDR \
#     "approve(address,uint256)" \
#     $HOOK_ADDR \
#     $STEEL_AMOUNT \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK
#
# Verify:
#
# cast call $STEEL_ADDR "allowance(address,address)(uint256)" \
#     $DEPLOYER_ADDRESS $HOOK_ADDR \
#     --rpc-url $RPC_URL
# # Expected: 360000000000000000000000000

echo "[STEP 6] Approve hook to spend 360M STEEL"
echo "  Run: cast send STEEL.approve(\$HOOK_ADDR, 360M × 10^18)"
echo ""

# ============================================================
# STEP 7: UNWRAP WETH TO NATIVE ETH
# ============================================================
# Pool's currency0 is native ETH. seedInitialLiquidity expects
# msg.value to match ethAmount. WETH must be unwrapped first.
#
# Run:
#
# cast send $WETH "withdraw(uint256)" $ETH_AMOUNT \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK
#
# Verify deployer has 0.11 ETH+ in native:
#
# cast balance $DEPLOYER_ADDRESS --rpc-url $RPC_URL
# # Expected: ≥ 0.11 ETH (plus gas reserve)

echo "[STEP 7] Unwrap 0.11 WETH to native ETH"
echo "  Run: cast send WETH.withdraw(0.11 ETH)"
echo "  Verify deployer ETH balance ≥ 0.11"
echo ""

# ============================================================
# STEP 8: SEED INITIAL LIQUIDITY
# ============================================================
# Calls PossessioHook.seedInitialLiquidity with msg.value =
# ethAmount. Hook pulls STEEL via safeTransferFrom (allowance
# from Step 6), unlocks PoolManager, mints full-range LP.
#
# Run:
#
# cast send $HOOK_ADDR \
#     "seedInitialLiquidity(uint256,uint256)" \
#     $ETH_AMOUNT \
#     $STEEL_AMOUNT \
#     --rpc-url $RPC_URL \
#     --private-key $DEPLOYER_PK \
#     --value $ETH_AMOUNT
#
# Verify pool has liquidity:
#
# cast call 0xa3c0c9b65bad0b08107aa264b0f3db444b867a71 \
#     "getLiquidity(bytes32)(uint128)" \
#     $POOL_ID --rpc-url $RPC_URL
# # Expected: non-zero, > 0

echo "[STEP 8] Seed initial liquidity (0.11 ETH + 360M STEEL)"
echo "  Run: cast send seedInitialLiquidity(...) --value 0.11 ETH"
echo "  Verify: getLiquidity(POOL_ID) > 0"
echo ""

# ============================================================
# DEPLOYMENT COMPLETE
# ============================================================
echo "═══════════════════════════════════════════════"
echo "POST-DEPLOYMENT VERIFICATION CHECKLIST"
echo "═══════════════════════════════════════════════"
echo ""
echo "[ ] STEEL_ADDR deployed and verified on Basescan"
echo "[ ] HOOK_ADDR deployed and matches predicted address"
echo "[ ] HOOK_ADDR & 0x3FFF == 0x8C8 (permission bits correct)"
echo "[ ] Pool initialized at correct sqrtPriceX96"
echo "[ ] poolInitialized() == true in hook"
echo "[ ] Pool has non-zero liquidity"
echo "[ ] PFG v1.5.0-rev2 deployment-mode dry run passes"
echo "[ ] Update README with deployed addresses"
echo "[ ] Update RATIFIED_COMMIT to deployment commit"
echo "[ ] Verify contracts on Basescan (forge verify-contract)"
echo ""
echo "Deployed addresses to record in council statement:"
echo "  STEEL_ADDR:     <fill in>"
echo "  HOOK_ADDR:      <fill in>"
echo "  POOL_ID:        <derive from PoolKey>"
echo "  Initial LP:     0.11 ETH + 360,000,000 STEEL"
echo "  Launch ratio:   ~3.27B STEEL per ETH"
echo "═══════════════════════════════════════════════"
