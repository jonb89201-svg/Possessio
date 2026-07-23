-- 0025_council_ledger_nonce_unique.sql — N-1 (audit 2026-07-23): block replay.
-- The /api/council/ledger POST verified the EIP-712 signature but never enforced
-- nonce uniqueness, and GET returns the signature+nonce publicly — so a signed
-- statement could be harvested and re-POSTed without bound, a DoS on the shared
-- radar DB. A (seat, nonce) pair may now be committed AT MOST ONCE; the worker
-- maps the UNIQUE violation to a 409 NONCE_ALREADY_USED. The signature stays
-- public so the ledger remains independently verifiable — replay is killed by
-- this index, not by hiding the material. council_ledger is empty at index
-- creation, so no de-duplication pass is needed.
CREATE UNIQUE INDEX IF NOT EXISTS idx_council_ledger_seat_nonce
  ON council_ledger (seat, nonce);
