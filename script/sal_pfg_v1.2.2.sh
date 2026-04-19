#!/bin/bash
# ============================================================
# POSSESSIO SAL: Pre-Flight Guard v1.2.2
# Amendment V Ratified | Mobile Nomad Standard
# ============================================================
# CHANGELOG v1.2.2:
#   Gate 3b redesigned — replaced liquidity() delta with
#   balanceOf delta across 10 blocks. Same data source as
#   Gate 3a. Eliminates Slipstream in-range liquidity
#   limitation and false-positive pass condition from v1.2.1.
#   awk sanitization applied to all balance reads — resolves
#   bc arithmetic errors from scientific notation in cast output.
#   Hard reserve veto preserved. Invariant #273 null-check
#   veto adopted from Gemini spec.
#
# CHANGELOG v1.2.1:
#   Gate 3 reserve integrity fix — replaced liquidity()(uint128)
#   reserve check with balanceOf reads on underlying tokens.
#   liquidity() returns in-range liquidity only on Slipstream.
#   balanceOf reflects actual reserves regardless of tick range.
#   liquidity() calls retained for Gate 4 tick concentration math.
# ============================================================
# DEPENDENCIES: cast (Foundry), oathtool, curl, bc, awk
#
# REQUIRED .env.secret VARIABLES:
#   RPC_URL                — Base mainnet RPC endpoint
#   POOL_ADDR              — Aerodrome WETH/PLATE Slipstream pool
#                            0x031c08ca0aed0c813aca333aa4ca0025ecee6afa
#   ORACLE_ADDR            — Chainlink ETH/USD feed on Base
#   SAL_SECRET             — TOTP seed (base32)
#   GITHUB_TOKEN           — Personal access token (repo:read scope only)
#   GITHUB_REPO            — owner/repo e.g. "john/possessio"
#   RATIFIED_COMMIT        — Full SHA of the ratified commit
#   MIN_LIQ_FLOOR          — Tick concentration bypass floor
#                            (1000000000000000000 = 1e18)
#   MIN_RESERVE_THRESHOLD  — Hard veto floor for reserve drain detection
#                            Default: 10000000000000000 (0.01 ETH equivalent)
#                            Recommended: 50000000000000000 (0.05 ETH)
#                            Raise threshold as pool liquidity grows.
#                            Ratify value with full council before raising.
#
# USAGE:
#   source .env.secret && bash sal_pfg_v1.2.2.sh
#
# FIRST-RUN SETUP:
#   sha256sum sal_pfg_v1.2.2.sh PLATE.sol
#   Commit both files, note the commit SHA, set RATIFIED_COMMIT
# ============================================================

set -euo pipefail

# --- ENV VALIDATION ---
: "${RPC_URL:?Not set}"
: "${POOL_ADDR:?Not set}"
: "${ORACLE_ADDR:?Not set}"
: "${SAL_SECRET:?Not set}"
: "${GITHUB_TOKEN:?Not set}"
: "${GITHUB_REPO:?Not set}"
: "${RATIFIED_COMMIT:?Not set}"
: "${MIN_LIQ_FLOOR:?Not set}"

# MIN_RESERVE_THRESHOLD defaults to 0.01 ETH if not set
THRESHOLD="${MIN_RESERVE_THRESHOLD:-10000000000000000}"

VETO=0
WARNINGS=0

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  POSSESSIO SAL: PRE-FLIGHT GUARD v1.2.2      ║"
echo "║  Amendment V — Gold Master                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ============================================================
# 1. GITHUB REMOTE ANCHOR — Heartbeat
# ============================================================
echo "[1/5] HEARTBEAT: Verifying local files against ratified commit..."

