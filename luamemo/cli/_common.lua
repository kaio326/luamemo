-- luamemo.cli._common
-- Shared CLI bootstrap helpers: the luamemo config from the MEMO_* environment, read
-- through luamemo.settings (`memo` has sourced the .luamemorc files into it; the MCP
-- server loads them itself), the embedder keys `memo org` carries between projects,
-- and the .luamemorc writer.

local M = {}

local env = require("luamemo.util").env   -- nil when unset OR empty

--- A `die(msg, code)` for the subcommand `name`: "memo NAME: msg" on stderr, then exit
--- with `code` (default `default_code`, else 1).
function M.die_for(name, default_code)
    return function(msg, code)
        io.stderr:write("memo ", name, ": ", tostring(msg), "\n")
        os.exit(code or default_code or 1)
    end
end

--- luamemo set up from the settings → the luamemo module, else die(why, opts.code) (the
--- command's own). opts.db: another database; opts.no_embed: the command never embeds (no
--- embedder probe); opts.prefix: before the reason ("setup failed: ").
function M.setup_or_die(die, opts)
    opts = opts or {}
    local lm = require("luamemo")
    local cfg = M.config_from_env({})
    if opts.db then cfg.db = opts.db end
    if opts.no_embed then cfg.skip_embed_probe = true end
    local ok, err = pcall(lm.setup, cfg)
    if not ok then die((opts.prefix or "") .. tostring(err), opts.code) end
    return lm
end

-- The .luamemorc keys that select the embedder (one embedding space per database:
-- a project joining an org database takes that database's values).
M.EMBED_KEYS = { "MEMO_EMBEDDER", "MEMO_EMBEDDER_URL", "MEMO_EMBEDDER_ADAPTER", "MEMO_EMBEDDER_MODEL",
                 "MEMO_GGUF_MODEL", "MEMO_EMBED_DIM", "MEMO_EMBED_MAX_CHARS" }

-- The embedder rules, on a config holding the settings: an HTTP embedder
-- (MEMO_EMBEDDER_URL) takes priority; otherwise the in-process one MEMO_EMBEDDER names,
-- default hash — gguf_ffi with its model file from MEMO_GGUF_MODEL.
local function embedder(cfg)
    if cfg.embedder_url then
        cfg.embedder_local = nil
        cfg.embedder_adapter = cfg.embedder_adapter or "generic"
    else
        cfg.embedder_local = cfg.embedder_local or "hash"
        cfg.embedder_adapter, cfg.embedder_model = nil, nil
        if cfg.embedder_local == "gguf_ffi" then cfg.embedder_model = cfg.gguf_model end
    end
    return cfg
end

--- The embedder keys set in this process's environment → { KEY = value }.
function M.embed_env()
    local out = {}
    for _, k in ipairs(M.EMBED_KEYS) do
        local v = os.getenv(k)
        if v and v ~= "" then out[k] = v end
    end
    return out
end

--- An embedder-only config from a { KEY = value } map (see embed_env).
function M.embed_config(map)
    map = map or {}
    local all = require("luamemo.settings").from_env(function(k) return map[k] end)
    local cfg = {}
    for _, k in ipairs({ "embedder_local", "embedder_url", "embedder_adapter", "embedder_model", "gguf_model",
                         "embed_dim", "embed_max_chars" }) do
        cfg[k] = all[k]
    end
    return embedder(cfg)
end

local _warned = false

--- The luamemo config from the MEMO_* environment: every setting set there (see
--- luamemo.settings), the embedder rules above, and the vault's master key
--- (MEMO_MASTER_KEY_ENV is taken raw — an explicit empty value is honoured).
--- A strict setting that doesn't parse goes into cfg.settings_errors: setup() refuses
--- to start with it. Once per process, any other value that doesn't parse and a MEMO_
--- variable luamemo doesn't read are reported (opts.warn: a function taking the line,
--- or false for none); a process `memo` started after checking them
--- (MEMO__SETTINGS_CHECKED) stays quiet.
function M.config_from_env(opts)
    opts = opts or {}
    local settings = require("luamemo.settings")
    local cfg, problems, fatal = settings.from_env(env)
    embedder(cfg)
    local mke = os.getenv("MEMO_MASTER_KEY_ENV")
    if mke then cfg.master_key_env = mke end
    if #fatal > 0 then cfg.settings_errors = fatal end

    if not _warned and opts.warn ~= false and not env("MEMO__SETTINGS_CHECKED") then
        _warned = true
        local warn = type(opts.warn) == "function" and opts.warn
            or function(line) io.stderr:write("luamemo: ", line, "\n") end
        for _, p in ipairs(problems) do warn(p) end
        for _, u in ipairs(settings.unknown(settings.env_names())) do warn(settings.unknown_message(u)) end
    end
    return cfg
end

--- Project config file (.luamemorc, KEY=value lines): set / replace a key, or
--- remove it (value = nil). Same semantics as cli/memo's _save_rc_key: the value
--- is written single-quoted (read back literally) and a newline is refused; the
--- file stays 0600 (it holds this machine's settings).
function M.rc_set(path, key, value)
    local util = require("luamemo.util")
    if value ~= nil and tostring(value):find("\n", 1, true) then
        return nil, "refusing to write " .. key .. " — the value contains a newline"
    end
    -- A project file memo didn't write and nobody trusted (it came with the repository or
    -- a download, or was edited) is not rewritten: memo would vouch for whatever else it
    -- says. One memo writes is trusted as written (settings.trusted: memo's own, or
    -- reviewed), so memo keeps using it.
    local settings = require("luamemo.settings")
    local home = os.getenv("HOME") or ""
    local own = path == home .. "/.luamemorc" or path == home .. "/.memorc"
    -- A project's settings file that is a symlink is left alone: a downloaded folder could
    -- point it at any file of the user's, which would be read and rewritten. (The user's
    -- own ~/.luamemorc is written through its link — a dotfiles manager's.)
    local link = not own and os.execute("test -L " .. util.shell_quote(path))
    if link == 0 or link == true then
        return nil, ("%s is a symbolic link — left alone; luamemo writes a project's settings only to a "
            .. "regular file"):format(path)
    end
    local trusted, why = true, nil   -- the user's own files (a dotfiles repo may track them)
    if not own then trusted, why = settings.trusted(path) end
    if trusted == false then
        return nil, ("%s was left alone — %s. Review it; if it's fine: memo config trust"):format(path, why)
    end
    local entry = value ~= nil and (key .. "=" .. util.shell_quote(value)) or nil
    local lines, found = {}, false
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            if line:match("^" .. key .. "=") then
                if entry and not found then lines[#lines + 1] = entry end
                found = true
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    if entry and not found then lines[#lines + 1] = entry end
    -- 0600 (a settings file may hold a database path or a vault reference), written atomically.
    local ok, werr = util.write_private(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""),
        { follow_link = own })
    if not ok then return nil, werr end
    if not own then return settings.trust(path) end
    return true
end

return M
