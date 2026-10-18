-- luamemo.cli.config
--
-- `memo config` — luamemo's settings (luamemo.settings), read and changed by people:
--   memo config [list] [--json]          every setting: its value and where it comes from
--   memo config list --markdown          the reference tables of SETTINGS.md (M.markdown)
--   memo config get KEY                  the value in force
--   memo config set KEY VALUE [--user]   into this project's .luamemorc (or ~/.luamemorc)
--   memo config unset KEY [--user]
--   memo config check                    values that don't parse, MEMO_ names luamemo doesn't read
--   memo config trust                    use a .luamemorc memo didn't write (committed, downloaded, edited)
-- KEY: MEMO_DEDUP_THRESHOLD, DEDUP_THRESHOLD or dedup_threshold. A value is checked
-- (type, range, allowed words) before it is written; a header holding a credential in
-- plain text is refused — the credential goes into the vault (memo secret-store NAME)
-- and the header says {secret:NAME}. MCP reads settings (memory_status) but can't
-- change them.

local settings = require("luamemo.settings")

local M = {}

local USAGE = [[usage: memo config [list] [--json | --markdown]
       memo config get KEY
       memo config set KEY VALUE [--user]
       memo config unset KEY [--user]
       memo config check
       memo config trust
KEY: e.g. MEMO_DEDUP_THRESHOLD (or dedup_threshold). --user: ~/.luamemorc (every
project) instead of this project's .luamemorc, which wins over it. trust: use this
project's .luamemorc as it is although memo didn't write it (committed to git,
downloaded with the project, edited by hand).
--markdown: every setting's name, accepted values, default and meaning (SETTINGS.md).
]]

local die = require("luamemo.cli._common").die_for("config")

local function entry_of(name)
    local e = settings.get(name)
    if e then return e end
    local up = name:upper()
    local full = up:match("^MEMO_") and up or ("MEMO_" .. up)
    if settings.OTHER_VARS[full] then
        die(full .. " is read from the environment where it is used — not a setting memo config manages")
    end
    local u = settings.unknown({ full })[1]
    die(u and settings.unknown_message(u) or ("unknown setting: " .. name))
end

