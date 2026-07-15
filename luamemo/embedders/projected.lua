-- luamemo.embedders.projected  (Phase 8 — generic learned projection)
--
-- Wraps ANY base embedder with a learned projection W:
--     embed(text) = L2norm( W · base.embed(text) )
-- The base is resolved by name (cfg.projected_base): "hash", "gguf_ffi", or any
-- local embedder module exposing embed(text, cfg). W is trained offline by
-- luamemo.projection_train on feedback triples and loaded from the versioned
-- artifact. With NO (matching) W configured it returns the base vector unchanged
-- — so it is exactly the base embedder until a project-adapted W is promoted.
--
-- This is the general form of luamemo.embedders.hash_learned (which is the
-- base="hash" special case). Model-agnostic: point projected_base at gguf_ffi and
-- MEMO_GGUF_MODEL at any GGUF, and the projection adapts THAT model to the project.
--
-- W formats (both supported): { kind="full", dim, m=[d*d] } or
-- { kind="lowrank", dim, rank=r, U=[d*r], V=[r*d] } giving W = I + U·V.

local M = {}

local function l2norm(v)
    local s = 0
    for i = 1, #v do s = s + v[i] * v[i] end
    if s > 0 then local inv = 1 / math.sqrt(s); for i = 1, #v do v[i] = v[i] * inv end end
    return v
end

-- y = W · x, dispatching on the stored W format. x length = d.
function M.apply_W(x, W)
    local d = #x
    if W.kind == "lowrank" then
        local r, U, V = W.rank, W.U, W.V
        local h = {}                      -- h = V x  (length r)
        for k = 1, r do
            local base, s = (k - 1) * d, 0
            for j = 1, d do s = s + V[base + j] * x[j] end
            h[k] = s
        end
        local y = {}                      -- y = x + U h  (W = I + U·V)
        for i = 1, d do
            local base, s = (i - 1) * r, x[i]
            for k = 1, r do s = s + U[base + k] * h[k] end
            y[i] = s
        end
        return y
    else                                  -- full d×d
        local m, y = W.m, {}
        for i = 1, d do
            local base, s = (i - 1) * d, 0
            for j = 1, d do s = s + m[base + j] * x[j] end
            y[i] = s
        end
        return y
    end
end

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
    local base_name = cfg and (cfg.projected_base or cfg.embedder_base)
    if not base_name or base_name == "" then
        return nil, "projected: projected_base required (e.g. 'gguf_ffi' or 'hash')"
    end
    local ok, base = pcall(require, "luamemo.embedders." .. base_name)
    if not ok or type(base.embed) ~= "function" then
        return nil, "projected: base embedder '" .. tostring(base_name) .. "' not found or has no embed()"
    end
    local x, err = base.embed(text, cfg)
    if type(x) ~= "table" then return nil, err or "projected: base embed failed" end

    local W = current_W(cfg)
    if type(W) ~= "table" or (W.dim and W.dim ~= #x) then
        return x                          -- identity: no matching W -> base unchanged
    end
    return l2norm(M.apply_W(x, W))
end

function M.selftest(cfg)
    local v = M.embed("the quick brown fox", cfg)
    return type(v) == "table" and #v > 0
end

return M
