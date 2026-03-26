# ============================================================
# POSSESSIO PROTOCOL — Treasury Sustainability Model
# ============================================================
# Models how cbETH staking yield funds free public searches
# Treasury grows from $PITI swap fees → deployed to cbETH
# Yield covers API costs → index stays free forever
#
# Protocol:  POSSESSIO
# Token:     $PITI
# Network:   Base
# Treasury:  0x188bE439C141c9138Bd3075f6A376F73c07F1903
# GitHub:    github.com/jonb89201-svg/Possessio
# ============================================================

# ── CONSTANTS ────────────────────────────────────────────────

STAKING_APY       = 0.035   # 3.5% annual yield on cbETH
API_COST_PER_CALL = 0.05    # $0.05 per search (BatchData + First Street)
DAYS_IN_YEAR      = 365
SWAP_FEE_PCT      = 0.01    # 1% fee on every $PITI swap
TREASURY_SPLIT    = 0.75    # 75% of swap fees go to treasury
YIELD_TO_LP       = 0.25    # 25% of yield reinvested into LP
YIELD_TO_OPS      = 0.75    # 75% of yield funds operations (API costs)

# ── CORE FUNCTIONS ───────────────────────────────────────────

def calculate_daily_capacity(treasury_balance_usd):
    """
    How many free searches can yield fund per day?
    Only uses the operational portion of yield (75%)
    """
    annual_yield     = treasury_balance_usd * STAKING_APY
    operational_yield = annual_yield * YIELD_TO_OPS
    daily_yield      = operational_yield / DAYS_IN_YEAR
    searches_per_day = daily_yield / API_COST_PER_CALL
    return round(searches_per_day)


def monthly_yield(treasury_balance_usd):
    """Total monthly yield from staked treasury"""
    return round(treasury_balance_usd * STAKING_APY / 12, 2)


def operational_monthly_yield(treasury_balance_usd):
    """Monthly yield available for API costs (75% of total yield)"""
    return round(monthly_yield(treasury_balance_usd) * YIELD_TO_OPS, 2)


def lp_monthly_yield(treasury_balance_usd):
    """Monthly yield reinvested into LP (25% of total yield)"""
    return round(monthly_yield(treasury_balance_usd) * YIELD_TO_LP, 2)


def treasury_needed_for_api(monthly_api_cost):
    """How large does the treasury need to be to fund an API tier from yield alone?"""
    annual_cost   = monthly_api_cost * 12
    needed        = annual_cost / (STAKING_APY * YIELD_TO_OPS)
    return round(needed, 2)


def volume_to_fill_treasury(target_treasury_usd):
    """How much swap volume needed to build the treasury to target size?"""
    treasury_per_dollar = SWAP_FEE_PCT * TREASURY_SPLIT
    return round(target_treasury_usd / treasury_per_dollar, 2)


def daily_volume_for_api(monthly_api_cost):
    """Daily swap volume needed to directly cover an API cost from fees"""
    daily_api = monthly_api_cost / 30
    daily_treasury_per_dollar = SWAP_FEE_PCT * TREASURY_SPLIT
    return round(daily_api / daily_treasury_per_dollar, 2)


# ── SUSTAINABILITY TABLE ──────────────────────────────────────

def print_sustainability_table():
    balances = [1_000, 5_000, 8_268, 10_000, 25_000, 32_571,
                50_000, 100_000, 171_429, 250_000, 500_000]

    print("\n" + "=" * 80)
    print("POSSESSIO TREASURY SUSTAINABILITY MODEL")
    print("cbETH APY: 3.5% | API Cost: $0.05/search | Yield Split: 25% LP / 75% Ops")
    print("=" * 80)
    print(f"{'Treasury':>12} | {'Daily Searches':>14} | {'Monthly Yield':>13} | {'To LP/mo':>10} | {'To Ops/mo':>10}")
    print("-" * 80)

    for b in balances:
        label = ""
        if b == 8_268:   label = " ← Day 16"
        if b == 32_571:  label = " ← ATTOM funded"
        if b == 171_429: label = " ← Full API funded"

        print(
            f"${b:>11,} | "
            f"{calculate_daily_capacity(b):>14,} | "
            f"${monthly_yield(b):>12,} | "
            f"${lp_monthly_yield(b):>9,} | "
            f"${operational_monthly_yield(b):>9,}"
            f"{label}"
        )

    print("=" * 80)


