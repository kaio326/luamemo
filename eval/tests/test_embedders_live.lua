-- eval/tests/test_embedders_live.lua
-- The HTTP embedders against a real service, through memo (what a user runs): Ollama and
-- TEI each embed, rank a paraphrase above an unrelated text, and carry a write / search
-- round trip in a project of their own. Each is skipped when nothing answers at its URL
-- (the in-process GGUF embedder has test_gguf_ffi). Endpoints — kept by the runner:
--   MEMO_LIVE_OLLAMA_URL   (http://127.0.0.1:11434/api/embeddings)
--   MEMO_LIVE_OLLAMA_MODEL (nomic-embed-text), MEMO_LIVE_OLLAMA_DIM (768)
--   MEMO_LIVE_TEI_URL      (http://127.0.0.1:8081/embed), MEMO_LIVE_TEI_DIM (1024)
-- Run: luajit eval/tests/run.lua --only embedders_live

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("live embedders")
local check, section, finish = T.check, T.section, T.finish
local json = require("luamemo.json")
local sh = H.sh

local REPO = (sh("pwd")):gsub("%s+$", "")
local LUA_DIR = ((sh("command -v " .. H.lua_bin())):gsub("%s+$", "")):match("^(.*)/") or "/usr/bin"

local function env(name, default)
    local v = os.getenv(name)
    return (v and v ~= "") and v or default
end

local SERVICES = {
    { name = "Ollama", adapter = "ollama", url = env("MEMO_LIVE_OLLAMA_URL", "http://127.0.0.1:11434/api/embeddings"),
      model = env("MEMO_LIVE_OLLAMA_MODEL", "nomic-embed-text"), dim = env("MEMO_LIVE_OLLAMA_DIM", "768") },
    { name = "TEI", adapter = "tei", url = env("MEMO_LIVE_TEI_URL", "http://127.0.0.1:8081/embed"),
      model = env("MEMO_LIVE_TEI_MODEL", ""), dim = env("MEMO_LIVE_TEI_DIM", "1024") },
}

local function answers(url)
    local base = url:match("^(https?://[^/]+)")
    local _, code = sh(("curl -s -m 3 -o /dev/null %q"):format(base or url))
    return code == 0
end

for _, s in ipairs(SERVICES) do
section(s.name, function()
io.write("\n--- ", s.name, " (", s.url, ") ---\n")
if not answers(s.url) then io.write("[SKIP] nothing answers at ", s.url, "\n"); return end
local base = os.tmpname(); os.remove(base)
local home, proj = base .. "-home", base .. "-proj"
os.execute(("mkdir -p %q %q"):format(home, proj))
local rc = assert(io.open(proj .. "/.luamemorc", "w"))
rc:write(("MEMO_DB='%s'\nMEMO_SCOPE='repo:live'\nMEMO_EMBEDDER_ADAPTER='%s'\nMEMO_EMBEDDER_URL='%s'\nMEMO_EMBED_DIM='%s'\n")
    :format(base .. ".db", s.adapter, s.url, s.dim))
if s.model ~= "" then rc:write(("MEMO_EMBEDDER_MODEL='%s'\n"):format(s.model)) end
rc:close()
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- by hand: trusted (memo runs with HOME=home)
local ENV = ("cd %q && env -i HOME=%q PATH=%q bash %q"):format(proj, home, LUA_DIR .. ":/usr/bin:/bin", REPO .. "/cli/memo")
local function embed(a, b)
    return json.decode((sh(("%s embed %q --compare-to %q --json 2>/dev/null"):format(ENV, a, b)))) or {}
end
local near = embed("the deploy waits for the staging gate", "deployments must pass the staging check first")
local far = embed("the deploy waits for the staging gate", "a recipe for lemon cake with almonds")
check("embeds: the configured size, no truncation", near.ok and tonumber(near.dim) == tonumber(s.dim)
    and near.truncated == false, json.encode(near))
check(("a paraphrase is closer than an unrelated text (%.3f > %.3f)"):format(tonumber(near.cosine) or 0,
    tonumber(far.cosine) or 0), (tonumber(near.cosine) or 0) > (tonumber(far.cosine) or 1) + 0.05)
sh(("%s write --kind decision --title %q --body %q"):format(ENV, "staging gate",
    "Every deploy waits for the staging gate to pass."))
sh(("%s write --kind fact --title %q --body %q"):format(ENV, "cake", "The lemon cake needs almonds."))
local r = json.decode((sh(("%s search %q --limit 1 2>/dev/null"):format(ENV, "do releases need a check before going out?"))))
    or {}
check("write / search through it: the meaning is found, not the words", ((r.results or {})[1] or {}).title
    == "staging gate", json.encode(r.results))
os.execute(("rm -rf %q %q %q.db*"):format(home, proj, base))
end)
end

finish()
