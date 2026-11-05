-- eval/corpus/build.lua — the benchmark corpus: a luamemo database of ~100,000 entries that
-- looks like the one luamemo writes, kept apart from every real project.
--
--   luajit eval/corpus/build.lua --out PATH [--target 100000] [--seed 1] [--embedder gguf|hash]
--                                [--gguf-model PATH] [--only a,b] [--no-notes] [--list]
--
-- How it is made (nothing is invented from random words):
--   * the real schema: a new file, luamemo's own migrations applied by luamemo.db;
--   * the code of each source project goes through `memo index ingest`'s code
--     (luamemo.index.ingest → symbol / file / dependency rows, requires / required_by facts)
--     into codeindex:<project>; huge trees are sampled with a seeded order;
--   * its documents, instruction files, decision comments and git history go through
--     `memo calibrate`'s scan (luamemo.cli.calibrate.scan) into repo:<project>;
--   * the agent-written memories are the owner's real notes (eval/corpus/notes.lua);
--   * every row is embedded with the configuration given (the owner's: EmbeddingGemma 2,
--     task prompts, 24,000 characters) into the real `embedding` column.
-- The sources are eval/corpus/sources.lua's: the owner's repositories and the libraries
-- installed on the machine. The database is labelled (lm_meta bench = 1) and every other
-- tool of luamemo that would write into it refuses; this builder refuses any file that is
-- not one of its own. It is resumable: a finished source is recorded (lm_meta done:<name>)
-- and skipped on the next run.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json = require("luamemo.json")
local util = require("luamemo.util")

local M = {}

local function now_text() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

-- ── the database ─────────────────────────────────────────────────────────────

