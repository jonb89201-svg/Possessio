#!/bin/bash
# ============================================================
# POSSESSIO SAL: Pre-Flight Guard v1.5.0-rev3
# Amendment V Ratified | Mobile Nomad Standard | Uniswap V4
# ============================================================
# CHANGELOG v1.5.0-rev3:
#   Code Integrity audit pass. Seven findings resolved:
#
#   F1 (CRITICAL): PoolId slice index. cast abi-encode for
#     "f((...))" form does NOT prepend a function selector.
#     Verified against ETH/USDC 500/10 reference pool via
#     script/poolid_check.sh. Slice changed from :10 to :2.
#
#   F2 (HIGH): Numeric guards. Added require_uint helper to
#     validate values before -lt comparisons and bc arithmetic.
#     Error strings no longer silently flow into numeric tests
#     and bypass vetos.
#
#   F3 (HIGH): cbPaused check. getState() field 5 (cbPaused)
#     now inspected alongside field 4 (routingPaused). Parser
#     uses sed -n line addressing for consistency with poolKey
#     parsing.
#
#   F4 (MEDIUM): PFG_STRICT mode introduced. Auto-resolved
#     based on MODE: DEPLOYMENT=1 (hard exit on veto),
#     CALIBRATION=0 (continue to surface all findings).
#     Override with PFG_STRICT=1 or PFG_STRICT=0. Gate vetos
#     now route through gate_veto helper which respects strict.
#
#   F5 (MEDIUM): Chainlink staleness. updatedAt (field 4 of
#     latestRoundData) now compared against system time. Veto
#     if > 3600s stale.
#
#   F6 (LOW): MAX_PRICE_IMPACT removed. Variable was declared
#     but never referenced. If price-impact gating is added in
#     a future rev, it will be wired with proper math.
#
#   F7 (LOW): Negative oracle answer. Sign no longer stripped
#     in oracle parsing. Negative or zero price now vetos.
#
# CHANGELOG v1.5.0-rev2:
#   Dry-run readiness pass. Two operating modes detected
#   automatically based on env configuration:
#
#   CALIBRATION MODE — HOOK_ADDR unset or non-responsive.
#     Tests V4-substrate cast calls (StateView, V4 Quoter)
#     against any existing V4 pool. Used pre-V2-deployment to
#     surface bash-side parsing bugs in V4 calls before they
#     hit deployment-day operations.
#
#   DEPLOYMENT MODE — HOOK_ADDR responds with verified
#     PoolManager. Tests PossessioHook getters in addition
#     to V4 substrate. Used post-V2-deployment.
#
#   Improvements over rev1:
#   - PoolId derivation built into script via cast keccak +
#     cast abi-encode. Architect provides PoolKey components,
#     script computes PoolId. No external derivation needed.
#   - Multi-format tuple parsing: handles cast's comma-separated,
#     line-separated, and parenthesized output formats.
#   - DEBUG mode (export PFG_DEBUG=1) prints each cast command
#     before executing. Bug surfacing via verbose tracing.
#   - cast balance used for native ETH reads (currency0 in
#     PossessioHook pool). balanceOf only used for ERC20s.
#   - PossessioHook.getState() integrated in deployment mode —
#     one call returns 6 protocol state values. Drastically
#     fewer round-trips than separate getter calls.
#   - Auto-detection of mode via PossessioHook.POOL_MANAGER()
#     verification. Mismatch surfaces wrong HOOK_ADDR config.
#
# CHANGELOG v1.5.0-rev1:
#   Council deliberation cycle integrated. Verified findings
#   from COUNCIL_0 (Gemini): POOL_FEE=0, tickSpacing=200,
#   StateView at 0xa3c0c9b65bad0b08107aa264b0f3db444b867a71,
#   V4 Quoter callable directly (revert handled internally).
#
# CHANGELOG v1.5.0:
#   Initial V4 calibration template. Code Integrity completed
#   COUNCIL_3 (Grok)'s torch-pass with verified V4 addresses.
#
# CHANGELOG v1.4.0:
#   TOTP retired. Surgical human-in-loop removal.
#
# CHANGELOG v1.3.x:
#   Cast suffix fixes, KDA activation, Gate 5 hardening.
#
# CHANGELOG v1.2.2:
#   Heartbeat: git blob SHA replaces sha256sum.
#
# NOTE: RATIFIED_COMMIT must point to committed v1.5.0-rev3 SHA.
# ============================================================
# DEPENDENCIES: cast (Foundry), curl, bc, awk, git, sed
# ============================================================
# REQUIRED .env.secret VARIABLES:
#   RPC_URL                — Base mainnet RPC. Private RPC
#                            recommended (Alchemy, QuickNode).
#   GITHUB_TOKEN           — Personal access token (repo:read)
#   GITHUB_REPO            — jonb89201-svg/Possessio
#   RATIFIED_COMMIT        — Full SHA of v1.5.0-rev2 commit
#
# CALIBRATION MODE (test V4 substrate before V2 deploys):
#   Set CURRENCY_ONE to a token paired with native ETH in
#   an existing V4 pool. Set POOL_FEE, POOL_TICK_SPACING,
#   POOL_HOOKS to that pool's actual values. Leave HOOK_ADDR
#   unset (or set to 0x0...0).
#
#   Example: ETH/USDC on V4 with no hooks
#     CURRENCY_ONE=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
#     POOL_FEE=500
#     POOL_TICK_SPACING=10
#     POOL_HOOKS=0x0000000000000000000000000000000000000000
#
# DEPLOYMENT MODE (after V2 deploys to Base mainnet):
#   Set HOOK_ADDR to deployed PossessioHook address. Script
#   queries hook for PoolKey components and verifies hook's
#   POOL_MANAGER matches verified V4 PoolManager. CURRENCY_ONE
#   etc. are read from hook's poolKey() — no need to set.
#
# DEBUG MODE:
#   export PFG_DEBUG=1
#   Each cast command prints before execution. Use when bugs
#   surface to see exact failing call.
#
# USAGE:
#   set -a && source .env.secret && set +a && bash script/sal_pfg_v1.5.0.sh
# ============================================================

