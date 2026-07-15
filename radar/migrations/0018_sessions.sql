-- 0018: the §0 SESSION GATE writer's storage — EXTEND the existing `sessions`
-- table (it shipped in the base schema, daily-keyed: session_date PK,
-- trailing_vol, avg_7d_vol, ratio, gate_pass, notes, recorded_ms). The base
-- table already carried the reading's core (window metric, 7d baseline, ratio,
-- pass, timestamp); what it lacked was the two fields that make a reading
-- AUDITABLE and §7-adjustable: the exact threshold each reading was judged
-- against, and a machine-readable statement of WHAT was measured. Add those.
--
-- WHY NOT A NEW TABLE: the base `sessions` table, the /radar/session-gate route,
-- and schema.sql already reference these columns; a parallel table would be
-- drift. One row per UTC day (session_date PK), recomputed each cadence tick so
-- today's row is always the freshest reading — a daily history the ledger (§5)
-- correlates gate readings against outcomes over the tuning window, exactly what
-- §0/§7 call for ("the threshold gets tightened or loosened by ratification once
-- real correlation data exists").
--
-- threshold_used: the config threshold this reading was judged at (§0's 0.60–0.70
--   band, default 0.65, env-overridable — NEVER frozen; stored per-reading so a
--   later threshold change stays honest about what each historical row used).
-- basis: what the window metric IS (the volume proxy + window/baseline spans +
--   sample counts). Self-documenting: a reader never has to guess the source.
--
-- Repo mirror: schema.sql folds these into the `sessions` CREATE (as of 0018).

ALTER TABLE sessions ADD COLUMN threshold_used REAL;  -- gate cutoff this reading was judged at (§7-adjustable, per-reading)
ALTER TABLE sessions ADD COLUMN basis TEXT;           -- machine-readable: what was measured (proxy + window + sample counts)
