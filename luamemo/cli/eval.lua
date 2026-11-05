-- luamemo.cli.eval
--
-- `memo eval …` — the retrieval benchmarks on this machine: R@k, MRR, the miss rate and
-- the bytes an agent reads before the right memory comes (eval/metrics.lua). None of it
-- is in the rock: the eval kit (the runners and their loaders, the personalization set,
-- the fixtures, the baselines, the dataset list) is an optional download from this
-- release's GitHub assets, checked against the checksum the rock ships
-- (luamemo/evalkit.lua); the public datasets come from their own sources, each file
-- checked against the kit's datasets.json. Nothing is downloaded or run implicitly.
--
--   memo eval status [--json] [--data DIR]
--   memo eval install [--from CHECKOUT]
--   memo eval fetch NAME… [--yes] [--data DIR]
--   memo eval run [BENCH…] [--tier quick|standard|full|corpus] [--embedder E[,E…]] [--n N]
--                 [--rerank R] [--prompts auto] [--out DIR] [--data DIR] [--keep-db] [--no-smoke]
--   memo eval history [BENCH…] [--embedder LABEL[,LABEL…]] [--json]
--   memo eval build-corpus [--stage …] [--out bench-NAME.db] …   (the 100,000-entry corpus the corpus tier runs on)
--
-- The runners never touch the user's memories: each one gets a new scratch database and
-- an environment without the MEMO_* settings (only the GGUF runtime and library paths
-- are kept), so a project's .luamemorc, a learned reranker or a projection can't change
-- the numbers. What a run keeps is its results: the newest three of each benchmark ×
-- embedder, in the project's memory (scope eval:<project>; see "history" below).
-- Exit: 0 ok, 1 failed / not possible, 2 usage.

local M = {}

local util = require("luamemo.util")
local json = require("luamemo.json")
local shq, sh, exists = util.shell_quote, util.sh, util.exists

local USAGE = [=[
usage: memo eval status [--json] [--data DIR]
       memo eval install [--from CHECKOUT]
       memo eval fetch NAME… [--yes] [--data DIR]
       memo eval run [BENCH…] [--tier quick|standard|full|corpus] [--embedder E[,E…]] [--n N]
                     [--rerank R] [--prompts auto] [--out DIR] [--data DIR] [--keep-db] [--no-smoke]
       memo eval history [BENCH…] [--embedder LABEL[,LABEL…]] [--json]
       memo eval build-corpus [--stage build|rescan|dedupe|queries|paraphrase|simulate|all] [--out bench-NAME.db]
                              [--target 100000] [--seed N] [--embedder gguf|hash] [--only a,b] [--no-notes]
                              [--queries 20000] [--paraphrase-n 5000] [--limit N] [--max-seconds N]
                              [--heavy-cycles 6] [--heavy-min 200]
  run keeps the last 3 results of each benchmark × embedder in the project's memory
  (scope eval:<project>) and prints them side by side; history shows them.
  benchmarks: personalization, session, codemap, locomo, convomem, longmemeval_oracle,
              membench, longmemeval_s, perf
  tiers:      quick = personalization, session, codemap (in the kit); standard = + locomo,
              convomem, longmemeval_oracle; full = + membench, longmemeval_s, perf
              corpus = scale, task_cost, multiscope, maintenance, learned (on the corpus that
              build-corpus makes; runs alone, not part of the others)
  embedders:  mine (the one this project uses), hash, gguf, ollama, tei — default mine,hash
  rerankers:  noop, learned, cross_encoder, ollama:<model> (e.g. ollama:gemma4:e4b)
  prompts:    auto — the embedder's task prompts (MEMO_EMBED_PROMPTS); a label of their own
]=]

-- Where the release's assets are (tests point it at a file:// directory).
M.REPO_URL = require("luamemo.embedders.native.bundle").REPO_URL

-- The kit: what `install --from` copies and eval/release/eval_kit.sh packs — one list.
M.KIT_FILES = {
    "LICENSE",
    "eval/metrics.lua",
    "eval/personalization_run.lua", "eval/locomo_run.lua", "eval/convomem_run.lua",
    "eval/longmemeval_run.lua", "eval/membench_run.lua", "eval/build_convomem_corpus.lua",
    "eval/datasets/locomo.lua", "eval/datasets/convomem.lua", "eval/datasets/longmemeval.lua",
    "eval/datasets/membench.lua",
    "eval/personalization/corpus.jsonl", "eval/personalization/queries.jsonl",
    "eval/fixtures/locomo_tiny.json", "eval/fixtures/convomem_tiny.json",
    "eval/fixtures/membench_tiny/aggregative.json", "eval/fixtures/membench_tiny/highlevel.json",
    "eval/fixtures/membench_tiny/knowledge_update.json", "eval/fixtures/membench_tiny/simple.json",
    "eval/datasets.json", "eval/baselines.json",
    "eval/session_run.lua", "eval/codemap_run.lua", "eval/perf_run.lua", "eval/codemap/queries.jsonl",
    "eval/grep_baseline.lua",
    "eval/corpus/build.lua", "eval/corpus/sources.lua", "eval/corpus/notes.lua", "eval/corpus/queries.lua",
    "eval/corpus/paraphrase.lua", "eval/corpus/simulate.lua", "eval/corpus_run.lua",
}

-- The benchmarks: the runner, the dataset it needs (datasets.json; none: in the kit) and
-- its arguments for a data directory.
M.BENCHES = {
    personalization    = { runner = "personalization_run.lua", title = "Project personalization", no_n = true },
    locomo             = { runner = "locomo_run.lua", dataset = "locomo", title = "LoCoMo",
                           args = function(d) return { "--corpus", d .. "/locomo.json" } end },
    convomem           = { runner = "convomem_run.lua", dataset = "convomem", title = "ConvoMem",
                           args = function(d) return { "--corpus", d .. "/convomem.json" } end },
    longmemeval_oracle = { runner = "longmemeval_run.lua", dataset = "longmemeval_oracle",
                           title = "LongMemEval oracle",
                           args = function(d) return { "--corpus", d .. "/longmemeval_oracle.json" } end },
    membench           = { runner = "membench_run.lua", dataset = "membench", title = "MemBench",
                           args = function(d) return { "--data-dir", d .. "/membench" } end },
    longmemeval_s      = { runner = "longmemeval_run.lua", dataset = "longmemeval_s", title = "LongMemEval _s",
                           args = function(d) return { "--corpus", d .. "/longmemeval_s.json" } end },
    -- What the agent pays before any search: the usage rules, the tool definitions, the
    -- brief (the MCP server this memo runs). Once per run — no embedder involved.
    session            = { runner = "session_run.lua", kind = "session", once = true, no_n = true,
                           title = "Session's fixed cost",
                           args = function(_, ctx) return { "--memo", ctx.memo } end },
    -- "Where is X done?" over luamemo's own modules: index_search vs grep.
    codemap            = { runner = "codemap_run.lua", title = "Code map", rerank = false },
    -- The machine's side: search latency by size, embedding / write speed, the server's
    -- start and memory, the database's size. Once per run.
    perf               = { runner = "perf_run.lua", kind = "perf", once = true, no_n = true,
                           title = "Speed and footprint",
                           args = function(_, ctx)
                               local a = { "--memo", ctx.memo }
                               local m = require("luamemo.cli.probe").gguf_model_path()
                               if m then a[#a + 1] = "--gguf-model"; a[#a + 1] = m end
                               return a
                           end },
    -- The 100,000-entry corpus (memo eval build-corpus): luamemo's own ingestion of real source trees, with
    -- labelled questions and a simulated history. Not built: these are skipped and everything else runs.
    scale              = { runner = "corpus_run.lua", kind = "retrieval", once = true, corpus = true, rerank = false,
                           title = "Corpus: retrieval at scale",
                           args = function(_, ctx) return { "--suite", "scale", "--db", ctx.corpus_db, "--gguf-model", ctx.gguf_model } end },
    learned            = { runner = "corpus_run.lua", kind = "learned", once = true, corpus = true, no_n = true,
                           title = "Corpus: learned reranker",
                           args = function(_, ctx) return { "--suite", "learned", "--db", ctx.corpus_db, "--gguf-model", ctx.gguf_model } end },
    multiscope         = { runner = "corpus_run.lua", kind = "multiscope", once = true, corpus = true, rerank = false,
                           title = "Corpus: searching several scopes",
                           args = function(_, ctx) return { "--suite", "multiscope", "--db", ctx.corpus_db, "--gguf-model", ctx.gguf_model } end },
    maintenance        = { runner = "corpus_run.lua", kind = "maintenance", once = true, corpus = true, no_n = true,
                           title = "Corpus: maintenance (consolidation)",
                           args = function(_, ctx) return { "--suite", "maintenance", "--db", ctx.corpus_db, "--gguf-model", ctx.gguf_model } end },
    task_cost          = { runner = "corpus_run.lua", kind = "retrieval", once = true, corpus = true, rerank = false,
                           title = "Corpus: bytes an agent reads (code map vs grep)",
                           args = function(_, ctx) return { "--suite", "task_cost", "--db", ctx.corpus_db, "--gguf-model", ctx.gguf_model } end },
}
M.ORDER = { "personalization", "session", "codemap", "locomo", "convomem", "longmemeval_oracle", "membench",
            "longmemeval_s", "perf", "scale", "task_cost", "multiscope", "maintenance", "learned" }
M.TIERS = {
    corpus   = { "scale", "task_cost", "multiscope", "maintenance", "learned" },
    quick    = { "personalization", "session", "codemap" },
    standard = { "personalization", "session", "codemap", "locomo", "convomem", "longmemeval_oracle" },
    full     = { "personalization", "session", "codemap", "locomo", "convomem", "longmemeval_oracle", "membench",
                 "longmemeval_s", "perf" },
}
-- Each runner on the kit's tiny fixtures, with hash, before the real runs: does it run
-- here at all (a few seconds; no numbers reported).
M.SMOKE = {
    { name = "locomo", runner = "locomo_run.lua", args = { "--corpus", "eval/fixtures/locomo_tiny.json" } },
    { name = "convomem", runner = "convomem_run.lua", args = { "--corpus", "eval/fixtures/convomem_tiny.json" } },
    { name = "membench", runner = "membench_run.lua", args = { "--data-dir", "eval/fixtures/membench_tiny",
        "--cats", "aggregative,highlevel,knowledge_update,simple", "--k-max", "5" } },
}
-- A built dataset's file (the runner reads it; datasets.json lists what it's built from).
local BUILT = { convomem = "convomem.json" }
-- Downloads above this need --yes.
M.BIG = 50 * 1024 * 1024
-- The flags against the baseline: R@1 down by this much (a fraction), bytes-to-hit up by
-- this share.
M.DROP_R1, M.MORE_BYTES = 0.01, 0.10