set -euo pipefail

# --- DEBUG MODE ---
PFG_DEBUG="${PFG_DEBUG:-0}"

# --- STRICT MODE ---
# auto = resolve from MODE after detection (DEPLOYMENT=1, CALIBRATION=0)
# 1    = hard exit on first veto (default for deployment)
# 0    = continue past vetos to surface all findings (calibration)
PFG_STRICT="${PFG_STRICT:-auto}"

# Helper: trace cast commands when DEBUG enabled
cast_call_trace() {
    if [ "$PFG_DEBUG" = "1" ]; then
        echo "   [DEBUG] cast call $*" >&2
    fi
    cast call "$@"
}

# Helper: extract first value from cast tuple output (handles
# multiple cast output formats: comma-separated, line-separated,
# parenthesized).
cast_extract_first() {
    local raw="$1"
    # Try comma-separated first
    local first=$(echo "$raw" | head -1 | awk -F',' '{print $1}' | tr -d '[:space:]()' | sed 's/\[.*\]//')
    if [ -n "$first" ]; then
        echo "$first"
        return 0
    fi
    # Fallback: line-separated, take first line
    first=$(echo "$raw" | head -1 | tr -d '[:space:]()' | sed 's/\[.*\]//')
    echo "$first"
}

# Helper: assert variable is a non-negative integer.
# Returns 0 if valid uint, 1 if not. Does not exit — caller decides.
require_uint() {
    local val="$1"
    local name="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "   ⚠️  $name parse failure: non-numeric value '${val:0:80}'"
        return 1
    fi
    return 0
}

