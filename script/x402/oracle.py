"""
PossessioX402Core v0.6 — Python oracle
Nonce-commitment (settleCall step 4) + velocity decay math (_decayedVelocity,
_bumpVelocity, getRunningMinimumFloor).

Every function here is an integer-exact mirror of the Solidity. No floats.
Run standalone to see worked examples; import into a fuzz/property harness
to cross-check against forge output.

Dependency note: no network access in this sandbox, so eth_abi/eth_utils/
pycryptodome weren't installable. keccak256.py is a from-spec pure-Python
Keccak-256 (Ethereum variant), verified against the standard keccak256("")
known-answer vector before being trusted here. When this moves to your repo
with network access, swap `from keccak256 import keccak256` for
`from eth_utils import keccak as keccak256` — same output, faster.
"""

from keccak256 import keccak256

UINT256_MAX = (1 << 256) - 1


# ---------------------------------------------------------------------------
# Minimal ABI encoder for the ONE call site that needs it:
#   keccak256(abi.encode(address, bytes32, uint256, bytes32))
# All four Solidity types here are "static" (fixed 32-byte-word) types, so
# abi.encode is just concatenation of four 32-byte words — no offset/length
# header machinery needed (that's only for dynamic types: bytes, string,
# arrays). This is why a full eth_abi dependency isn't actually required
# for this specific commitment.
# ---------------------------------------------------------------------------

def _word_address(addr: str) -> bytes:
    """address -> 32-byte word, left-padded with zeros (right-aligned)."""
    a = addr.lower().removeprefix("0x")
    if len(a) != 40:
        raise ValueError(f"address must be 20 bytes / 40 hex chars, got {addr!r}")
    return bytes(12) + bytes.fromhex(a)


def _word_bytes32(b: bytes | str) -> bytes:
    """bytes32 -> exactly 32 bytes, as-is (no padding for a full bytes32)."""
    if isinstance(b, str):
        b = bytes.fromhex(b.removeprefix("0x"))
    if len(b) != 32:
        raise ValueError(f"expected exactly 32 bytes, got {len(b)}")
    return b


def _word_uint256(n: int) -> bytes:
    """uint256 -> 32-byte big-endian word."""
    if not (0 <= n <= UINT256_MAX):
        raise ValueError(f"uint256 out of range: {n}")
    return n.to_bytes(32, "big")


def nonce_commitment(seller: str, channel_id, value: int, salt) -> bytes:
    """
    Mirrors settleCall step 4 exactly:
        bytes32 expectedCommitment = keccak256(abi.encode(seller, channelId, value, salt));

    seller: "0x..." address string
    channel_id: bytes (32) or hex string
    value: int (uint256)
    salt: bytes (32) or hex string
    Returns: 32-byte commitment (compare against the signed `nonce`).
    """
    preimage = (
        _word_address(seller)
        + _word_bytes32(channel_id)
        + _word_uint256(value)
        + _word_bytes32(salt)
    )
    return keccak256(preimage)


# ---------------------------------------------------------------------------
# Velocity decay math — exact integer mirror of _decayedVelocity /
# _bumpVelocity / getRunningMinimumFloor. Every operation below uses the
# SAME integer division / right-shift semantics Solidity uses; there is no
# floating point anywhere in this section on purpose.
# ---------------------------------------------------------------------------

def decayed_velocity(velocity_scaled: int, last_ts: int, now_ts: int, halflife: int) -> int:
    """
    Mirrors _decayedVelocity():
        uint256 v = velocityScaled;
        if (v == 0) return 0;
        uint256 dt = block.timestamp - lastVelocityTs;
        if (dt == 0 || VELOCITY_HALFLIFE == 0) return v;
        uint256 halvings = dt / VELOCITY_HALFLIFE;
        if (halvings >= 128) return 0;
        v >>= halvings;
        uint256 rem = dt % VELOCITY_HALFLIFE;
        if (rem > 0 && v > 0) v -= (v * rem) / (2 * VELOCITY_HALFLIFE);
        return v;
    """
    v = velocity_scaled
    if v == 0:
        return 0

    dt = now_ts - last_ts
    if dt < 0:
        # Solidity: uint256 subtraction underflow -> revert. now_ts must be
        # >= last_ts for this call to be meaningful; surface it loudly.
        raise ValueError("now_ts < last_ts — Solidity would revert on this subtraction")

    if dt == 0 or halflife == 0:
        return v

    halvings = dt // halflife
    if halvings >= 128:
        return 0

    v >>= halvings  # exact bit-shift, matches Solidity >>=

    rem = dt % halflife
    if rem > 0 and v > 0:
        v -= (v * rem) // (2 * halflife)  # integer division, matches Solidity /

    return v


