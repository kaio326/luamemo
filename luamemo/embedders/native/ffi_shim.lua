-- luamemo.embedders.native.ffi_shim
-- Shared helpers for the two LuaJIT-FFI callers of gguf_shim.so — the in-process
-- embedder (luamemo.embedders.gguf_ffi) and the sensing generator
-- (luamemo.sensing.generate). Both need to locate + load the same .so; this
-- centralises that so they don't each re-implement path resolution and caching.
--
-- Pure at require-time: the library is only loaded by load().

local M = {}

--- Does a file exist and open for reading?
function M.exists(p)
    local f = p and io.open(p, "r")
    if f then f:close(); return true end
    return false
end

--- Resolve the gguf_shim.so path. Honours an explicit override
--- (cfg.gguf_shim_path, or MEMO_GGUF_SHIM / MEMO_GEMMA_SHIM); otherwise resolves
--- it next to this module (native/).
function M.shim_path(cfg)
    local p = cfg and cfg.gguf_shim_path
    if not (p and p ~= "") then p = os.getenv("MEMO_GGUF_SHIM") end
    if not (p and p ~= "") then p = os.getenv("MEMO_GEMMA_SHIM") end
    if p and p ~= "" then return p end
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return (src:gsub("ffi_shim%.lua$", "gguf_shim.so"))
end

-- One dlopen handle shared by both callers (it is the same .so).
local _lib
function M.load(cfg)
    if _lib then return _lib end
    _lib = require("luamemo.native.loader").ffi.load(M.shim_path(cfg))
    return _lib
end

--- Was this loaded shim built before luamemo 0.5.0? Such a shim has no
--- lmembed_last_truncated, and it fails on any text longer than the model's context:
--- its token buffer held n_ctx tokens, which llama_tokenize leaves empty when the text
--- needs more. An upgrade keeps a shim built next to the modules (it was never part of
--- the rock), so it can outlive its luamemo. (gguf_ffi declares the symbol.)
function M.stale(lib)
    return not pcall(function() return lib.lmembed_last_truncated end)
end
M.STALE = "this GGUF shim was built before luamemo 0.5.0 and can't embed a text longer than the model's "
    .. "context — rebuild it (luamemo/embedders/native/build.sh) or run memo gguf install"

return M