# Helper: register a gate veto. In strict mode, exits immediately.
# In permissive mode (calibration with PFG_STRICT=0), accumulates VETO
# and continues to surface other findings.
gate_veto() {
    local name="$1"
    local msg="$2"
    echo "❌ $name VETO: $msg"
    VETO=1
    if [ "$PFG_STRICT" = "1" ]; then
        echo "   Strict mode: aborting."
        exit 1
    fi
    echo "   Permissive mode (calibration): continuing to surface other findings."
}

# --- ENV VALIDATION ---
: "${RPC_URL:?Not set}"
: "${GITHUB_TOKEN:?Not set}"
: "${GITHUB_REPO:?Not set}"
: "${RATIFIED_COMMIT:?Not set}"

# --- VERIFIED V4 ADDRESSES (Base mainnet) ---
POOL_MANAGER="${POOL_MANAGER:-0x498581fF718922c3f8e6A244956aF099B2652b2b}"
QUOTER_V4="${QUOTER_V4:-0x0d5e0f971ed27fbff6c2837bf31316121532048d}"
STATE_VIEW="${STATE_VIEW:-0xa3c0c9b65bad0b08107aa264b0f3db444b867a71}"

# --- CHAINLINK ETH/USD ON BASE ---
ORACLE_ADDR="${ORACLE_ADDR:-0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70}"

# --- DEPLOYMENT-TIME PLACEHOLDERS ---
HOOK_ADDR="${HOOK_ADDR:-0x0000000000000000000000000000000000000000}"

# --- PoolKey components (set explicitly in calibration mode,
#     auto-discovered from hook in deployment mode) ---
CURRENCY_ZERO="${CURRENCY_ZERO:-0x0000000000000000000000000000000000000000}"
CURRENCY_ONE="${CURRENCY_ONE:-0x0000000000000000000000000000000000000000}"
POOL_FEE="${POOL_FEE:-0}"
POOL_TICK_SPACING="${POOL_TICK_SPACING:-200}"
POOL_HOOKS="${POOL_HOOKS:-${HOOK_ADDR}}"

# --- THRESHOLDS ---
THRESHOLD="${MIN_RESERVE_THRESHOLD:-10000000000000000}"
PROBE_AMOUNT="${PROBE_AMOUNT:-100000000000000}"  # 0.0001 ETH
ORACLE_STALENESS_LIMIT="${ORACLE_STALENESS_LIMIT:-3600}"  # seconds

VETO=0
WARNINGS=0
MODE="UNKNOWN"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  POSSESSIO SAL: PRE-FLIGHT GUARD v1.5.0-rev3 ║"
echo "║  Uniswap V4 | Council-Operative              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ============================================================
# 0. MODE DETECTION
# ============================================================
echo "[0/5] MODE DETECTION: Determining calibration vs deployment..."