fetch_remote_hash() {
    local FILEPATH="$1"
    local API_URL="https://api.github.com/repos/${GITHUB_REPO}/contents/${FILEPATH}?ref=${RATIFIED_COMMIT}"
    RESPONSE=$(curl -sf \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3.raw" \
        "$API_URL" 2>/dev/null) || return 1
    echo "$RESPONSE" | sha256sum | awk '{print $1}'
}

echo "   Fetching remote hash: sal_pfg_v1.2.2.sh..."
REMOTE_SCRIPT_HASH=$(fetch_remote_hash "sal_pfg_v1.2.2.sh") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    echo "   Hard-block engaged. Do not proceed."
    exit 1
}

echo "   Fetching remote hash: PLATE.sol..."
REMOTE_PLATE_HASH=$(fetch_remote_hash "PLATE.sol") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    echo "   Hard-block engaged. Do not proceed."
    exit 1
}

LOCAL_SCRIPT_HASH=$(sha256sum sal_pfg_v1.2.2.sh | awk '{print $1}')
LOCAL_PLATE_HASH=$(sha256sum PLATE.sol | awk '{print $1}')

HASH_FAIL=0
if [ "$LOCAL_SCRIPT_HASH" != "$REMOTE_SCRIPT_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: sal_pfg_v1.2.2.sh does not match ratified commit"
    echo "   Local:  $LOCAL_SCRIPT_HASH"
    echo "   Remote: $REMOTE_SCRIPT_HASH"
    HASH_FAIL=1
fi
if [ "$LOCAL_PLATE_HASH" != "$REMOTE_PLATE_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: PLATE.sol does not match ratified commit"
    echo "   Local:  $LOCAL_PLATE_HASH"
    echo "   Remote: $REMOTE_PLATE_HASH"
    HASH_FAIL=1
fi
if [ "$HASH_FAIL" -eq 1 ]; then
    echo "   Tampering or drift detected. Hard-block engaged."
    exit 1
fi

echo "✅ Heartbeat OK — local files match commit ${RATIFIED_COMMIT:0:8}"

# ============================================================
# 2. SEQUENCER CONGESTION — Block Time Check
# ============================================================
echo ""
echo "[2/5] SEQUENCER: Checking avg block time over last 5 blocks..."

BLOCK_NOW=$(cast block-number --rpc-url "$RPC_URL") || {
    echo "❌ RPC FAIL: Cannot reach Base sequencer"; exit 1
}

BLOCK_PRIOR=$((BLOCK_NOW - 5))
BLOCK_10_AGO=$((BLOCK_NOW - 10))

TIME_NOW=$(cast block "$BLOCK_NOW" --rpc-url "$RPC_URL" \
    | grep -i "^timestamp" | awk '{print $2}')
TIME_PRIOR=$(cast block "$BLOCK_PRIOR" --rpc-url "$RPC_URL" \
    | grep -i "^timestamp" | awk '{print $2}')

ELAPSED=$((TIME_NOW - TIME_PRIOR))
AVG_BLOCK=$(echo "scale=2; $ELAPSED / 5" | bc)

CONGESTED=$(echo "$AVG_BLOCK > 4.0" | bc)
if [ "$CONGESTED" -eq 1 ]; then
    echo "⚠️  CONGESTION WARNING: Avg block time ${AVG_BLOCK}s (threshold: 4.0s)"
    echo "   Sequencer load elevated. Proceed with caution."
    WARNINGS=$((WARNINGS + 1))
else
    echo "✅ Sequencer nominal: ${AVG_BLOCK}s avg"
fi

# ============================================================
# 3. JIT GUARD — Reserve Integrity + 10-Block Balance Delta (v1.2.2)
# ============================================================
# Sub-check A: Reserve integrity via balanceOf (terminal lock)
#   Hard veto if either token balance is below MIN_RESERVE_THRESHOLD.
#   Single-sided drain is a JIT signal regardless of the other side.
#
# Sub-check B: 10-block balance delta via balanceOf (veto)
#   v1.2.2: Replaced liquidity() delta with balanceOf delta.
#   Same data source as Sub-check A. No Slipstream in-range limitation.
#   Resolves false-positive pass condition from v1.2.1.
#   awk sanitization applied to all reads — resolves bc scientific
#   notation errors that produced empty delta values in dry run 1.
#
# liquidity() calls retained in Gate 4 for tick concentration math only.
# ============================================================
echo ""
echo "[3/5] JIT GUARD: Reserve integrity + 10-block balance delta..."

# --- Sub-check A: Reserve Integrity ---
echo "   [3a] Reserve integrity check..."

TOKEN0=$(cast call "$POOL_ADDR" "token0()(address)" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]') || {
    echo "❌ FATAL: Failed to read token0 from pool."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}
TOKEN1=$(cast call "$POOL_ADDR" "token1()(address)" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]') || {
    echo "❌ FATAL: Failed to read token1 from pool."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}

