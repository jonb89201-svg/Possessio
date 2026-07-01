#!/usr/bin/env python3
"""
ffi bridge for the decay oracle. Usage:
    decay_cli.py <velocity_scaled> <last_ts> <now_ts> <halflife>
Prints the decayed velocity as a 0x-prefixed 32-byte big-endian word so
forge's vm.ffi can abi.decode it straight to uint256. This calls the SAME
decayed_velocity() the worked-examples use - no reimplementation.
"""
import sys
from oracle import decayed_velocity

if __name__ == "__main__":
    v, last_ts, now_ts, halflife = (int(x) for x in sys.argv[1:5])
    out = decayed_velocity(v, last_ts, now_ts, halflife)
    print("0x" + out.to_bytes(32, "big").hex())
