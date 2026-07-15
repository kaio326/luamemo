-- luamemo.learner_store  (Phase 11 — per-scope learner weights, DB-backed)
--
-- The learned reranker/projection are promoted PER SCOPE and their versioned
-- weights live in Postgres (lm_learner_weights, migration 013) rather than a
-- single global file. This fits the stateless / multi-instance model and is the
-- federation seam: Phase 12 syncs an org's weights down through the same backing.
--
-- One row per (scope, kind, version); exactly one per (scope, kind) has
-- is_current = true (the active model). promote()/rollback() flip that flag
-- atomically. lm_promotion_runs records every promote attempt for observability.

local db = require("luamemo.db")

local ok_cjson, cjson = pcall(require, "cjson")
if not ok_cjson then cjson = require("luamemo.json") end

local M = {}

local function tbl_exists(name)
    local ok, util = pcall(require, "luamemo.util")
    if ok and util.table_exists then return util.table_exists(name) end
    return true
end

-- Decode a weights column that pgmoon may hand back as a Lua table or a string.
local function decode_weights(v)
    if type(v) == "table" then return v end
    if type(v) == "string" then
        local ok, t = pcall(cjson.decode, v)
        if ok then return t end
    end
    return nil
end

--- Save a NEW version for (scope, kind). Not made current — call promote().
-- @return version (int) or nil, err
function M.save_version(scope, kind, weights, meta)
    if not scope or scope == "" or not kind or kind == "" then
        return nil, "save_version: scope and kind required"
    end
    if not tbl_exists("lm_learner_weights") then return nil, "lm_learner_weights missing (run migrate)" end
    local mrow = db.query("SELECT COALESCE(max(version), 0) AS v FROM lm_learner_weights WHERE scope = "
        .. db.escape_literal(scope) .. " AND kind = " .. db.escape_literal(kind))
    local version = (mrow and mrow[1] and tonumber(mrow[1].v) or 0) + 1
    local wjson = cjson.encode(weights or {})
    local score = meta and tonumber(meta.score)
    local note  = meta and meta.note
    local sql = "INSERT INTO lm_learner_weights (scope, kind, version, weights, score, note) VALUES ("
        .. db.escape_literal(scope) .. ", " .. db.escape_literal(kind) .. ", " .. version .. ", "
        .. db.escape_literal(wjson) .. "::jsonb, "
        .. (score and string.format("%.6f", score) or "NULL") .. ", "
        .. (note and db.escape_literal(note) or "NULL") .. ")"
    local ok, err = pcall(db.query, sql)
    if not ok then return nil, err end
    return version
end

--- Make a version current (clears is_current on the rest for this scope+kind).
function M.promote(scope, kind, version)
    if not tbl_exists("lm_learner_weights") then return nil, "lm_learner_weights missing" end
    local v = math.floor(tonumber(version) or 0)
    local exists = db.query("SELECT 1 FROM lm_learner_weights WHERE scope = " .. db.escape_literal(scope)
        .. " AND kind = " .. db.escape_literal(kind) .. " AND version = " .. v .. " LIMIT 1")
    if not (exists and exists[1]) then return nil, "promote: no such version " .. v end
    db.query("UPDATE lm_learner_weights SET is_current = false WHERE scope = " .. db.escape_literal(scope)
        .. " AND kind = " .. db.escape_literal(kind))
    db.query("UPDATE lm_learner_weights SET is_current = true WHERE scope = " .. db.escape_literal(scope)
        .. " AND kind = " .. db.escape_literal(kind) .. " AND version = " .. v)
    return true
end

--- Weights of the current version for (scope, kind), or nil.
function M.load_current(scope, kind)
    if not scope or scope == "" or not tbl_exists("lm_learner_weights") then return nil end
    local rows = db.query("SELECT weights FROM lm_learner_weights WHERE scope = " .. db.escape_literal(scope)
        .. " AND kind = " .. db.escape_literal(kind) .. " AND is_current = true LIMIT 1")
    if rows and rows[1] then return decode_weights(rows[1].weights) end
    return nil
end

--- Current version number for (scope, kind), or nil.
function M.current_version(scope, kind)
    local rows = db.query("SELECT version FROM lm_learner_weights WHERE scope = " .. db.escape_literal(scope)
        .. " AND kind = " .. db.escape_literal(kind) .. " AND is_current = true LIMIT 1")
    return rows and rows[1] and tonumber(rows[1].version) or nil
end

--- Roll back to the highest version below the current one. Returns the new
--- current version, or nil if there is nothing to roll back to.
function M.rollback(scope, kind)
    local cur = M.current_version(scope, kind)
    if not cur then return nil, "rollback: no current version" end
    local prev = db.query("SELECT max(version) AS v FROM lm_learner_weights WHERE scope = "
        .. db.escape_literal(scope) .. " AND kind = " .. db.escape_literal(kind)
        .. " AND version < " .. math.floor(cur))
    local pv = prev and prev[1] and tonumber(prev[1].v)
    if not pv then return nil, "rollback: no earlier version" end
    M.promote(scope, kind, pv)
    return pv
end

--- Append an audit row for a promotion attempt.
function M.record_run(scope, kind, decision, meta)
    if not tbl_exists("lm_promotion_runs") then return end
    meta = meta or {}
    local function num(x) return x and string.format("%.6f", tonumber(x)) or "NULL" end
    local function int(x) return x and tostring(math.floor(tonumber(x))) or "NULL" end
    local sql = "INSERT INTO lm_promotion_runs "
        .. "(scope, kind, decision, new_score, incumbent_score, n_train, n_gate, version, note) VALUES ("
        .. db.escape_literal(scope) .. ", " .. db.escape_literal(kind) .. ", " .. db.escape_literal(decision) .. ", "
        .. num(meta.new_score) .. ", " .. num(meta.incumbent_score) .. ", "
        .. int(meta.n_train) .. ", " .. int(meta.n_gate) .. ", " .. int(meta.version) .. ", "
        .. (meta.note and db.escape_literal(meta.note) or "NULL") .. ")"
    pcall(db.query, sql)
end

return M
