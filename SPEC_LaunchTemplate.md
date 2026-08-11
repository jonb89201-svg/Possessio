# SPEC — V3 Launch Template: the coin, the pair, the owner's 2%

**Type:** Protocol-layer spec (draft → council review → Architect ratification → DoD → fork-proof)
**Seat:** Fathom (Code lane) — specifying after a full read of `POSSESSIO_v2-6-3.sol` (2,223 lines).
**Status:** DRAFT FOR COUNCIL. Two rulings are OPEN (§5) and everything downstream of them
is held. Companion to `SPEC_CouncilToken.md` — the two specs describe one machine and
should be read together.
**Prior rulings captured (Architect, 2026-08-11):** a launch IS a V3 — the 2% fee
machine — and the fee goes to whoever deployed it. Launches pair against the council
token. The council economy never touches ETH (§2).

---

## 0. Creed (the standing test — every clause below must pass)

> **Non-extraction with full sovereignty. Immutable and deterministic at its core.
> On-chain transparency.**

Cold seats review in order: (1) does it skim beyond the front door? (2) does it owe
anyone the right to exist? (3) can it change later, or land at an unpredicted address?
(4) can a stranger verify it without permission?

## 1. What a launch IS

The product a stranger buys from the launchpad for the one-time deployment fee:

- **Their coin** — a token they own outright.
- **Their market** — a Uniswap v4 pool initialized against the COUNCIL TOKEN in the
  same atomic transaction (enforced by `PossessioLaunchFactory`, already on main —
  a launch not paired against the council token is not expressible in that bytecode).
- **Their 2%** — the V3 fee engine (`beforeSwap` capture, Balanced Delta pattern,
  `FEE_BPS = 200`) with the fee routed to **the launch owner**. Not to POSSESSIO.
  The protocol is paid once, at the door. (Architect ruling, 2026-08-11.)

What a launch is NOT: it is not STEEL. STEEL is the protocol's own V3 — one instance,
its own ETH pool, the full treasury engine (cbETH legs, Chainlink Automation, X-LINK,
embedded SAV). None of that machinery ships in the launch template. The launch is the
*small-business* V3: coin, pair, fee, owner. Sovereignty in a box.

## 2. The currency ladder (context — why the pair target is fixed)

```
ETH  <->  STEEL  <->  COUNCIL TOKEN  <->  every launched V3
```

- STEEL/ETH is the ONLY gate to outside money, and it is POSSESSIO's own machine.
- Council seats hold STEEL (SAV). They never hold ETH. A council buying another
  council's V3 allocation walks: STEEL -> council token -> allocation.
- The AI economy is fenced entirely inside protocol-issued assets. Custody boundary
  and regulatory boundary in one structure.
- **Fee-in-the-denominator (measured consequence, new to this spec):** because a
  launch's pool is against the council token, the owner's 2% arrives denominated in
  the pair's assets — every trading launch makes its owner an accumulator of the
  council token. Demand for the denominator is built into every launch's income
  stream. This property should be ratified into `SPEC_CouncilToken` §7 wording.
- The ladder needs its middle rung deployed: a **STEEL <-> council token pair** (or
  council-token genesis lines for the seats). Deploy-plan item, Architect-ratified
  numbers.

## 3. What the template KEEPS from V3, DROPS, and REDIRECTS

**Keeps (proven mechanism, same bytecode discipline):**
- The 2% `beforeSwap` capture via BeforeSwapDelta (v2.5 Balanced Delta pattern —
  positive delta + take(), net-zero in PoolManager accounting).
- `afterSwap` fee event emission (indexer-honest, C-5 style: log the router sender).
- Hook-flag address discipline: the artifact address must carry the exact permission
  bits for its implemented callbacks, CREATE3-mined salts, sender-locked to the
  factory. (Flag set depends on §5.2 — see coupling note in §6.)

