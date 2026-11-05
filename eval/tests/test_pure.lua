-- eval/tests/test_pure.lua
-- Merged pure-Lua tests (no DB, no network):
--   Recommend       (cli.recommend decision tree)
--   Paraphrase      (eval/utils.lua deterministic generator)
--   Cross Encoder   (rerankers.cross_encoder with a stand-in luamemo.http)
--   Index format numbers, shared helpers (util / federation.common)
--
-- Usage:
--   luajit eval/tests/run.lua --only pure

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
-- Recommend
-- =========================================================================
header("Recommend")

do
    local R = require("luamemo.cli.recommend")

    -- Services as calibrate's probes report them once they answered a real
    -- embedding from this host (probe.ollama_ready / probe.tei_ready).
    local OLL = { url = "http://localhost:11434/api/embeddings", model = "nomic-embed-text", dim = 768 }
    local TEI = { url = "http://127.0.0.1:8081/embed", model = "BAAI/bge-m3", dim = 1024,
                  container = "lapis-tei-embed" }

    local cases = {
        -- In-process GGUF is the preferred default once it is actually set up
        -- (shim built + model present + selftest passed) — never before.
        { "GGUF ready -> in-process GGUF (preferred default)",
          { gguf_capable=true, gguf_ready=true, gguf_model="/m/embeddinggemma-300M-Q8_0.gguf" },
          "gguf", "embeddinggemma-300M-Q8_0.gguf" },
        { "GGUF ready preempts the GPU+Docker service ladder",
          { gguf_capable=true, gguf_ready=true, gguf_model="/m/embeddinggemma-300M-Q8_0.gguf",
            has_gpu=true, gpu_free_mb=8192, has_docker=true },
          "gguf", "embeddinggemma-300M-Q8_0.gguf" },
        { "GGUF-capable but not set up, nothing else -> interim hash (not a broken gguf_ffi)",
          { gguf_capable=true },
          "hash", "hash" },
        { "GGUF-capable but not set up, Ollama serving -> ollama now",
          { gguf_capable=true, ollama_ready=OLL },
          "ollama", "nomic-embed-text" },
        { "gguf_ready without a model path is not ready",
          { gguf_capable=true, gguf_ready=true },
          "hash", "hash" },
        { "GGUF opted out (--no-gguf) -> falls back to a serving service",
          { gguf_capable=true, allow_gguf=false, ollama_ready=OLL },
          "ollama", "nomic-embed-text" },
        -- Service ladder: only services that answered a real embedding count.
        { "Ollama serving -> ollama",
          { has_gpu=true, gpu_free_mb=4096, has_docker=true, has_ollama=true, ollama_ready=OLL },
          "ollama", "nomic-embed-text" },
        { "TEI + Ollama serving, multilingual -> tei",
          { tei_ready=TEI, ollama_ready=OLL, multilingual=true },
          "tei", "BAAI/bge-m3" },
        { "TEI serving, long rows -> tei",
          { tei_ready=TEI, long_rows=true },
          "tei", "BAAI/bge-m3" },
        { "TEI + Ollama serving, English short -> ollama (lighter)",
          { tei_ready=TEI, ollama_ready=OLL },
          "ollama", "nomic-embed-text" },
        { "Only TEI serving, English short -> tei",
          { tei_ready=TEI },
          "tei", "BAAI/bge-m3" },
        { "GPU below 2GB free, Ollama serving -> ollama",
          { has_gpu=true, gpu_free_mb=512, ollama_ready=OLL },
          "ollama", "nomic-embed-text" },
        { "GPU+Docker but nothing serving -> nil (no unverified service URL)",
          { has_gpu=true, gpu_free_mb=8192, has_docker=true, ram_mb=8192, multilingual=true },
          nil, nil },
        { "Ollama reachable but model not pulled -> nil",
          { has_docker=true, ram_mb=8192, has_ollama=true, ollama_not_ready="model not found" },
          nil, nil },
        { "No local embedder at all -> nil (no hosted API is ever recommended)",
          {},
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

    -- Field-level checks for the gguf branches (what calibrate persists).
    do
        local model = "/m/embeddinggemma-300M-Q8_0.gguf"
        local r = R.decide({ gguf_capable=true, gguf_ready=true, gguf_model=model, gguf_dim=768 })
        check("recommend: gguf ready persists the model path",
            r and r.setup_keys.embedder_model == model and r.setup_keys.embedder_local == "gguf_ffi")
        check("recommend: gguf ready uses the model's native dim",
            r and r.dim == 768 and r.setup_keys.embed_dim == 768)
        check("recommend: gguf ready -> no upgrade guide", r and not r.gguf_upgrade)

        local r2 = R.decide({ gguf_capable=true, gguf_ready=true, gguf_model=model, gguf_dim=512 })
        check("recommend: non-768 gguf model -> its own dim", r2 and r2.setup_keys.embed_dim == 512)

        -- EmbeddingGemma 2: its 8K context (24,000 characters) and task prompts; the 300M model as before.
        local eg2 = "/m/embeddinggemma-2-Q8_0.gguf"
        local r3 = R.decide({ gguf_capable=true, gguf_ready=true, gguf_model=eg2, gguf_dim=768 })
        check("recommend: EmbeddingGemma 2 -> 24,000-character cap and task prompts (auto)",
            r3 and r3.setup_keys.embed_max_chars == 24000 and r3.setup_keys.embed_prompts == "auto")
        check("recommend: the 300M model -> 8,000 characters, no prompts (as before)",
            r.setup_keys.embed_max_chars == 8000 and r.setup_keys.embed_prompts == nil)
        local probe = require("luamemo.cli.probe")
        check("probe: the default model is EmbeddingGemma 2, the 300M one is still looked for",
            probe.GGUF_DEFAULT_MODEL == "embeddinggemma-2-Q8_0.gguf"
            and probe.GGUF_PREVIOUS_MODELS[1] == "embeddinggemma-300M-Q8_0.gguf"
            and probe.GGUF_DEFAULT_URL:find("embeddinggemma-2-GGUF", 1, true) ~= nil)

        local h = R.decide({ gguf_capable=true, gguf_not_ready="native shim not built" })
        check("recommend: interim hash runs at the gguf dim (768)",
            h and h.dim == 768 and h.setup_keys.embed_dim == 768)
        check("recommend: interim pick flags the upgrade guide", h and h.gguf_upgrade == true)
        check("recommend: not-ready reason is in the rationale",
            h and table.concat(h.rationale, " "):find("native shim not built", 1, true) ~= nil)

        local o = R.decide({ gguf_capable=true, ollama_ready=OLL })
        check("recommend: service-ladder interim also flags the upgrade", o and o.gguf_upgrade == true)

        local no = R.decide({ gguf_capable=true, allow_gguf=false, allow_hash=true })
        check("recommend: --no-gguf -> no upgrade guide, hash at 384",
            no and not no.gguf_upgrade and no.dim == 384)

        local plain = R.decide({ allow_hash=true })
        check("recommend: --allow-hash on a non-gguf host -> hash at 384", plain and plain.dim == 384)
    end

    -- Field-level checks for the service branches: the persisted URL is the
    -- host-side endpoint that was tested (with its API path).
    do
        local o = R.decide({ ollama_ready = OLL })
        check("recommend: ollama persists the tested host endpoint",
            o and o.setup_keys.embedder_url == OLL.url and o.setup_keys.embedder_adapter == "ollama")
        check("recommend: ollama dim comes from the live probe", o and o.setup_keys.embed_dim == 768)

        local t = R.decide({ tei_ready = TEI, multilingual = true })
        check("recommend: tei persists the tested host endpoint",
            t and t.setup_keys.embedder_url == TEI.url and t.setup_keys.embedder_adapter == "tei")
        check("recommend: tei dim comes from the live probe", t and t.setup_keys.embed_dim == 1024)
        check("recommend: tei safe chars keyed by model basename (bge-m3)",
            t and t.setup_keys.embed_max_chars == R.SAFE_CHARS["bge-m3"])

        local unknown = R.decide({ tei_ready = { url = "http://127.0.0.1:9000/embed",
            model = "acme/mystery-embed", dim = 512, container = "x" } })
        check("recommend: unknown service model -> conservative 6000 chars",
            unknown and unknown.setup_keys.embed_max_chars == 6000 and unknown.setup_keys.embed_dim == 512)

        local leaked = {}
        for _, p in ipairs({ { ollama_ready = OLL }, { tei_ready = TEI }, { tei_ready = TEI, long_rows = true },
                             { gguf_capable = true, ollama_ready = OLL } }) do
            local r = R.decide(p)
            local u = r and r.setup_keys.embedder_url or ""
            if u:find("host.docker.internal", 1, true) or u:find("lapis-tei-embed", 1, true) then
                leaked[#leaked + 1] = u
            end
        end
        check("recommend: persisted URL is never a container-only hostname", #leaked == 0,
            table.concat(leaked, ", "))

        local _, why = R.decide({ has_gpu=true, gpu_free_mb=8192, has_docker=true, ram_mb=8192, multilingual=true })
        check("recommend: nothing serving -> hint to start TEI bge-m3 (GPU image)",
            why and why:find("docker run", 1, true) and why:find("--gpus all", 1, true)
                and why:find("--model-id BAAI/bge-m3", 1, true) ~= nil, why)

        local _, why2 = R.decide({ has_ollama=true, ollama_not_ready="model 'nomic-embed-text' not found" })
        check("recommend: Ollama not-ready reason surfaces", why2 and why2:find("not found", 1, true) ~= nil, why2)
    end

    -- probe.parse_docker_port: host address of a TEI container's published port.
    do
        local P = require("luamemo.cli.probe")
        for _, c in ipairs({
            { "127.0.0.1:8081->80/tcp",                     "127.0.0.1:8081" },
            { "0.0.0.0:8081->80/tcp, [::]:8081->80/tcp",    "127.0.0.1:8081" },
            { "192.168.1.5:9000->80/tcp",                   "192.168.1.5:9000" },
            { "80/tcp",                                     nil },
            { "0.0.0.0:5433->5432/tcp",                     nil },
            { "",                                           nil },
        }) do
            local got = P.parse_docker_port(c[1], 80)
            check(("probe.parse_docker_port(%q) = %s"):format(c[1], tostring(c[2])), got == c[2],
                "got " .. tostring(got))
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
-- Paraphrase
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
-- Cross Encoder
-- =========================================================================
header("Cross Encoder")

do
    local cjson = require("luamemo.json")

    -- A stand-in luamemo.http, injected BEFORE (re)loading the adapter (it
    -- captures the module at load time); the real one is restored at the end.
    local fake_response
    local real_http = package.loaded["luamemo.http"]
    package.loaded["luamemo.http"] = {
        request = function() return fake_response.status, fake_response.body, nil end,
    }
    package.loaded["luamemo.rerankers.cross_encoder"] = nil

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
    package.loaded["luamemo.http"] = real_http
    package.loaded["luamemo.rerankers.cross_encoder"] = nil
end

-- =========================================================================
-- The Ollama reranker and the rerank stats (what the benchmarks report as its cost)
-- =========================================================================
header("Ollama reranker")

do
    local cjson = require("luamemo.json")
    local sent, reply
    local real_http = package.loaded["luamemo.http"]
    package.loaded["luamemo.http"] = {
        request = function(_, o) sent = cjson.decode(o.body); return 200, reply, nil end,
    }
    package.loaded["luamemo.rerankers.ollama"] = nil
    local rerank = require("luamemo.rerank")
    rerank.stats(true)
    local hits = { { id = 1, title = "a", body = "deploys go through staging" }, { id = 2, title = "b", body = "lunch" } }
    reply = cjson.encode({ response = cjson.encode({ scores = { { index = 2, score = 0.9 }, { index = 1, score = 0.1 } } }),
        prompt_eval_count = 100, eval_count = 20 })
    local out = rerank.rerank("where do deploys go", hits, { rerank_adapter = "ollama",
        rerank_url = "http://x/api/generate", rerank_model = "gemma4:e4b" })
    check("ollama: the request asks for JSON without thinking (think = false), the model named",
        sent and sent.think == false and sent.format == "json" and sent.model == "gemma4:e4b", cjson.encode(sent))
    check("ollama: the scores reorder the hits", out and out[1].id == 2 and out[2].id == 1)
    reply = cjson.encode({ response = "not json", prompt_eval_count = 50, eval_count = 5 })
    local kept = rerank.rerank("q", hits, { rerank_adapter = "ollama", rerank_url = "http://x/api/generate" })
    check("ollama: a reply that isn't the JSON fails the rerank (nil)", kept == nil)
    local s = rerank.stats()
    check("rerank stats: both calls timed, the model's tokens counted (prompt + generated), one failed",
        #s.ms == 2 and s.tokens[1] == 120 and s.tokens[2] == 55 and s.failed == 1, cjson.encode(s))
    package.loaded["eval.metrics"] = nil
    local rs = require("eval.metrics").rerank_summary()
    check("metrics.rerank_summary: ms mean / p90, tokens mean, failures",
        rs.rerank_ms_mean and rs.rerank_ms_p90 and rs.rerank_tokens_mean == 87.5 and rs.rerank_failed == 1,
        cjson.encode(rs))
    rerank.stats(true)
    check("metrics.rerank_summary: nothing reranked → {}", next(require("eval.metrics").rerank_summary()) == nil)
    package.loaded["luamemo.http"] = real_http
    package.loaded["luamemo.rerankers.ollama"] = nil
end

-- =========================================================================
-- Task prompts (luamemo.embed): the embedder's own query / document instructions
-- =========================================================================
header("Embedding task prompts")

do
    local embed, common = require("luamemo.embed"), require("luamemo.federation.common")
    local gemma = { embedder_local = "gguf_ffi", embedder_model = "/m/embeddinggemma-300M-Q8_0.gguf", embed_dim = 768 }
    check("prompts: none by default", embed.prompts(gemma) == nil)
    gemma.embed_prompts = "auto"
    local p = embed.prompts(gemma)
    check("prompts auto: EmbeddingGemma's own", p and p.query == "task: search result | query: {text}"
        and p.document == "title: none | text: {text}")
    local nomic = embed.prompts({ embed_prompts = "auto", embedder_adapter = "ollama", embedder_model = "nomic-embed-text" })
    check("prompts auto: nomic-embed-text's own", nomic and nomic.query == "search_query: {text}"
        and nomic.document == "search_document: {text}")
    check("prompts auto: none for an embedder without known prompts (hash)",
        embed.prompts({ embed_prompts = "auto", embedder_local = "hash" }) == nil)
    check("prompts: a custom JSON pair", (embed.prompts({ embed_prompts = '{"query":"Q: {text}","document":"D: {text}"}' })
        or {}).query == "Q: {text}")
    check("prompts: part of the embedding space (embedder_sig); without them the signature as before",
        common.embedder_sig(gemma) == "gguf_ffi|embeddinggemma-300M-Q8_0.gguf|768|auto:embeddinggemma"
        and common.embedder_sig({ embedder_local = "hash" }) == "hash||384")
    -- Applied: the query and the stored text get their own instruction.
    embed.configure({ embedder_local = "hash", embed_dim = 64, embed_prompts = '{"query":"Q: {text}","document":"D: {text}"}' })
    local q, d = embed.embed("deploys go through staging", "query"), embed.embed("deploys go through staging")
    embed.configure({ embedder_local = "hash", embed_dim = 64 })
    local q2, d2 = embed.embed("Q: deploys go through staging"), embed.embed("D: deploys go through staging")
    local function same(a, b) for i = 1, #a do if math.abs(a[i] - b[i]) > 1e-12 then return false end end return #a == #b end
    check("prompts: a query is embedded as its prompt, a stored text as its own", q and d and same(q, q2) and same(d, d2)
        and not same(q, d))
end

-- =========================================================================
-- index.format number rendering
-- =========================================================================
header("Index format numbers")

do
    -- Agents must see "path:351" for a line number, whatever the number type.
    local F = require("luamemo.index.format")
    check("format.num(351.0) = '351'", F.num(351.0) == "351", F.num(351.0))
    check("format.num(2.5) keeps the fraction", F.num(2.5) == "2.5", F.num(2.5))
    check("format.num('x') passes through", F.num("x") == "x")
    local sym = F.symbol_line({ title = "m.f", metadata = { path = "a.lua", line = 351.0, symbol_type = "function" } })
    check("symbol_line renders an integral float line as an integer",
        sym:find("a.lua:351  ", 1, true) ~= nil and not sym:find("351.0", 1, true), sym)
    local fl = F.file_line({ title = "a.lua", metadata = { path = "a.lua", lines = 87.0 } })
    check("file_line renders an integral float line count as an integer",
        fl:find("(87 lines)", 1, true) ~= nil, fl)
end

-- =========================================================================
header("Shared helpers (util / federation.common)")
do
    local util = require("luamemo.util")
    local r = util.redact_url
    check("redact_url: password masked, user kept", r("postgres://pg:secret@h:5432/db") == "postgres://pg:***@h:5432/db")
    check("redact_url: a bare userinfo (token) is masked whole", r("https://ghp_T0KEN@github.com/x") == "https://***@github.com/x")
    check("redact_url: a raw '@' in the password leaks nothing", r("postgres://u:p@w@h/db") == "postgres://u:***@h/db")
    check("redact_url: '@' in a query is not userinfo; text without URLs untouched",
        r("http://h/p?mail=a@b.c") == "http://h/p?mail=a@b.c" and r("user:dev@corp.io") == "user:dev@corp.io")
    check("redact_url: every URL in a message", r("a http://x:y@h1/ b http://z:w@h2/") == "a http://x:***@h1/ b http://z:***@h2/")
    check("redact_url: a credential query param is masked, an ordinary one kept",
        r("https://api/e?api_key=AIza9&model=m&keyword=cat") == "https://api/e?api_key=***&model=m&keyword=cat")
    -- write_private: a 0600 file, the parent dir created 0700, written atomically.
    local base = os.tmpname(); os.remove(base)
    local p = base .. "-wp/sub/secret.txt"
    local ok_wp = util.write_private(p, "s3cret")
    local function st(path)   -- octal mode: GNU stat -c, else BSD / macOS stat -f
        return (io.popen(("stat -c %%a %s 2>/dev/null || stat -f %%Lp %s"):format(path, path)):read("*a") or "")
            :gsub("%s+$", "")
    end
    local mode, dmode = st(p), st(base .. "-wp/sub")
    local rf = io.open(p); local got = rf and rf:read("*a"); if rf then rf:close() end
    check("util.write_private: 0600 file in a 0700 dir, content written", ok_wp == true and mode == "600"
        and dmode == "700" and got == "s3cret")
    check("util.write_private: no temp file left behind",
        tonumber((io.popen("ls " .. base .. "-wp/sub | wc -l"):read("*a"))) == 1)   -- (macOS pads the count)
    -- A dotfiles manager's symlink (~/.luamemorc → dotfiles/.luamemorc) is written through
    -- with follow_link: it was replaced by a plain file, and the dotfiles copy went stale.
    -- Without it the link is replaced and its target left alone.
    local function slurp(p) local h = io.open(p); local s = h and h:read("*a"); if h then h:close() end; return s end
    local function is_link(p) local r = os.execute("test -L " .. p); return r == 0 or r == true end
    os.execute(("mkdir -p %s-wp/dots && printf old > %s-wp/dots/rc && ln -s dots/rc %s-wp/rc && "
        .. "printf other > %s-wp/dots/other && ln -s dots/other %s-wp/rc2"):format(base, base, base, base, base))
    local ok_ln = util.write_private(base .. "-wp/rc", "new", { follow_link = true })
    check("util.write_private follow_link: a link to the user's own file stays; the target is written",
        ok_ln == true and is_link(base .. "-wp/rc") and slurp(base .. "-wp/dots/rc") == "new")
    local ok_nf = util.write_private(base .. "-wp/rc2", "new")
    check("util.write_private: otherwise a link is replaced, its target left alone", ok_nf == true
        and not is_link(base .. "-wp/rc2") and slurp(base .. "-wp/dots/other") == "other")
    -- rc_set: the user's own ~/.luamemorc follows its link; a project's linked settings
    -- file (a downloaded folder pointing it at another of the user's files) is left alone.
    local ffi = require("ffi"); pcall(ffi.cdef, "int setenv(const char*, const char*, int);")
    local old_home = os.getenv("HOME")
    os.execute(("mkdir -p %s-wp/home/proj && printf '{\"theme\":1}\\n' > %s-wp/home/app.json && "
        .. "ln -s ../app.json %s-wp/home/proj/.luamemorc && ln -s ../dots/rc %s-wp/home/.luamemorc")
        :format(base, base, base, base))
    ffi.C.setenv("HOME", base .. "-wp/home", 1)
    local cli_common = require("luamemo.cli._common")
    local ok_home = cli_common.rc_set(base .. "-wp/home/.luamemorc", "MEMO_X", "1")
    local ok_proj, why_proj = cli_common.rc_set(base .. "-wp/home/proj/.luamemorc", "MEMO_X", "1")
    ffi.C.setenv("HOME", old_home, 1)
    check("rc_set: ~/.luamemorc is written through its link", ok_home == true
        and is_link(base .. "-wp/home/.luamemorc") and (slurp(base .. "-wp/dots/rc") or ""):find("MEMO_X=", 1, true))
    check("rc_set: a project's settings file that is a link is left alone (and what it points to)",
        ok_proj == nil and tostring(why_proj):find("symbolic link", 1, true)
        and slurp(base .. "-wp/home/app.json") == '{"theme":1}\n', tostring(why_proj))
    os.execute("rm -rf " .. base .. "-wp")
    check("util.env: the value, nil when unset or empty", util.env("HOME") == os.getenv("HOME")
        and util.env("LUAMEMO_SURELY_UNSET_VAR") == nil)
    -- Text cut at a byte count ended inside a character ("decis\195" of "decisão"):
    -- stored, sent to rerankers / embedders, shown to the agent as bytes that aren't text.
    local fix = util.fix_utf8
    local pt = "A decisão sobre a migração do serviço foi adiada."
    local all_ok = true
    for n = 1, #pt do
        if fix(util.cut_utf8(pt, n)) ~= util.cut_utf8(pt, n) or fix(util.clip(pt, n)) ~= util.clip(pt, n)
            or fix(require("luamemo.federation.common").clip(pt, n) or "") ~= (require("luamemo.federation.common").clip(pt, n) or "") then
            all_ok = false
        end
    end
    check("cut_utf8 / util.clip / common.clip never end inside a character (every cut length)", all_ok
        and util.cut_utf8(pt, 8) == "A decis" and util.cut_utf8("abc", 5) == "abc")
    -- calibrate's project scan: the directory went into `find` unquoted — one named
    -- x$(…)y ran the command, one with a space scanned nothing.
    local probe = require("luamemo.cli.probe")
    local pbase = os.tmpname(); os.remove(pbase)
    local spaced, evil, mark = pbase .. "-my proj", pbase .. "-x$(touch " .. pbase .. "-RAN)y", pbase .. "-RAN"
    for _, d in ipairs({ spaced, evil }) do
        os.execute(("mkdir -p %s && printf x > %s"):format(util.shell_quote(d .. "/src"), util.shell_quote(d .. "/src/a.lua")))
    end
    local c1, c2 = probe.scan_project(spaced).ext_census, probe.scan_project(evil).ext_census
    local ran = io.open(mark); if ran then ran:close() end
    check("calibrate's project scan: a directory with a space or $(…) in its name is scanned, nothing runs",
        not ran and (c1[1] or {}).ext == "lua" and (c2[1] or {}).ext == "lua", tostring(ran))
    os.execute(("rm -rf %s %s %s"):format(util.shell_quote(spaced), util.shell_quote(evil), util.shell_quote(mark)))
    check("fix_utf8: valid text unchanged; a broken byte, an overlong form, a surrogate → U+FFFD",
        fix(pt) == pt and fix("ab\195") == "ab\239\191\189" and fix("x\192\175y") == "x\239\191\189\239\191\189y"
        and fix("\237\160\128") == "\239\191\189\239\191\189\239\191\189" and fix("plain") == "plain")
    -- The settings a project's .luamemorc may never set (they name code to run): the same
    -- list in cli/memo (bash) and luamemo.settings (Lua).
    local mf = io.open("cli/memo"); local memo_src = mf and mf:read("*a") or ""; if mf then mf:close() end
    local bash_list, lua_list = {}, {}
    for k in (memo_src:match('_RC_USER_ONLY="([^"]*)"') or ""):gmatch("%S+") do bash_list[#bash_list + 1] = k end
    for k in pairs(require("luamemo.settings").USER_ONLY) do lua_list[#lua_list + 1] = k end
    table.sort(bash_list); table.sort(lua_list)
    check("the user-only settings: cli/memo and luamemo.settings list the same ones",
        #lua_list >= 4 and table.concat(bash_list, ",") == table.concat(lua_list, ","),
        table.concat(bash_list, ",") .. " vs " .. table.concat(lua_list, ","))

    -- redact_secrets: what a pasted credential looks like is replaced before a memory is
    -- stored; ids, hashes and code stay as they are.
    local rs = util.redact_secrets
    local key = "sk-ant-api03-" .. ("Ab3x"):rep(10)
    check("redact_secrets: a prefixed API key", rs("use " .. key .. " now") == "use [redacted] now")
    check("redact_secrets: GitHub / AWS / Slack tokens", rs("ghp_" .. ("a1B2"):rep(9)) == "[redacted]"
        and rs("id AKIAIOSFODNN7EXAMPLE") == "id [redacted]" and rs("xoxb-" .. ("12ab"):rep(6)) == "[redacted]")
    check("redact_secrets: Bearer / Basic credentials keep their label",
        rs("Authorization: Bearer abcdef0123456789xyz") == "Authorization: Bearer [redacted]"
        and rs("Authorization: Basic dXNlcjpwYXNz") == "Authorization: Basic [redacted]")
    check("redact_secrets: a JWT", rs("t=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl x")
        == "t=[redacted] x")
    check("redact_secrets: a private-key block, also one cut off",
        rs("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAb3Bl\n-----END OPENSSH PRIVATE KEY-----\nok") == "[redacted]\nok"
        and rs("x -----BEGIN RSA PRIVATE KEY----- MIIEowIBAAKCAQ") == "x [redacted]")
    check("redact_secrets: password= / API_KEY= / JSON \"secret\" values that mix letters and digits",
        rs('password=hunter2hunter OPENAI_API_KEY="abc123def456" "secret": "s3cr3tvalue"')
        == 'password=[redacted] OPENAI_API_KEY="[redacted]" "secret": "[redacted]"')
    check("redact_secrets: URL credentials (redact_url)",
        rs("postgres://bob:pa55word@db/x") == "postgres://bob:***@db/x")
    local keep = "commit 5219bac0f3e1d2c4b5a6978877665544332211aa uuid 123e4567-e89b-12d3-a456-426614174000 "
        .. "local token = args.token or self.access_token_v2; password = os.getenv(\"PW\") max_tokens = 4096 "
        .. "token: ${{ secrets.API_KEY }} sk-learn luamemo/embedders/native/bundle.lua snake_case_name_123"
    check("redact_secrets: SHAs, UUIDs, code, $VARIABLES and paths are left alone", rs(keep) == keep, rs(keep))
    check("redact_secrets: an AWS key id glued to other text; ASIA… words without a digit kept",
        rs("xAKIAIOSFODNN7EXAMPLE") == "[redacted]" and rs("ASIAPACIFICREGIONSXX") == "ASIAPACIFICREGIONSXX")
    -- has_token: the same shapes, as the org-proposal filter's check (one list for both).
    check("has_token: the scrubber's token shapes, not assignments or code",
        util.has_token(key) and util.has_token("Authorization: Basic dXNlcjpwYXNz")
        and util.has_token("-----BEGIN RSA PRIVATE KEY") and not util.has_token("password=hunter2hunter")
        and not util.has_token(keep) and not util.has_token("") and not util.has_token(nil))
    local big = ("0123456789abcdef"):rep(65536)
    local t0 = os.clock(); rs(big)
    check("redact_secrets: linear (1 MB without a break in well under a second)", os.clock() - t0 < 1,
        os.clock() - t0)
    check("util.exists / is_dir", util.exists("luamemo/util.lua") and not util.exists("luamemo/nope.lua")
        and util.is_dir("luamemo") and not util.is_dir("luamemo/util.lua"))
    -- util.ints: the values of a list that are numbers, as whole numbers (ids a caller or stored metadata hands in)
    check("util.ints: numbers and numeric strings floored, the rest left out; nil and {} give {}",
        table.concat(util.ints({ 3, "4", 5.9, "6.2", "x", true, {}, "0x10" }), ",") == "3,4,5,6,16"
        and #util.ints(nil) == 0 and #util.ints({}) == 0)
    -- util.is_symlink: the link itself, whatever it points at (and a name with spaces and quotes is quoted)
    local link_dir = os.tmpname(); os.remove(link_dir); os.execute(("mkdir -p %q"):format(link_dir))
    local plain, weird = link_dir .. "/plain file", link_dir .. "/it's a \"link\" $HOME"
    local pf = assert(io.open(plain, "w")); pf:write("x"); pf:close()
    local q = util.shell_quote
    os.execute(("ln -s %s %s; ln -s %s %s"):format(q(plain), q(weird), q(link_dir .. "/nowhere"), q(link_dir .. "/dangling")))
    check("util.is_symlink: a link (also dangling, also with a hostile name) is; a file, a directory, a missing path and nil are not",
        util.is_symlink(weird) and util.is_symlink(link_dir .. "/dangling") and not util.is_symlink(plain)
        and not util.is_symlink(link_dir) and not util.is_symlink(link_dir .. "/missing") and not util.is_symlink(nil)
        and not util.is_symlink(""))
    os.execute(("rm -rf %q"):format(link_dir))
    local r1, r2 = util.random_hex(16), util.random_hex(16)
    check("util.random_hex: 2n hex digits, a new value each call (one helper: db id, temp names)",
        #r1 == 32 and r1:match("^%x+$") ~= nil and r1 ~= r2, r1)
    check("util.to_hex / from_hex round trip", util.to_hex("\0\1\255A") == "0001ff41"
        and util.from_hex("0001ff41") == "\0\1\255A")
    local common = require("luamemo.federation.common")
    check("common.clip: trims, truncates, nil when absent / blank",
        common.clip("  abc  ", 10) == "abc" and common.clip("abcdef", 3) == "abc" and common.clip("   ", 5) == nil
        and common.clip(nil, 5) == nil)
    check("common.int_array: table or Postgres text", table.concat(common.int_array("{3,-4,5}"), ",") == "3,-4,5"
        and table.concat(common.int_array({ "7", 8 }), ",") == "7,8")
    check("common.manifest_digest: order-independent, version-sensitive",
        common.manifest_digest({ { 1, 10 }, { 2, 20 } }) == common.manifest_digest({ { 2, 20 }, { 1, 10 } })
        and common.manifest_digest({ { 1, 10 } }) ~= common.manifest_digest({ { 1, 11 } }))
end

-- =========================================================================
-- Benchmark metrics (eval/metrics.lua): miss rate, bytes to the hit
-- =========================================================================
header("Benchmark metrics")

do
    local metrics = require("eval.metrics")
    local ops, json = require("luamemo.ops"), require("luamemo.json")
    local function row(i, body)
        return { id = i, title = "t" .. i, body = body or ("body " .. i), kind = "fact", scope = "s",
                 tier = 1, score = 0.5, metadata = { lm_rank = 3, sid = "x/" .. i },
                 created_at = "2026-10-21 10:00:00.123+00" }
    end
    local rows = {}
    for i = 1, 12 do rows[i] = row(i) end

    -- The agent's bytes: the server's list of compact rows, as its tool result text.
    local compact = {}
    for i = 1, 10 do compact[i] = ops.compact_row(rows[i], ops.BODY_CAP) end
    local text = json.encode(json.list(compact))
    if json.encode("/") == '"\\/"' then text = text:gsub("\\/", "/") end
    local sum = 0
    for i = 1, 10 do sum = sum + metrics.row_bytes(rows[i]) end
    check("row_bytes: 10 rows = the server's JSON array of them ('[' + ']' − the last comma)",
        sum + 1 == #text, ("sum=%d text=%d"):format(sum, #text))
    local long = row(1, ("é"):rep(3000))
    check("row_bytes: a long body is counted at the server's cap (BODY_CAP), not whole",
        metrics.row_bytes(long) < 6000 / 2 + 400 and metrics.row_bytes(long) > ops.BODY_CAP,
        metrics.row_bytes(long))
    check("row_bytes: internal lm_* metadata is not counted (the server drops it)",
        metrics.row_bytes(row(1)) == metrics.row_bytes((function() local r = row(1)
            r.metadata = { sid = "x/1" }; return r end)()))

    local m = metrics.new()
    metrics.record(m, 1, rows)       -- hit at 1
    metrics.record(m, 3, rows)       -- hit at 3
    metrics.record(m, 12, rows)      -- found, but past the limit: a miss for the agent
    metrics.record(m, nil, rows)     -- not found
    metrics.record(m, nil, {})       -- nothing returned
    local s = metrics.summary(m)
    local b1, b3 = metrics.row_bytes(rows[1]), 0
    for i = 1, 3 do b3 = b3 + metrics.row_bytes(rows[i]) end
    local b10 = 0
    for i = 1, 10 do b10 = b10 + metrics.row_bytes(rows[i]) end
    check("summary: R@k and MRR as before", s["recall@1"] == 1 / 5 and s["recall@5"] == 2 / 5
        and s["recall@20"] == 3 / 5 and math.abs(s.mrr - (1 + 1 / 3 + 1 / 12) / 5) < 1e-9, json.encode(s))
    check("summary: miss_rate = 1 − R@limit (a rank past the limit is a miss)",
        s.miss_rate == 3 / 5 and math.abs(s.miss_rate - (1 - s["recall@10"])) < 1e-9, s.miss_rate)
    check("summary: bytes_to_hit = rows 1..rank, hits only", s.bytes_to_hit_mean == (b1 + b3) / 2
        and s.bytes_to_hit_median == (b1 + b3) / 2 and s.bytes_to_hit_p90 == b3, json.encode(s))
    check("summary: est_tokens = bytes / 4", s.est_tokens_to_hit_mean == s.bytes_to_hit_mean / 4)
    check("summary: bytes_on_miss = the limit's rows (an empty result costs 0)",
        s.bytes_on_miss_mean == (b10 + b10 + 0) / 3, s.bytes_on_miss_mean)
    check("summary: tail_misses only counts the not-found", s.tail_misses == 2 and s.limit == 10)
    local e = metrics.summary(metrics.new({ ks = { 1, 3 } }))
    check("summary: no questions — zeros, absent byte figures, the line says —",
        e.n_questions == 0 and e.miss_rate == 0 and e.bytes_to_hit_mean == nil and e["recall@3"] == 0
        and metrics.line(e):find("mean=—", 1, true) ~= nil, metrics.line(e))
    check("line: the figures in one line", metrics.line(s):find("miss=60.0%", 1, true) ~= nil, metrics.line(s))
end

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
