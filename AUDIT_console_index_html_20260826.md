# Cold-seat audit — `public/index.html` (Operator Console v0.6.0)

**Scope:** `public/index.html` @ main `e57e299` (4,942 lines). The live console:
ethers 6.13.4, wallet connect, `PossessioFactory.deployTemplate()` launch rail, council
feed, and the AI trade desk. **Sibling** `pitch/index.html` (354 lines, marketing) not
deep-audited — say the word and I'll cover it.

**Provenance:** MEASURED = grep + line-level read against the file. DERIVED = a
code-reading conclusion, not a runtime pentest (I did not execute the page in a browser).
Findings are PRIVATE / Architect-gated per council discipline.

---

## What holds (verified, not assumed)

| Control | Evidence | Verdict |
|---|---|---|
| DOM-injection escaping — coin feed (GeckoTerminal/DexScreener, attacker-controllable token name/symbol) | `coinHTML` escapes `c.s`/`c.n`/`c.img` via `esc` (L3956–3959, helper L3739 escapes `& < > " '`) | **Safe** |
| DOM-injection escaping — council feed | `row()` escapes seat/kind/body/ref (L4732–4740) | **Safe** |
| Wallet write chain guard | generic write throws if `walletChainId !== contract.chainId` (L2045–2046); launch rail re-reads `getNetwork()` at submission (L3051/3107/3284) | **Safe** |
| Launch-rail deploy integrity | preview-mode when factory unset — no fake addresses (D1); initCode hash-checked against on-chain `factory.templateCodehash()` **before** signing (D2, L2981–2983); fee read live from `DEPLOYMENT_FEE()` (D4); EIP-3009 nonce from `crypto.getRandomValues` (D3) | **Well-designed** |
| Reverse tabnabbing | all 8 `target="_blank"` carry `rel="noopener"` | **Safe** |
| Secrets in client | none (`api_key`/`secret`/`private_key`/64-hex sweep clean); scrub CI job also gates | **Safe** |
| Dangerous sinks | no `eval` / `new Function` / `srcdoc` / string-`setTimeout` / data-driven `on*` attribute | **Safe** |

---

## Findings

### W-1 — Unpinned, unversioned `esm.sh` dynamic import returns the wallet provider · **Medium** · MEASURED+DERIVED
`await import("https://esm.sh/@farcaster/miniapp-sdk")` at **L2171** and **L4880** — no
version pin (esm.sh resolves to *latest*), no integrity (a dynamic `import()` can't carry
SRI). L2171 is load-bearing: its result yields the wallet's EIP-1193 provider
(`sdk.wallet.getEthereumProvider()`, L2173) that **every miniapp transaction flows
through**. If esm.sh or the upstream package is compromised, attacker JS runs in the
wallet-connected page and can substitute the provider → transaction redirection / drain,
in the Farcaster/Base-app miniapp path.

Inconsistent with the page's own standard: ethers is pinned **and** SRI-hashed (L14).

**Fix (in order of strength):** (a) self-host/bundle the SDK same-origin — the pattern
already used for `/miniapp-solana.js` (L4914) — so it sits inside the page's trust
boundary and a CSP; or (b) pin an exact version (`@farcaster/miniapp-sdk@X.Y.Z`) and
subresource-verify via an esm.sh integrity query. (a) is preferred.

### W-2 — No Content-Security-Policy on a wallet-connected page · **Low–Medium** · MEASURED
No CSP (`http-equiv` or header) anywhere. A page that connects wallets, pulls third-party
script (cdnjs, esm.sh), and does many DOM-injection renders has zero containment if any
one of those is subverted (see W-1). Even report-only, a CSP makes the trust boundary
explicit and shrinks W-1's blast radius via a `script-src` / `connect-src` allowlist and
`frame-ancestors`.

Caveat: the console uses heavy inline `onclick=` handlers, so a *strict* `script-src`
needs refactoring first. But `connect-src` (RPCs + the two coin APIs + esm.sh + worker
endpoints), `frame-ancestors`, and `base-uri` are achievable now with no refactor.

### C-1 — Console pins SUPERSEDED contract addresses (redeploy repoint) · **Operational, not exploitable** · MEASURED
`CFG.FACTORY[8453] = 0x0DD06656…49Bd` (**L2999**) is the OLD factory; the adjacent comment
cites the OLD heart `0xE0612f38…`. After the fixed-source redeploy (factory →
`0x5509BA75…`, pool → `0xD064Bb5C…`), **both** this `CFG` **and** `public/artifacts/payments.json`
must be regenerated for the fixed template (new codehash
`0x7dd017f4…7130`). Design **fails safe** — a codehash mismatch drops the rail to preview
rather than mis-deploying (D2), so this is not a vulnerability — but it is a required
repoint. Already tracked in `REDEPLOY_CHECKLIST_2026-08-26.md` post-deploy §3; recorded
here so the console file itself carries the pointer.

### Note — read RPCs are public endpoints · Informational · MEASURED
Read providers are public (`mainnet.base.org`, `publicnode`, `1rpc.io`, `llamarpc`;
L523–524, L1536–1538). A lying read-RPC could feed a false `templateCodehash()` to the
client-side gate, but the deploy tx is signed through the user's own wallet/RPC and the
on-chain factory is the real authority, so impact is bounded to UI deception. Mitigated by
the multi-RPC ladder (L1542–1543). No action required; noted for completeness.

---

## Resolution (2026-08-26, same PR)

- **W-1 — FIXED.** All four `esm.sh` imports of `@farcaster/miniapp-sdk` pinned to an
  exact version `@0.3.0` (current `latest`, so no behavior change): `public/index.html`
  ×2, `public/miniapp-solana.js` L72, `radar/feed.ts` L486. This also closes the documented
  2026-08-05 drift defect (two SDK versions in one page) noted in `miniapp-solana.js`.
  Residual: still served by esm.sh (CDN trust) — full removal needs same-origin bundling,
  left as a follow-up; version-pinning removes the silent-bump vector, which was the finding.
- **W-2 — SHIPPED (Report-Only).** `public/_headers` now serves a
  `Content-Security-Policy-Report-Only` grounded in the real load set (adds the `esm.sh`
  script/connect origins and the Base read-RPCs the earlier draft omitted). Report-Only
  monitors without blocking, so it is safe to ship without device access; the enforcing
  `Content-Security-Policy` is drafted immediately beside it and flips on only after an
  on-device pass shows the Report-Only console clean (Codebyte Law: verify before enforcing).
- **C-1 — unchanged (redeploy checklist item).** Repoint happens at redeploy time.

## Bottom line
No live exploit in the console. The injection and wallet-tx paths are handled with real
care (escaping at every sink, chain-guarded writes, a codehash-gated fail-safe launch
rail). The one item worth acting on before the next announcement is **W-1** — pin or
self-host the miniapp SDK — with **W-2** (a CSP) as the defense-in-depth that would have
contained it. **C-1** is a redeploy checklist item, not a defect.
