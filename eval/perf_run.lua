-- eval/perf_run.lua — speed and footprint on this machine.
--
--   * search latency (p50 / p95 ms, every vector in scope scored + the full-text leg) at
--     1k, 20k and 100k memories of 768 dimensions — synthetic, seeded memories written
--     with their vectors, so only the store is timed;
--   * the query embedding, hash and (with --gguf-model) the in-process GGUF model;
--   * writes per second: hash, measured; gguf, from its measured embedding time plus the
--     store's measured cost per write;
--   * the MCP server (`memo mcp`): start until it answers initialize, the first search,
--     its resident memory idle and with the GGUF model loaded;
--   * the database's size per 1k memories.
--
--   MEMO_NO_MAINTENANCE=1 MEMO_DB=scratch luajit eval/perf_run.lua --memo /usr/local/bin/memo [--gguf-model M] --out r.json
--
-- memo eval runs it (benchmark `perf`). Machine-dependent: its history compares this
-- machine's runs; nothing is compared with the baseline.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json   = require("luamemo.json")
local util   = require("luamemo.util")
local socket = require("socket")

local args = { memo = "memo", out = nil, gguf_model = nil, sizes = { 1000, 20000, 100000 } }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--memo" then args.memo = arg[i + 1]; i = i + 2
        elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
        elseif a == "--gguf-model" then args.gguf_model = arg[i + 1]; i = i + 2
        elseif a == "--sizes" then
            args.sizes = {}
            for n in arg[i + 1]:gmatch("%d+") do args.sizes[#args.sizes + 1] = tonumber(n) end
            i = i + 2
        elseif a == "--embedder" then i = i + 2   -- (memo eval passes one; both are measured here)
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
assert(args.out, "--out is required")
local db_path = assert(util.env("MEMO_DB"), "MEMO_DB (a scratch database) is required")
local DIM = 768
local now = socket.gettime

local function percentile(t, p)
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    return s[math.max(1, math.ceil(p / 100 * #s))]
end

local memory = require("luamemo")
memory.setup({ embedder_local = "hash", embed_dim = DIM, skip_embed_probe = true, dedup_enabled = false,
               patterns_enabled = false })
local store, db = memory.store, require("luamemo.db")

-- Seeded synthetic memories: text from a fixed vocabulary, a unit vector each.
math.randomseed(20261022)
local VOCAB = {}
for i = 1, 3000 do
    local w = {}
    for j = 1, 4 + (i % 6) do w[j] = string.char(97 + (i * 7 + j * 13) % 26) end
    VOCAB[i] = table.concat(w)
end
local function text(n)
    local w = {}
    for i = 1, n do w[i] = VOCAB[math.random(#VOCAB)] end
    return table.concat(w, " ")
end
local function vector()
    local v, ss = {}, 0
    for i = 1, DIM do local x = math.random() - 0.5; v[i] = x; ss = ss + x * x end
    local inv = 1 / math.sqrt(ss)
    for i = 1, DIM do v[i] = v[i] * inv end
    return v
end

local SCOPE = "perf"
assert(db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE))
local overall, have = { dim = DIM }, 0
local queries = {}
for i = 1, 40 do queries[i] = text(6) end
for _, n in ipairs(args.sizes) do
    while have < n do
        local batch = {}
        for i = 1, math.min(1000, n - have) do
            batch[i] = { scope = SCOPE, kind = "fact", title = text(5), body = text(40), embedding = vector() }
        end
        assert(store.write_many(batch, { dedup_strategy = "append" }))
        have = have + #batch
    end
    -- A scope with no backlog: a search right after a bulk write also consolidates a slice
    -- of it inline (100 memories), which is maintenance, not search. Marked consolidated,
    -- and the in-process "pending" flag cleared.
    assert(db.run("UPDATE lm_memories SET consolidated_at = ? WHERE scope = ? AND consolidated_at IS NULL",
        util.now_us(), SCOPE))
    require("luamemo.consolidate").process(SCOPE, { limit = 1 })
    local times = {}
    for i, q in ipairs(queries) do
        local t0 = now()
        assert(memory.search({ scope = SCOPE, query = q, limit = 10 }))
        if i > 5 then times[#times + 1] = (now() - t0) * 1000 end   -- (the first few warm the cache)
    end
    local key = n >= 1000 and (math.floor(n / 1000) .. "k") or tostring(n)
    overall["search_ms_p50_" .. key], overall["search_ms_p95_" .. key] = percentile(times, 50), percentile(times, 95)
    io.stderr:write(("%d memories: search p50 %.1f ms, p95 %.1f ms\n"):format(n,
        overall["search_ms_p50_" .. key], overall["search_ms_p95_" .. key]))
end

-- The database's size per 1k memories (after a checkpoint, so the WAL is in the file).
db.run("PRAGMA wal_checkpoint(TRUNCATE)")
local function size(p) local f = io.open(p, "rb"); if not f then return 0 end; local s = f:seek("end"); f:close(); return s end
overall.db_kb_per_1k = (size(db_path) + size(db_path .. "-wal")) / 1024 / (have / 1000)

-- Query embedding: hash (in process, the store's embedder).
local hash = require("luamemo.embedders.hash")
local et = {}
for i, q in ipairs(queries) do
    local t0 = now()
    hash.embed(q, { embed_dim = DIM })
    if i > 5 then et[#et + 1] = (now() - t0) * 1000 end
end
overall.embed_ms_hash = percentile(et, 50)

-- Writes per second, hash: one memory per write, as the MCP tool writes them.
local W, t0 = 300, now()
for i = 1, W do assert(memory.write({ scope = "perf-writes", kind = "fact", title = text(5), body = text(60) })) end
local per_write = (now() - t0) / W
overall.writes_per_s_hash = 1 / per_write

-- gguf: the query embedding, and a memory's (~60 words) — writes/s = 1 / (embed + store).
if args.gguf_model and util.exists(args.gguf_model) then
    local g = require("luamemo.embedders.gguf_ffi")
    local cfg = { embedder_model = args.gguf_model }
    g.embed("warm up", cfg)
    local q, w = {}, {}
    for i = 1, 20 do
        local a = now(); g.embed(queries[i], cfg); q[#q + 1] = (now() - a) * 1000
        local b = now(); g.embed(text(60), cfg); w[#w + 1] = now() - b
    end
    overall.embed_ms_gguf = percentile(q, 50)
    local hash_embed_s = (overall.embed_ms_hash or 0) / 1000
    overall.writes_per_s_gguf = 1 / (percentile(w, 50) + math.max(0, per_write - hash_embed_s))
end

-- The MCP server: start (until it answers initialize), the first search, its memory.
local dir = (db_path:match("^(.*)/[^/]+$") or ".") .. "/perf-mcp"
os.execute("rm -rf " .. util.shell_quote(dir) .. " && mkdir -p " .. util.shell_quote(dir .. "/home"))
local q = util.shell_quote
local INIT = json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = {
    protocolVersion = "2025-06-18", capabilities = {}, clientInfo = { name = "memo-eval", version = "1" } } })
local SEARCH = json.encode({ jsonrpc = "2.0", id = 2, method = "tools/call",
    params = { name = "memory_search", arguments = { query = "staging gate deploy", scope = SCOPE } } })
local function server_env(extra)
    return ("env HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s MEMO_DB=%s MEMO_SCOPE=%s %s"):format(q(dir .. "/home"),
        q(dir .. "/home/.config"), q(dir .. "/home/.local/share"), q(db_path), SCOPE, extra or "MEMO_EMBEDDER=hash MEMO_EMBED_DIM=768")
end
-- One scripted session, timed whole (the server exits when its input ends).
local function timed(lines, extra)
    local req = dir .. "/req.jsonl"
    local f = assert(io.open(req, "w")); f:write(table.concat(lines, "\n") .. "\n"); f:close()
    local t = now()
    os.execute(("cd %s && %s %s mcp --project %s < %s > %s 2>/dev/null"):format(q(dir), server_env(extra),
        q(args.memo), q(dir), q(req), q(dir .. "/out.jsonl")))
    return (now() - t) * 1000
end
local starts, firsts = {}, {}
for _ = 1, 5 do
    local a = timed({ INIT })
    local b = timed({ INIT, SEARCH })
    starts[#starts + 1], firsts[#firsts + 1] = a, math.max(0, b - a)
end
overall.cold_start_ms, overall.first_search_ms = percentile(starts, 50), percentile(firsts, 50)

-- Resident memory: the server kept alive (its input held open), measured after it answered.
local function rss_mb(lines, extra)
    local req = dir .. "/req-rss.jsonl"
    local f = assert(io.open(req, "w")); f:write(table.concat(lines, "\n") .. "\n"); f:close()
    -- (cd first, on its own: `cd … && … &` would put a subshell in the background, and $!
    -- would be that shell, not the server)
    local script = ("cd %s || exit 1; { cat %s; sleep 6; } | %s %s mcp --project %s > %s 2>/dev/null & pid=$!; "
        .. "for i in $(seq 1 50); do grep -q '\"id\":%d' %s 2>/dev/null && break; sleep 0.2; done; "
        .. "ps -o rss= -p $pid; wait"):format(q(dir), q(req), server_env(extra), q(args.memo), q(dir),
        q(dir .. "/out-rss.jsonl"), #lines, q(dir .. "/out-rss.jsonl"))
    local kb = tonumber(util.sh(script):match("(%d+)%s*$"))
    return kb and kb / 1024 or nil
end
overall.rss_idle_mb = rss_mb({ INIT })                 -- right after initialize (modules load lazily)
overall.rss_search_mb = rss_mb({ INIT, SEARCH })      -- after a hash search (SQLite, the store loaded)
if args.gguf_model and util.exists(args.gguf_model) then
    overall.rss_gguf_mb = rss_mb({ INIT, SEARCH }, ("MEMO_EMBEDDER=gguf_ffi MEMO_GGUF_MODEL=%s MEMO_EMBED_DIM=768")
        :format(q(args.gguf_model)))
end
os.execute("rm -rf " .. q(dir))

io.stderr:write(json.encode(overall) .. "\n")
local jf = assert(io.open(args.out, "w"))
jf:write(json.encode({ suite = "perf", machine = util.sh("uname -sm"), overall = overall })); jf:close()
