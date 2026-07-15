-- luamemo.index
-- Orchestrator for the codebase indexation pipeline.
-- Requires configure(config) to be called (done by luamemo.init.setup()).
-- Soft-errors on all API calls if not configured.

local walker   = require("luamemo.index.walker")
local parser   = require("luamemo.index.parser")
local checksum = require("luamemo.index.checksum")
local differ   = require("luamemo.index.differ")
local resolver = require("luamemo.index.resolver")
local digester = require("luamemo.index.digester")
local format   = require("luamemo.index.format")
local ctags    = require("luamemo.index.ctags")

local M = {}

local cfg = nil  -- set by configure()

-- Lazy store reference to avoid circular dep at load time.
local function _store()
    return require("luamemo.store")
end

local function _ready()
    if not cfg then return nil, "index: not configured (call setup() first)" end
    return true
end

-- ---------------------------------------------------------------------------
-- configure  — called from luamemo.init.setup()
-- ---------------------------------------------------------------------------
function M.configure(config)
    cfg = config
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Build the scope string for a project.
local function _scope(opts)
    return opts.scope or ("codeindex:" .. (opts.project or "default"))
end

-- Dotted module name for a symbol, derived from its file path.
-- "luamemo/store.lua" → "luamemo.store". Falls back to project, then "?".
-- This is the real public identifier; the parser's sym.module is only the
-- local table variable ("M"), which is meaningless outside the file.
local function _symbol_module(sym, project)
    local mod = sym.path and resolver.path_to_module(sym.path) or nil
    return mod or project or "?"
end

-- Build the embeddable body string for a symbol row.
-- `qualified` is the fully-qualified name ("luamemo.store.write"); when given
-- it replaces the as-written name ("M.write") so the embedding text carries the
-- real module path instead of the local table variable.
local function _symbol_body(sym, qualified)
    local doc = (sym.docstring and sym.docstring ~= "") and (sym.docstring .. " — ") or ""
    local args_hint = ""
    if sym.arity and sym.arity > 0 then
        args_hint = "(" .. sym.arity .. (sym.vararg and "+" or "") .. " args)"
    elseif sym.vararg then
        args_hint = "(...)"
    end
    return doc .. sym.symbol_type .. " " .. (qualified or sym.full_name or sym.name) .. args_hint
end

