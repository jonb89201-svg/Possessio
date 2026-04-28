#!/bin/bash
# ============================================================
# poolid_check.sh — PoolId Slice Validator
# ============================================================
# Purpose:
#   Verify the cast abi-encode slice index used in
#   sal_pfg_v1.5.0.sh for V4 PoolId derivation.
#
#   sal_pfg line 227 strips 10 chars from the abi-encode output
#   on the assumption that cast prepends a 4-byte function
#   selector. In modern Foundry, `cast abi-encode` does NOT
#   prepend a selector — only `cast calldata` does. If that's
#   true here, the script is stripping the first 4 bytes of
#   currency0 and producing garbage PoolIds.
#
#   This validator probes a known Base V4 pool both ways and
#   reports which slice returns nonzero liquidity. Whichever
#   works is the correct slice for sal_pfg.
#
# Reference pool:
#   ETH/USDC, fee=500, tickSpacing=10, no hooks on Base V4
#
# Usage:
#   set -a && source .env.secret && set +a
#   bash script/poolid_check.sh
#
# Required env:
#   RPC_URL — Base mainnet RPC
# ============================================================

set -euo pipefail

: "${RPC_URL:?Not set}"

STATE_VIEW="0xa3c0c9b65bad0b08107aa264b0f3db444b867a71"

# Known V4 reference pool on Base: ETH/USDC, fee=500, tickSpacing=10, no hooks
C0="0x0000000000000000000000000000000000000000"
C1="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
FEE=500
TS=10
HOOKS="0x0000000000000000000000000000000000000000"

echo ""
echo "════════════════════════════════════════════════"
echo "  PoolId Slice Validator"
echo "  Reference: ETH/USDC 500/10/no-hooks on Base V4"
echo "════════════════════════════════════════════════"
echo ""

# Encode PoolKey
ENC=$(cast abi-encode "f((address,address,uint24,int24,address))" \
    "($C0,$C1,$FEE,$TS,$HOOKS)")

echo "Raw abi-encode output:"
echo "  $ENC"
echo "  hex chars after 0x: $(( ${#ENC} - 2 ))"
echo ""

# Candidate A: strip "0x" + 8 selector chars (sal_pfg's current assumption)
ID_A=$(cast keccak "0x${ENC:10}")

# Candidate B: strip "0x" only (no selector — modern cast behavior)
ID_B=$(cast keccak "0x${ENC:2}")

echo "Candidate A (slice :10, assumes selector present):"
echo "  PoolId: $ID_A"
echo ""
echo "Candidate B (slice :2, no selector prefix):"
echo "  PoolId: $ID_B"
echo ""

# Probe StateView for each
echo "Querying StateView.getLiquidity for both candidates..."
LIQ_A_RAW=$(cast call "$STATE_VIEW" "getLiquidity(bytes32)(uint128)" "$ID_A" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
LIQ_B_RAW=$(cast call "$STATE_VIEW" "getLiquidity(bytes32)(uint128)" "$ID_B" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

LIQ_A=$(echo "$LIQ_A_RAW" | head -1 | awk '{print $1}' | tr -d '[:space:]')
LIQ_B=$(echo "$LIQ_B_RAW" | head -1 | awk '{print $1}' | tr -d '[:space:]')

echo "  A liquidity: ${LIQ_A:-<empty>}"
echo "  B liquidity: ${LIQ_B:-<empty>}"
echo ""

# Verdict
echo "════════════════════════════════════════════════"
if [[ -n "$LIQ_A" && "$LIQ_A" != "0" ]]; then
    echo "✅ VERDICT: Slice :10 is CORRECT."
    echo "   sal_pfg_v1.5.0.sh line 227 is right as-is. No patch needed."
elif [[ -n "$LIQ_B" && "$LIQ_B" != "0" ]]; then
    echo "⚠️  VERDICT: Slice :2 is correct — SCRIPT HAS THE BUG."
    echo ""
    echo "   Patch sal_pfg_v1.5.0.sh line 227:"
    echo "     - POOL_KEY_BYTES=\"\${POOL_KEY_ENCODED:10}\""
    echo "     + POOL_KEY_BYTES=\"\${POOL_KEY_ENCODED:2}\""
    echo ""
    echo "   Update the comment on lines 225-226 to reflect that"
    echo "   cast abi-encode does NOT prepend a selector."
else
    echo "❌ INDETERMINATE: Both candidates returned zero liquidity."
    echo ""
    echo "   Either the reference pool has no liquidity right now, or"
    echo "   the RPC is rejecting the call. Diagnose:"
    echo "     1. Check if pool exists: search Base V4 for ETH/USDC 500"
    echo "     2. Try a private RPC if using public"
    echo "     3. Try a different reference pool by editing C1/FEE/TS above"
fi
echo "════════════════════════════════════════════════"
echo ""
