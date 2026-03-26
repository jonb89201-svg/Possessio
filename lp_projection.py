# ============================================================
# POSSESSIO PROTOCOL — LP Depth Projection Model
# ============================================================
# Complete model including all four LP sources:
# 1. Protocol swap fee injections (25% of 1% fee)
# 2. Aerodrome AERO incentive emissions
# 3. Organic community LP provision
# 4. cbETH yield reinvestment (25% of staking yield)
# Plus: $PITI price appreciation effect on USD LP value
#
# Protocol:  POSSESSIO
# Token:     $PITI
# Network:   Base
# Treasury:  0x188bE439C141c9138Bd3075f6A376F73c07F1903
# ============================================================

DAILY_VOLUME    = 20000   # $20K/day swap volume
SWAP_FEE        = 0.01    # 1% fee
LP_SPLIT        = 0.25    # 25% of fees to LP
INITIAL_SEED    = 500     # Launch seed liquidity
STAKING_APY     = 0.03    # 3% blended ETH staking yield
YIELD_TO_LP     = 0.25    # 25% of yield to LP

daily_fees         = DAILY_VOLUME * SWAP_FEE        # $200/day
daily_lp_injection = daily_fees * LP_SPLIT          # $50/day

# ── SOURCE 1: Protocol Fee Injections ────────────────────────
# 25% of 1% swap fee injected daily
# Immutable — cannot be changed
# $50/day at $20K volume

# ── SOURCE 2: Aerodrome AERO Incentives ──────────────────────
# Aerodrome rewards popular pairs with AERO emissions
# LPs earn trading fees + AERO — attracts external capital
def aerodrome_monthly_incentive(month):
    if month <= 2:    return 500
    elif month <= 4:  return 2000
    elif month <= 6:  return 5000
    elif month <= 9:  return 8000
    elif month <= 12: return 12000
    else:             return 15000

# ── SOURCE 3: Organic Community LP ───────────────────────────
# Buyers who provide LP to earn trading fees
# Grows with token adoption and community size
def organic_lp_monthly(month):
    if month == 1:    return 2000
    elif month == 2:  return 1000
    elif month <= 4:  return 1500
    elif month <= 6:  return 2500
    elif month <= 9:  return 4000
    elif month <= 12: return 6000
    else:             return 8000

# ── SOURCE 4: Yield Reinvestment ─────────────────────────────
# 25% of cbETH staking yield reinvested into LP
# Grows as treasury compounds
def yield_lp_monthly(treasury):
    annual_yield = treasury * STAKING_APY
    return (annual_yield * YIELD_TO_LP) / 12

# ── PRICE APPRECIATION ───────────────────────────────────────
# Conservative estimate of $PITI price appreciation
# Increases USD value of existing LP
def price_multiplier(month):
    if month <= 3:    return 1.0
    elif month <= 6:  return 1.5
    elif month <= 9:  return 2.5
    elif month <= 12: return 4.0
    elif month <= 18: return 8.0
    elif month <= 24: return 15.0
    else:             return 25.0

# ── SIMULATION ───────────────────────────────────────────────
def run_simulation():
    raw_lp   = INITIAL_SEED
    treasury = 5000

    milestones = {
        50000:   "$50K  — Option A threshold",
        100000:  "$100K — Option B threshold",
        500000:  "$500K — Option C threshold",
        1000000: "$1M   — TWAP scales to 1hr",
    }
    shown_raw   = set()
    shown_price = set()

    totals = {
        'fees': 0, 'aero': 0,
        'organic': 0, 'yield': 0
    }

    print("=" * 90)
    print("POSSESSIO LP DEPTH PROJECTION — COMPLETE MODEL")
    print(f"Base volume: ${DAILY_VOLUME:,}/day | Seed: ${INITIAL_SEED:,} | Daily LP injection: ${daily_lp_injection}/day")
    print("Sources: Protocol fees + Aerodrome incentives + Organic LP + Yield reinvestment")
    print("=" * 90)
    print(f"{'Mo':>3} | {'Fees':>7} | {'Aero':>7} | {'Organic':>8} | {'Yield':>6} | {'Raw LP':>10} | {'w/Price':>12} | Notes")
    print("-" * 90)

    for month in range(1, 25):
        monthly_fee = daily_lp_injection * 30
        aero        = aerodrome_monthly_incentive(month)
        organic     = organic_lp_monthly(month)
        y_lp        = yield_lp_monthly(treasury)

        totals['fees']    += monthly_fee
        totals['aero']    += aero
        totals['organic'] += organic
        totals['yield']   += y_lp

        treasury += (daily_fees * 0.75 * 30) - 95
        raw_lp   += monthly_fee + aero + organic + y_lp
        price_lp  = raw_lp * price_multiplier(month)

        note = ""
        for t, label in milestones.items():
            if raw_lp >= t and t not in shown_raw:
                note = f"RAW: ✓ {label}"
                shown_raw.add(t)
            if price_lp >= t and t not in shown_price:
                note = f"PRICE: ✓ {label}"
                shown_price.add(t)

        if month == 9:
            note = "◄ AGENT LAYER GATE"

        print(
            f"{month:>3} | "
            f"${monthly_fee:>6,.0f} | "
            f"${aero:>6,.0f} | "
            f"${organic:>7,.0f} | "
            f"${y_lp:>5,.0f} | "
            f"${raw_lp:>9,.0f} | "
            f"${price_lp:>11,.0f} | "
            f"{note}"
        )

    print("=" * 90)
    print(f"\nCUMULATIVE LP SOURCES AT MONTH 24:")
    print(f"  Initial seed:          ${INITIAL_SEED:>10,.0f}")
    print(f"  Fee injections:        ${totals['fees']:>10,.0f}")
    print(f"  Aerodrome incentives:  ${totals['aero']:>10,.0f}")
    print(f"  Organic LP:            ${totals['organic']:>10,.0f}")
    print(f"  Yield reinvestment:    ${totals['yield']:>10,.0f}")
    total = INITIAL_SEED + sum(totals.values())
    print(f"  ─────────────────────────────────────")
    print(f"  Total raw LP:          ${total:>10,.0f}")
    print(f"\nKEY MILESTONES (raw LP, no price appreciation):")
    print(f"  $50K  threshold:  Month ~8  (Option A agent gate)")
    print(f"  $100K threshold:  Month ~11 (Option B agent gate)")
    print(f"\nKEY MILESTONES (with conservative price appreciation):")
    print(f"  $50K  threshold:  Month ~6")
    print(f"  $100K threshold:  Month ~7")
    print(f"  $500K threshold:  Month ~12")
    print(f"  $1M   threshold:  Month ~13 (TWAP scales to 1hr)")
    print(f"\nAGENT LAYER AT MONTH 9:")
    print(f"  Raw LP:           ~$76,000")
    print(f"  Price-adjusted:   ~$190,000")
    print(f"  Recommendation:   $50K raw threshold is met ✓")
    print(f"  4-hour TWAP:      Active and protecting ✓")
    print(f"  15% circuit:      Active and protecting ✓")
    print(f"\nPOSSESSIO Protocol — github.com/jonb89201-svg/Possessio")

if __name__ == "__main__":
    run_simulation()
