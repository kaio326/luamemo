-- eval/tests/test_settings.lua
-- Phase 14.5b-A — luamemo's settings, the same for the CLI and the MCP server:
--   * luamemo.settings: every setting typed, ranged and named MEMO_<KEY>; luamemo's
--     default config built from it; older names still read; a value that doesn't
--     parse is reported and ignored — or, for a strict setting (embedder, dimension,
--     org share), stops luamemo; MEMO_ names luamemo doesn't read are named, with the
--     closest setting.
--   * `memo` reads ~/.luamemorc too (the project's .luamemorc wins); `memo config
--     list|get|set|unset|check` checks values before writing them (0600, kept out of
--     git), refuses a plain-text credential in a header and the master key.
--   * {secret:NAME} in a header is read from the vault when the request is made: a
--     mock HTTP embedder that wants an API key gets it, the key is never in a file,
--     a listing or an error; the first `memo secret-store` creates the vault's key;
--     calibrate says how to give a refusing (401) embedder its key.
--   * The MCP server (over stdio) reads the .luamemorc files itself — the client's
--     environment wins — and memory_status {details} lists every setting's source.
--   * Two settings that never reached their module: digest's consolidate_threshold,
--     the learned reranker's rerank_epsilon.
-- Run: luajit eval/tests/run.lua --only settings

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Settings")
local check, section, finish = T.check, T.section, T.finish
local sh, slurp = H.sh, H.slurp

local json     = require("luamemo.json")
local settings = require("luamemo.settings")
local ffi      = require("luamemo.native.loader").ffi
pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
pcall(ffi.cdef, "int unsetenv(const char *name);")
local function setenv(k, v) if v == nil or v == false then ffi.C.unsetenv(k) else ffi.C.setenv(k, v, 1) end end
local q = require("luamemo.util").shell_quote
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end

local REPO = (sh("pwd"))
local LUA  = H.lua_bin()
local BASE = os.tmpname(); os.remove(BASE)

-- ---------------------------------------------------------------------------
section("the settings table", function()
io.write("\n--- the settings table ---\n")
local lm = require("luamemo")
local same = true
for k, v in pairs(settings.defaults()) do
    local e = settings.get(k)
    if settings.format(e, v) ~= settings.format(e, lm.config[k]) then same = false end
end
check("luamemo's default config is built from the table", same)
-- Every config key luamemo's modules read (the 14.5b audit) is a setting.
local missing = {}
for _, k in ipairs({ "db", "embedder_url", "embedder_adapter", "embedder_headers", "embedder_local", "embed_dim",
    "embed_timeout_ms", "embed_max_chars", "corpus_health_check", "skip_embed_probe", "default_scope",
    "hybrid_weights", "default_importance", "default_decay_rate", "dedup_enabled", "dedup_threshold",
    "dedup_strategy", "summarizer_adapter", "summarizer_url", "summarizer_model", "summarizer_headers",
    "summarizer_timeout_ms", "summarizer_interval_seconds", "summarizer_weight_threshold",
    "summarizer_retention_days", "summarizer_batch_size", "summarizer_max_batches", "obs_max_slots",
    "patterns_enabled", "patterns_max_body_chars", "person_name_boost", "person_name_boost_enabled",
    "quoted_phrase_boost", "quoted_phrase_boost_enabled", "ensure_ready_retry_secs", "rerank_adapter",
    "rerank_url", "rerank_model", "rerank_headers", "rerank_timeout_ms", "rerank_top_n", "rerank_enabled",
    "rerank_epsilon", "feedback_enabled", "miss_threshold", "auto_digest_enabled", "auto_digest_interval",
    "role", "org_url", "org_fingerprint", "federation_dir", "org_name", "org_share", "org_sync_ttl",
    "org_identity", "org_propose", "org_propose_scopes", "org_proposals", "org_knowledge_decay", "org_prefix",
    "master_key_path", "master_key_env", "master_key", "consolidate_threshold",
    "consolidate_reinforce_threshold", "consolidate_log_errors", "temporal_alpha", "digest_promote_tier2_at",
    "digest_promote_tier3_at", "digest_grace_days", "digest_escalate_alpha", "digest_idle_seconds",
    "dedup_candidate_limit", "embedder_input_type", "embedder_num_ctx", "projected_base", "gguf_n_ctx",
    "gguf_n_gpu", "gguf_shim_path", "gen_model", "gen_n_ctx", "gen_n_gpu" }) do
    if not settings.get(k) then missing[#missing + 1] = k end
end
check("every config key luamemo reads is a setting", #missing == 0, table.concat(missing, ", "))
local named = true
for _, e in ipairs(settings.LIST) do
    if not e.env:match("^MEMO_[A-Z0-9_]+$") or not e.doc or not e.group then named = false end
end
check("each has a MEMO_ name, a group and a meaning", named)
-- SETTINGS.md's reference is generated from the table (memo config list --markdown): a
-- setting added, removed or changed without regenerating it fails here.
local doc = slurp(REPO .. "/SETTINGS.md") or ""
local block = doc:match("<!%-%- settings:begin[^\n]*%-%->\n(.-)<!%-%- settings:end %-%->")
local md = require("luamemo.cli.config").markdown()
local first_diff
if block and block ~= md then
    local a, b = {}, {}
    for l in block:gmatch("[^\n]*") do a[#a + 1] = l end
    for l in md:gmatch("[^\n]*") do b[#b + 1] = l end
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then first_diff = ("line %d: %s\n  want: %s"):format(i, tostring(a[i]), tostring(b[i])); break end
    end
end
check("SETTINGS.md lists every setting as the table has it (regenerate: memo config list --markdown)",
    block == md, block and first_diff or "no settings:begin / settings:end block in SETTINGS.md")
local undocumented = {}
for _, e in ipairs(settings.LIST) do
    if not md:find("`" .. e.env .. "`", 1, true) then undocumented[#undocumented + 1] = e.env end
end
for name, d in pairs(settings.OTHER_VARS) do
    if type(d) == "string" and not md:find("`" .. name .. "`", 1, true) then undocumented[#undocumented + 1] = name end
end
check("… every setting and every documented tool variable is in it", #undocumented == 0,
    table.concat(undocumented, ", "))
check("names: the MEMO_ name, the config key, without MEMO_, any case",
    settings.get("MEMO_DEDUP_THRESHOLD") == settings.get("dedup_threshold")
    and settings.get("DEDUP_THRESHOLD") == settings.get("dedup_threshold")
    and settings.get("Dedup_Threshold") == settings.get("dedup_threshold") and settings.get("MEMO_NOPE") == nil)

local function P(name, text) return settings.parse(settings.get(name), text) end
check("booleans: 1 / true / yes / on and 0 / false / no / off", P("dedup_enabled", "1") == true
    and P("dedup_enabled", "on") == true and P("dedup_enabled", "0") == false and P("dedup_enabled", "OFF") == false)
local _, e1 = P("dedup_enabled", "maybe")
check("… anything else is refused", e1 and e1:find("true or false", 1, true) ~= nil, e1)
local _, e2 = P("dedup_threshold", "1.5")
check("a number out of range is refused, naming the range", e2 and e2:find("between 0 and 1", 1, true) ~= nil, e2)
local _, e3 = P("rerank_top_n", "2.5")
check("a whole-number setting refuses 2.5", e3 and e3:find("whole number", 1, true) ~= nil, e3)
local _, e4 = P("dedup_strategy", "merge")
check("a word outside the allowed ones is refused, listing them", e4 and e4:find("update | skip | append", 1, true) ~= nil, e4)
check("a list is split on commas", table.concat(P("org_propose_scopes", "repo:a, repo:b") or {}, "|") == "repo:a|repo:b")
local hw = P("hybrid_weights", '{"vector":0.5,"fts":0.5}')
check("a JSON object setting", hw and hw.vector == 0.5 and hw.fts == 0.5)
check("… an array, a wrong key, both weights 0 are refused", not P("hybrid_weights", "[1,2]")
    and not P("hybrid_weights", '{"vec":1}') and not P("hybrid_weights", '{"vector":0,"fts":0}'))
check("a header value with a line break, a bad header name are refused",
    not P("embedder_headers", '{"X-A":"a\\r\\nX-B: b"}') and not P("embedder_headers", '{"Bad Name":"x"}'))
check("a JSON value is written with its keys in order",
    settings.format(settings.get("hybrid_weights"), { vector = 0.7, fts = 0.3 }) == '{"fts":0.3,"vector":0.7}')
check("numbers are written plainly", settings.format(settings.get("dedup_threshold"), 0.9) == "0.9"
    and settings.format(settings.get("embed_dim"), 768) == "768")
local HE = settings.get("embedder_headers")
check("a plain-text credential in a header is found, and masked when shown",
    table.concat(settings.plain_credentials(HE, { Authorization = "Bearer sk-1", ["X-Trace"] = "abc" }), ",")
        == "Authorization" and settings.show(HE, { Authorization = "Bearer sk-1" }) == '{"Authorization":"****"}')
check("… a {secret:NAME} reference is shown as it is",
    settings.show(HE, { Authorization = "Bearer {secret:k}" }) == '{"Authorization":"Bearer {secret:k}"}'
    and #settings.plain_credentials(HE, { ["X-Api-Key"] = "{secret:k}" }) == 0)
check("the master key is never shown", settings.show(settings.get("master_key"), ("ab"):rep(32)) == "(set)")

local function env_of(t) return function(k) return t[k] end end
local c, probs = settings.from_env(env_of({ MEMO_AUTO_DIGEST = "1", MEMO_DEDUP_THRESHOLD = "x",
    MEMO_RERANK_TOP_N = "7" }))
check("an older name is still read (MEMO_AUTO_DIGEST)", c.auto_digest_enabled == true)
check("a value that doesn't parse is reported and ignored", c.dedup_threshold == nil and #probs == 1
    and probs[1]:find("ignored", 1, true) ~= nil, probs[1])
check("values arrive typed", c.rerank_top_n == 7)
check("the current name wins over an older one",
    settings.from_env(env_of({ MEMO_AUTO_DIGEST = "1", MEMO_AUTO_DIGEST_ENABLED = "false" })).auto_digest_enabled == false)
local _, p2, fatal = settings.from_env(env_of({ MEMO_EMBEDDER = "gguf_fii", MEMO_ORG_SHARE = "signal",
    MEMO_EMBED_DIM = "abc", MEMO_ROLE = "orgg" }))
check("a strict setting that doesn't parse is fatal (embedder, dimension, org share, role)", #fatal == 4 and #p2 == 0)

local u = settings.unknown({ "MEMO_DEDUP_TRESHOLD", "MEMO_DB_URL", "MEMO_PROJECT", "MEMO__ARGV", "MEMO_ZZZ",
    "MEMO_DB", "MEMO_GEMMA_NCTX" })
check("unknown names: a typo gets the closest setting", u[2] and u[2].name == "MEMO_DEDUP_TRESHOLD"
    and u[2].suggestion == "MEMO_DEDUP_THRESHOLD", json.encode(u))
check("… a retired name says what replaced it", u[1] and u[1].name == "MEMO_DB_URL"
    and settings.unknown_message(u[1]):find("SQLite file", 1, true) ~= nil)
check("… tools' variables, internals, settings and older names are not reported", #u == 3 and u[3].name == "MEMO_ZZZ"
    and u[3].suggestion == nil)

local rcf = BASE .. "-rc"
write(rcf, "# luamemo\nMEMO_A='it'\\''s'\nexport MEMO_B=\"$HOME/x\"\nMEMO_C=plain # note\nOTHER=1\n")
local r = settings.read_file(rcf)
check("a .luamemorc is read as the shell reads it (quotes, $HOME, comments)", r.MEMO_A == "it's"
    and r.MEMO_B == os.getenv("HOME") .. "/x" and r.MEMO_C == "plain" and r.OTHER == nil, json.encode(r))
os.remove(rcf)

local files = { project = { MEMO_DEDUP_THRESHOLD = "0.9" },
                user = { MEMO_RERANK_TOP_N = "7", MEMO_DEDUP_THRESHOLD = "0.8" } }
local cfg = settings.defaults()
cfg.dedup_threshold, cfg.rerank_top_n, cfg.obs_max_slots, cfg.embedder_local = 0.9, 7, 5, "hash"
local src = {}
for _, row in ipairs(settings.effective(cfg, files, function() return nil end)) do src[row.entry.env] = row.source end
check("sources: project / user / environment / default", src.MEMO_DEDUP_THRESHOLD == "project"
    and src.MEMO_RERANK_TOP_N == "user" and src.MEMO_OBS_MAX_SLOTS == "environment"
    and src.MEMO_PATTERNS_ENABLED == "default" and src.MEMO_EMBEDDER == "default", json.encode(src))
local function values(c0)
    local v = {}
    for _, row in ipairs(settings.effective(c0, {}, function() return nil end)) do v[row.entry.env] = row.value end
    return v
end
local hv, dv = values({ embedder_url = "http://x" }), values({ org_url = "http://c" })
check("a default that depends on another setting: MEMO_EMBEDDER (hash only without a URL), MEMO_ROLE",
    hv.MEMO_EMBEDDER == nil and values({}).MEMO_EMBEDDER == "hash" and hv.MEMO_ROLE == "solo"
    and dv.MEMO_ROLE == "dev")

-- load_files: what the MCP server does at startup.
local pdir = BASE .. "-lf"
os.execute(("mkdir -p %q"):format(pdir))
local user_rc = os.getenv("HOME") .. "/.luamemorc"
-- A project file nobody wrote with memo nor trusted (it came with a download) is not
-- read; nor, trusted, the settings that name code to load (USER_ONLY).
write(pdir .. "/.luamemorc", "MEMO_RERANK_TOP_N='9'\n")
local f0 = settings.files(pdir)
check("files: a project file memo didn't write (a download, a hand edit) isn't read until trusted",
    next(f0.project) == nil and tostring(f0.untrusted):find("didn't write", 1, true) ~= nil, tostring(f0.untrusted))
write(pdir .. "/.luamemorc", "MEMO_RERANK_TOP_N='9'\nMEMO_LUA='./evil.sh'\nMEMO_LIB_SQLITE3='./evil.so'\n")
H.trust_rc(pdir .. "/.luamemorc")
local f1 = settings.files(pdir)
check("files: even trusted, a project's file never names code to load (MEMO_LUA, MEMO_LIB_*, the shim)",
    f1.project.MEMO_RERANK_TOP_N == "9" and f1.project.MEMO_LUA == nil and f1.project.MEMO_LIB_SQLITE3 == nil
    and table.concat(f1.user_only or {}, ",") == "MEMO_LIB_SQLITE3,MEMO_LUA", table.concat(f1.user_only or {}, ","))
write(pdir .. "/.luamemorc", "MEMO_OBS_MAX_SLOTS='5'\nMEMO_RERANK_TOP_N='9'\n")
H.trust_rc(pdir .. "/.luamemorc")
write(user_rc, "MEMO_RERANK_TOP_N='4'\nMEMO_PATTERNS_MAX_BODY_CHARS='123'\n")
setenv("MEMO_OBS_MAX_SLOTS", "2")
local set = settings.load_files(pdir)
check("load_files: a variable already set wins", os.getenv("MEMO_OBS_MAX_SLOTS") == "2" and set.MEMO_OBS_MAX_SLOTS == nil)
check("… the project's file over the user's", os.getenv("MEMO_RERANK_TOP_N") == "9"
    and set.MEMO_RERANK_TOP_N == "project")
check("… the user's file fills in the rest", os.getenv("MEMO_PATTERNS_MAX_BODY_CHARS") == "123"
    and set.MEMO_PATTERNS_MAX_BODY_CHARS == "user")
local names = {}
for _, n in ipairs(settings.env_names()) do names[n] = true end
check("env_names lists the MEMO_ variables of this process", names.MEMO_RERANK_TOP_N and names.MEMO_OBS_MAX_SLOTS
    and not names.HOME)
for _, k in ipairs({ "MEMO_OBS_MAX_SLOTS", "MEMO_RERANK_TOP_N", "MEMO_PATTERNS_MAX_BODY_CHARS" }) do setenv(k, nil) end
os.remove(user_rc)
os.execute(("rm -rf %q"):format(pdir))
end)

-- ---------------------------------------------------------------------------
section("config_from_env", function()
io.write("\n--- config_from_env ---\n")
local common = require("luamemo.cli._common")
local function with(vars, fn)
    local old = {}
    for k, v in pairs(vars) do old[k] = os.getenv(k) or false; setenv(k, v) end
    local ok, res = pcall(fn)
    for k, v in pairs(old) do setenv(k, v) end
    if not ok then error(res, 0) end
    return res
end
local function cfg_with(vars) return with(vars, function() return common.config_from_env({ warn = false }) end) end
local c = cfg_with({ MEMO_EMBEDDER_URL = "http://127.0.0.1:9/v1/embeddings", MEMO_EMBEDDER = "gguf_ffi" })
check("an HTTP embedder wins over MEMO_EMBEDDER; its adapter defaults to generic", c.embedder_url ~= nil
    and c.embedder_local == nil and c.embedder_adapter == "generic")
local g = cfg_with({ MEMO_EMBEDDER_URL = false, MEMO_EMBEDDER = "gguf_ffi", MEMO_GGUF_MODEL = "/m/e.gguf",
    MEMO_EMBEDDER_MODEL = "other" })
check("gguf_ffi takes its model file from MEMO_GGUF_MODEL, not MEMO_EMBEDDER_MODEL",
    g.embedder_local == "gguf_ffi" and g.embedder_model == "/m/e.gguf")
check("no embedder named: hash", cfg_with({ MEMO_EMBEDDER = false, MEMO_EMBEDDER_URL = false }).embedder_local == "hash")
local lm = require("luamemo")
local ok1, err1 = pcall(lm.setup, cfg_with({ MEMO_EMBEDDER = "gguf_fii" }))
check("a mistyped embedder stops setup, naming the setting (no fallback to hash)", not ok1
    and tostring(err1):find("MEMO_EMBEDDER must be one of", 1, true) ~= nil, err1)
local ok2, err2 = pcall(lm.setup, cfg_with({ MEMO_ORG_SHARE = "signal" }))
check("MEMO_ORG_SHARE=signal stops setup (never falls back to sending query text)", not ok2
    and tostring(err2):find("MEMO_ORG_SHARE", 1, true) ~= nil, err2)
local code = "package.path='./?.lua;./?/init.lua;'..package.path; local c = require('luamemo.cli._common'); "
    .. "c.config_from_env({}); c.config_from_env({})"
local out = sh(("MEMO_DEDUP_TRESHOLD=1 MEMO_DEDUP_THRESHOLD=x %s -e %q"):format(LUA, code))
check("an unknown name and a bad value are warned about once per process",
    select(2, out:gsub("did you mean MEMO_DEDUP_THRESHOLD", "")) == 1
    and select(2, out:gsub("must be a number", "")) == 1, out)
local quiet = sh(("MEMO__SETTINGS_CHECKED=1 MEMO_DEDUP_TRESHOLD=1 %s -e %q"):format(LUA, code))
check("… and not at all once memo checked them (calibrate)", quiet == "", quiet)
end)

-- ---------------------------------------------------------------------------
-- A `memo` with its own HOME / data / project (no settings of the runner's).
local memo_env = H.memo_env

section("memo config", function()
io.write("\n--- memo config ---\n")
local home, proj = BASE .. "-home", BASE .. "-proj"
os.execute(("mkdir -p %q %q && git -C %q init -q"):format(home, proj, proj))
local ENV = memo_env(home, proj)
local function memo(args) return sh(("cd %q && %s %q %s </dev/null"):format(proj, ENV, REPO .. "/cli/memo", args)) end
local function rc(key) return H.rc_get(slurp(proj .. "/.luamemorc"), key) end
local out, code = memo("config set dedup_threshold 0.9")
check("set: written to the project's .luamemorc, 0600", code == 0 and rc("MEMO_DEDUP_THRESHOLD") == "0.9"
    and H.mode(proj .. "/.luamemorc") == "600", out)
check("… which is kept out of git", (slurp(proj .. "/.gitignore") or ""):find(".luamemorc", 1, true) ~= nil)
check("get: the value in force", (memo("config get MEMO_DEDUP_THRESHOLD")) == "0.9")
local o2, c2 = memo("config set MEMO_DEDUP_THRESHOLD 1.5")
check("a value out of range is refused (exit 1), the file unchanged", c2 == 1
    and o2:find("between 0 and 1", 1, true) ~= nil and rc("MEMO_DEDUP_THRESHOLD") == "0.9", o2)
local o3, c3 = memo("config set MEMO_DEDUP_TRESHOLD 0.9")
check("a mistyped name is refused, naming the closest setting", c3 == 1
    and o3:find("did you mean MEMO_DEDUP_THRESHOLD", 1, true) ~= nil, o3)
local o4, c4 = memo([[config set MEMO_EMBEDDER_HEADERS '{"Authorization":"Bearer sk-live-123"}']])
check("a plain-text credential in a header is refused — with the vault recipe", c4 == 1
    and o4:find("memo secret-store", 1, true) ~= nil
    and not (slurp(proj .. "/.luamemorc") or ""):find("sk-live-123", 1, true), o4)
local o5, c5 = memo("config set MEMO_MASTER_KEY " .. ("ab"):rep(32))
check("the master key is never written", c5 == 1 and not (slurp(proj .. "/.luamemorc") or ""):find("abab", 1, true), o5)
local o6 = memo("config set MEMO_EMBED_DIM 768")
check("an embedding change says to re-embed, and that a running MCP server takes it on restart "
    .. "(memo mcp reads .luamemorc: no client config to re-write)",
    o6:find("memo reembed --all", 1, true) ~= nil and o6:find("picks this up when it restarts", 1, true) ~= nil
    and not o6:find("memo calibrate", 1, true), o6)
memo("config unset MEMO_EMBED_DIM")
local f = assert(io.open(proj .. "/.luamemorc", "a")); f:write("MEMO_AUTO_DIGEST='1'\n"); f:close()
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- edited by hand: trusted again
memo("config set MEMO_AUTO_DIGEST_ENABLED false")
local text = slurp(proj .. "/.luamemorc") or ""
check("set replaces a setting's older name in the file", not text:find("MEMO_AUTO_DIGEST=", 1, true)
    and rc("MEMO_AUTO_DIGEST_ENABLED") == "false", text)
local o7 = memo("config set MEMO_RERANK_TOP_N 7 --user")
check("--user writes ~/.luamemorc (0600)", H.rc_get(slurp(home .. "/.luamemorc"), "MEMO_RERANK_TOP_N") == "7"
    and H.mode(home .. "/.luamemorc") == "600", o7)
memo("config set MEMO_DEDUP_THRESHOLD 0.8 --user")
check("memo reads ~/.luamemorc, and the project's file wins over it",
    (memo("config get rerank_top_n")) == "7" and (memo("config get dedup_threshold")) == "0.9")
local list = json.decode((memo("config list --json"))) or {}
local by = {}
for _, s in ipairs(list.settings or {}) do by[s.name] = s end
check("list --json: every setting, its value and its source", #(list.settings or {}) == #settings.LIST
    and (by.MEMO_DEDUP_THRESHOLD or {}).source == "project" and (by.MEMO_RERANK_TOP_N or {}).source == "user"
    and (by.MEMO_DEDUP_STRATEGY or {}).source == "default" and (by.MEMO_DEDUP_STRATEGY or {}).value == "update")
local o8 = memo("config unset dedup_threshold")
check("unset: gone from the project's file — the user's value applies", o8:find("~/.luamemorc sets 0.8", 1, true) ~= nil
    and (memo("config get dedup_threshold")) == "0.8", o8)
local o9, c9 = sh(("cd %q && MEMO_DEDUP_TRESHOLD=1 %s %q config check"):format(proj, ENV, REPO .. "/cli/memo"))
check("check: names a variable luamemo doesn't read (exit 1)", c9 == 1
    and o9:find("did you mean MEMO_DEDUP_THRESHOLD", 1, true) ~= nil, o9)
local _, c10 = memo("config check")
check("check: exit 0 when every setting is fine", c10 == 0)
local omd, cmd_ = sh(("cd %q && %s %q config list --markdown </dev/null"):format(proj, ENV, REPO .. "/cli/memo"))
check("list --markdown prints the reference (the same text SETTINGS.md holds)", cmd_ == 0
    and omd == require("luamemo.cli.config").markdown():gsub("\n$", ""), omd:sub(1, 200))
os.execute(("rm -rf %q %q"):format(home, proj))
end)

-- ---------------------------------------------------------------------------
section("settings files are data; a committed one needs trust", function()
io.write("\n--- .luamemorc: data, and trust ---\n")
local home, proj = BASE .. "-thome", BASE .. "-tproj"
os.execute(("mkdir -p %q %q"):format(home, proj))
local ENV = memo_env(home, proj)
local function memo(args) return sh(("cd %q && %s %q %s </dev/null"):format(proj, ENV, REPO .. "/cli/memo", args)) end
local mark = BASE .. "-ran"
write(proj .. "/.luamemorc", ("MEMO_SCOPE=x$(touch %s)\nMEMO_DEFAULT_SCOPE='it'\\''s'\n"
    .. "MEMO_OBS_MAX_SLOTS=4 # four\nexport MEMO_DB_LABEL_UNUSED=1\nMEMO_FEDERATION_DIR=\"$HOME/kr\"\n"):format(mark))
local ignored = memo("config get MEMO_OBS_MAX_SLOTS")
check("a project file memo didn't write (a download, a hand edit) is ignored until trusted — memo says why",
    ignored:find("didn't write it", 1, true) ~= nil and ignored:find("memo config trust", 1, true) ~= nil, ignored)
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")
local out = memo("config get MEMO_SCOPE")
check("memo reads .luamemorc as data: nothing in it runs", slurp(mark) == nil and out:find("$(touch", 1, true) ~= nil, out)
local raw = settings.read_file(proj .. "/.luamemorc")
check("… the same values as luamemo.settings reads (quotes, comments, $HOME)",
    (memo("config get MEMO_DEFAULT_SCOPE")) == raw.MEMO_DEFAULT_SCOPE and raw.MEMO_DEFAULT_SCOPE == "it's"
    and (memo("config get MEMO_OBS_MAX_SLOTS")) == "4" and (memo("config get MEMO_FEDERATION_DIR")) == home .. "/kr")
-- A .luamemorc committed to git: it came with the repository.
write(proj .. "/.luamemorc", "MEMO_RERANK_TOP_N='9'\n")
os.execute(("cd %q && git init -q && git -c user.email=t@t -c user.name=t add .luamemorc "
    .. "&& git -c user.email=t@t -c user.name=t commit -qm rc"):format(proj))
local function last(s) return (s:match("([^\n]*)$")) end
local ig = memo("config get rerank_top_n")
check("a committed .luamemorc is not used — memo says why and what to do", last(ig) == "20"
    and ig:find("memo config trust", 1, true) ~= nil, ig)
local mcp = H.mcp(("env -u MEMO_EMBEDDER HOME=%q XDG_CONFIG_HOME=%q MEMO_PROJECT=%q MEMO_DB=%q")
    :format(home, home .. "/.config", proj, home .. "/t.db"), { { "memory_status", { details = true } } })
local top
for _, s in ipairs((mcp[1] or {}).settings or {}) do if s.name == "MEMO_RERANK_TOP_N" then top = s.value end end
check("… nor by the MCP server", top == "20", tostring(top))
local refused, rc = memo("config set MEMO_DEDUP_THRESHOLD 0.9")
check("… memo config won't rewrite it (that would vouch for the rest of it)", rc ~= 0
    and refused:find("memo config trust", 1, true) ~= nil and not slurp(proj .. "/.luamemorc"):find("DEDUP", 1, true),
    refused)
local cal, cc = sh(("cd %q && %s %q calibrate --no-mcp --no-plugin --no-git --no-comments --allow-hash </dev/null")
    :format(proj, ENV, REPO .. "/cli/memo"))
check("… nor will calibrate build on it", cc ~= 0 and cal:find("memo config trust", 1, true) ~= nil, cal:sub(1, 600))
local t = memo("config trust")
check("memo config trust: shows what it trusts, then memo uses it", t:find("MEMO_RERANK_TOP_N=9", 1, true) ~= nil
    and (memo("config get rerank_top_n")) == "9", t)
local s2 = memo("config set MEMO_DEDUP_THRESHOLD 0.85")
check("memo's own changes keep it trusted", (memo("config get dedup_threshold")) == "0.85"
    and (memo("config get rerank_top_n")) == "9", s2)
write(proj .. "/.luamemorc", "MEMO_RERANK_TOP_N='3'\n")   -- as a git pull would change it
check("a changed file needs trusting again", last((memo("config get rerank_top_n"))) == "20")
os.execute(("rm -rf %q %q %q"):format(home, proj, mark))
end)

-- ---------------------------------------------------------------------------
-- A mock HTTP embedder (OpenAI-compatible) that wants `Authorization: Bearer WANT_KEY`:
-- 8-dim vectors for the right key; 401 echoing the header it got otherwise.
local MOCK = [[
local socket = require("socket")
local json = require("luamemo.json")
local srv = assert(socket.bind("127.0.0.1", 0))
local _, port = srv:getsockname()
local f = assert(io.open(os.getenv("PORTFILE"), "w")); f:write(port); f:close()
local want = "Bearer " .. os.getenv("WANT_KEY")
local log = assert(io.open(os.getenv("MOCKLOG"), "a"))
srv:settimeout(300)
while true do
    local c = srv:accept()
    if not c then break end
    c:settimeout(5)
    local line = c:receive("*l") or ""
    local len, auth = 0, nil
    while true do
        local h = c:receive("*l")
        if not h or h == "" then break end
        local n = h:lower():match("^content%-length:%s*(%d+)")
        if n then len = tonumber(n) end
        auth = h:match("^[Aa]uthorization:%s*(.-)%s*$") or auth
    end
    local body = len > 0 and c:receive(len) or ""
    if line:find("/stop", 1, true) then
        c:send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); c:close(); break
    end
    log:write(tostring(auth), "\n"); log:flush()
    local status, out
    if auth == want then
        local text = tostring((json.decode(body) or {}).input or "")
        local v = {}
        for i = 1, 8 do v[i] = ((#text * 31 + i * 17 + (text:byte(i) or 0)) % 97) / 97 + 0.01 end
        status, out = "200 OK", json.encode({ data = { { embedding = v } } })
    else
        status, out = "401 Unauthorized", json.encode({ error = "invalid api key: " .. tostring(auth) })
    end
    c:send(("HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s")
        :format(status, #out, out))
    c:close()
end
]]

section("credentials in headers come from the vault", function()
io.write("\n--- {secret:NAME} in headers ---\n")
local secrets = require("luamemo.secrets")
local lm = require("luamemo")
lm.setup({ db = H.create_db("hdrs"), embedder_local = "hash", embed_dim = 384, skip_embed_probe = true,
    master_key = ("cd"):rep(32) })
assert(secrets.store("emb", "sk-test-XYZ\n"))
local plain = { ["X-Trace"] = "1" }
check("headers without a reference come back as they are", secrets.resolve_headers(plain) == plain)
local r = secrets.resolve_headers({ Authorization = "Bearer {secret:emb}", ["X-Trace"] = "1" })
check("{secret:NAME} is replaced by the secret (a stored trailing newline dropped)",
    r and r.Authorization == "Bearer sk-test-XYZ" and r["X-Trace"] == "1")
check("scrub masks the value in a message", secrets.scrub("401: invalid key Bearer sk-test-XYZ", r)
    == "401: invalid key Bearer ***")
local _, e1 = secrets.resolve_headers({ Authorization = "Bearer {secret:nope}" })
check("a missing secret is an error naming it and how to store it", e1 and e1:find("no secret named nope", 1, true)
    and e1:find("memo secret-store nope", 1, true) ~= nil, e1)
require("luamemo.db").run("INSERT INTO lm_secrets (name, value, internal, created_at, updated_at) "
    .. "VALUES (?, 'x1:00', 1, 0, 0)", "luamemo.k")
local _, e2 = secrets.resolve_headers({ Authorization = "{secret:luamemo.k}" })
check("an internal secret is refused", e2 and e2:find("internal secret", 1, true) ~= nil, e2)
secrets.configure({})
local _, e3 = secrets.resolve_headers({ Authorization = "{secret:emb}" })
check("no vault key: a clear error", e3 and e3:find("memo secret-store", 1, true) ~= nil, e3)
H.drop_dbs()

-- End to end: a project whose HTTP embedder wants a key.
local home, proj = BASE .. "-vhome", BASE .. "-vproj"
os.execute(("mkdir -p %q %q"):format(home, proj))
local KEY = ("sk-live-%d%04d"):format(os.time(), math.random(0, 9999))
local portfile, logf = BASE .. "-port", BASE .. "-mock.log"
os.execute(("cd %q && PORTFILE=%q WANT_KEY=%q MOCKLOG=%q %s -e %q >/dev/null 2>&1 &"):format(REPO, portfile, KEY,
    logf, LUA, "package.path='./?.lua;./?/init.lua;'..package.path " .. MOCK))
local port
for _ = 1, 100 do
    port = tonumber(slurp(portfile) or "")
    if port then break end
    os.execute("sleep 0.1")
end
check("the mock embedder is up", port ~= nil)
if not port then return end
local dbp = home .. "/emb.db"
write(proj .. "/.luamemorc", ("MEMO_DB=%s\nMEMO_EMBEDDER_URL='http://127.0.0.1:%d/v1/embeddings'\n"
    .. "MEMO_EMBEDDER_ADAPTER='openai_compatible'\nMEMO_EMBED_DIM='8'\nMEMO_SCOPE='repo:vault'\n"):format(q(dbp), port))
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- written by hand: trusted
local ENV = memo_env(home, proj)
local function memo(args) return sh(("cd %q && %s %q %s </dev/null"):format(proj, ENV, REPO .. "/cli/memo", args)) end
local function memo_json(args) return json.decode((memo(args .. " 2>/dev/null"))) or {} end
local MENV = ("env -u MEMO_DB -u MEMO_EMBEDDER HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q MEMO_PROJECT=%q")
    :format(home, home .. "/.config", home .. "/.local/share", proj)
local keyfile, badfile = home .. "/key", home .. "/bad"
write(keyfile, KEY .. "\n"); write(badfile, "sk-wrong-777\n")
local o1 = memo([[config set MEMO_EMBEDDER_HEADERS '{"Authorization":"Bearer {secret:emb}"}']])
check("the header refers to the vault", H.rc_get(slurp(proj .. "/.luamemorc"), "MEMO_EMBEDDER_HEADERS")
    == '{"Authorization":"Bearer {secret:emb}"}', o1)
local before = H.mcp(MENV, { { "secret_store", { name = "x", value = "y" } } })
check("MCP secret_store doesn't set the vault up — a person does, with memo secret-store",
    ((before[1] or {}).error or ""):find("memo secret-store", 1, true) ~= nil, json.encode(before[1]))
local vk = home .. "/.config/luamemo/vault.key"
local o2 = memo("secret-store emb --file " .. q(keyfile))
check("the first memo secret-store creates the vault key (0600, its directory 0700) and says so",
    H.mode(vk) == "600" and H.mode(home .. "/.config/luamemo") == "700"
    and o2:find("created the vault key", 1, true) ~= nil, o2)
check("memo secret-store without --desc stores it (a JSON null description binds as NULL)",
    o2:find('"ok": true', 1, true) ~= nil, o2)
local sl = json.decode((memo("secret-list 2>/dev/null"))) or {}
check("memo secret-list names it (never its value)", (sl[1] or {}).name == "emb"
    and not json.encode(sl):find(KEY, 1, true), json.encode(sl))
local w = memo_json("write --scope repo:vault --kind fact --title t1 --body " .. q("alpha beta gamma"))
check("a write embeds through the mock — the request carried the vault's key", (w.memory or {}).id ~= nil
    and (slurp(logf) or ""):find("Bearer " .. KEY, 1, true) ~= nil, json.encode(w))
local po = memo("ping --embedder")
check("memo ping --embedder uses the same headers", po:find("PASS", 1, true) ~= nil, po)
memo("secret-store emb --file " .. q(badfile))
local bad = memo("write --scope repo:vault --kind fact --title t2 --body " .. q("delta epsilon"))
check("a refused request's error masks the key the server echoed", bad:find("HTTP 401", 1, true) ~= nil
    and bad:find("***", 1, true) ~= nil and not bad:find("sk-wrong-777", 1, true), bad)
memo("secret-store emb --file " .. q(keyfile))
local listing = memo("config list") .. (slurp(proj .. "/.luamemorc") or "")
check("the key is in no file and no listing", not listing:find(KEY, 1, true)
    and listing:find("{secret:emb}", 1, true) ~= nil)

-- The MCP server: settings from the project's .luamemorc (no MEMO_ variables passed).
local res, stderr = H.mcp(MENV, {
    { "memory_write", { title = "via mcp", body = "zeta eta theta", kind = "fact" } },
    { "memory_status", { details = true } },
    { "secret_store", { name = "x", value = "y" } },
})
check("MCP: a write through the server embeds with the project's settings and the vault's key",
    (res[1] or {}).ok == true and ((res[1] or {}).memory or {}).scope == "repo:vault", json.encode(res[1]) .. stderr)
local st = {}
for _, s in ipairs((res[2] or {}).settings or {}) do st[s.name] = s end
check("MCP memory_status {details}: every setting, with its source", #((res[2] or {}).settings or {}) == #settings.LIST
    and (st.MEMO_EMBEDDER_URL or {}).source == "project" and (st.MEMO_DB or {}).source == "project"
    and (st.MEMO_DEDUP_STRATEGY or {}).source == "default", json.encode(st.MEMO_EMBEDDER_URL))
check("… credentials as their {secret:…} reference", ((st.MEMO_EMBEDDER_HEADERS or {}).value or ""):find("{secret:emb}", 1,
    true) ~= nil and not json.encode(res[2] or {}):find(KEY, 1, true))
check("… read-only: the note says people change them with memo config", ((res[2] or {}).settings_note or "")
    :find("memo config set", 1, true) ~= nil)
check("MCP secret_store works once the vault key exists (found in its default place)", (res[3] or {}).ok == true,
    json.encode(res[3]))
local env_res = H.mcp(MENV .. " MEMO_DEDUP_THRESHOLD=0.7", { { "memory_status", { details = true } } })
local st2 = {}
for _, s in ipairs((env_res[1] or {}).settings or {}) do st2[s.name] = s end
write(proj .. "/.luamemorc", (slurp(proj .. "/.luamemorc") or "") .. "MEMO_DEDUP_THRESHOLD='0.9'\n")
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- edited by hand: trusted again
local env_res2 = H.mcp(MENV .. " MEMO_DEDUP_THRESHOLD=0.7", { { "memory_status", { details = true } } })
local st3 = {}
for _, s in ipairs((env_res2[1] or {}).settings or {}) do st3[s.name] = s end
check("the client's environment wins over the project's file", (st2.MEMO_DEDUP_THRESHOLD or {}).value == "0.7"
    and (st3.MEMO_DEDUP_THRESHOLD or {}).value == "0.7" and (st3.MEMO_DEDUP_THRESHOLD or {}).source == "environment")

-- calibrate: an HTTP embedder that refuses (no key configured) → how to give it one.
local text = (slurp(proj .. "/.luamemorc") or ""):gsub("MEMO_EMBEDDER_HEADERS=[^\n]*\n", "")
write(proj .. "/.luamemorc", text)
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- edited by hand: trusted again
local co = sh(("cd %q && %s %q calibrate --keep-embedder --no-mcp --no-plugin --no-git --no-comments --allow-hash "
    .. "</dev/null"):format(proj, ENV, REPO .. "/cli/memo"))
check("calibrate: a 401 from the embedder → store the key in the vault, refer to it in the header",
    co:find("refused the request (HTTP 401)", 1, true) ~= nil
    and co:find("memo secret-store embedder-api-key", 1, true) ~= nil
    and co:find("{secret:embedder-api-key}", 1, true) ~= nil, co:sub(1, 3000))
pcall(require("luamemo.http").request, ("http://127.0.0.1:%d/stop"):format(port), { timeout_ms = 2000 })
os.execute(("rm -rf %q %q %q %q %q"):format(home, proj, portfile, logf, BASE .. "-stop"))
end)

-- ---------------------------------------------------------------------------
section("settings that never reached their module", function()
io.write("\n--- settings that never reached their module ---\n")
local lm = require("luamemo")
local util = require("luamemo.util")
lm.setup({ db = H.create_db("fixes"), embedder_local = "hash", embed_dim = 384, skip_embed_probe = true,
    consolidate_threshold = 0.5, rerank_adapter = "learned", rerank_epsilon = 0.3 })
lm.write({ scope = "s", kind = "note", title = "a", body = "alpha beta", tier = 0 })
local seen
local orig = util.cluster
util.cluster = function(_, t) seen = t; return {} end
local ok = pcall(require("luamemo.digest").run, "s", {})
util.cluster = orig
check("digest clusters at MEMO_CONSOLIDATE_THRESHOLD (was always 0.80)", ok and seen == 0.5, seen)
local learned = require("luamemo.rerankers.learned")
local got
local orig_r = learned.rerank
learned.rerank = function(qy, hits, view) got = view.rerank_epsilon; return orig_r(qy, hits, view) end
require("luamemo.rerank").rerank("alpha", { { id = 1, title = "a", body = "alpha", score = 1 } }, {})
learned.rerank = orig_r
check("the learned reranker gets MEMO_RERANK_EPSILON (was always 0)", got == 0.3, got)
H.drop_dbs()
end)

finish()
