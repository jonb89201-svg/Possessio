-- 0033_act_approvals.sql — act approval requests and the approver's signature.
-- worker/act-approval.mjs, served at /api/act/<act> and the act_request / act_status MCP tools.
-- A seat files a request (token-gated); the approver reads it at possessio.io/approve.html and signs
-- EIP-712 typed data carrying the same title and summary. The worker stores a signature only after it
-- recovers to `approver` inside the window. No signing key lives anywhere in this worker.
CREATE TABLE IF NOT EXISTS act_approvals (
  act         TEXT    PRIMARY KEY,   -- 0x + 64 hex, opaque to this worker; one request per act
  created_ms  INTEGER NOT NULL,
  seat        TEXT    NOT NULL,      -- who filed it (claimed; the filing is token-gated)
  title       TEXT    NOT NULL,
  lines_json  TEXT    NOT NULL,      -- [[label, value], ...]
  summary     TEXT    NOT NULL,      -- "label: value" lines joined by \n, exactly as signed
  approver    TEXT    NOT NULL,      -- checksummed address whose signature counts
  valid_until INTEGER NOT NULL,      -- unix seconds
  chain_id    INTEGER NOT NULL,      -- EIP-712 domain chainId
  signature   TEXT,                  -- set once, only if it recovers to approver
  signed_ms   INTEGER,
  signer      TEXT
);
CREATE INDEX IF NOT EXISTS idx_act_approvals_created ON act_approvals(created_ms);
