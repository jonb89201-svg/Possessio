#!/bin/bash
# ============================================================
# POSSESSIO SAL: Pre-Flight Guard v1.3.2
# Amendment V Ratified | Mobile Nomad Standard
# ============================================================
# CHANGELOG v1.3.2:
#   Cast suffix fix — cast appends [scientific_notation] to
#   uint256 outputs e.g. 106106846807834730[1.061e17].
#   Added sed 's/\[.*\]//' after tr -d on all four balance
#   reads: BAL0_RAW, BAL1_RAW, BAL0_PRIOR_RAW, BAL1_PRIOR_RAW.
#   Fixes Gate 3b false positive pass and Gate 5 empty ratio.
#   This is the surgical fix. No other logic changes.
#
# CHANGELOG v1.3.1:
#   KDA nomenclature codified. Threshold comment corrected.
#   Four new env variables documented.
#
# CHANGELOG v1.3.0:
#   Gate 4 KDA ACTIVATED via QuoterV2 quoteExactInputSingle.
#   Gate 5 Synthetic Price Discovery ACTIVATED.
#
# CHANGELOG v1.2.2:
#   Heartbeat: git blob SHA replaces sha256sum. Deterministic.
#
# NOTE: v1.2.3 and v1.3.0 were design iterations. v1.3.2
#   deploys from v1.2.2 committed baseline. RATIFIED_COMMIT
#   must point to the committed v1.3.2 script SHA.
# ============================================================
# DEPENDENCIES: cast (Foundry), oathtool, curl, bc, awk, git, sed
#
# REQUIRED .env.secret VARIABLES:
#   RPC_URL                — Base mainnet RPC endpoint
#                            WARNING: public RPC may revert on
#                            Quoter calls. Private RPC recommended.
#   POOL_ADDR              — 0x031c08ca0aed0c813aca333aa4ca0025ecee6afa
#   QUOTER_ADDR            — 0x166128B234e7939180371457008B17130F309597
#   WETH_ADDR              — 0x4200000000000000000000000000000000000006
#   PLATE_ADDR             — 0x726D6a7A598A4D12aDe7019Dc2598D955391E298
#   ORACLE_ADDR            — 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
#   SAL_SECRET             — TOTP seed (base32)
#   GITHUB_TOKEN           — Personal access token (repo:read scope)
#   GITHUB_REPO            — jonb89201-svg/Possessio
#   RATIFIED_COMMIT        — Full SHA of the ratified commit
#   MIN_LIQ_FLOOR          — 1000000000000000000 (1e18)
#   MIN_RESERVE_THRESHOLD  — 10000000000000000 (0.01 ETH — Architect configured)
#   MAX_PRICE_IMPACT       — Max allowed impact in bps (default: 50 = 0.5%)
#
# KNOWN LIMITATIONS:
#   Gate 3b: LIQ_PRIOR=0 bypasses delta — documented, not patched.
#   Gate 4 KDA: quoteExactInputSingle may revert on public RPC.
#               Private RPC strongly recommended for production.
#
# USAGE:
#   set -a && source .env.secret && set +a && bash script/sal_pfg_v1.3.2.sh
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

QUOTER_ADDR="${QUOTER_ADDR:-0x166128B234e7939180371457008B17130F309597}"
WETH_ADDR="${WETH_ADDR:-0x4200000000000000000000000000000000000006}"
PLATE_ADDR="${PLATE_ADDR:-0x726D6a7A598A4D12aDe7019Dc2598D955391E298}"
THRESHOLD="${MIN_RESERVE_THRESHOLD:-10000000000000000}"
MAX_PRICE_IMPACT="${MAX_PRICE_IMPACT:-50}"

VETO=0
WARNINGS=0
MODE="FULL PASS"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  POSSESSIO SAL: PRE-FLIGHT GUARD v1.3.2      ║"
echo "║  Amendment V — Full Spectrum Guard           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ============================================================
# 1. GITHUB REMOTE ANCHOR — Heartbeat
# ============================================================
echo "[1/5] HEARTBEAT: Verifying local files against ratified commit..."

