-- luamemo.learner_store  (Phase 11 — per-scope learner weights, DB-backed)
--
-- The learned reranker/projection are promoted PER SCOPE and their versioned
-- weights live in the database (lm_learner_weights) rather than a single global
-- file. This is the federation seam: an org's weights sync down through the
-- same backing.
--
-- One row per (scope, kind, version); exactly one per (scope, kind) has
-- is_current = 1 (the active model). promote()/rollback() flip that flag
-- atomically. lm_promotion_runs records every promote attempt for observability.

local db   = require("luamemo.db")
local util = require("luamemo.util")

local M = {}

-- The weights column comes back decoded; tolerate a JSON string too.
local function decode_weights(v)
    if type(v) == "table" then return v end
    if type(v) == "string" then
        local ok, t = pcall(require("luamemo.json").decode, v)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

--- Save a NEW version for (scope, kind). Not made current — call promote().
-- @return version (int) or nil, err
function M.save_version(scope, kind, weights, meta)
    if not scope or scope == "" or not kind or kind == "" then
        return nil, "save_version: scope and kind required"
    end
    local version
    local ok, err = db.transaction(function(h)
        version = (tonumber(h.value("SELECT COALESCE(max(version), 0) FROM lm_learner_weights "
            .. "WHERE scope = ? AND kind = ?", scope, kind)) or 0) + 1
        local n, ierr = h.run("INSERT INTO lm_learner_weights (scope, kind, version, weights, score, note, created_at) "
            .. "VALUES (?, ?, ?, ?, ?, ?, ?)", scope, kind, version, db.json(weights or {}),
            meta and tonumber(meta.score) or nil, meta and meta.note or nil, util.now_us())
        if not n then error(ierr, 0) end
    end)
    if not ok then return nil, err end
    return version
end

--- Make a version current (clears is_current on the rest for this scope+kind).
function M.promote(scope, kind, version)
    local v = math.floor(tonumber(version) or 0)
    if not db.value("SELECT 1 FROM lm_learner_weights WHERE scope = ? AND kind = ? AND version = ?",
            scope, kind, v) then
        return nil, "promote: no such version " .. v
    end
    local ok, err = db.transaction(function(h)
        assert(h.run("UPDATE lm_learner_weights SET is_current = 0 WHERE scope = ? AND kind = ?", scope, kind))
        assert(h.run("UPDATE lm_learner_weights SET is_current = 1 WHERE scope = ? AND kind = ? AND version = ?",
            scope, kind, v))
    end)
    if not ok then return nil, "promote: " .. tostring(err) end
    return true
end

--- Clear the current version for (scope, kind) — no weights apply until a
--- version is promoted again (e.g. the org central withdrew its model).
function M.deactivate(scope, kind)
    local n, err = db.run("UPDATE lm_learner_weights SET is_current = 0 WHERE scope = ? AND kind = ?", scope, kind)
    if not n then return nil, err end
    return true
end

--- Current version's note for (scope, kind), or nil (federation: "org:v<N>").
function M.current_note(scope, kind)
    return (db.value("SELECT note FROM lm_learner_weights WHERE scope = ? AND kind = ? AND is_current = 1 LIMIT 1",
        scope, kind))
end

--- Weights of the current version for (scope, kind), or nil.
function M.load_current(scope, kind)
    if not scope or scope == "" then return nil end
    local row = db.first("SELECT weights FROM lm_learner_weights WHERE scope = ? AND kind = ? AND is_current = 1 "
        .. "LIMIT 1", scope, kind)
    if row then return decode_weights(row.weights) end
    return nil
end

--- Current version number for (scope, kind), or nil.
function M.current_version(scope, kind)
    return tonumber((db.value("SELECT version FROM lm_learner_weights WHERE scope = ? AND kind = ? "
        .. "AND is_current = 1 LIMIT 1", scope, kind)))
end

--- Roll back to the highest version below the current one (recorded in
--- lm_promotion_runs). Returns the new current version, or nil if there is nothing
--- to roll back to.
function M.rollback(scope, kind)
    local cur = M.current_version(scope, kind)
    if not cur then return nil, "rollback: no current version" end
    local pv = tonumber((db.value("SELECT max(version) FROM lm_learner_weights WHERE scope = ? AND kind = ? "
        .. "AND version < ?", scope, kind, math.floor(cur))))
    if not pv then return nil, "rollback: no earlier version" end
    M.promote(scope, kind, pv)
    M.record_run(scope, kind, "rollback", { version = pv, note = ("rolled back from v%d"):format(cur) })
    return pv
end

--- (scope, kind)'s model versions (newest first) and its last `n` promotion runs →
--- { current = version | nil, versions = { … }, runs = { … } }.
function M.status(scope, kind, n)
    local iso = util.us_to_iso
    local versions = db.query("SELECT version, score, note, is_current, created_at FROM lm_learner_weights "
        .. "WHERE scope = ? AND kind = ? ORDER BY version DESC", scope, kind) or {}
    for _, v in ipairs(versions) do v.is_current = v.is_current == 1; v.created_at = iso(v.created_at) end
    local runs = db.query("SELECT decision, new_score, incumbent_score, n_train, n_gate, version, note, created_at "
        .. "FROM lm_promotion_runs WHERE scope = ? AND kind = ? ORDER BY created_at DESC, id DESC LIMIT ?",
        scope, kind, math.floor(tonumber(n) or 10)) or {}
    for _, r in ipairs(runs) do r.created_at = iso(r.created_at) end
    return { current = M.current_version(scope, kind), versions = versions, runs = runs }
end

--- Append an audit row for a promotion attempt.
function M.record_run(scope, kind, decision, meta)
    meta = meta or {}
    local function int(x) return tonumber(x) and math.floor(tonumber(x)) or nil end
    pcall(db.run, "INSERT INTO lm_promotion_runs (scope, kind, decision, new_score, incumbent_score, n_train, "
        .. "n_gate, version, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        scope, kind, decision, tonumber(meta.new_score), tonumber(meta.incumbent_score),
        int(meta.n_train), int(meta.n_gate), int(meta.version), meta.note, util.now_us())
end

return M
