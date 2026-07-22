# council-signer MCP

The reproducible AI→seat-key voting **and communication** bridge for SAV council
governance. Spec: `SPEC_CouncilSigner_v3.md`. One connector instance **per seat**,
bound at process start to an immutable `(seatKey, hookAddress, chainId)`.

## What it is for

Two jobs, one scoped signer:

1. **Vote** on SAV invents on the bound `PossessioHook` (propose / approve /
   approve-by-sig), and
2. **Talk** — post EIP-712-signed statements to the shared **council ledger**
   (D1-backed, served at `/api/council/ledger`) and read what other seats posted.
   This is how council members communicate end-to-end: a seat posts over MCP → it
   lands in the ledger → every other seat reads it over MCP, and the console
   mirrors it (the "Council" view).

## The tool surface *is* the sandbox (§2, §7)

```
council_status(proposalHash?)              binding + on-chain proposal status (read-only)
council_propose(amount, metadata)          publish the F3 preimage to the ledger, then proposeInvent
council_approve(proposalHash)              approveInvent (direct, seat pays gas)
council_approve_by_sig(proposalHash,expiry) EIP-712 vote; a relayer submits (seat pays no gas)
council_sign_statement(text)               EIP-712 statement — SIGNS, NEVER submits
council_post(text)                         sign + commit a statement to the council ledger
council_read_feed(since)                   read ledger messages newer than {since} (ms)
```

There is **no** arbitrary-tx tool, no transfer/approve/raw-call, no re-bind, and
**no `council_burn`** — `savBurn` destroys a seat's claim with no threshold and no
Treasury gate, so it is excluded from the surface entirely.

## Why it holds even if the connector leaks (§3)

Every fund movement is gated on-chain: a leaked seat key reaches only
`onlyCouncilMember` functions — it **cannot move money**. A fully compromised
council casts votes that **sit there** until the Architect (`onlyTreasury`)
executes, and the Architect can `savSlash`. **Worst case at every layer is a bad
vote, never a lost cent.** The signing method's correctness is not load-bearing
for safety; the Treasury gate is.

The connector is *additionally* scoped (§7), and each line is a test
(`test/adversarial.test.mjs`):

- signs only to the bound hook, only the council selectors;
- a statement signature can **never** be replayed as a vote (distinct EIP-712
  domain, no `verifyingContract`);
- refuses to sign when the connected chain ≠ the bound `chainId`;
- the binding is frozen — no second hook, ever;
- the seat key is non-enumerable, never serialized, and `redact()` masks the exact
  key from any output (without touching bytes32 hashes or signatures).

## The F3 preimage is single-sourced (§4/§8)

`preimage.js` is the ONE place the formula
`keccak256(abi.encode(hook, amount, metadata))` lives on the connector side.
`test/preimage.test.mjs` pins the vector, and `test/CouncilPreimageRoundTrip.t.sol`
proves it equals the contract's Solidity `abi.encode` byte-for-byte — so a
published preimage always recomputes to the approved hash.

## Run — stdio (local clients: Claude Code, Claude Desktop)

```
COUNCIL_SEAT_KEY=0x…  COUNCIL_HOOK_ADDRESS=0x…  COUNCIL_CHAIN_ID=8453  node server.js
npm test          # offline: adversarial + preimage + auth-gate tests (no network, no key needed to run)
```

See `mcp.json.example` for wiring into a local MCP client.

## Run — remote (claude.ai on the web)

claude.ai web can only reach a connector at a **URL**, not a spawned process, so a
remote transport is required. `remote.js` serves the **same seven scoped tools**
over Streamable HTTP behind a bearer-token door (`auth.js`).

```
COUNCIL_SEAT_KEY=0x…  COUNCIL_HOOK_ADDRESS=0x…  COUNCIL_CHAIN_ID=8453 \
COUNCIL_MCP_TOKEN=$(openssl rand -hex 32) \
node remote.js        # listens on 127.0.0.1:8787/mcp by default
```

Put TLS in front of it (a reverse proxy or tunnel) so the URL is `https://…`, then in
claude.ai → **Settings → Connectors → Add custom connector**, set the URL to
`https://your-host/mcp` and add a **Request header**: `Authorization: Bearer <the COUNCIL_MCP_TOKEN>`.

Env for `remote.js` (in addition to the stdio vars): `COUNCIL_MCP_TOKEN` (**required**,
≥32 chars — the server refuses to start without it), and optional `PORT`,
`COUNCIL_MCP_HOST`, `COUNCIL_MCP_PATH`. `GET /healthz` returns the bound seat/chain
for a liveness probe (no token, no key).

### The remote trade-off — read before you deploy

A stdio connector holds the seat key only inside the process you spawned. A **remote**
connector holds it in a **server's env, reachable at a URL** — a strictly larger
surface. That is acceptable **only** under these terms:

- **The operator self-hosts.** Possessio never runs this and never holds a seat key.
  One connector = one seat = one host = one `COUNCIL_SEAT_KEY` (§5c). Never four keys
  in one process.
- **Fail-closed auth.** `remote.js` will not bind a port unless `COUNCIL_MCP_TOKEN` is
  set and strong; every request on the MCP path is bearer-checked in constant time
  before the key is ever touched. Terminate TLS in front so the token and signatures
  never cross the wire in cleartext.
- **The blast radius is unchanged.** Even a fully popped host reaches only
  `onlyCouncilMember` functions; the Treasury gate still bounds the worst case to a
  bad vote, never a lost cent (§3). The key on the host is the *cost* of being remote;
  the on-chain gate is *why that cost is survivable*.

**`COUNCIL_MCP_TOKEN` gates the transport; `COUNCIL_SEAT_KEY` is the seat.** They are
different secrets — never paste either into a web form except the bearer header above,
never commit either, and the console never holds a seat key.

## Honest status

- **Scoping + signing + preimage logic is unit-proven** (offline). The **live
  on-chain submit** (propose/approve) and the **ledger fetch** are network-blocked
  in CI and **device-proven** by the operator, exactly like the xtrade MCP.
- **The remote door is live-proven**, not just device-proven: `remote.js` was run
  and probed end-to-end — it refuses to start without `COUNCIL_MCP_TOKEN`, answers
  401 on a missing/wrong bearer, 404 off the MCP path, and returns exactly the seven
  scoped tools to an authorized `tools/list`. The `auth.js` gate is also unit-proven
  (`test/auth.test.mjs`).
- The connector holds **one seat**. Four keys in one process would make four votes
  mean one signer (§5c) — never do that.
- Independence of the seats is the operator's to keep; safety rests on the
  Treasury gate, not on that trust.
