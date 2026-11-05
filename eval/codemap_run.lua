-- eval/codemap_run.lua — "where is X done?": the code map (index_search) against grep.
--
-- luamemo's own modules (the luamemo/ tree this luamemo runs from — every install has it,
-- at its own version) are indexed into a scratch database, and each question of
-- eval/codemap/queries.jsonl (gold = the file(s) that answer it) is asked two ways:
--
--   * index_search, as the MCP tool runs it: R@k, MRR, miss rate, and bytes to hit — the
--     result lines the agent reads (index.format, as the tool prints them) up to the first
--     line in a gold file;
--   * grep: the question's words, files ranked by how many of them they hold (then by
--     how often), read whole until the gold file — grep_bytes_to_hit_*, grep_miss_rate
--     (gold not among the first 10 files).
--
--   MEMO_NO_MAINTENANCE=1 MEMO_DB=scratch luajit eval/codemap_run.lua --embedder hash --out r.json [--n N]
--
-- memo eval runs it (benchmark `codemap`).

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json    = require("luamemo.json")
local metrics = require("eval.metrics")

local args = { embedder = "hash", out = nil, queries = "eval/codemap/queries.jsonl", root = nil, n = nil }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--embedder" then args.embedder = arg[i + 1]; i = i + 2
        elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
        elseif a == "--queries" then args.queries = arg[i + 1]; i = i + 2
        elseif a == "--root" then args.root = arg[i + 1]; i = i + 2
        elseif a == "--n" then args.n = tonumber(arg[i + 1]); i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
assert(args.out, "--out is required")

-- The luamemo/ tree this luamemo runs from (where require finds it).
local root = args.root
if not root then
    local init = assert(package.searchpath("luamemo", package.path), "luamemo not found on package.path")
    root = init:match("^(.*)/init%.lua$")
end

-- The embedder, as the other runners set it up.
local setup = { skip_embed_probe = true }
if args.embedder == "hash" then
    setup.embedder_local, setup.embed_dim = "hash", 384
elseif args.embedder == "gguf" then
    setup.embedder_local = "gguf_ffi"
    setup.embedder_model = os.getenv("MEMO_GGUF_MODEL") or (os.getenv("HOME") .. "/models/embeddinggemma-300M-Q8_0.gguf")
    setup.embed_dim = tonumber(os.getenv("MEMO_GGUF_DIM") or "768")
elseif args.embedder == "ollama" or args.embedder == "tei" then
    local up = args.embedder:upper()
    setup.embedder_adapter = args.embedder
    setup.embedder_url = os.getenv(up .. "_URL") or (args.embedder == "ollama"
        and "http://127.0.0.1:11434/api/embeddings" or "http://127.0.0.1:8081/embed")
    setup.embedder_model = os.getenv(up .. "_MODEL") or (args.embedder == "ollama" and "nomic-embed-text" or "BAAI/bge-m3")
    setup.embed_dim = tonumber(os.getenv(up .. "_DIM") or (args.embedder == "ollama" and "768" or "1024"))
else
    io.stderr:write("unknown --embedder: " .. tostring(args.embedder) .. "\n"); os.exit(2)
end
setup.embed_prompts = os.getenv("EMBED_PROMPTS")   -- none | auto | JSON (luamemo.embed)
local memory = require("luamemo")
memory.setup(setup)
local index, format = require("luamemo.index"), require("luamemo.index.format")
local db = require("luamemo.db")

local SCOPE = "codeindex:codemap"
assert(db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE))
local t0 = os.time()
local ing, ierr = index.ingest(root, { scope = SCOPE, extensions = { lua = true }, respect_gitignore = false })
assert(ing, "ingest failed: " .. tostring(ierr))
io.stderr:write(("indexed %s (%ds)\n"):format(root, os.time() - t0))

-- The files grep would see: the same .lua files the index walked.
local files = {}
for _, r in ipairs(db.query("SELECT json_extract(metadata, '$.path') AS path FROM lm_memories "
    .. "WHERE scope = ? AND kind = 'file' ORDER BY path", SCOPE) or {}) do
    local f = io.open(root .. "/" .. r.path, "rb")
    if f then files[#files + 1] = { path = r.path, text = f:read("*a"):lower() }; f:close() end
end

-- grep: files holding the most of the words first (then the most hits), read whole.
local function grep_rank(q, gold) return require("eval.grep_baseline").rank(files, q, gold, metrics.LIMIT) end

local queries = {}
for line in io.lines(args.queries) do
    local q = line:match("%S") and json.decode(line)
    if q then queries[#queries + 1] = q end
    if args.n and #queries >= args.n then break end
end

local m = metrics.new()
local grep_hit, grep_miss = {}, 0
local line_bytes = function(r) return #format.results({ r }) + 1 end   -- a result line and its newline
local per_query = {}
for _, q in ipairs(queries) do
    local gold = {}
    for _, g in ipairs(q.gold) do gold[g] = true end
    local rows = index.search(q.q, { scope = SCOPE, limit = metrics.LIMIT }) or {}
    local rank
    for i, r in ipairs(rows) do
        local p = type(r.metadata) == "table" and r.metadata.path
        if p and gold[p] then rank = i; break end
    end
    metrics.record(m, rank, rows, line_bytes)
    local grank, gbytes = grep_rank(q.q, gold)
    if grank then grep_hit[#grep_hit + 1] = gbytes else grep_miss = grep_miss + 1 end
    per_query[#per_query + 1] = { q = q.q, rank = rank, grep_rank = grank, grep_bytes = gbytes }
end

local overall = metrics.summary(m)
local function median(t)
    if #t == 0 then return nil end
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    local mid = math.floor(#s / 2) + 1
    return #s % 2 == 1 and s[mid] or (s[mid - 1] + s[mid]) / 2
end
local sum = 0
for _, v in ipairs(grep_hit) do sum = sum + v end
overall.grep_bytes_to_hit_mean = #grep_hit > 0 and sum / #grep_hit or nil
overall.grep_bytes_to_hit_median = median(grep_hit)
overall.grep_miss_rate = #queries > 0 and grep_miss / #queries or 0
print(("index_search: R@1 %.1f %% · miss %.1f %% · bytes to hit %s   grep: bytes to hit %s · miss %.1f %%"):format(
    100 * overall["recall@1"], 100 * overall.miss_rate, tostring(overall.bytes_to_hit_mean and
    math.floor(overall.bytes_to_hit_mean) or "—"), tostring(overall.grep_bytes_to_hit_mean and
    math.floor(overall.grep_bytes_to_hit_mean) or "—"), 100 * overall.grep_miss_rate))
local jf = assert(io.open(args.out, "w"))
jf:write(json.encode({ suite = "codemap", embedder = args.embedder, root = root, n_files = #files,
    overall = overall, per_query = per_query }))
jf:close()
