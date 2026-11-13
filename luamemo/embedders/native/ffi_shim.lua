-- luamemo.embedders.native.ffi_shim
-- Shared helpers for the two LuaJIT-FFI callers of gguf_shim.so — the in-process
-- embedder (luamemo.embedders.gguf_ffi) and the sensing generator
-- (luamemo.sensing.generate). Both need to locate + load the same .so; this
-- centralises that so they don't each re-implement path resolution and caching.
--
-- Where the shim is: an explicit override (MEMO_GGUF_SHIM — `memo gguf install` sets it),
-- else <data dir>/native/gguf_shim.so, where gguf/build.sh puts a shim built from source.
-- Never next to this module: which copy of a module loaded must not decide where the
-- library is (0.5.3's MCP server loaded a copy the rock kept beside mcp/, and looked for
-- the .so next to it while build.sh had put it elsewhere).
--
-- Pure at require-time: the library is only loaded by load().

local M = {}
local util = require("luamemo.util")

-- The directory this module was loaded from.
local function module_dir()
    return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]?ffi_shim%.lua$", ""))
end

--- Where gguf/build.sh puts a shim built from source, and where luamemo looks without an override.
function M.default_path() return util.data_dir() .. "/native/gguf_shim.so" end

--- An explicit override (cfg.gguf_shim_path, MEMO_GGUF_SHIM, MEMO_GEMMA_SHIM) → path | nil.
function M.override(cfg)
    local p = cfg and cfg.gguf_shim_path
    if not (p and p ~= "") then p = os.getenv("MEMO_GGUF_SHIM") end
    if not (p and p ~= "") then p = os.getenv("MEMO_GEMMA_SHIM") end
    return (p and p ~= "") and p or nil
end

--- The shim in force: the override, else the default place.
function M.shim_path(cfg) return M.override(cfg) or M.default_path() end

--- Where build.sh put the shim before 0.5.4: next to this module. Named in messages, never loaded.
function M.legacy_path() return module_dir() .. "/gguf_shim.so" end

--- gguf/build.sh of this install → path | nil: beside luamemo/ in a checkout or the plugin,
--- in this version's rock directory in a LuaRocks tree.
function M.build_script()
    local dir = module_dir()
    local root = dir:match("^(.*)[/\\]luamemo[/\\]embedders[/\\]native$")
        or (dir:match("^luamemo[/\\]embedders[/\\]native$") and ".")
    if not root then return nil end
    if util.exists(root .. "/gguf/build.sh") then return root .. "/gguf/build.sh" end
    local tree, lua_ver = root:match("^(.*)/share/lua/([%d%.]+)$")
    local p = tree and ("%s/lib/luarocks/rocks-%s/luamemo/%s-1/gguf/build.sh"):format(
        tree, lua_ver, require("luamemo").VERSION)
    return (p and util.exists(p)) and p or nil
end

--- build_script(), or — where it can't be found from here — where to get it. One wording for every message.
function M.build_hint()
    return M.build_script() or "gguf/build.sh (from luamemo's source, github.com/kaio326/luamemo)"
end

--- build_script() as a line to paste into a shell: the path, or a comment that says where to get it.
function M.build_command()
    return M.build_script() or "gguf/build.sh   # from luamemo's source, github.com/kaio326/luamemo"
end

--- Why luamemo's data directory can't hold the runtime: it depends on the working directory (HOME unset, a
--- relative XDG_DATA_HOME) → text | nil. A project could put its own library there, so nothing is installed
--- into it or loaded from it. The one test: refused_place() (loading) and bundle.available() (installing).
function M.data_dir_refusal()
    if util.data_dir():sub(1, 1) == "/" then return nil end
    return "HOME is not set, or XDG_DATA_HOME is not an absolute path"
end

--- Why the default place is not used → text | nil (data_dir_refusal, when no MEMO_GGUF_SHIM is set: an
--- explicit override is the user's choice and is not judged).
function M.refused_place(cfg)
    local why = (not M.override(cfg)) and M.data_dir_refusal()
    if not why then return nil end
    return "the GGUF runtime's place is relative to the working directory (" .. why .. ") — fix HOME or "
        .. "XDG_DATA_HOME, or set MEMO_GGUF_SHIM to the absolute path of gguf_shim.so"
end

--- Why no shim can be loaded, and what to do → text | nil (the shim is there).
function M.missing(cfg)
    local refused = M.refused_place(cfg)
    if refused then return refused end
    local override = M.override(cfg)
    local path = M.shim_path(cfg)
    if util.exists(path) then return nil end
    local build = M.build_hint()
    if override then
        return ("the GGUF runtime is not at %s, the place MEMO_GGUF_SHIM names (it wins over a runtime built from "
            .. "source) — run memo gguf install, or unset it (memo config unset --user MEMO_GGUF_SHIM) and "
            .. "build one: LLAMA_DIR=~/llama.cpp bash %s"):format(path, build)
    end
    local old = util.exists(M.legacy_path()) and M.legacy_path() or nil
    return ("the GGUF runtime is not installed (looked for %s)%s — install the prebuilt one (memo gguf install) "
        .. "or build it: LLAMA_DIR=~/llama.cpp bash %s"):format(path,
        old and ("; one built before luamemo 0.5.4 is at " .. old .. ", where luamemo no longer looks") or "", build)
end

-- One dlopen handle shared by both callers (it is the same .so).
local _lib
function M.load(cfg)
    if _lib then return _lib end
    local why = M.missing(cfg)
    if why then error(why, 0) end
    _lib = require("luamemo.native.loader").ffi.load(M.shim_path(cfg))
    return _lib
end

--- Was this loaded shim built before luamemo 0.5.0? Such a shim has no
--- lmembed_last_truncated, and it fails on any text longer than the model's context:
--- its token buffer held n_ctx tokens, which llama_tokenize leaves empty when the text
--- needs more. A shim built from source stays in the data directory across upgrades
--- (it was never part of the rock), so it can outlive its luamemo. (gguf_ffi declares the symbol.)
function M.stale(lib)
    return not pcall(function() return lib.lmembed_last_truncated end)
end
M.STALE = "this GGUF shim was built before luamemo 0.5.0 and can't embed a text longer than the model's "
    .. "context — rebuild it (gguf/build.sh) or run memo gguf install"

return M
