-- eval/summarizer_bench.lua — which model should summarize by default: the in-process gemma-4 or Ollama's?
--
--   luajit eval/summarizer_bench.lua --db bench-100k.db [--batches 12] [--size 6] [--backend both|gguf|ollama]
--        [--gguf-model PATH] [--ollama-model gemma4:e4b] [--ollama-url URL] [--out r.json]
--
-- The same batches of real memories (consecutive sections of the owner's own notes in the corpus: planner, change-log,
-- research, per-project notes — read locally, never sent anywhere) go through each backend with the SAME prompt
-- (summarizers/_common.summary_prompt) and the SAME parser, and for each batch it measures
--   seconds       wall time of the call (the in-process model's load is reported apart)
--   parsed        the output is a JSON object with a title and a body (strict: the whole output; lenient: the
--                 first {…} in it — what an adapter without constrained decoding would have to do)
--   coverage      the share of the sources' salient tokens (numbers, identifiers, file names, camelCase, ALLCAPS)
--                 that the summary keeps
--   invented      the share of the summary's salient tokens found in NO source (a hallucination proxy)
--   ratio         summary length / source length
-- Decision rule (docs: copilot-planer, Phase 20.1b): the backend whose coverage and invented rate are no worse than
-- the other's beyond noise; on a tie the faster; on a tie again the in-process one (no server to run).

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json   = require("luamemo.json")
local util   = require("luamemo.util")
local socket = require("socket")

local args = { db = nil, batches = 12, size = 6, backend = "both", out = nil,
               ollama_model = "gemma4:e4b", ollama_url = "http://127.0.0.1:11434/api/generate",
               gguf_model = util.env("MEMO_GEN_MODEL") }
do
    local i = 1
    while i <= #arg do
        local a, v = arg[i], arg[i + 1]
        if a == "--db" then args.db = v
        elseif a == "--batches" then args.batches = tonumber(v)
        elseif a == "--size" then args.size = tonumber(v)
        elseif a == "--backend" then args.backend = v
        elseif a == "--out" then args.out = v
        elseif a == "--gguf-model" then args.gguf_model = v
        elseif a == "--ollama-model" then args.ollama_model = v
        elseif a == "--ollama-url" then args.ollama_url = v
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
        i = i + 2
    end
end
assert(args.db, "--db is required")
assert(require("corpus.build").is_bench_path(args.db))

-- ── the batches ──────────────────────────────────────────────────────────────

local src = assert(require("luamemo.db").open(args.db, { readonly = true }))
local rows = src.query("SELECT scope, title, body FROM lm_memories WHERE scope LIKE 'repo:%' AND "
    .. "json_extract(metadata, '$.role') IN ('planner', 'changelog', 'research', 'note', 'rules') ORDER BY scope, id") or {}
src.close()
local chunks, cur = {}, {}
for _, r in ipairs(rows) do
    if #cur > 0 and cur[1].scope ~= r.scope then cur = {} end
    cur[#cur + 1] = r
    if #cur == args.size then chunks[#chunks + 1] = cur; cur = {} end
end
assert(#chunks >= args.batches, "only " .. #chunks .. " batches of " .. args.size .. " in the notes")
local batches, stride = {}, math.floor(#chunks / args.batches)
for i = 1, args.batches do batches[i] = chunks[(i - 1) * stride + 1] end

-- ── what a summary keeps ─────────────────────────────────────────────────────

-- The salient tokens of a text: numbers, identifiers with an underscore or a dot, file names, camelCase, ALLCAPS —
-- the very rule the fold review applies, so what is measured here is what the review would check.
local salient = require("luamemo.fold").salient

local function score(batch, summary)
    local sources = {}
    local total_len = 0
    for _, m in ipairs(batch) do
        for k in pairs(salient((m.title or "") .. " " .. (m.body or ""))) do sources[k] = true end
        total_len = total_len + #(m.body or "")
    end
    local mine = salient((summary.title or "") .. " " .. (summary.body or ""))
    local n_src, kept, n_mine, invented = 0, 0, 0, 0
    for k in pairs(sources) do n_src = n_src + 1; if mine[k] then kept = kept + 1 end end
    for k in pairs(mine) do n_mine = n_mine + 1; if not sources[k] then invented = invented + 1 end end
    return { coverage = n_src > 0 and kept / n_src or 0, invented = n_mine > 0 and invented / n_mine or 0,
             ratio = total_len > 0 and #(summary.body or "") / total_len or 0 }
end

-- ── the backends ─────────────────────────────────────────────────────────────

local common = require("luamemo.summarizers._common")

local function parse_strict(text)
    local t = json.decode(text)
    if type(t) == "table" and t.title and t.body then return t end
end
local function parse_lenient(text)
    local s = tostring(text):gsub("^%s*```%a*%s*", ""):gsub("%s*```%s*$", "")
    local a, b = s:find("%b{}")
    if a then
        local t = json.decode(s:sub(a, b))
        if type(t) == "table" and t.title and t.body then return t end
    end
end

local backends = {}

backends.ollama = {
    name = "Ollama " .. args.ollama_model,
    run = function(batch)
        local t0 = socket.gettime()
        local sum, err = require("luamemo.summarizers.ollama").summarize(batch,
            { summarizer_url = args.ollama_url, summarizer_model = args.ollama_model, summarizer_timeout_ms = 900000 })
        return { secs = socket.gettime() - t0, strict = sum, lenient = sum, err = err }
    end,
}

backends.gguf = {
    name = "in-process " .. tostring(args.gguf_model):match("([^/]+)$"),
    run = function(batch)
        local gen = require("luamemo.sensing.generate")
        local cfg = { gen_model = args.gguf_model, gen_n_ctx = 8192, max_tokens = 700 }
        local markup = gen.markup(cfg)
        local prompt = common.summary_prompt(batch)
        if markup == "gemma4" then prompt = "<|turn>user\n" .. prompt .. "<turn|>\n<|turn>model\n"
        else prompt = "<start_of_turn>user\n" .. prompt .. "<end_of_turn>\n<start_of_turn>model\n" end
        local t0 = socket.gettime()
        local out, err = gen.complete(prompt, cfg)
        local secs = socket.gettime() - t0
        if not out then return { secs = secs, err = err } end
        return { secs = secs, strict = parse_strict(out), lenient = parse_lenient(out), raw = out }
    end,
    warm = function(batch)   -- (the model's load is not the cost of a summary)
        local gen = require("luamemo.sensing.generate")
        local t0 = socket.gettime()
        gen.complete("<|turn>user\nsay ok<turn|>\n<|turn>model\n", { gen_model = args.gguf_model, gen_n_ctx = 8192, max_tokens = 4 })
        return socket.gettime() - t0
    end,
}

-- ── run ──────────────────────────────────────────────────────────────────────

local function mean(t) local s = 0; for _, v in ipairs(t) do s = s + v end return #t > 0 and s / #t or 0 end
local function median(t)
    if #t == 0 then return 0 end
    local c = {}; for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    return c[math.floor(#c / 2) + 1]
end

local result = { batches = #batches, size = args.size, backends = {} }
for _, key in ipairs({ "gguf", "ollama" }) do
    if args.backend == "both" or args.backend == key then
        local be = backends[key]
        local r = { name = be.name, secs = {}, strict = 0, lenient = 0, cov = {}, inv = {}, ratio = {}, errors = 0 }
        if be.warm then r.load_secs = be.warm() end
        for i, batch in ipairs(batches) do
            local o = be.run(batch)
            r.secs[#r.secs + 1] = o.secs
            if o.err then r.errors = r.errors + 1 end
            if o.strict then r.strict = r.strict + 1 end
            local best = o.strict or o.lenient
            if o.lenient then r.lenient = r.lenient + 1 end
            if best then
                local s = score(batch, best)
                r.cov[#r.cov + 1], r.inv[#r.inv + 1], r.ratio[#r.ratio + 1] = s.coverage, s.invented, s.ratio
            end
            io.stderr:write(("  %-34s batch %2d/%d  %6.1f s  %s\n"):format(be.name, i, #batches, o.secs,
                best and "parsed" or ("NOT parsed" .. (o.err and (": " .. tostring(o.err):sub(1, 60)) or ""))))
        end
        r.summary = { secs_mean = mean(r.secs), secs_median = median(r.secs), parsed_strict = r.strict / #batches,
                      parsed_lenient = r.lenient / #batches, coverage = mean(r.cov), invented = mean(r.inv), ratio = mean(r.ratio),
                      errors = r.errors }
        result.backends[key] = r
        local s = r.summary
        print(("%-34s %6.1f s/batch (median %.1f)%s · parsed %3.0f %% strict, %3.0f %% lenient · keeps %4.1f %% of the facts · invented %4.1f %% · summary %3.0f %% of the source"):format(
            be.name, s.secs_mean, s.secs_median, r.load_secs and (" (load " .. ("%.0f"):format(r.load_secs) .. " s)") or "",
            100 * s.parsed_strict, 100 * s.parsed_lenient, 100 * s.coverage, 100 * s.invented, 100 * s.ratio))
    end
end

if args.out then
    local f = assert(io.open(args.out, "w"))
    f:write(json.encode(result)); f:close()
end
