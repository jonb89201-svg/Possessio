// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HandshakeLib} from "./libraries/HandshakeLib.sol";

/// @title SymmetryGuardCore (v3 - typed additive triggers)
/// @notice The V4-independent core of the Symmetry Guard + Handshake primitive.
///         Deliberately contains NO Uniswap V4 imports so the hardest gauntlet
///         tests run without compiling V4. The V4 hook (separate file) is a thin
///         plumbing layer over this.
///
/// ============================= v3 CHANGE (typed triggers) =====================
/// v2 had a SINGLE flag and a SINGLE punitive fee scaling to ONE shared cap, which
/// POOLED different behaviors into one path (and once capped, more bad behavior was
/// free). v3 replaces that with a TYPED, ADDITIVE trigger system:
///   - a fixed BASE_FEE_BPS applies to every swap (the toll floor),
///   - each behavior is its own trigger with its own signature/flag/penalty,
///   - the fee is base + the SUM of each triggered penalty (itemized, not pooled),
///   - the TOTAL is clamped at one ceiling (MAX_TOTAL_FEE_BPS) so no trader freezes.
/// Principle: different behavior -> different punishment; total bounded; self-curing.
/// Adding a future trigger = add an enum member + its measurement + flag + penalty,
/// WITHOUT touching existing triggers (open to extension, closed to modification).
///
/// ===================== CARRIED FROM v2 (three bugcatches, intact) =============
/// FIX 1 baseline-fraction flagging (not raw count) for RoundTripExtraction.
/// FIX 2 per-deployment DUST_FLOOR (decimals-correct; no magic unit).
/// FIX 3 read-time decay so punishment self-cures on slow-down OR full cessation.
///
/// ============================ DELIBERATE DECISIONS ============================
/// A  learning ON-CHAIN (weakness = probeable -> false-negatives = acceptable).
/// B  two stores: immutable ROOT = authorization; mutable signal written ONLY by
///    deterministic guard logic from on-chain facts. No human/owner path => no
///    capture surface => no injectable false-positive.
/// C  single-use proof at register(); swaps READ registration, never re-prove.
/// D  punishment bounded + self-curing (read-time decay) + total-clamped; never
///    permanent damnation on a guess.
/// =============================================================================
abstract contract SymmetryGuardCore {
    // ----------------------------------------------------------------- metadata
    string internal constant PRIMITIVE_NAME = "SymmetryGuardHandshake";
    string internal constant REQUIRES = "uniswap-v4-hooks;flash-accounting;sha256-precompile";
    string internal constant PROVIDES = "identity-handshake-auth;symmetry-mev-guard;typed-additive-toll";
    string internal constant CONFLICTS = "v3-fork-amm;v3-callbacks;aerodrome-slipstream";

    // -------------------------------------------------------------- immutables
    /// @notice AUTHORIZATION root (good standing). Immutable by construction.
    bytes32 public immutable HANDSHAKE_ROOT;
    /// @notice Dust floor in the POOL's token units (FIX 2). Set once at deploy to
    ///         match token decimals; legs below this are ignored as dust. Immutable.
    uint256 public immutable DUST_FLOOR;

    // ----------------------------------------------- HARDCODED, IMMUTABLE policy
    // The product sells the SOVEREIGNTY of a fixed, proven policy - not tunability.
    // Nobody (incl. the platform) can alter these post-deploy.
    uint256 internal constant BASE_FEE_BPS      = 200;  // 2% toll floor on every swap
    uint256 internal constant MAX_TOTAL_FEE_BPS = 500;  // 5% ceiling on base + all penalties
    uint256 internal constant HEADROOM          = MAX_TOTAL_FEE_BPS - BASE_FEE_BPS; // 300

    // -- RoundTripExtraction trigger (carried from v2, semantics unchanged) --
    uint256 internal constant WINDOW_BLOCKS      = 3;    // round-trip must pair within N blocks
    uint256 internal constant DECAY_BLOCKS       = 50;   // idle blocks per decay step (round-trip)
    uint32  internal constant DECAY_AMT          = 2;    // score bled per decay step
    uint256 internal constant MIRROR_TOL_BPS     = 500;  // legs within 5% size => "mirrored"
    uint32  internal constant MIN_OBSERVATIONS   = 6;    // no round-trip flag until enough sample
    uint256 internal constant FLAG_NUM           = 3;    // flag when shapeHits/observations >= 3/4
    uint256 internal constant FLAG_DEN           = 4;    // i.e. >= 75% of activity is the shape
    uint256 internal constant PUNITIVE_SLOPE_BPS = 25;   // round-trip bps per hit over the gate

    // -- DustSpam trigger (NEW in v3) --
    // PROVISIONAL CONSTANTS - conservative starting values, NOT proven. MUST be
    // validated against real swap streams (false-positive check on honest
    // high-frequency small traders) before the mainnet freeze. Hardcoded-and-
    // immutable means there is no second chance to tune.
    uint256 internal constant DUST_SPAM_BAND_MULT     = 5;   // "small" = [DUST_FLOOR, 5*DUST_FLOOR)
    uint256 internal constant DUST_SPAM_WINDOW_BLOCKS = 20;  // rolling frequency window / decay step
    uint32  internal constant DUST_SPAM_MIN_HITS      = 10;  // >= 10 small legs in-window => dust-spam
    uint256 internal constant DUST_SPAM_SLOPE_BPS     = 25;  // dust bps per hit over the threshold

    /// @notice Behavior taxonomy. Each penalty term maps to one member. Adding a
    ///         trigger = add a member + its measurement + flag + penalty, leaving
    ///         existing triggers untouched (extensible, additive, never pooled).
    enum Trigger { None, RoundTripExtraction, DustSpam }

    // ---------------------------------------------------------------------- state
    /// @notice Single-use nullifier (DECISION C). leaf => consumed-forever.
    mapping(bytes32 => bool) public consumed;
    /// @notice Persistent good-standing (DECISION C). Minted once per identity.
    mapping(address => bool) public registered;

    struct GuardSlot {
        uint64  lastBlock;       // block of this sender's last observed leg in this pool
        bool    lastZeroForOne;
        uint128 lastAbsIn;       // absolute input of last leg. CAP at uint128 max below is a
                                 // DELIBERATE accepted edge: sizes beyond 3.4e38 saturate the
                                 // mirror reference. Not an oversight; no realistic leg hits it.
        uint32  shapeHits;       // RoundTripExtraction signal (decays at read - FIX 3)
        uint32  observations;    // total non-dust legs (the baseline denominator)
        uint64  shapeBlock;      // block of last shapeHit (round-trip read-time decay)
        uint32  dustHits;        // DustSpam signal (decays at read)
        uint64  dustBlock;       // block of last dust hit (dust read-time decay)
    }
    /// @notice MUTABLE culprit signal (DECISION B). Written ONLY by _observe.
    mapping(bytes32 => GuardSlot) internal _guard; // key = keccak(sender, poolId)

    // --------------------------------------------------------------------- events
    event Registered(address indexed caller, bytes32 indexed leaf);
    event AsymmetryObserved(address indexed sender, bytes32 indexed poolId, uint32 shapeHits, uint32 observations);
    event DustSpamObserved(address indexed sender, bytes32 indexed poolId, uint32 dustHits);
    /// @notice Itemized audit record. Keeps "different behavior, different
    ///         punishment" legible EVEN WHEN the total clamps at MAX_TOTAL_FEE_BPS:
    ///         the pre-clamp per-trigger terms are recorded alongside the clamped total.
    event Tolled(address indexed sender, bytes32 indexed poolId,
                 uint256 baseBps, uint256 roundTripBps, uint256 dustBps, uint256 totalBpsAfterClamp);

    // --------------------------------------------------------------------- errors
    error AlreadyUsed();
    error NotAuthorized();
    error BadAuthData();

    constructor(bytes32 root, uint256 dustFloor) {
        HANDSHAKE_ROOT = root;
        DUST_FLOOR = dustFloor;
    }

    // =========================================================================
    //  HANDSHAKE - register once, single-use (DECISION C; spine S9)
    // =========================================================================
    function register(bytes32 secret, bytes32[] calldata proof) external {
        if (proof.length == 0 || proof.length > 64) revert BadAuthData();
        // INVARIANT (v3 S6.1): the leaf is reconstructed from msg.sender to BIND the
        // call to the caller. Do NOT refactor to accept a precomputed leaf from
        // calldata - that reopens the copy-and-race handshake front-run.
        bytes32 leaf = HandshakeLib.hashLeaf(secret, msg.sender);

        if (consumed[leaf]) revert AlreadyUsed();
        if (!HandshakeLib.verify(HANDSHAKE_ROOT, leaf, proof)) revert NotAuthorized();

        consumed[leaf] = true;
        registered[msg.sender] = true;
        emit Registered(msg.sender, leaf);
    }

    // =========================================================================
    //  OBSERVATION - on-chain learning (A) feeding mutable signals (B)
    // =========================================================================
    function _slotKey(address sender, bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, poolId));
    }

    function _mirrors(uint256 a, uint256 b) internal view returns (bool) {
        if (a < DUST_FLOOR || b < DUST_FLOOR) return false;
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        return hi * 10_000 <= lo * (10_000 + MIRROR_TOL_BPS);
    }

    /// @notice Read-time decayed round-trip hits (FIX 3). Self-cures on slow OR stop.
    function _decayedShapeHits(GuardSlot storage s) internal view returns (uint32) {
        uint32 hits = s.shapeHits;
        if (hits == 0 || s.shapeBlock == 0) return hits;
        uint256 elapsed = block.number - s.shapeBlock;
        if (elapsed <= DECAY_BLOCKS) return hits;
        uint256 bleed = (elapsed / DECAY_BLOCKS) * DECAY_AMT;
        return bleed >= hits ? 0 : uint32(hits - bleed);
    }

    /// @notice Read-time decayed dust hits. Decays over DUST_SPAM_WINDOW_BLOCKS steps
    ///         so the rolling window does double duty: within a window hits persist,
    ///         beyond it they bleed - self-curing on cessation, same as round-trip.
    function _decayedDustHits(GuardSlot storage s) internal view returns (uint32) {
        uint32 hits = s.dustHits;
        if (hits == 0 || s.dustBlock == 0) return hits;
        uint256 elapsed = block.number - s.dustBlock;
        if (elapsed <= DUST_SPAM_WINDOW_BLOCKS) return hits;
        uint256 bleed = (elapsed / DUST_SPAM_WINDOW_BLOCKS) * DECAY_AMT;
        return bleed >= hits ? 0 : uint32(hits - bleed);
    }

    function _satInc(uint32 x) private pure returns (uint32) {
        // saturate-cap instead of wrapping (S7): observations is a security
        // DENOMINATOR; a wrap would invert the saturation fraction.
        return x == type(uint32).max ? x : x + 1;
    }

    /// @notice Observe one swap leg. Feeds BOTH triggers from the five primitives
    ///         {sender, poolId, direction, size, block}. Legs BELOW DUST_FLOOR are
    ///         excluded entirely (neither trigger). The band [DUST_FLOOR,
    ///         DUST_SPAM_BAND_MULT*DUST_FLOOR) additionally feeds DustSpam.
    function _observe(address sender, bytes32 poolId, bool zeroForOne, uint256 absIn) internal {
        bytes32 k = _slotKey(sender, poolId);
        GuardSlot storage s = _guard[k];

        // legs below the floor are excluded from EVERYTHING (S6.6).
        if (absIn < DUST_FLOOR) {
            emit AsymmetryObserved(sender, poolId, s.shapeHits, s.observations);
            return;
        }

        // ---- RoundTripExtraction signal ----
        uint32 decayed = _decayedShapeHits(s);
        if (decayed != s.shapeHits) { s.shapeHits = decayed; s.shapeBlock = uint64(block.number); }

        if (s.lastBlock != 0) {
            uint256 gap = block.number - s.lastBlock;
            if (gap <= WINDOW_BLOCKS && zeroForOne != s.lastZeroForOne && _mirrors(absIn, s.lastAbsIn)) {
                s.shapeHits = _satInc(s.shapeHits);
                s.shapeBlock = uint64(block.number);
            }
        }
        s.lastBlock = uint64(block.number);
        s.lastZeroForOne = zeroForOne;
        s.lastAbsIn = absIn > type(uint128).max ? type(uint128).max : uint128(absIn);
        s.observations = _satInc(s.observations);
        emit AsymmetryObserved(sender, poolId, s.shapeHits, s.observations);

        // ---- DustSpam signal (band just above the floor) ----
        if (absIn < DUST_FLOOR * DUST_SPAM_BAND_MULT) {
            uint32 dDecayed = _decayedDustHits(s);
            if (dDecayed != s.dustHits) { s.dustHits = dDecayed; }
            s.dustHits = _satInc(s.dustHits);
            s.dustBlock = uint64(block.number);
            emit DustSpamObserved(sender, poolId, s.dustHits);
        }

        // ---- itemized toll record (S5) ----
        (uint256 b, uint256 rt, uint256 d, uint256 total) = _assess(s);
        emit Tolled(sender, poolId, b, rt, d, total);
    }

    // =========================================================================
    //  TYPED ADDITIVE PENALTIES - each 0 unless ITS trigger is flagged
    // =========================================================================
    function _isFlaggedRoundTrip(GuardSlot storage s) internal view returns (bool) {
        uint32 obs = s.observations;
        if (obs < MIN_OBSERVATIONS) return false;
        uint32 hits = _decayedShapeHits(s);
        return uint256(hits) * FLAG_DEN >= uint256(obs) * FLAG_NUM; // >= 75%
    }

    function _isFlaggedDustSpam(GuardSlot storage s) internal view returns (bool) {
        return _decayedDustHits(s) >= DUST_SPAM_MIN_HITS;
    }

    /// @dev RoundTrip penalty: scales with decayed hits OVER the 75% gate. Individually
    ///      bounded by HEADROOM so no single term alone exceeds the total headroom.
    function _penaltyRoundTrip(GuardSlot storage s) internal view returns (uint256) {
        if (!_isFlaggedRoundTrip(s)) return 0;
        uint32 hits = _decayedShapeHits(s);
        uint256 gate = (uint256(s.observations) * FLAG_NUM + FLAG_DEN - 1) / FLAG_DEN; // ceil
        uint256 over = hits > gate ? hits - gate : 0;
        uint256 raw = (over + 1) * PUNITIVE_SLOPE_BPS;
        return raw > HEADROOM ? HEADROOM : raw;
    }

    /// @dev DustSpam penalty: scales with decayed dust hits OVER the threshold.
    function _penaltyDustSpam(GuardSlot storage s) internal view returns (uint256) {
        uint32 hits = _decayedDustHits(s);
        if (hits < DUST_SPAM_MIN_HITS) return 0;
        uint256 over = uint256(hits) - DUST_SPAM_MIN_HITS;
        uint256 raw = (over + 1) * DUST_SPAM_SLOPE_BPS;
        return raw > HEADROOM ? HEADROOM : raw;
    }

    /// @notice Itemized assessment: base + each penalty, total clamped. Pure read.
    function _assess(GuardSlot storage s)
        internal view returns (uint256 base, uint256 roundTrip, uint256 dust, uint256 total)
    {
        base = BASE_FEE_BPS;
        roundTrip = _penaltyRoundTrip(s);
        dust = _penaltyDustSpam(s);
        uint256 sum = base + roundTrip + dust;
        total = sum > MAX_TOTAL_FEE_BPS ? MAX_TOTAL_FEE_BPS : sum;
    }

    /// @notice Total fee in bps the host charges this (sender,pool). Honest path =
    ///         exactly BASE_FEE_BPS (S6.3). Each penalty is 0 unless its trigger fires.
    function totalFeeBps(address sender, bytes32 poolId) public view returns (uint256 total) {
        (, , , total) = _assess(_guard[_slotKey(sender, poolId)]);
    }

    // ----------------------------------------------------------- view helpers (tests/host)
    function feeBreakdown(address sender, bytes32 poolId)
        external view returns (uint256 base, uint256 roundTrip, uint256 dust, uint256 total)
    {
        return _assess(_guard[_slotKey(sender, poolId)]);
    }
    function guardShapeHits(address sender, bytes32 poolId) external view returns (uint32) {
        return _decayedShapeHits(_guard[_slotKey(sender, poolId)]);
    }
    function guardObservations(address sender, bytes32 poolId) external view returns (uint32) {
        return _guard[_slotKey(sender, poolId)].observations;
    }
    function guardDustHits(address sender, bytes32 poolId) external view returns (uint32) {
        return _decayedDustHits(_guard[_slotKey(sender, poolId)]);
    }
    function isFlaggedRoundTrip(address sender, bytes32 poolId) external view returns (bool) {
        return _isFlaggedRoundTrip(_guard[_slotKey(sender, poolId)]);
    }
    function isFlaggedDustSpam(address sender, bytes32 poolId) external view returns (bool) {
        return _isFlaggedDustSpam(_guard[_slotKey(sender, poolId)]);
    }
    function metadata() external pure returns (string memory r, string memory p, string memory c) {
        return (REQUIRES, PROVIDES, CONFLICTS);
    }
}