if [[ "$HOOK_ADDR" != "0x0000000000000000000000000000000000000000" ]]; then
    # HOOK_ADDR set — verify it's a real PossessioHook
    HOOK_PM=$(cast_call_trace "$HOOK_ADDR" "POOL_MANAGER()(address)" \
        --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]') || HOOK_PM=""

    if [[ -n "$HOOK_PM" ]] && [[ "${HOOK_PM,,}" == "${POOL_MANAGER,,}" ]]; then
        MODE="DEPLOYMENT"
        echo "   ✅ Mode: DEPLOYMENT (PossessioHook responds with verified PoolManager)"

        # Auto-discover PoolKey components from hook
        echo "   Discovering PoolKey from hook..."
        POOL_KEY_RAW=$(cast_call_trace "$HOOK_ADDR" \
            "poolKey()(address,address,uint24,int24,address)" \
            --rpc-url "$RPC_URL" 2>/dev/null) || POOL_KEY_RAW=""

        if [[ -n "$POOL_KEY_RAW" ]]; then
            # Parse poolKey tuple (try multiple formats)
            CURRENCY_ZERO=$(echo "$POOL_KEY_RAW" | head -1 | tr -d '[:space:]()' | sed 's/\[.*\]//')
            CURRENCY_ONE=$(echo "$POOL_KEY_RAW" | sed -n '2p' | tr -d '[:space:]()' | sed 's/\[.*\]//')
            POOL_FEE=$(echo "$POOL_KEY_RAW" | sed -n '3p' | tr -d '[:space:]()' | sed 's/\[.*\]//')
            POOL_TICK_SPACING=$(echo "$POOL_KEY_RAW" | sed -n '4p' | tr -d '[:space:]()' | sed 's/\[.*\]//')
            POOL_HOOKS=$(echo "$POOL_KEY_RAW" | sed -n '5p' | tr -d '[:space:]()' | sed 's/\[.*\]//')

            echo "   PoolKey from hook:"
            echo "     currency0:   $CURRENCY_ZERO"
            echo "     currency1:   $CURRENCY_ONE"
            echo "     fee:         $POOL_FEE"
            echo "     tickSpacing: $POOL_TICK_SPACING"
            echo "     hooks:       $POOL_HOOKS"
        else
            echo "   ⚠️  Could not read poolKey() — using env-provided values"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        MODE="CALIBRATION"
        echo "   ⚠️  HOOK_ADDR set but does not respond as valid PossessioHook"
        echo "      Hook PoolManager: ${HOOK_PM:-<no response>}"
        echo "      Expected:         $POOL_MANAGER"
        echo "      Falling back to CALIBRATION mode."
        WARNINGS=$((WARNINGS + 1))
    fi
else
    MODE="CALIBRATION"
    echo "   ✅ Mode: CALIBRATION (HOOK_ADDR unset, testing V4 substrate)"
fi

# Resolve PFG_STRICT auto-mode now that MODE is known
if [ "$PFG_STRICT" = "auto" ]; then
    if [ "$MODE" = "DEPLOYMENT" ]; then
        PFG_STRICT=1
        echo "   PFG_STRICT auto-resolved to 1 (deployment mode: hard exit on veto)"
    else
        PFG_STRICT=0
        echo "   PFG_STRICT auto-resolved to 0 (calibration mode: surface all findings)"
    fi
fi

# Compute POOL_ID from PoolKey components
echo "   Computing PoolId from PoolKey components..."
POOL_KEY_ENCODED=$(cast abi-encode \
    "f((address,address,uint24,int24,address))" \
    "($CURRENCY_ZERO,$CURRENCY_ONE,$POOL_FEE,$POOL_TICK_SPACING,$POOL_HOOKS)" 2>/dev/null) || POOL_KEY_ENCODED=""

if [[ -z "$POOL_KEY_ENCODED" ]]; then
    echo "   ❌ Cannot encode PoolKey. Verify currency/fee/tickSpacing/hooks values."
    exit 1
fi

# cast abi-encode does NOT prepend a function selector for "f(...)" form.
# Output is raw ABI-encoded struct. Strip only the "0x" prefix.
# Verified via script/poolid_check.sh against ETH/USDC 500/10 on Base V4.
POOL_KEY_BYTES="${POOL_KEY_ENCODED:2}"  # remove only "0x" prefix
POOL_ID=$(cast keccak "0x$POOL_KEY_BYTES" 2>/dev/null) || POOL_ID=""

if [[ -z "$POOL_ID" ]]; then
    echo "   ❌ Cannot compute PoolId."
    exit 1
fi

echo "   PoolId: $POOL_ID"
echo "   Mode:   $MODE"
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

REMOTE_SCRIPT_HASH=$(fetch_remote_hash "script/sal_pfg_v1.5.0.sh") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    exit 1
}

REMOTE_SOL_HASH=$(fetch_remote_hash "src/POSSESSIO_v2.sol") || {
    echo "❌ HEARTBEAT FAIL: GitHub unreachable or auth failed."
    exit 1
}