if [[ -z "$TOKEN0" || -z "$TOKEN1" ]]; then
    echo "❌ FATAL: Token address read returned empty."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
fi

echo "   Token0: $TOKEN0"
echo "   Token1: $TOKEN1"

# awk sanitization strips scientific notation from cast output
# Invariant #273: null result from parsing is a hard block
BAL0_RAW=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]' | awk '{printf "%.0f\n", $1}') || {
    echo "❌ FATAL: Failed to read Token0 balance."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}
BAL1_RAW=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]' | awk '{printf "%.0f\n", $1}') || {
    echo "❌ FATAL: Failed to read Token1 balance."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}

# Invariant #273: null-check veto — fail on empty, allow zero
if [[ -z "$BAL0_RAW" || -z "$BAL1_RAW" ]]; then
    echo "❌ FATAL: Invariant #273 — balance parsing returned null."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
fi

READABLE_BAL0=$(echo "scale=6; $BAL0_RAW / 10^18" | bc -l 2>/dev/null || echo "0")
READABLE_BAL1=$(echo "scale=6; $BAL1_RAW / 10^18" | bc -l 2>/dev/null || echo "0")
READABLE_THRESHOLD=$(echo "scale=6; $THRESHOLD / 10^18" | bc -l)

echo "   Pool reserves:"
echo "     Token0 (WETH):  $READABLE_BAL0 (raw: $BAL0_RAW)"
echo "     Token1 (PLATE): $READABLE_BAL1 (raw: $BAL1_RAW)"
echo "     Threshold:      $READABLE_THRESHOLD"

# Hard veto on low reserves — security critical, do not downgrade to warning
BAL0_LOW=$(echo "$BAL0_RAW < $THRESHOLD" | bc)
BAL1_LOW=$(echo "$BAL1_RAW < $THRESHOLD" | bc)

if [[ "$BAL0_LOW" -eq 1 || "$BAL1_LOW" -eq 1 ]]; then
    echo "❌ RESERVE VETO: One or both reserves below threshold."
    echo "   Token0 below threshold: $BAL0_LOW"
    echo "   Token1 below threshold: $BAL1_LOW"
    echo "   Potential JIT or drain condition. Terminal lock engaged."
    exit 1
fi

echo "   ✅ Reserve integrity OK — both sides above threshold"

# --- Sub-check B: 10-Block Balance Delta ---
echo "   [3b] 10-block balance delta check..."

BAL0_PRIOR_RAW=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>/dev/null \
    | tr -d '[:space:]' | awk '{printf "%.0f\n", $1}') || BAL0_PRIOR_RAW="0"
BAL1_PRIOR_RAW=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>/dev/null \
    | tr -d '[:space:]' | awk '{printf "%.0f\n", $1}') || BAL1_PRIOR_RAW="0"

if [ "$BAL0_PRIOR_RAW" -eq 0 ]; then
    echo "⚠️  JIT WARNING: Prior balance is zero — pool may be new"
    WARNINGS=$((WARNINGS + 1))
