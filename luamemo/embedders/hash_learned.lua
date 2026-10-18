-- luamemo.embedders.hash_learned  (Phase 5 — project-adapted, maximally durable)
--
-- The hash embedder with the project's learned projection W: luamemo.embedders.projected
-- with projected_base = "hash" (embedder_local = "hash_learned" is its own name for it).
-- With no W trained it returns the RAW hash vector, so it is the plain hash embedder by
-- default. Pure math, no model and no vendor: nothing can ever deprecate it (goal 1).
-- W is trained offline (luamemo.projection_train) on feedback triples.

local projected = require("luamemo.embedders.projected")

local M = {}

-- The caller's config, seen with projected_base = "hash" (a view, not a copy — the
-- config is luamemo's whole one); one view per config table.
local views = setmetatable({}, { __mode = "k" })
local DEFAULT = {}
local function with_hash(cfg)
    cfg = cfg or DEFAULT
    local v = views[cfg]
    if not v then
        v = setmetatable({ projected_base = "hash" }, { __index = cfg })
        views[cfg] = v
    end
    return v
end

function M.embed(text, cfg) return projected.embed(text, with_hash(cfg)) end

-- y = W x (a full or low-rank W) — the trainer and the tests apply W directly.
M.project = projected.apply_W
M.reset_cache = projected.reset_cache

function M.selftest(cfg)
    local v = M.embed("the quick brown fox", cfg or { embed_dim = 384 })
    return type(v) == "table" and #v > 0
end

return M