-- ── files ────────────────────────────────────────────────────────────────────

local function version() return require("luamemo").VERSION end
local function data_home() return require("luamemo.db").data_dir() end
function M.kit_dir(v) return data_home() .. "/eval-kit/" .. (v or version()) end
function M.default_data() return data_home() .. "/eval-data" end

local function read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    local ok, v = pcall(json.decode, text)
    return ok and type(v) == "table" and v or nil
end

local function write_file(path, text)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(text); f:close()
    return true
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end"); f:close()
    return n
end

local function mkdir_p(dir) os.execute("mkdir -p " .. shq(dir)) end

-- rm -rf, only under luamemo's own eval directories (a wrong path never goes further).
local function remove_tree(path)
    local home = data_home() .. "/eval-"
    if path:sub(1, #home) ~= home or path:find("/%.%./") then return false end
    return os.execute("rm -rf " .. shq(path)) == 0
end

local function size_text(n)
    if n >= 1048576 then return ("%.1f MB"):format(n / 1048576) end
    if n >= 1024 then return ("%.1f KB"):format(n / 1024) end
    return n .. " bytes"
end

local function ok_exec(r) return r == 0 or r == true end

-- The file's SHA-256, hex: sha256sum / shasum (they stream), else in process (libsodium).
local function sha256_file(path)
    for _, cmd in ipairs({ "sha256sum", "shasum -a 256" }) do
        if sh("command -v " .. cmd:match("^%S+")) ~= "" then
            local hex = sh(cmd .. " " .. shq(path)):match("^(%x+)")
            if hex and #hex == 64 then return hex:lower() end
        end
    end
    local f = io.open(path, "rb")
    if not f then return "" end
    local data = f:read("*a"); f:close()
    local ok, digest = pcall(require("luamemo.native.sodium").sha256, data or "")
    return ok and util.to_hex(digest):lower() or ""
end

-- HTTPS only, redirects too (file:// only when a test points REPO_URL at a directory).
local function download(url, dest)
    local file = url:match("^file://") ~= nil
    local proto = file and "--proto =file" or "--proto =https --proto-redir =https --tlsv1.2"
    return ok_exec(os.execute(("curl -fsSL %s --retry 2 -o %s %s"):format(proto, shq(dest), shq(url))))
end

-- ── the kit ──────────────────────────────────────────────────────────────────

--- The installed kit for this luamemo: its kit.json (+ dir), or nil.
function M.kit(v)
    local dir = M.kit_dir(v)
    local info = read_json(dir .. "/kit.json")
    if not (info and exists(dir .. "/eval/metrics.lua")) then return nil end
    info.dir = dir
    return info
end

--- The checksum this rock ships for its own kit: { version, sha256, asset } or nil.
function M.release_entry(v)
    v = v or version()
    local ok, sums = pcall(require, "luamemo.evalkit")
    if ok and type(sums) == "table" and sums.version == v and type(sums.sha256) == "string"
        and type(sums.asset) == "string" then
        return sums
    end
    return nil
end

-- Move a staged kit into place (the old one, if any, goes).
local function put_kit(stage_kit, v, info)
    info.version, info.installed = v, os.date("!%Y-%m-%dT%H:%M:%SZ")
    local ok, err = write_file(stage_kit .. "/kit.json", json.encode(info) .. "\n")
    if not ok then return nil, err end
    local dir = M.kit_dir(v)
    remove_tree(dir)
    if not ok_exec(os.execute(("mv %s %s"):format(shq(stage_kit), shq(dir)))) then
        return nil, "couldn't move the kit into " .. dir
    end
    return dir
end

--- Download this release's kit, check it against the rock's checksum, unpack it. → dir |
--- nil, why. Nothing is run; nothing is left behind on a failure.
function M.install_release(v, say)
    v, say = v or version(), say or function(_) end
    local entry = M.release_entry(v)
    if not entry then
        return nil, ("this luamemo (%s) ships no eval kit checksum — a checkout: memo eval install "
            .. "--from <the checkout>"):format(v)
    end
    for _, cmd in ipairs({ "curl", "tar" }) do
        if sh("command -v " .. cmd) == "" then return nil, cmd .. " is needed to download the eval kit" end
    end
    local parent = data_home() .. "/eval-kit"
    mkdir_p(parent)
    local tmp = parent .. "/." .. entry.asset .. ".part"
    local url = ("%s/releases/download/v%s/%s"):format(M.REPO_URL, v, entry.asset)
    say("downloading " .. url)
    if not download(url, tmp) then os.remove(tmp); return nil, "download failed: " .. url end
    local got = sha256_file(tmp)
    if got ~= entry.sha256:lower() then
        os.remove(tmp)
        return nil, ("the download doesn't match the checksum this release ships (got %s, want %s) — "
            .. "not installed"):format(got ~= "" and got or "?", entry.sha256:lower())
    end
    local stage = parent .. "/." .. v .. ".new"
    remove_tree(stage); mkdir_p(stage)
    local tok = os.execute(("tar -xzf %s -C %s"):format(shq(tmp), shq(stage)))
    os.remove(tmp)
    local top = stage .. "/luamemo-evalkit-" .. v
    if not ok_exec(tok) or not exists(top .. "/eval/metrics.lua") then
        remove_tree(stage)
        return nil, "unpacking failed (not an eval kit for " .. v .. ")"
    end
    local dir, err = put_kit(top, v, { source = "release", asset = entry.asset, sha256 = entry.sha256:lower() })
    remove_tree(stage)
    return dir, err
end

--- The kit from a checkout of the same version (developers). → dir | nil, why.
function M.install_from(checkout, v)
    v = v or version()
    local root = util.real_dir(checkout)
    if not root then return nil, "no directory " .. tostring(checkout) end
    local init = util.read_file(root .. "/luamemo/init.lua") or ""
    local have = init:match('\nM%.VERSION = "([^"]+)"')
    if not have then return nil, root .. " is not a luamemo checkout (no luamemo/init.lua VERSION)" end
    if have ~= v then
        return nil, ("that checkout is luamemo %s, this luamemo is %s — the kit's runners must match the "
            .. "library they measure (check out v%s, or install that version)"):format(have, v, v)
    end
    local missing = {}
    for _, f in ipairs(M.KIT_FILES) do
        if not exists(root .. "/" .. f) then missing[#missing + 1] = f end
    end
    if #missing > 0 then return nil, "the checkout lacks " .. table.concat(missing, ", ") end
    local parent = data_home() .. "/eval-kit"
    local stage = parent .. "/." .. v .. ".new"
    remove_tree(stage)
    for _, f in ipairs(M.KIT_FILES) do
        local dest = stage .. "/" .. f
        mkdir_p(dest:match("^(.*)/[^/]+$"))
        local data = util.read_file(root .. "/" .. f)
        local ok, err = write_file(dest, data or "")
        if not (data and ok) then remove_tree(stage); return nil, "copying " .. f .. ": " .. tostring(err) end
    end
    return put_kit(stage, v, { source = "checkout", from = root })
end

-- ── datasets ─────────────────────────────────────────────────────────────────

local function datasets(kit)
    local d = read_json(kit.dir .. "/eval/datasets.json")
    return d and type(d.datasets) == "table" and d.datasets or {}
end

local function total_bytes(ds)
    local n = 0
    for _, f in ipairs(ds.files or {}) do n = n + (tonumber(f.bytes) or 0) end
    return n
end

--- Is a dataset there? A built one: its built file; else each file at its size (the
--- checksums are checked when it is fetched).
function M.present(ds, data)
    if ds.build then return exists(data .. "/" .. BUILT[ds.build]) end
    for _, f in ipairs(ds.files or {}) do
        if file_size(data .. "/" .. f.path) ~= tonumber(f.bytes) then return false end
    end
    return true
end

-- The interpreter, and the module paths of this process (the rock's), for a runner.
local function lua_bin() return util.env("MEMO_LUA") or "luajit" end

-- The MEMO_* variables a runner keeps: where the GGUF runtime is and its GPU layers (speed
-- only), and the native libraries' paths (MEMO_LIB_*). Every other one is removed — a
-- setting there (hybrid weights, a learned reranker, a context size) changes the numbers.
local KEEP_ENV = { MEMO_GGUF_SHIM = true, MEMO_GEMMA_SHIM = true, MEMO_GGUF_NGL = true, MEMO_GEMMA_NGL = true }

local function memo_vars()
    local ffi = require("ffi")
    pcall(ffi.cdef, "extern char **environ;")
    local out, i = {}, 0
    while ffi.C.environ[i] ~= nil do
        local k = ffi.string(ffi.C.environ[i]):match("^([^=]+)=")
        if k and k:match("^MEMO_") and not (KEEP_ENV[k] or k:match("^MEMO_LIB_")) then out[#out + 1] = k end
        i = i + 1
    end
    table.sort(out)
    return out
end

--- `cd KIT && env -u … K=V … luajit eval/<file> args`, its output into log (M. for the
--- tests: what a runner's environment holds).
function M.kit_command(kit, file, args, env, log)
    local parts = { "cd", shq(kit.dir), "&&", "env" }
    for _, k in ipairs(memo_vars()) do parts[#parts + 1] = "-u " .. k end
    local keys = {}
    for k in pairs(env) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. shq(env[k]) end
    parts[#parts + 1] = "LUA_PATH=" .. shq(package.path)
    parts[#parts + 1] = "LUA_CPATH=" .. shq(package.cpath)
    parts[#parts + 1] = shq(lua_bin())
    parts[#parts + 1] = shq("eval/" .. file)
    for _, a in ipairs(args) do parts[#parts + 1] = shq(a) end
    -- log: a file for the output; nil: dropped; false: the terminal's (a long build shows its progress)
    if log ~= false then parts[#parts + 1] = log and (">" .. shq(log) .. " 2>&1") or ">/dev/null 2>&1" end
    return table.concat(parts, " ")
end

--- Fetch datasets into `data`. opts.yes: allow the big ones; opts.say. → true | nil, why.
function M.fetch(kit, names, opts)
    opts = opts or {}
    local say = opts.say or function(_) end
    local data = opts.data or M.default_data()
    local all, plan, big = datasets(kit), {}, 0
    for _, name in ipairs(names) do
        local ds = all[name]
        if not ds then
            local known = {}
            for k in pairs(all) do known[#known + 1] = k end
            table.sort(known)
            return nil, ("no dataset %q (%s)"):format(name, table.concat(known, ", "))
        end
        plan[#plan + 1] = { name = name, ds = ds }
        if not M.present(ds, data) then big = big + total_bytes(ds) end
    end
    for _, p in ipairs(plan) do
        say(("%s: %s — %d file(s), %s, from %s (the dataset's own license applies)"):format(p.name,
            p.ds.title or p.name, #p.ds.files, size_text(total_bytes(p.ds)), p.ds.source or "?"))
    end
    if big > M.BIG and not opts.yes then
        return nil, ("that is %s to download — rerun with --yes to fetch it"):format(size_text(big))
    end
    if sh("command -v curl") == "" then return nil, "curl is needed to download the datasets" end
    mkdir_p(data)
    for _, p in ipairs(plan) do
        for _, f in ipairs(p.ds.files) do
            local dest = data .. "/" .. f.path
            mkdir_p(dest:match("^(.*)/[^/]+$"))
            if file_size(dest) == tonumber(f.bytes) and sha256_file(dest) == f.sha256 then
                say("  " .. f.path .. ": already there")
            else
                say("  " .. f.path .. ": downloading " .. size_text(tonumber(f.bytes) or 0))
                local part = dest .. ".part"
                if not download(f.url, part) then os.remove(part); return nil, "download failed: " .. f.url end
                local got = sha256_file(part)
                if got ~= f.sha256 then
                    os.remove(part)
                    return nil, ("%s differs from the copy the baselines were measured on (sha256 %s, want %s) — "
                        .. "not kept"):format(f.url, got, f.sha256)
                end
                os.rename(part, dest)
            end
        end
        if p.ds.build == "convomem" and not exists(data .. "/" .. BUILT.convomem) then
            say("  building " .. BUILT.convomem)
            local log = data .. "/convomem_build.log"
            local cmd = M.kit_command(kit, "build_convomem_corpus.lua",
                { "--in", data .. "/convomem_raw", "--out", data .. "/" .. BUILT.convomem }, {}, log)
            if not ok_exec(os.execute(cmd)) or not exists(data .. "/" .. BUILT.convomem) then
                return nil, "building " .. BUILT.convomem .. " failed — " .. log
            end
        end
    end
    return true
end

-- ── embedders ────────────────────────────────────────────────────────────────

local function basename(p) return (p:match("([^/]+)$") or p):gsub("%.gguf$", "") end

-- The embedder this project uses (memo sourced its .luamemorc): name, config | nil, why.
local function mine()
    local common = require("luamemo.cli._common")
    local env = common.embed_env()
    local cfg = common.embed_config(env)
    if cfg.embedder_url then
        local a = cfg.embedder_adapter
        if a == "ollama" or a == "tei" then return a, cfg, env end
        return nil, ("this project's embedder is an HTTP API (%s) — memo eval runs local embedders only "
            .. "(hash, gguf, ollama, tei)"):format(tostring(a))
    end
    if cfg.embedder_local == "gguf_ffi" then return "gguf", cfg, env end
    return "hash", cfg, env   -- hash, hash_learned, projected: the base (a learned part is the user's)
end

--- An embedder for the runners: { name, label, env } | nil, why. name: hash, gguf,
--- ollama, tei or mine.
function M.embedder(name)
    local cfg, env = {}, {}
    if name == "mine" then
        local n, c, e = mine()
        if not n then return nil, c end
        name, cfg, env = n, c, e
    end
    if name == "hash" then return { name = "hash", label = "hash", env = {} } end
    -- gguf:<model>: another GGUF embedding model than the configured one — a path, or a
    -- name in ~/models (gguf:embeddinggemma-2-Q8_0); its dimension is the model's own.
    local pick = name:match("^gguf:(.+)$")
    if pick then
        local path = exists(pick) and pick or ((os.getenv("HOME") or "") .. "/models/" .. pick:gsub("%.gguf$", "") .. ".gguf")
        if not exists(path) then return nil, "no GGUF model " .. pick .. " (a path, or a name in ~/models)" end
        local code = ("local g = require('luamemo.embedders.gguf_ffi') io.write(tostring(g.dim({ embedder_model = %q })))")
            :format(path)
        local dim = tonumber(sh(("LUA_PATH=%s %s -e %s"):format(shq(package.path), shq(lua_bin()), shq(code))))
        if not dim then return nil, "the GGUF model doesn't load: " .. path .. " (memo gguf status)" end
        cfg, env, name = { gguf_model = path }, { MEMO_EMBED_DIM = tostring(dim) }, "gguf"
    end
    if name == "gguf" then
        local model = cfg.gguf_model or require("luamemo.cli.probe").gguf_model_path()
        if not (model and exists(model)) then
            return nil, "no GGUF model found (MEMO_GGUF_MODEL, or ~/models/"
                .. require("luamemo.cli.probe").GGUF_DEFAULT_MODEL .. ") — memo gguf status"
        end
        -- On a GPU (MEMO_GGUF_NGL, kept for the runners) the vectors differ slightly from the
        -- CPU's: its results are a label of their own, never compared with the CPU's.
        local ngl = util.env("MEMO_GGUF_NGL") or util.env("MEMO_GEMMA_NGL")
        local gpu = ngl and ngl ~= "0"
        return { name = "gguf", label = "gguf:" .. basename(model) .. (gpu and "@gpu" or ""),
                 env = { MEMO_GGUF_MODEL = model, MEMO_GGUF_DIM = env.MEMO_EMBED_DIM or "768" } }
    end
    if name == "ollama" or name == "tei" then
        local up = name:upper()
        local own = cfg.embedder_adapter == name
        local url = own and cfg.embedder_url or util.env(up .. "_URL")
            or (name == "ollama" and "http://127.0.0.1:11434/api/embeddings" or "http://127.0.0.1:8081/embed")
        local model = own and cfg.embedder_model or util.env(up .. "_MODEL")
            or (name == "ollama" and "nomic-embed-text" or "BAAI/bge-m3")
        local dim = own and env.MEMO_EMBED_DIM or util.env(up .. "_DIM") or (name == "ollama" and "768" or "1024")
        -- The longest text sent (the runners send whole sessions; 0 = all): within the
        -- model's context — nomic-embed-text 2048 tokens; bge-m3 8192, and a TEI asked for
        -- more than its batch-token limit holds the request until the timeout. The
        -- published numbers were measured with these.
        local max_chars = util.env("EMBED_MAX_CHARS") or (name == "ollama" and "8000" or "24000")
        return { name = name, label = name .. ":" .. model,
                 env = { [up .. "_URL"] = url, [up .. "_MODEL"] = model, [up .. "_DIM"] = dim,
                         EMBED_MAX_CHARS = max_chars } }
    end
    return nil, ("unknown embedder %q (mine, hash, gguf, gguf:<model>, ollama, tei)"):format(tostring(name))
end

--- The embedder a benchmark database was built with, as "<model>" (its lm_meta bench_embedder), or nil.
function M.corpus_embedder(path)
    local h = require("luamemo.db").open(path, { readonly = true })
    if not h then return nil end
    local sig = h.value("SELECT value FROM lm_meta WHERE key = 'bench_embedder'")
    h.close()
    local name, model = tostring(sig or ""):match("^([^|]*)|([^|]*)|")
    if not name then return nil end
    return (model ~= "" and model:gsub("%.gguf$", "") or name)
end

--- A reranker for the retrieval runs: noop | learned | cross_encoder | ollama:<model>
--- (a local Ollama's chat model, e.g. ollama:gemma4:e4b). → { label, args, env } | nil, why.
function M.rerank_spec(spec)
    local adapter, model = tostring(spec):match("^([%a_]+):?(.*)$")
    local env = {}
    if adapter == "ollama" then
        if model == "" then return nil, "--rerank ollama:<model>, e.g. ollama:gemma4:e4b" end
        local base = (util.env("OLLAMA_URL") or "http://127.0.0.1:11434"):gsub("/api/.*$", "")
        env.OLLAMA_RERANK_URL, env.OLLAMA_RERANK_MODEL = base .. "/api/generate", model
    elseif adapter == "cross_encoder" then
        env.RERANK_URL = util.env("RERANK_URL") or "http://127.0.0.1:8080/rerank"
        env.RERANK_MODEL = model ~= "" and model or util.env("RERANK_MODEL") or "BAAI/bge-reranker-v2-m3"
    elseif adapter == "noop" or adapter == "learned" then
        if model ~= "" then return nil, adapter .. " takes no model" end
    else
        return nil, ("unknown reranker %q (noop, learned, cross_encoder, ollama:<model>)"):format(tostring(spec))
    end
    return { label = adapter .. (model ~= "" and (":" .. model) or ""), env = env,
             args = { "--rerank", "--rerank-adapter", adapter, "--rerank-top-n", "20" } }
end

-- ── runs ─────────────────────────────────────────────────────────────────────

local function slug(s) return (s:gsub("[^%w%.%-]+", "_")) end
local function pct(v) return v and ("%.1f"):format(v * 100) or "—" end
local function num(v, f) return v and (f or "%.0f"):format(v) or "—" end
-- A change in points ("+1.2", 0 under 0.05) / in percent ("+3 %", 0 under half a percent).
local function pts(now, prev)
    local d = ((now or 0) - (prev or 0)) * 100
    return ("%+.1f"):format(math.abs(d) < 0.05 and 0 or d)
end
local function rel(now, prev)
    if not (now and prev and prev ~= 0) then return "—" end
    local d = (now - prev) / prev * 100
    return ("%+.0f %%"):format(math.abs(d) < 0.5 and 0 or d)
end
local function more_than(now, prev, share) return now and prev and prev > 0 and (now - prev) / prev >= share - 1e-9 end

-- What a kind of benchmark reports: the figures its result keeps (the history and the
-- baselines), its table's columns ({ header, cell(entry), when = a key only some results
-- have }), what changed between two of its results, and its flags against the published
-- baseline (compare = nil: machine-dependent, not compared).
M.KINDS = {
    retrieval = {
        keys = { "n_questions", "recall@1", "recall@5", "recall@10", "mrr", "miss_rate", "bytes_to_hit_mean",
                 "bytes_to_hit_median", "bytes_to_hit_p90", "est_tokens_to_hit_mean", "bytes_on_miss_mean",
                 "embed_max_chars", "rerank_ms_mean", "rerank_ms_p90", "rerank_tokens_mean", "rerank_failed",
                 "grep_bytes_to_hit_mean", "grep_bytes_to_hit_median", "grep_miss_rate",
                 "search_ms_p50", "search_ms_p95" },
        columns = {
            { "n", function(e) return num(e.n_questions) end },
            { "R@1", function(e) return pct(e["recall@1"]) end },
            { "R@5", function(e) return pct(e["recall@5"]) end },
            { "R@10", function(e) return pct(e["recall@10"]) end },
            { "MRR", function(e) return num(e.mrr, "%.3f") end },
            { "Miss rate", function(e) return pct(e.miss_rate) .. " %" end },
            { "Bytes to hit (mean / median)",
              function(e) return num(e.bytes_to_hit_mean) .. " / " .. num(e.bytes_to_hit_median) end },
            { "Rerank per search (ms / tokens)", when = "rerank_ms_mean", function(e)
                return num(e.rerank_ms_mean) .. " / " .. num(e.rerank_tokens_mean)
                    .. ((e.rerank_failed or 0) > 0 and (" · " .. e.rerank_failed .. " failed") or "") end },
            { "grep instead (bytes to hit / miss)", when = "grep_bytes_to_hit_mean",
              function(e) return num(e.grep_bytes_to_hit_mean) .. " / " .. pct(e.grep_miss_rate) .. " %" end },
            { "Search ms (p50 / p95)", when = "search_ms_p50",
              function(e) return num(e.search_ms_p50) .. " / " .. num(e.search_ms_p95) end },
        },
        change = function(now, prev)
            if now.n_questions ~= prev.n_questions then return "another n — not compared" end
            return ("R@1 %s pts · miss %s pts · bytes %s"):format(pts(now["recall@1"], prev["recall@1"]),
                pts(now.miss_rate, prev.miss_rate), rel(now.bytes_to_hit_mean, prev.bytes_to_hit_mean))
        end,
        compare = function(row, base)
            if base.n_questions ~= row.n_questions then return { "n differs from the baseline's — not compared" } end
            local out = {}
            local d1 = (row["recall@1"] or 0) - (base["recall@1"] or 0)
            if d1 <= -M.DROP_R1 + 1e-9 then out[#out + 1] = ("R@1 %.1f pts below the baseline"):format(-d1 * 100) end
            if more_than(row.bytes_to_hit_mean, base.bytes_to_hit_mean, M.MORE_BYTES) then
                out[#out + 1] = ("bytes-to-hit %.0f %% above the baseline"):format(
                    (row.bytes_to_hit_mean - base.bytes_to_hit_mean) / base.bytes_to_hit_mean * 100)
            end
            return out
        end,
    },
    -- The learned reranker's learning curve on the corpus: for each number of outcomes it trained on,
    -- how many projects the promotion gate let through and the change in R@1 on their eval queries
    -- (paired with the same queries without it). Simulated outcomes — read with that caveat.
    learned = {
        keys = { "n_questions", "recall@1", "mrr", "learned_promoted_100", "learned_d_r1_100", "learned_n_eval_100",
                 "learned_promoted_1000", "learned_d_r1_1000", "learned_n_eval_1000",
                 "learned_promoted_10000", "learned_d_r1_10000", "learned_n_eval_10000" },
        columns = (function()
            local cols = { { "Eval queries", function(e) return num(e.n_questions) end },
                           { "R@1 without", function(e) return pct(e["recall@1"]) end } }
            for _, p in ipairs({ "100", "1000", "10000" }) do
                cols[#cols + 1] = { ("ΔR@1 after %s outcomes (projects promoted)"):format(p), when = "learned_d_r1_" .. p, function(e)
                    return ("%+.2f pts (%s)"):format((e["learned_d_r1_" .. p] or 0) * 100, num(e["learned_promoted_" .. p])) end }
            end
            return cols
        end)(),
        change = function(now, prev)
            return ("ΔR@1 at 10,000 outcomes %s pts"):format(pts(now.learned_d_r1_10000, prev.learned_d_r1_10000))
        end,
        compare = function() return {} end,
    },
    -- Widening a search: the same questions over 1, 2, 4 and 8 scopes (the right one plus seeded distractors),
    -- and the project's own repo: + codeindex: pair against the right scope alone.
    multiscope = {
        keys = { "n_questions", "s1_r1", "s2_r1", "s4_r1", "s8_r1", "s1_r10", "s2_r10", "s4_r10", "s8_r10",
                 "s1_ms_p50", "s8_ms_p50", "s8_ms_p95", "pair_n", "pair_r1", "pair_single_r1" },
        columns = {
            { "n", function(e) return num(e.n_questions) end },
            { "R@1 over 1 · 2 · 4 · 8 scopes", function(e)
                return pct(e.s1_r1) .. " · " .. pct(e.s2_r1) .. " · " .. pct(e.s4_r1) .. " · " .. pct(e.s8_r1) end },
            { "R@10 over 1 · 2 · 4 · 8 scopes", function(e)
                return pct(e.s1_r10) .. " · " .. pct(e.s2_r10) .. " · " .. pct(e.s4_r10) .. " · " .. pct(e.s8_r10) end },
            { "Search ms p50: 1 scope / 8 scopes (p95)", function(e)
                return num(e.s1_ms_p50) .. " / " .. num(e.s8_ms_p50) .. " (" .. num(e.s8_ms_p95) .. ")" end },
            { "Project pair R@1 (right scope alone) n", function(e)
                return pct(e.pair_r1) .. " (" .. pct(e.pair_single_r1) .. ") " .. num(e.pair_n) end },
        },
        change = function(now, prev)
            return ("R@1 over 8 scopes %s pts · over 1 scope %s pts"):format(pts(now.s8_r1, prev.s8_r1), pts(now.s1_r1, prev.s1_r1))
        end,
        compare = function() return {} end,
    },
    -- Consolidation on a copy: the cost of the near-duplicate search by working-set size, what is redundant,
    -- and recall before and after collapsing it.
    maintenance = {
        keys = { "big_rows", "big_cons_ms_500", "big_cons_ms_1000", "big_cons_ms_2000", "big_cons_ms_5000",
                 "big_redundant_1000", "big_redundant_5000", "big_collapsed", "big_r10_before", "big_r10_after",
                 "big_largest_group", "big_r10_after_95", "repo_rows", "repo_cons_ms_1000", "repo_redundant_1000",
                 "repo_collapsed", "repo_collapsed_95", "repo_largest_group", "repo_largest_group_95", "repo_r10_before",
                 "repo_r10_after", "repo_r10_after_95", "digest_ms", "summarize_ms" },
        columns = {
            { "Largest scope rows", function(e) return num(e.big_rows) end },
            { "Consolidate ms over 500 · 1000 · 2000 · 5000 rows", function(e)
                return num(e.big_cons_ms_500) .. " · " .. num(e.big_cons_ms_1000) .. " · " .. num(e.big_cons_ms_2000)
                    .. " · " .. num(e.big_cons_ms_5000) end },
            { "Redundant rows (over 1000 / 5000)", function(e)
                return num(e.big_redundant_1000) .. " / " .. num(e.big_redundant_5000) end },
            { "R@10 before → after collapsing the groups at 0.85 (0.95): largest scope", function(e)
                return pct(e.big_r10_before) .. " → " .. pct(e.big_r10_after) .. " (" .. pct(e.big_r10_after_95) .. ")" end },
            { "… repo scope: rows collapsed (largest group), R@10", function(e)
                return num(e.repo_collapsed) .. " (" .. num(e.repo_largest_group) .. ") " .. pct(e.repo_r10_before) .. " → "
                    .. pct(e.repo_r10_after) .. " · at 0.95: " .. num(e.repo_collapsed_95) .. " (" .. num(e.repo_largest_group_95)
                    .. ") → " .. pct(e.repo_r10_after_95) end },
            { "Digest / summarize dry run ms", function(e) return num(e.digest_ms) .. " / " .. num(e.summarize_ms) end },
        },
        change = function(now, prev)
            return ("consolidate over 1000 rows %s"):format(rel(now.big_cons_ms_1000, prev.big_cons_ms_1000))
        end,
        compare = function() return {} end,
    },
    session = {
        keys = { "instructions_bytes", "tools_bytes", "tools_core_bytes", "n_tools", "n_tools_core", "brief_bytes",
                 "session_bytes", "session_core_bytes" },
        columns = {
            { "Usage rules", function(e) return num(e.instructions_bytes) end },
            { "Tool definitions: all (n) / core (n)", function(e)
                return ("%s (%s) / %s (%s)"):format(num(e.tools_bytes), num(e.n_tools), num(e.tools_core_bytes),
                    num(e.n_tools_core)) end },
            { "Brief", function(e) return num(e.brief_bytes) end },
            { "Total bytes: all / core", function(e) return num(e.session_bytes) .. " / " .. num(e.session_core_bytes) end },
            { "≈ Tokens: all / core", function(e)
                return num(e.session_bytes and e.session_bytes / 4) .. " / "
                    .. num(e.session_core_bytes and e.session_core_bytes / 4) end },
        },
        change = function(now, prev)
            return ("total %s · core %s"):format(rel(now.session_bytes, prev.session_bytes),
                rel(now.session_core_bytes, prev.session_core_bytes))
        end,
        compare = function(row, base)
            if more_than(row.session_bytes, base.session_bytes, M.MORE_BYTES) then
                return { ("the session's fixed cost %.0f %% above the baseline"):format(
                    (row.session_bytes - base.session_bytes) / base.session_bytes * 100) }
            end
            return {}
        end,
    },
    perf = {
        keys = { "search_ms_p50_1k", "search_ms_p95_1k", "search_ms_p50_20k", "search_ms_p95_20k",
                 "search_ms_p50_100k", "search_ms_p95_100k", "dim", "embed_ms_hash", "embed_ms_gguf",
                 "writes_per_s_hash", "writes_per_s_gguf", "cold_start_ms", "first_search_ms", "rss_idle_mb",
                 "rss_search_mb", "rss_gguf_mb", "db_kb_per_1k" },
        columns = {
            { "Search p50 / p95 ms at 1k · 20k · 100k", function(e)
                local function c(n) return num(e["search_ms_p50_" .. n], "%.1f") .. "/" .. num(e["search_ms_p95_" .. n], "%.1f") end
                return c("1k") .. " · " .. c("20k") .. " · " .. c("100k") end },
            { "Query embed ms: hash / gguf", function(e)
                return num(e.embed_ms_hash, "%.2f") .. " / " .. num(e.embed_ms_gguf, "%.0f") end },
            { "Writes/s: hash / gguf", function(e) return num(e.writes_per_s_hash) .. " / " .. num(e.writes_per_s_gguf, "%.1f") end },
            { "Server start / first search ms", function(e) return num(e.cold_start_ms) .. " / " .. num(e.first_search_ms) end },
            { "Server MB: idle / searching / gguf", function(e)
                return num(e.rss_idle_mb, "%.1f") .. " / " .. num(e.rss_search_mb, "%.1f") .. " / " .. num(e.rss_gguf_mb) end },
            { "DB KB per 1k", function(e) return num(e.db_kb_per_1k) end },
        },
        change = function(now, prev)
            return ("search at 100k %s · start %s"):format(rel(now.search_ms_p50_100k, prev.search_ms_p50_100k),
                rel(now.cold_start_ms, prev.cold_start_ms))
        end,
        -- compare = nil: what a machine measures says nothing about another; its history compares
    },
}

--- The flags of one result against its baseline (same benchmark, embedder and n).
function M.compare(row, base, kind)
    if not base then return { "no baseline" } end
    local k = M.KINDS[kind or "retrieval"]
    if not k.compare then return { "machine-dependent — not compared" } end
    return k.compare(row, base)
end

-- ── history: the last results of each benchmark × embedder, kept in memory ──────
-- After a full run (a partial one, --n, compares with nothing), the newest M.HISTORY
-- results of each benchmark × embedder are kept as one memory in the project's database,
-- scope eval:<project> (out of the project's own searches). The run's table compares
-- them, `memo eval history` shows them, and an agent can search them; the results
-- directory is only the run's detail.

M.HISTORY = 3
local ORDER_OF = {}
for i, b in ipairs(M.ORDER) do ORDER_OF[b] = i end
local function kind_of(bench) return (M.BENCHES[bench] or {}).kind or "retrieval" end

--- A history entry from a run's result (numbers rounded as they are kept).
function M.entry(s, when, kind)
    local e = { measured = when or os.date("!%Y-%m-%d %H:%M"), luamemo = version() }
    for _, k in ipairs(M.KINDS[kind or "retrieval"].keys) do
        local v = s[k]
        if type(v) == "number" then v = math.floor(v * 1e6 + 0.5) / 1e6 end
        e[k] = v
    end
    return e
end

--- What changed from the previous entry ("R@1 +1.2 pts · miss -0.5 pts · bytes -3 %") | nil.
function M.change(now, prev, kind)
    if not (now and prev) then return nil end
    return M.KINDS[kind or "retrieval"].change(now, prev)
end

--- The scope the history is kept in: eval:<project> (MEMO_SCOPE without its prefix).
function M.history_scope()
    local scope = util.env("MEMO_SCOPE")
    local project = scope and scope:gsub("^%a+:", "")
    if not project or project == "" then
        project = require("luamemo.settings").project_dir():match("([^/]+)/*$") or "default"
    end
    return "eval:" .. project
end

-- The project's memory (memo sourced its settings) | nil, why. read_only: only a database
-- that exists already (status / history never create one).
local _memory, _memory_err
local function project_memory(read_only)
    if _memory or _memory_err then return _memory, _memory_err end
    if read_only then
        local path, perr = require("luamemo.db").path()
        if not path then return nil, perr end
        if path ~= ":memory:" and not exists(path) then return nil, "no database at " .. path .. " yet" end
    end
    local memory = require("luamemo")
    local cfg = require("luamemo.cli._common").config_from_env({ warn = false })
    cfg.skip_embed_probe = true
    local ok, err = pcall(memory.setup, cfg)
    if ok then _memory = memory else _memory_err = tostring(err) end
    return _memory, _memory_err
end

-- The history memories of the scope: { [benchmark|label] = row }, the newest of each.
local function history_rows(memory, scope)
    local out = {}
    for _, r in ipairs(memory.recent({ scope = scope, kind = "eval", limit = 200 }) or {}) do
        local md = type(r.metadata) == "table" and r.metadata or {}
        if type(md.eval_key) == "string" and not out[md.eval_key] then out[md.eval_key] = r end
    end
    return out
end

-- The cells as tables, one per kind (in the order their benchmarks come): each a list of
-- rows of cell texts, the header first. md: "(now)" marks the newest, else "*".
local function tables_of(cells, md)
    local groups, order = {}, {}
    for _, c in ipairs(cells) do
        local k = c.kind or kind_of(c.bench)
        if not groups[k] then groups[k] = {}; order[#order + 1] = k end
        groups[k][#groups[k] + 1] = c
    end
    local out = {}
    for _, k in ipairs(order) do
        local cols = {}
        for _, col in ipairs(M.KINDS[k].columns) do
            local show = not col.when
            for _, c in ipairs(groups[k]) do
                for _, e in ipairs(c.history) do if col.when and e[col.when] ~= nil then show = true end end
            end
            if show then cols[#cols + 1] = col end
        end
        local header = { md and "Benchmark" or "benchmark", md and "Embedder" or "embedder",
                         md and "Measured" or "measured", "luamemo" }
        for _, col in ipairs(cols) do header[#header + 1] = col[1] end
        header[#header + 1] = md and "Change vs the one below" or "change vs the one below"
        local rows = { header }
        for _, c in ipairs(groups[k]) do
            for i, e in ipairs(c.history) do
                local row = { i == 1 and (md and c.title or c.bench) or "", i == 1 and c.label or "",
                              tostring(e.measured) .. ((i == 1 and c.now) and (md and " (now)" or "*") or ""),
                              tostring(e.luamemo or "?") }
                for _, col in ipairs(cols) do row[#row + 1] = col[2](e) end
                row[#row + 1] = M.change(e, c.history[i + 1], k) or ""
                rows[#rows + 1] = row
            end
        end
        out[#out + 1] = rows
    end
    return out
end

--- The comparison of cells ({ bench, title, label, history (newest first), now }), Markdown:
--- one table per kind of benchmark.
function M.history_md(cells)
    local out = {}
    for _, rows in ipairs(tables_of(cells, true)) do
        if #out > 0 then out[#out + 1] = "" end
        out[#out + 1] = "| " .. table.concat(rows[1], " | ") .. " |"
        out[#out + 1] = "|" .. ("---|"):rep(#rows[1])
        for i = 2, #rows do out[#out + 1] = "| " .. table.concat(rows[i], " | ") .. " |" end
    end
    return table.concat(out, "\n")
end

--- The same comparison as text, for the terminal (columns padded to their widest cell).
function M.history_text(cells)
    local out = {}
    for _, rows in ipairs(tables_of(cells, false)) do
        if #out > 0 then out[#out + 1] = "" end
        local width = {}
        for _, row in ipairs(rows) do
            for j, cell in ipairs(row) do
                local w = #cell:gsub("[\128-\191]", "")   -- UTF-8 characters, not bytes
                if w > (width[j] or 0) then width[j] = w end
            end
        end
        for _, row in ipairs(rows) do
            local parts = {}
            for j, cell in ipairs(row) do
                parts[j] = j == #row and cell or (cell .. (" "):rep(width[j] - #cell:gsub("[\128-\191]", "")))
            end
            out[#out + 1] = (table.concat(parts, "  "):gsub("%s+$", ""))
        end
    end
    return table.concat(out, "\n")
end

--- Keep each row's result in the project's memory — the newest M.HISTORY of each
--- benchmark × embedder — and put that history on the row (r.history, newest first).
--- → nil when kept, else why not.
function M.record(rows, when)
    local memory, err = project_memory()
    if not memory then return "the project's memory isn't available (" .. tostring(err) .. ")" end
    local scope = M.history_scope()
    local ok, existing = pcall(history_rows, memory, scope)
    if not ok then return tostring(existing) end
    local problems = {}
    for _, r in ipairs(rows) do
        local key = r.bench .. "|" .. r.label
        local old = existing[key]
        local prev = old and type(old.metadata) == "table" and type(old.metadata.history) == "table"
            and old.metadata.history or {}
        local kind = r.kind or kind_of(r.bench)
        local hist = { M.entry(r.summary, when, kind) }
        for i = 1, math.min(#prev, M.HISTORY - 1) do hist[#hist + 1] = prev[i] end
        r.history = hist
        local cell = { bench = r.bench, kind = kind, title = r.title, label = r.label, history = hist }
        local what = kind == "retrieval" and ("with the %s embedder"):format(r.label) or "on this machine"
        local fields = {
            title    = ("memo eval: %s · %s"):format(r.title, r.label),
            body     = ("The last %d results of the %s benchmark %s (newest first), from memo eval run.%s\n\n%s")
                :format(#hist, r.title, what, kind == "retrieval" and " Miss rate: the right memory is not in "
                    .. "the 10 results; bytes to hit: what the agent reads up to it." or "", M.history_md({ cell })),
            tags     = { "eval", r.bench },
            metadata = { eval_key = key, benchmark = r.bench, embedder = r.label, history = hist },
        }
        local res, werr
        if old then
            res, werr = memory.update(old.id, fields)
        else
            fields.scope, fields.kind, fields.dedup_strategy, fields.no_miss = scope, "eval", "append", true
            res, werr = memory.write(fields)
        end
        if not res then problems[#problems + 1] = key .. ": " .. tostring(werr) end
    end
    if #problems > 0 then return table.concat(problems, "; ") end
end

--- The kept history: cells (bench order, then embedder), optionally only these
--- benchmarks / embedder labels. → cells, scope | nil, why.
function M.history(benches, labels)
    local memory, err = project_memory(true)
    if not memory then return nil, "the project's memory isn't available (" .. tostring(err) .. ")" end
    local scope = M.history_scope()
    local ok, rows = pcall(history_rows, memory, scope)
    if not ok then return nil, tostring(rows) end
    local want_b, want_l
    if benches and #benches > 0 then want_b = {}; for _, b in ipairs(benches) do want_b[b] = true end end
    if labels and #labels > 0 then want_l = {}; for _, l in ipairs(labels) do want_l[l] = true end end
    local cells = {}
    for _, r in pairs(rows) do
        local md = r.metadata
        if (not want_b or want_b[md.benchmark]) and (not want_l or want_l[md.embedder])
            and type(md.history) == "table" and #md.history > 0 then
            cells[#cells + 1] = { bench = md.benchmark, label = md.embedder, history = md.history,
                kind = kind_of(md.benchmark), title = (M.BENCHES[md.benchmark] or {}).title or tostring(md.benchmark) }
        end
    end
    table.sort(cells, function(a, b)
        local oa, ob = ORDER_OF[a.bench] or 99, ORDER_OF[b.bench] or 99
        if oa ~= ob then return oa < ob end
        return tostring(a.label) < tostring(b.label)
    end)
    return cells, scope
end

local function report_md(meta, rows, kept)
    local kinds = {}
    for _, r in ipairs(rows) do kinds[r.kind or "retrieval"] = true end
    local out = {
        "# luamemo benchmarks", "",
        ("luamemo %s · %s · %s · `%s`"):format(meta.luamemo, meta.date, meta.machine, meta.command), "",
        ("## The last %d measurements"):format(M.HISTORY), "",
        M.history_md(rows), "",
        kept and ("Not kept in memory: %s."):format(kept)
            or ("Kept in the project's memory (scope `%s`): the newest %d of each benchmark × embedder."):format(
                M.history_scope(), M.HISTORY),
        "", "## Against the published baseline", "",
        "| Benchmark | Embedder | vs baseline |", "|---|---|---|",
    }
    for _, r in ipairs(rows) do
        out[#out + 1] = ("| %s | %s | %s |"):format(r.title, r.label,
            #r.flags > 0 and table.concat(r.flags, "; ") or "within the baseline")
    end
    out[#out + 1] = ""
    if kinds.retrieval then
        out[#out + 1] = "- **Miss rate** — the share of questions whose right memory is not in the 10 results an "
            .. "agent gets (1 − R@10; a rank past 10 counts): the agent has to search again, grep or read files."
        out[#out + 1] = "- **Bytes to hit** — what the agent reads up to the right memory: the compact rows "
            .. "1..rank as the MCP server returns them (bodies capped at 2000; the code map's lines), over the "
            .. "questions answered within 10. Tokens ≈ bytes / 4 (an estimate; the bytes are the figure)."
        out[#out + 1] = "- **Rerank** — the reranker's own time and model tokens per search, set against what it "
            .. "changes above. **grep instead** — the code map's questions answered by grep: the files it ranks "
            .. "first, read whole until the right one."
        out[#out + 1] = "- Retrieval only (no generated answers scored); each benchmark on its own — never averaged."
    end
    if kinds.session then
        out[#out + 1] = "- **Session's fixed cost** — what an agent receives from luamemo before its first search: "
            .. "the usage rules, the tool definitions (all, or MEMO_MCP_TOOLS=core) and the session brief."
    end
    if kinds.perf then
        out[#out + 1] = "- **Speed and footprint** — this machine's figures (not compared with the baseline): "
            .. "every search scores every vector in scope, so its time grows with the memories."
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

--- Run benchmarks. opts: benches, embedders (specs), n, out, data, keep_db, no_smoke,
--- command (text for the report), say. → { rows, failed, out } | nil, why.
function M.run_benches(kit, opts)
    local say = opts.say or function(_) end
    local data = opts.data or M.default_data()
    local all = datasets(kit)
    local missing, bytes = {}, 0
    for _, b in ipairs(opts.benches) do
        local ds = M.BENCHES[b].dataset
        if ds and not (all[ds] and M.present(all[ds], data)) then
            missing[#missing + 1] = ds
            bytes = bytes + (all[ds] and total_bytes(all[ds]) or 0)
        end
    end
    if #missing > 0 then
        return nil, ("missing dataset(s) in %s: %s (%s) — memo eval fetch %s"):format(data,
            table.concat(missing, ", "), size_text(bytes), table.concat(missing, " "))
    end
    local out = opts.out or (data_home() .. "/eval-results/" .. os.date("%Y%m%d-%H%M%S"))
    mkdir_p(out .. "/scratch")
    local function run_one(file, args, env, tag)
        local db = out .. "/scratch/" .. tag .. ".db"
        for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(db .. sfx) end
        -- (MEMO_NO_MAINTENANCE: a benchmark's scratch database starts no `memo maintain` of its own)
        local e = { MEMO_DB = db, MEMO_PROJECT = "", MEMO_NO_MAINTENANCE = "1" }
        for k, v in pairs(env) do e[k] = v end
        local log = out .. "/" .. tag .. ".log"
        local t0 = os.time()
        local ok = ok_exec(os.execute(M.kit_command(kit, file, args, e, log)))
        if not opts.keep_db then for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(db .. sfx) end end
        return ok, os.time() - t0, log
    end

    local failed = {}
    if not opts.no_smoke then
        for _, s in ipairs(M.SMOKE) do
            local json_out = out .. "/smoke-" .. s.name .. ".json"
            local args = { "--embedder", "hash", "--out", json_out }
            for _, a in ipairs(s.args) do args[#args + 1] = a end
            local ok, secs, log = run_one(s.runner, args, {}, "smoke-" .. s.name)
            ok = ok and read_json(json_out) ~= nil
            say(("smoke  %-18s %s (%ds)"):format(s.name, ok and "ok" or ("FAILED — " .. log), secs))
            if not ok then failed[#failed + 1] = "smoke " .. s.name end
        end
        if #failed > 0 then return { rows = {}, failed = failed, out = out } end
    end

    local baselines = (read_json(kit.dir .. "/eval/baselines.json") or {}).results or {}
    local ctx = { data = data, memo = util.env("MEMO__BIN") or "memo" }
    local rows = {}
    for _, b in ipairs(opts.benches) do
        local bench = M.BENCHES[b]
        local kind = bench.kind or "retrieval"
        -- A benchmark of the machine (the session's cost, speed) runs once, not per embedder.
        local embs = bench.once and { { name = "hash", label = "—", env = {} } } or opts.embedders
        -- A corpus benchmark needs the benchmark database; without it the run goes on without
        -- (the public sets and the rest are unaffected) and says so once.
        local corpus_skip
        if bench.corpus then
            ctx.corpus_db = opts.corpus_db or (data_home() .. "/eval-data/bench-100k.db")
            if not exists(ctx.corpus_db) then
                corpus_skip = ("benchmark database not built (%s) — memo eval build-corpus"):format(ctx.corpus_db)
            else
                local sig = require("luamemo.cli.eval").corpus_embedder(ctx.corpus_db)
                embs = { { name = "hash", label = "corpus:" .. (sig or "?"), env = {} } }
                ctx.gguf_model = require("luamemo.cli.probe").gguf_model_path() or ""
            end
        end
        if corpus_skip then embs = {} ; say(("skip   %-18s %s"):format(b, corpus_skip)) end
        for _, emb in ipairs(embs) do
            local rr = opts.rerank and bench.rerank ~= false and kind == "retrieval" and not bench.once and opts.rerank
            -- Task prompts (luamemo.embed): their own label — another embedding space.
            local pr = opts.prompts and opts.prompts ~= "none" and kind == "retrieval" and not bench.once
            local label = emb.label .. (pr and "+prompts" or "") .. (rr and ("+rerank:" .. rr.label) or "")
            local tag = b .. "-" .. slug(label)
            local json_out = out .. "/" .. tag .. ".json"
            local args = { "--embedder", emb.name, "--out", json_out }
            if opts.n and not bench.no_n then args[#args + 1] = "--n"; args[#args + 1] = tostring(opts.n) end
            for _, a in ipairs(bench.args and bench.args(data, ctx) or {}) do args[#args + 1] = a end
            local env = {}
            for k, v in pairs(emb.env) do env[k] = v end
            if pr then env.EMBED_PROMPTS = opts.prompts end
            if rr then
                for _, a in ipairs(rr.args) do args[#args + 1] = a end
                for k, v in pairs(rr.env) do env[k] = v end
            end
            say(("run    %-18s %s …"):format(b, label))
            local ok, secs, log = run_one(bench.runner, args, env, tag)
            local res = ok and read_json(json_out)
            local overall = res and type(res.overall) == "table" and res.overall
            if not overall then
                failed[#failed + 1] = b .. " " .. label
                say(("       FAILED after %ds — %s"):format(secs, log))
            else
                local s = {}
                for _, k in ipairs(M.KINDS[kind].keys) do s[k] = overall[k] end
                s.elapsed_s = secs
                if kind == "retrieval" then
                    s.embed_max_chars = tonumber(env.EMBED_MAX_CHARS or util.env("EMBED_MAX_CHARS")) or 0
                end
                local base = (baselines[b] or {})[label]
                rows[#rows + 1] = { bench = b, kind = kind, title = bench.title, label = label, summary = s,
                                    flags = M.compare(s, base, kind) }
                if kind == "retrieval" then
                    say(("       done in %ds: R@1 %s %%, miss %s %%, bytes-to-hit %s"):format(secs,
                        pct(s["recall@1"]), pct(s.miss_rate), num(s.bytes_to_hit_mean)))
                else
                    say(("       done in %ds"):format(secs))
                end
            end
        end
    end
    if not opts.keep_db then os.remove(out .. "/scratch") end

    -- The results into the project's memory, with the previous ones (the comparison).
    local kept
    if opts.n then kept = "a partial run (--n) is compared with nothing and not kept"
    elseif #rows > 0 then kept = M.record(rows) end
    for _, r in ipairs(rows) do
        r.history, r.now, r.title = r.history or { M.entry(r.summary, nil, r.kind) }, true, r.title or r.bench
    end

    local meta = { luamemo = version(), date = os.date("!%Y-%m-%d"), machine = sh("uname -sm"),
                   command = opts.command or "memo eval run", n = opts.n }
    local results = {}
    for _, r in ipairs(rows) do
        results[r.bench] = results[r.bench] or {}
        results[r.bench][r.label] = r.summary
    end
    local summary = { luamemo = meta.luamemo, measured = meta.date, machine = meta.machine,
                      command = meta.command, n = meta.n, results = results }
    write_file(out .. "/summary.json", json.encode(summary) .. "\n")
    write_file(out .. "/report.md", report_md(meta, rows, kept))
    return { rows = rows, failed = failed, out = out, kept = kept }
end

-- ── status ───────────────────────────────────────────────────────────────────

--- The state as a table (status --json).
function M.status(data)
    data = data or M.default_data()
    local v = version()
    local kit = M.kit(v)
    local st = { luamemo = v, data_dir = data, kit = { installed = kit ~= nil, dir = M.kit_dir(v),
        release_asset = M.release_entry(v) ~= nil } }
    if kit then st.kit.source, st.kit.from = kit.source, kit.from end
    local name, cfg = mine()
    local emb, why = M.embedder("mine")
    st.embedder = { configured = name or "unsupported", label = emb and emb.label or nil, runnable = emb ~= nil,
                    why = (not name and cfg) or why }
    st.gguf_model = require("luamemo.cli.probe").gguf_model_path()
    local cells, scope_or_why = M.history()
    st.history = { scope = M.history_scope(), results = cells and #cells or 0,
                   why = (not cells) and scope_or_why or nil }
    for _, c in ipairs(cells or {}) do
        local m = c.history[1] and c.history[1].measured
        if m and (not st.history.last or m > st.history.last) then st.history.last = m end
    end
    if kit then
        local all = datasets(kit)
        st.datasets = { personalization = { present = true, in_kit = true } }
        for k, ds in pairs(all) do
            st.datasets[k] = { present = M.present(ds, data), bytes = total_bytes(ds), tier = ds.tier,
                               source = ds.source }
        end
        st.tiers = {}
        for tier, benches in pairs(M.TIERS) do
            local miss, bytes = {}, 0
            for _, b in ipairs(benches) do
                local ds = M.BENCHES[b].dataset
                if ds and not (st.datasets[ds] and st.datasets[ds].present) then
                    miss[#miss + 1] = ds
                    bytes = bytes + (st.datasets[ds] and st.datasets[ds].bytes or 0)
                end
            end
            st.tiers[tier] = { ready = #miss == 0, missing = json.list(miss), missing_bytes = bytes }
        end
    end
    return st
end

local function status_text(st)
    local w = io.write
    w("luamemo eval\n")
    w(("  luamemo:   %s\n"):format(st.luamemo))
    if st.kit.installed then
        w(("  kit:       installed (%s%s) — %s\n"):format(st.kit.source or "?",
            st.kit.from and (" " .. st.kit.from) or "", st.kit.dir))
    else
        w(("  kit:       not installed — %s\n"):format(st.kit.release_asset
            and "memo eval install (downloads this release's kit from GitHub, checksum-verified)"
            or "this luamemo ships no kit checksum (a checkout): memo eval install --from <the checkout>"))
    end
    w(("  embedder:  %s\n"):format(st.embedder.runnable and st.embedder.label
        or (st.embedder.configured .. " — " .. tostring(st.embedder.why))))
    w(("  gguf:      %s\n"):format(st.gguf_model or "no model found"))
    local h = st.history
    w(("  history:   %s\n"):format(h.why and ("unavailable — " .. h.why)
        or h.results == 0 and ("none yet (kept in " .. h.scope .. " after a run)")
        or ("%d benchmark × embedder result(s) in %s, the newest %s — memo eval history"):format(h.results, h.scope,
            tostring(h.last))))
    w(("  data:      %s\n"):format(st.data_dir))
    if st.datasets then
        local names = {}
        for k in pairs(st.datasets) do names[#names + 1] = k end
        table.sort(names)
        for _, k in ipairs(names) do
            local d = st.datasets[k]
            w(("    %-20s %s\n"):format(k, d.in_kit and "in the kit" or d.present and "present"
                or ("missing — memo eval fetch " .. k .. " (" .. size_text(d.bytes or 0) .. ")")))
        end
        for _, t in ipairs({ "quick", "standard", "full" }) do
            local s = st.tiers[t]
            w(("  %-10s %s\n"):format(t .. ":", s.ready and "ready" or ("needs " .. table.concat(s.missing, ", ")
                .. " (" .. size_text(s.missing_bytes) .. ")")))
        end
    end
end

-- ── command line ─────────────────────────────────────────────────────────────

local function die(msg, code)
    io.stderr:write("memo eval: ", tostring(msg), "\n")
    os.exit(code or 1)
end

local function say(line) io.write("  ", line, "\n"); io.flush() end

local function need_kit()
    local kit = M.kit()
    if not kit then
        die(("no eval kit for luamemo %s — memo eval install%s"):format(version(),
            M.release_entry() and "" or " --from <the checkout>"))
    end
    return kit
end

function M.main(argv)
    local cmd = argv[1] or "status"
    local opts, pos = {}, {}
    local i = 2
    while i <= #argv do
        local a = argv[i]
        local function value()
            local v = argv[i + 1]
            if v == nil then io.stderr:write(USAGE); die(a .. " needs a value", 2) end
            i = i + 1
            return v
        end
        if a == "--json" then opts.json = true
        elseif a == "--yes" then opts.yes = true
        elseif a == "--keep-db" then opts.keep_db = true
        elseif a == "--no-smoke" then opts.no_smoke = true
        elseif a == "--data" then opts.data = value()
        elseif a == "--from" then opts.from = value()
        elseif a == "--out" then opts.out = value()
        elseif a == "--tier" then opts.tier = value()
        elseif a == "--embedder" then opts.embedder = value()
        elseif a == "--stage" then opts.stage = value()
        elseif a == "--queries" then opts.queries = tonumber(value())
        elseif a == "--paraphrase-n" then opts.paraphrase_n = tonumber(value())
        elseif a == "--limit" then opts.limit = tonumber(value())
        elseif a == "--heavy-cycles" then opts.heavy_cycles = tonumber(value())
        elseif a == "--heavy-min" then opts.heavy_min = tonumber(value())
        elseif a == "--max-seconds" then opts.max_seconds = tonumber(value())
        elseif a == "--target" then opts.target = tonumber(value())
        elseif a == "--seed" then opts.seed = tonumber(value())
        elseif a == "--only" then opts.only = value()
        elseif a == "--no-notes" then opts.no_notes = true
        elseif a == "--rerank" then opts.rerank = value()
        elseif a == "--prompts" then opts.prompts = value()
        elseif a == "--n" then
            opts.n = tonumber(value())
            if not (opts.n and opts.n >= 1 and opts.n == math.floor(opts.n)) then die("--n needs a whole number", 2) end
        elseif a == "-h" or a == "--help" then io.write(USAGE); return 0
        elseif a:sub(1, 2) == "--" then io.stderr:write(USAGE); die("unknown option " .. a, 2)
        else pos[#pos + 1] = a end
        i = i + 1
    end
    if opts.data then opts.data = util.real_dir(opts.data) or opts.data:gsub("/+$", "") end

    if cmd == "status" then
        local st = M.status(opts.data)
        if opts.json then io.write(json.encode(st), "\n") else status_text(st) end
        return 0
    elseif cmd == "install" then
        local dir, why
        if opts.from then dir, why = M.install_from(opts.from)
        else dir, why = M.install_release(nil, say) end
        if not dir then die(why) end
        io.write("  eval kit ", version(), " installed: ", dir, "\n")
        return 0
    elseif cmd == "fetch" then
        if #pos == 0 then io.stderr:write(USAGE); die("name a dataset (memo eval status lists them)", 2) end
        local ok, why = M.fetch(need_kit(), pos, { yes = opts.yes, data = opts.data, say = say })
        if not ok then die(why) end
        return 0
    elseif cmd == "build-corpus" then
        -- The benchmark corpus (eval/corpus/): ~100,000 rows of luamemo's own ingestion over real
        -- source trees, in a database of its own — never a project's. Resumable; takes hours.
        local kit = need_kit()
        local out = opts.out or (M.default_data() .. "/bench-100k.db")
        local args = { "--out", out, "--target", tostring(opts.target or 100000), "--seed", tostring(opts.seed or 1) }
        local e, why = M.embedder(opts.embedder or "gguf")
        if not e then die(why) end
        if e.name == "hash" then
            args[#args + 1] = "--embedder"; args[#args + 1] = "hash"
        elseif e.name == "gguf" then
            args[#args + 1] = "--gguf-model"; args[#args + 1] = e.env.MEMO_GGUF_MODEL
        else
            die("the corpus is embedded in process: --embedder gguf (the default) or hash", 2)
        end
        if opts.only then args[#args + 1] = "--only"; args[#args + 1] = opts.only end
        if opts.no_notes then args[#args + 1] = "--no-notes" end
        for _, kv in ipairs({ { "stage", "--stage" }, { "queries", "--queries" }, { "paraphrase_n", "--paraphrase-n" },
                              { "limit", "--limit" }, { "max_seconds", "--max-seconds" },
                              { "heavy_cycles", "--heavy-cycles" }, { "heavy_min", "--heavy-min" } }) do
            if opts[kv[1]] then args[#args + 1] = kv[2]; args[#args + 1] = tostring(opts[kv[1]]) end
        end
        io.write("  building ", out, " (resumable: run it again to continue)\n"); io.flush()
        local ok = ok_exec(os.execute(M.kit_command(kit, "corpus/build.lua", args, {}, false)))
        return ok and 0 or 1
    elseif cmd == "history" then
        for _, b in ipairs(pos) do
            if not M.BENCHES[b] then die(("unknown benchmark %q — %s"):format(b, table.concat(M.ORDER, ", ")), 2) end
        end
        local cells, scope = M.history(pos)
        if not cells then die(scope) end
        if opts.embedder then   -- a name (gguf) matches its labels (gguf:<model>)
            local keep = {}
            for _, c in ipairs(cells) do
                for f in opts.embedder:gmatch("[^,%s]+") do
                    if c.label == f or c.label:sub(1, #f + 1) == f .. ":" then keep[#keep + 1] = c; break end
                end
            end
            cells = keep
        end
        if opts.json then
            local out = {}
            for _, c in ipairs(cells) do
                out[#out + 1] = { benchmark = c.bench, embedder = c.label, history = c.history }
            end
            io.write(json.encode({ scope = scope, results = json.list(out) }), "\n")
        elseif #cells == 0 then
            io.write(("  no results kept in %s yet — memo eval run\n"):format(scope))
        else
            io.write(("The last %d measurements, kept in %s:\n"):format(M.HISTORY, scope), M.history_text(cells), "\n")
        end
        return 0
    elseif cmd == "run" then
        if #pos > 0 and opts.tier then die("name benchmarks or a tier, not both", 2) end
        local benches = pos
        if #benches == 0 then
            benches = M.TIERS[opts.tier or "quick"]
            if not benches then
                local names = {}
                for t in pairs(M.TIERS) do names[#names + 1] = t end
                table.sort(names)
                die("unknown tier " .. tostring(opts.tier) .. " (" .. table.concat(names, ", ") .. ")", 2)
            end
        end
        for _, b in ipairs(benches) do
            if not M.BENCHES[b] then die(("unknown benchmark %q — %s"):format(b, table.concat(M.ORDER, ", ")), 2) end
        end
        local embedders, seen = {}, {}
        for name in (opts.embedder or "mine,hash"):gmatch("[^,%s]+") do
            local e, why = M.embedder(name)
            if not e and not opts.embedder then
                say(tostring(why) .. " — hash only")   -- the default: this project's embedder can't run here
            elseif not e then
                die(why)
            elseif not seen[e.label] then
                seen[e.label] = true; embedders[#embedders + 1] = e
            end
        end
        local rerank
        if opts.rerank then
            local why
            rerank, why = M.rerank_spec(opts.rerank)
            if not rerank then die(why, 2) end
        end
        local kit = need_kit()
        local words = { "memo eval run" }
        for k = 2, #argv do words[#words + 1] = argv[k] end
        local res, why = M.run_benches(kit, { benches = benches, embedders = embedders, n = opts.n, out = opts.out,
            data = opts.data, keep_db = opts.keep_db, no_smoke = opts.no_smoke, say = say, rerank = rerank,
            prompts = opts.prompts, command = table.concat(words, " ") })
        if not res then die(why) end
        if #res.rows > 0 then
            io.write(("\nThe last %d measurements (* now):\n"):format(M.HISTORY), M.history_text(res.rows), "\n")
            io.write("\n  ", res.kept and ("not kept in memory: " .. res.kept)
                or ("kept in the project's memory (scope " .. M.history_scope() .. "; memo eval history)"), "\n")
            local any = false
            for _, r in ipairs(res.rows) do
                for _, f in ipairs(r.flags) do
                    if f ~= "no baseline" then
                        if not any then io.write("\nagainst the baseline:\n"); any = true end
                        io.write(("  %s %s: %s\n"):format(r.bench, r.label, f))
                    end
                end
            end
        end
        io.write("\n  results: ", res.out, " (report.md, summary.json, each runner's JSON and log)\n")
        if #res.failed > 0 then die("failed: " .. table.concat(res.failed, ", ")) end
        return 0
    end
    io.stderr:write(USAGE)
    die("unknown command " .. tostring(cmd), 2)
end

-- cli/memo's entry (memo eval …).
function M.run(argv) os.exit(M.main(argv) or 0) end

return M