-- Build the searchable body string for a file row.
-- Enriched so lexical search actually hits: Postgres FTS tokenises a path like
-- "src/payments/refund.lua" as ONE token, so we also emit the split path words
-- ("src payments refund") and the names of the symbols the file defines
-- ("defines: processRefund, issueChargeback") as separate tokens. This is what
-- lets a query like "refund payments" or "the file that defines write_many"
-- match the file row — important because file rows are stored FTS-only (no
-- vector) by default.
local function _file_body(rel_path, first_line, symbols)
    local parts = { rel_path }
    if first_line and first_line ~= "" then parts[#parts + 1] = first_line end

    -- Split path into word tokens (drop the extension and separators).
    local base = rel_path:gsub("%.[%w_]+$", "")
    local words = base:gsub("[/\\%.%-_]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if words ~= "" and words ~= rel_path then parts[#parts + 1] = words end

    -- Up to 15 defined symbol names, exported first.
    if symbols and #symbols > 0 then
        local names, seen = {}, {}
        local function collect(want_exported)
            for _, s in ipairs(symbols) do
                local nm = s.name
                if nm and not seen[nm] and (s.exported == want_exported) then
                    seen[nm] = true
                    names[#names + 1] = nm
                    if #names >= 15 then return end
                end
            end
        end
        collect(true)
        if #names < 15 then collect(false) end
        if #names > 0 then
            parts[#parts + 1] = "defines: " .. table.concat(names, ", ")
        end
    end

    return table.concat(parts, " — ")
end

-- Extract the first meaningful line from source (skip blank + comment lines).
local function _first_meaningful_line(src)
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^%-%-") then
            return line:sub(1, 120)
        end
    end
    return nil
end

-- Convert a symbol table from parser into a store row table.
local function _symbol_to_row(sym, scope, project)
    local mod  = _symbol_module(sym, project)
    local qual = mod .. "." .. (sym.name or sym.full_name or "?")
    return {
        scope      = scope,
        kind       = "symbol",
        title      = qual,
        body       = _symbol_body(sym, qual),
        importance = sym.exported and 1.5 or 0.8,
        tier       = 1,
        tags       = { sym.symbol_type, sym.path and sym.path:match("[^/\\]+$") or "" },
        metadata   = {
            path        = sym.path,
            line        = sym.line,
            symbol_type = sym.symbol_type,
            module      = mod,             -- dotted module name (not the local var "M")
            source_name = sym.full_name,   -- as written in source, e.g. "M.write"
            arity       = sym.arity,
            vararg      = sym.vararg and true or false,
            exported    = sym.exported and true or false,
        },
    }
end

-- Wipe stale KG facts for a given from_module before re-writing.
-- Removes both "requires" (subject=from_module) and "required_by" (object=from_module).
local function _kg_invalidate_file(scope, from_module)
    local db = require("luamemo.db")
    db.query(
        ("DELETE FROM lm_kg_facts WHERE scope = %s AND predicate = 'requires' AND subject = %s"):format(
            db.escape_literal(scope), db.escape_literal(from_module)))
    db.query(
        ("DELETE FROM lm_kg_facts WHERE scope = %s AND predicate = 'required_by' AND object = %s"):format(
            db.escape_literal(scope), db.escape_literal(from_module)))
end

-- Ingest one file: delete old rows, write new rows, write KG dependency facts.
-- root: absolute project root path, used by resolver for dependency resolution.
-- want_symbols: when false, write only the file row (whole-repo file index mode).
--   Symbols are also skipped when no language parser handles the extension.
-- preloaded: optional { src, cksum } already read by the caller (update path),
--   reused to avoid a second full read + rehash of the same file.
-- embed_file_rows: when true, file rows get a vector too (default: FTS-only).
-- use_ctags: when not false, use universal-ctags (if available) for non-native
--   code languages. Default enabled; ctags absence is a silent no-op.
-- Returns: symbols_written, requires_written, err
local function _ingest_file(file_entry, scope, project, root, want_symbols, preloaded, embed_file_rows, use_ctags)
    local st     = _store()
    local path   = file_entry.path
    local rel    = file_entry.rel

    -- Source + checksum: reuse the caller's read when supplied, else read disk.
    local src, cksum
    if preloaded and preloaded.src then
        src, cksum = preloaded.src, preloaded.cksum
    else
        local f, ferr = io.open(path, "r")
        if not f then return 0, 0, "open: " .. tostring(ferr) end
        src = f:read("*a")
        f:close()
    end
    cksum = cksum or checksum.source(src)
    local lines_count = 0
    for _ in (src .. "\n"):gmatch("[^\n]*\n") do lines_count = lines_count + 1 end

    -- Delete existing memory rows for this file (file + symbol + dependency rows).
    st.delete_where({ scope = scope, metadata_filter = { path = rel } })

    -- Derive the module name for this file (used as KG subject/object).
    local from_module = resolver.path_to_module(rel)

    -- Delete stale KG facts for this file. Only languages whose imports resolve
    -- to KG facts (Lua today) can have facts to clear — skip the two no-op
    -- DELETEs for every other file (the bulk of a whole-repo ingest).
    if from_module and resolver.has_resolver(rel) then
        _kg_invalidate_file(scope, from_module)
    end

    -- Symbol extraction. Merge policy:
    --   1. Native pure-Lua parser wins (lua/py/js/ts) — it also gives docstrings
    --      + import edges, which ctags does not.
    --   2. Otherwise, if enabled and available, universal-ctags fills the gap for
    --      other code languages (go/rust/ruby/java/c/…) — symbols only.
    --   3. Otherwise the file still gets a `file` row, but no symbols.
    local parse_result = { symbols = {}, requires = {} }
    local do_symbols = false
    if want_symbols ~= false then
        if parser.has_parser(rel) then
            parse_result = parser.parse_source(src, rel)
            do_symbols = true
        elseif use_ctags ~= false and ctags.handles(rel) then
            parse_result = ctags.parse_file(path, rel)
            do_symbols = true
        end
    end
    local first_line   = _first_meaningful_line(src)

    -- Build rows.
    local rows = {}

    -- File row. FTS-only by default (no_embed) — file lookups are lexical
    -- (path + symbol names), so we skip the embed call unless the caller opts
    -- back in via embed_file_rows. Body is enriched with split path words +
    -- defined symbol names so lexical search actually hits.
    rows[#rows + 1] = {
        scope      = scope,
        kind       = "file",
        title      = rel,
        body       = _file_body(rel, first_line, parse_result.symbols),
        importance = 0.3,
        tier       = 1,
        no_embed   = (not embed_file_rows) or nil,
        metadata   = {
            path         = rel,
            checksum     = cksum,
            lines        = lines_count,
            last_indexed = os.time(),
        },
    }

    -- Symbol rows.
    for _, sym in ipairs(parse_result.symbols) do
        rows[#rows + 1] = _symbol_to_row(sym, scope, project)
    end

    -- Dependency rows + KG facts.
    local kg = require("luamemo.kg")
    for _, req in ipairs(parse_result.requires) do
        local resolved_path = root and resolver.resolve(req.module, root) or nil
        rows[#rows + 1] = {
            scope      = scope,
            kind       = "dependency",
            title      = req.path .. " → " .. req.module,
            body       = ('require("%s") in %s at line %d'):format(req.module, req.path, req.line),
            importance = 0.2,
            tier       = 0,
            metadata   = {
                from_path     = req.path,
                to_module     = req.module,
                resolved_path = resolved_path,
                line          = req.line,
            },
        }
        -- Write KG facts only for internal (resolved) dependencies.
        if from_module and resolved_path then
            kg.assert_fact({ scope=scope, subject=from_module,   predicate="requires",     object=req.module })
            kg.assert_fact({ scope=scope, subject=req.module,    predicate="required_by",  object=from_module })
        end
    end

    -- Write all memory rows (append — delete-before-write guarantees no duplicates).
    if #rows > 0 then
        local _, werr = st.write_many(rows, { dedup_strategy = "append" })
        if werr then return 0, 0, "write_many: " .. tostring(werr) end
    end

    return #parse_result.symbols, #parse_result.requires, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- ingest(root, opts)
-- Full codebase ingest. By default indexes EVERY text file under root (one
-- `file` row each) and extracts symbols for languages with a parser.
--
-- COST NOTE: file rows are FTS-only by default (no embed call) — their lookup
-- is lexical (path words + defined symbol names), so they cost nothing to embed.
-- Only symbol/dependency/diff rows are embedded. To further bound cost, narrow
-- with `extensions = { lua=true, ... }` or set `symbols=false` (file-index only).
-- Set `file_row_embeddings=true` to also embed file rows (rarely needed).
--
-- opts:
--   scope               = "codeindex:myproject"   (overrides project)
--   project             = "myproject"             (used if scope not given)
--   extensions          = { lua=true, ... } | "*" (default "*" — whole-repo)
--   symbols             = bool  (default true; false = file-level index only)
--   file_row_embeddings = bool  (default false; true = embed file rows too)
--   exclude_patterns    = { ".git", "vendor/", ... }
--   max_file_bytes   = number
--   dry_run          = bool  (walk + parse but do not write)
--   progress_fn      = function(rel, syms_written, files_done, files_total)
function M.ingest(root, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local scope   = _scope(opts)
    local project = opts.project or scope:match("^codeindex:(.+)$") or "default"
    local want_symbols = opts.symbols ~= false
    local embed_file_rows = opts.file_row_embeddings == true
    local use_ctags = opts.use_ctags ~= false

    -- Walk. Default to every text file (whole-repo index); callers may narrow
    -- with opts.extensions = { lua=true, ... }.
    local files, werr = walker.walk(root, {
        extensions       = opts.extensions or "*",
        exclude_patterns = opts.exclude_patterns or { ".git", "vendor/", "node_modules/" },
        max_file_bytes   = opts.max_file_bytes,
        warn_fn          = opts.warn_fn,
    })
    if not files then return nil, "ingest: walker failed: " .. tostring(werr) end

    local total_syms, total_reqs, total_files = 0, 0, #files
    local errors = {}

    for i, file_entry in ipairs(files) do
        if not opts.dry_run then
            local syms, reqs, ferr = _ingest_file(file_entry, scope, project, root, want_symbols, nil, embed_file_rows, use_ctags)
            if ferr then
                errors[#errors + 1] = file_entry.rel .. ": " .. ferr
            else
                total_syms = total_syms + syms
                total_reqs = total_reqs + reqs
            end
        end
        if opts.progress_fn then
            opts.progress_fn(file_entry.rel, total_syms, i, total_files)
        end
    end

    return {
        files   = total_files,
        symbols = total_syms,
        requires = total_reqs,
        errors  = errors,
        scope   = scope,
        dry_run = opts.dry_run and true or false,
    }
end

-- update(root, opts)
-- Incremental update: only processes MODIFIED, NEW, and DELETED files.
-- UNCHANGED files (same checksum) are skipped with no disk reads or DB writes.
-- DELETED files (in store but not on disk) have all rows removed.
-- Same opts as ingest().
-- Returns: { files, symbols, requires, deleted, skipped, errors, scope, dry_run }
function M.update(root, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local scope   = _scope(opts)
    local project = opts.project or scope:match("^codeindex:(.+)$") or "default"
    local want_symbols = opts.symbols ~= false
    local embed_file_rows = opts.file_row_embeddings == true
    local use_ctags = opts.use_ctags ~= false
    local st      = _store()
    local db      = require("luamemo.db")

    -- Step 1: Batch-fetch all stored file checksums in one SQL query.
    local stored = {}  -- rel_path → checksum string
    local q = ("SELECT metadata->>'path' AS path, metadata->>'checksum' AS cksum "
             .. "FROM lm_memories WHERE scope = %s AND kind = 'file'"):format(
                 db.escape_literal(scope))
    local rows, qerr = db.query(q)
    if rows then
        for _, row in ipairs(rows) do
            if row.path then stored[row.path] = row.cksum or false end
        end
    elseif opts.warn_fn then
        opts.warn_fn("update: could not fetch stored checksums: " .. tostring(qerr))
    end

    -- Step 2: Walk the filesystem (whole-repo by default; see ingest()).
    local files, werr = walker.walk(root, {
        extensions       = opts.extensions or "*",
        exclude_patterns = opts.exclude_patterns or { ".git", "vendor/", "node_modules/" },
        max_file_bytes   = opts.max_file_bytes,
        warn_fn          = opts.warn_fn,
    })
    if not files then return nil, "update: walker failed: " .. tostring(werr) end

    -- Build current-file set.
    local current = {}
    for _, fe in ipairs(files) do current[fe.rel] = fe end

    -- Step 3: Delete rows for files that no longer exist on disk.
    local deleted_rows = 0
    if not opts.dry_run then
        for rel_path in pairs(stored) do
            if not current[rel_path] then
                local n = st.delete_where({ scope = scope, metadata_filter = { path = rel_path } })
                deleted_rows = deleted_rows + (n or 0)
            end
        end
    end

    -- Step 4: Process NEW and MODIFIED files; skip UNCHANGED.
    local total_syms, total_reqs, total_files = 0, 0, #files
    local skipped = 0
    local errors  = {}

    for i, file_entry in ipairs(files) do
        if not opts.dry_run then
            local rel = file_entry.rel

            -- Compute checksum.
            local f, ferr = io.open(file_entry.path, "r")
            if not f then
                errors[#errors + 1] = rel .. ": open: " .. tostring(ferr)
            else
                local src = f:read("*a")
                f:close()
                local cksum = checksum.source(src)

                local stored_cksum = stored[rel]  -- nil = NEW, false = stored but no checksum
                if stored_cksum and stored_cksum == cksum then
                    -- UNCHANGED — skip entirely.
                    skipped = skipped + 1
                else
                    -- NEW or MODIFIED — reuse the read we just did (src + cksum)
                    -- so _ingest_file does not open/read/hash the file again.
                    local syms, reqs, ferr2 = _ingest_file(file_entry, scope, project, root,
                        want_symbols, { src = src, cksum = cksum }, embed_file_rows, use_ctags)
                    if ferr2 then
                        errors[#errors + 1] = rel .. ": " .. ferr2
                    else
                        total_syms = total_syms + syms
                        total_reqs = total_reqs + reqs
                    end
                end
            end
        end
        if opts.progress_fn then
            opts.progress_fn(file_entry.rel, total_syms, i, total_files)
        end
    end

    return {
        files    = total_files,
        symbols  = total_syms,
        requires = total_reqs,
        deleted  = deleted_rows,
        skipped  = skipped,
        errors   = errors,
        scope    = scope,
        dry_run  = opts.dry_run and true or false,
    }
end

-- search(query, opts)
-- Wrapper around store.search with code-specific defaults.
-- opts: scope, project, kind, path_filter, limit, hybrid_weights
function M.search(query, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local scope = _scope(opts)
    local st = _store()

    local search_args = {
        query           = query,
        scope           = scope,
        kind            = opts.kind,
        limit           = opts.limit or 20,
        hybrid_weights  = opts.hybrid_weights or { vector = 0.3, fts = 0.7 },
        skip_temporal   = true,
        skip_observations = true,
    }
    if opts.path_filter then
        search_args.metadata_filter = { path = opts.path_filter }
    end

    return st.search(search_args)
end

-- Load all symbol rows for a given file path (direct SQL, no ranking).
-- Returns a list of { id, title, body, metadata } with metadata decoded.
local function _symbols_for_path(scope, path, limit)
    local db = require("luamemo.db")
    local q = ("SELECT id, title, body, kind, metadata FROM lm_memories "
            .. "WHERE scope = %s AND kind = 'symbol' AND metadata->>'path' = %s "
            .. "ORDER BY CAST(metadata->>'line' AS INTEGER) ASC LIMIT %d"):format(
                db.escape_literal(scope), db.escape_literal(path), limit or 200)
    local rows = db.query(q)
    return rows or {}
end

-- Build a { dotted_module -> rel_path } map from the file rows in a scope.
-- This is the join key between KG facts (dotted names) and symbol rows (paths).
local function _module_path_map(scope)
    local db = require("luamemo.db")
    local rows = db.query(
        ("SELECT metadata->>'path' AS path FROM lm_memories WHERE scope = %s AND kind = 'file'"):format(
            db.escape_literal(scope)))
    local map = {}
    for _, r in ipairs(rows or {}) do
        if r.path then
            local mod = resolver.path_to_module(r.path)
            if mod then map[mod] = r.path end
        end
    end
    return map
end

-- explore(query, opts) → { matched, callers, callees, all }, or nil, err
--
-- Returns matched symbols PLUS one hop of dependency context:
--   callers — symbols in modules that require a matched symbol's module
--   callees — symbols in modules required by a matched symbol's module
-- All four lists hold symbol rows; `all` is the deduplicated union.
--
-- opts:
--   scope   = "codeindex:myproject"
--   limit   = N      (matched-symbol search limit; default 20)
--   depth   = 1      (one hop only; depth >= 2 not yet implemented)
--   per_mod = N      (max symbols loaded per discovered module; default 50)
function M.explore(query, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local scope   = _scope(opts)
    local limit   = opts.limit or 20
    local per_mod = opts.per_mod or 50
    local st = _store()
    local kg = require("luamemo.kg")

    -- 1. Direct matches.
    local matched, serr = st.search({
        query           = query,
        scope           = scope,
        kind            = "symbol",
        limit           = limit,
        hybrid_weights  = { vector = 0.3, fts = 0.7 },
        skip_temporal   = true,
        skip_observations = true,
    })
    if not matched then return nil, "explore: search failed: " .. tostring(serr) end

    -- Dedup tracking by row id across all legs.
    local seen = {}
    for _, row in ipairs(matched) do
        if row.id then seen[tostring(row.id)] = true end
    end

    -- 2. Collect distinct dotted module names from matched symbols (via path).
    local matched_modules = {}
    for _, row in ipairs(matched) do
        local path = row.metadata and row.metadata.path
        if path then
            local mod = resolver.path_to_module(path)
            if mod then matched_modules[mod] = true end
        end
    end

    -- 3. One-hop neighbours via KG. callers = required_by, callees = requires.
    local mod_path = _module_path_map(scope)
    local caller_mods, callee_mods = {}, {}
    for mod in pairs(matched_modules) do
        local rb = kg.query({ scope = scope, predicate = "required_by", subject = mod })
        for _, f in ipairs(rb or {}) do
            if f.object and not matched_modules[f.object] then caller_mods[f.object] = true end
        end
        local rq = kg.query({ scope = scope, predicate = "requires", subject = mod })
        for _, f in ipairs(rq or {}) do
            if f.object and not matched_modules[f.object] then callee_mods[f.object] = true end
        end
    end

    -- 4. Load symbol rows for neighbour modules; dedup against matched + each other.
    local function _collect(mod_set)
        local out = {}
        for mod in pairs(mod_set) do
            local path = mod_path[mod]
            if path then
                for _, sym in ipairs(_symbols_for_path(scope, path, per_mod)) do
                    local key = tostring(sym.id)
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = sym
                    end
                end
            end
        end
        return out
    end

    local callers = _collect(caller_mods)
    local callees = _collect(callee_mods)

    -- 5. Flattened, deduplicated union (matched first, then callers, then callees).
    local all = {}
    for _, r in ipairs(matched) do all[#all + 1] = r end
    for _, r in ipairs(callers) do all[#all + 1] = r end
    for _, r in ipairs(callees) do all[#all + 1] = r end

    return {
        matched = matched,
        callers = callers,
        callees = callees,
        all     = all,
    }
end

-- status(opts) → { file=N, symbol=N, dependency=N, diff=N }
-- Row counts by kind for the given scope.
function M.status(opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local scope = _scope(opts)
    local db = require("luamemo.db")

    local kinds = { "file", "symbol", "dependency", "diff" }
    local counts = {}
    for _, kind in ipairs(kinds) do
        -- Use a cheap FTS-free count query.
        local res, qerr = db.query(
            ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s AND kind = %s"):format(
                db.escape_literal(scope), db.escape_literal(kind)))
        if res and res[1] then
            counts[kind] = tonumber(res[1].n) or 0
        else
            counts[kind] = 0
            if qerr and opts.warn_fn then opts.warn_fn("status: " .. tostring(qerr)) end
        end
    end
    return counts
end

-- outline(path, opts) → { file = file_row|nil, symbols = {...} }, or nil, err
-- "What is defined in this file" — the read-before-editing primitive. Returns
-- the file row (path, lines, checksum) plus every symbol row for that path,
-- ordered by line. Direct SQL (no ranking, no embed).
-- opts: scope | project, per_file (symbol cap, default 200)
function M.outline(path, opts)
    local ok, err = _ready()
    if not ok then return nil, err end
    if type(path) ~= "string" or path == "" then
        return nil, "outline: path is required"
    end

    opts = opts or {}
    local scope = _scope(opts)
    local db = require("luamemo.db")

    local frows = db.query(
        ("SELECT id, title, body, kind, metadata FROM %s "
      .. "WHERE scope = %s AND kind = 'file' AND metadata->>'path' = %s LIMIT 1"):format(
            "lm_memories", db.escape_literal(scope), db.escape_literal(path)))
    local file_row = frows and frows[1] or nil

    local symbols = _symbols_for_path(scope, path, opts.per_file or 200)

    return { file = file_row, symbols = symbols }
end

-- ingest_diff(diff_text_or_opts, opts)
-- Parse a unified diff string and store diff hunks as searchable memory rows.
-- diff_text_or_opts: the raw unified diff string, OR a table with .text field.
-- opts:
--   scope          = "codeindex:myproject"
--   commit_sha     = "abc1234"   (optional, stored in metadata)
--   commit_message = "..."       (optional, prepended to body)
--   author         = "..."       (optional)
-- Returns: { hunks=N, rows=N, errors={} }
function M.ingest_diff(diff_text_or_opts, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local diff_text
    if type(diff_text_or_opts) == "string" then
        diff_text = diff_text_or_opts
    elseif type(diff_text_or_opts) == "table" then
        diff_text = diff_text_or_opts.text
        for k, v in pairs(diff_text_or_opts) do
            if k ~= "text" and opts[k] == nil then opts[k] = v end
        end
    end
    if not diff_text or diff_text == "" then
        return nil, "ingest_diff: diff_text is required"
    end

    local scope   = _scope(opts)
    local st      = _store()

    local hunks, perr = digester.parse(diff_text)
    if not hunks then return nil, "ingest_diff: parse failed: " .. tostring(perr) end

    local commit_sha = opts.commit_sha   or "unknown"
    local commit_msg = opts.commit_message or ""
    local author     = opts.author        or ""

    local rows = {}
    local errors = {}

    -- Batch symbol attribution: fetch every symbol row for the files this diff
    -- touches in ONE query, then match line ranges in Lua per hunk (replaces a
    -- per-hunk SELECT — N queries collapse to 1 for an N-hunk commit).
    local db = require("luamemo.db")
    local syms_by_path = {}   -- path -> { {title=, line=}, ... }
    do
        local seen, path_lits = {}, {}
        for _, h in ipairs(hunks) do
            if not seen[h.file_path] then
                seen[h.file_path] = true
                path_lits[#path_lits + 1] = db.escape_literal(h.file_path)
            end
        end
        if #path_lits > 0 then
            local q = ("SELECT title, metadata->>'path' AS path, "
                    .. "CAST(metadata->>'line' AS INTEGER) AS line "
                    .. "FROM lm_memories WHERE scope = %s AND kind = 'symbol' "
                    .. "AND metadata->>'path' IN (%s)"):format(
                        db.escape_literal(scope), table.concat(path_lits, ","))
            local srows = db.query(q)
            for _, r in ipairs(srows or {}) do
                if r.path then
                    local lst = syms_by_path[r.path]
                    if not lst then lst = {}; syms_by_path[r.path] = lst end
                    lst[#lst + 1] = { title = r.title, line = tonumber(r.line) }
                end
            end
        end
    end

    for _, hunk in ipairs(hunks) do
        local file_base = hunk.file_path:match("[^/\\]+$") or hunk.file_path
        local title = commit_sha:sub(1, 8) .. ": " .. hunk.file_path
                   .. " +" .. #hunk.added .. " -" .. #hunk.removed

        -- Clip body: commit message + raw hunk.
        local body_prefix = commit_msg ~= "" and (commit_msg .. "\n---\n") or ""
        local body = body_prefix .. hunk.raw_hunk
        if #body > 3000 then body = body:sub(1, 3000) .. "…" end

        -- Symbol attribution: match pre-fetched symbols by line range (≤10),
        -- preserving the original BETWEEN [from_line, from_line+from_count+added].
        local sym_names = {}
        local lo = hunk.from_line
        local hi = hunk.from_line + hunk.from_count + #hunk.added
        for _, s in ipairs(syms_by_path[hunk.file_path] or {}) do
            if s.line and s.line >= lo and s.line <= hi then
                sym_names[#sym_names + 1] = s.title
                if #sym_names >= 10 then break end
            end
        end

        rows[#rows + 1] = {
            scope      = scope,
            kind       = "diff",
            title      = title,
            body       = body,
            importance = 1.2,
            tier       = 1,
            tags       = { "diff", file_base },
            metadata   = {
                commit            = commit_sha,
                author            = author,
                file_path         = hunk.file_path,
                from_line         = hunk.from_line,
                to_line           = hunk.to_line,
                added_count       = #hunk.added,
                removed_count     = #hunk.removed,
                symbols_affected  = sym_names,
            },
        }
    end

    local written = 0
    if #rows > 0 then
        local _, werr = st.write_many(rows, { dedup_strategy = "append" })
        if werr then
            errors[#errors + 1] = "write_many: " .. tostring(werr)
        else
            written = #rows
        end
    end

    return { hunks = #hunks, rows = written, errors = errors }
end

-- invalidate(path_or_scope, opts)
-- Remove index entries for a specific file or an entire project scope.
-- Also clears the matching KG dependency facts so no orphans are left behind.
-- path_or_scope: a relative file path ("luamemo/store.lua") or a scope string ("codeindex:proj")
function M.invalidate(path_or_scope, opts)
    local ok, err = _ready()
    if not ok then return nil, err end

    opts = opts or {}
    local st = _store()
    local db = require("luamemo.db")

    if path_or_scope:match("^codeindex:") then
        -- Full scope wipe: memory rows + all KG facts for the scope.
        local n = st.delete_where({ scope = path_or_scope })
        db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(
            db.escape_literal(path_or_scope)))
        return n
    else
        -- File-level wipe: memory rows for the file + that file's KG facts.
        local scope = _scope(opts)
        local n = st.delete_where({ scope = scope, metadata_filter = { path = path_or_scope } })
        local from_module = resolver.path_to_module(path_or_scope)
        if from_module then _kg_invalidate_file(scope, from_module) end
        return n
    end
end

-- expose sub-modules for direct access
M.walker   = walker
M.parser   = parser
M.checksum = checksum
M.differ   = differ
M.resolver = resolver
M.digester = digester
M.format   = format
M.ctags    = ctags

return M
