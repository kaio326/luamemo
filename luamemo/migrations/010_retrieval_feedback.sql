-- Migration 010: Retrieval feedback event log (learned-from-usage substrate)
--
-- lm_retrieval_feedback records each retrieval event — the query text and the
-- ordered candidate memory ids that were surfaced — so a later reinforcement
-- (lm_reinforcements: mistake/reversal/direct_command/praise) on any candidate
-- can be joined back into a (query, positive, negatives) training triple for the
-- learned reranker (Phase 4) and projection (Phase 5).
--
-- Written append-only by store.search when config.feedback_enabled is true.
-- Signal-quality rule: frequency alone produces candidate lists but NO training
-- positive — a positive requires a reinforcement — so corrections/outcomes
-- dominate and raw access frequency never does.
--
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS lm_retrieval_feedback (
    id            BIGSERIAL   PRIMARY KEY,
    scope         TEXT        NOT NULL,
    query         TEXT        NOT NULL,
    candidate_ids BIGINT[]    NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS lm_retrieval_feedback_scope_idx
    ON lm_retrieval_feedback (scope, created_at DESC);
CREATE INDEX IF NOT EXISTS lm_retrieval_feedback_candidates_idx
    ON lm_retrieval_feedback USING GIN (candidate_ids);
