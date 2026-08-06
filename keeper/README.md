# The Model B keeper

The thing that makes the stop real.

The user holds their own coin. They grant one **bounded, revocable** SPL delegate
per position. The keeper watches the executable price and fires the exit the
human already authored — the target, or the un-removable stop — including at 3am
while they are asleep, which is the only reason it exists.

It is not autonomous and is not meant to become autonomous. The human picks the
coin and the target on the desk. The keeper only executes an instruction that
already exists.

## What the keeper cannot do

Five rules. Each is enforced in code and proved in `test/keeper.test.js`.

| # | Rule | How it is enforced |
|---|------|--------------------|
| 1 | Never sell without a **live** delegate, re-read from the chain **every cycle** | `readDelegate` is called inside the per-position loop; a revoke lands on the next tick, not the next restart |
| 2 | Never sell a position whose **rule** is unknown | Structural: the loop iterates *rules*, never *grants*. An unruled delegate is never enumerated, so it can never be traded |
| 3 | Never exceed the **delegated** amount | The exit is built for `live.delegatedAmount`, never `live.amount` |
| 4 | Proceeds go to the **user** | The user is the swap's owner and destination; the keeper is fee payer and signer only |
| 5 | The stop is **read**, never assigned | No literal stop multiplier exists in the keeper; it comes from the position's `stopBps` |

Two more, from operating it:

- `DRY_RUN` defaults **on**. Live mode has to be chosen deliberately, and refuses
  to start — and refuses again at the point of signing — without a key.
- An unreadable account fails **closed**. An RPC hiccup stands one position down;
  it does not crash the loop and leave the others unwatched.

## Running it

```bash
# Watch only — builds exits and prints them, signs nothing. This is the default.
SOLANA_RPC_URL=<rpc> KEEPER_PUBKEY=<pubkey> node keeper/index.js

# Live. Requires the keypair, and DRY_RUN turned off by hand.
SOLANA_RPC_URL=<rpc> SOLANA_KEEPER_KEY=<bs58-or-json-array> DRY_RUN=0 node keeper/index.js
```

| Env | Default | Meaning |
|-----|---------|---------|
| `SOLANA_RPC_URL` | — | required |
| `DRY_RUN` | `1` | anything but `"0"` means sign nothing |
| `SOLANA_KEEPER_KEY` | — | bs58 string or JSON byte array; required only for live |
| `KEEPER_PUBKEY` | — | public key alone, enough for a dry run |
| `POSITION_SOURCE` | `desk` | `desk` \| `ledger` \| `onchain` |
| `DESK_URL` | `https://possessio.io` | rules, when the source is `desk` — polls `/api/desk/rules` |
| `LEDGER_FILE` | `./keeper/positions.json` | rules, when the source is `ledger` |
| `AUTOTARGET_ADDRESS`, `BASE_RPC_URL` | — | rules, when the source is `onchain` |
| `POLL_MS` | `5000` | tick interval |
| `SLIPPAGE_BPS` | `300` | quote and exit band |

The key is never logged and never written — startup prints the **public** key,
and the DoD asserts that.

### The rule ledger is still the Architect's call

`POSITION_SOURCE` is pluggable because that decision is open, and the loop must
not block on it:

- **`onchain`** — AutoTarget intents on Base. The target and the un-removable
  stop are facts on a chain, which is what the product claims. Needs the desk
  contracts deployed.
- **`ledger`** — a local record. Ships with no deploy, but the rule is then a
  promise from a server rather than a fact on a chain.

## Testing

```bash
node keeper/test/keeper.test.js                            # offline: 19 checks
SOLANA_RPC_URL=<rpc> node keeper/test/keeper-live.js       # live mainnet: 8 checks
```

The live suite signs nothing and spends nothing — every step runs through
`simulateTransaction` against real mainnet state.

### Why there is a live suite at all

The first delegate-discovery design passed every offline test and then died on
real infrastructure:

```
TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA excluded from account
secondary indexes; this RPC method unavailable for key
```

It scanned the whole SPL Token program for accounts delegated to the keeper.
Providers refuse that, because scanning every token account on Solana is
ruinously expensive. No amount of retrying fixes it. An offline DoD cannot catch
a whole design being impossible, so the replacement gets certified against the
live chain before it is trusted.

The replacement is better regardless: the keeper reads **one** account per
position it already has a rule for — targeted, always available, cheap — and
rule 2 becomes structural rather than a warning.

### Certifying the positive branch honestly

Proving the keeper *stands down* is easy. Proving it *fires* is the hard half:
no mainnet stranger has granted this keeper a delegate, and enumerating the
retail accounts that do use delegates is the exact scan the RPC refuses.

So the live suite executes the **real** grant instruction the user signs against
**real** mainnet state via `simulateTransaction`, reads back the post-execution
account bytes, and feeds them to the keeper's own `decide` predicate. The
authorisation rule lives in exactly one place so the harness cannot pass by
re-implementing it more leniently than the loop does. Then it drives a full
cycle on that state and watches the loop price the position on a live Jupiter
route and build a real exit.

Everything is real except the grant's presence in *committed* state.

`cycle` takes an injectable `readDelegate` only so that harness can reach the
fire path. It defaults to the live on-chain read, and the DoD asserts the
default — a deployment that forgets to pass one gets the chain, never a stub
that says yes.