# ── API TIER MILESTONES ───────────────────────────────────────

def print_api_milestones():
    tiers = [
        ("ATTOM Entry",             95),
        ("ATTOM + Basic Insurance", 500),
        ("Full Institutional",      2_500),
    ]

    print("\n── API TIER FUNDING MILESTONES ─────────────────────────────────────────────")
    print(f"{'API Tier':>28} | {'Monthly Cost':>12} | {'Treasury Needed':>15} | {'Daily Volume':>12}")
    print("-" * 80)

    for name, cost in tiers:
        needed = treasury_needed_for_api(cost)
        daily_vol = daily_volume_for_api(cost)
        print(f"{name:>28} | ${cost:>11,} | ${needed:>14,} | ${daily_vol:>11,}")

    print("-" * 80)


# ── FLYWHEEL SIMULATION ───────────────────────────────────────

def simulate_flywheel(daily_volume_usd, days=180, initial_treasury=0):
    """
    Simulate treasury growth and LP depth over time
    Shows how swap fees build treasury which generates yield
    """
    treasury = initial_treasury
    lp_depth = 200  # Starting LP in USD

    print(f"\n── FLYWHEEL SIMULATION: ${daily_volume_usd:,}/day for {days} days ────────────────")
    print(f"{'Day':>5} | {'Treasury':>12} | {'LP Depth':>10} | {'Daily Searches':>14} | {'Milestone'}")
    print("-" * 75)

    milestones = {
        32_571:  "ATTOM funded from yield",
        171_429: "Full API funded from yield",
    }

    shown = set()
    checkpoints = [1, 7, 14, 30, 60, 90, 120, 150, 180]

    for day in range(1, days + 1):
        # Daily fee income
        daily_fees      = daily_volume_usd * SWAP_FEE_PCT
        lp_injection    = daily_fees * (1 - TREASURY_SPLIT)
        treasury_income = daily_fees * TREASURY_SPLIT

        # Daily yield on treasury
        daily_yield_total = treasury * STAKING_APY / DAYS_IN_YEAR
        yield_to_lp       = daily_yield_total * YIELD_TO_LP
        yield_to_treasury = daily_yield_total * YIELD_TO_OPS

        # Update balances
        treasury += treasury_income + yield_to_treasury
        lp_depth += lp_injection + yield_to_lp

        # Check milestones
        milestone = ""
        for threshold, label in milestones.items():
            if treasury >= threshold and threshold not in shown:
                milestone = f"★ {label}"
                shown.add(threshold)

        if day in checkpoints or milestone:
            print(
                f"{day:>5} | "
                f"${treasury:>11,.0f} | "
                f"${lp_depth:>9,.0f} | "
                f"{calculate_daily_capacity(treasury):>14,} | "
                f"{milestone}"
            )

    print("-" * 75)


# ── MAIN ─────────────────────────────────────────────────────

if __name__ == "__main__":
    print_sustainability_table()
    print_api_milestones()

    # Optimistic scenario — $500/day volume
    simulate_flywheel(daily_volume_usd=500, days=180, initial_treasury=0)

    # Strong scenario — $2,000/day volume
    simulate_flywheel(daily_volume_usd=2_000, days=180, initial_treasury=0)

    print("\nPOSSESSIO Protocol — possessio.io")
    print("Treasury: 0x188bE439C141c9138Bd3075f6A376F73c07F1903")
    print("GitHub:   github.com/jonb89201-svg/Possessio")
