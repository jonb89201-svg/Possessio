#!/usr/bin/env python3
"""
oracle_sgc_v3.py - branch-for-branch mirror of SymmetryGuardCore v3's observe +
typed additive penalty math. Certifies the NEW logic (base toll, RoundTrip + DustSpam
additive penalties, total clamp, dust read-time decay) in a plain terminal - no forge,
no V4. The Solidity is written to match this; the forge gauntlet confirms on-chain.

Runs the change-spec S9 teeth.
"""

# ---- constants: identical to the Solidity ----
BASE_FEE_BPS      = 200
MAX_TOTAL_FEE_BPS = 500
HEADROOM          = MAX_TOTAL_FEE_BPS - BASE_FEE_BPS   # 300
WINDOW_BLOCKS     = 3
DECAY_BLOCKS      = 50
DECAY_AMT         = 2
MIRROR_TOL_BPS    = 500
MIN_OBSERVATIONS  = 6
FLAG_NUM, FLAG_DEN = 3, 4
PUNITIVE_SLOPE_BPS = 25
DUST_SPAM_BAND_MULT     = 5
DUST_SPAM_WINDOW_BLOCKS = 20
DUST_SPAM_MIN_HITS      = 10
DUST_SPAM_SLOPE_BPS     = 25
U32MAX = 2**32 - 1

DUST_FLOOR = 1_000_000      # $1 @ 6dp (test deployment)
BAND_HI = DUST_FLOOR * DUST_SPAM_BAND_MULT   # 5e6

def mirrors(a, b):
    if a < DUST_FLOOR or b < DUST_FLOOR: return False
    lo, hi = (a, b) if a < b else (b, a)
    return hi * 10_000 <= lo * (10_000 + MIRROR_TOL_BPS)

def sat_inc(x): return x if x == U32MAX else x + 1

class Slot:
    def __init__(s):
        s.lastBlock=0; s.lastZ=False; s.lastAbs=0
        s.shapeHits=0; s.observations=0; s.shapeBlock=0
        s.dustHits=0; s.dustBlock=0

