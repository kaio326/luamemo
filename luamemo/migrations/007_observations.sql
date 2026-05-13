-- migrations/007_observations.sql
--
-- Plan 9: Observation Consolidation
-- Adds:
--   * consolidated_at column on lm_memories (tracks which rows have been
--     processed by the consolidation engine)
--   * lm_observations table: deduplicated beliefs backed by proof counts,
--     evidence provenance, and freshness trends
--
-- Idempotent: safe to re-run.

-- Track which memory rows have been processed by consolidate.process().
ALTER TABLE lm_memories ADD COLUMN IF NOT EXISTS consolidated_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS lm_memories_consolidated_at_idx
    ON lm_memories (scope, consolidated_at)
    WHERE consolidated_at IS NULL;

-- Observation table: each row is a deduplicated belief synthesised from
-- one or more source memories.  Embedding is always REAL[] for portability
-- (cosine similarity is computed in Lua, same as the bruteforce backend).
CREATE TABLE IF NOT EXISTS lm_observations (
    id              BIGSERIAL PRIMARY KEY,
    scope           TEXT    NOT NULL,
    body            TEXT    NOT NULL,
    proof_count     INTEGER NOT NULL DEFAULT 1
                        CHECK (proof_count >= 1),
    evidence_ids    BIGINT[] NOT NULL DEFAULT '{}',
    evidence_quotes TEXT[]  NOT NULL DEFAULT '{}',
    freshness_trend TEXT    NOT NULL DEFAULT 'new'
                        CHECK (freshness_trend IN
                            ('new', 'strengthening', 'stable', 'weakening', 'stale')),
    last_reinforced TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    importance      REAL    NOT NULL DEFAULT 0.5
                        CHECK (importance >= 0.0 AND importance <= 10.0),
    embedding       REAL[]
);

CREATE INDEX IF NOT EXISTS lm_observations_scope_idx
    ON lm_observations (scope);

CREATE INDEX IF NOT EXISTS lm_observations_reinforced_idx
    ON lm_observations (scope, last_reinforced DESC);
