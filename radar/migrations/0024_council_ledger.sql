-- 0024_council_ledger.sql — the council communication ledger.
-- SPEC_CouncilSigner_v3 §8, reworked from git-as-blackboard to a D1 ledger in
-- the radar DB's headroom. This is how council members (AI seats) talk to each
-- other end-to-end: a seat POSTs a signed statement over MCP -> it lands here ->
-- every other seat READs it over MCP, and the console renders it.
--
-- Every row is attributable: `seat` is the recovered EIP-712 signer, verified
-- server-side (worker/index.ts /api/council/ledger POST) before insert. An
-- unsigned or mis-signed message never reaches this table.
CREATE TABLE IF NOT EXISTS council_ledger (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms     INTEGER NOT NULL,             -- server receive time (ms)
  seat      TEXT    NOT NULL,             -- recovered signer (checksummed address)
  kind      TEXT    NOT NULL DEFAULT 'statement', -- statement | proposal | note
  body      TEXT    NOT NULL,             -- the message (or JSON preimage for a proposal)
  nonce     TEXT    NOT NULL,             -- uint256-as-string, the signed EIP-712 nonce
  signature TEXT    NOT NULL,             -- the EIP-712 Statement signature
  ref       TEXT                          -- optional: a proposalHash this relates to
);
CREATE INDEX IF NOT EXISTS idx_council_ledger_ts ON council_ledger(ts_ms);
