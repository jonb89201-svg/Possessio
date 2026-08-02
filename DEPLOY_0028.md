# DEPLOY — Option B (`hasStop`) and migration 0028

Answers to Assay's §4. Both measured on a real SQLite database, not reasoned.

## (a) ORDER: **MIGRATION FIRST, THEN WORKER.** Not reversible in order.

Both orders leave an intermediate window. They are not equivalent.

| order | window state | result |
|---|---|---|
| **migration → worker** | new schema + OLD worker | old write (`stop_bps=1000`) **OK** · new write (NULL) **OK** |
| worker → migration | old schema + NEW worker | stopped rule OK · **no-stop rule FAILS**: `NOT NULL constraint failed: desk_rules.stop_bps` |

Migration-first has **no failing case**: the new schema accepts everything the
old worker writes, because `1000` satisfies `CHECK (NULL OR 1..9999)`.

Worker-first fails, and fails on the **normal** path rather than an edge: after
this change `signRule` DEFAULTS to no stop, so a no-stop rule is what an
ordinary buy produces. In that window every buy would take a 500 on the ledger
write **after the user has already paid for the coin and signed** — the exact
state the mini-app's warning path exists to handle, reached for an operational
reason rather than a user one.

### The deploy instruction

1. **Re-verify the table is empty, at the moment of the change** — not earlier:
   ```
   curl -s https://possessio.io/api/desk/rules
   ```
   Expect `{"positions":[]}`. **If it returns any row, stop.** The blast-radius
   claim rests on this and it must be true *now*, not when it was checked.

2. **Apply the migration:**
   ```
   npx wrangler d1 execute possessio-radar-ledger --remote \
     --file radar/migrations/0028_stop_is_optional.sql
   ```

3. **Confirm the schema and — critically — the indexes:**
   ```
   npx wrangler d1 execute possessio-radar-ledger --remote \
     --command "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='desk_rules' AND name NOT LIKE 'sqlite_%'"
   ```
   Expect **three**: `idx_desk_rules_status`, `idx_desk_rules_owner_nonce`,
   `idx_desk_rules_open_position`. Two are UNIQUE and carry security
   properties. **If fewer than three come back, the replay guard is gone** —
   roll back before deploying the worker.

4. **Deploy the worker** (`console-deploy.yml` fires on a push to `main`
   touching `worker/**` or `public/**`).

5. **Confirm the endpoint still answers:** `curl -s https://possessio.io/api/desk/rules`

## (b) ROLLBACK: `0028_down_stop_is_required.sql`, with a hard precondition

**Reversible only until the first no-stop rule is written.** After that it is
not, and that is correct rather than a gap: a no-stop rule has no threshold, and
there is no value that can stand in for one. Zero was rejected. 10000 was
rejected. Any number written there would be a threshold the user never signed.

The down migration **does not invent a value**. It writes into a `NOT NULL`
column, so a NULL row aborts the whole script and leaves the original table
untouched. Measured across all three states:

| state | result |
|---|---|
| empty table (**production today**) | rollback **OK**, 3/3 indexes restored |
| rows all carrying a stop | rollback **OK**, rows and indexes intact |
| a no-stop row exists | **aborts loudly** — `NOT NULL constraint failed`; data verified intact, indexes intact |

If you hit that abort the rollback is genuinely unavailable, and the correct
move is forward: fix on the 0028 schema. **Do not hand-fill `stop_bps` to make
the script pass** — that forges a signed instruction.

Rollback command:
```
npx wrangler d1 execute possessio-radar-ledger --remote \
  --file radar/migrations/0028_down_stop_is_required.sql
```
Then redeploy the previous worker. Order reverses too: **worker back first, then
schema back** — the old worker cannot write NULL, so it is safe against the new
schema, while the new worker is not safe against the old one.
