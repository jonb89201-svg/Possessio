# Test fixtures

## createx.runtime.hex

The **canonical deployed runtime bytecode** of CreateX, the deterministic
deployment factory, used only as a `vm.etch` fixture so the salt-pool CREATE3
test runs offline (no fork / no RPC). It is never compiled, imported, linked,
or deployed by any POSSESSIO source or artifact.

- Upstream: https://github.com/pcaversaccio/createx (AGPL-3.0-only, applies to
  CreateX, not to POSSESSIO). CreateX is deployed permissionlessly at the same
  canonical address on every chain: `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`.

### Provenance (how these exact bytes were obtained, offline)

1. Extracted the canonical **creation** bytecode from CreateX's own presigned
   deployment transaction (`scripts/presigned-createx-deployment-transactions/`).
2. Executed it to obtain the runtime, then baked the `_SELF` immutable to the
   canonical address (25 slots).
3. Verified the result against CreateX's **published** runtime codehash before
   trusting it.

### Pinned codehash (the notarization)

```
keccak256(runtime) == 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f
```

This is CreateX's own published value (README: "the keccak256 hash ... of the
deployed runtime bytecode is 0xbd8a7ea8..."). The test pins it two ways:

- **Offline** - `setUp` etches this fixture and asserts
  `CREATEX.codehash == <pinned>`; a corrupted or wrong-version hex fails loudly
  instead of green-against-non-CreateX.
- **Fork-gated** - `test_fork_pinnedCodehashMatchesLiveCreateX` confirms the
  pinned constant equals LIVE CreateX on Base when `BASE_RPC_URL` is set.

A CREATE3 address depends only on `(factory address, guarded salt, proxy
init-code hash)`, never on compiler version - but these bytes are the real
mainnet bytes regardless, confirmed by the pinned hash.
