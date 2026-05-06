-- eval/smoke_recommend.lua — decision-tree matrix tests for cli.recommend.
-- Pure Lua, no DB, no network. Run with:
--   cd luamemo && lua5.1 eval/smoke_recommend.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local R = require("luamemo.cli.recommend")

local cases = {
    -- has_gpu, gpu_free, has_docker, has_ollama, ram_mb, multi, long, hosted, allow_hash | want_adapter, want_model
    {"GPU+Docker, multilingual",
     {has_gpu=true, gpu_free_mb=4096, has_docker=true, multilingual=true},
     "tei", "BAAI/bge-m3"},

    {"GPU+Docker, long rows",
     {has_gpu=true, gpu_free_mb=4096, has_docker=true, long_rows=true},
     "tei", "BAAI/bge-m3"},

    {"GPU+Docker, English short",
     {has_gpu=true, gpu_free_mb=4096, has_docker=true},
     "ollama", "nomic-embed-text"},

    {"GPU below 2GB free -> treated as no-GPU",
     {has_gpu=true, gpu_free_mb=512, has_docker=true, has_ollama=true, ram_mb=8192},
     "ollama", "nomic-embed-text"},

    {"No GPU, Docker+RAM, multilingual -> bge-m3 CPU",
     {has_docker=true, ram_mb=8192, multilingual=true},
     "tei", "BAAI/bge-m3"},

    {"No GPU, Docker+RAM, English short, ollama reachable -> nomic CPU",
     {has_docker=true, ram_mb=8192, has_ollama=true},
     "ollama", "nomic-embed-text"},

    {"No GPU, Docker, low RAM, hosted ok -> openai",
     {has_docker=true, ram_mb=1024, allow_hosted=true},
     "openai", "text-embedding-3-small"},

    {"Nothing local, hosted ok -> openai",
     {allow_hosted=true},
     "openai", "text-embedding-3-small"},

    {"Nothing, allow_hash -> hash",
     {allow_hash=true},
     "hash", "hash"},
}

local fail = 0
for _, c in ipairs(cases) do
    local name, profile, want_a, want_m = c[1], c[2], c[3], c[4]
    local rec, err = R.decide(profile)
    if not rec then
        io.write(string.format("[FAIL] %s -> nil (err=%s)\n", name, err)); fail = fail + 1
    elseif rec.adapter ~= want_a or rec.model ~= want_m then
        io.write(string.format("[FAIL] %s -> %s/%s (want %s/%s)\n",
            name, rec.adapter, rec.model, want_a, want_m)); fail = fail + 1
    else
        io.write(string.format("[ok]   %s -> %s/%s\n", name, rec.adapter, rec.model))
    end
end

-- Negative: nothing + no allow flags -> nil
local rec, err = R.decide({})
if rec then
    io.write("[FAIL] empty profile should not yield a recommendation\n"); fail = fail + 1
else
    io.write("[ok]   empty profile -> nil (" .. err:gsub("\n.*", "") .. "...)\n")
end

-- Sanity: SAFE_CHARS table is populated.
assert(R.SAFE_CHARS["bge-m3"] == 24000)
assert(R.SAFE_CHARS["nomic-embed-text"] == 6000)
io.write("[ok]   SAFE_CHARS populated\n")

if fail > 0 then
    io.write(string.format("\n%d failure(s).\n", fail)); os.exit(1)
end
io.write("\nAll passed.\n")
