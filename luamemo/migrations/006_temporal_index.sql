-- Migration 006: temporal retrieval index
-- Adds a created_at index for the temporal search leg introduced in v0.3.0.
-- Safe to apply multiple times (IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS lm_memories_created_at_scope_idx
    ON lm_memories (scope, created_at DESC);