**Drops (POSSESSIO-specific machinery that stays STEEL's):**
- cbETH staking legs, Aerodrome routing, Chainlink Automation, harvest math.
- Embedded SAV / council logic (the council's constitution lives in STEEL, once).
- X-LINK treasury plumbing, timelocks, forwarder gates.
- Ownable2Step admin surface — the launch template should have the SMALLEST owner
  surface that honors sovereignty: the owner collects fees and (per §5.3) manages
  liquidity. No routing config, no oracle set, no upgrade path.

**Redirects:**
- Fee destination: `TREASURY_SAFE` -> the launch **owner** (factory-written at
  deploy; the ratified `(address owner, bytes initArgs)` template convention, so
  ownership can never be spoofed).

## 4. Wiring constraints discovered by reading V3 (load-bearing)

1. **One salt, one artifact.** The factory pulls ONE pre-mined salt and deploys ONE
   codehash-pinned artifact. V3 is TWO contracts (STEEL + PossessioHook). The
   template must resolve this shape (§5.1) because the factory's pair key depends
   on it: the merged `PossessioLaunchFactory` sets `hooks = launch` AND
   `currency = launch` — which is only correct if the launch is a SINGLE contract
   that is both the ERC20 and its own hook. A two-contract template requires the
   factory to key the pair on `launch.token()` instead (one surgical change,
   pre-deploy — the factory is merged but NOT deployed; nothing is frozen).
2. **Pool registration must be atomic and unspoofable.** STEEL's flow is
   `registerPool` by owner after initialize — a human step. The launchpad's flow is
   atomic: the factory initializes the pool in the deploy transaction. The template
   must learn its own PoolKey at birth. Because CREATE3 deploys through the CreateX
   proxy, the template's constructor CANNOT see the factory as `msg.sender` — so the
   canonical factory address must be **pinned as a constant in the frozen template
   bytecode**. CREATE3 makes this possible: the factory's address is predictable
   before either exists. Order: predict factory address -> freeze template with the
   constant -> hash template -> deploy factory with that codehash. The constellation
   dance, one more verse. `registerPool` (or constructor-computed key) is then
   factory-gated and one-shot.
3. **Salt flags must match the template's flag set.** The salt pool the factory
   draws from must be loaded with salts mined for EXACTLY the template's required
   bits (see §5.2). Mining happens after §5 is ruled, never before.

## 5. OPEN — the rulings the council owes the Architect (explain in his terms)

**5.1 Single contract or two?**
- **Option A — one contract (coin IS its own fee engine):** ERC20 + hook in one
  artifact at one flagged address. Keeps the merged factory correct as-built. One
  codehash, one salt, one address per launch. Lean; fewer moving parts; the
  Macadoodles answer.
- **Option B — two contracts (STEEL's exact shape):** clean token + separate hook,
  hook deploys or references the token. Mirrors proven V3 structure; costs a
  factory change (pair keys on `launch.token()`), a second address per launch, and
  more deploy surface.
- Seat's recommendation: **A**, unless the council finds a v4 constraint that makes
  a token-that-is-a-hook unsafe (e.g. PoolManager interactions with the currency
  contract itself — this is exactly the kind of first-step question Gemini sees
  that we don't).

**5.2 Does a launch inherit the POL gate?**
STEEL's `beforeAddLiquidity` rejects all LPers except the hook itself — the
protocol owns 100% of its own liquidity. For launches:
- **Gate ON (sovereign pools):** the launch owner's contract owns all LP; nobody
  else can add. Strongest anti-rug posture to SELL (the owner cannot be diluted,
  and liquidity walks only if the owner walks) — but it concentrates every pool's
  depth on each owner's wallet discipline.
- **Gate OFF (open pools):** anyone may LP; deeper markets, ordinary DEX behavior;
  rug surface is the standard one.
- Flag consequence: ON = 0x08C8-class salts (with BEFORE_ADD_LIQUIDITY), OFF =
  0x00C8-class. **Salt mining is blocked on this ruling.**

**5.3 Genesis + liquidity seeding (needs Architect numbers, council mechanics):**
Where does the launch's initial liquidity come from? Options: owner supplies council
token alongside the launch supply at deploy (factory escrows and seeds atomically);
or the pool opens dry at the caller's initial price and the owner seeds after.
Related: launch token supply — fixed at template (uniformity, honest comparisons
across launches) or constructor-parameterized like the council token? Seat leans:
fixed supply for launches (every launch comparable at a glance — the §7 prediction
market reads cleaner when every listing has the same denominator of supply), owner
receives 100% minus what seeds the pool.

## 6. DoD sketch (assertable once §5 is ruled)

1. Launch deploys through the factory only; direct construction reverts or is inert
   (factory constant enforced).
2. 2% capture proven on the launch's own pair; fee lands with the OWNER, exact,
   every swap — and NOWHERE else (non-extraction: zero protocol skim post-door).
3. Pair key: currency set contains COUNCIL_TOKEN and the launch's currency; hooks =
   the launch's hook address; assert against §5.1's ruled shape.
4. Atomicity: any failure in deploy+pair (including seeding, per §5.3) unwinds
   everything, fee included.
5. Flag discipline: template's implemented callbacks == address bits == mined salt
   class; a wrong-flag address is rejected by the live PoolManager (already proven
   in `PossessioLaunchFactoryFork.t.sol`).
6. Owner surface: enumerate every owner-callable function; each must map to
   fee-collection or (if §5.2 ON) liquidity management. Anything else fails review.
7. SAV/STEEL untouched: no launch-template code path reads or writes protocol
   treasury state.

## 7. Sequencing (extends SPEC_CouncilToken §9)

1. Council rules §5.1 / §5.2 / §5.3 -> Architect ratifies.
2. Template written (warm seat) -> offline DoD -> cold-seat re-edit -> ratified
   codehash frozen.
3. Factory adjusted IF §5.1 = B (one surgical change; factory is merged, not
   deployed — nothing is burned).
4. Constellation: predict factory -> freeze template constant -> mine salts to the
   ruled flag class -> deploy per `script/DeployLaunchFactory.s.sol` (token first,
   §9 of the token spec; heart with factory in sources; loaded salt pool).
5. Fork run (`BASE_FORK_RPC`) -> Architect terminal broadcast.

---

*Cold-seat review before ratification. The specifying seat does not certify
implementation. If it can't be tested, it doesn't exist; if it's not in the
terminal, it's not proven.*
