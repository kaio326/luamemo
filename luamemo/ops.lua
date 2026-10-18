-- luamemo/ops.lua — the operations `memo` (luamemo.cli.api) and the MCP server
-- (mcp/server.lua) both offer, in one place: each reads its arguments as either
-- surface sends them — text from memo's flags ("on", "0.5", '{"k":"v"}', "a,b") or
-- typed values from MCP — and calls the module that does the work. A surface keeps
-- only what is its own: its default scope, its defaults, the shape of its answer.
-- (The two used to map every argument separately; eval/tests/test_parity.lua checks
-- that every argument is reachable from both.)

local json = require("luamemo.json")
local util = require("luamemo.util")

local M = {}

local to_bool = util.to_bool

-- ── Arguments ────────────────────────────────────────────────────────────────

--- A JSON object (a table, or its text) → table | nil (absent), err.
function M.json_arg(v, name)
    if v == nil or type(v) == "table" then return v end
    local t = json.decode(tostring(v))
    if type(t) ~= "table" or t[1] ~= nil then
        return nil, ("%s (--%s) must be a JSON object, e.g. '{\"source\":\"x\"}'"):format(name,
            (name:gsub("_", "-")))
    end
    return t
end

--- On / off (a boolean, or true false 1 0 on off yes no) → boolean | nil (absent), err.
function M.bool_arg(v, name)
    if v == nil or type(v) == "boolean" then return v end
    local s = tostring(v):lower()
    if s == "1" or s == "true" or s == "on" or s == "yes" then return true end
    if s == "0" or s == "false" or s == "off" or s == "no" then return false end
    return nil, ("%s (--%s) is on or off, not %q"):format(name, (name:gsub("_", "-")), tostring(v))
end

--- Per-call search weights { vector = …, fts = … }, checked like MEMO_HYBRID_WEIGHTS.
function M.weights_arg(v)
    local t, err = M.json_arg(v, "hybrid_weights")
    if not t then return nil, err end
    local settings = require("luamemo.settings")
    return settings.parse(settings.get("hybrid_weights"), json.encode(t))
end