--- Is `path` a benchmark database this builder made (or a path that doesn't exist yet)?
--- → true | false, why.
function M.is_bench_path(path)
    if not (path and path ~= "") then return false, "no path" end
    local base = path:match("([^/]+)$") or path
    if not base:match("^bench[%w%._%-]*%.db$") then
        return false, ("the file must be named bench*.db (got %s): a real project's database is never a benchmark's"):format(base)
    end
    if not util.exists(path) then return true end
    local h = require("luamemo.db").open(path, { readonly = true })
    if not h then return false, "cannot open " .. path end
    local ok, v = pcall(function() return h.value("SELECT value FROM lm_meta WHERE key = 'bench'") end)
    h.close()
    if ok and tostring(v) == "1" then return true end
    return false, path .. " exists but is not a benchmark database (lm_meta bench = 1): refusing to write into it"
end

local function meta_set(db, k, v)
    assert(db.run("INSERT OR REPLACE INTO lm_meta (key, value) VALUES (?, ?)", k, tostring(v)))
end
local function meta_get(db, k)
    local v = db.value("SELECT value FROM lm_meta WHERE key = ?", k)
    return v ~= nil and tostring(v) or nil
end

-- ── the embedder ─────────────────────────────────────────────────────────────

--- The embedder settings a corpus is built (and replayed) with: hash, or the owner's GGUF model
--- with its own cap and task prompts (luamemo.cli.probe.gguf_model_settings).
--- opts: embedder ("gguf" | "hash"), gguf_model. → settings | nil, why
function M.embedder_setup(opts)
    if opts.embedder == "hash" then return { embedder_local = "hash", embed_dim = 384 } end
    local probe = require("luamemo.cli.probe")
    local model = opts.gguf_model or probe.gguf_model_path()
    if not model then return nil, "no GGUF model (--gguf-model, or --embedder hash)" end
    local st = probe.gguf_model_settings(model)
    return { embedder_local = "gguf_ffi", embedder_model = model, embed_dim = 768,
             embed_max_chars = st.max_chars, embed_prompts = st.prompts }
end

--- The settings an existing corpus was built with: the recorded ones (lm_meta bench_setup), else
--- read back from its embedder signature ("gguf_ffi|<model>|768|auto:…"; the model is looked for in
--- ~/models). → settings | nil, why
function M.embedder_from_meta(path, opts)
    local h = require("luamemo.db").open(path, { readonly = true })
    if not h then return nil, "cannot open " .. path end
    local rec = h.value("SELECT value FROM lm_meta WHERE key = 'bench_setup'")
    local sig = h.value("SELECT value FROM lm_meta WHERE key = 'bench_embedder'")
    h.close()
    if rec then
        local s = json.decode(tostring(rec))
        if type(s) == "table" then
            if opts and opts.gguf_model then s.embedder_model = opts.gguf_model end
            return s
        end
    end
    local name, model = tostring(sig or ""):match("^([^|]*)|([^|]*)|")
    if name == "hash" then return { embedder_local = "hash", embed_dim = 384 } end
    if name ~= "gguf_ffi" or model == "" then return nil, "this corpus' embedder is not recorded (lm_meta bench_embedder)" end
    local file = (opts and opts.gguf_model) or ((os.getenv("HOME") or "") .. "/models/" .. model)
    if not util.exists(file) then return nil, "the corpus' embedding model is not at " .. file .. " (--gguf-model)" end
    local st = require("luamemo.cli.probe").gguf_model_settings(file)
    return { embedder_local = "gguf_ffi", embedder_model = file, embed_dim = 768, embed_max_chars = st.max_chars,
             embed_prompts = st.prompts }
end

-- ── sampling ─────────────────────────────────────────────────────────────────

--- A seeded, repeatable sample of `files` (walker entries): the same tree gives the same
--- files; in the walk's own order. (Ordered by SHA-256 of seed|project|path: a cheap hash
--- such as djb2 keeps near-identical names in name order, and the "sample" would be the
--- first files alphabetically.)
function M.sampler(max_files, seed, salt)
    local sha256 = require("luamemo.native.sodium").sha256
    return function(files)
        if not max_files or #files <= max_files then return files end
        local keyed = {}
        for i, f in ipairs(files) do
            keyed[i] = { util.to_hex(sha256(tostring(seed) .. "|" .. salt .. "|" .. f.rel)):sub(1, 16), i }
        end
        table.sort(keyed, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
        local pick = {}
        for i = 1, max_files do pick[keyed[i][2]] = true end
        local out = {}
        for i, f in ipairs(files) do if pick[i] then out[#out + 1] = f end end
        return out
    end
end

-- ── the build ────────────────────────────────────────────────────────────────

local function count(db) return tonumber(db.value("SELECT count(*) FROM lm_memories")) or 0 end

-- A source half-done by an interrupted run starts again: its code index, and the rows its
-- scan wrote (marked metadata.calibrate), with their facts.
local function reset_source(db, src)
    db.run("DELETE FROM lm_kg_facts WHERE scope = ?", "codeindex:" .. src.name)
    db.run("DELETE FROM lm_memories WHERE scope = ?", "codeindex:" .. src.name)
    db.run("DELETE FROM lm_memories WHERE scope = ? AND json_extract(metadata, '$.calibrate') = 1", "repo:" .. src.name)
end

local function write_rows(memory, rows)
    for i = 1, #rows, 50 do
        local batch = {}
        for j = i, math.min(i + 49, #rows) do batch[#batch + 1] = rows[j] end
        -- ("update": a row the scope already holds is refreshed, not written again — write_many appends unless
        -- the call says otherwise, whatever the rows ask for; a rescan once doubled the README rows this way)
        local _, err = memory.store.write_many(batch, { batch_size = 50, dedup_strategy = "update" })
        if err then return nil, err end
    end
    return true
end

--- Remove the exact duplicates of a memory (same scope, kind, title and body) from the `repo:` scopes — what a
--- rescan without dedup left — keeping the oldest row of each. The code index keeps its repeats: the same name in
--- two files is two symbols. The history of use refers to row ids, so it goes too (simulate makes it again).
--- → { removed } | nil, why
function M.dedupe(path, say)
    say = say or function(_) end
    local ok, why = M.is_bench_path(path)
    if not ok then return nil, why end
    local h = assert(require("luamemo.db").open(path))
    local n = tonumber(h.value("SELECT count(*) FROM lm_memories WHERE id NOT IN (SELECT min(id) FROM lm_memories "
        .. "WHERE scope LIKE 'repo:%' GROUP BY scope, kind, title, body) AND scope LIKE 'repo:%'")) or 0
    if n > 0 then
        h.run("DELETE FROM lm_memories WHERE scope LIKE 'repo:%' AND id NOT IN (SELECT min(id) FROM lm_memories "
            .. "WHERE scope LIKE 'repo:%' GROUP BY scope, kind, title, body)")
        h.run("DELETE FROM lm_reinforcements"); h.run("DELETE FROM lm_retrieval_feedback")
    end
    say(("removed %d duplicate rows"):format(n))
    h.close()
    return { removed = n }
end

--- Build (or resume) the corpus. opts: out, target, seed, embedder ("gguf" | "hash"),
--- gguf_model, only, notes (false: skip), sources (tests: the list), note_files (tests), say.
--- → { rows, sources, by_scope } | nil, why.
function M.build(opts)
    local say = opts.say or function(_) end
    local ok, why = M.is_bench_path(opts.out)
    if not ok then return nil, why end
    local target, seed = tonumber(opts.target) or 100000, tonumber(opts.seed) or 1

    local setup, serr = M.embedder_setup(opts)
    if not setup then return nil, serr end
    setup.db, setup.skip_embed_probe = opts.out, true
    local memory = require("luamemo")
    memory.setup(setup)
    local db = require("luamemo.db")
    require("luamemo.db").path()   -- (opened and migrated by the first use below)
    assert(db.value("SELECT count(*) FROM lm_meta") ~= nil)

    local fresh = meta_get(db, "bench") == nil
    if fresh then
        meta_set(db, "bench", "1")
        meta_set(db, "bench_created", now_text())
        meta_set(db, "bench_seed", seed)
        meta_set(db, "bench_target", target)
        meta_set(db, "bench_luamemo", require("luamemo").VERSION)
        meta_set(db, "bench_embedder", require("luamemo.federation.common").embedder_sig(memory.config))
        local rec = {}
        for k, v in pairs(setup) do if k ~= "db" and k ~= "skip_embed_probe" then rec[k] = v end end
        meta_set(db, "bench_setup", json.encode(rec))
    elseif meta_get(db, "bench_seed") ~= tostring(seed) then
        return nil, ("this corpus was started with seed %s, not %s"):format(tostring(meta_get(db, "bench_seed")), seed)
    end

    local sources = require("corpus.sources").discover({
        seed = seed, only = opts.only, extra = opts.sources, own_dirs = opts.own_dirs })
    local index, calibrate = require("luamemo.index"), require("luamemo.cli.calibrate")
    local manifest, done = {}, 0
    for _, src in ipairs(sources) do manifest[#manifest + 1] = src.name .. "=" .. tostring(src.max_files or "all") end
    meta_set(db, "bench_manifest", util.djb2_hex(table.concat(manifest, ",")) .. " " .. #sources .. " sources")

    for _, src in ipairs(sources) do
        if count(db) >= target and not opts.rescan then say(("target %d reached"):format(target)); break end
        if meta_get(db, "done:" .. src.name) then
            done = done + 1
            -- opts.rescan: the scan again (the rows ask for dedup update: it adds what is new — what a
            -- scan fixed since the source was built — and rewrites nothing else)
            if opts.rescan and src.scan_root then
                local rows = calibrate.scan(src.scan_root, "repo:" .. src.name, { no_git = not src.git })
                local before = count(db)
                if rows and #rows > 0 then write_rows(memory, rows) end
                say(("%-34s rescanned: +%d rows"):format(src.name, count(db) - before))
            end
        elseif not opts.rescan then   -- (a rescan never builds a source the target had left out)
            local t0, before = os.time(), count(db)
            reset_source(db, src)
            local pok, res, err = pcall(index.ingest, src.root, { scope = "codeindex:" .. src.name,
                select_files = M.sampler(src.max_files, seed, src.name) })
            if not pok then res, err = nil, res end   -- a crash inside the ingest: log, skip, go on
            if not res then
                say(("source %s: %s — skipped"):format(src.name, tostring(err)))
            else
                local scanned = 0
                if src.scan_root then
                    local rows, serr = calibrate.scan(src.scan_root, "repo:" .. src.name, { no_git = not src.git })
                    if rows and #rows > 0 then
                        local wok, werr = write_rows(memory, rows)
                        if wok then scanned = #rows else say(("source %s: scan rows not written: %s"):format(src.name, tostring(werr))) end
                    elseif not rows then
                        say(("source %s: scan failed: %s"):format(src.name, tostring(serr)))
                    end
                end
                meta_set(db, "done:" .. src.name, json.encode({ files = res.files, symbols = res.symbols,
                    requires = res.requires, scanned = scanned, errors = #(res.errors or {}), secs = os.time() - t0 }))
                say(("%-34s +%5d rows  (%d files, %d symbols, %d scanned)  %ds  total %d"):format(src.name,
                    count(db) - before, res.files, res.symbols, scanned, os.time() - t0, count(db)))
                done = done + 1
            end
        end
    end

    if opts.notes ~= false and not meta_get(db, "done:notes") and not opts.rescan then
        local rows = require("corpus.notes").load({ files = opts.note_files })
        local t0 = os.time()
        -- (a note a rerun rewrites: the rows of this role are deleted first)
        db.run("DELETE FROM lm_memories WHERE json_extract(metadata, '$.role') IN ('planner','changelog','research','note','rules')")
        local wok, werr = write_rows(memory, rows)
        if not wok then return nil, "notes: " .. tostring(werr) end
        meta_set(db, "done:notes", json.encode({ rows = #rows, secs = os.time() - t0 }))
        say(("%-34s +%5d rows  (the agent-written notes)  %ds  total %d"):format("notes", #rows, os.time() - t0, count(db)))
    end

    local by_scope = {}
    for _, r in ipairs(db.query("SELECT substr(scope, 1, instr(scope || ':', ':') - 1) AS fam, kind, count(*) AS n "
        .. "FROM lm_memories GROUP BY fam, kind ORDER BY n DESC") or {}) do
        by_scope[#by_scope + 1] = { family = r.fam, kind = r.kind, n = tonumber(r.n) }
    end
    meta_set(db, "bench_summary", json.encode({ rows = count(db), sources = done, at = now_text() }))
    return { rows = count(db), sources = done, by_scope = by_scope,
             kg_facts = tonumber(db.value("SELECT count(*) FROM lm_kg_facts")) or 0 }
end

-- ── command line ─────────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("corpus/build%.lua$") then
    package.loaded["corpus.build"] = M   -- (run as a script: the other stages require this module back)
    local opts = { target = 100000, seed = 1, embedder = "gguf" }
    local i = 1
    local function value() i = i + 1; return arg[i] end
    while i <= #arg do
        local a = arg[i]
        if a == "--out" then opts.out = value()
        elseif a == "--target" then opts.target = tonumber(value())
        elseif a == "--seed" then opts.seed = tonumber(value())
        elseif a == "--embedder" then opts.embedder = value()
        elseif a == "--gguf-model" then opts.gguf_model = value()
        elseif a == "--own-dirs" then
            opts.own_dirs = {}
            for d in value():gmatch("[^,]+") do opts.own_dirs[#opts.own_dirs + 1] = d end
        elseif a == "--only" then
            opts.only = {}
            for n in value():gmatch("[^,]+") do opts.only[n] = true end
        elseif a == "--no-notes" then opts.notes = false
        elseif a == "--list" then opts.list = true
        elseif a == "--stage" then opts.stage = value()
        elseif a == "--queries" then opts.queries = tonumber(value())
        elseif a == "--paraphrase-n" then opts.paraphrase_n = tonumber(value())
        elseif a == "--paraphrase-model" then opts.paraphrase_model = value()
        elseif a == "--limit" then opts.limit = tonumber(value())
        elseif a == "--heavy-cycles" then opts.heavy_cycles = tonumber(value())
        elseif a == "--heavy-min" then opts.heavy_min = tonumber(value())
        elseif a == "--max-seconds" then opts.max_seconds = tonumber(value())
        else io.stderr:write("unknown argument: " .. a .. "\n"); os.exit(2) end
        i = i + 1
    end
    if opts.list then
        for _, s in ipairs(require("corpus.sources").discover({ seed = opts.seed, only = opts.only, own_dirs = opts.own_dirs })) do
            io.write(("%-34s %-4s %s%s\n"):format(s.name, s.kind, s.root, s.scan_root and ("  (docs: " .. s.scan_root .. ")") or ""))
        end
        os.exit(0)
    end
    if not opts.out then io.stderr:write("usage: build.lua --out bench-NAME.db [--target N] [--seed S] [--embedder gguf|hash]\n"); os.exit(2) end
    opts.say = function(l) io.stderr:write(l, "\n") end
    -- stages: build (default; resumable), rescan (the scan of finished sources again), dedupe (exact repeats in the
    -- repo: scopes removed), queries (labelled questions),
    -- paraphrase (a model rewrites a sample — cached), simulate (the history), all (every one, in order)
    local stage = opts.stage or "build"
    local function fail(e) io.stderr:write("build-corpus: ", tostring(e), "\n"); os.exit(1) end
    local out = {}
    if stage == "build" or stage == "all" then
        local res, err = M.build(opts)
        if not res then fail(err) end
        out.build = res
    end
    if stage == "rescan" then
        opts.rescan = true
        local res, err = M.build(opts)
        if not res then fail(err) end
        out.rescan = res
    end
    if stage == "dedupe" then
        local res, err = M.dedupe(opts.out, opts.say)
        if not res then fail(err) end
        out.dedupe = res
    end
    if stage == "queries" or stage == "all" then
        local res, err = require("corpus.queries").build(opts.out, { seed = opts.seed, total = opts.queries, say = opts.say })
        if not res then fail(err) end
        out.queries = res
    end
    if stage == "paraphrase" or stage == "all" then
        local res, err = require("corpus.paraphrase").run(opts.out, { seed = opts.seed, n = opts.paraphrase_n,
            model = opts.paraphrase_model, max_seconds = opts.max_seconds, say = opts.say })
        if not res then fail(err) end
        out.paraphrase = res
    end
    if stage == "simulate" or stage == "all" then
        local res, err = require("corpus.simulate").run(opts.out, { seed = opts.seed, limit = opts.limit, say = opts.say,
            gguf_model = opts.gguf_model, heavy_cycles = opts.heavy_cycles, heavy_min = opts.heavy_min })
        if not res then fail(err) end
        out.simulate = res
    end
    if not next(out) then fail("unknown stage " .. stage .. " (build, rescan, dedupe, queries, paraphrase, simulate, all)") end
    io.write(json.encode(out), "\n")
    os.exit(0)
end

return M
