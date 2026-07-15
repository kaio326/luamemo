-- Migration 012: persisted per-scope digest cursor (lazy auto-trigger)
--
-- luamemo is stateless — each CLI invocation is a fresh process, so the in-memory
-- idle timer (digest.notify_write/should_run) can't debounce across runs. This
-- table persists the last time each scope was digested so digest.maybe_run() can
-- piggyback a debounced maintenance pass on ordinary writes: the digest then runs
-- without depending on any external trigger (agent or scheduler) remembering to.
--
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS lm_digest_state (
    scope            TEXT PRIMARY KEY,
    last_digested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