-- The config in force (defaults + the environment memo built from the .luamemorc files),
-- and the problems found reading it.
local function current()
    local cfg = settings.defaults()
    for k, v in pairs(require("luamemo.cli._common").config_from_env({ warn = false })) do
        if k ~= "settings_errors" then cfg[k] = v end
    end
    local _, problems, fatal = settings.from_env(function(name)
        local v = os.getenv(name)
        if v ~= "" then return v end
    end)
    local out = {}
    for _, f in ipairs(fatal) do out[#out + 1] = f .. " — luamemo won't start until this is fixed" end
    for _, p in ipairs(problems) do out[#out + 1] = p end
    for _, u in ipairs(settings.unknown(settings.env_names())) do out[#out + 1] = settings.unknown_message(u) end
    return cfg, out
end

-- A path as shown: relative to the working directory when under it, else ~/….
local function home_path(p)
    local here, home = os.getenv("PWD"), os.getenv("HOME")
    if here and here ~= "" and p:sub(1, #here + 1) == here .. "/" then return p:sub(#here + 2) end
    if home and home ~= "" and p:sub(1, #home + 1) == home .. "/" then return "~" .. p:sub(#home + 1) end
    return p
end

local function cmd_list(json_out)
    local cfg, problems = current()
    local files = settings.files()
    local view = settings.view(cfg, files)
    if json_out then
        io.write(require("luamemo.json").encode({ settings = view, problems = problems,
            files = { project = files.paths.project, user = files.paths.user } }), "\n")
        return
    end
    local group
    for _, s in ipairs(view) do
        if s.group ~= group then
            group = s.group
            io.write(group, "\n")
        end
        local value = s.value or "-"
        io.write(("  %-36s %-28s %s\n"):format(s.name, value, s.value and s.source or ""))
    end
    io.write(("\nread from %s (project), %s (user) and the environment — the project's file wins\n")
        :format(home_path(files.paths.project), home_path(files.paths.user)))
    io.write("change with: memo config set KEY VALUE [--user]\n")
    if files.untrusted then
        io.write("warning: ", settings.untrusted_message(home_path(files.paths.project), files.untrusted), "\n")
    end
    if #problems > 0 then
        io.write("\n")
        for _, p in ipairs(problems) do io.write("warning: ", p, "\n") end
    end
end

-- ---------------------------------------------------------------------------
-- The reference: SETTINGS.md's tables, generated from the registry so the document
-- can't drift from what luamemo reads (eval/tests/test_settings.lua compares them).
-- ---------------------------------------------------------------------------
local GROUP_TITLES = {
    project = "Project", embedder = "Embedder", writes = "Writes", search = "Search",
    rerank = "Reranker", summarizer = "Summarizer", maintenance = "Maintenance",
    learning = "Learning from use", federation = "Federation (org mode)", secrets = "Secrets vault",
}

-- Text for a table cell: one line, no column breaks, no HTML (user:<email> stays visible).
local function cell(s)
    return (tostring(s):gsub("\n", " "):gsub("|", "\\|"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- What a setting accepts.
local function accepts(e)
    if e.values then
        local t = {}
        for _, v in ipairs(e.values) do t[#t + 1] = "`" .. v .. "`" end
        return table.concat(t, " · ")
    end
    local t = ({ boolean = "true / false", number = "number", integer = "whole number",
                 list = "comma-separated list", json = "JSON object", string = "text" })[e.type] or e.type
    local function n(v) return settings.format({}, v) end
    if e.min and e.max then return ("%s, %s–%s"):format(t, n(e.min), n(e.max)) end
    if e.min then return ("%s ≥ %s"):format(t, n(e.min)) end
    if e.max then return ("%s ≤ %s"):format(t, n(e.max)) end
    return t
end

--- The reference tables (markdown): every setting by group, then the other MEMO_
--- variables luamemo's tools read.
function M.markdown()
    local out, group = {}, nil
    local function w(s) out[#out + 1] = s end
    for _, e in ipairs(settings.LIST) do
        if e.group ~= group then
            group = e.group
            if #out > 0 then w("") end
            w("### " .. (GROUP_TITLES[group] or group)); w("")
            w("| Setting | Accepts | Default | Meaning |"); w("|---|---|---|---|")
        end
        local d = settings.implied(e, {})
        local notes = { cell(e.doc) }
        if e.reembed then notes[#notes + 1] = "Changing it: `memo reembed --all`." end
        if e.strict then notes[#notes + 1] = "An invalid value stops luamemo (it is never ignored)." end
        if e.mcp_env then
            notes[#notes + 1] = "Set only in your shell, `memo calibrate` offers to save it in `.luamemorc` "
                .. "(an MCP client starts the server without your shell's settings)."
        end
        if e.aliases then
            local a = {}
            for _, name in ipairs(e.aliases) do a[#a + 1] = "`" .. name .. "`" end
            notes[#notes + 1] = "Older name, still read: " .. table.concat(a, ", ") .. "."
        end
        w(("| `%s` | %s | %s | %s |"):format(e.env, accepts(e),
            d ~= nil and ("`" .. cell(settings.show(e, d)) .. "`") or "—", table.concat(notes, " ")))
    end
    local names = {}
    for name, doc in pairs(settings.OTHER_VARS) do
        if type(doc) == "string" then names[#names + 1] = name end
    end
    table.sort(names)
    w(""); w("### Other variables"); w("")
    w("Read from the environment where they are used (not from `memo config`)."); w("")
    w("| Variable | Meaning |"); w("|---|---|")
    for _, name in ipairs(names) do w(("| `%s` | %s |"):format(name, cell(settings.OTHER_VARS[name]))) end
    return table.concat(out, "\n") .. "\n"
end

local function cmd_get(name)
    local e = entry_of(name)
    local cfg = current()
    for _, r in ipairs(settings.effective(cfg, settings.files())) do
        if r.entry == e then
            local shown = settings.show(e, r.value)
            if shown == nil then os.exit(1) end
            io.write(shown, "\n")
            return
        end
    end
end

-- The vault's secret names, when this database's vault can be read (else nil). A
-- database that doesn't exist yet is not created for this.
local function vault_names(cfg)
    local ok, names = pcall(function()
        local path = cfg.db and require("luamemo.db").resolve(cfg.db)
        local f = path and io.open(path, "rb")
        if not f then return nil end
        f:close()
        local c = {}
        for k, v in pairs(cfg) do c[k] = v end
        c.skip_embed_probe = true
        require("luamemo").setup(c)
        local secrets = require("luamemo.secrets")
        if not secrets.enabled() then return nil end
        local out = {}
        for _, s in ipairs(secrets.list()) do out[s.name] = true end
        return out
    end)
    return ok and names or nil
end

local function cmd_set(name, text, user)
    local e = entry_of(name)
    if e.secret then
        die("memo config doesn't write the master key — keep it in a file (MEMO_MASTER_KEY_PATH) "
            .. "or name the variable holding it (MEMO_MASTER_KEY_ENV)")
    end
    local v, err = settings.parse(e, text)
    if v == nil then die(err) end
    local plain = settings.plain_credentials(e, v)
    if #plain > 0 then
        die(("%s: header %s holds a credential in plain text — store it in the vault and refer to it:\n"
            .. "  memo secret-store NAME            (paste the key; it is kept encrypted)\n"
            .. "  memo config set %s '{\"%s\": \"Bearer {secret:NAME}\"}'")
            :format(e.env, table.concat(plain, ", "), e.env, plain[1]))
    end
    local cfg = current()
    local files = settings.files()
    local before
    for _, r in ipairs(settings.effective(cfg, files)) do
        if r.entry == e then before = settings.format(e, r.value) end
    end
    local path = user and files.paths.user or files.paths.project
    local common = require("luamemo.cli._common")
    local ok, werr = common.rc_set(path, e.env, settings.format(e, v))
    if not ok then die(werr) end
    for _, a in ipairs(e.aliases or {}) do common.rc_set(path, a, nil) end
    io.write(("%s=%s → %s\n"):format(e.env, settings.show(e, v), home_path(path)))

    if user and (files.project[e.env] or "") ~= "" then
        io.write(("  This project's .luamemorc sets %s too — that value wins here.\n"):format(e.env))
    end
    if e.headers then
        local wanted = {}
        for _, value in pairs(v) do
            for ref in tostring(value):gmatch("{secret:([%w%.%-_]+)}") do wanted[#wanted + 1] = ref end
        end
        if #wanted > 0 then
            local have = vault_names(cfg)
            for _, ref in ipairs(wanted) do
                if not have then
                    io.write(("  {secret:%s} is read from this database's vault when a request is made "
                        .. "(memo secret-list shows what is stored).\n"):format(ref))
                elseif not have[ref] then
                    io.write(("  No secret named %s is stored yet: memo secret-store %s\n"):format(ref, ref))
                end
            end
        end
    end
    local changed = before ~= settings.format(e, v)
    if e.reembed and changed then
        io.write("  Memories already stored keep vectors from the previous embedder: run memo reembed --all.\n")
    end
    io.write("  A running MCP server picks this up when it restarts (reconnect it in your client).\n")
end

local function cmd_unset(name, user)
    local e = entry_of(name)
    local files = settings.files()
    local which = user and "user" or "project"
    local path = files.paths[which]
    local present = false
    for _, n in ipairs({ e.env, unpack(e.aliases or {}) }) do
        if files[which][n] ~= nil then present = true end
    end
    if not present then
        io.write(("%s is not set in %s\n"):format(e.env, home_path(path)))
        return
    end
    local common = require("luamemo.cli._common")
    for _, n in ipairs({ e.env, unpack(e.aliases or {}) }) do
        local ok, err = common.rc_set(path, n, nil)
        if not ok then die(err) end
    end
    -- What is in force now (as shown: never a credential).
    local function shown(raw)
        local v = settings.parse(e, raw)
        return v ~= nil and settings.show(e, v) or "(an invalid value)"
    end
    local after
    if user and files.project[e.env] then
        after = "this project's .luamemorc sets " .. shown(files.project[e.env])
    elseif not user and files.user[e.env] then
        after = "~/.luamemorc sets " .. shown(files.user[e.env])
    elseif settings.implied(e, {}) ~= nil then
        after = "the default applies: " .. settings.show(e, settings.implied(e, {}))
    else
        after = "unset"
    end
    io.write(("%s removed from %s — %s\n"):format(e.env, home_path(path), after))
    io.write("  A running MCP server picks this up when it restarts (reconnect it in your client).\n")
end

local function cmd_check()
    local _, problems = current()
    local files = settings.files()
    if files.untrusted then
        problems[#problems + 1] = settings.untrusted_message(home_path(files.paths.project), files.untrusted)
    end
    if files.user_only then
        problems[#problems + 1] = settings.user_only_message(home_path(files.paths.project), files.user_only)
    end
    if #problems == 0 then io.write("settings OK\n"); return end
    for _, p in ipairs(problems) do io.write("warning: ", p, "\n") end
    os.exit(1)
end

-- memo config trust: use this project's .luamemorc, as it is now, although memo didn't
-- write it (committed to git, downloaded with the project, edited by hand) — shown
-- first, for review.
local function cmd_trust()
    local path = settings.files().paths.project
    local f = io.open(path, "r")
    if not f then die("this project has no .luamemorc") end
    f:close()
    if settings.trusted(path) then
        io.write(("%s is in use as it is (memo wrote it, or you trusted it); nothing to trust.\n")
            :format(home_path(path)))
        return
    end
    io.write(("Trusting %s as it is now:\n"):format(home_path(path)))
    local raw = settings.read_file(path)
    local names = {}
    for k in pairs(raw) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        local e = settings.get(k)
        local v = e and settings.parse(e, raw[k])
        io.write(("  %s=%s\n"):format(k, e and (v ~= nil and settings.show(e, v) or "(an invalid value)")
            or "(not a luamemo setting)"))
    end
    local ok, err = settings.trust(path)
    if not ok then die(err) end
    io.write("Trusted. If the file changes (a git pull, an edit), memo stops using it until you trust it "
        .. "again — memo's own changes (memo config set, calibrate) keep it trusted.\n")
end

function M.run(argv)
    local pos, user, json_out, md_out = {}, false, false, false
    for _, a in ipairs(argv) do
        if a == "--user" then user = true
        elseif a == "--json" then json_out = true
        elseif a == "--markdown" then md_out = true
        elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
        else pos[#pos + 1] = a end
    end
    local sub = pos[1] or "list"
    if sub == "list" and #pos <= 1 and md_out and not json_out then io.write(M.markdown()); return
    elseif sub == "list" and #pos <= 1 and not md_out then return cmd_list(json_out)
    elseif sub == "get" and #pos == 2 then return cmd_get(pos[2])
    elseif sub == "set" and #pos == 3 then return cmd_set(pos[2], pos[3], user)
    elseif sub == "unset" and #pos == 2 then return cmd_unset(pos[2], user)
    elseif sub == "check" and #pos == 1 then return cmd_check()
    elseif sub == "trust" and #pos == 1 then return cmd_trust()
    end
    io.stderr:write(USAGE)
    os.exit(2)
end

return M
