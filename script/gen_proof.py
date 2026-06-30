#!/usr/bin/env python3
"""
gen_proof.py - off-chain mirror of src/libraries/HandshakeLib.sol byte discipline.

Builds the MerkleHandshakeAuth tree that SymmetryGuardCore.register() verifies.
The hashing MUST match HandshakeLib byte-for-byte or every real proof fails on
chain (that intolerance is the feature - see HandshakeLib SPEC S1 note):

    inner     = sha256( abi.encode(secret, caller) )   # 64-byte preimage
    leaf      = sha256( abi.encode(inner) )            # 32-byte preimage (double hash)
    node(a,b) = sha256( sorted(a, b) )                 # 64-byte preimage, lo||hi

ABI layout that pins the bytes:
    abi.encode(bytes32, address) -> 32-byte secret || address left-padded to 32 = 64 bytes
    abi.encode(bytes32)          -> the 32 bytes verbatim
    node uses abi.encodePacked(lo, hi) -> raw 64-byte concat, operands sorted ascending

Tree shape: adjacent-pair, sorted-node Merkle (OpenZeppelin-style). An unpaired
tail node at a level is promoted (carried up) unchanged. Because node() sorts its
operands, proof folding is order-independent, so proofs carry only sibling values.

Output: a single 0x-prefixed hex blob of concatenated 32-byte words, which
Foundry's vm.ffi decodes to exact bytes (the test reads words by mload):
    leaf  <secretHex> <addrHex>                  -> [leaf]
    root  <n> <s0> <a0> ... <s_{n-1}> <a_{n-1}>  -> [root]
    proof <i> <n> <s0> <a0> ...                  -> [root, sib0, sib1, ...]

This is the on-chain counterpart certified by test_ffi_leaf_matches_onchain.
"""

import sys
import hashlib


def sha256(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def _strip0x(h: str) -> str:
    return h[2:] if h[:2] in ("0x", "0X") else h


def parse_bytes32(h: str) -> bytes:
    b = bytes.fromhex(_strip0x(h))
    if len(b) != 32:
        raise ValueError(f"bytes32 must be 32 bytes, got {len(b)} from {h!r}")
    return b


def encode_address(h: str) -> bytes:
    # abi.encode(address) left-pads the 20-byte address to a 32-byte word.
    b = bytes.fromhex(_strip0x(h))
    if len(b) != 20:
        raise ValueError(f"address must be 20 bytes, got {len(b)} from {h!r}")
    return b"\x00" * 12 + b


def hash_leaf(secret_hex: str, addr_hex: str) -> bytes:
    inner = sha256(parse_bytes32(secret_hex) + encode_address(addr_hex))  # 64-byte preimage
    return sha256(inner)                                                  # 32-byte preimage


def hash_node(a: bytes, b: bytes) -> bytes:
    lo, hi = (a, b) if a <= b else (b, a)   # bytes compare == bytes32 unsigned compare
    return sha256(lo + hi)


def build_levels(leaves):
    """Return list of levels, level 0 = leaves, last level = [root]."""
    levels = [list(leaves)]
    cur = list(leaves)
    while len(cur) > 1:
        nxt = []
        i = 0
        while i < len(cur):
            if i + 1 < len(cur):
                nxt.append(hash_node(cur[i], cur[i + 1]))
                i += 2
            else:
                nxt.append(cur[i])   # unpaired tail promoted unchanged
                i += 1
        levels.append(nxt)
        cur = nxt
    return levels


def make_proof(leaves, index):
    levels = build_levels(leaves)
    proof = []
    idx = index
    for lvl in range(len(levels) - 1):
        cur = levels[lvl]
        sib = idx ^ 1
        if sib < len(cur):           # promoted tail has no sibling at this level
            proof.append(cur[sib])
        idx //= 2
    return levels[-1][0], proof


def leaves_from_args(n, args):
    if len(args) < 2 * n:
        raise ValueError(f"need {2 * n} (secret,addr) tokens, got {len(args)}")
    return [hash_leaf(args[2 * k], args[2 * k + 1]) for k in range(n)]


def emit(words):
    sys.stdout.write("0x" + b"".join(words).hex())


def main(argv):
    if not argv:
        raise SystemExit("usage: gen_proof.py {leaf|root|proof} ...")
    cmd = argv[0]
    if cmd == "leaf":
        emit([hash_leaf(argv[1], argv[2])])
    elif cmd == "root":
        n = int(argv[1])
        leaves = leaves_from_args(n, argv[2:])
        emit([build_levels(leaves)[-1][0]])
    elif cmd == "proof":
        i = int(argv[1])
        n = int(argv[2])
        leaves = leaves_from_args(n, argv[3:])
        root, proof = make_proof(leaves, i)
        emit([root] + proof)
    else:
        raise SystemExit(f"unknown command: {cmd!r}")


if __name__ == "__main__":
    main(sys.argv[1:])
