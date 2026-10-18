-- luamemo.schema
-- The SQLite schema, as an ordered list of migrations, applied when a database is
-- opened (luamemo.db). Each migration runs once, inside a transaction, and is recorded
-- in lm_migrations; PRAGMA user_version mirrors the count.
--
-- Conventions: timestamps are INTEGER microseconds since the epoch (UTC); JSON values
-- (tags, metadata, …) are TEXT; vectors are float32 BLOBs with their L2 norm next to them;
-- booleans are INTEGER 0/1. Full-text search is the FTS5 table lm_memories_fts (contentless,
-- porter stemmer), kept in step with lm_memories by triggers.

local M = {}

-- Microseconds since the epoch, inside SQL. SQLite's clock ticks in milliseconds
-- ('now' is a whole millisecond): a value it gives can be BEHIND a µs time luamemo
-- wrote a moment earlier — so the touch trigger below never moves a row back.
local NOW_US = "CAST((julianday('now') - 2440587.5) * 86400000000 AS INTEGER)"
M.NOW_US = NOW_US

-- The secrets vault (luamemo.secrets): values encrypted with the master key; names and
-- metadata in clear. In every luamemo database, and alone in a separate store file
-- (the per-user federation keyring — SECRETS_MIGRATIONS).
local SECRETS_TABLE = [[
CREATE TABLE lm_secrets (
    name         TEXT PRIMARY KEY,
    value        TEXT NOT NULL,
    description  TEXT,
    internal     INTEGER NOT NULL DEFAULT 0,
    used_count   INTEGER NOT NULL DEFAULT 0,
    last_used_at INTEGER,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);
]]

