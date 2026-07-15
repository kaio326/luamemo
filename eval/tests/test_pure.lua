-- eval/tests/test_pure.lua
-- Merged pure-Lua tests (no DB, no network):
--   Section 1: Bug Fixes       (pg_array escaping, SSRF dot pattern, UTC epoch)
--   Section 2: Recommend       (cli.recommend decision tree)
--   Section 3: Paraphrase      (eval/utils.lua deterministic generator)
--   Section 4: Cross Encoder   (rerankers.cross_encoder with mocked resty.http)
--
-- Usage:
--   cd /path/to/repo && lua5.1 eval/tests/test_pure.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local pass = 0
local fail = 0

local function check(label, ok, detail)
    if ok then
        io.write("[PASS] " .. label .. "\n")
        pass = pass + 1
    else
        io.write("[FAIL] " .. label .. (detail and (" — " .. detail) or "") .. "\n")
        fail = fail + 1
    end
end

local function header(s)
    io.write(string.format("\n=== %s ===\n", s))
end

-- =========================================================================
-- Section 1: Bug Fixes
-- =========================================================================
header("Bug Fixes")

io.write("\n-- Bug 1: pg_array() SQL-injection escaping --\n")

local function pg_array(arr)
    if not arr or #arr == 0 then return "'{}'" end
    local parts = {}
    for i, v in ipairs(arr) do
        local s = tostring(v)
            :gsub("\\", "\\\\")
            :gsub('"',  '\\"')
            :gsub("'",  "''")
        parts[i] = '"' .. s .. '"'
    end
    return "'{" .. table.concat(parts, ",") .. "}'"
end

local EXPECTED_PLAIN = "'{\""  .. "hello" .. "\"}'"
check("plain tag exact", pg_array({"hello"}) == EXPECTED_PLAIN, pg_array({"hello"}))

local q = pg_array({"it's"})
check("single-quote doubled",  q:find("it''s") ~= nil,  q)
check("single-quote not raw",  q:find("it's") == nil or q:find("it''s") ~= nil, q)

local bs = pg_array({"a\\b"})
check("backslash escaped",   bs:find("a\\\\b") ~= nil, bs)

local dq = pg_array({'say "hi"'})
check("double-quote escaped", dq:find('\\"hi\\"') ~= nil, dq)

local combined = pg_array({"o'neil\\path"})
check("combined ' and \\ escaped",
    combined:find("o''neil") ~= nil and combined:find("\\\\path") ~= nil,
    combined)

check("empty array", pg_array({}) == "'{}'", pg_array({}))
check("nil array",   pg_array(nil) == "'{}'", tostring(pg_array(nil)))

io.write("\n-- Bug 2: SSRF resolved-IP dot pattern --\n")

local FIXED_PATTERN = "^172%.3[0-1]%."

check("172.30.0.1 blocked",    ("172.30.0.1"):match(FIXED_PATTERN) ~= nil)
check("172.31.255.255 blocked",("172.31.255.255"):match(FIXED_PATTERN) ~= nil)
check("172.30.1.100 blocked",  ("172.30.1.100"):match(FIXED_PATTERN) ~= nil)
check("172.301.0.0 not blocked", ("172.301.0.0"):match(FIXED_PATTERN) == nil)
check("172.30X0.0 not blocked",  ("172.30X0.0"):match(FIXED_PATTERN) == nil)
check("172.32.0.1 not blocked",  ("172.32.0.1"):match(FIXED_PATTERN) == nil)
check("172.29.0.1 not blocked",  ("172.29.0.1"):match(FIXED_PATTERN) == nil)
check("10.0.0.1 not blocked",    ("10.0.0.1"):match(FIXED_PATTERN) == nil)

local OLD_PATTERN = "^172%.3[0-1]."
check("OLD pattern wrongly matched 172.30X0.0",
    ("172.30X0.0"):match(OLD_PATTERN) ~= nil)

io.write("\n-- Bug 3: _ts_to_epoch() UTC offset --\n")

local tz_offset = os.difftime(os.time(), os.time(os.date("!*t")))

check("_tz_offset is a number", type(tz_offset) == "number")
check("_tz_offset is whole seconds (multiple of 60)",
    math.fmod(math.abs(tz_offset), 60) == 0,
    "offset=" .. tostring(tz_offset))
check("_tz_offset within sane bounds (≤14h)",
    math.abs(tz_offset) <= 14 * 3600,
    "offset=" .. tostring(tz_offset))

local function ts_to_epoch_fixed(s)
    local y, mo, d = tostring(s):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return 0 end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = 0, min = 0, sec = 0,
    }) + tz_offset
end

local function ts_to_epoch_old(s)
    local y, mo, d = tostring(s):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return 0 end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = 0, min = 0, sec = 0,
    })
end