fetch_remote_hash() {
    local FILEPATH="$1"
    local API_URL="https://api.github.com/repos/${GITHUB_REPO}/contents/${FILEPATH}?ref=${RATIFIED_COMMIT}"
    curl -sf \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$API_URL" 2>/dev/null \
        | grep '"sha"' \
        | head -1 \
        | awk -F'"' '{print $4}'
}

echo "   Fetching remote blob SHA: script/sal_pfg_v1.3.2.sh..."
REMOTE_SCRIPT_HASH=$(fetch_remote_hash "script/sal_pfg_v1.3.2.sh") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    echo "   Hard-block engaged. Do not proceed."
    exit 1
}

echo "   Fetching remote blob SHA: src/PLATE.sol..."
REMOTE_PLATE_HASH=$(fetch_remote_hash "src/PLATE.sol") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    echo "   Hard-block engaged. Do not proceed."
    exit 1
}

if [[ -z "$REMOTE_SCRIPT_HASH" || -z "$REMOTE_PLATE_HASH" ]]; then
    echo "❌ HEARTBEAT FAIL: Remote blob SHA returned empty."
    echo "   Hard-block engaged. Do not proceed."
    exit 1
fi

LOCAL_SCRIPT_HASH=$(git hash-object script/sal_pfg_v1.3.2.sh)
LOCAL_PLATE_HASH=$(git hash-object src/PLATE.sol)

HASH_FAIL=0
if [ "$LOCAL_SCRIPT_HASH" != "$REMOTE_SCRIPT_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: script/sal_pfg_v1.3.2.sh does not match ratified commit"
    echo "   Local:  $LOCAL_SCRIPT_HASH"
    echo "   Remote: $REMOTE_SCRIPT_HASH"
    HASH_FAIL=1
fi
if [ "$LOCAL_PLATE_HASH" != "$REMOTE_PLATE_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: src/PLATE.sol does not match ratified commit"
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
# 3. JIT GUARD — Reserve Integrity + 10-Block Delta
# ============================================================
echo ""
echo "[3/5] JIT GUARD: Reserve integrity + 10-block delta..."

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

# v1.3.2: sed strips cast's [scientific_notation] suffix
BAL0_RAW=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]' | sed 's/\[.*\]//') || {
    echo "❌ FATAL: Failed to read Token0 balance."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}
BAL1_RAW=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]' | sed 's/\[.*\]//') || {
    echo "❌ FATAL: Failed to read Token1 balance."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
}

if [[ -z "$BAL0_RAW" || -z "$BAL1_RAW" ]]; then
    echo "❌ FATAL: Balance read returned empty."
    echo "   Terminal lock engaged. Do not execute."
    exit 1
fi

READABLE_BAL0=$(echo "scale=6; $BAL0_RAW / 10^18" | bc -l)
READABLE_BAL1=$(echo "scale=6; $BAL1_RAW / 10^18" | bc -l)
READABLE_THRESHOLD=$(echo "scale=6; $THRESHOLD / 10^18" | bc -l)

echo "   Pool reserves:"
echo "     Token0: $READABLE_BAL0 (raw: $BAL0_RAW)"
echo "     Token1: $READABLE_BAL1 (raw: $BAL1_RAW)"
echo "     Threshold: $READABLE_THRESHOLD"

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

echo "   [3b] 10-block balance delta check..."

BAL0_PRIOR_RAW=$(cast call "$TOKEN0" \
    "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" \
    | tr -d '[:space:]' | sed 's/\[.*\]//') || {
    echo "⚠️  JIT WARNING: Cannot fetch prior Token0 balance"
    WARNINGS=$((WARNINGS + 1))
    BAL0_PRIOR_RAW="0"
}

BAL1_PRIOR_RAW=$(cast call "$TOKEN1" \
    "balanceOf(address)(uint256)" "$POOL_ADDR" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" \
    | tr -d '[:space:]' | sed 's/\[.*\]//') || {
    echo "⚠️  JIT WARNING: Cannot fetch prior Token1 balance"
    WARNINGS=$((WARNINGS + 1))
    BAL1_PRIOR_RAW="0"
}

