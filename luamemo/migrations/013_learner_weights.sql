-- Migration 013: per-scope learner weights + promotion audit (Phase 11)
--
-- The learned reranker/projection are now promoted PER SCOPE, and their weights
-- live in the DB (not a single global file) so they fit the stateless/multi-
-- instance model AND become the federation seam — Phase 12 syncs an org's weights
-- down through the same backing.
--
--   lm_learner_weights : versioned weight blobs per (scope, kind); one row per
--                        (scope, kind) has is_current = true (the active model).
--   lm_promotion_runs  : an audit row per promote attempt (promote / reject /
--                        skip) with the gate scores, for observability + rollback.
--
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS lm_learner_weights (
    id          BIGSERIAL   PRIMARY KEY,
    scope       TEXT        NOT NULL,
    kind        TEXT        NOT NULL,          -- 'reranker' | 'projection'
    version     INTEGER     NOT NULL,          -- monotonic per (scope, kind)
    weights     JSONB       NOT NULL,
    score       REAL,                          -- held-out gate score at creation
    note        TEXT,
    is_current  BOOLEAN     NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (scope, kind, version)
);

CREATE INDEX IF NOT EXISTS lm_learner_weights_current_idx
    ON lm_learner_weights (scope, kind, is_current);

CREATE TABLE IF NOT EXISTS lm_promotion_runs (
    id              BIGSERIAL   PRIMARY KEY,
    scope           TEXT        NOT NULL,
    kind            TEXT        NOT NULL,
    decision        TEXT        NOT NULL,      -- 'promote' | 'reject' | 'skip'
    new_score       REAL,
    incumbent_score REAL,
    n_train         INTEGER,
    n_gate          INTEGER,
    version         INTEGER,                   -- version created when decision='promote'
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS lm_promotion_runs_scope_idx
    ON lm_promotion_runs (scope, kind, created_at DESC);
