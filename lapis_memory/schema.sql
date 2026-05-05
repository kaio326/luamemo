-- lapis-memory schema (PostgreSQL + pgvector)
--
-- Default embedding dimension is 384 (sentence-transformers/all-MiniLM-L6-v2
-- and Ollama's nomic-embed-text). If you use a different model, edit the
-- vector(384) declaration BEFORE running this file.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS lapis_memory (
    id          BIGSERIAL PRIMARY KEY,
    scope       TEXT NOT NULL,
    kind        TEXT NOT NULL,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    tags        TEXT[] NOT NULL DEFAULT '{}',
    metadata    JSONB  NOT NULL DEFAULT '{}'::jsonb,
    embedding   vector(384),
    -- Hybrid-search ranking weights (see migration 002):
    --   weight = importance * exp(-decay_rate * days_since_updated)
    importance  REAL   NOT NULL DEFAULT 1.0
                    CHECK (importance >= 0.0 AND importance <= 10.0),
    decay_rate  REAL   NOT NULL DEFAULT 0.0
                    CHECK (decay_rate >= 0.0 AND decay_rate <= 1.0),
    fts         tsvector GENERATED ALWAYS AS
                    (to_tsvector('english',
                        coalesce(title, '') || ' ' || coalesce(body, '')))
                STORED,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lapis_memory_scope_idx
    ON lapis_memory (scope);

CREATE INDEX IF NOT EXISTS lapis_memory_kind_idx
    ON lapis_memory (kind);

CREATE INDEX IF NOT EXISTS lapis_memory_tags_idx
    ON lapis_memory USING GIN (tags);

CREATE INDEX IF NOT EXISTS lapis_memory_fts_idx
    ON lapis_memory USING GIN (fts);

-- HNSW for fast approximate nearest neighbour search.
-- Requires pgvector >= 0.5.0. Use ivfflat on older versions.
CREATE INDEX IF NOT EXISTS lapis_memory_embedding_hnsw_idx
    ON lapis_memory USING hnsw (embedding vector_cosine_ops);

-- Auto-update updated_at on UPDATE.
CREATE OR REPLACE FUNCTION lapis_memory_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS lapis_memory_touch_updated_at_trg ON lapis_memory;
CREATE TRIGGER lapis_memory_touch_updated_at_trg
    BEFORE UPDATE ON lapis_memory
    FOR EACH ROW
    EXECUTE FUNCTION lapis_memory_touch_updated_at();
