-- 0035_desk_trending.sql — the desk's hand-curated trending list (2026-10-15).
--
-- Manual only: the Architect finds a coin by address on the desk and adds it,
-- or deletes it. Every write is an Ed25519 signature from the wallet, verified
-- by the worker against the SAME allowlist that gates arming the keeper
-- (deskArmingAllowed). `added_by` is that verified signer, never a claim.
--
-- Read by GET /api/desk/trending; written only by POST /api/desk/trending
-- (worker/desk-feed.mjs, handleTrending).
CREATE TABLE IF NOT EXISTS desk_trending (
  mint     TEXT PRIMARY KEY,          -- Solana mint, base58, 32 bytes (checked before insert)
  added_by TEXT NOT NULL,             -- the verified signer
  ts_ms    INTEGER NOT NULL
);

-- Spent nonces. A signed add/delete names a timestamp and is accepted only
-- within 10 minutes of the worker's clock; recording its nonce means even
-- inside that window the same signature cannot be used twice. Rows older than
-- twice the window are pruned on each write.
CREATE TABLE IF NOT EXISTS desk_trending_nonces (
  nonce TEXT PRIMARY KEY,
  ts_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS desk_trending_nonces_ts ON desk_trending_nonces (ts_ms);
