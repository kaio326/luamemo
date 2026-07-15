-- luamemo.cli.index
-- `memo index` subcommands: ingest, update, search, status, invalidate, diff, explore
-- Called via: cmd_local_lua index <subcommand> [flags]

local M = {}

-- ---------------------------------------------------------------------------
-- Setup helper: load luamemo and configure it from the MEMO_* env vars.
-- Config construction is shared with the other CLI entrypoints via _common.
-- ---------------------------------------------------------------------------
local common = require("luamemo.cli._common")

local function setup()
    local ok, luamemo = pcall(require, "luamemo")
    if not ok then
        io.stderr:write("memo index: cannot load luamemo: " .. tostring(luamemo) .. "\n")
        os.exit(1)
    end
    local cfg = common.config_from_env({ auth = true })
    local ok2, err = pcall(luamemo.setup, cfg)
    if not ok2 then
        io.stderr:write("memo index: setup failed: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    return luamemo
end

-- ---------------------------------------------------------------------------
-- Argument parser
-- ---------------------------------------------------------------------------
local function parse_args(argv)
    local flags = {}
    local positional = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a:sub(1, 2) == "--" then
            local key = a:sub(3):gsub("%-", "_")
            local val = argv[i + 1]
            if val and val:sub(1, 2) ~= "--" then
                flags[key] = val
                i = i + 2
            else
                flags[key] = true
                i = i + 1
            end
        else
            positional[#positional + 1] = a
            i = i + 1
        end
    end
    return flags, positional
end

-- Apply the scan-related flags shared by ingest and update onto an opts table:
--   --exclude a,b,c       comma-separated exclude patterns
--   --extensions lua,py   narrow the walk (or "*" for all text files; default)
--   --no-symbols          file-level index only (skip symbol extraction)
--   --embed-file-rows     also embed file rows (default: file rows are FTS-only)
--   --no-ctags            disable universal-ctags enrichment for non-native langs
local function apply_scan_opts(opts, flags)
    if flags.exclude and flags.exclude ~= true then
        local excludes = {}
        for p in flags.exclude:gmatch("[^,]+") do excludes[#excludes + 1] = p end
        opts.exclude_patterns = excludes
    end
    if flags.extensions and flags.extensions ~= true then
        if flags.extensions == "*" then
            opts.extensions = "*"
        else
            local exts = {}
            for e in flags.extensions:gmatch("[^,]+") do
                e = e:gsub("%s+", ""):gsub("^%.", "")
                if e ~= "" then exts[e] = true end
            end
            opts.extensions = exts
        end
    end
    if flags.no_symbols then opts.symbols = false end
    if flags.embed_file_rows then opts.file_row_embeddings = true end
    if flags.no_ctags then opts.use_ctags = false end
    return opts
end

-- ---------------------------------------------------------------------------
-- Subcommand: ingest
-- Indexes EVERY text file by default (whole-repo). Narrow with
-- `--extensions lua,py` or store file rows only with `--no-symbols` to limit
-- embedding volume / cost on large repos.
-- ---------------------------------------------------------------------------
local function cmd_ingest(argv)
    local flags, _ = parse_args(argv)
    local luamemo = setup()
    local root    = flags.root or "."
    local scope   = flags.scope
    local project = flags.project
    local dry_run = flags.dry_run and true or false

    io.write(("[memo index ingest] root=%s scope=%s dry_run=%s\n"):format(
        root, scope or "(auto)", tostring(dry_run)))
    io.flush()

    local opts = apply_scan_opts({
        scope   = scope,
        project = project,
        dry_run = dry_run,
        progress_fn = function(rel, syms, done, total)
            io.write(("[%d/%d] %s → %d symbols\n"):format(done, total, rel, syms))
            io.flush()
        end,
    }, flags)

    local result, err = luamemo.index.ingest(root, opts)
    if not result then
        io.stderr:write("memo index ingest: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    io.write(("\n[done] files=%d symbols=%d dependencies=%d errors=%d scope=%s\n"):format(
        result.files, result.symbols, result.requires, #result.errors, result.scope))
    if #result.errors > 0 then
        io.write("Errors:\n")
        for _, e in ipairs(result.errors) do io.write("  " .. e .. "\n") end
    end
end

-- ---------------------------------------------------------------------------
-- Subcommand: update
-- ---------------------------------------------------------------------------
local function cmd_update(argv)
    local flags, _ = parse_args(argv)
    local luamemo = setup()
    local root    = flags.root or "."
    local scope   = flags.scope
    local project = flags.project

    io.write(("[memo index update] root=%s scope=%s\n"):format(root, scope or "(auto)"))
    io.flush()

    local opts = apply_scan_opts({
        scope   = scope,
        project = project,
        progress_fn = function(rel, syms, done, total)
            io.write(("[%d/%d] %s → %d symbols\n"):format(done, total, rel, syms))
            io.flush()
        end,
    }, flags)

    local result, err = luamemo.index.update(root, opts)
    if not result then
        io.stderr:write("memo index update: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    io.write(("\n[done] files=%d symbols=%d dependencies=%d errors=%d scope=%s\n"):format(
        result.files, result.symbols, result.requires, #result.errors, result.scope))
end

-- ---------------------------------------------------------------------------
-- Subcommand: search
-- ---------------------------------------------------------------------------
local function cmd_search(argv)
    local flags, positional = parse_args(argv)
    local query = positional[1]
    if not query or query == "" then
        io.stderr:write("usage: memo index search <query> [--scope S] [--kind K] [--limit N]\n")
        os.exit(2)
    end
    local luamemo = setup()

    local opts = {
        scope  = flags.scope,
        kind   = flags.kind,
        limit  = tonumber(flags.limit) or 20,
    }

    local rows, err = luamemo.index.search(query, opts)
    if not rows then
        io.stderr:write("memo index search: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    if #rows == 0 then
        io.write("(no results)\n")
        return
    end

    for i, r in ipairs(rows) do
        local meta = r.metadata or {}
        local loc = meta.path and (meta.path .. (meta.line and (":" .. meta.line) or "")) or ""
        io.write(("[%d] %s  [%s]  %s\n  %s\n"):format(
            i, r.title or "", r.kind or "", loc,
            (r.body or ""):sub(1, 120)))
    end
end

-- ---------------------------------------------------------------------------
-- Subcommand: status
-- ---------------------------------------------------------------------------
local function cmd_status(argv)
    local flags, _ = parse_args(argv)
    local luamemo = setup()
    local opts = { scope = flags.scope, project = flags.project }

    local counts, err = luamemo.index.status(opts)
    if not counts then
        io.stderr:write("memo index status: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local scope_str = opts.scope or ("codeindex:" .. (opts.project or "default"))
    io.write(("scope: %s\n"):format(scope_str))
    for kind, n in pairs(counts) do
        io.write(("  %-12s %d\n"):format(kind, n))
    end
end

-- ---------------------------------------------------------------------------
-- Subcommand: invalidate
-- ---------------------------------------------------------------------------
local function cmd_invalidate(argv)
    local flags, positional = parse_args(argv)
    local target = positional[1] or flags.scope
    if not target then
        io.stderr:write("usage: memo index invalidate <file|scope> [--scope S]\n")
        os.exit(2)
    end
    local luamemo = setup()
    local opts = { scope = flags.scope, project = flags.project }

    local n, err = luamemo.index.invalidate(target, opts)
    if not n and err then
        io.stderr:write("memo index invalidate: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    io.write(("deleted %d rows for: %s\n"):format(n or 0, target))
end

-- ---------------------------------------------------------------------------
-- Subcommand: diff
-- ---------------------------------------------------------------------------
local function cmd_diff(argv)
    local flags, _ = parse_args(argv)
    local luamemo = setup()

    local diff_text
    local source_label

    if flags.commit then
        -- git diff <commit>~1..<commit>
        local sha = flags.commit
        -- Security: this value is interpolated into a shell command, so it must
        -- be a plain git ref. Reject anything outside a conservative ref charset
        -- to prevent command injection (e.g. --commit 'x; rm -rf ~').
        if type(sha) ~= "string" or #sha > 100 or not sha:match("^[%w][%w._/%-]*$") then
            io.stderr:write("memo index diff: invalid --commit ref (allowed: letters, digits, . _ / -)\n")
            os.exit(2)
        end
        local pipe = io.popen(('git diff %s~1 %s 2>/dev/null'):format(sha, sha))
        if not pipe then
            io.stderr:write("memo index diff: cannot run git diff\n")
            os.exit(1)
        end
        diff_text = pipe:read("*a")
        pipe:close()
        source_label = "commit " .. sha

    elseif flags.file then
        local f, ferr = io.open(flags.file, "r")
        if not f then
            io.stderr:write("memo index diff: " .. tostring(ferr) .. "\n")
            os.exit(1)
        end
        diff_text = f:read("*a")
        f:close()
        source_label = flags.file

    elseif flags.stdin then
        diff_text = io.read("*a")
        source_label = "stdin"

    else
        io.stderr:write("usage: memo index diff --commit SHA | --file FILE | --stdin\n")
        os.exit(2)
    end

    if not diff_text or diff_text == "" then
        io.write("(empty diff — nothing to ingest)\n")
        return
    end

    local opts = {
        scope          = flags.scope,
        project        = flags.project,
        commit_sha     = flags.commit or "unknown",
        commit_message = flags.message or "",
        author         = flags.author or "",
    }

    io.write(("[memo index diff] source=%s scope=%s\n"):format(source_label, opts.scope or "(auto)"))
    io.flush()

    local result, err = luamemo.index.ingest_diff(diff_text, opts)
    if not result then
        io.stderr:write("memo index diff: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    io.write(("[done] hunks=%d rows=%d errors=%d\n"):format(
        result.hunks, result.rows, #result.errors))
    if #result.errors > 0 then
        for _, e in ipairs(result.errors) do io.write("  " .. e .. "\n") end
    end
end

-- ---------------------------------------------------------------------------
-- Subcommand: explore
-- ---------------------------------------------------------------------------
local function cmd_explore(argv)
    local flags, positional = parse_args(argv)
    local query = positional[1]
    if not query or query == "" then
        io.stderr:write("usage: memo index explore <query> [--scope S] [--limit N]\n")
        os.exit(2)
    end
    local luamemo = setup()

    local opts = {
        scope = flags.scope,
        limit = tonumber(flags.limit) or 20,
    }

    local res, err = luamemo.index.explore(query, opts)
    if not res then
        io.stderr:write("memo index explore: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local function _print_group(label, rows)
        io.write(("\n%s (%d):\n"):format(label, #rows))
        for _, r in ipairs(rows) do
            local meta = r.metadata or {}
            local loc = meta.path and (meta.path .. (meta.line and (":" .. tostring(meta.line)) or "")) or ""
            io.write(("  %-40s %s\n"):format(r.title or "", loc))
        end
    end

    _print_group("matched", res.matched)
    _print_group("callers (required_by)", res.callers)
    _print_group("callees (requires)", res.callees)
    io.write(("\ntotal unique symbols: %d\n"):format(#res.all))
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------
function M.run(argv)
    argv = argv or {}
    local subcmd = table.remove(argv, 1)
    if not subcmd then
        io.stderr:write("usage: memo index <ingest|update|search|status|invalidate|diff|explore> [opts]\n")
        os.exit(2)
    end

    if     subcmd == "ingest"     then cmd_ingest(argv)
    elseif subcmd == "update"     then cmd_update(argv)
    elseif subcmd == "search"     then cmd_search(argv)
    elseif subcmd == "status"     then cmd_status(argv)
    elseif subcmd == "invalidate" then cmd_invalidate(argv)
    elseif subcmd == "diff"       then cmd_diff(argv)
    elseif subcmd == "explore"    then cmd_explore(argv)
    else
        io.stderr:write("memo index: unknown subcommand: " .. subcmd .. "\n")
        io.stderr:write("usage: memo index <ingest|update|search|status|invalidate|diff|explore>\n")
        os.exit(2)
    end
end

return M
