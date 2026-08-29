# BaseScan Verification Runbook — the live constellation (Base 8453)

Goal: publish (verify) the source of the five live mainnet contracts on BaseScan so
each is **sealed** — anyone can read the exact source that produced the on-chain bytecode.

Run this **from the deploy environment** (`/workspaces/Possessio`, where `broadcast/` and the
build cache live). Verification needs three things that only that environment holds together:
the exact source, the exact compiler settings used at deploy, and the constructor arguments.

> **Secrets discipline:** the Etherscan API key is a secret. It stays in your shell env
> (`export ETHERSCAN_API_KEY=...`). It never goes in this repo, a commit, or a chat.

---

## The five addresses

| Contract | Address | Deploy script |
|---|---|---|
| PossessioPool (Heart) | `0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce` | `script/DeployPoolCreate3.s.sol` |
| PossessioX402Core | `0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05` | `script/DeployX402CoreCreate3.s.sol` |
| PossessioFactory | `0x0DD06656cb9a38730a7177792C357E48cEdb49Bd` | `script/DeployFactoryCreate3.s.sol` |
| PossessioSaltPool | `0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6` | `script/DeploySaltPoolCreate3.s.sol` |
| PossessioPayments | `0x67247eB2108E7229331127DF1309D624d95467ca` | `script/DeployPayments.s.sol` |

Verify in **deploy order** (Heart → x402Core → Factory → SaltPool → Payments) so each page's
"read contract" links resolve as you go.

---

## Two things that MUST match the deploy, or verification fails

1. **Exact solc patch version used on 2026-07-28** (the deploy date). The repo currently
   builds on **0.8.35** (README), but if the July-28 deploy used a different patch, submitting
   0.8.35 produces different bytecode and BaseScan rejects it. Read the real version from that
   deploy's build-info:

   ```bash
   # exact compiler + settings recorded at deploy, per contract
   jq '.transactions[].contractName, .transactions[].hash' \
     broadcast/DeployPoolCreate3.s.sol/8453/run-latest.json
   # the solc version + settings are in the sibling cache/build-info json:
   ls -t out/build-info/*.json | head -1 | xargs jq '.solcVersion, .input.settings'
   ```

2. **Optimizer settings** (from `foundry.toml`, uniform): `optimizer = true`,
   `optimizer_runs = 200`, `via_ir = true`. `forge verify-contract` reads these from the
   project automatically — do not override them.

---

## The command (per contract)

`forge verify-contract` submits Standard-JSON + constructor args directly, so it works
regardless of the CREATE3 indirection (BaseScan can't always auto-detect a CREATE3 child's
creation tx, which is why we pass args explicitly rather than relying on the web "guess" flow).

```bash
export ETHERSCAN_API_KEY=<your etherscan.io key>   # unified Etherscan V2 key — one key, all chains incl. Base

forge verify-contract \
  <ADDRESS> \
  src/<Name>.sol:<Name> \
  --chain-id 8453 \
  --constructor-args <ABI_ENCODED_HEX> \
  --watch
```

Etherscan moved to the **V2 unified API**: one key from `etherscan.io` covers Base (chain-id
8453). Legacy standalone BaseScan keys are deprecated — if an old key 400s, mint a V2 key.

### Getting `<ABI_ENCODED_HEX>` (constructor args)

The args are recorded in each deploy's broadcast. For a CREATE3 deploy the child's constructor
args are the trailing bytes of the `initCode` in `additionalContracts`, or the `arguments`
array on the deploying tx:

```bash
jq '.transactions[] | {contractName, arguments, additionalContracts}' \
  broadcast/DeployX402CoreCreate3.s.sol/8453/run-latest.json
```

- If `arguments` is populated → `cast abi-encode` them in constructor order (below).
- If args live only inside `initCode` (common for CREATE3) → take the bytes **after** the
  contract's `type(Name).creationCode`; that tail **is** the already-abi-encoded args, paste
  it directly as `--constructor-args 0x<tail>`.

Constructor signatures (arg order for `cast abi-encode`):

- **PossessioPool** `(address payToken, address[] authorizedSources, address operatorDestination, address treasuryDestination, uint256 operationalCap, uint256 absoluteFloor, uint256 floorPerUnit, uint256 velocityHalflife)`
- **PossessioX402Core** `(bytes32 root, uint256 dustFloor, address payToken, address heartSink, address operatorDestination, address deploymentFeeSource, uint256 operationalCap, uint256 absoluteFloor, …)`
- **PossessioFactory** `(uint256 deploymentFee, bytes32 templateCodehash, address saltPool, address payToken, …)` — `deploymentFee = 50000000` (50 USDC), `payToken = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- **PossessioSaltPool** `(address factory, address keeper, address operatorDestination, address treasuryDestination, address deploymentFeeSource)` — `keeper = 0x319E6728a3c326D7cCc8b406052E8B5dCf04e6B9`
- **PossessioPayments** `(address factoryOwner, bytes initArgs)` — `initArgs = abi.encode(DeployParams)`; the exact blob is in `broadcast/DeployPayments.s.sol/8453/run-latest.json`. `owner = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9`.

> Payments is the fiddly one: its constructor is `(address, bytes)` and the `bytes` is an
> abi-encoded struct. Pull the exact `arguments` hex from its broadcast rather than
> reconstructing the struct by hand.

---

## Confirm it's sealed

After each `--watch` returns `OK`, the page flips to a green "Contract Source Code Verified":

- https://basescan.org/address/0xE0612f38EEd23BEba5228b14bd5E1f269D4D19ce#code
- https://basescan.org/address/0x60d867AfA7c6f4b0822413fA51D0EE9edE786c05#code
- https://basescan.org/address/0x0DD06656cb9a38730a7177792C357E48cEdb49Bd#code
- https://basescan.org/address/0x7181a6Dac7582f4544c5dFC5e1C512258F4A61B6#code
- https://basescan.org/address/0x67247eB2108E7229331127DF1309D624d95467ca#code

Terminal is the judge: the `forge verify-contract` `OK` line + the green page are the proof.
If BaseScan reports "bytecode does not match", the solc patch or a setting differs from the
2026-07-28 deploy — fix the version (step 1), don't force it.

---

*Status as of 2026-08-26: all five NOT VERIFIED (checked on BaseScan). This runbook seals them.*
