-- luamemo.summarizer
--
-- Orchestrator: selects candidate memories, dispatches them to the
-- configured summarizer adapter, and replaces the originals with one
-- summary row per batch. Used by:
--   * the background ngx.timer.every job (init.lua)
--   * the manual POST /api/memory/summarize endpoint (routes.lua)
--   * the `memo summarize` CLI

local store = require("luamemo.store")
local db    = require("luamemo.db")

local M = {}

local cfg             = nil
local _adapter_cache  = {}   -- [name] -> module; avoids repeated pcall+validation

function M.configure(config)
    cfg = config
end

-- Load a summarizer adapter by name, caching the result.
local function load_adapter(name)
    name = name or "noop"
    if _adapter_cache[name] then return _adapter_cache[name] end
    local ok, mod = pcall(require, "luamemo.summarizers." .. name)
    if not ok then
        return nil, "summarizer: adapter not found: " .. name
            .. " (" .. tostring(mod) .. ")"
    end
    if type(mod.summarize) ~= "function" then
        return nil, "summarizer: adapter '" .. name .. "' missing summarize()"
    end
    _adapter_cache[name] = mod
    return mod
end

--- Run one summarisation cycle.
-- @param opts table  optional: scope, dry_run, weight_threshold, retention_days,
--                   batch_size, max_batches
-- @return table  { batches = N, summarised = N, replaced_ids = {...}, errors = {...} }
function M.run(opts)
    opts = opts or {}
    if not cfg then
        return { batches = 0, summarised = 0, replaced_ids = {},
                 errors = { "summarizer: not configured" } }
    end

    local adapter, aerr = load_adapter(cfg.summarizer_adapter)
    if not adapter then
        return { batches = 0, summarised = 0, replaced_ids = {},
                 errors = { aerr } }
    end

    local batches = store.select_for_summarization({
        scope            = opts.scope,
        weight_threshold = opts.weight_threshold,
        retention_days   = opts.retention_days,
        batch_size       = opts.batch_size,
        max_batches      = opts.max_batches,
    })

    local result = {
        batches      = #batches,
        summarised   = 0,
        replaced_ids = {},
        new_ids      = {},
        errors       = {},
    }

    for _, batch in ipairs(batches) do
        local sum, serr = adapter.summarize(batch.memories, cfg)
        if not sum then
            table.insert(result.errors, "scope=" .. batch.scope .. ": " .. tostring(serr))
        else
            local ids = {}
            for _, m in ipairs(batch.memories) do
                ids[#ids + 1] = m.id
            end
            sum.scope = batch.scope

            if opts.dry_run then
                -- Don't mutate; just count what would have happened.
                result.summarised = result.summarised + 1
                for _, id in ipairs(ids) do
                    table.insert(result.replaced_ids, id)
                end
            else
                local row, rerr = store.replace_with_summary(ids, sum)
                if not row then
                    table.insert(result.errors,
                        "scope=" .. batch.scope .. ": " .. tostring(rerr))
                else
                    result.summarised = result.summarised + 1
                    table.insert(result.new_ids, row.id)
                    for _, id in ipairs(ids) do
                        table.insert(result.replaced_ids, id)
                    end
                end
            end
        end
    end

    return result
end

-- ---------------------------------------------------------------------------
-- promote
-- Roll all (non-summary) rows from `from_scope` into a single summary row in
-- `to_scope`. Used to bridge session continuity: write hot working memory to
-- `session:<uuid>`, then promote into `user:<id>:long_term` at session end so
-- the next session can find it.
--
-- Required: opts.from_scope, opts.to_scope.
-- Optional:
--   delete_source (bool, default false) — hard-delete source rows after
--                                         the summary is written, in the
--                                         same transaction.
--   dry_run       (bool, default false) — no DB writes; report what would
--                                         have happened.
--   limit         (int,  default 200)   — cap source rows pulled.
--   min_rows      (int,  default 1)     — bail with reason="no_rows" if
--                                         fewer than this in source.
--
-- Returns: { promoted = 0|1, summary_id, source_ids, dry_run,
--            deleted_source, reason, errors }
-- ---------------------------------------------------------------------------
function M.promote(opts)
    opts = opts or {}
    if not cfg then
        return { promoted = 0, errors = { "promote: not configured" } }
    end
    if not opts.from_scope or opts.from_scope == "" then
        return { promoted = 0, errors = { "promote: from_scope required" } }
    end
    if not opts.to_scope or opts.to_scope == "" then
        return { promoted = 0, errors = { "promote: to_scope required" } }
    end
    if opts.from_scope == opts.to_scope then
        return { promoted = 0, errors = { "promote: from_scope == to_scope" } }
    end

    local adapter, aerr = load_adapter(cfg and cfg.summarizer_adapter)
    if not adapter then
        return { promoted = 0, errors = { aerr } }
    end

    local rows, lerr = store.list_by_scope(opts.from_scope, {
        limit = opts.limit or 200,
    })
    if not rows then
        return { promoted = 0, errors = { tostring(lerr) } }
    end

    local min_rows = tonumber(opts.min_rows) or 1
    if #rows < min_rows then
        return { promoted = 0, source_ids = {}, reason = "no_rows" }
    end

    local source_ids = {}
    for _, r in ipairs(rows) do source_ids[#source_ids + 1] = r.id end

    local sum, serr = adapter.summarize(rows, cfg)
    if not sum then
        return { promoted = 0, source_ids = source_ids,
                 errors = { tostring(serr) } }
    end

    -- Stamp provenance so the next session can audit where this came from.
    local meta = sum.metadata or {}
    meta.promoted_from = opts.from_scope
    meta.source_ids    = source_ids

    local title = sum.title or ("Promoted from " .. opts.from_scope)
    if title:sub(1, 11) ~= "[promoted] " then
        title = "[promoted] " .. title
    end

    if opts.dry_run then
        return {
            promoted       = 1,
            source_ids     = source_ids,
            dry_run        = true,
            deleted_source = false,
        }
    end

    local insert_args = {
        scope          = opts.to_scope,
        kind           = "summary",
        title          = title,
        body           = sum.body,
        tags           = sum.tags,
        metadata       = meta,
        importance     = sum.importance or 1.0,
        decay_rate     = sum.decay_rate or 0.0,
        -- Promoted summaries are first-class; never let dedup collapse them.
        dedup_strategy = "append",
    }

    db.query("BEGIN")
    local row, werr = store.write(insert_args)
    if not row then
        db.query("ROLLBACK")
        return { promoted = 0, source_ids = source_ids,
                 errors = { "promote: insert failed: " .. tostring(werr) } }
    end

    local deleted = false
    if opts.delete_source then
        local id_list = {}
        for _, id in ipairs(source_ids) do
            local n = tonumber(id)
            if n then id_list[#id_list + 1] = tostring(n) end
        end
        if #id_list > 0 then
            local del_sql = "DELETE FROM " .. store.table_name()
                .. " WHERE id IN (" .. table.concat(id_list, ",") .. ")"
            local _, derr = db.query(del_sql)
            if derr then
                db.query("ROLLBACK")
                return { promoted = 0, source_ids = source_ids,
                         errors = { "promote: delete failed: " .. tostring(derr) } }
            end
            deleted = true
        end
    end

    db.query("COMMIT")

    return {
        promoted       = 1,
        summary_id     = row.id,
        source_ids     = source_ids,
        dry_run        = false,
        deleted_source = deleted,
    }
end

-- ---------------------------------------------------------------------------
-- consolidate
-- Three-phase maintenance run:
--   Phase 1 — Expire decayed: memories whose effective importance has fallen
--              below decay_threshold get importance = 0; they stop appearing
--              in search results without being hard-deleted.
--   Phase 2 — Cluster near-duplicates: fetch up to max_rows memories,
--              pairwise cosine comparison, union-find grouping. Returns the
--              cluster report even on dry_run (read-only diagnosis).
--   Phase 3 — Merge clusters: if summarizer adapter ≠ "noop" and dry_run is
--              false, call adapter.summarize() per cluster, write the merged
--              memory, delete the originals via replace_with_summary().
--
-- @param opts table  scope, dry_run, similarity_threshold, decay_threshold,
--                    max_rows
-- @return table  { expired={ids}, clusters=[{ids,titles}],
--                  merged={old_ids}, new_ids={new_ids}, errors={...} }
-- ---------------------------------------------------------------------------
function M.consolidate(opts)
    opts = opts or {}
    if not cfg then
        return { expired = {}, clusters = {}, merged = {}, new_ids = {},
                 errors = { "consolidate: not configured" } }
    end

    local dry_run = opts.dry_run and true or false
    local result  = { expired = {}, clusters = {}, merged = {}, new_ids = {}, errors = {} }

    -- Phase 1: expire decayed memories.
    local expired, eerr = store.find_decayed({
        scope           = opts.scope,
        decay_threshold = opts.decay_threshold,
        max_rows        = opts.max_rows,
        apply           = not dry_run,
    })
    if not expired then
        table.insert(result.errors, "phase1: " .. tostring(eerr))
    else
        result.expired = expired
    end

    -- Phase 2: find near-duplicate clusters.
    local clusters, cerr = store.find_clusters({
        scope                = opts.scope,
        similarity_threshold = opts.similarity_threshold,
        max_rows             = opts.max_rows,
    })
    if not clusters then
        table.insert(result.errors, "phase2: " .. tostring(cerr))
        return result
    end

    for _, c in ipairs(clusters) do
        table.insert(result.clusters, { ids = c.ids, titles = c.titles })
    end

    -- Phase 3: merge clusters via adapter (skip when noop or dry_run).
    local adapter_name = cfg.summarizer_adapter or "noop"
    if not dry_run and adapter_name ~= "noop" then
        local adapter, aerr = load_adapter(adapter_name)
        if not adapter then
            table.insert(result.errors, "phase3: " .. tostring(aerr))
            return result
        end

        for _, c in ipairs(clusters) do
            local sum, serr = adapter.summarize(c.members, cfg)
            if not sum then
                table.insert(result.errors,
                    "merge [" .. table.concat(c.ids, ",") .. "]: " .. tostring(serr))
            else
                sum.scope = c.members[1].scope
                local row, rerr = store.replace_with_summary(c.ids, sum)
                if not row then
                    table.insert(result.errors,
                        "replace [" .. table.concat(c.ids, ",") .. "]: " .. tostring(rerr))
                else
                    table.insert(result.new_ids, row.id)
                    for _, id in ipairs(c.ids) do
                        table.insert(result.merged, id)
                    end
                end
            end
        end
    end

    return result
end

return M
