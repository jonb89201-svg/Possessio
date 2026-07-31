# Possessio Remote Agent — the Solana execution leg

**Base holds custody and the rules. Solana is where the trade happens.**
This service is the hand that executes a Solana pick that a human authored on
Base. It decides nothing.

```
human taps +50 on a SOL coin
        │
        ▼
AutoTarget.openIntent            (Base — the human signs, pays $0.02)
        │
        ▼
Rail.openRemoteLeg               (keeper — draws USDC under the vault's caps,
        │                         sends it to this agent's BASE address)
        ▼
THIS AGENT                       buys the mint on Solana from its FLOAT, watches
        │                         price, sells on target or the −10% stop
        ▼
returns USDC to the Rail on Base, then Rail.settleRemoteLeg MEASURES what arrived
```

## What this agent may and may not do

| | |
|---|---|
| **Never** chooses a coin | it only executes `intentId`s already authored on Base |
| **Never** changes a target or the stop | both are read from the on-chain intent |
| **Never** exceeds the vault's caps | the draw already happened on Base, under cap |
| **Only** sells back to USDC | the return address is the Rail, hardcoded |

The human-picks law is therefore structural on this side too: the agent has no
code path that creates an intent.

## The two-sided float — and why

pump.fun coins on the screen are **4–20 seconds old**. Bridging USDC from Base to
Solana takes minutes. So capital *cannot* be bridged per trade — the entry would
be long gone.

Instead the agent holds a **float on both chains**:

- **Solana float** — buys the mint the instant a leg opens.
- **Base float** — pays the measured proceeds back to the Rail.

A profitable trade grows the Solana side and shrinks the Base side (and vice
versa). Totals stay flat; the *split* drifts. The agent tracks the drift and
warns when either side falls below `FLOAT_MIN_*`, at which point the operator
rebalances (a normal CCTP transfer, off the trade path, no hurry).

**This is the trust window, stated plainly:** between the draw and the settle,
the drawn USDC is in this agent's custody, not in a contract. It is bounded by
`maxPerTrade`, by `maxOutstanding`, and by the fact that an unsettled leg starves
the next draw. A Solana program holding the float under the same caps is the way
to close it; that is future work, not this service.

## Running it

Keys come from the environment only. They are never written to disk, never
logged, and never leave the process.

```bash
cd agent && npm install

export BASE_RPC_URL=...            # your Base node / QuickNode
export SOLANA_RPC_URL=...          # your Solana node / QuickNode
export RAIL_ADDRESS=0x...          # the deployed Rail
export AUTOTARGET_ADDRESS=0x...    # the deployed AutoTarget
export BASE_KEEPER_KEY=0x...       # calls resolveIntent / settleRemoteLeg
export SOLANA_AGENT_KEY=[..]       # the float wallet (json array or base58)
export DRY_RUN=1                   # BUILD AND QUOTE ONLY — SIGNS NOTHING

node index.js
```

**Run with `DRY_RUN=1` first.** It performs the entire loop — reads the intent,
quotes Jupiter, builds the swap transaction, computes the exit trigger — and
stops immediately before signing, printing exactly what it would have sent.
That is the honest first run: you see the whole path execute without a lamport
moving.
