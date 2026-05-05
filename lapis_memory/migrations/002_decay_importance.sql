-- lapis-memory migration 002: importance + decay scoring
--
-- Adds two columns used by hybrid search to weight results:
--   importance  REAL  (0..10) — set on write; default 1.0
--   decay_rate  REAL  (0..1)  — per-day exponential decay; default 0.0 (no decay)
--
-- Effective weight at search time:
--   weight = importance * exp(-decay_rate * days_since_updated)
--
-- Defaults preserve existing search behaviour for rows created before this
-- migration. Safe to re-run.

ALTER TABLE lapis_memory
    ADD COLUMN IF NOT EXISTS importance REAL NOT NULL DEFAULT 1.0;

ALTER TABLE lapis_memory
    ADD COLUMN IF NOT EXISTS decay_rate REAL NOT NULL DEFAULT 0.0;

-- Range guards. Drop-then-add so re-running is safe even if bounds change.
ALTER TABLE lapis_memory
    DROP CONSTRAINT IF EXISTS lapis_memory_importance_range;
ALTER TABLE lapis_memory
    ADD CONSTRAINT lapis_memory_importance_range
    CHECK (importance >= 0.0 AND importance <= 10.0);

ALTER TABLE lapis_memory
    DROP CONSTRAINT IF EXISTS lapis_memory_decay_rate_range;
ALTER TABLE lapis_memory
    ADD CONSTRAINT lapis_memory_decay_rate_range
    CHECK (decay_rate >= 0.0 AND decay_rate <= 1.0);
