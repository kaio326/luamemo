-- luamemo.cli.agent
--
-- `memo agent` — make luamemo the agent's memory without the user configuring anything by hand.
-- For Claude Code (the only client with a hook API today):
--
--   memo agent install [--with-transcripts | --no-transcripts] [--dry-run] [--no-notes] [--force]
--       · copies the hook scripts (hooks/claude/) to <data dir>/hooks/claude — $XDG_DATA_HOME/luamemo, else
--         ~/.local/share/luamemo; a path that survives a LuaRocks upgrade — and wires them into
--         ~/.claude/settings.json:
--           SessionStart      session_start.sh      the brief, injected into the session
--           UserPromptSubmit  user_prompt.sh        what the user says → memo sense (corrections, rules)
--           PreToolUse        block_file_memory.sh  no file memory in a project that uses luamemo
--         (--with-transcripts also: PreCompact pre_compact.sh, PostToolUse post_message.sh — the
--         conversation's last messages saved as tier-0 memories. They stay wired on later runs; --no-transcripts
--         takes them out);
--       · writes a marked block into ~/.claude/CLAUDE.md telling the agent luamemo is its memory;
--       · imports the project's existing Claude Code memory notes (import-notes).
--     Settings are merged, never replaced: other hooks and keys stay, in their order; ours are recognised by the
--     "luamemo-agent" marker on their command (or by a script of luamemo's own: a path with /luamemo/ and
--     /hooks/claude/), so a second run changes nothing and an upgrade replaces them. A symlinked settings.json is
--     written through and keeps its mode; the original is copied once to settings.json.luamemo-bak. When the
--     luamemo PLUGIN is enabled it already ships the hooks: only the CLAUDE.md block and the import are done.
--     Claude Code is looked for in ~/.claude (or $CLAUDE_CONFIG_DIR); absent, nothing is done (--force creates it).
--   memo agent uninstall [--dry-run]     removes the hooks, the CLAUDE.md block and the script copies. It does not
--                                        move notes back, delete imported memories, the backup, or the MEMORY.md
--                                        pointer (move memory-archive-DATE/*.md back and delete MEMORY.md to
--                                        return to Claude Code's file memory)
--   memo agent status                    what is installed, what is stale, what could be imported
--   memo agent import-notes [--dir PATH] [--dry-run]
--       the project's Claude Code memory notes (~/.claude/projects/<project>/memory/*.md) become luamemo memories
--       (kind by the note's type, source=claude-memory-import; a note whose text changed since its import updates
--       that memory); the originals, and the old MEMORY.md, are then moved to memory-archive-DATE (a name already
--       there is never overwritten) and MEMORY.md becomes a pointer — only when every note was imported and moved.
--
-- The environment `memo` gives it: MEMO__BIN (this memo), MEMO__HOOKS_DIR (the shipped hooks/),
-- MEMO__PROJECT_DIR (the project). Needs jq (for the settings merge — it keeps the file's key order).

local util = require("luamemo.util")
local sh = util.shell_quote
local die = require("luamemo.cli._common").die_for("agent", 1)

local M = {}

local MARK = "luamemo-agent"
local BEGIN_MARK, END_MARK = "<!-- luamemo:begin", "<!-- luamemo:end -->"
-- The hooks: event, the script in hooks/claude/, timeout (s), matcher; `transcripts` ones are opt-in.
local HOOKS = {
    { event = "SessionStart",     script = "session_start.sh",     timeout = 10 },
    { event = "UserPromptSubmit", script = "user_prompt.sh",       timeout = 5 },
    { event = "PreToolUse",       script = "block_file_memory.sh", timeout = 5, matcher = "Write|Edit|NotebookEdit" },
    { event = "PreCompact",       script = "pre_compact.sh",       timeout = 10, transcripts = true },
    { event = "PostToolUse",      script = "post_message.sh",      timeout = 10, matcher = "*", transcripts = true },
}
-- (sourced by the scripts above, so copied with them)
local SHARED = { "_project.sh" }
local SHARED_TRANSCRIPTS = { "_save.sh" }

-- (short on purpose: this file is read in every session of every project; how to use the tools is in the MCP
-- instructions luamemo's server sends, which are only there when luamemo is)
M.CLAUDE_MD_BLOCK = BEGIN_MARK .. " (written by `memo agent install`; `memo agent uninstall` removes it) -->\n"
    .. "## Memory: luamemo\n\n"
    .. "When the luamemo MCP tools (memory_search, memory_write, memory_sense …) are available, luamemo is the one place for\n"
    .. "durable memory: decisions, facts, plans, what the user teaches you. Do not keep memory in files under\n"
    .. "`~/.claude/projects/*/memory/`; if the tools are missing, say so rather than falling back to files.\n"
    .. END_MARK .. "\n"

-- ── small helpers ───────────────────────────────────────────────────────────

local function home() return util.env("HOME") or "." end
function M.claude_home() return util.env("CLAUDE_CONFIG_DIR") or (home() .. "/.claude") end
local function settings_path() return M.claude_home() .. "/settings.json" end
local function claude_md_path() return M.claude_home() .. "/CLAUDE.md" end
-- Where the hook copies live: a path that outlives the LuaRocks version that shipped them.
function M.hooks_copy_dir() return require("luamemo.db").data_dir() .. "/hooks" end

-- Run a shell command → whether it exited 0, its output (stderr included). (popen's close() does not
-- say, in Lua 5.1 / LuaJIT without 5.2 compatibility: the status is asked of the shell.)
local function run(cmd)
    local p = io.popen(cmd .. " 2>&1; echo \"@@EXIT=$?\"")
    local out = p:read("*a") or ""
    p:close()
    local code = tonumber(out:match("@@EXIT=(%d+)%s*$"))
    return code == 0, (out:gsub("@@EXIT=%d+%s*$", ""))
end

local read = util.read_file
local function mkdir_p(dir) util.private_dir(dir) end

-- Write a file by renaming a finished temporary one over it. A symlink is written THROUGH (a dotfiles link stays a
-- link), and the file keeps its mode and owner (a 0600 settings.json does not become 0644): the temporary starts as
-- a `cp -p` of the file.
local function write_atomic(path, text)
    local target = util.realpath(path) or path
    local tmp = target .. ".luamemo-tmp"
    if util.exists(target) then os.execute("cp -p " .. sh(target) .. " " .. sh(tmp) .. " 2>/dev/null") end
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    f:write(text); f:close()
    local ok, rerr = os.rename(tmp, target)
    if not ok then os.remove(tmp); return nil, rerr end
    return true
end

-- A copy of the file beside it, with its mode (the original of settings.json may hold tokens in its env block); the
-- first one stays.
local function backup(path, suffix)
    local dst = path .. suffix
    if util.exists(dst) or not util.exists(path) then return end
    os.execute("cp -p " .. sh(util.realpath(path) or path) .. " " .. sh(dst) .. " 2>/dev/null")
end

local function has_jq() return (run("command -v jq")) end

local function memo_bin()
    return util.env("MEMO__BIN") or die("MEMO__BIN is not set — run it as `memo agent …`", 2)
end

-- The directory holding the shipped scripts: <hooks>/claude.
local function shipped_dir()
    local h = util.env("MEMO__HOOKS_DIR")
    if h and util.exists(h .. "/claude/user_prompt.sh") then return h .. "/claude" end
    -- (memo agent and memo doctor both pass it; this is only for a caller that does not: a checkout's memo has hooks/
    -- two levels up from cli/memo)
    local bin = util.env("MEMO__BIN")
    local beside = bin and bin:match("^(.*)/cli/[^/]+$")
    if beside and util.exists(beside .. "/hooks/claude/user_prompt.sh") then return beside .. "/hooks/claude" end
    return nil
end

-- ── the hook scripts' copies ────────────────────────────────────────────────

-- The hooks to wire (and the files they need) → list, files
local function wanted(transcripts)
    local hooks, files = {}, {}
    for _, f in ipairs(SHARED) do files[#files + 1] = f end
    if transcripts then for _, f in ipairs(SHARED_TRANSCRIPTS) do files[#files + 1] = f end end
    for _, h in ipairs(HOOKS) do
        if transcripts or not h.transcripts then hooks[#hooks + 1] = h; files[#files + 1] = h.script end
    end
    return hooks, files
end

-- Copy the scripts the install needs → how many were written (changed or new), the directory.
local function copy_scripts(src, files, dry)
    local dst = M.hooks_copy_dir() .. "/claude"
    local changed = 0
    if not dry then mkdir_p(dst) end
    for _, f in ipairs(files) do
        local new, old = read(src .. "/" .. f), read(dst .. "/" .. f)
        if not new then die("the shipped hook " .. f .. " is missing from " .. src) end
        if new ~= old then
            changed = changed + 1
            if not dry then
                local ok, err = write_atomic(dst .. "/" .. f, new)
                if not ok then die("could not write " .. dst .. "/" .. f .. ": " .. tostring(err)) end
                os.execute("chmod 755 " .. sh(dst .. "/" .. f))
            end
        end
    end
    return changed, dst
end

local function command_for(script, memo)
    return ("MEMO_BIN=%s %s # %s"):format(sh(memo), sh(M.hooks_copy_dir() .. "/claude/" .. script), MARK)
end

-- ── ~/.claude/settings.json (merged with jq: the file's key order stays) ────

-- A hook command is ours when it carries the marker, or is one of luamemo's own scripts wired by hand (a path
-- through /luamemo/ and /hooks/claude/ — the checkout, the rock, the copies), or the earlier hand-made guard by its
-- name. Another tool's script that happens to be called user_prompt.sh is not.
local JQ_DEFS = [[
def ours: type == "object" and ((.command // "") | (contains("luamemo-agent")
    or (contains("/luamemo/") and contains("/hooks/claude/")) or contains("block-file-memory.sh")));
def strip: map(if (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end)
    | map(select((.hooks | type) != "array" or (.hooks | length) > 0));
def strip_all: if (.hooks | type) == "object"
    then .hooks |= (with_entries(.value |= (if type == "array" then strip else . end))
        | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
    else . end
  | if .hooks == {} then del(.hooks) else . end;
]]
local JQ_INSTALL = JQ_DEFS .. [[
strip_all | .hooks = ((.hooks // {}) | reduce $ours[] as $o (.;
    .[$o.event] = ((.[$o.event] // []) + [ (if $o.matcher then {matcher: $o.matcher} else {} end)
        + {hooks: [ {type: "command", command: $o.command, timeout: $o.timeout} ]} ])))
]]
local JQ_UNINSTALL = JQ_DEFS .. "strip_all"

local function jq_on(path, filter, args)
    return run("jq " .. (args or "") .. " " .. sh(filter) .. " " .. sh(path))
end

-- The settings file's text | nil when absent; dies when it is not JSON (never overwritten then).
local function read_settings()
    local path = settings_path()
    local text = read(path)
    if not text then return nil end
    local ok, out = jq_on(path, ".")
    if not ok then die(path .. " is not valid JSON — fix it, then run this again (" .. out:gsub("%s+$", "") .. ")") end
    return text
end

-- Is the luamemo plugin enabled (it ships the hooks itself)?
local function plugin_enabled()
    local path = settings_path()
    if not util.exists(path) then return false end
    local ok, out = jq_on(path, '[(.enabledPlugins // {}) | to_entries[] | select((.key | test("luamemo")) and .value == true)] | length', "-r")
    return ok and (tonumber(out:match("%d+")) or 0) > 0
end

-- A SessionStart hook that injects the brief already exists in the project's own settings?
local function project_wires_brief(project)
    for _, f in ipairs({ "/.claude/settings.json", "/.claude/settings.local.json" }) do
        local p = project .. f
        if util.exists(p) then
            local ok, out = jq_on(p, '[(.hooks.SessionStart // [])[] | .hooks[]? | .command // "" | select(contains("brief"))] | length', "-r")
            if ok and (tonumber(out:match("%d+")) or 0) > 0 then return true end
        end
    end
    return false
end

-- The commands of the hooks that are luamemo's (`ours`, the one definition above), one per line; "" when there are none
-- or no settings file. Whether a hook is wired, and whether the transcript hooks were, are answered from these — not
-- from the raw text: another tool's pre_compact.sh is not luamemo's.
local JQ_OURS_COMMANDS = JQ_DEFS .. [[
[(if (.hooks | type) == "object" then .hooks else {} end) | to_entries[] | .value | arrays | .[] | objects
    | .hooks | arrays | .[] | select(ours) | .command] | join("\n")
]]
local function ours_commands()
    local path = settings_path()
    if not util.exists(path) then return "" end
    local ok, out = jq_on(path, JQ_OURS_COMMANDS, "-r")
    return ok and (out:gsub("%s+$", "")) or ""
end

-- Are the transcript hooks (PreCompact, PostToolUse) luamemo's in the settings (installed by an earlier run, or wired by
-- hand as the README describes)? They stay so on a plain install; a plain install never turns them on by itself.
local function transcripts_wired(cmds)
    return cmds:find("pre_compact.sh", 1, true) ~= nil or cmds:find("post_message.sh", 1, true) ~= nil
end

local function write_settings(out, before, dry)
    local path = settings_path()
    if out == (before or "") then return false end
    if not dry then
        if before then backup(path, ".luamemo-bak") end
        mkdir_p(M.claude_home())
        local ok, err = write_atomic(path, out)
        if not ok then die("could not write " .. path .. ": " .. tostring(err)) end
    end
    return true
end

local function merge_settings(entries, dry)
    local path = settings_path()
    local before = read_settings()
    local tmp = os.tmpname()
    local src = before and path or tmp
    if not before then local f = io.open(tmp, "w"); f:write("{}"); f:close() end
    local ok, out = run(("jq --argjson ours %s %s %s"):format(sh(require("luamemo.json").encode(entries)), sh(JQ_INSTALL), sh(src)))
    os.remove(tmp)
    if not ok then die("could not merge the hooks into " .. path .. ": " .. out) end
    return write_settings(out, before, dry)
end

local function strip_settings(dry)
    local before = read_settings()
    if not before then return false end
    -- No luamemo hook in it: nothing to take out — and jq's re-serialising would only reformat the user's file.
    if ours_commands() == "" then return false end
    local ok, out = jq_on(settings_path(), JQ_UNINSTALL)
    if not ok then die("could not edit " .. settings_path() .. ": " .. out) end
    return write_settings(out, before, dry)
end

-- ── ~/.claude/CLAUDE.md (a marked block, replaced in place, never duplicated) ──

-- Where the luamemo block is: its first character, its last (the newline after the end marker included) | nil.
-- The block is the first end marker and the LAST begin marker before it: a begin marker left without an end (an edit,
-- a truncated file) is not the start of a block, and the text after it is not swallowed.
local function locate_block(text)
    local e1, e2 = text:find(END_MARK, 1, true)
    if not e1 then return nil end
    local s, from = nil, 1
    while true do
        local b = text:find(BEGIN_MARK, from, true)
        if not b or b > e1 then break end
        s, from = b, b + 1
    end
    if not s then return nil end
    if text:sub(e2 + 1, e2 + 1) == "\n" then e2 = e2 + 1 end
    return s, e2
end

local function install_block(dry)
    local path = claude_md_path()
    local text = read(path) or ""
    local s, e = locate_block(text)
    local new
    if s then
        new = text:sub(1, s - 1) .. M.CLAUDE_MD_BLOCK .. text:sub(e + 1)
    else
        new = text .. ((text ~= "" and not text:match("\n\n$")) and (text:match("\n$") and "\n" or "\n\n") or "") .. M.CLAUDE_MD_BLOCK
    end
    if new ~= text and not dry then
        mkdir_p(M.claude_home())
        local ok, err = write_atomic(path, new)
        if not ok then die("could not write " .. path .. ": " .. tostring(err)) end
    end
    return new ~= text
end

-- Take the block out, and the one blank line install put in front of it; the rest of the file is left as it is.
local function remove_block(dry)
    local path = claude_md_path()
    local text = read(path)
    if not text then return false end
    local s, e = locate_block(text)
    if not s then return false end
    local before, after = text:sub(1, s - 1), text:sub(e + 1)
    if before:match("\n\n$") and (after == "" or after:match("^\n")) then before = before:sub(1, -2) end
    local new = before .. after
    if not dry then
        -- (a file that held only the block goes; a LINK to one — dotfiles — stays, its target written empty: removing
        -- the link would leave the block in the real file)
        if new:match("^%s*$") and not util.is_symlink(path) then os.remove(path) else write_atomic(path, new) end
    end
    return true
end

-- ── the project's Claude Code memory notes → luamemo ────────────────────────

local KIND = { feedback = "decision", project = "plan", reference = "fact", user = "fact" }
local IMPORTANCE = { feedback = 5, project = 3, reference = 3, user = 5 }
local POINTER = "# Memory Index\n\nMemory for this project lives in luamemo (the `luamemo` MCP server) — not in files here.\n"
    .. "Read it with `memory_search` / `memory_brief`; save with `memory_write` and `memory_sense`.\n"
    .. "Do not create memory files in this directory.\n"

-- Where Claude Code keeps this project's file memory: ~/.claude/projects/<path with every
-- character that is not a letter or digit as '-'>/memory
function M.notes_dir(project)
    project = project or util.env("MEMO__PROJECT_DIR") or "."
    local abs = util.real_dir(project) or project
    return M.claude_home() .. "/projects/" .. abs:gsub("[^%w]", "-") .. "/memory"
end

local function list_notes(dir)
    local ok, out = run("ls -1 " .. sh(dir) .. " 2>/dev/null")
    local names = {}
    if not ok then return names end
    for name in out:gmatch("[^\n]+") do
        if name:match("%.md$") and name ~= "MEMORY.md" then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- A note's frontmatter and body → { name, description, type }, body | nil. The keys are read line by line: `type:`
-- is found flat (name / description / type) or nested under `metadata:`.
local function parse_note(text)
    local fm, body = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
    if not fm then return nil end
    local fields = {}
    for line in (fm .. "\n"):gmatch("([^\n]*)\n") do
        local key, value = line:match("^%s*([%w_%-]+):%s*(.-)%s*$")
        if key and value ~= "" and fields[key] == nil then fields[key] = value end
    end
    local desc = (fields.description or ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"):gsub('\\"', '"')
    return { name = fields.name or "", description = desc, type = fields.type or "project" },
        (body:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One note into luamemo → "imported" | "updated" (its text changed since an earlier import) | "same" | "unreadable"
-- [, why it failed]. `store` nil: a dry run, which only says what would happen.
local function import_one(store, db, scope, dir, name)
    local text = read(dir .. "/" .. name) or ""
    local fm, body = parse_note(text)
    if not fm then return "unreadable" end
    local hash = util.djb2_hex(text) .. ":" .. #text
    local prior = db and db.first("SELECT id, json_extract(metadata, '$.original_hash') AS hash FROM lm_memories "
        .. "WHERE scope = ? AND json_extract(metadata, '$.source') = 'claude-memory-import' "
        .. "AND json_extract(metadata, '$.original_file') = ? ORDER BY id DESC LIMIT 1", scope, name)
    -- (an import from before the hash was kept has none: the note is taken as the same)
    if prior and (prior.hash == nil or prior.hash == hash) then return "same" end
    if not store then return prior and "updated" or "imported" end
    local title = fm.description ~= "" and fm.description or fm.name
    if #title > 200 then title = util.cut_utf8(title, 197) .. "…" end
    local full = (fm.description ~= "" and (fm.description .. "\n\n") or "") .. body
    local metadata = { source = "claude-memory-import", original_file = name, original_type = fm.type, original_hash = hash }
    if prior then
        local row, err = store.update(prior.id, { title = title, body = full, metadata = metadata })
        return row and "updated" or "failed", err
    end
    local tags = { "imported", "claude-memory", fm.type }
    if fm.name ~= "" then tags[#tags + 1] = fm.name end
    local row, err = store.write({
        scope = scope, kind = KIND[fm.type] or "fact", title = title, body = full, importance = IMPORTANCE[fm.type] or 3,
        tags = tags, metadata = metadata, dedup_strategy = "append", no_miss = true,
    })
    return row and "imported" or "failed", err
end

-- Move the files into the archive directory, each under a name nobody has used there → how many moved, an error text | nil
local function archive_files(dir, archive, names)
    mkdir_p(archive)
    if not util.is_dir(archive) then return 0, "could not make " .. archive end
    local moved = 0
    for _, name in ipairs(names) do
        local target, n = archive .. "/" .. name, 0
        while util.exists(target) do n = n + 1; target = ("%s/%s.%d"):format(archive, name, n) end
        if os.rename(dir .. "/" .. name, target) then moved = moved + 1
        else return moved, "could not move " .. name .. " to " .. archive end
    end
    return moved
end

-- import_notes{dir, dry_run} → { notes, imported, updated, same, unreadable = {names}, archived, archive, dir, error } | nil, why
function M.import_notes(opts)
    opts = opts or {}
    local dir = opts.dir or M.notes_dir()
    local names = list_notes(dir)
    local res = { imported = 0, updated = 0, same = 0, unreadable = {}, archived = 0, dir = dir, notes = #names }
    if #names == 0 then return res end
    local scope = util.env("MEMO_SCOPE")
    local store, db
    if scope then
        local okl, lerr = pcall(require("luamemo.cli._common").setup_or_die, function(m) error(m, 0) end, {})
        if not okl then return nil, tostring(lerr) end
        db = require("luamemo.db")
        if not opts.dry_run then store = require("luamemo.store") end
    elseif not opts.dry_run then
        return nil, "no scope: this project has no MEMO_SCOPE (run memo calibrate)"
    end
    for _, name in ipairs(names) do
        local state, why = import_one(store, db, scope, dir, name)
        if state == "unreadable" then res.unreadable[#res.unreadable + 1] = name
        elseif state == "failed" then res.error = ("%s: %s"):format(name, tostring(why))
        else res[state] = res[state] + 1 end
    end
    if opts.dry_run or res.error or #res.unreadable > 0 then return res end   -- (nothing moves while a note is not in luamemo)
    -- everything is in luamemo: the notes (and an index of the user's own) move out of Claude Code's memory directory
    local files = {}
    for _, name in ipairs(names) do files[#files + 1] = name end
    local index = read(dir .. "/MEMORY.md")
    if index and index ~= POINTER then files[#files + 1] = "MEMORY.md" end
    res.archive = dir:gsub("/memory$", "") .. "/memory-archive-" .. os.date("%Y-%m-%d")
    local moved, merr = archive_files(dir, res.archive, files)
    res.archived = moved
    if merr then res.error = merr; return res end
    local ok, werr = write_atomic(dir .. "/MEMORY.md", POINTER)
    if not ok then res.error = "could not write " .. dir .. "/MEMORY.md: " .. tostring(werr) end
    return res
end

-- ── checks (status, doctor) ─────────────────────────────────────────────────

local function check_hooks(add)
    if plugin_enabled() then
        add("ok", "Claude Code: the luamemo plugin is enabled — it ships the hooks")
        return
    end
    local cmds = ours_commands()
    local hooks, files = wanted(transcripts_wired(cmds))
    local project = util.env("MEMO__PROJECT_DIR") or "."
    local missing, stale = {}, {}
    for _, h in ipairs(hooks) do
        local wired = cmds:find(h.script, 1, true) ~= nil
        if not wired and not (h.event == "SessionStart" and project_wires_brief(project)) then
            missing[#missing + 1] = h.event
        end
    end
    local src = shipped_dir()
    for _, f in ipairs(files) do
        local copy = M.hooks_copy_dir() .. "/claude/" .. f
        if not util.exists(copy) then stale[#stale + 1] = f .. " (its copy is gone)"
        elseif src and read(copy) ~= read(src .. "/" .. f) then stale[#stale + 1] = f .. " (older than the installed luamemo)" end
    end
    if #missing == 0 and #stale == 0 then
        local events = {}
        for _, h in ipairs(hooks) do events[#events + 1] = h.event end
        add("ok", "Claude Code hooks: " .. table.concat(events, ", ") .. " — wired in " .. settings_path())
        return
    end
    if #missing > 0 then add("warn", "Claude Code hooks not wired: " .. table.concat(missing, ", ") .. " — run: memo agent install") end
    if #stale > 0 then add("warn", "Claude Code hooks out of date: " .. table.concat(stale, ", ") .. " — run: memo agent install") end
end

local function check_claude_md(add)
    local md = read(claude_md_path()) or ""
    local s, e = locate_block(md)
    if not s then
        add("warn", "CLAUDE.md: no luamemo block in " .. claude_md_path() .. " — run: memo agent install")
    elseif md:sub(s, e) == M.CLAUDE_MD_BLOCK then
        add("ok", "CLAUDE.md: the luamemo block is current (" .. claude_md_path() .. ")")
    else
        add("warn", "CLAUDE.md: the luamemo block is out of date — run: memo agent install")
    end
end

local function check_notes(add)
    local dir = M.notes_dir()
    local notes = list_notes(dir)
    if #notes > 0 then
        add("warn", ("%d Claude Code memory note(s) not in luamemo yet (%s) — run: memo agent import-notes"):format(#notes, dir))
    end
end

-- The state, as { { level = "ok"|"warn"|"info", text = … }, … } (`memo agent status`, `memo doctor`).
function M.check()
    local out = {}
    local function add(level, text) out[#out + 1] = { level = level, text = text } end
    local claude = M.claude_home()
    if not util.is_dir(claude) then
        add("info", "Claude Code: not found (" .. claude .. ") — memo agent install does nothing without it")
    elseif not has_jq() then
        add("warn", "jq is not installed: the hooks and memo agent need it")
    else
        check_hooks(add); check_claude_md(add); check_notes(add)
    end
    return out
end

--- The checks as lines of text: "[OK] …", "[WARN] …", "[INFO] …".
function M.render(checks)
    local label = { ok = "OK", warn = "WARN", info = "INFO" }
    local lines = {}
    for _, c in ipairs(checks) do lines[#lines + 1] = ("[%s] %s"):format(label[c.level] or "INFO", c.text) end
    return lines
end

-- ── commands ────────────────────────────────────────────────────────────────

local function parse_flags(argv, known)
    local f = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a:sub(1, 2) ~= "--" then die("unexpected argument " .. a .. " (memo agent --help)", 2) end
        local name = a:sub(3)
        local spec = known[name]
        if not spec then die("unknown option " .. a .. " (memo agent --help)", 2) end
        if spec == "value" then f[name] = argv[i + 1] or die(a .. " needs a value", 2); i = i + 1 else f[name] = true end
        i = i + 1
    end
    return f
end

local function say(fmt, ...) io.write("  ", fmt:format(...), "\n") end

-- What an import did, as lines.
local function report_notes(res, err, dry, prefix)
    if not res then return say("%snotes: not imported — %s", prefix, tostring(err)) end
    if res.notes == 0 then return say("%snotes: no Claude Code memory notes for this project.", prefix) end
    if dry then
        say("%snotes: %d note(s) in %s: %d to import, %d to update, %d already there.", prefix, res.notes, res.dir,
            res.imported, res.updated, res.same)
    else
        say("notes: %d imported, %d updated, %d already there; %d moved to %s", res.imported, res.updated, res.same, res.archived,
            res.archive or "(nowhere yet)")
    end
    if #res.unreadable > 0 then
        say("%snotes: not readable as notes (left where they are, and nothing moved): %s", prefix, table.concat(res.unreadable, ", "))
    end
    if dry then return end
    if res.error then say("notes: %s", res.error) end
end

-- Wire the hooks (or say why not) → prints
local function wire_hooks(f, dry, memo, src, prefix)
    local transcripts = (f["with-transcripts"] or (transcripts_wired(ours_commands()) and not f["no-transcripts"])) and true or false
    local hooks, files = wanted(transcripts)
    local n, dst = copy_scripts(src, files, dry)
    say("%shook scripts: %s (%d new or updated of %d)", prefix, dst, n, #files)
    local entries, events = {}, {}
    local project = util.env("MEMO__PROJECT_DIR") or "."
    for _, h in ipairs(hooks) do
        if h.event == "SessionStart" and project_wires_brief(project) then
            say("%sSessionStart: this project's own settings already inject the brief — not added at user level.", prefix)
        else
            entries[#entries + 1] = { event = h.event, matcher = h.matcher, command = command_for(h.script, memo), timeout = h.timeout }
            events[#events + 1] = h.event
        end
    end
    local changed = merge_settings(entries, dry)
    say("%s%s: %s (%s)", prefix, settings_path(), changed and "hooks wired" or "already wired — unchanged", table.concat(events, ", "))
end

local function install(argv)
    local f = parse_flags(argv, { ["dry-run"] = true, ["with-transcripts"] = true, ["no-transcripts"] = true, ["no-notes"] = true,
        force = true, quiet = true })
    if not has_jq() then die("jq is needed (it merges Claude Code's settings.json without disturbing it)", 2) end
    local claude = M.claude_home()
    if not util.is_dir(claude) and not f.force then
        io.write("  Claude Code was not found (", claude, " does not exist) — nothing to install. (--force creates it.)\n")
        return 0
    end
    local dry = f["dry-run"] == true
    local prefix = dry and "[dry-run] " or ""
    local memo = memo_bin()
    local src = shipped_dir() or die("the hook scripts were not found (MEMO__HOOKS_DIR) — reinstall luamemo", 1)
    if plugin_enabled() then
        say("%sThe luamemo plugin is enabled in Claude Code: it already ships the hooks, so only the notes below are done.", prefix)
    else
        wire_hooks(f, dry, memo, src, prefix)
    end
    local block = install_block(dry)
    say("%s%s: %s", prefix, claude_md_path(), block and "luamemo block written" or "luamemo block already current — unchanged")
    if not f["no-notes"] then
        local res, err = M.import_notes({ dry_run = dry })
        report_notes(res, err, dry, prefix)
    end
    if not dry and not f.quiet then
        io.write("  Done. Restart Claude Code (or open /hooks once) so it reads the new hooks. `memo agent status` shows the state.\n")
    end
    return 0
end

local function uninstall(argv)
    local f = parse_flags(argv, { ["dry-run"] = true })
    if not has_jq() then die("jq is needed", 2) end
    local dry = f["dry-run"] == true
    local prefix = dry and "[dry-run] " or ""
    say("%s%s: %s", prefix, settings_path(), strip_settings(dry) and "luamemo hooks removed" or "no luamemo hooks")
    say("%s%s: %s", prefix, claude_md_path(), remove_block(dry) and "luamemo block removed" or "no luamemo block")
    local copies = M.hooks_copy_dir()
    if util.is_dir(copies) then
        if not dry then os.execute("rm -rf " .. sh(copies)) end
        say("%s%s: removed", prefix, copies)
    end
    return 0
end

local function status()
    io.write("memo agent — Claude Code integration\n")
    for _, l in ipairs(M.render(M.check())) do io.write(l, "\n") end
    return 0
end

local function import_notes(argv)
    local f = parse_flags(argv, { ["dry-run"] = true, dir = "value" })
    local res, err = M.import_notes({ dir = f.dir, dry_run = f["dry-run"] == true })
    if not res then die(err) end
    if res.notes == 0 then say("no Claude Code memory notes in %s", res.dir); return 0 end
    report_notes(res, nil, f["dry-run"] == true, f["dry-run"] and "[dry-run] " or "")
    return (res.error or #res.unreadable > 0) and 1 or 0
end

local USAGE = [[
Usage: memo agent install [--with-transcripts | --no-transcripts] [--dry-run] [--no-notes] [--force]
       memo agent uninstall [--dry-run]
       memo agent status
       memo agent import-notes [--dir PATH] [--dry-run]

Makes luamemo the agent's memory in Claude Code: hooks (the brief at session start; what you say
→ corrections and standing rules reach memory; no file memory in a luamemo project) merged into
~/.claude/settings.json, a luamemo block in ~/.claude/CLAUDE.md, and the project's existing
Claude Code memory notes moved into luamemo. memo calibrate does it (without asking; skip it
with memo calibrate --no-agent). See README.md → Session
continuity and hooks.]]

function M.run(argv)
    argv = argv or {}
    local cmd = table.remove(argv, 1)
    local code
    if cmd == "install" then code = install(argv)
    elseif cmd == "uninstall" then code = uninstall(argv)
    elseif cmd == "status" then code = status()
    elseif cmd == "import-notes" then code = import_notes(argv)
    elseif cmd == nil or cmd == "-h" or cmd == "--help" or cmd == "help" then io.write(USAGE, "\n"); code = 0
    else die("unknown command '" .. tostring(cmd) .. "' (memo agent --help)", 2) end
    os.exit(code or 0)
end

return M
