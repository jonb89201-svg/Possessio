# HANDOFF — PossessioTestnetLaunchPool + Worker Dripper
**Origin:** Code Integrity seat, per Architect directive ("build the pool the console/repo pulls from that unlocks testnet launches").
**Status:** SPEC-GRADE. Codebyte Law applies — none of this exists until Claude Code compiles it and the suite runs green. This sandbox has no network, so `forge` could not be installed; the Solidity is hand-audited but **UNCOMPILED**.

---

## What this is

One on-chain pool on Base Sepolia that aggregates every faucet drip, plus one Worker endpoint that draws stipends from it. Together they unlock console testnet launches: a zero-balance wallet taps **Fuel**, receives launch gas (and 100 testnet USDC for the factory fee), and the LaunchRail unlocks.

```
faucets (CDP / Chainstack / QuickNode / PoW / Alchemy)
        │  all claims pointed at ONE address:
        ▼
PossessioTestnetLaunchPool (Base Sepolia, open receive())
        ▲ drawEth / drawToken — OPERATOR_ROLE only
        │
possessio Worker  POST /api/testnet/drip   (KV rate-limit + chain cooldown)
        ▲
        │
Console LaunchRail (testnet mode): balance check → Fuel → poll → Launch unlocked
```

## Substrate-honest guards (SaltPool tradition)

| Guard | Mechanism |
|---|---|
| Cannot exist on mainnet | Constructor reverts `WrongChain` unless `block.chainid == 84532` |
| Owner ≠ operator | Constructor `RoleSeparationViolation` |
| Operator can never be paid a sweep | `sweepEth/sweepToken` revert if target holds OPERATOR_ROLE |
| Honest empty state | `PoolEmpty()` revert, never silent partial send |
| Honest throttling | `CooldownActive(readyAt)` carries the exact unlock timestamp |
| No hidden admin | OWNER_ROLE self-administered; DEFAULT_ADMIN_ROLE held by no one; pinned by test |
| Deploy key retires holding nothing | Owner = Base Account **at construction** — nothing to renounce |
| Gas + fee in one session | ETH and per-token cooldowns tracked independently |

`OWNER_ROLE` = `0xb19546dff01e856fb3f010c267a7b1c60363cf8a4664e21cc89c26224620214e` — independently recomputed this session via KAT-verified keccak; a test pins it against drift.

## Files

| File | Destination in repo | Note |
|---|---|---|
| `src/PossessioTestnetLaunchPool.sol` | `src/` | contract |
| `test/PossessioTestnetLaunchPool.t.sol` | `test/` | 16 tests; `setUp` must keep `vm.chainId(84532)` or everything reverts on Foundry's 31337 default |
| `script/DeployTestnetLaunchPool.s.sol` | `script/` (not scripts/) | owner defaults to Base Account `0x6cfe...9203` |
| `worker/drip-endpoint.ts` | `possessio` Worker | route `POST /api/testnet/drip` |

## Provisioned already (this session)

- Cloudflare KV namespace **possessio-testnet-drip-limits**, id `49f2f2c858424605a9e90efc11e5e5f7` — bind as `DRIP_LIMITS`. Free tier, deletable if red-penned.

## Claude Code steps (repo writer)

1. Land the three Solidity files; adjust OZ remappings to repo convention.
2. `forge build` + `forge test` — suite must go green **before** any claim of existence. On green: 674 + 16 = 690 pending Architect certification of a full run. (These are local tests, no fork; they extend the Sepolia-side count.)
3. Merge `drip-endpoint.ts` into the Worker router; add the KV binding + vars from the file header to wrangler config.
4. Console LaunchRail testnet mode: on wallet connect, read balance; if `< 0.005 ETH` or USDC `< 100e6`, render **Fuel from pool** → POST drip (eth, then usdc) → poll balances → enable Launch. Bilingual ⓘ: plain face "Free test fuel so you can try a launch"; technical layer names the pool address, stipend, cooldown, and the honest error states (`POOL_EMPTY`, `COOLDOWN_ACTIVE`).
5. Gauntlet + device-look on working branch before merge, per GATE 5 pattern.

## Architect steps (keys + ratification)

1. Generate a **new throwaway testnet operator key**. Never the wave PK, never the old deployer, never anything mainnet-privileged. Its blast radius if leaked: draining testnet tokens at stipend rate on 84532 — nothing else.
2. Set the Worker secret: `wrangler secret put TESTNET_OPERATOR_PK` (terminal only).
3. When the pool deploy broadcasts (any funded testnet key can deploy — the deployer holds no role afterward): record the address, then point **every faucet claim at the pool address directly** (open `receive()`). Until then, keep pooling to a wallet and forward once.
4. From the Base Account (owner), one enable call: `setTokenStipend(0x036CbD53842c5426634e7929541eC2318f3dCF7e, 100000000)` — turns on the 100 USDC fee drip.
5. Feed the pool USDC too: CDP faucet drips testnet USDC; send claims to the pool address.

## Open for ratification

1. **Stipend/cooldown defaults:** 0.02 ETH + 100 USDC per draw, 12 h cooldown. Owner-tunable live; red-pen the starting values.
2. **Draw gating today is operator-key + KV + chain cooldown.** A later hardening seam exists: restrict `drawEth` recipients to wallets that subsequently call the factory (post-hoc audit via events is already possible — every draw and launch is on-chain). Not needed for the rehearsal.
3. **This pool is testnet plumbing, not the wave.** It rehearses constructor-set ownership (the strongest Principle 1 form) but the grant→verify→renounce reps still happen with the real stack per the amended runbook.

*Additive document. Nothing here supersedes the wave runbook; it front-runs it with a rehearsal fuel system.*
