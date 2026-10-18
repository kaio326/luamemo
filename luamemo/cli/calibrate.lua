-- luamemo.cli.calibrate
--
-- `memo calibrate` — host probe, embedder recommendation, and codebase ingest.
--
-- Runs in two modes depending on the flags passed:
--
--   Probe mode (default):
--     Probes GPU / RAM / Docker / Ollama / TEI / the in-process GGUF embedder and
--     prints the best-fit embedder as MEMO_* settings — the bash wrapper records
--     them in the project's .luamemorc (it reads them from --write PATH).
--
--   Scan mode (--scan flag, called by the bash wrapper internally):
--     Scans the project for architectural knowledge and outputs one JSON
--     memory per line (NDJSON) to stdout; the bash wrapper pipes it into
--     `api write-many`. All scan progress goes to stderr.
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
--   --allow-hash        permit the hash fallback
--   --write PATH        also write the recommended settings (MEMO_*='value' lines) to PATH

local json      = require("luamemo.json")
local probe     = require("luamemo.cli.probe")
local recommend = require("luamemo.cli.recommend")
local util      = require("luamemo.util")

local M = {}

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local read_file  = util.read_file
local trim       = util.trim
local shell_quote = util.shell_quote

-- The llama.cpp release the shim is built and tested against.
local function llama_tag() return require("luamemo.embedders.native.bundle").LLAMA_TAG end

local pread = util.sh   -- a command's output, stderr dropped, trailing whitespace trimmed

local function truncate(s, n)
    if #s <= n then return s end
    return util.cut_utf8(s, n) .. "\n[…truncated]"
end
local function cut(s, n) return util.cut_utf8(s, n) end   -- titles: on a character

-- ---------------------------------------------------------------------------
-- NDJSON emitter
-- Each call prints one JSON line to stdout for the bash wrapper to POST.
-- ---------------------------------------------------------------------------

