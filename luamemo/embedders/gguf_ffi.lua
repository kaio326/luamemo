-- luamemo.embedders.gguf_ffi  (Phase 7 — in-process embedder, the durability play)
--
-- Embeds text IN-PROCESS via LuaJIT FFI over gguf_shim.so (llama.cpp + ANY
-- llama.cpp-compatible GGUF embedding model) — no HTTP, no sidecar, no vendor
-- API. The recommended default model is EmbeddingGemma-300M, but it is fully
-- swappable: point embedder_model at any open-weights GGUF embedding model as
-- more capable ones appear. Achieves "win 1" (drop the embedder service) and
-- hosts fast inline learning ("win 2").
--
-- Requires LuaJIT (ffi). Under PUC lua5.1 the module still loads but M.embed
-- returns a clear error so the embedder registry can fall back gracefully.
--
-- Config (cfg or env; MEMO_GEMMA_* accepted as back-compat aliases):
--   embedder_model / MEMO_GGUF_MODEL   path to the .gguf  (required)
--   gguf_shim_path / MEMO_GGUF_SHIM    path to gguf_shim.so (default: ./native/)
--   embed_dim                          Matryoshka truncation dim (<= model dim; renormalised)
--   gguf_n_ctx / MEMO_GGUF_NCTX        context length (default 2048)

local ok_ffi, ffi = pcall(require, "ffi")
local ffishim     = require("luamemo.embedders.native.ffi_shim")

local M = {}

if ok_ffi then
    ffi.cdef [[
        void * lmembed_load(const char * path, int n_ctx, int n_gpu_layers);
        int    lmembed_dim(void * handle);
        int    lmembed_embed(void * handle, const char * text, float * out, int max_dim);
        void   lmembed_free(void * handle);
    ]]
end

local function env(name)  -- MEMO_GGUF_<name>, falling back to MEMO_GEMMA_<name>
    local v = os.getenv("MEMO_GGUF_" .. name)
    if v and v ~= "" then return v end
    v = os.getenv("MEMO_GEMMA_" .. name)
    if v and v ~= "" then return v end
    return nil
end

local _handle, _dim, _outbuf

local function ensure_handle(cfg)
    if _handle then return _handle end
    local lib = ffishim.load(cfg)
    local model = (cfg and cfg.embedder_model) or env("MODEL")
    if not model or model == "" then
        error("gguf_ffi: model path required (cfg.embedder_model or MEMO_GGUF_MODEL)")
    end
    local n_ctx = tonumber((cfg and (cfg.gguf_n_ctx or cfg.gemma_n_ctx)) or env("NCTX")) or 2048
    -- GPU offload for the embedder: 0 = CPU (default), N = N layers, -1 = all.
    -- No-op on a CPU-only libllama; MEMO_GGUF_NGL activates it after a CUDA build.
    local n_gpu = tonumber((cfg and cfg.gguf_n_gpu) or env("NGL")) or 0
    local h = lib.lmembed_load(model, n_ctx, n_gpu)
    if h == nil then error("gguf_ffi: failed to load model: " .. model) end
    _handle = h
    _dim    = lib.lmembed_dim(h)
    _outbuf = ffi.new("float[?]", _dim)
    return _handle
end

--- Embed text -> Lua array of floats (L2-normalised). Returns nil, err on failure.
function M.embed(text, cfg)
    if not ok_ffi then return nil, "gguf_ffi: requires LuaJIT (ffi not available)" end
    local ok, res = pcall(function()
        local lib = ffishim.load(cfg)
        local h   = ensure_handle(cfg)
        local n   = lib.lmembed_embed(h, text or "", _outbuf, _dim)
        if n < 0 then error("embed failed") end

        local want = tonumber(cfg and cfg.embed_dim) or _dim
        if want > _dim then want = _dim end
        local out = {}
        if want < _dim then
            -- Matryoshka: truncate to `want` dims, then re-normalise.
            local ss = 0
            for i = 0, want - 1 do local v = _outbuf[i]; out[i + 1] = v; ss = ss + v * v end
            if ss > 0 then local inv = 1 / math.sqrt(ss); for i = 1, want do out[i] = out[i] * inv end end
        else
            for i = 0, _dim - 1 do out[i + 1] = _outbuf[i] end
        end
        return out
    end)
    if not ok then return nil, "gguf_ffi: " .. tostring(res) end
    return res
end

--- Native embedding dim of the loaded model (loads it if needed).
function M.dim(cfg)
    if not ok_ffi then return nil, "gguf_ffi: requires LuaJIT" end
    local ok = pcall(ensure_handle, cfg); if not ok then return nil end
    return _dim
end

function M.reset()
    if _handle then pcall(function() ffishim.load().lmembed_free(_handle) end) end
    _handle, _dim, _outbuf = nil, nil, nil
end

function M.selftest(cfg)
    local v, err = M.embed("the quick brown fox", cfg)
    return (type(v) == "table" and #v > 0), err
end

return M
