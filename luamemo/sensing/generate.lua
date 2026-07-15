-- luamemo.sensing.generate  (Phase 9 — in-process generation for "dreams" extraction)
--
-- A general complete(prompt) primitive via LuaJIT FFI over the SAME gguf_shim.so
-- (llama.cpp) used by the embedder — a small instruct GGUF (e.g. gemma-3-1b-it)
-- loaded ON-DEMAND (cached, not resident during normal embedding). Greedy /
-- deterministic. Requires LuaJIT; returns nil + error under PUC lua5.1 so the
-- sensing pipeline degrades to heuristics-only.
--
-- Config (cfg or env): gen_model / MEMO_GEN_MODEL (instruct .gguf, required);
--   gen_n_ctx / MEMO_GEN_NCTX (4096); gguf_shim_path / MEMO_GGUF_SHIM;
--   gen_n_gpu / MEMO_GEN_NGL (0 = CPU, N = offload N layers, -1 = all — requires a
--   CUDA-built libllama; harmless no-op on a CPU-only build).

local ok_ffi, ffi = pcall(require, "ffi")

local M = {}

if ok_ffi then
    -- Only the generation symbols (the embedder's lmembed_* may already be cdef'd
    -- by gguf_ffi.lua; re-declaring identical names would error — these are distinct).
    pcall(ffi.cdef, [[
        void * lmgen_load(const char * path, int n_ctx, int n_gpu_layers);
        int    lmgen_complete(void * handle, const char * prompt, char * out, int max_out, int max_tokens);
        void   lmgen_free(void * handle);
    ]])
end

local ffishim = require("luamemo.embedders.native.ffi_shim")

local function env(name)
    local v = os.getenv("MEMO_GEN_" .. name)
    if v and v ~= "" then return v end
    return nil
end

local function model_path(cfg)
    return (cfg and cfg.gen_model) or env("MODEL")
end

local _handle, _outbuf
local OUTCAP = 8192

local function ensure(cfg)
    if _handle then return _handle end
    local lib   = ffishim.load(cfg)
    local model = model_path(cfg)
    if not model or model == "" then error("gen model required (cfg.gen_model or MEMO_GEN_MODEL)") end
    local n_ctx = tonumber((cfg and cfg.gen_n_ctx) or env("NCTX")) or 4096
    -- GPU offload: 0 = CPU (default), N = N layers, -1 = all. A CUDA-built
    -- libllama + a 4B model here is the "good extraction" path; no-op on CPU builds.
    local n_gpu = tonumber((cfg and cfg.gen_n_gpu) or env("NGL")) or 0
    local h = lib.lmgen_load(model, n_ctx, n_gpu)
    if h == nil then error("failed to load gen model: " .. model) end
    _handle = h
    _outbuf = ffi.new("char[?]", OUTCAP)
    return _handle
end

--- Is in-process generation usable right now? (LuaJIT + shim + model all present.)
function M.available(cfg)
    if not ok_ffi then return false end
    local m = model_path(cfg)
    return (m ~= nil and m ~= "") and ffishim.exists(ffishim.shim_path(cfg)) and ffishim.exists(m)
end

--- complete(prompt, cfg) -> string | nil, err. Greedy/deterministic.
function M.complete(prompt, cfg)
    if not ok_ffi then return nil, "generate: requires LuaJIT (ffi)" end
    local ok, res = pcall(function()
        local lib = ffishim.load(cfg)
        local h   = ensure(cfg)
        local max_tokens = tonumber(cfg and cfg.max_tokens) or 256
        local n = lib.lmgen_complete(h, prompt or "", _outbuf, OUTCAP, max_tokens)
        if n < 0 then error("generation failed") end
        return ffi.string(_outbuf, n)
    end)
    if not ok then return nil, "generate: " .. tostring(res) end
    return res
end

function M.reset()
    if _handle then pcall(function() ffishim.load().lmgen_free(_handle) end) end
    _handle, _outbuf = nil, nil
end

return M