def bump_velocity(velocity_scaled: int, last_ts: int, now_ts: int, halflife: int) -> int:
    """
    Mirrors _bumpVelocity():
        velocityScaled = _decayedVelocity();
        lastVelocityTs = block.timestamp;
        velocityScaled += 1e18;
    Returns the new velocityScaled. Solidity 0.8.x reverts on overflow
    (checked arithmetic) rather than wrapping, so this raises instead of
    silently masking — matching the real revert behavior for fuzzing.
    """
    v = decayed_velocity(velocity_scaled, last_ts, now_ts, halflife)
    v_new = v + 10**18
    if v_new > UINT256_MAX:
        raise OverflowError("velocityScaled + 1e18 overflows uint256 — Solidity would revert")
    return v_new


def running_minimum_floor(velocity_scaled: int, last_ts: int, now_ts: int,
                           halflife: int, absolute_floor: int, floor_per_unit: int) -> int:
    """
    Mirrors getRunningMinimumFloor():
        uint256 vUnits = _decayedVelocity() / 1e18;
        return ABSOLUTE_FLOOR + (vUnits * FLOOR_PER_UNIT);
    """
    v_units = decayed_velocity(velocity_scaled, last_ts, now_ts, halflife) // 10**18
    return absolute_floor + (v_units * floor_per_unit)


def expected_value(base_price: int, toll_bps: int) -> int:
    """
    Mirrors settleCall step 3:
        uint256 expectedValue = basePrice + (basePrice * tollBps) / 10_000;
    Included since it's the other half of every settleCall oracle check,
    even though this turn's ask was specifically nonce + decay.
    """
    return base_price + (base_price * toll_bps) // 10_000


if __name__ == "__main__":
    print("=== nonce_commitment worked example ===")
    seller = "0x" + (1).to_bytes(20, "big").hex()
    channel_id = (2).to_bytes(32, "big")
    value = 1_050_000  # e.g. 1.05 USDC at 6 decimals
    salt = (777).to_bytes(32, "big")
    commitment = nonce_commitment(seller, channel_id, value, salt)
    print("seller     :", seller)
    print("channelId  :", channel_id.hex())
    print("value      :", value)
    print("salt       :", salt.hex())
    print("commitment :", "0x" + commitment.hex())
    print("(this is what the buyer sets `nonce` to when signing the EIP-3009")
    print(" authorization; settleCall recomputes it and requires an exact match)")

    print()
    print("=== decayed_velocity worked examples (halflife = 3600s / 1hr) ===")
    HALFLIFE = 3600
    ONE = 10**18

    # exactly one full halflife elapsed -> should be exactly half
    v1 = decayed_velocity(ONE, 0, HALFLIFE, HALFLIFE)
    print(f"1 halflife elapsed: {v1} (expect exactly {ONE // 2})")
    assert v1 == ONE // 2, "exact-halving case should have zero remainder correction"

    # zero time elapsed -> unchanged
    v2 = decayed_velocity(ONE, 1000, 1000, HALFLIFE)
    assert v2 == ONE
    print(f"0 elapsed: {v2} (expect {ONE}, unchanged)")

    # way past 128 halvings -> fully decayed to 0
    v3 = decayed_velocity(ONE, 0, HALFLIFE * 200, HALFLIFE)
    assert v3 == 0
    print(f"200 halflives elapsed: {v3} (expect 0, capped at 128)")

    # partial window: half a halflife elapsed
    v4 = decayed_velocity(ONE, 0, HALFLIFE // 2, HALFLIFE)
    print(f"half a halflife elapsed: {v4}")
    # sanity: true exponential would give ONE * 2**-0.5 ≈ 0.7071 * ONE.
    # our linear-interpolation approximation should sit ABOVE that (conservative).
    true_exp_approx = int(ONE * 0.70710678)
    print(f"  true exponential ≈ {true_exp_approx} — approximation should be >= this")
    assert v4 >= true_exp_approx, "approximation should overestimate (safe direction)"
    print("  confirmed: approximation is conservative (>= true exponential decay)")

    print()
    print("=== running_minimum_floor worked example ===")
    floor = running_minimum_floor(
        velocity_scaled=ONE * 5,  # 5 "units" of decayed velocity, no decay yet
        last_ts=0, now_ts=0, halflife=HALFLIFE,
        absolute_floor=100_000_000,  # 100 USDC (6 decimals)
        floor_per_unit=1_000_000,    # +1 USDC per unit of velocity
    )
    print(f"floor = {floor} (expect 100_000_000 + 5*1_000_000 = 105_000_000)")
    assert floor == 105_000_000

    print()
    print("All worked examples passed. Wire these into forge via ffi or a")
    print("matching Foundry test harness for the actual fuzz cross-check.")
