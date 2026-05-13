-- Migration 009: Reinforcement event log (Hippocampus Digest)
--
-- lm_reinforcements records discrete feedback events that affect a memory's
-- importance trajectory: direct commands, corrections (mistakes), reversals,
-- and praise. The digest job (luamemo.digest) reads this table to decide
-- how far to escalate or diminish each memory's tier.
--
-- event_type values:
--   direct_command — agent received an explicit instruction about this memory
--   mistake        — agent made an error that this memory should prevent
--   reversal       — a previously recorded belief was contradicted
--   praise         — positive reinforcement; memory is confirmed correct
--
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS lm_reinforcements (
    id          BIGSERIAL PRIMARY KEY,
    memory_id   BIGINT NOT NULL REFERENCES lm_memories(id) ON DELETE CASCADE,
    scope       TEXT NOT NULL,
    event_type  TEXT NOT NULL CHECK (event_type IN
                    ('direct_command','mistake','reversal','praise')),
    delta       REAL NOT NULL,
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS lm_reinforcements_memory_idx
    ON lm_reinforcements (memory_id);

CREATE INDEX IF NOT EXISTS lm_reinforcements_scope_type_idx
    ON lm_reinforcements (scope, event_type);
