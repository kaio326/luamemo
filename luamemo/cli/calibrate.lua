-- luamemo.cli.calibrate
--
-- `memo calibrate` — host probe, corpus health, and codebase ingest.
-- Supersedes `memo init`.
--
-- Runs in two modes depending on the flags passed:
--
--   Probe mode (default, no server required):
--     Probes GPU/RAM/Docker/Ollama, asks two questions, and prints a
--     setup({}) snippet for the best-fit embedder. Same as old memo init.
--     If MEMO_URL is not set, the command stops after the probe.
--
--   Scan mode (--scan flag, called by the bash wrapper internally):
--     Scans the project for architectural knowledge and outputs one JSON
--     memory-write payload per line (NDJSON) to stdout. The bash wrapper
--     pipes each line to POST /write. All scan progress goes to stderr.
--
-- Sources scanned (Phase 3):
--   1. Agent instruction files (.github/copilot-instructions.md, AGENTS.md, …)
--   2. ADR / decision documents in docs/adr/, decisions/, rfcs/, …
--   3. Top-level markdown: README.md, ARCHITECTURE.md, CONTRIBUTING.md, …
--   4. Source comments tagged ARCH:, DECISION:, DESIGN:
--   5. Git commit messages (architectural language filter)
--
-- Flags (parsed by run()):
--   --root DIR          project root for scanning (default ".")
--   --scope SCOPE       memory scope (set by bash wrapper before --scan)
--   --since-commit SHA  ingest only git commits after this SHA
--   --no-git            skip git commit scanning
--   --no-comments       skip tagged source comment scanning
--   --scan              enter scan/output mode (internal; used by bash wrapper)
--   --probe-only        run probe + recommendation only, then exit
--   --non-interactive   use flag-supplied answers, do not prompt
--   --multilingual      treat content as multilingual
--   --long              treat rows as long-form (>4k chars)
--   --hosted            permit hosted-API recommendations
--   --allow-hash        permit the hash fallback
--   --write PATH        also write the config snippet to PATH

local cjson     = require("cjson.safe")
local probe     = require("luamemo.cli.probe")
local recommend = require("luamemo.cli.recommend")

local M = {}

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return c
end

local function pread(cmd)
    local f = io.popen(cmd .. " 2>/dev/null")
    if not f then return "" end
    local out = f:read("*a") or ""; f:close()
    return out:gsub("%s+$", "")
end

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function truncate(s, n)
    if #s <= n then return s end
    return s:sub(1, n) .. "\n[…truncated]"
end

-- ---------------------------------------------------------------------------
-- NDJSON emitter
-- Each call prints one JSON line to stdout for the bash wrapper to POST.
-- ---------------------------------------------------------------------------

local function emit(scope, kind, title, body, importance, tags, meta)
    if not title or trim(title) == "" then return end
    body = trim(body or "")
    if #body < 20 then return end   -- skip trivial stubs
    print(cjson.encode({
        scope          = scope,
        kind           = kind or "fact",
        title          = trim(title):sub(1, 200),
        body           = truncate(body, 4000),
        importance     = importance or 2,
        decay_rate     = 0,
        tags           = tags or {},
        metadata       = meta or {},
        dedup_strategy = "update",   -- reruns refresh content, never duplicate
    }))
end

