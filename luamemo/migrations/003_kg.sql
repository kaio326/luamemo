-- luamemo migration 003: knowledge-graph layer
--
-- Lightweight subject/predicate/object fact store with bitemporal
-- validity windows. Adjunct to the vector memory table; not a
-- replacement. Used to express directive memory ("the CSP rule for
-- inline styles") and entity memory ("user X's preferred theme")
-- where the truth value changes over time and the latest answer
-- must override older ones — a query pattern that vector search
-- handles poorly because it returns *similar* rows, not the
-- *currently valid* one.
--
-- Schema:
--   id                    BIGSERIAL primary key
--   scope                 TEXT NOT NULL   — same scope semantics as luamemo
--   subject               TEXT NOT NULL   — the entity the fact is about
--   predicate             TEXT NOT NULL   — the relation
--   object                TEXT NOT NULL   — the value (free-form)
--   valid_from            TIMESTAMPTZ NOT NULL DEFAULT now()
--   valid_until           TIMESTAMPTZ              — NULL = currently valid
--   source_memory_id      BIGINT REFERENCES lapis_memory(id) ON DELETE SET NULL
--   created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
--
-- Indexes:
--   - GIN on (subject, predicate) is overkill for plain text; use a
--     composite btree instead. (GIN would only pay off for trigram or
--     array-style filters; we don't need either.)
--   - Partial btree on (subject, predicate) WHERE valid_until IS NULL
--     for the hot "currently valid" lookup path.
--   - btree on (scope) so multi-tenant queries stay cheap.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS lm_kg_facts (
    id               BIGSERIAL PRIMARY KEY,
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

-- Hot path: "what is currently true for (subject, predicate)?"
CREATE INDEX IF NOT EXISTS lm_kg_facts_current_idx
    ON lm_kg_facts (subject, predicate)
    WHERE valid_until IS NULL;

-- Validity-window invariant. Drop-then-add so re-running is safe even
-- if bounds change.
ALTER TABLE lm_kg_facts
    DROP CONSTRAINT IF EXISTS lm_kg_facts_validity_window;
ALTER TABLE lm_kg_facts
    ADD CONSTRAINT lm_kg_facts_validity_window
    CHECK (valid_until IS NULL OR valid_until >= valid_from);