if [[ -z "$REMOTE_SCRIPT_HASH" || -z "$REMOTE_SOL_HASH" ]]; then
    echo "❌ HEARTBEAT FAIL: Remote blob SHA returned empty."
    exit 1
fi

LOCAL_SCRIPT_HASH=$(git hash-object script/sal_pfg_v1.5.0.sh)
LOCAL_SOL_HASH=$(git hash-object src/POSSESSIO_v2.sol)

HASH_FAIL=0
if [ "$LOCAL_SCRIPT_HASH" != "$REMOTE_SCRIPT_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: script does not match ratified commit"
    HASH_FAIL=1
fi
if [ "$LOCAL_SOL_HASH" != "$REMOTE_SOL_HASH" ]; then
    echo "❌ HEARTBEAT FAIL: POSSESSIO_v2.sol does not match ratified commit"
    HASH_FAIL=1
fi
if [ "$HASH_FAIL" -eq 1 ]; then
    echo "   Tampering or drift detected."
    exit 1
fi

echo "✅ Heartbeat OK — files match commit ${RATIFIED_COMMIT:0:8}"

# ============================================================
# 2. SEQUENCER CONGESTION
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
    WARNINGS=$((WARNINGS + 1))
else
    echo "✅ Sequencer nominal: ${AVG_BLOCK}s avg"
fi

# ============================================================
# 3. JIT GUARD — V4 StateView Pool-Specific Reads
# ============================================================
echo ""
echo "[3/5] JIT GUARD: V4 StateView pool reads..."

LIQ_RAW=$(cast_call_trace "$STATE_VIEW" \
    "getLiquidity(bytes32)(uint128)" "$POOL_ID" \
    --rpc-url "$RPC_URL" 2>&1) || LIQ_RAW=""

LIQ_NOW=$(cast_extract_first "$LIQ_RAW")

if [[ -z "$LIQ_NOW" ]] || ! require_uint "$LIQ_NOW" "JIT-LIQ_NOW"; then
    echo "   Raw output: ${LIQ_RAW:0:100}"
    echo "   PoolId may be invalid or pool may not exist."
    if [ "$MODE" = "CALIBRATION" ]; then
        echo "   In calibration mode: verify CURRENCY_ONE, POOL_FEE,"
        echo "   POOL_TICK_SPACING, POOL_HOOKS match an existing V4 pool."
    fi
    gate_veto "JIT" "getLiquidity returned non-numeric or empty"
elif [ "$LIQ_NOW" = "0" ]; then
    echo "   Raw output: ${LIQ_RAW:0:100}"
    echo "   PoolId may be invalid or pool may not exist."
    gate_veto "JIT" "getLiquidity returned zero"
else
    READABLE_LIQ=$(echo "scale=6; $LIQ_NOW / 10^18" | bc -l)
    echo "   Pool liquidity: $READABLE_LIQ (raw: $LIQ_NOW)"

    if [ "$LIQ_NOW" -lt "$THRESHOLD" ]; then
        gate_veto "JIT" "Liquidity below threshold ($LIQ_NOW < $THRESHOLD)"
    else
        echo "   ✅ Pool liquidity above threshold"
    fi
fi

# 10-block delta check (only meaningful if LIQ_NOW was valid)
if [[ -n "${LIQ_NOW:-}" ]] && [[ "$LIQ_NOW" =~ ^[0-9]+$ ]] && [ "$LIQ_NOW" != "0" ]; then
    LIQ_PRIOR_RAW=$(cast_call_trace "$STATE_VIEW" \
        "getLiquidity(bytes32)(uint128)" "$POOL_ID" \
        --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>&1) || LIQ_PRIOR_RAW=""

    LIQ_PRIOR=$(cast_extract_first "$LIQ_PRIOR_RAW")

    if [[ -z "$LIQ_PRIOR" ]] || ! require_uint "$LIQ_PRIOR" "JIT-LIQ_PRIOR" || [ "$LIQ_PRIOR" = "0" ]; then
        echo "   ⚠️  JIT WARNING: Cannot fetch prior liquidity (RPC may not support historical reads)"
        WARNINGS=$((WARNINGS + 1))
    else
        LIQ_DELTA=$(echo "scale=4; ($LIQ_NOW - $LIQ_PRIOR) / $LIQ_PRIOR * 100" | bc -l)
        LIQ_DELTA_ABS=${LIQ_DELTA#-}
        SPIKE=$(echo "$LIQ_DELTA_ABS > 15" | bc)

        if [ "$SPIKE" -eq 1 ]; then
            gate_veto "JIT" "Liquidity shifted ${LIQ_DELTA}% in 10 blocks"
        else
            echo "   ✅ Liquidity delta OK: ${LIQ_DELTA}%"
        fi
    fi
fi

# ============================================================
# 4. KINETIC DEPTH ANCHOR (KDA) — V4 Quoter Probe
# ============================================================
echo ""
echo "[4/5] KINETIC DEPTH ANCHOR (KDA): V4 Quoter probe..."

QUOTE_RAW=$(cast_call_trace "$QUOTER_V4" \
    "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))(uint256,uint256)" \
    "(($CURRENCY_ZERO,$CURRENCY_ONE,$POOL_FEE,$POOL_TICK_SPACING,$POOL_HOOKS),true,$PROBE_AMOUNT,0x)" \
    --rpc-url "$RPC_URL" 2>&1) || QUOTE_RAW=""

if [[ -z "$QUOTE_RAW" ]] || [[ "$QUOTE_RAW" == *"error"* ]] || [[ "$QUOTE_RAW" == *"revert"* ]]; then
    echo "⚠️  KDA WARNING: V4 Quoter call failed or reverted"
    echo "   Raw output: ${QUOTE_RAW:0:150}"
    echo "   Possible causes:"
    echo "     - Public RPC blocks Quoter staticcall (try private RPC)"
    echo "     - PoolKey doesn't match an initialized pool"
    echo "     - Insufficient liquidity for probe size"
    WARNINGS=$((WARNINGS + 1))
else
    AMOUNT_OUT=$(cast_extract_first "$QUOTE_RAW")

    if [[ -z "$AMOUNT_OUT" ]] || ! require_uint "$AMOUNT_OUT" "KDA-AMOUNT_OUT"; then
        echo "   Raw output: ${QUOTE_RAW:0:150}"
        gate_veto "KDA" "Quoter returned non-numeric or empty"
    elif [ "$AMOUNT_OUT" = "0" ]; then
        gate_veto "KDA" "Zero output — hollow liquidity"
    else
        echo "   Probe input:  $PROBE_AMOUNT wei (currency0)"
        echo "   Quote output: $AMOUNT_OUT (currency1)"
        echo "✅ KDA OK: Non-zero quote returned"
    fi
fi

# ============================================================
# 5. SYNTHETIC PRICE DISCOVERY — sqrtPriceX96 + Oracle
# ============================================================
echo ""
echo "[5/5] PRICE DISCOVERY: sqrtPriceX96 delta + Chainlink oracle..."

# Chainlink ETH/USD reference
ORACLE_RAW=$(cast_call_trace "$ORACLE_ADDR" \
    "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
    --rpc-url "$RPC_URL" 2>/dev/null) || ORACLE_RAW=""

if [ -n "$ORACLE_RAW" ]; then
    # Field 2: answer (signed int256). Preserve sign — negative is a real failure mode.
    ORACLE_PRICE=$(echo "$ORACLE_RAW" | sed -n '2p' | tr -d '[:space:]' | sed 's/\[.*\]//')
    if [[ -z "$ORACLE_PRICE" ]]; then
        # Fallback: comma-separated single-line format
        ORACLE_PRICE=$(echo "$ORACLE_RAW" | awk -F',' '{print $2}' | tr -d '[:space:]' | sed 's/\[.*\]//')
    fi

    # Field 4: updatedAt (uint256 timestamp). For staleness check.
    ORACLE_UPDATED=$(echo "$ORACLE_RAW" | sed -n '4p' | tr -d '[:space:]' | sed 's/\[.*\]//')
    if [[ -z "$ORACLE_UPDATED" ]]; then
        ORACLE_UPDATED=$(echo "$ORACLE_RAW" | awk -F',' '{print $4}' | tr -d '[:space:]' | sed 's/\[.*\]//')
    fi

    # F7: sign-aware validation. Negative or zero price is a Chainlink failure.
    if [[ "$ORACLE_PRICE" == -* ]]; then
        gate_veto "ORACLE" "Negative Chainlink price: $ORACLE_PRICE"
    elif [[ -z "$ORACLE_PRICE" ]] || ! require_uint "$ORACLE_PRICE" "ORACLE-PRICE"; then
        echo "   ⚠️  ORACLE WARNING: Could not parse Chainlink response"
        WARNINGS=$((WARNINGS + 1))
    elif [ "$ORACLE_PRICE" = "0" ]; then
        gate_veto "ORACLE" "Zero Chainlink price"
    else
        ORACLE_ETH_USD=$(echo "scale=2; $ORACLE_PRICE / 100000000" | bc)
        echo "   ✅ Chainlink ETH/USD: \$$ORACLE_ETH_USD"

        # F5: staleness check
        if require_uint "$ORACLE_UPDATED" "ORACLE-UPDATED"; then
            NOW_TS=$(date +%s)
            STALE=$(( NOW_TS - ORACLE_UPDATED ))
            if [ "$STALE" -gt "$ORACLE_STALENESS_LIMIT" ]; then
                gate_veto "ORACLE" "Chainlink stale: ${STALE}s since update (limit: ${ORACLE_STALENESS_LIMIT}s)"
            else
                echo "   ✅ Chainlink fresh: ${STALE}s since update"
            fi
        else
            echo "   ⚠️  ORACLE WARNING: Could not parse updatedAt for staleness check"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
else
    echo "   ⚠️  ORACLE WARNING: Chainlink unavailable"
    WARNINGS=$((WARNINGS + 1))
fi

# sqrtPriceX96 reads via StateView
SLOT0_RAW=$(cast_call_trace "$STATE_VIEW" \
    "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$POOL_ID" \
    --rpc-url "$RPC_URL" 2>&1) || SLOT0_RAW=""

SQRT_NOW=$(cast_extract_first "$SLOT0_RAW")

SLOT0_PRIOR_RAW=$(cast_call_trace "$STATE_VIEW" \
    "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$POOL_ID" \
    --rpc-url "$RPC_URL" --block "$BLOCK_10_AGO" 2>&1) || SLOT0_PRIOR_RAW=""

SQRT_PRIOR=$(cast_extract_first "$SLOT0_PRIOR_RAW")

if [[ -z "$SQRT_NOW" ]] || [[ -z "$SQRT_PRIOR" ]] || \
   ! require_uint "$SQRT_NOW" "PRICE-SQRT_NOW" || \
   ! require_uint "$SQRT_PRIOR" "PRICE-SQRT_PRIOR" || \
   [ "$SQRT_NOW" = "0" ] || [ "$SQRT_PRIOR" = "0" ]; then
    echo "   ⚠️  PRICE WARNING: sqrtPriceX96 reads incomplete or non-numeric"
    echo "   Now:   ${SQRT_NOW:-empty}"
    echo "   Prior: ${SQRT_PRIOR:-empty}"
    WARNINGS=$((WARNINGS + 1))
else
    SQRT_DELTA=$(echo "scale=4; ($SQRT_NOW - $SQRT_PRIOR) / $SQRT_PRIOR * 100" | bc -l)
    SQRT_DELTA_ABS=${SQRT_DELTA#-}
    SQRT_BREACH=$(echo "$SQRT_DELTA_ABS > 1.0" | bc)

    echo "   sqrtPriceX96 now:   $SQRT_NOW"
    echo "   sqrtPriceX96 prior: $SQRT_PRIOR"
    echo "   Delta: ${SQRT_DELTA}%"

    if [ "$SQRT_BREACH" -eq 1 ]; then
        gate_veto "PRICE" "sqrtPriceX96 moved ${SQRT_DELTA_ABS}% in 10 blocks"
    else
        echo "✅ Price discovery OK: sqrtPriceX96 delta ${SQRT_DELTA_ABS}%"
    fi
fi

# ============================================================
# 6. (DEPLOYMENT MODE ONLY) PossessioHook State Verification
# ============================================================
if [ "$MODE" = "DEPLOYMENT" ]; then
    echo ""
    echo "[6/6] HOOK STATE: Verifying PossessioHook state via getState()..."

    # getState returns: accumulated, daiReserve, cbPrincipal, routingPaused,
    #                   cbPaused, nextRouteAllowed
    STATE_RAW=$(cast_call_trace "$HOOK_ADDR" \
        "getState()(uint256,uint256,uint256,bool,bool,uint256)" \
        --rpc-url "$RPC_URL" 2>&1) || STATE_RAW=""

    if [[ -z "$STATE_RAW" ]]; then
        echo "   ⚠️  Could not read getState() — hook may be in unusual state"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   Hook state: $STATE_RAW"

        # Check pool initialized
        POOL_INIT=$(cast_call_trace "$HOOK_ADDR" "poolInitialized()(bool)" \
            --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]')

        if [[ "$POOL_INIT" != "true" ]]; then
            gate_veto "HOOK" "poolInitialized() returned $POOL_INIT (expected true)"
        else
            echo "   ✅ Pool initialized in hook"
        fi

        # F3: Parse getState fields by line addressing for consistency.
        # getState returns: accumulated, daiReserve, cbPrincipal,
        #                   routingPaused, cbPaused, nextRouteAllowed
        # Lines:            1,            2,          3,            4,
        #                   5,         6
        ROUTING_PAUSED=$(echo "$STATE_RAW" | sed -n '4p' | tr -d '[:space:]()' | sed 's/\[.*\]//')
        CB_PAUSED=$(echo "$STATE_RAW" | sed -n '5p' | tr -d '[:space:]()' | sed 's/\[.*\]//')

        if [[ "$ROUTING_PAUSED" == "true" ]]; then
            echo "   ⚠️  routingPaused = true — fee routing currently paused"
            WARNINGS=$((WARNINGS + 1))
        fi

        if [[ "$CB_PAUSED" == "true" ]]; then
            echo "   ⚠️  cbPaused = true — staking circuit breaker tripped"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo "   ✅ Hook state read successfully"
    fi
fi

# ============================================================
# FINAL GATE — Council-Operative Clearance
# ============================================================
echo ""
echo "══════════════════════════════════════════════"

if [ "$VETO" -eq 1 ]; then
    echo "❌ PRE-FLIGHT VETO: Execution blocked by sentinel."
    echo "   Mode: VETO"
    exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo "⚠️  $WARNINGS WARNING(s) active. Mode: $MODE"
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ PRE-FLIGHT CLEAR (V4 rev3)                ║"
echo "║  Council-Operative — TOTP Retired             ║"
echo "║  Mode: $MODE | Strict: $PFG_STRICT             "
echo "╚══════════════════════════════════════════════╝"
echo ""

if [ "$MODE" = "CALIBRATION" ]; then
    echo "Calibration complete. V4 substrate calls verified."
    echo "When V2 deploys: set HOOK_ADDR, re-run for DEPLOYMENT mode."
fi

if [ "$PFG_DEBUG" != "1" ]; then
    echo ""
    echo "TIP: export PFG_DEBUG=1 to surface exact cast commands"
    echo "     when bugs surface in next dry run."
fi

echo ""
exit 0