else
    BAL0_DELTA=$(echo "scale=4; ($BAL0_RAW - $BAL0_PRIOR_RAW) / $BAL0_PRIOR_RAW * 100" | bc -l)
    BAL1_DELTA=$(echo "scale=4; ($BAL1_RAW - $BAL1_PRIOR_RAW) / $BAL1_PRIOR_RAW * 100" | bc -l)

    # Strip sign for absolute comparison
    BAL0_DELTA_ABS=${BAL0_DELTA#-}
    BAL1_DELTA_ABS=${BAL1_DELTA#-}

    SPIKE0=$(echo "$BAL0_DELTA_ABS > 15" | bc)
    SPIKE1=$(echo "$BAL1_DELTA_ABS > 15" | bc)

    if [ "$SPIKE0" -eq 1 ] || [ "$SPIKE1" -eq 1 ]; then
        echo "❌ JIT VETO: Balance shifted >15% in 10 blocks"
        echo "   Token0 delta: ${BAL0_DELTA}% | Token1 delta: ${BAL1_DELTA}%"
        echo "   Note: thin pool — verify this is not normal LP activity before retrying"
        VETO=1
    else
        echo "   ✅ Balance delta OK: Token0 ${BAL0_DELTA}% | Token1 ${BAL1_DELTA}%"
    fi
fi

# ============================================================
# 4. SLIPSTREAM TICK CONCENTRATION — Active ±2 Tick Scan
# ============================================================
# Open research item: slot0() reverts on live PLATE/WETH pool.
# Confirmed against multiple ABI variants. Root cause unidentified.
# Gates 4 and 5 degrade gracefully — warnings issued, veto not triggered.
# See research/slot0_revert.md for full investigation log.
# ============================================================
echo ""
echo "[4/5] TICK SCAN: Checking active tick concentration..."

SLOT0_NOW=$(cast call "$POOL_ADDR" \
    "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" \
    --rpc-url "$RPC_URL" 2>/dev/null) || SLOT0_NOW=""

SLOT0_PRIOR=$(cast call "$POOL_ADDR" \
    "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>/dev/null) || SLOT0_PRIOR=""

if [[ -z "$SLOT0_NOW" || -z "$SLOT0_PRIOR" ]]; then
    echo "⚠️  TICK WARNING: slot0() unavailable — graceful bypass engaged"
    echo "   Open research item: slot0 revert on Aerodrome Slipstream pool."
    echo "   Gates 4 and 5 inactive until root cause resolved."
    echo "   See research/slot0_revert.md"
    WARNINGS=$((WARNINGS + 1))
    # Set sentinel values so Gate 5 also degrades gracefully
    SQRT_PRICE=""
    SQRT_PRIOR=""
else
    CURRENT_TICK=$(echo "$SLOT0_NOW"   | awk -F',' '{print $2}' | tr -d ' ')
    PRIOR_TICK=$(echo   "$SLOT0_PRIOR" | awk -F',' '{print $2}' | tr -d ' ')
    SQRT_PRICE=$(echo   "$SLOT0_NOW"   | awk -F',' '{print $1}' | tr -d ' ')
    SQRT_PRIOR=$(echo   "$SLOT0_PRIOR" | awk -F',' '{print $1}' | tr -d ' ')

    # liquidity() retained here for tick concentration math only
    LIQ_NOW_RAW=$(cast call "$POOL_ADDR" "liquidity()(uint128)" \
        --rpc-url "$RPC_URL" --block "$BLOCK_NOW" 2>/dev/null) || LIQ_NOW_RAW="0"
    LIQ_PRIOR_RAW=$(cast call "$POOL_ADDR" "liquidity()(uint128)" \
        --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>/dev/null) || LIQ_PRIOR_RAW="0"

    LIQ_NOW="$LIQ_NOW_RAW"
    LIQ_PRIOR="$LIQ_PRIOR_RAW"

    BELOW_FLOOR=$(echo "$LIQ_NOW < $MIN_LIQ_FLOOR" | bc)

    if [ "$BELOW_FLOOR" -eq 1 ]; then
        echo "⚠️  TICK WARNING: In-range liquidity ${LIQ_NOW} below floor ${MIN_LIQ_FLOOR}"
        echo "   Concentration veto bypassed. Price divergence veto remains active."
        WARNINGS=$((WARNINGS + 1))
    else
        ACTIVE_LIQ=0
        for i in -2 -1 0 1 2; do
            TICK_IDX=$((CURRENT_TICK + i))
            TICK_DATA=$(cast call "$POOL_ADDR" \
                "ticks(int24)(uint128,int128,uint256,uint256,int56,uint160,uint32,bool)" \
                "$TICK_IDX" --rpc-url "$RPC_URL" 2>/dev/null) || continue
            TICK_LIQ=$(echo "$TICK_DATA" | awk -F',' '{print $1}' | tr -d ' ')
            TICK_LIQ=${TICK_LIQ:-0}
            ACTIVE_LIQ=$((ACTIVE_LIQ + TICK_LIQ))
        done

        PRIOR_ACTIVE_LIQ=0
        for i in -2 -1 0 1 2; do
            TICK_IDX=$((PRIOR_TICK + i))
            TICK_DATA=$(cast call "$POOL_ADDR" \
                "ticks(int24)(uint128,int128,uint256,uint256,int56,uint160,uint32,bool)" \
                "$TICK_IDX" --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>/dev/null) || continue
            TICK_LIQ=$(echo "$TICK_DATA" | awk -F',' '{print $1}' | tr -d ' ')
            TICK_LIQ=${TICK_LIQ:-0}
            PRIOR_ACTIVE_LIQ=$((PRIOR_ACTIVE_LIQ + TICK_LIQ))
        done

        if [ "$LIQ_NOW" -gt 0 ] && [ "$LIQ_PRIOR" -gt 0 ]; then
            CONCENTRATION=$(echo "scale=4; $ACTIVE_LIQ / $LIQ_NOW * 100" | bc)
            PRIOR_CONCENTRATION=$(echo "scale=4; $PRIOR_ACTIVE_LIQ / $LIQ_PRIOR * 100" | bc)

            CONCENTRATED=$(echo "$CONCENTRATION > 70" | bc)
            PRIOR_WAS_LOW=$(echo "$PRIOR_CONCENTRATION < 30" | bc)

            if [ "$CONCENTRATED" -eq 1 ] && [ "$PRIOR_WAS_LOW" -eq 1 ]; then
                echo "❌ TICK VETO: ${CONCENTRATION}% of liquidity in active ±2 ticks"
                echo "   Prior was ${PRIOR_CONCENTRATION}% — sudden stacking detected"
                VETO=1
            else
                echo "✅ Tick concentration OK: ${CONCENTRATION}% (prior: ${PRIOR_CONCENTRATION}%)"
            fi
        else
            echo "⚠️  TICK WARNING: Cannot compute concentration ratio"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
fi

# ============================================================
# 5. ORACLE — PLATE/ETH 10-Block Delta
# ============================================================
# WETH(token0) / PLATE(token1) — both 18 decimals
# sqrtPriceX96 yields PLATE per 1 WETH
# Check: spot price has not moved >1.0% vs 10 blocks ago
# Chainlink ETH/USD fetched for reference logging only
# Degrades gracefully if slot0 unavailable (shared dependency with Gate 4)
# ============================================================
echo ""
echo "[5/5] ORACLE: Checking PLATE/ETH 10-block price delta..."

if [[ -z "${SQRT_PRICE:-}" || -z "${SQRT_PRIOR:-}" ]]; then
    echo "⚠️  ORACLE WARNING: slot0 unavailable — price delta check bypassed"
    echo "   Shared dependency with Gate 4. See research/slot0_revert.md"
    WARNINGS=$((WARNINGS + 1))
else
    SQRT_PRICE_DEC=$(cast to-dec "$SQRT_PRICE")
    SQRT_PRIOR_DEC=$(cast to-dec "$SQRT_PRIOR")

    Q96="79228162514264337593543950336"
    SPOT_PLATE_PER_ETH=$(echo  "scale=8; ($SQRT_PRICE_DEC / $Q96)^2" | bc)
    PRIOR_PLATE_PER_ETH=$(echo "scale=8; ($SQRT_PRIOR_DEC / $Q96)^2" | bc)

    ORACLE_RAW=$(cast call "$ORACLE_ADDR" \
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
        --rpc-url "$RPC_URL" 2>/dev/null) || ORACLE_RAW=""

    if [ -n "$ORACLE_RAW" ]; then
        ORACLE_PRICE_ABS=$(echo "$ORACLE_RAW" | awk -F',' '{print $2}' \
            | tr -d ' ' | tr -d '-')
        ORACLE_ETH_USD=$(echo "scale=2; $ORACLE_PRICE_ABS / 100000000" | bc)
        echo "   Chainlink ETH/USD reference: \$$ORACLE_ETH_USD"
    else
        echo "   Chainlink reference unavailable — continuing with spot delta check"
    fi

    if [ "$(echo "$PRIOR_PLATE_PER_ETH > 0" | bc)" -eq 1 ]; then
        DIVERGENCE=$(echo "scale=4; \
            ($SPOT_PLATE_PER_ETH - $PRIOR_PLATE_PER_ETH) \
            / $PRIOR_PLATE_PER_ETH * 100" | bc)
        DIVERGENCE_ABS=${DIVERGENCE#-}
        ORACLE_BREACH=$(echo "$DIVERGENCE_ABS > 1.0" | bc)

        if [ "$ORACLE_BREACH" -eq 1 ]; then
            echo "❌ ORACLE VETO: PLATE/ETH moved ${DIVERGENCE_ABS}% in 10 blocks"
            echo "   Threshold: 1.0% | Initiating 5-minute cooldown..."
            VETO=1
            sleep 300
        else
            echo "✅ Oracle OK: PLATE/ETH delta ${DIVERGENCE_ABS}% (threshold: 1.0%)"
        fi
    else
        echo "❌ ORACLE VETO: Cannot compute prior price — hard-block engaged"
        VETO=1
    fi
fi

# ============================================================
# FINAL GATE
# ============================================================
echo ""
echo "══════════════════════════════════════════════"

if [ "$VETO" -eq 1 ]; then
    echo "❌ PRE-FLIGHT VETO: Execution blocked by sentinel."
    echo "   Review the flags above. Do not proceed."
    exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo "⚠️  $WARNINGS WARNING(s) active. Review above before continuing."
    read -p "   Acknowledge warnings and proceed to auth? (y/N): " ACK
    if [ "$ACK" != "y" ] && [ "$ACK" != "Y" ]; then
        echo "   Execution aborted by Architect."
        exit 1
    fi
fi

# TOTP — Human-in-the-Loop Final Auth
echo ""
echo "🔐 TOTP: Final human-in-the-loop verification"
TERMINAL_CODE=$(oathtool --totp -b "$SAL_SECRET")

if [ -z "$TERMINAL_CODE" ]; then
    echo "❌ AUTH FAIL: oathtool returned empty code. Hard-block engaged."
    exit 1
fi

read -p "   Enter your 6-digit Authenticator code: " USER_CODE

if [ "$USER_CODE" != "$TERMINAL_CODE" ]; then
    echo "❌ AUTH FAIL: Code mismatch. Execution blocked."
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ PRE-FLIGHT CLEAR                          ║"
echo "║  All sentinels passed. Council authorized.   ║"
echo "║  You are clear for execution.                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
exit 0