--- A set of scopes: a list, or "a,b" text → list | nil (none given).
function M.scope_list(v)
    if type(v) == "string" then
        local names = {}
        for s in v:gmatch("[^,%s]+") do names[#names + 1] = s end
        v = names
    end
    return (type(v) == "table" and #v > 0) and v or nil
end

local function str(v) return (type(v) == "string" and v ~= "") and v or nil end

-- ── Memories ─────────────────────────────────────────────────────────────────

--- Search, and the facts its query is about → rows, facts | nil, err.
--- d: the surface's defaults { scope (searched when the call names none), tier_min }.
function M.search(p, d)
    d = d or {}
    local mf, err = M.json_arg(p.metadata_filter, "metadata_filter")
    if err then return nil, err end
    local hw
    if p.hybrid_weights ~= nil then
        hw, err = M.weights_arg(p.hybrid_weights)
        if not hw then return nil, err end
    end
    local rr
    rr, err = M.bool_arg(p.rerank, "rerank")
    if err then return nil, err end
    local scopes = M.scope_list(p.scopes)
    local scope = str(p.scope) or d.scope
    local query = p.query or p.q
    local rows, serr = require("luamemo.store").search({
        query           = query,
        scope           = scope,
        scopes          = scopes,
        kind            = p.kind,
        limit           = tonumber(p.limit),
        min_score       = tonumber(p.min_score),
        metadata_filter = mf,
        hybrid_weights  = hw,
        rerank          = rr,
        project         = str(p.project),
        since           = p.since,
        ["until"]       = p["until"],
        tier_min        = tonumber(p.tier_min) or d.tier_min,
        tier_max        = tonumber(p.tier_max),
        ignore_decay    = to_bool(p.ignore_decay),
    })
    if not rows then return nil, serr end
    return rows, require("luamemo.kg").for_query(scopes or scope, tostring(query or ""))
end

--- The newest memories → rows | nil, err (d.scope when the call names none).
function M.recent(p, d)
    return require("luamemo.store").recent({
        scope    = str(p.scope) or (d and d.scope),
        limit    = tonumber(p.limit),
        kind     = p.kind,
        offset   = tonumber(p.offset),
        tier_min = tonumber(p.tier_min) or (d and d.tier_min),
    })
end

--- A memory to write, as a surface received it → store.write's arguments | nil, err
--- (metadata an object or its JSON text). scope: the scope the surface chose for it.
function M.write_fields(p, scope)
    local meta, err = M.json_arg(p.metadata, "metadata")
    if err then return nil, err end
    return {
        scope          = scope,
        kind           = p.kind,
        title          = p.title,
        body           = p.body,
        tags           = p.tags,
        metadata       = meta,
        importance     = tonumber(p.importance),
        decay_rate     = tonumber(p.decay_rate),
        tier           = tonumber(p.tier),        -- 0–3 (else derived from importance)
        created_at     = p.created_at,            -- a backdated memory: ISO 8601 or epoch seconds
        dedup_strategy = p.dedup_strategy,
    }
end

--- Change a memory's fields → row | nil, err (a new scope moves it, policy-checked).
function M.update(id, p)
    local meta, err = M.json_arg(p.metadata, "metadata")
    if err then return nil, err end
    return require("luamemo.store").update(tonumber(id), {
        title      = p.title,
        body       = p.body,
        tags       = p.tags,
        metadata   = meta,
        importance = tonumber(p.importance),
        decay_rate = tonumber(p.decay_rate),
        kind       = p.kind,
        scope      = p.scope,
    })
end

--- What the embedder makes of a text (and how similar a second one is) → report | nil, err.
function M.embed(p)
    if type(p.text) ~= "string" or p.text == "" then return nil, "embed: a text is required" end
    return require("luamemo.embed").inspect(p.text, { compare_to = p.compare_to,
        vector = to_bool(p.vector or p.include_vector) == true })
end

-- ── Maintenance ──────────────────────────────────────────────────────────────

--- Fold a session scope into one summary in a long-term scope → { ok, result } | nil, err.
function M.promote(p)
    local result, err = require("luamemo.summarizer").promote({
        from_scope    = p.from_scope,
        to_scope      = p.to_scope,
        delete_source = to_bool(p.delete_source),
        dry_run       = to_bool(p.dry_run),
        limit         = tonumber(p.limit),
        min_rows      = tonumber(p.min_rows),
    })
    if not result then return nil, err end
    return { ok = (result.promoted == 1 or result.reason == "no_rows"), result = result }
end

--- Fold old, low-weight memories into summaries — of `scope`, or (nil) of every scope —
--- → { ok, result } | nil, err.
function M.summarize(p, scope)
    local result, err = require("luamemo.summarizer").run({
        scope            = str(scope),
        dry_run          = to_bool(p.dry_run),
        weight_threshold = tonumber(p.weight_threshold),
        retention_days   = tonumber(p.retention_days),
        batch_size       = tonumber(p.batch_size),
        max_batches      = tonumber(p.max_batches),
    })
    if not result then return nil, err end
    return { ok = #(result.errors or {}) == 0, result = result }
end

--- Expire decayed memories, group near-duplicates → { ok, result } | nil, err.
function M.consolidate(p)
    local result, err = require("luamemo.summarizer").consolidate({
        scope                = str(p.scope),
        dry_run              = to_bool(p.dry_run),
        similarity_threshold = tonumber(p.similarity_threshold),
        decay_threshold      = tonumber(p.decay_threshold),
        max_rows             = tonumber(p.max_rows),
    })
    if not result then return nil, err end
    return { ok = true, result = result }
end

--- Group ephemeral memories, promote proven ones in `scope` → { ok, result } | nil, err.
function M.digest(p, scope)
    if not str(scope) then return nil, "digest: scope required" end
    return { ok = true, result = require("luamemo.digest").run(scope, {
        dry_run   = to_bool(p.dry_run),
        threshold = tonumber(p.threshold),
    }) }
end

-- ── Learning from use ────────────────────────────────────────────────────────

--- Record the corrections / rules / praise in relayed turns → { ok, result } | nil, err.
function M.sense(p, scope)
    if not str(scope) then return nil, "sense: scope required" end
    if type(p.turns) ~= "table" then return nil, "sense: turns array required" end
    return { ok = true, result = require("luamemo.sensing").process(scope, p.turns, {
        generative     = to_bool(p.generative) == true,
        min_confidence = tonumber(p.min_confidence),
        min_similarity = tonumber(p.min_similarity),
        delta_scale    = tonumber(p.delta_scale),
    }) }
end

--- The scope's learned reranker: run (train; promoted only if better) / status /
--- rollback → the answer | nil, err.
function M.learn(p, scope)
    if not str(scope) then return nil, "learn: scope required" end
    local ls = require("luamemo.learner_store")
    local action = p.action or "run"
    if action == "status" then
        return { ok = true, scope = scope, kind = "reranker", status = ls.status(scope, "reranker") }
    elseif action == "rollback" then
        local was = ls.current_version(scope, "reranker")
        local v, err = ls.rollback(scope, "reranker")
        if not v then return nil, err end
        return { ok = true, scope = scope, kind = "reranker", current = v, previous = was }
    elseif action ~= "run" then
        return nil, "learn: action is run, status or rollback"
    end
    return { ok = true, result = require("luamemo.promote").run(scope, {
        min_samples = tonumber(p.min_samples),
        margin      = tonumber(p.margin),
        gate_frac   = tonumber(p.gate_frac),
        epochs      = tonumber(p.epochs),
        dry_run     = to_bool(p.dry_run) == true,
    }) }
end

--- Which hybrid_weights blend finds `scope`'s memories best → report | nil, err.
function M.tune_weights(p, scope)
    return require("luamemo.tune_weights").recommend({ scope = scope, samples = p.samples,
        metric = p.metric, in_force = require("luamemo").config.hybrid_weights })
end

return M
