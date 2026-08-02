# RUNBOOK — Option B (`hasStop`) + migration 0028

**Written for a phone.** Every command is one line, copy-paste, no editing.
Four of the seven steps are checks that can say STOP.

**Order is not optional: MIGRATION FIRST, MERGE LAST.**
Merging is the worker deploy — `public/**` and `worker/**` are on
`console-deploy.yml`'s trigger paths, so the merge itself pushes the new worker
live. Merge before the migration and you get the failing order: new worker on
old schema, where an ordinary buy hits `NOT NULL constraint failed` **after the
user has paid for the coin and signed.**

Measured, not reasoned:

| order | window | result |
|---|---|---|
| **migration → merge** | new schema + old worker | old write OK · new write OK — **no failing case** |
| merge → migration | old schema + new worker | **no-stop rule FAILS** `NOT NULL constraint failed: desk_rules.stop_bps` |

---

## STEP 1 — is the table empty? (gate)

Blast radius rests on this. Check it **now**, not on an earlier reading.

```
curl -s https://possessio.io/api/desk/rules
```

Expect exactly:
```
{"positions":[]}
```

**STOP if any row comes back.** A populated table means someone authored a rule
and the migration needs a different conversation.

---

## STEP 2 — apply the migration

```
npx wrangler d1 execute possessio-radar-ledger --remote --file radar/migrations/0028_stop_is_optional.sql
```

Expect success with no error. It rebuilds `desk_rules` so `stop_bps` can be NULL
and adds `CHECK (stop_bps IS NULL OR stop_bps BETWEEN 1 AND 9999)`.

---

## STEP 3 — did the indexes survive? (gate — the important one)

`DROP TABLE` takes indexes with it. **Two of the three are UNIQUE and carry
security properties**: the replay guard, and one-open-rule-per-wallet-per-coin.
Nothing in the test suite observes an index, so this is the only place their
absence would be noticed.

```
npx wrangler d1 execute possessio-radar-ledger --remote --command "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='desk_rules' AND name NOT LIKE 'sqlite_%' ORDER BY name"
```

Expect **three** rows:
```
idx_desk_rules_open_position
idx_desk_rules_owner_nonce
idx_desk_rules_status
```

**STOP if fewer than three. The replay guard is gone — do not merge.**
Roll back with STEP 7 and re-run 0027.

---

## STEP 4 — does the CHECK actually bite? (gate)

Proves zero is unwritable at the storage layer, not just at the validator.

```
npx wrangler d1 execute possessio-radar-ledger --remote --command "INSERT INTO desk_rules (ts_ms,owner,mint,decimals,entry_price,target_bps,stop_bps,nonce,signature) VALUES (0,'CHECKTEST','CHECKTEST',6,1.0,1000,0,'checktest','x')"
```

Expect it to **FAIL** with a CHECK constraint error.

**STOP if it succeeds** — and if it does, remove the row before doing anything
else:
```
npx wrangler d1 execute possessio-radar-ledger --remote --command "DELETE FROM desk_rules WHERE owner='CHECKTEST'"
```

---

## STEP 5 — merge PR #89  ← this is the worker deploy

https://github.com/jonb89201-svg/Possessio/pull/89

It is a **draft** — mark it ready for review first, then merge.

Merging pushes `public/index.html`, `public/miniapp-solana.js` and
`worker/index.ts` live via `console-deploy.yml`. Watch the Actions run finish
before STEP 6.

---

## STEP 6 — confirm the console and the ledger still answer

```
curl -s https://possessio.io/api/desk/rules
```
Expect `{"positions":[]}` again.

```
curl -s -o /dev/null -w "%{http_code}\n" https://possessio.io
```
Expect `200`.

Then open the desk on the phone and check three things by eye:
- the hero says **no automatic stop-loss** and shows **Force Sell**
- a coin card shows the **contract address chip** and a **DexScreener** link
- tapping **Buy · set target** opens a sheet with the **gain slider, default 10%**

---

## STEP 7 — rollback, only if needed

Reverse order: **worker back first, then schema.** The old worker cannot write
NULL so it is safe against the new schema; the new worker is not safe against
the old one.

1. Revert the merge on GitHub (this redeploys the previous worker).
2. Then:
```
npx wrangler d1 execute possessio-radar-ledger --remote --file radar/migrations/0028_down_stop_is_required.sql
```

**Reversible only until the first no-stop rule is written**, and that limit is
correct rather than a gap. A no-stop rule has no threshold and no value can
stand in for one — zero was rejected, 10000 was rejected, and any number written
there would be a threshold the user never signed.

The down migration does not invent one. It writes into a `NOT NULL` column, so a
NULL row **aborts the script and leaves the table untouched**. Verified on a
real SQLite database:

| state | result |
|---|---|
| empty table (production today) | rollback OK, 3/3 indexes restored |
| rows all carrying a stop | rollback OK, rows and indexes intact |
| a no-stop row exists | aborts loudly, data intact, indexes intact |

If you hit that abort, the rollback is genuinely unavailable and the correct
move is forward — fix on the 0028 schema. **Do not hand-fill `stop_bps` to make
the script pass.** That forges a signed instruction.

---

## What this deploy changes

- **"No stop" becomes an absence, not a value.** Zero is rejected at the
  validator and unwritable at the storage layer. The keeper branches; it never
  computes an unreachable threshold.
- **Token-2022 support on both paths.** 25 of 25 live radar picks are
  Token-2022; before this the keeper silently refused every position and the
  mini-app's delegate grant would have failed outright.
- **The signed target derives from the fill**, not the quote.
- **The console no longer claims a stop-loss it does not have** — including the
  preview animation that used to *demonstrate* one.
- **Every radar pick carries its contract address**, one tap to copy.

## What this deploy does NOT change

- Nothing goes live for users. Zero rules exist, the keeper defaults to
  `DRY_RUN`, a live exit needs an undeployed keypair, and the desk contracts are
  retired pending relaunch.
- Part 1 display work (MC **and** price, both labelled) is unfinished.
- Part 3 mint-authority flag is unshipped — it has never been observed to fire.
