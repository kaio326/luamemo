-- Migration 011: add the 'miss' reinforcement event type (retrieval-miss signal)
--
-- A 'miss' means retrieval FAILED to surface a memory that was needed. It is
-- detected automatically — a near-duplicate write re-created a memory that
-- should have been found (store.write), or a correction whose target already
-- existed but was never retrieved (sensing). It is the OPPOSITE of 'mistake':
-- the memory's content is fine, the ranking/recall failed. So a miss makes the
-- memory MORE findable (importance bump in digest.record_event) and feeds the
-- learned reranker/projection as a positive — it never diminishes the memory.
--
-- Idempotent: always drops the old CHECK before re-adding, safe to re-run.

ALTER TABLE lm_reinforcements DROP CONSTRAINT IF EXISTS lm_reinforcements_event_type_check;
ALTER TABLE lm_reinforcements ADD CONSTRAINT lm_reinforcements_event_type_check
    CHECK (event_type IN ('direct_command','mistake','reversal','praise','miss'));