M.MIGRATIONS = {
{ name = "001_init", sql = [[
CREATE TABLE lm_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE lm_memories (
    id              INTEGER PRIMARY KEY,
    scope           TEXT NOT NULL,
    kind            TEXT NOT NULL,
    title           TEXT NOT NULL,
    body            TEXT NOT NULL,
    tags            TEXT NOT NULL DEFAULT '[]',
    metadata        TEXT NOT NULL DEFAULT '{}',
    embedding       BLOB,
    emb_norm        REAL,
    importance      REAL NOT NULL DEFAULT 1.0 CHECK (importance >= 0 AND importance <= 10),
    decay_rate      REAL NOT NULL DEFAULT 0.0 CHECK (decay_rate >= 0 AND decay_rate <= 1),
    was_truncated   INTEGER NOT NULL DEFAULT 0,
    tier            INTEGER NOT NULL DEFAULT 1,
    consolidated_at INTEGER,
    created_at      INTEGER NOT NULL DEFAULT (]] .. NOW_US .. [[),
    updated_at      INTEGER NOT NULL DEFAULT (]] .. NOW_US .. [[)
);
CREATE INDEX lm_memories_scope_idx ON lm_memories (scope);
CREATE INDEX lm_memories_scope_kind_idx ON lm_memories (scope, kind);
CREATE INDEX lm_memories_kind_idx ON lm_memories (kind);
CREATE INDEX lm_memories_created_at_scope_idx ON lm_memories (scope, created_at DESC);
CREATE INDEX lm_memories_tier_scope_idx ON lm_memories (scope, tier);
CREATE INDEX lm_memories_consolidated_at_idx ON lm_memories (scope, consolidated_at) WHERE consolidated_at IS NULL;
CREATE INDEX lm_memories_was_truncated_idx ON lm_memories (was_truncated) WHERE was_truncated = 1;
CREATE UNIQUE INDEX lm_memories_org_replica_uq ON lm_memories (scope, json_extract(metadata, '$.lm_org_id'))
    WHERE json_extract(metadata, '$.lm_org_id') IS NOT NULL;

-- updated_at moves forward on every UPDATE that doesn't set it itself (never back:
-- the SQL clock is coarser than the µs times luamemo writes).
CREATE TRIGGER lm_memories_touch_updated_at AFTER UPDATE ON lm_memories
WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE lm_memories SET updated_at = max(]] .. NOW_US .. [[, OLD.updated_at + 1) WHERE id = NEW.id;
END;

-- The indexed text is lm_fts_doc(title, body) (luamemo.fts.doc_text, a Lua function every
-- luamemo connection registers): stopwords become a placeholder, as Postgres's tsvector
-- left them out. A connection without it can read the database but not write memories.
CREATE VIRTUAL TABLE lm_memories_fts USING fts5(doc, content = '', tokenize = 'porter unicode61');
CREATE TRIGGER lm_memories_fts_ai AFTER INSERT ON lm_memories BEGIN
    INSERT INTO lm_memories_fts (rowid, doc) VALUES (NEW.id, lm_fts_doc(NEW.title, NEW.body));
END;
CREATE TRIGGER lm_memories_fts_ad AFTER DELETE ON lm_memories BEGIN
    INSERT INTO lm_memories_fts (lm_memories_fts, rowid, doc) VALUES ('delete', OLD.id, lm_fts_doc(OLD.title, OLD.body));
END;
CREATE TRIGGER lm_memories_fts_au AFTER UPDATE OF title, body ON lm_memories BEGIN
    INSERT INTO lm_memories_fts (lm_memories_fts, rowid, doc) VALUES ('delete', OLD.id, lm_fts_doc(OLD.title, OLD.body));
    INSERT INTO lm_memories_fts (rowid, doc) VALUES (NEW.id, lm_fts_doc(NEW.title, NEW.body));
END;

CREATE TABLE lm_kg_facts (
    id               INTEGER PRIMARY KEY,
    scope            TEXT NOT NULL,
    subject          TEXT NOT NULL,
    predicate        TEXT NOT NULL,
    object           TEXT NOT NULL,
    valid_from       INTEGER NOT NULL,
    valid_until      INTEGER,
    source_memory_id INTEGER REFERENCES lm_memories (id) ON DELETE SET NULL,
    created_at       INTEGER NOT NULL,
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);
CREATE INDEX lm_kg_facts_scope_idx ON lm_kg_facts (scope);
CREATE INDEX lm_kg_facts_sp_idx ON lm_kg_facts (subject, predicate);
CREATE INDEX lm_kg_facts_current_idx ON lm_kg_facts (subject, predicate) WHERE valid_until IS NULL;

CREATE TABLE lm_observations (
    id              INTEGER PRIMARY KEY,
    scope           TEXT NOT NULL,
    body            TEXT NOT NULL,
    proof_count     INTEGER NOT NULL DEFAULT 1 CHECK (proof_count >= 1),
    evidence_ids    TEXT NOT NULL DEFAULT '[]',
    evidence_quotes TEXT NOT NULL DEFAULT '[]',
    freshness_trend TEXT NOT NULL DEFAULT 'new'
                    CHECK (freshness_trend IN ('new', 'strengthening', 'stable', 'weakening', 'stale')),
    last_reinforced INTEGER NOT NULL,
    created_at      INTEGER NOT NULL,
    importance      REAL NOT NULL DEFAULT 0.5 CHECK (importance >= 0 AND importance <= 10),
    embedding       BLOB,
    emb_norm        REAL
);
CREATE INDEX lm_observations_scope_idx ON lm_observations (scope);
CREATE INDEX lm_observations_reinforced_idx ON lm_observations (scope, last_reinforced DESC);

CREATE TABLE lm_reinforcements (
    id         INTEGER PRIMARY KEY,
    memory_id  INTEGER NOT NULL REFERENCES lm_memories (id) ON DELETE CASCADE,
    scope      TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('direct_command', 'mistake', 'reversal', 'praise', 'miss')),
    delta      REAL NOT NULL,
    note       TEXT,
    created_at INTEGER NOT NULL,
    source     TEXT,
    source_ref TEXT
);
CREATE INDEX lm_reinforcements_memory_idx ON lm_reinforcements (memory_id);
CREATE INDEX lm_reinforcements_scope_type_idx ON lm_reinforcements (scope, event_type);
CREATE UNIQUE INDEX lm_reinforcements_source_ref_uq ON lm_reinforcements (source, source_ref) WHERE source_ref IS NOT NULL;

CREATE TABLE lm_retrieval_feedback (
    id            INTEGER PRIMARY KEY,
    scope         TEXT NOT NULL,
    query         TEXT NOT NULL,
    candidate_ids TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    source        TEXT,
    source_ref    TEXT
);
CREATE INDEX lm_retrieval_feedback_scope_idx ON lm_retrieval_feedback (scope, created_at DESC);
CREATE UNIQUE INDEX lm_retrieval_feedback_source_ref_uq ON lm_retrieval_feedback (source, source_ref) WHERE source_ref IS NOT NULL;
-- Which retrievals a memory was a candidate in (Postgres used a GIN index on the array).
-- Filled from candidate_ids (a JSON array of ids, in rank order) by the trigger below, so
-- every writer just inserts the feedback row.
CREATE TABLE lm_retrieval_candidates (
    feedback_id INTEGER NOT NULL REFERENCES lm_retrieval_feedback (id) ON DELETE CASCADE,
    memory_id   INTEGER NOT NULL,
    rank        INTEGER NOT NULL,
    PRIMARY KEY (feedback_id, rank)
);
CREATE INDEX lm_retrieval_candidates_memory_idx ON lm_retrieval_candidates (memory_id);
CREATE TRIGGER lm_retrieval_feedback_candidates AFTER INSERT ON lm_retrieval_feedback BEGIN
    INSERT INTO lm_retrieval_candidates (feedback_id, memory_id, rank)
    SELECT NEW.id, CAST(value AS INTEGER), key + 1 FROM json_each(NEW.candidate_ids)
    WHERE json_valid(NEW.candidate_ids) AND CAST(value AS INTEGER) > 0;
END;

CREATE TABLE lm_digest_state (
    scope            TEXT PRIMARY KEY,
    last_digested_at INTEGER NOT NULL
);

CREATE TABLE lm_learner_weights (
    id         INTEGER PRIMARY KEY,
    scope      TEXT NOT NULL,
    kind       TEXT NOT NULL,
    version    INTEGER NOT NULL,
    weights    TEXT NOT NULL,
    score      REAL,
    note       TEXT,
    is_current INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    UNIQUE (scope, kind, version)
);
CREATE INDEX lm_learner_weights_current_idx ON lm_learner_weights (scope, kind, is_current);

CREATE TABLE lm_promotion_runs (
    id              INTEGER PRIMARY KEY,
    scope           TEXT NOT NULL,
    kind            TEXT NOT NULL,
    decision        TEXT NOT NULL,
    new_score       REAL,
    incumbent_score REAL,
    n_train         INTEGER,
    n_gate          INTEGER,
    version         INTEGER,
    note            TEXT,
    created_at      INTEGER NOT NULL
);
CREATE INDEX lm_promotion_runs_scope_idx ON lm_promotion_runs (scope, kind, created_at DESC);

CREATE TABLE lm_federation_state (
    org_scope                  TEXT PRIMARY KEY,
    instance_id                TEXT,
    last_pull_at               INTEGER,
    last_pull_ok               INTEGER,
    last_error                 TEXT,
    snapshot_cursor            TEXT,
    embedder_sig               TEXT,
    last_push_at               INTEGER,
    last_push_feedback_id      INTEGER NOT NULL DEFAULT 0,
    last_push_reinforcement_id INTEGER NOT NULL DEFAULT 0,
    updated_at                 INTEGER NOT NULL
);

CREATE TABLE lm_org_devs (
    id             INTEGER PRIMARY KEY,
    org_scope      TEXT NOT NULL,
    identity       TEXT NOT NULL,
    public_key     TEXT NOT NULL,
    fingerprint    TEXT NOT NULL,
    pairing_code   TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'removed')),
    requested_at   INTEGER NOT NULL,
    decided_at     INTEGER,
    decided_by     TEXT,
    last_seen_at   INTEGER,
    requested_from TEXT
);
CREATE UNIQUE INDEX lm_org_devs_key_uq ON lm_org_devs (org_scope, public_key);
CREATE INDEX lm_org_devs_identity_idx ON lm_org_devs (org_scope, identity, status);
CREATE INDEX lm_org_devs_pending_from_idx ON lm_org_devs (org_scope, requested_from) WHERE status = 'pending';

