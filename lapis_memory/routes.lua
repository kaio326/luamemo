-- lapis_memory.routes
-- Lapis route factory. Call routes.register(app, { prefix = "/api/memory" }).

local cjson = require("cjson.safe")

local M = {}

local function json(status, body)
    return { status = status, json = body }
end

local function decode_body(self)
    if self.params and next(self.params) then return self.params end
    if self.req and self.req.params_post then return self.req.params_post end
    return {}
end

local function get_cfg()
    -- Lazy require to avoid circular dependency at module load.
    return require("lapis_memory").config
end

local function authorise(self)
    local cfg = get_cfg()
    if cfg.before_request then
        local ok, err = cfg.before_request(self)
        if not ok then
            return json(err and err.status or 403,
                        { error = err and err.message or "forbidden" })
        end
    end
    if not cfg.auth_fn(self) then
        return json(403, { error = "forbidden" })
    end
    return nil
end

--- Register all memory routes on a Lapis app.
-- @param app  Lapis Application instance
-- @param opts table  { prefix = "/api/memory" }
function M.register(app, opts)
    opts = opts or {}
    local prefix = opts.prefix or "/api/memory"
    local store  = require("lapis_memory.store")

    -- POST /write
    app:post(prefix .. "/write", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local row, err, action = store.write({
            scope          = p.scope,
            kind           = p.kind,
            title          = p.title,
            body           = p.body,
            tags           = p.tags,
            metadata       = p.metadata,
            importance     = p.importance,
            decay_rate     = p.decay_rate,
            dedup_strategy = p.dedup_strategy,
        })
        if not row then return json(400, { error = err }) end
        return json(200, { ok = true, memory = row, action = action or "inserted" })
    end)

    -- GET /search
    app:get(prefix .. "/search", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = self.params
        if not p.q or p.q == "" then
            return json(400, { error = "q is required" })
        end
        local rows, err = store.search({
            query        = p.q,
            scope        = p.scope,
            kind         = p.kind,
            limit        = tonumber(p.limit),
            ignore_decay = p.ignore_decay == "1" or p.ignore_decay == "true",
            -- Phase 11: temporal bounds. `until` is a Lua reserved word so
            -- we read the HTTP param as bracket syntax and pass on as
            -- `until_` to the store layer.
            since        = p.since,
            until_       = p["until"],
        })
        if not rows then return json(400, { error = err }) end
        return json(200, { ok = true, results = rows })
    end)

    -- GET /recent
    app:get(prefix .. "/recent", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = self.params
        local rows = store.recent({
            scope = p.scope,
            limit = tonumber(p.limit),
        })
        return json(200, { ok = true, results = rows })
    end)

    -- GET /:id
    app:get(prefix .. "/:id", function(self)
        local denied = authorise(self); if denied then return denied end
        local row = store.get(self.params.id)
        if not row then return json(404, { error = "not found" }) end
        return json(200, { ok = true, memory = row })
    end)

    -- POST /:id/update
    app:post(prefix .. "/:id/update", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local row, err = store.update(self.params.id, p)
        if not row then return json(400, { error = err }) end
        return json(200, { ok = true, memory = row })
    end)

    -- POST /:id/delete
    app:post(prefix .. "/:id/delete", function(self)
        local denied = authorise(self); if denied then return denied end
        store.delete(self.params.id)
        return json(200, { ok = true })
    end)

    -- POST /summarize  (manual trigger; same auth as the rest of the API)
    app:post(prefix .. "/summarize", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local summarizer = require("lapis_memory.summarizer")
        local result = summarizer.run({
            scope            = p.scope,
            dry_run          = p.dry_run == true or p.dry_run == "1" or p.dry_run == "true",
            weight_threshold = tonumber(p.weight_threshold),
            retention_days   = tonumber(p.retention_days),
            batch_size       = tonumber(p.batch_size),
            max_batches      = tonumber(p.max_batches),
        })
        return json(200, { ok = true, result = result })
    end)

    -- POST /promote  (session continuity: roll from_scope into to_scope)
    app:post(prefix .. "/promote", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local summarizer = require("lapis_memory.summarizer")
        local result = summarizer.promote({
            from_scope    = p.from_scope,
            to_scope      = p.to_scope,
            delete_source = p.delete_source == true or p.delete_source == "1" or p.delete_source == "true",
            dry_run       = p.dry_run == true or p.dry_run == "1" or p.dry_run == "true",
            limit         = tonumber(p.limit),
            min_rows      = tonumber(p.min_rows),
        })
        local status = (result.promoted == 1 or result.reason == "no_rows") and 200 or 400
        return json(status, { ok = status == 200, result = result })
    end)

    -- ---------------------------------------------------------------
    -- Knowledge-graph layer (Phase 16.5)
    -- ---------------------------------------------------------------
    local kg = require("lapis_memory.kg")

    -- POST /kg/assert
    app:post(prefix .. "/kg/assert", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local row, err = kg.assert_fact({
            scope            = p.scope,
            subject          = p.subject,
            predicate        = p.predicate,
            object           = p.object,
            valid_from       = p.valid_from,
            source_memory_id = tonumber(p.source_memory_id),
            supersede        = p.supersede == true or p.supersede == "1" or p.supersede == "true",
        })
        if not row then return json(400, { error = err }) end
        return json(200, { ok = true, fact = row })
    end)

    -- GET /kg/query
    app:get(prefix .. "/kg/query", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = self.params
        local rows, err = kg.query({
            scope               = p.scope,
            subject             = p.subject,
            predicate           = p.predicate,
            object              = p.object,
            at                  = p.at,
            include_invalidated = p.include_invalidated == "1" or p.include_invalidated == "true",
            limit               = tonumber(p.limit),
        })
        if not rows then return json(400, { error = err }) end
        return json(200, { ok = true, results = rows })
    end)

    -- POST /kg/invalidate
    app:post(prefix .. "/kg/invalidate", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = decode_body(self)
        local n, err = kg.invalidate({
            scope     = p.scope,
            subject   = p.subject,
            predicate = p.predicate,
            object    = p.object,
            at        = p.at,
        })
        if not n then return json(400, { error = err }) end
        return json(200, { ok = true, invalidated = n })
    end)

    -- GET /kg/timeline
    app:get(prefix .. "/kg/timeline", function(self)
        local denied = authorise(self); if denied then return denied end
        local p = self.params
        local rows, err = kg.timeline({
            scope     = p.scope,
            subject   = p.subject,
            predicate = p.predicate,
        })
        if not rows then return json(400, { error = err }) end
        return json(200, { ok = true, results = rows })
    end)
end

return M
