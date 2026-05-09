-- luamemo migration 005: composite index for (scope, kind) queries
--
-- Adds a composite btree index on (scope, kind) for queries that filter on
-- both columns simultaneously. The composite index also covers single-column
-- queries on `scope` alone (leftmost prefix rule), so it complements the
-- existing lm_memories_scope_idx without conflicting with it — the query
-- planner will choose whichever is cheaper.
--
-- Safe to re-run (IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS lm_memories_scope_kind_idx
    ON lm_memories (scope, kind);
