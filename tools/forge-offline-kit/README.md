# forge offline kit

Foundry's `forge` that runs with **no internet**: build, test and fuzz Solidity inside a sandbox that cannot download
anything. Made for hand-delivery to sandboxed agents (ChatGPT's code sandbox has no network).

**The kit is a GitHub Release asset, not a file in this repository** (Architect, 2026-10-18: a 36 MB binary stays out
of git history).

- Release: `forge-offline-kit-v1.5.1` → https://github.com/jonb89201-svg/Possessio/releases/tag/forge-offline-kit-v1.5.1
- Asset: `forge-offline-kit-v1.5.1.zip`, 36,181,759 bytes
- **sha256:** `41ce25ae660ed31e52b6c2902b3914ec62693f4bf96cf5ef4672726afde86426` (a `.sha256` sidecar sits beside it)

| Inside the zip | |
|---|---|
| `bin/forge` | Foundry forge 1.5.1, Linux x86_64; sha256 `a39fc1913b53dde6a35b603756f65d799e13817ef694107ec0d3704c20435cce`, the digest checked against Foundry's signed v1.5.1 release attestation |
| `bin/solc-0.8.35` | Solidity 0.8.35, fully static; sha256 `fa8ac9a32d301ad023a36ee5a29f8e291fe3200c60244e43c142539e82a617f4`, verified against the official `list.json` |
| `lib/forge-std/` | forge-std 1.9.7 at commit `77041d2` |
| `example/` | a 3-test project (incl. a 256-run fuzz test) that proves the kit works |
| `setup.sh` | verifies every file against `SHA256SUMS`, sets permissions, checks the host, runs the example |
| `PROVENANCE.md`, `LICENSES/` | sources and hashes; Foundry MIT/Apache-2.0, solc GPL-3.0, forge-std MIT/Apache-2.0 |

**Host requirements:** Linux x86_64, glibc 2.34 or newer. Nothing else.

## Use

```bash
sha256sum -c forge-offline-kit-v1.5.1.zip.sha256          # optional, before unzipping
unzip -q forge-offline-kit-v1.5.1.zip && cd forge-offline-kit-v1.5.1 && bash setup.sh
# expected last line:  Suite result: ok. 3 passed; 0 failed; 0 skipped
```

For your own project: `forge test --offline --use "$KIT/bin/solc-0.8.35"` with `$KIT/bin` on `PATH`. Both flags
matter: without them forge tries to download a compiler. The project's `lib/` must already be populated.

## Verified

- MEASURED 2026-10-18, packaging host: the zip unpacked two ways into a fresh home directory inside a network
  namespace with no network; every checksum matched; the example compiled with 0 warnings and passed 3/3; nothing was
  written outside the kit.
- MEASURED 2026-10-18, a second council seat: the zip matches the sha256 above, all 44 entries match its `SHA256SUMS`,
  its `forge` is byte-identical to that seat's own install and its `solc` to the official
  `solc-linux-amd64-v0.8.35+commit.47b9dedd`.
- RECORDED 2026-10-18, ChatGPT's sandbox: "Foundry 1.5.1 launched successfully, Linux x86_64 · glibc 2.41";
  "compiler version and bundled checksums verified"; "3 passed · 0 failed", 32 seconds after upload.

## Scope

Carries **solc 0.8.35 only**: it runs standalone projects whose pragmas accept 0.8.35. It does not run this
repository's own suite by itself (`lib/v4-core/src/PoolManager.sol` pins `=0.8.26`; that needs a second compiler in
`~/.svm`).
