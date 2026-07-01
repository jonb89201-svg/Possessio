# Test fixtures

## createx.runtime.hex

Compiled **runtime bytecode** of CreateX, the canonical deterministic-deployment
factory, used **only** as a `vm.etch` fixture so the salt-pool CREATE3 test can
run offline (no fork / no RPC). It is not compiled, imported, linked, or
deployed by any POSSESSIO source or artifact.

- Upstream source: https://github.com/pcaversaccio/createx (`src/CreateX.sol`, main)
- Upstream license: AGPL-3.0-only (applies to CreateX, not to POSSESSIO)
- CreateX is deployed permissionlessly at the same canonical address on every
  chain (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`); this is that same public
  on-chain bytecode, so etching it is equivalent to what a mainnet fork loads.

Note on provenance: the `_SELF` immutable (CreateX's own address) is baked into
the bytecode as the canonical address, matching a real deployment. A CREATE3
address derives only from `(factory address, guarded salt, proxy init-code hash)`
- never from CreateX's own bytecode or compiler - so the addresses this fixture
produces match mainnet CreateX exactly. The test cross-checks that three
independent ways.