class Guard:
    def __init__(g): g.slots={}
    def _s(g,key): return g.slots.setdefault(key, Slot())

    def _decShape(g,s,blk):
        if s.shapeHits==0 or s.shapeBlock==0: return s.shapeHits
        el=blk-s.shapeBlock
        if el<=DECAY_BLOCKS: return s.shapeHits
        bleed=(el//DECAY_BLOCKS)*DECAY_AMT
        return 0 if bleed>=s.shapeHits else s.shapeHits-bleed

    def _decDust(g,s,blk):
        if s.dustHits==0 or s.dustBlock==0: return s.dustHits
        el=blk-s.dustBlock
        if el<=DUST_SPAM_WINDOW_BLOCKS: return s.dustHits
        bleed=(el//DUST_SPAM_WINDOW_BLOCKS)*DECAY_AMT
        return 0 if bleed>=s.dustHits else s.dustHits-bleed

    def observe(g, key, z, absIn, blk):
        s=g._s(key)
        if absIn < DUST_FLOOR:
            return
        dec=g._decShape(s,blk)
        if dec!=s.shapeHits: s.shapeHits=dec; s.shapeBlock=blk
        if s.lastBlock!=0:
            gap=blk-s.lastBlock
            if gap<=WINDOW_BLOCKS and z!=s.lastZ and mirrors(absIn,s.lastAbs):
                s.shapeHits=sat_inc(s.shapeHits); s.shapeBlock=blk
        s.lastBlock=blk; s.lastZ=z; s.lastAbs=min(absIn,2**128-1)
        s.observations=sat_inc(s.observations)
        if absIn < BAND_HI:
            dd=g._decDust(s,blk)
            if dd!=s.dustHits: s.dustHits=dd
            s.dustHits=sat_inc(s.dustHits); s.dustBlock=blk

    # ---- typed additive penalties (read at block blk) ----
    def _flagRT(g,s,blk):
        if s.observations<MIN_OBSERVATIONS: return False
        return g._decShape(s,blk)*FLAG_DEN >= s.observations*FLAG_NUM
    def _penRT(g,s,blk):
        if not g._flagRT(s,blk): return 0
        hits=g._decShape(s,blk)
        gate=(s.observations*FLAG_NUM + FLAG_DEN-1)//FLAG_DEN
        over=hits-gate if hits>gate else 0
        return min((over+1)*PUNITIVE_SLOPE_BPS, HEADROOM)
    def _penDust(g,s,blk):
        hits=g._decDust(s,blk)
        if hits<DUST_SPAM_MIN_HITS: return 0
        over=hits-DUST_SPAM_MIN_HITS
        return min((over+1)*DUST_SPAM_SLOPE_BPS, HEADROOM)
    def assess(g,key,blk):
        s=g._s(key); base=BASE_FEE_BPS
        rt=g._penRT(s,blk); d=g._penDust(s,blk)
        total=min(base+rt+d, MAX_TOTAL_FEE_BPS)
        return base,rt,d,total

PASS="[PASS]"; FAIL="[FAIL]"; fails=0
def check(n,c):
    global fails
    print(f"  {PASS if c else FAIL} {n}")
    if not c: fails+=1

print("="*72)
print("ORACLE - SymmetryGuardCore v3 typed-additive toll (change-spec S9 teeth)")
print("="*72)
LEG=100_000_000      # normal leg ($100): not small, not dust
SMALL=2_000_000      # $2: in band [1e6,5e6) -> dust-spam band
K="A0/POOL"

# 1. honest trader, no triggers -> exactly 200
g=Guard(); blk=1
for i in range(12):
    blk+=10; g.observe(K, True, LEG, blk)   # same dir, spaced -> no shape, not small
b,rt,d,t=g.assess(K,blk)
check(f"honest -> exactly base 200 (got {t}, rt={rt}, d={d})", t==200 and rt==0 and d==0)

# 2. round-trip extractor -> base + scaling rt penalty
g=Guard(); blk=1; dir=True
for i in range(16):
    blk+=1; g.observe(K, dir, LEG, blk); dir=not dir
b,rt,d,t=g.assess(K,blk)
check(f"round-trip extractor -> base+rt, no dust (rt={rt}, d={d}, total={t})", rt>0 and d==0 and t>200)

# 3. dust-spammer -> base + scaling dust penalty (same dir small flood, no mirror)
g=Guard(); blk=1
for i in range(14):
    blk+=2; g.observe(K, True, SMALL, blk)   # every 2 blocks (< window 20), same dir
b,rt,d,t=g.assess(K,blk)
check(f"dust-spammer -> base+dust, no rt (rt={rt}, d={d}, total={t})", d>0 and rt==0 and t>200)

# 4. trader doing BOTH -> base + both, summed (small + mirrored + alternating + rapid)
g=Guard(); blk=1; dir=True
for i in range(24):
    blk+=1; g.observe(K, dir, SMALL, blk); dir=not dir
b,rt,d,t=g.assess(K,blk)
check(f"BOTH triggers -> base+rt+dust summed (rt={rt}, d={d}, total={t})", rt>0 and d>0)

# 5. any combination -> total never exceeds 500
check(f"total clamped <= 500 (got {t})", t<=500)

# 6. borderline (just over a gate) -> small penalty, never frozen
g=Guard(); blk=1; dir=True
# build exactly to the 75% gate with minimal over: 6 obs, ~5 hits
for i in range(6):
    blk+=1; g.observe(K, dir, LEG, blk); dir=not dir
b,rt,d,t=g.assess(K,blk)
check(f"borderline flagged -> small nonzero rt, total<500 (rt={rt}, total={t})", rt>0 and t<500)

# 7. dust legs below floor -> excluded, no dust trigger
g=Guard(); blk=1
for i in range(30):
    blk+=1; g.observe(K, i%2==0, DUST_FLOOR-1, blk)
b,rt,d,t=g.assess(K,blk)
check(f"sub-floor legs excluded -> base only (rt={rt}, d={d}, total={t})", t==200 and d==0 and rt==0)

# 8. honest high-frequency SMALL trader spaced beyond window -> NOT dust-flagged
g=Guard(); blk=1
for i in range(30):
    blk+=DUST_SPAM_WINDOW_BLOCKS+1; g.observe(K, True, SMALL, blk)  # each gap > window -> never clusters
b,rt,d,t=g.assess(K,blk)
check(f"honest spaced small trader -> NOT dust-flagged (d={d}, total={t})", d==0 and t==200)

# 9. flooding own slot cannot inflate a victim's counters (separate keys independent)
g=Guard(); blk=1; dir=True
for i in range(24):
    blk+=1; g.observe("ATK/POOL", dir, SMALL, blk); dir=not dir
_,_,_,tv=g.assess("VICTIM/POOL", blk)
check(f"victim slot untouched by attacker flood (victim total={tv})", tv==200)

# 10. flagged actor stops -> all triggers decay to base (self-cure)
g=Guard(); blk=1; dir=True
for i in range(24):
    blk+=1; g.observe(K, dir, SMALL, blk); dir=not dir
_,rt0,d0,t0=g.assess(K,blk)
blk += DUST_SPAM_WINDOW_BLOCKS*200 + DECAY_BLOCKS*200   # long idle
b,rt,d,t=g.assess(K,blk)
check(f"self-cure on cessation: flagged({t0}) -> base {t} (rt={rt}, d={d})", t==200 and rt==0 and d==0)

# 11. Tolled itemization stays legible even at clamp
g=Guard(); blk=1; dir=True
for i in range(60):
    blk+=1; g.observe(K, dir, SMALL, blk); dir=not dir
b,rt,d,t=g.assess(K,blk)
check(f"itemized at clamp: base={b} rt={rt} dust={d} -> total clamps {t}==500", t==500 and (b+rt+d)>=500)

# 12. honest high-volume whale: round-trips a MINORITY of flow -> base only
g=Guard(); blk=1; dr=True
for cyc in range(10):
    blk+=1; g.observe(K, dr, LEG, blk)
    blk+=1; g.observe(K, (not dr), LEG, blk)
    for j in range(8):
        blk+=1; g.observe(K, True, LEG + j*DUST_FLOOR, blk)
    dr = not dr
b,rt,d,t=g.assess(K,blk)
check(f"honest whale (minority round-trips) -> base only (rt={rt}, d={d}, total={t})", t==200 and rt==0 and d==0)

print("\n"+"="*72)
if fails==0:
    print("ORACLE: all S9 teeth GREEN. base=200 floor; RoundTrip + DustSpam additive and")
    print("itemized; total clamped at 500; both triggers self-cure; honest pays exactly base.")
    print("The Solidity is written to match - run the forge gauntlet to confirm on-chain.")
else:
    print(f"ORACLE: {fails} RED. Logic mismatch - fix before trusting v3.")
print("="*72)
