-- dev/init.sql
-- Bootstraps the lapis_memory_dev database for the dev container.
-- Uses the bruteforce (REAL[]) schema — no pgvector extension required,
-- so a plain postgres:15-alpine image is sufficient.
-- Inlines all migrations (001-004) as idempotent statements.
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- 001: base schema  (lapis_memory/schema_bruteforce.sql)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS lapis_memory (
    id            BIGSERIAL   PRIMARY KEY,
    scope         TEXT        NOT NULL,
    kind          TEXT        NOT NULL,
    title         TEXT        NOT NULL,
    body          TEXT        NOT NULL,
    tags          TEXT[]      NOT NULL DEFAULT '{}',
    metadata      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    embedding     REAL[],
    importance    REAL        NOT NULL DEFAULT 1.0
                      CHECK (importance >= 0.0 AND importance <= 10.0),
    decay_rate    REAL        NOT NULL DEFAULT 0.0
                      CHECK (decay_rate >= 0.0 AND decay_rate <= 1.0),
    was_truncated BOOLEAN     NOT NULL DEFAULT FALSE,
    fts           tsvector    GENERATED ALWAYS AS
                      (to_tsvector('english',
                          coalesce(title, '') || ' ' || coalesce(body, '')))
                  STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lapis_memory_scope_idx
    ON lapis_memory (scope);

CREATE INDEX IF NOT EXISTS lapis_memory_kind_idx
    ON lapis_memory (kind);

CREATE INDEX IF NOT EXISTS lapis_memory_tags_idx
    ON lapis_memory USING GIN (tags);

CREATE INDEX IF NOT EXISTS lapis_memory_fts_idx
    ON lapis_memory USING GIN (fts);

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

-- ---------------------------------------------------------------------------
-- 002: importance + decay_rate constraints (columns already in schema above)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 003: knowledge-graph table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS lm_kg_facts (
    id               BIGSERIAL   PRIMARY KEY,
    scope            TEXT        NOT NULL,
    subject          TEXT        NOT NULL,
    predicate        TEXT        NOT NULL,
    object           TEXT        NOT NULL,
    valid_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until      TIMESTAMPTZ,
    source_memory_id BIGINT      REFERENCES lapis_memory(id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lm_kg_facts_scope_idx
    ON lm_kg_facts (scope);

CREATE INDEX IF NOT EXISTS lm_kg_facts_sp_idx
    ON lm_kg_facts (subject, predicate);

CREATE INDEX IF NOT EXISTS lm_kg_facts_current_idx
    ON lm_kg_facts (subject, predicate)
    WHERE valid_until IS NULL;

ALTER TABLE lm_kg_facts
    DROP CONSTRAINT IF EXISTS lm_kg_facts_validity_window;
ALTER TABLE lm_kg_facts
    ADD CONSTRAINT lm_kg_facts_validity_window
    CHECK (valid_until IS NULL OR valid_until >= valid_from);

-- ---------------------------------------------------------------------------
-- 004: was_truncated flag (no-op: column already in schema above)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS lapis_memory_was_truncated_idx
    ON lapis_memory (was_truncated)
    WHERE was_truncated = TRUE;
