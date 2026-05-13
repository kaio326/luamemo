-- Migration 008: Memory Tiers
--
-- Adds a `tier` column (0–3) to lm_memories for structural memory hierarchy:
--   0 = ephemeral  — raw session events; candidates for digest/deletion
--   1 = working    — default for new writes; active context
--   2 = consolidated — surfaced by consolidation engine; reliable facts
--   3 = core       — explicitly promoted; permanent architectural decisions
--
-- The `consolidated_at` column was added by migration 007; this migration
-- includes an idempotent ALTER for environments that skipped 007.
--
-- Idempotent: safe to run multiple times.

-- consolidated_at (already present if 007 was applied; no-op if re-run).
ALTER TABLE lm_memories ADD COLUMN IF NOT EXISTS consolidated_at TIMESTAMPTZ;

-- Tier column: defaults to 1 (working) so existing rows are unaffected.
ALTER TABLE lm_memories ADD COLUMN IF NOT EXISTS tier SMALLINT NOT NULL DEFAULT 1;

-- Backfill: derive tier from existing importance values.
UPDATE lm_memories SET tier = CASE
    WHEN importance < 0.3  THEN 0
    WHEN importance < 0.6  THEN 1
    WHEN importance < 0.85 THEN 2
    ELSE 3
END
WHERE tier = 1;   -- only touch default-value rows; skip rows already set

-- Composite index for tier-filtered searches.
CREATE INDEX IF NOT EXISTS lm_memories_tier_scope_idx
    ON lm_memories (scope, tier);