CREATE TABLE lm_org_sessions (
    id         TEXT PRIMARY KEY,
    dev_id     INTEGER NOT NULL REFERENCES lm_org_devs (id) ON DELETE CASCADE,
    keys       TEXT NOT NULL,
    recv_n     INTEGER NOT NULL DEFAULT 0,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX lm_org_sessions_expires_idx ON lm_org_sessions (expires_at);

CREATE TABLE lm_org_proposals (
    id           INTEGER PRIMARY KEY,
    org_scope    TEXT NOT NULL,
    project      TEXT,
    kind         TEXT NOT NULL,
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    embedding    BLOB,
    emb_norm     REAL,
    score        REAL NOT NULL DEFAULT 0,
    support      INTEGER NOT NULL DEFAULT 1,
    proposers    TEXT NOT NULL DEFAULT '[]',
    grounding    TEXT NOT NULL DEFAULT '[]',
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn')),
    update_of    INTEGER,
    memory_id    INTEGER,
    decided_by   TEXT,
    decided_at   INTEGER,
    reason       TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);
CREATE INDEX lm_org_proposals_hash_idx ON lm_org_proposals (org_scope, content_hash);
CREATE INDEX lm_org_proposals_status_idx ON lm_org_proposals (org_scope, status);

CREATE TABLE lm_org_proposed (
    memory_id     INTEGER NOT NULL REFERENCES lm_memories (id) ON DELETE CASCADE,
    org_scope     TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    status        TEXT NOT NULL
                  CHECK (status IN ('pending', 'approved', 'known', 'rejected', 'refused', 'withdrawing', 'withdrawn')),
    proposal_id   INTEGER,
    org_memory_id INTEGER,
    sent_at       INTEGER NOT NULL,
    checked_at    INTEGER,
    PRIMARY KEY (memory_id, org_scope)
);

]] .. SECRETS_TABLE },
-- The lazy summarizer's per-scope cursor (MEMO_SUMMARIZER_INTERVAL_SECONDS > 0).
{ name = "002_summarize_state", sql = [[
CREATE TABLE lm_summarize_state (
    scope              TEXT PRIMARY KEY,
    last_summarized_at INTEGER NOT NULL
);
]] },
-- A write's duplicate check reads the scope's newest candidates by updated_at: without this
-- index SQLite sorted every row of the scope first (28.5 → 7 ms at 5,000 memories).
{ name = "003_scope_updated_idx", sql = [[
CREATE INDEX lm_memories_scope_updated_idx ON lm_memories (scope, updated_at DESC);
]] },
-- The code map finds a file's rows by metadata.path (index ingest / update replace each
-- file's rows, index_outline, explore, diffs): without this index every lookup scanned
-- the scope — ingest grew with files × rows (47 s for 2,000 files), outline 59 ms at
-- 5,000. Only rows that have a path get an entry.
{ name = "004_path_idx", sql = [[
CREATE INDEX lm_memories_path_idx ON lm_memories (scope, json_extract(metadata, '$.path'))
    WHERE json_extract(metadata, '$.path') IS NOT NULL;
]] },
-- The org central finds a dev's proposal by (identity, ref) on every push — each status
-- check, withdrawal and proposal. Matched inside the proposers JSON, that read every
-- proposal per ref (20,000 proposals: 22 ms a ref, 1.1 s for a push's 50 checks, the
-- central serving one request at a time). This table mirrors proposers (triggers).
{ name = "005_proposal_refs", sql = [[
CREATE TABLE lm_org_proposal_refs (
    proposal_id INTEGER NOT NULL REFERENCES lm_org_proposals (id) ON DELETE CASCADE,
    identity    TEXT NOT NULL,
    ref         TEXT NOT NULL
);
CREATE INDEX lm_org_proposal_refs_idx ON lm_org_proposal_refs (identity, ref);
CREATE INDEX lm_org_proposal_refs_proposal_idx ON lm_org_proposal_refs (proposal_id);
CREATE TRIGGER lm_org_proposals_refs_ai AFTER INSERT ON lm_org_proposals BEGIN
    INSERT INTO lm_org_proposal_refs (proposal_id, identity, ref)
    SELECT NEW.id, json_extract(value, '$.identity'), json_extract(value, '$.ref') FROM json_each(NEW.proposers)
    WHERE json_extract(value, '$.identity') IS NOT NULL AND json_extract(value, '$.ref') IS NOT NULL;
END;
CREATE TRIGGER lm_org_proposals_refs_au AFTER UPDATE OF proposers ON lm_org_proposals BEGIN
    DELETE FROM lm_org_proposal_refs WHERE proposal_id = NEW.id;
    INSERT INTO lm_org_proposal_refs (proposal_id, identity, ref)
    SELECT NEW.id, json_extract(value, '$.identity'), json_extract(value, '$.ref') FROM json_each(NEW.proposers)
    WHERE json_extract(value, '$.identity') IS NOT NULL AND json_extract(value, '$.ref') IS NOT NULL;
END;
INSERT INTO lm_org_proposal_refs (proposal_id, identity, ref)
SELECT p.id, json_extract(e.value, '$.identity'), json_extract(e.value, '$.ref')
FROM lm_org_proposals p, json_each(p.proposers) e
WHERE json_extract(e.value, '$.identity') IS NOT NULL AND json_extract(e.value, '$.ref') IS NOT NULL;
]] },
-- A memory's "Preference: …" companions (luamemo.patterns: metadata is_synthetic, source_id)
-- go with it on a delete or new text: found here, not by reading the scope — a code map's
-- per-file replace deletes through the same path.
{ name = "006_synthetic_idx", sql = [[
CREATE INDEX lm_memories_synthetic_idx ON lm_memories (scope, json_extract(metadata, '$.source_id'))
    WHERE json_extract(metadata, '$.is_synthetic') = 1;
]] },
}

-- A secrets store file of its own (luamemo.secrets.open).
M.SECRETS_MIGRATIONS = {
    { name = "001_secrets", sql = SECRETS_TABLE },
}

return M
