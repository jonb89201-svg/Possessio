"""
Pure-Python Keccak-256 (the Ethereum variant, NOT NIST SHA3-256 - different
padding domain byte: 0x01 for Keccak, 0x06 for SHA3). No dependencies, since
this sandbox has no network access to pip install eth_abi/eth_utils/pycryptodome.

Implements the Keccak-f[1600] permutation + sponge construction directly from
spec (rate=1088 bits / 136 bytes, capacity=512 bits, output=256 bits).
"""

MASK64 = (1 << 64) - 1

RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

# rotation offsets, indexed R[x][y]
R = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]


def _rol(x, s):
    s %= 64
    if s == 0:
        return x & MASK64
    return ((x << s) | (x >> (64 - s))) & MASK64


def _keccak_f1600(state):
    # state: list of 25 64-bit lanes, indexed state[x + 5*y]
    for rnd in range(24):
        # theta
        C = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        D = [C[(x - 1) % 5] ^ _rol(C[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] ^= D[x]
        # rho + pi
        B = [0] * 25
        for x in range(5):
            for y in range(5):
                B[y + 5 * ((2 * x + 3 * y) % 5)] = _rol(state[x + 5 * y], R[x][y])
        # chi
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y] & MASK64)
        # iota
        state[0] ^= RC[rnd]
    return state


def keccak256(data: bytes) -> bytes:
    rate_bytes = 136  # 1088 bits
    state = [0] * 25

    padded = bytearray(data)
    padded.append(0x01)  # Keccak domain byte (0x01, NOT SHA3's 0x06)
    while len(padded) % rate_bytes != 0:
        padded.append(0x00)
    padded[-1] |= 0x80  # multi-rate padding close bit

    for i in range(0, len(padded), rate_bytes):
        block = padded[i:i + rate_bytes]
        for j in range(0, rate_bytes, 8):
            lane = int.from_bytes(block[j:j + 8], "little")
            state[j // 8] ^= lane
        state = _keccak_f1600(state)

    out = b"".join(state[i].to_bytes(8, "little") for i in range(4))
    return out


if __name__ == "__main__":
    # Known-answer test: keccak256("") is the canonical Ethereum vector
    # (this exact value is what Solidity's keccak256("") returns, and is
    # also the widely-cited "empty node hash" used elsewhere in Ethereum).
    result = keccak256(b"").hex()
    expected = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    assert result == expected, f"KAT FAILED: got {result}, expected {expected}"
    print("keccak256('') KAT: PASS -", result)

    print("keccak256('abc'):", keccak256(b"abc").hex())
    print("keccak256('testing'):", keccak256(b"testing").hex())