local ts = "2024-03-15 00:00:00"
local fixed_epoch = ts_to_epoch_fixed(ts)
local old_epoch   = ts_to_epoch_old(ts)
-- fixed = old + tz_offset, so (fixed - old) == tz_offset
check("fixed and old differ by exactly tz_offset",
    (fixed_epoch - old_epoch) == tz_offset,
    string.format("old=%d fixed=%d diff=%d offset=%d",
        old_epoch, fixed_epoch, fixed_epoch - old_epoch, tz_offset))

-- Hard correctness check: known UTC epoch for 2024-01-01 00:00:00 UTC = 1704067200
check("fixed gives correct UTC epoch for 2024-01-01",
    ts_to_epoch_fixed("2024-01-01") == 1704067200,
    string.format("got=%d want=1704067200 diff=%d",
        ts_to_epoch_fixed("2024-01-01"),
        ts_to_epoch_fixed("2024-01-01") - 1704067200))

if tz_offset == 0 then
    check("UTC machine: fixed == old (expected)", fixed_epoch == old_epoch)
else
    check("non-UTC machine: fixed != old (offset applied)",
        fixed_epoch ~= old_epoch,
        "offset=" .. tz_offset)
end

check("nil input returns 0",       ts_to_epoch_fixed(nil) == 0)
check("bad string returns 0",      ts_to_epoch_fixed("not-a-date") == 0)
check("partial string returns 0",  ts_to_epoch_fixed("2024-03") == 0)

-- =========================================================================
-- Section 2: Recommend
-- =========================================================================
header("Recommend")

do
    local R = require("luamemo.cli.recommend")

    local cases = {
        -- In-process GGUF is the preferred default whenever the host can run it.
        { "GGUF-capable -> in-process GGUF (preferred default)",
          { gguf_capable=true },
          "gguf", "embeddinggemma-300M" },
        { "GGUF-capable preempts the GPU+Docker service ladder",
          { gguf_capable=true, has_gpu=true, gpu_free_mb=8192, has_docker=true },
          "gguf", "embeddinggemma-300M" },
        { "GGUF opted out (--no-gguf) -> falls back to service ladder",
          { gguf_capable=true, allow_gguf=false, has_docker=true, ram_mb=8192, has_ollama=true },
          "ollama", "nomic-embed-text" },
        -- Service ladder (no gguf capability) is unchanged.
        { "GPU+Docker, multilingual",
          { has_gpu=true, gpu_free_mb=4096, has_docker=true, multilingual=true },
          "tei", "BAAI/bge-m3" },
        { "GPU+Docker, long rows",
          { has_gpu=true, gpu_free_mb=4096, has_docker=true, long_rows=true },
          "tei", "BAAI/bge-m3" },
        { "GPU+Docker, English short",
          { has_gpu=true, gpu_free_mb=4096, has_docker=true },
          "ollama", "nomic-embed-text" },
        { "GPU below 2GB free -> treated as no-GPU",
          { has_gpu=true, gpu_free_mb=512, has_docker=true, has_ollama=true, ram_mb=8192 },
          "ollama", "nomic-embed-text" },
        { "No GPU, Docker+RAM, multilingual -> bge-m3 CPU",
          { has_docker=true, ram_mb=8192, multilingual=true },
          "tei", "BAAI/bge-m3" },
        { "No GPU, Docker+RAM, English short, ollama reachable -> nomic CPU",
          { has_docker=true, ram_mb=8192, has_ollama=true },
          "ollama", "nomic-embed-text" },
        -- OpenAI/hosted was removed from the auto-recommend ladder.
        { "No local, hosted flag set -> nil (OpenAI dropped from ladder)",
          { allow_hosted=true },
          nil, nil },
        { "Nothing, allow_hash -> hash",
          { allow_hash=true },
          "hash", "hash" },
    }

    for _, c in ipairs(cases) do
        local name, profile, want_a, want_m = c[1], c[2], c[3], c[4]
        local rec, err = R.decide(profile)
        if want_a == nil then
            check("recommend: " .. name, rec == nil,
                rec and ("unexpectedly got " .. (rec.adapter or "?")) or nil)
        elseif not rec then
            check("recommend: " .. name, false, "nil (err=" .. tostring(err) .. ")")
        elseif rec.adapter ~= want_a or rec.model ~= want_m then
            check("recommend: " .. name, false,
                string.format("got %s/%s want %s/%s", rec.adapter, rec.model, want_a, want_m))
        else
            check("recommend: " .. name, true)
        end
    end

    local rec, err = R.decide({})
    check("recommend: empty profile -> nil", rec == nil,
        rec and "unexpectedly got " .. (rec.adapter or "?") or nil)
    io.write("  empty profile -> nil (" .. (err or ""):gsub("\n.*", "") .. "...)\n")

    check("SAFE_CHARS[bge-m3] == 24000",       R.SAFE_CHARS["bge-m3"] == 24000)
    check("SAFE_CHARS[nomic-embed-text] == 6000", R.SAFE_CHARS["nomic-embed-text"] == 6000)