LIQ_NOW="$BAL0_RAW"
LIQ_PRIOR="$BAL0_PRIOR_RAW"

# KNOWN LIMITATION: LIQ_PRIOR=0 bypasses delta check.
if [ "$LIQ_PRIOR" -eq 0 ]; then
    echo "⚠️  JIT WARNING: Prior balance is zero — delta check bypassed"
    echo "   Known limitation. See script header."
    WARNINGS=$((WARNINGS + 1))
else
    BAL0_DELTA=$(echo "scale=4; ($BAL0_RAW - $BAL0_PRIOR_RAW) / $BAL0_PRIOR_RAW * 100" | bc -l)
    BAL0_DELTA_ABS=${BAL0_DELTA#-}
    BAL1_DELTA=$(echo "scale=4; ($BAL1_RAW - $BAL1_PRIOR_RAW) / $BAL1_PRIOR_RAW * 100" | bc -l)
    BAL1_DELTA_ABS=${BAL1_DELTA#-}

    SPIKE0=$(echo "$BAL0_DELTA_ABS > 15" | bc)
    SPIKE1=$(echo "$BAL1_DELTA_ABS > 15" | bc)

    if [ "$SPIKE0" -eq 1 ] || [ "$SPIKE1" -eq 1 ]; then
        echo "❌ JIT VETO: Balance shifted >15% in 10 blocks"
        echo "   Token0 delta: ${BAL0_DELTA}%"
        echo "   Token1 delta: ${BAL1_DELTA}%"
        echo "   Note: thin pool — verify not normal LP activity before retrying"
        VETO=1
    else
        echo "   ✅ Balance delta OK: Token0 ${BAL0_DELTA}% Token1 ${BAL1_DELTA}%"
    fi
fi

# ============================================================
# 4. KINETIC DEPTH ANCHOR (KDA) — Liquidity Density Probe
# ============================================================
# The KDA probes the inertia of the pool by simulating a
# 0.0001 ETH swap through the Aerodrome Slipstream QuoterV2.
#
# Logic: If the pool shifts (Price Impact) beyond the Anchor
# threshold, the liquidity is deemed hollow or manipulated.
#
# Does not require slot0. tickSpacing=200 confirmed.
# Falls back to DEGRADED warning if Quoter reverts (public RPC).
# ============================================================
echo ""
echo "[4/5] KINETIC DEPTH ANCHOR (KDA): Probing liquidity depth..."

PROBE_AMOUNT="100000000000000"
TICK_SPACING="200"

QUOTE_RAW=$(cast call "$QUOTER_ADDR" \
    "quoteExactInputSingle(address,address,int24,uint256,uint160)(uint256,uint160,uint32,uint256)" \
    "$WETH_ADDR" "$PLATE_ADDR" "$TICK_SPACING" "$PROBE_AMOUNT" "0" \
    --rpc-url "$RPC_URL" 2>/dev/null) || QUOTE_RAW=""

if [[ -z "$QUOTE_RAW" ]]; then
    echo "⚠️  KDA WARNING: QuoterV2 unavailable — Gate 4 bypassed"
    echo "   Likely public RPC limitation. Private RPC required for FULL PASS."
    echo "   Recommendation: configure Alchemy or QuickNode endpoint."
    WARNINGS=$((WARNINGS + 1))
    MODE="DEGRADED"
else
    AMOUNT_OUT=$(echo "$QUOTE_RAW" | awk -F',' '{print $1}' \
        | tr -d ' ' | sed 's/\[.*\]//')

    if [[ -z "$AMOUNT_OUT" || "$AMOUNT_OUT" -eq 0 ]]; then
        echo "❌ KDA VETO: Zero output on swap simulation — hollow liquidity detected"
        VETO=1
    else
        EXPECTED_OUT=$(echo "scale=0; $PROBE_AMOUNT * $BAL1_RAW / $BAL0_RAW" | bc)

        if [[ "$EXPECTED_OUT" -gt 0 ]]; then
            PRICE_IMPACT=$(echo "scale=2; ($EXPECTED_OUT - $AMOUNT_OUT) * 10000 / $EXPECTED_OUT" | bc -l)
            PRICE_IMPACT_ABS=${PRICE_IMPACT#-}
            IMPACT_BREACH=$(echo "$PRICE_IMPACT_ABS > $MAX_PRICE_IMPACT" | bc)

            if [ "$IMPACT_BREACH" -eq 1 ]; then
                echo "❌ KDA VETO: Price impact ${PRICE_IMPACT_ABS} bps exceeds threshold ${MAX_PRICE_IMPACT} bps"
                echo "   Hollow or manipulated liquidity detected."
                VETO=1
            else
                echo "✅ KDA OK: Price impact ${PRICE_IMPACT_ABS} bps (threshold: ${MAX_PRICE_IMPACT} bps)"
            fi
        else
            echo "⚠️  KDA WARNING: Cannot compute expected output — skipping impact check"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
fi

# ============================================================
# 5. SYNTHETIC PRICE DISCOVERY — Reserve Ratio Delta
# ============================================================
# Derives implicit PLATE/WETH price from actual pool reserves.
# Compares current ratio against 10-block-ago ratio.
# No slot0 required. Veto if ratio drifts >1.0% in 10 blocks.
# ============================================================
echo ""
echo "[5/5] PRICE DISCOVERY: Checking reserve ratio delta..."

if [[ -z "$BAL0_PRIOR_RAW" || "$BAL0_PRIOR_RAW" -eq 0 || \
      -z "$BAL1_PRIOR_RAW" || "$BAL1_PRIOR_RAW" -eq 0 ]]; then
    echo "⚠️  PRICE WARNING: Prior reserves unavailable — Gate 5 bypassed"
    WARNINGS=$((WARNINGS + 1))
    MODE="DEGRADED"
else
    RATIO_NOW=$(echo "scale=8; $BAL1_RAW / $BAL0_RAW" | bc -l)
    RATIO_PRIOR=$(echo "scale=8; $BAL1_PRIOR_RAW / $BAL0_PRIOR_RAW" | bc -l)
    RATIO_DELTA=$(echo "scale=4; ($RATIO_NOW - $RATIO_PRIOR) / $RATIO_PRIOR * 100" | bc -l)
    RATIO_DELTA_ABS=${RATIO_DELTA#-}
    RATIO_BREACH=$(echo "$RATIO_DELTA_ABS > 1.0" | bc)

    ORACLE_RAW=$(cast call "$ORACLE_ADDR" \
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
        --rpc-url "$RPC_URL" 2>/dev/null) || ORACLE_RAW=""

    if [ -n "$ORACLE_RAW" ]; then
        ORACLE_PRICE_ABS=$(echo "$ORACLE_RAW" | awk -F',' '{print $2}' \
            | tr -d ' ' | tr -d '-' | sed 's/\[.*\]//')
        ORACLE_ETH_USD=$(echo "scale=2; $ORACLE_PRICE_ABS / 100000000" | bc)
        echo "   Chainlink ETH/USD reference: \$$ORACLE_ETH_USD"
    fi

    echo "   Implicit PLATE/WETH ratio now:   $RATIO_NOW"
    echo "   Implicit PLATE/WETH ratio prior:  $RATIO_PRIOR"
    echo "   Delta: ${RATIO_DELTA}%"

    if [ "$RATIO_BREACH" -eq 1 ]; then
        echo "❌ PRICE VETO: Reserve ratio moved ${RATIO_DELTA_ABS}% in 10 blocks"
        echo "   Threshold: 1.0% — potential price manipulation detected."
        echo "   Retry after conditions stabilize."
        VETO=1
    else
        echo "✅ Price discovery OK: ratio delta ${RATIO_DELTA_ABS}% (threshold: 1.0%)"
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
    echo "   Mode: VETO"
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
echo "║  Core sentinels passed. Warnings acknowledged.║"
echo "╚══════════════════════════════════════════════╝"
echo "   Mode: $MODE"
echo ""
exit 0