-- ---------------------------------------------------------------------------
-- Markdown section splitter
-- Splits on any heading level (# / ## / ###). Sections with < 40 chars of
-- body are skipped (badges, blank intros, etc.).
-- ---------------------------------------------------------------------------

local function split_md(content, default_title)
    local sections = {}
    local cur_title = default_title or "Overview"
    local cur_lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local h = line:match("^#+%s+(.+)")
        if h then
            local body = trim(table.concat(cur_lines, "\n"))
            if #body > 40 then
                table.insert(sections, { title = trim(cur_title), body = body })
            end
            cur_title = h
            cur_lines = {}
        else
            table.insert(cur_lines, line)
        end
    end
    local body = trim(table.concat(cur_lines, "\n"))
    if #body > 40 then
        table.insert(sections, { title = trim(cur_title), body = body })
    end
    return sections
end

-- ---------------------------------------------------------------------------
-- Source 1: Agent instruction files
-- Importance = 5 — these are authoritative; agents trust them above all else.
-- ---------------------------------------------------------------------------

local AGENT_FILES = {
    ".github/copilot-instructions.md",
    ".cursorrules",
    "AGENTS.md",
    "CLAUDE.md",
    ".cursor/rules",
    ".aider.conf.yml",
    ".copilot/instructions.md",
}

local function scan_agent_files(root, scope)
    for _, rel in ipairs(AGENT_FILES) do
        local path = root .. "/" .. rel
        local content = read_file(path)
        if content and #content > 50 then
            io.stderr:write("  [agent-file] " .. rel .. "\n")
            local sections = split_md(content, rel)
            if #sections == 0 then
                emit(scope, "fact",
                    "Agent instructions: " .. rel,
                    content, 5, { "calibrate", "agent-instructions" },
                    { source = rel, calibrate = true })
            else
                for _, sec in ipairs(sections) do
                    emit(scope, "fact",
                        "Agent instructions / " .. sec.title,
                        sec.body, 5, { "calibrate", "agent-instructions" },
                        { source = rel, section = sec.title, calibrate = true })
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Source 2: ADR / decision documents
-- Importance = 4 — explicit, dated architectural decisions.
-- ---------------------------------------------------------------------------

local ADR_DIRS = { "docs/adr", "docs/decisions", "adr", "decisions", "rfcs" }

local function scan_adr_files(root, scope)
    for _, dir in ipairs(ADR_DIRS) do
        local ls = pread(string.format(
            "find %s/%s -maxdepth 2 -name '*.md' -type f 2>/dev/null | sort",
            root, dir))
        for path in ls:gmatch("[^\n]+") do
            local content = read_file(path)
            if content and #content > 50 then
                local filename = path:match("([^/]+)$") or path
                local title = content:match("^#%s+(.-)%s*\n")
                    or filename:gsub("%.md$", ""):gsub("^%d+[-_]", ""):gsub("[-_]", " ")
                io.stderr:write("  [adr] " .. path .. "\n")
                emit(scope, "decision",
                    "ADR: " .. trim(title),
                    truncate(content, 4000), 4, { "calibrate", "adr" },
                    { source = path, calibrate = true })
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Source 3: Top-level documentation markdown
-- Importance = 3 — project-level context, less authoritative than ADRs.
-- ---------------------------------------------------------------------------

local README_FILES = {
    "README.md", "CONTRIBUTING.md", "ARCHITECTURE.md",
    "DESIGN.md", "DEVELOPMENT.md", "OVERVIEW.md",
}

local function scan_readme_files(root, scope)
    for _, name in ipairs(README_FILES) do
        local path = root .. "/" .. name
        local content = read_file(path)
        if content and #content > 100 then
            io.stderr:write("  [readme] " .. name .. "\n")
            local label = name:gsub("%.md$", "")
            local sections = split_md(content, label)
            for _, sec in ipairs(sections) do
                -- Skip sections that are pure badge/image lines or very short
                local non_badge = sec.body:gsub("%[!%[.-%]%(.-%)", ""):gsub("%s", "")
                if #non_badge > 60 then
                    emit(scope, "fact",
                        label .. ": " .. sec.title,
                        sec.body, 3, { "calibrate", "readme" },
                        { source = name, section = sec.title, calibrate = true })
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Source 4: Source comments tagged ARCH:, DECISION:, DESIGN:
-- Importance = 3 — inline rationale is high-signal.
-- ---------------------------------------------------------------------------

local function scan_source_comments(root, scope)
    local cmd = string.format(
        "grep -rn -E '(ARCH|DECISION|DESIGN):[[:space:]]' %s"
        .. " --include='*.lua' --include='*.py' --include='*.js' --include='*.ts'"
        .. " --include='*.go'  --include='*.rb' --include='*.rs' --include='*.java'"
        .. " --include='*.c'   --include='*.cpp' --include='*.h' --include='*.ex'"
        .. " --include='*.exs' --include='*.clj' --include='*.scala'"
        .. " --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor"
        .. " --exclude-dir=.venv --exclude-dir=dist --exclude-dir=build"
        .. " 2>/dev/null | head -300",
        root)

    local out = pread(cmd)
    if out == "" then return end

    -- Group adjacent lines from the same file into a single memory.
    local last_file, last_lnum = nil, -99
    local block_lines, block_tag, block_lnum = {}, nil, nil

    local function flush()
        if #block_lines > 0 and last_file then
            local tag = block_tag or "ARCH"
            local body = table.concat(block_lines, "\n")
                .. "\n\n(source: " .. last_file .. ":" .. tostring(block_lnum) .. ")"
            io.stderr:write("  [comment] " .. last_file .. ":" .. tostring(block_lnum) .. "\n")
            emit(scope, "decision",
                tag .. ": " .. trim(block_lines[1]):sub(1, 150),
                body, 3, { "calibrate", "source-comment", tag:lower() },
                { source = last_file, line = block_lnum, calibrate = true })
        end
        block_lines = {}; block_tag = nil; block_lnum = nil
    end

    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        local file, lnum, content = line:match("^([^:]+):(%d+):(.+)$")
        if file and lnum and content then
            lnum = tonumber(lnum)
            if file ~= last_file or (lnum - last_lnum) > 5 then
                flush()
                last_file = file
            end
            last_lnum = lnum
            local tag = content:match("(ARCH|DECISION|DESIGN):")
            if not block_tag and tag then block_tag = tag end
            if not block_lnum then block_lnum = lnum end
            -- Strip comment sigils
            local stripped = content:match("^%s*[%-#/*]+%s*(.+)") or content
            table.insert(block_lines, trim(stripped))
        end
    end
    flush()
end

-- ---------------------------------------------------------------------------
-- Source 5: Git commit messages (architectural language filter)
-- Importance = 2 — useful context, but noisier than explicit docs.
-- ---------------------------------------------------------------------------

local ARCH_WORDS = {
    "arch", "design", "decision", "refactor", "rewrite", "breaking",
    "remove", "deprecat", "replac", "migrat", "restructur", "redesign",
    "extract", "introduce", "abandon", "rethink",
}

local function is_architectural(subject)
    local lo = subject:lower()
    if lo:match("^feat:") or lo:match("^feat%(") then return true end
    if lo:match("^refactor:") or lo:match("^refactor%(") then return true end
    if lo:match("^chore:") and #subject > 60 then return true end
    for _, w in ipairs(ARCH_WORDS) do
        if lo:find(w, 1, true) then return true end
    end
    return #subject > 100  -- long commit subjects are usually significant
end

local function scan_git_commits(root, scope, since_sha, limit)
    limit = limit or 200
    local range
    if since_sha and since_sha ~= "" then
        range = since_sha .. "..HEAD"
    else
        range = "HEAD~" .. limit .. "..HEAD"
    end
    local cmd = string.format(
        "git -C %s log %s --no-merges --format='%%H\t%%as\t%%s' 2>/dev/null | head -%d",
        root, range, limit)
    local out = pread(cmd)
    if out == "" then return end

    local count = 0
    for line in (out .. "\n"):gmatch("([^\n]+)") do
        local sha, date, subject = line:match("^([0-9a-f]+)\t([^\t]+)\t(.+)$")
        if sha and subject and is_architectural(subject) then
            io.stderr:write("  [git] " .. sha:sub(1, 7) .. " " .. subject:sub(1, 60) .. "\n")
            emit(scope, "fact",
                "git: " .. subject:sub(1, 180),
                subject .. "\n\ncommit: " .. sha .. "\ndate: " .. date,
                2, { "calibrate", "git-commit" },
                { commit = sha, date = date, calibrate = true })
            count = count + 1
        end
    end
    if count > 0 then
        io.stderr:write("  " .. count .. " architectural commits found\n")
    end
end

-- ---------------------------------------------------------------------------
-- Probe-mode helpers (identical to old init.lua)
-- ---------------------------------------------------------------------------

local function fmt_snippet(rec)
    local lines = { 'require("luamemo").setup({' }
    local order = {
        "embedder_local", "embedder_adapter", "embedder_url",
        "embedder_model", "embed_dim", "embed_max_chars", "embedder_headers",
    }
    for _, key in ipairs(order) do
        local v = rec.setup_keys[key]
        if v ~= nil then
            if type(v) == "string" then
                table.insert(lines, string.format("    %s = %q,", key, v))
            elseif type(v) == "number" then
                table.insert(lines, string.format("    %s = %d,", key, v))
            elseif type(v) == "table" then
                local parts = {}
                for k, vv in pairs(v) do
                    table.insert(parts, string.format("%s = %q", k, vv))
                end
                table.insert(lines, string.format("    %s = { %s },",
                    key, table.concat(parts, ", ")))
            end
        end
    end
    table.insert(lines, "    corpus_health_check = true,")
    table.insert(lines, '    auth_fn = function() return false end,  -- private by default')
    table.insert(lines, "})")
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Flag parser
-- ---------------------------------------------------------------------------

local function parse_flags(argv)
    local f = {
        root            = ".",
        scope           = "global",
        since_commit    = nil,
        no_git          = false,
        no_comments     = false,
        scan_mode       = false,
        probe_only      = false,
        multilingual    = false,
        long            = false,
        hosted          = false,
        allow_hash      = false,
        write           = nil,
    }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if     a == "--root"            then f.root = argv[i+1];         i = i+1
        elseif a == "--scope"           then f.scope = argv[i+1];        i = i+1
        elseif a == "--since-commit"    then f.since_commit = argv[i+1]; i = i+1
        elseif a == "--no-git"          then f.no_git = true
        elseif a == "--no-comments"     then f.no_comments = true
        elseif a == "--scan"            then f.scan_mode = true
        elseif a == "--probe-only"      then f.probe_only = true
        elseif a == "--non-interactive" then  -- no-op: calibrate is always non-interactive
        elseif a == "--multilingual"    then f.multilingual = true
        elseif a == "--long"            then f.long = true
        elseif a == "--hosted"          then f.hosted = true
        elseif a == "--allow-hash"      then f.allow_hash = true
        elseif a == "--write"           then f.write = argv[i+1]; i = i+1
        else
            io.stderr:write("memo calibrate: unknown flag: " .. a .. "\n")
            os.exit(2)
        end
        i = i + 1
    end
    return f
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

function M.run(argv)
    local flags = parse_flags(argv or {})

    -- ── SCAN MODE ─────────────────────────────────────────────────────────
    -- Outputs NDJSON (one JSON object per line) to stdout.
    -- Progress messages go to stderr so bash can pipe stdout cleanly.
    if flags.scan_mode then
        local scope = flags.scope
        local root  = flags.root
        io.stderr:write("memo calibrate: scanning " .. root
            .. " → scope=" .. scope .. "\n")

        scan_agent_files(root, scope)
        scan_adr_files(root, scope)
        scan_readme_files(root, scope)
        if not flags.no_comments then
            scan_source_comments(root, scope)
        end
        if not flags.no_git then
            scan_git_commits(root, scope, flags.since_commit)
        end
        return
    end

    -- ── PROBE MODE ────────────────────────────────────────────────────────
    -- Detects host capabilities and recommends an embedder configuration.

    io.write("memo calibrate — host probe\n")
    io.write("============================\n\n")

    local gpu    = probe.gpu()
    local docker = probe.docker()
    local ollama = probe.ollama()
    local ram    = probe.ram_mb()
    local scan   = probe.scan_project(flags.root)

    io.write(string.format("  GPU:    %s\n",
        gpu.ok
            and string.format("%s (%d MiB free)", gpu.value.name, gpu.value.free_mb)
            or  ("none (" .. gpu.err .. ")")))
    io.write(string.format("  Docker: %s\n",
        docker.ok and ("ok, " .. docker.value) or ("none (" .. docker.err .. ")")))
    io.write(string.format("  Ollama: %s\n",
        ollama.ok and ("reachable at " .. ollama.value) or ("none (" .. ollama.err .. ")")))
    io.write(string.format("  RAM:    %s\n",
        ram.ok and (ram.value .. " MiB available") or ("unknown (" .. ram.err .. ")")))

    io.write("\nProject scan (root=" .. flags.root .. "):\n")
    if #scan.ext_census == 0 then
        io.write("  no files found\n")
    else
        for i = 1, math.min(5, #scan.ext_census) do
            local e = scan.ext_census[i]
            io.write(string.format("  .%-10s  %d files\n", e.ext, e.count))
        end
    end
    if scan.multilingual_hint then
        io.write("  i18n/locales directory detected → multilingual likely\n")
    end
    io.write("\n")

    -- Calibrate is always non-interactive: use scan hints + explicit flags.
    -- Pass --multilingual / --long / --hosted / --allow-hash to override.
    local multilingual = flags.multilingual or scan.multilingual_hint or false
    local long         = flags.long   or false
    local hosted       = flags.hosted or false
    local allow_hash   = flags.allow_hash or false

    local profile = {
        has_gpu      = gpu.ok,
        gpu_free_mb  = gpu.ok and gpu.value.free_mb or 0,
        has_docker   = docker.ok,
        has_ollama   = ollama.ok,
        ram_mb       = ram.ok and ram.value or 0,
        multilingual = multilingual,
        long_rows    = long,
        allow_hosted = hosted,
        allow_hash   = allow_hash or flags.allow_hash,
    }

    local rec, err = recommend.decide(profile)
    if not rec then
        io.stderr:write("\nNo recommendation possible:\n  " .. err .. "\n")
        os.exit(1)
    end

    io.write("\nRecommendation:\n")
    io.write(string.format("  adapter:         %s\n", rec.adapter))
    io.write(string.format("  model:           %s\n", rec.model))
    io.write(string.format("  embed_dim:       %d\n", rec.dim))
    if rec.embed_max_chars then
        io.write(string.format("  embed_max_chars: %d\n", rec.embed_max_chars))
    end
    if rec.tei_image then
        io.write(string.format("  tei image:       %s\n", rec.tei_image))
    end
    io.write("\nRationale:\n")
    for _, r in ipairs(rec.rationale) do
        io.write("  - " .. r .. "\n")
    end

    local snippet = fmt_snippet(rec)
    io.write("\nSnippet (paste into your app startup):\n\n")
    io.write(snippet .. "\n")

    if flags.write then
        local f, ferr = io.open(flags.write, "w")
        if not f then
            io.stderr:write("\nmemo calibrate: failed to write "
                .. flags.write .. ": " .. tostring(ferr) .. "\n")
            os.exit(1)
        end
        f:write(snippet .. "\n"); f:close()
        io.write("\nWrote: " .. flags.write .. "\n")
    end

    if flags.probe_only then
        io.write("\nRun `memo calibrate` (without --probe-only) to also ingest"
            .. " codebase decisions into the memory store.\n")
    end
end

return M
