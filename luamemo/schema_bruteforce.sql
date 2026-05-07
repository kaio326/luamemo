-- luamemo schema (PostgreSQL, NO extensions)
--
-- Use this file when you cannot or do not want to install pgvector. It
-- creates the same table as schema.sql with two differences:
--   1. `embedding` is REAL[] instead of vector(N).
--   2. No HNSW index is created (Lua does the cosine work at query time).
--
-- Pair with `backend = "bruteforce"` (or leave `backend = "auto"`; the
-- library detects the missing extension and switches automatically).
--
-- Default embedding dimension is 384 (sentence-transformers/all-MiniLM-L6-v2
-- and Ollama's nomic-embed-text). The brute-force backend does not enforce
-- a length at the column level; the embedder dispatcher in embed.lua
-- validates it on every call.

CREATE TABLE IF NOT EXISTS lm_memories (
    id          BIGSERIAL PRIMARY KEY,
    scope       TEXT NOT NULL,
    kind        TEXT NOT NULL,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    tags        TEXT[] NOT NULL DEFAULT '{}',
    metadata    JSONB  NOT NULL DEFAULT '{}'::jsonb,
    embedding   REAL[],
    -- Hybrid-search ranking weights (see migration 002):
    --   weight = importance * exp(-decay_rate * days_since_updated)
    importance  REAL   NOT NULL DEFAULT 1.0
                    CHECK (importance >= 0.0 AND importance <= 10.0),
    decay_rate  REAL   NOT NULL DEFAULT 0.0
                    CHECK (decay_rate >= 0.0 AND decay_rate <= 1.0),
    -- TRUE when the embedder client truncated the input before producing
    -- the embedding (see config.embed_max_chars). Surfaced by `memo doctor`.
    was_truncated BOOLEAN NOT NULL DEFAULT FALSE,
    fts         tsvector GENERATED ALWAYS AS
                    (to_tsvector('english',
                        coalesce(title, '') || ' ' || coalesce(body, '')))
                STORED,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lm_memories_scope_idx
    ON lm_memories (scope);

CREATE INDEX IF NOT EXISTS lm_memories_kind_idx
    ON lm_memories (kind);

CREATE INDEX IF NOT EXISTS lm_memories_tags_idx
    ON lm_memories USING GIN (tags);

CREATE INDEX IF NOT EXISTS lm_memories_fts_idx
    ON lm_memories USING GIN (fts);

-- No vector index: the brute-force backend computes cosine in Lua over a
-- candidate set pre-filtered by scope/kind/FTS. Install pgvector and use
-- schema.sql instead when you outgrow the brute-force crossover.

-- Auto-update updated_at on UPDATE.
CREATE OR REPLACE FUNCTION lm_memories_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS lm_memories_touch_updated_at_trg ON lm_memories;
CREATE TRIGGER lm_memories_touch_updated_at_trg
    BEFORE UPDATE ON lm_memories
    FOR EACH ROW
    EXECUTE FUNCTION lm_memories_touch_updated_at();
