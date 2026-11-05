-- eval/corpus/notes.lua — the agent-written memories of the benchmark corpus.
--
-- What an agent saves with memory_write is prose it wrote about a project: a decision and
-- why, a plan, a rule it was given, a fact it established — 200 to 4,000 characters, tagged,
-- at importance 1–9. The closest real thing on a machine is the documentation an agent wrote
-- about that project: the owner's planner, change-log and research notes for luamemo, and the
-- memory notes the agent keeps per project. They are split into sections the way
-- `memo calibrate` splits a README (every heading, sections under 40 characters dropped,
-- bodies cut at 4,000), and each section becomes one memory whose kind, importance and tags
-- come from fixed rules over its file and heading — never from a model.
--
-- Not read: raw chat transcripts, and notes about the person (type: user, user_profile…).
--
--   load({ files = { { path, scope, role } … } }) → rows (the tables memo write takes)
--   default_files() → the notes this machine has

local M = {}

local util = require("luamemo.util")
local sh, shq = util.sh, util.shell_quote

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Sections of a Markdown text: { { title, body } … }, as calibrate splits a README.
function M.split(content, default_title)
    local sections, title, cur = {}, default_title or "Overview", {}
    local function flush()
        local body = trim(table.concat(cur, "\n"))
        if #body > 40 then sections[#sections + 1] = { title = trim(title), body = body } end
        cur = {}
    end
    local fence = false
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^```") then fence = not fence end
        local h = (not fence) and line:match("^#+%s+(.+)")
        if h then flush(); title = h else cur[#cur + 1] = line end
    end
    flush()
    return sections
end

-- The frontmatter's type of a memory note ("type: feedback"), and the text without it.
local function frontmatter(text)
    local fm, rest = text:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
    if not fm then return {}, text end
    local t = fm:match("\n%s*type:%s*(%w+)") or fm:match("^type:%s*(%w+)")
    return { type = t, name = fm:match("name:%s*([^\n]+)") }, rest
end

local function cut(s, n) return util.cut_utf8(s, n) end
local function truncate(s, n)
    if #s <= n then return s end
    return cut(s, n) .. "\n[…truncated]"
end

-- Kind and importance by role, from the heading and the file — fixed rules.
local RULES = {
    planner  = function(title) return ((title:match("^Phase") or title:lower():find("plan", 1, true)
                   or title:find("PLANNED", 1, true) or title:find("DONE", 1, true)) and "plan" or "fact"), 3 end,
    changelog = function(title) return (title:lower():find("decision", 1, true) and "decision" or "fact"), 2 end,
    research = function(title) return (title:lower():find("decision", 1, true) and "decision" or "fact"), 3 end,
    note     = function(title) return "fact", 5 end,
    rules    = function(title) return "fact", 5 end,
}

--- The note files this machine has: { { path, scope, role } … }. `roots`: { luamemo = dir,
--- projects = dir } (defaults: ~/.claude/luamemo and ~/.claude/projects).
function M.default_files(roots)
    roots = roots or {}
    local home = os.getenv("HOME") or ""
    local lm = roots.luamemo or (home .. "/.claude/luamemo")
    local pj = roots.projects or (home .. "/.claude/projects")
    local out = {}
    local function add(path, scope, role)
        if util.exists(path) then out[#out + 1] = { path = path, scope = scope, role = role } end
    end
    add(lm .. "/copilot-planer.md", "repo:luamemo", "planner")
    add(lm .. "/change-log.md", "repo:luamemo", "changelog")
    add(lm .. "/copilot-instructions.md", "repo:luamemo", "rules")
    for _, f in ipairs((function()
        local l = {}
        for p in (sh(("ls %s/research/*.md 2>/dev/null | LC_ALL=C sort"):format(shq(lm))) .. "\n"):gmatch("([^\n]+)") do l[#l + 1] = p end
        return l
    end)()) do add(f, "repo:luamemo", "research") end
    -- the per-project memory notes: the project is the directory's last words
    local PROJECTS = { ["-mnt-k-repositorios-github-luamemo"] = "luamemo", ["-mnt-k-repositorios-github-portfolio"] = "portfolio",
                       ["-root-projects-a11y-audit"] = "a11y-audit" }
    for dirname, project in pairs(PROJECTS) do
        for p in (sh(("ls %s/%s/memory/*.md 2>/dev/null | LC_ALL=C sort"):format(shq(pj), shq(dirname))) .. "\n"):gmatch("([^\n]+)") do
            local base = p:match("([^/]+)$")
            if base ~= "MEMORY.md" and not base:lower():find("user_profile", 1, true) then
                add(p, "repo:" .. project, "note")
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- Rows for the given files (opts.files, else the defaults).
function M.load(opts)
    opts = opts or {}
    local rows = {}
    for _, f in ipairs(opts.files or M.default_files(opts.roots)) do
        local text = read(f.path)
        if text then
            local fm, body = {}, text
            if f.role == "note" then fm, body = frontmatter(text) end
            if fm.type ~= "user" then
                local base = (f.path:match("([^/]+)$") or f.path):gsub("%.md$", "")
                local rule = RULES[f.role] or RULES.note
                for _, sec in ipairs(M.split(body, base)) do
                    local kind, importance = rule(sec.title)
                    rows[#rows + 1] = {
                        scope = f.scope, kind = kind, importance = importance, decay_rate = 0,
                        title = cut(trim(f.role == "note" and (fm.name or base) .. ": " .. sec.title or base .. ": " .. sec.title), 200),
                        body = truncate(sec.body, 4000),
                        tags = { "agent", f.role, base },
                        metadata = { source = f.path:match("([^/]+)$"), section = sec.title, role = f.role },
                        dedup_strategy = "update",
                    }
                end
            end
        end
    end
    return rows
end

return M