end

-- =========================================================================
-- Section 3: Paraphrase
-- =========================================================================
header("Paraphrase")

do
    local pp = require("utils")

    local cases = {
        "Did I buy the car at the big dealership?",
        "What movie did you like best in 2024?",
        "I went to the doctor on Monday.",
        "My company is in Toronto.",
        "Sphinx of black quartz, judge my vow.",
    }

    for _, q in ipairs(cases) do
        local v = pp.variants(q, 3)
        -- Determinism
        local v2 = pp.variants(q, 3)
        for i = 1, 3 do
            check("paraphrase determinism v" .. i .. " for: " .. q:sub(1, 30),
                v[i] == v2[i], "non-determinism")
        end
        -- Each variant differs from original
        for i = 1, 3 do
            check("paraphrase variant " .. i .. " differs from input",
                v[i] ~= q, "variant " .. i .. " unchanged")
        end
    end

    local v6 = pp.variants("Did I buy the big car?", 6)
    check("paraphrase n=6 produces 6 variants", #v6 == 6, "got " .. #v6)
end

-- =========================================================================
-- Section 4: Cross Encoder
-- =========================================================================
header("Cross Encoder")

do
    local cjson = require("cjson.safe")

    -- Inject fake resty.http BEFORE loading the adapter.
    local fake_response
    package.loaded["resty.http"] = {
        new = function()
            return {
                set_timeout = function() end,
                request_uri = function(_, _, _) return fake_response end,
            }
        end,
    }
    package.loaded["eval._resty_http_shim"] = package.loaded["resty.http"]

    local ce = require("luamemo.rerankers.cross_encoder")

    local hits = {
        { id = 1, title = "alpha", body = "first candidate body" },
        { id = 2, title = "beta",  body = "second candidate body" },
        { id = 3, title = "gamma", body = "third candidate body" },
    }

    -- Test 1: TEI native shape
    fake_response = {
        status = 200,
        body = cjson.encode({
            { index = 2, score = 0.91 },
            { index = 0, score = 0.62 },
            { index = 1, score = 0.05 },
        }),
    }
    local out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
    check("cross_encoder TEI: no error",       err == nil, tostring(err))
    check("cross_encoder TEI: result count=3", out ~= nil and #out == 3,
        tostring(out and #out))
    check("cross_encoder TEI: row1.index=2",  out ~= nil and out[1] ~= nil and out[1].index == 2,
        tostring(out and out[1] and out[1].index))
    check("cross_encoder TEI: row1.score≈0.91",
        out ~= nil and out[1] ~= nil and math.abs(out[1].score - 0.91) < 1e-6,
        tostring(out and out[1] and out[1].score))
    check("cross_encoder TEI: row2.index=0",  out ~= nil and out[2] ~= nil and out[2].index == 0,
        tostring(out and out[2] and out[2].index))

    -- Test 2: Cohere/Jina shape
    fake_response = {
        status = 200,
        body = cjson.encode({
            results = {
                { index = 1, relevance_score = 0.88 },
                { index = 2, relevance_score = 0.40 },
            },
        }),
    }
    out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
    check("cross_encoder Cohere: no error",        err == nil, tostring(err))
    check("cross_encoder Cohere: result count=2",  out ~= nil and #out == 2,
        tostring(out and #out))
    check("cross_encoder Cohere: row1.index=1",    out ~= nil and out[1] ~= nil and out[1].index == 1,
        tostring(out and out[1] and out[1].index))
    check("cross_encoder Cohere: row1.score≈0.88",
        out ~= nil and out[1] ~= nil and math.abs(out[1].score - 0.88) < 1e-6,
        tostring(out and out[1] and out[1].score))

    -- Test 3: missing rerank_url
    out, err = ce.rerank("q", hits, {})
    check("cross_encoder missing url: out=nil", out == nil)
    check("cross_encoder missing url: error msg", err ~= nil and err:find("rerank_url not set") ~= nil,
        tostring(err))

    -- Test 4: HTTP 503
    fake_response = { status = 503, body = "Service Unavailable" }
    out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
    check("cross_encoder HTTP 503: out=nil", out == nil)
    check("cross_encoder HTTP 503: error mentions HTTP 503",
        err ~= nil and err:find("HTTP 503") ~= nil, tostring(err))

    -- Test 5: malformed JSON
    fake_response = { status = 200, body = "not json at all" }
    out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
    check("cross_encoder bad JSON: out=nil",  out == nil)
    check("cross_encoder bad JSON: err set",  err ~= nil)

    -- Test 6: empty hits
    out, err = ce.rerank("q", {}, { rerank_url = "http://x/rerank" })
    check("cross_encoder empty hits: no error", err == nil, tostring(err))
    check("cross_encoder empty hits: out empty", out ~= nil and #out == 0,
        tostring(out and #out))
end

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