local function emit(scope, kind, title, body, importance, tags, meta)
    if not title or trim(title) == "" then return end
    body = trim(body or "")
    if #body < 20 then return end   -- skip trivial stubs
    print(json.encode({
        scope          = scope,
        kind           = kind or "fact",
        title          = cut(trim(title), 200),
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
            shell_quote(root), shell_quote(dir)))
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
        shell_quote(root))

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
                tag .. ": " .. cut(trim(block_lines[1]), 150),
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
        shell_quote(root), shell_quote(range), limit)
    local out = pread(cmd)
    if out == "" then return end

    local count = 0
    for line in (out .. "\n"):gmatch("([^\n]+)") do
        local sha, date, subject = line:match("^([0-9a-f]+)\t([^\t]+)\t(.+)$")
        if sha and subject and is_architectural(subject) then
            io.stderr:write("  [git] " .. sha:sub(1, 7) .. " " .. subject:sub(1, 60) .. "\n")
            emit(scope, "fact",
                "git: " .. cut(subject, 180),
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

-- The recommendation as MEMO_* settings: { { NAME, value }, … } — gguf_ffi takes
-- its model file as MEMO_GGUF_MODEL, an HTTP embedder its model as MEMO_EMBEDDER_MODEL.
local function rec_settings(rec)
    local s, out = rec.setup_keys, {}
    local function add(name, v) if v ~= nil then out[#out + 1] = { name, tostring(v) } end end
    add("MEMO_EMBEDDER", s.embedder_local)
    add("MEMO_EMBEDDER_ADAPTER", s.embedder_adapter)
    add("MEMO_EMBEDDER_URL", s.embedder_url)
    add(s.embedder_local == "gguf_ffi" and "MEMO_GGUF_MODEL" or "MEMO_EMBEDDER_MODEL", s.embedder_model)
    add("MEMO_EMBED_DIM", s.embed_dim)
    add("MEMO_EMBED_MAX_CHARS", s.embed_max_chars)
    return out
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
        allow_hash      = false,
        no_gguf         = false,
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
        elseif a == "--allow-hash"      then f.allow_hash = true
        elseif a == "--no-gguf"         then f.no_gguf = true
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
    local gguf   = probe.gguf()
    -- Live readiness check (loads the model once) only when the gguf path is in play.
    local gguf_state = (gguf.ok and not flags.no_gguf) and probe.gguf_ready() or { ready = false }
    -- Embedding services count only if they answer a real embedding from this
    -- host. Skipped when the gguf embedder is ready (it is preferred anyway).
    local ollama_state, tei_state = { checked = false }, { checked = false }
    if not gguf_state.ready then
        if ollama.ok then ollama_state = probe.ollama_ready(ollama.value); ollama_state.checked = true end
        if docker.ok then tei_state = probe.tei_ready(); tei_state.checked = true end
    end
    local scan   = probe.scan_project(flags.root)

    io.write(string.format("  GPU:    %s\n",
        gpu.ok
            and string.format("%s (%d MiB free)", gpu.value.name, gpu.value.free_mb)
            or  ("none (" .. gpu.err .. ")")))
    io.write(string.format("  Docker: %s\n",
        docker.ok and ("ok, " .. docker.value) or ("none (" .. docker.err .. ")")))
    local ollama_line
    if not ollama.ok then
        ollama_line = "none (" .. ollama.err .. ")"
    elseif ollama_state.ready then
        ollama_line = ("serving %s at %s (dim %d)"):format(ollama_state.model, ollama_state.url, ollama_state.dim)
    elseif ollama_state.checked then
        ollama_line = "reachable at " .. ollama.value .. " but not serving embeddings — " .. ollama_state.reason
    else
        ollama_line = "reachable at " .. ollama.value
    end
    io.write(string.format("  Ollama: %s\n", ollama_line))
    local tei_line
    if tei_state.ready then
        tei_line = ("'%s' serving %s at %s (dim %d)"):format(tei_state.container, tei_state.model,
            tei_state.url, tei_state.dim)
    elseif tei_state.checked then
        tei_line = "none (" .. tei_state.reason .. ")"
    else
        tei_line = docker.ok and "not checked (gguf embedder is ready)" or "none (docker not available)"
    end
    io.write(string.format("  TEI:    %s\n", tei_line))
    io.write(string.format("  RAM:    %s\n",
        ram.ok and (ram.value .. " MiB available") or ("unknown (" .. ram.err .. ")")))
    local gguf_line
    if not gguf.ok then
        gguf_line = "not available (missing: " .. table.concat(gguf.missing, ", ") .. ")"
    elseif gguf_state.ready then
        gguf_line = "ready — in-process embedder works (model: " .. gguf_state.model .. ")"
    elseif flags.no_gguf then
        gguf_line = "capable (LuaJIT + C toolchain) — opted out with --no-gguf"
    else
        gguf_line = "capable (LuaJIT + C toolchain) but not set up yet — " .. gguf_state.reason
    end
    io.write(string.format("  GGUF:   %s\n", gguf_line))

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
    -- Pass --multilingual / --long / --allow-hash to override.
    local multilingual = flags.multilingual or scan.multilingual_hint or false
    local long         = flags.long   or false
    local allow_hash   = flags.allow_hash or false

    local profile = {
        has_gpu      = gpu.ok,
        gpu_free_mb  = gpu.ok and gpu.value.free_mb or 0,
        has_docker   = docker.ok,
        has_ollama   = ollama.ok,
        ram_mb       = ram.ok and ram.value or 0,
        multilingual = multilingual,
        long_rows    = long,
        allow_hash   = allow_hash or flags.allow_hash,
        gguf_capable   = gguf.ok,
        allow_gguf     = not flags.no_gguf,   -- --no-gguf opts out of the in-process default
        gguf_ready     = gguf_state.ready,
        gguf_model     = gguf_state.ready and gguf_state.model or nil,
        gguf_dim       = gguf_state.dim,
        gguf_not_ready = gguf_state.reason,
        ollama_ready   = ollama_state.ready
            and { url = ollama_state.url, model = ollama_state.model, dim = ollama_state.dim } or nil,
        ollama_not_ready = (ollama_state.checked and not ollama_state.ready) and ollama_state.reason or nil,
        tei_ready      = tei_state.ready
            and { url = tei_state.url, model = tei_state.model, dim = tei_state.dim,
                  container = tei_state.container } or nil,
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
    io.write("\nRationale:\n")
    for _, r in ipairs(rec.rationale) do
        io.write("  - " .. r .. "\n")
    end

    local recommended = rec_settings(rec)
    io.write(flags.probe_only and "\nSettings (memo calibrate records them in .luamemorc):\n"
        or "\nSettings (recorded in .luamemorc unless it already sets them):\n")
    for _, kv in ipairs(recommended) do io.write("  ", kv[1], "=", kv[2], "\n") end

    if rec.gguf_upgrade then
        local step1
        if gguf.shim then
            step1 = "  1. The runtime (gguf_shim.so) is installed already — nothing to do here.\n"
        elseif gguf.prebuilt then
            step1 = "  1. Install the prebuilt runtime for " .. gguf.prebuilt.platform .. " (no compiler needed):\n"
                .. "       memo gguf install\n"
        else
            step1 = [[
  1. Build llama.cpp (shared libs) and the shim:
       git clone --depth 1 --branch ]] .. llama_tag() .. [[ https://github.com/ggml-org/llama.cpp ~/llama.cpp
       cmake -B ~/llama.cpp/build -S ~/llama.cpp -DBUILD_SHARED_LIBS=ON \
             -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF \
             -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
             -DLLAMA_BUILD_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release
       cmake --build ~/llama.cpp/build --target llama -j
       LLAMA_DIR=~/llama.cpp bash <luamemo>/embedders/native/build.sh
]]
        end
        io.write([[

Optional upgrade — in-process GGUF embedder (one-time setup)
------------------------------------------------------------
This host can run a GGUF embedding model INSIDE your process via LuaJIT FFI — no
sidecar, no vendor API, owned weights (survives provider changes), and far better
retrieval than hash. It is not set up yet, so calibrate configured the working
embedder above; memo is usable now. Upgrade whenever you like:

]] .. step1 .. [[

  2. Download the model (EmbeddingGemma-300M recommended; ~320 MB):
       mkdir -p ~/models && curl -sL -o ~/models/embeddinggemma-300M-Q8_0.gguf \
         https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf
     Want a different / newer open-weights model instead? Point MEMO_GGUF_MODEL
     at ANY llama.cpp-compatible GGUF embedding model — gemma is just the default.

  3. Check it: re-run `memo calibrate --probe-only` — the GGUF line must say "ready".

  4. Switch this project:
       memo config set MEMO_EMBEDDER gguf_ffi
       memo config set MEMO_GGUF_MODEL <path-to.gguf>
       memo config set MEMO_EMBED_DIM 768
       memo config unset MEMO_EMBEDDER_URL        (and MEMO_EMBEDDER_ADAPTER, if set)
     Then restart the MCP server in your client, and re-embed what is already
     stored:  memo reembed --all
     (the database moves to the new vector size once every scope is re-embedded).

Hide this suggestion: re-run `memo calibrate --no-gguf`.
]])
    end

    if flags.write then
        local f, ferr = io.open(flags.write, "w")
        if not f then
            io.stderr:write("\nmemo calibrate: failed to write "
                .. flags.write .. ": " .. tostring(ferr) .. "\n")
            os.exit(1)
        end
        for _, kv in ipairs(recommended) do f:write(kv[1], "=", shell_quote(kv[2]), "\n") end
        f:close()
    end

    if flags.probe_only then
        io.write("\nRun `memo calibrate` (without --probe-only) to also ingest"
            .. " codebase decisions into the memory store.\n")
    end
end

return M
