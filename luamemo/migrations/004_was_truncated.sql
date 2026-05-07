-- luamemo migration 004: was_truncated flag
--
-- Records whether the embedder client truncated the input text before
-- producing the embedding (see config.embed_max_chars). Used by
-- `memo doctor` to surface embedder-fit problems with concrete counts.
--
-- Default is FALSE so existing rows keep their semantics. When
-- embed_max_chars is unset (the historical default) no row will ever be
-- flagged.
--
-- Safe to re-run.

ALTER TABLE lm_memories
    ADD COLUMN IF NOT EXISTS was_truncated BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS lm_memories_was_truncated_idx
    ON lm_memories (was_truncated)
    WHERE was_truncated = TRUE;
