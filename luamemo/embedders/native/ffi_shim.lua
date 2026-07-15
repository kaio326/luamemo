-- luamemo.embedders.native.ffi_shim
-- Shared helpers for the two LuaJIT-FFI callers of gguf_shim.so — the in-process
-- embedder (luamemo.embedders.gguf_ffi) and the sensing generator
-- (luamemo.sensing.generate). Both need to locate + load the same .so; this
-- centralises that so they don't each re-implement path resolution and caching.
--
-- Pure at require-time (ffi is required lazily inside load()), so this module is
-- safe to require under PUC lua5.1 — only load() needs LuaJIT.

local M = {}

--- Does a file exist and open for reading?
function M.exists(p)
    local f = p and io.open(p, "r")
    if f then f:close(); return true end
    return false
end

--- Resolve the gguf_shim.so path. Honours an explicit override
--- (cfg.gguf_shim_path / gemma_shim_path / gen_shim_path, or MEMO_GGUF_SHIM /
--- MEMO_GEMMA_SHIM); otherwise resolves it next to this module (native/).
function M.shim_path(cfg)
    local p = cfg and (cfg.gguf_shim_path or cfg.gemma_shim_path or cfg.gen_shim_path)
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
    _lib = require("ffi").load(M.shim_path(cfg))
    return _lib
end

return M
