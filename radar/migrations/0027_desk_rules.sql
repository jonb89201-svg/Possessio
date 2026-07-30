-- 0027_desk_rules.sql — the desk's rule ledger.
--
-- THE MISSING LINK. The console's trading desk already buys the coin and grants
-- the keeper a bounded delegate, but it recorded the human's actual instruction
-- — this coin, this target, this stop — only in browser memory. Refresh the tab
-- and the rule was gone, so the keeper had nothing to watch and the stop could
-- never fire. This table is where that instruction lives.
--
-- A rule is NOT authority. The keeper can only sell if the chain ALSO says it
-- holds a live delegate over that exact account. A row here without a delegate
-- is inert; a delegate without a row here is never even looked at, because the
-- keeper iterates rules, never grants.
--
-- BUT a forged rule over a wallet that HAS granted a delegate would be a real
-- attack: set the target to zero and the keeper dumps someone's position on
-- command. So every row is signed by the Solana wallet it applies to, verified
-- server-side (Ed25519, WebCrypto) before insert. `owner` is the verified
-- signer, not a claim. This is also the honest consent moment: "sell at +25% or
-- -10%" is the thing the human is really agreeing to, so it gets a signature of
-- its own rather than being inferred from the buy.
CREATE TABLE IF NOT EXISTS desk_rules (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms       INTEGER NOT NULL,            -- server receive time (ms)
  owner       TEXT    NOT NULL,            -- Solana pubkey (base58) — the VERIFIED signer
  mint        TEXT    NOT NULL,            -- the picked coin (base58 mint)
  decimals    INTEGER NOT NULL,            -- so the keeper prices without a lookup
  entry_price REAL    NOT NULL,            -- USDC per whole token at the buy
  target_bps  INTEGER NOT NULL,            -- +1000 / +2500 / +5000 (the desk's three buttons)
  stop_bps    INTEGER NOT NULL,            -- 1000 — the un-removable -10%
  status      TEXT    NOT NULL DEFAULT 'open',  -- open | exited | cancelled
  nonce       TEXT    NOT NULL,            -- replay guard, bound into the signature
  signature   TEXT    NOT NULL,            -- Ed25519 over the canonical preimage
  exit_kind   TEXT,                        -- target | stop, set when the keeper fires
  exit_price  REAL,
  exit_sig    TEXT                         -- the Solana transaction signature
);

-- The keeper polls for open rules; this is its hot path.
CREATE INDEX IF NOT EXISTS idx_desk_rules_status ON desk_rules(status, ts_ms);

-- Replay is dead at the DB: a wallet may commit any nonce at most once, so a
-- rule harvested from the public GET can never be re-POSTed to resurrect a
-- cancelled position or re-arm one the user closed.
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_owner_nonce ON desk_rules(owner, nonce);

-- One open rule per wallet+coin. A second buy of the same coin updates the
-- existing rule rather than creating a rival instruction — two open rules over
-- one delegate would race, and the keeper would have no principled way to
-- choose which target is the human's real intent.
CREATE UNIQUE INDEX IF NOT EXISTS idx_desk_rules_open_position
  ON desk_rules(owner, mint) WHERE status = 'open';
