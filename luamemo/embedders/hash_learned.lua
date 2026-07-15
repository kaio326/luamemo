-- luamemo.embedders.hash_learned  (Phase 5 — project-adapted, maximally durable)
--
-- Base hash features → optional learned projection W → L2-normalise.
-- A drop-in local embedder (embedder_local = "hash_learned"): with no W
-- configured it returns the RAW hash vector unchanged, so it is identical to the
-- plain hash embedder by default. Because it is pure math with no model and no
-- vendor, it is the most durable embedding option in the stack — nothing can
-- ever deprecate it (goal 1).
--
-- W is trained offline (luamemo.projection_train) on feedback triples and stored
-- as { dim = d, m = { d*d flat, row-major } }. Inference is one mat-vec.

local hash = require("luamemo.embedders.hash")

local M = {}

local function l2norm(v)
    local s = 0
    for i = 1, #v do s = s + v[i] * v[i] end
    if s > 0 then
        local inv = 1 / math.sqrt(s)
        for i = 1, #v do v[i] = v[i] * inv end
    end
    return v
end

-- y = W x  (W is d×d row-major in W.m; x is length d)
function M.project(x, W)
    local d, m = W.dim, W.m
    local y = {}
    for i = 1, d do
        local base, s = (i - 1) * d, 0
        for j = 1, d do s = s + m[base + j] * x[j] end
        y[i] = s
    end
    return y
end

-- Lazily-loaded current projection (cached). cfg.projection_W overrides (used by
-- the trainer/bench to inject a specific matrix without touching the artifact).
local _W, _loaded
local function current_W(cfg)
    if cfg and type(cfg.projection_W) == "table" then return cfg.projection_W end
    if _loaded then return _W or nil end
    local ok, pt = pcall(require, "luamemo.projection_train")
    _W = (ok and pt.load_current and pt.load_current()) or false
    _loaded = true
    return _W or nil
end
function M.reset_cache() _loaded = nil; _W = nil end

function M.embed(text, cfg)
    local dim = (cfg and cfg.embed_dim) or 384
    local x = hash.embed(text, { embed_dim = dim })   -- base hash (already L2-normalised)
    local W = current_W(cfg)
    if type(W) ~= "table" or W.dim ~= dim or type(W.m) ~= "table" then
        return x                                       -- identity fallback == raw hash
    end
    return l2norm(M.project(x, W))
end

function M.selftest(cfg)
    local v = M.embed("the quick brown fox", cfg or { embed_dim = 384 })
    return type(v) == "table" and #v > 0
end

return M
