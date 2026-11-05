-- eval/tests/test_eval_cli.lua
-- `memo eval` (luamemo/cli/eval.lua): the kit's file list and dataset list are whole;
-- status / install --from through memo; the release path (download, checksum, unpack)
-- against a file:// asset, a tampered one refused; fetch (checksums, --yes, already
-- there); a quick-tier run on a scratch database — the project's database untouched, its
-- MEMO_* settings kept out of the runners — its summary, report and baseline flags; the
-- release scripts (eval_kit.sh, write_evalkit.lua).
-- Run: luajit eval/tests/run.lua --only eval_cli

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("memo eval")
local check, section, finish = T.check, T.section, T.finish

local json = require("luamemo.json")
local ev = require("luamemo.cli.eval")
local util = require("luamemo.util")
local VERSION = require("luamemo").VERSION

local tmp = (H.sh("mktemp -d " .. ((os.getenv("MEMO_TEST_TMP") or "") ~= "" and os.getenv("MEMO_TEST_TMP")
    or "/tmp") .. "/evalcli.XXXXXX"))
local repo = (H.sh("pwd"))
local function q(s) return util.shell_quote(s) end
local function write(path, text)
    os.execute("mkdir -p " .. q(path:match("^(.*)/[^/]+$")))
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end
local function sha(path) return ((H.sh("sha256sum " .. q(path) .. " 2>/dev/null || shasum -a 256 " .. q(path)))
    :match("^(%x+)") or ""):lower() end

section("the kit's lists", function()
    io.write("\n--- the kit's lists ---\n")
    local missing = {}
    for _, f in ipairs(ev.KIT_FILES) do if not util.exists(f) then missing[#missing + 1] = f end end
    check(("every kit file is in the checkout (%d)"):format(#ev.KIT_FILES), #missing == 0, table.concat(missing, ", "))
    local d = json.decode(H.slurp("eval/datasets.json") or "")
    local bad = {}
    for name, b in pairs(ev.BENCHES) do
        if b.dataset and not (d and d.datasets[b.dataset]) then bad[#bad + 1] = name end
    end
    check("every benchmark's dataset is in eval/datasets.json", d and #bad == 0, table.concat(bad, ", "))
    local shape = {}
    for name, ds in pairs(d and d.datasets or {}) do
        for _, f in ipairs(ds.files or {}) do
            if not (f.url:match("^https://") and #f.sha256 == 64 and f.sha256:match("^%x+$")
                and tonumber(f.bytes) and f.bytes > 0 and not f.path:find("..", 1, true)) then
                shape[#shape + 1] = name .. ":" .. tostring(f.path)
            end
        end
        if not (ds.source and ds.tier and #(ds.files or {}) > 0) then shape[#shape + 1] = name end
    end
    check("every dataset file: an https URL, a SHA-256, its size, a path inside the data dir", #shape == 0,
        table.concat(shape, ", "))
    local b = json.decode(H.slurp("eval/baselines.json") or "")
    check("eval/baselines.json: results by benchmark", type(b) == "table" and type(b.results) == "table")
    local tiers_ok = true
    for _, list in pairs(ev.TIERS) do for _, n in ipairs(list) do tiers_ok = tiers_ok and ev.BENCHES[n] ~= nil end end
    local no_download = #ev.TIERS.quick > 0
    for _, n in ipairs(ev.TIERS.quick) do no_download = no_download and ev.BENCHES[n].dataset == nil end
    check("the tiers name known benchmarks; quick needs no download", tiers_ok and no_download)
end)

section("the memo-run-eval skill names what memo eval has", function()
    io.write("\n--- the skill ---\n")
    local skill = H.slurp("skills/memo-run-eval/SKILL.md") or ""
    check("the skill exists, named memo-run-eval", skill:match("^%-%-%-\nname: memo%-run%-eval\n") ~= nil)
    local usage = H.slurp("luamemo/cli/eval.lua"):match("local USAGE = %[=%[(.-)%]=%]") or ""
    local bad = {}
    for sub, rest in skill:gmatch("memo eval (%l+)([^\n`]*)") do
        if not usage:find("memo eval " .. sub, 1, true) then bad[#bad + 1] = sub end
        for flag in rest:gmatch("%-%-[%l%-]+") do
            if not usage:find(flag, 1, true) then bad[#bad + 1] = sub .. " " .. flag end
        end
    end
    check("every memo eval command and flag the skill names exists", #bad == 0, table.concat(bad, ", "))
    local tiers_named = 0
    for t in pairs(ev.TIERS) do if skill:find("`" .. t .. "`", 1, true) then tiers_named = tiers_named + 1 end end
    check("the skill describes every tier", tiers_named == 3)
    local agent = H.slurp("agents/luamemo.agent.md") or ""
    check("the luamemo agent points to it", agent:find("memo-run-eval", 1, true) ~= nil)
end)

-- `memo` with its own HOME / data dir; MEMO_DB names a file that must never appear.
local home, proj = tmp .. "/home", tmp .. "/proj"
os.execute("mkdir -p " .. q(home) .. " " .. q(proj))
local user_db = tmp .. "/the-users.db"
local env = H.memo_env(home, proj) .. " MEMO_DB=" .. q(user_db)
local function memo(args) return H.memo_in(env, proj, args) end
local kit_dir = home .. "/.local/share/luamemo/eval-kit/" .. VERSION

section("status, install --from", function()
    io.write("\n--- status, install --from ---\n")
    local out, code = memo("eval status --json")
    local st = json.decode(out:match("{.*}") or "")
    check("status --json: this luamemo, no kit yet", code == 0 and st and st.luamemo == VERSION
        and st.kit.installed == false, out)
    check("… a checkout ships no kit checksum (release_asset false)", st and st.kit.release_asset == false)
    out, code = memo("eval run --embedder hash")
    check("run without a kit: exit 1, says to install it", code == 1 and out:find("memo eval install", 1, true), out)

    out, code = memo("eval install --from " .. q(repo))
    check("install --from the checkout", code == 0 and out:find("installed", 1, true), out)
    local kit = json.decode(H.slurp(kit_dir .. "/kit.json") or "")
    check("kit.json: version, source checkout, from", kit and kit.version == VERSION and kit.source == "checkout"
        and kit.from == util.real_dir(repo), H.slurp(kit_dir .. "/kit.json"))
    check("the kit's files are the checkout's", H.slurp(kit_dir .. "/eval/metrics.lua") == H.slurp("eval/metrics.lua")
        and H.slurp(kit_dir .. "/eval/datasets.json") == H.slurp("eval/datasets.json"))
    check("nothing else copied (no tests, no data)", not util.exists(kit_dir .. "/eval/tests/run.lua")
        and not util.is_dir(kit_dir .. "/eval/data"))
    out = memo("eval status --json")
    st = json.decode(out:match("{.*}") or "")
    check("status: kit installed; quick ready; standard needs its three datasets", st and st.kit.installed
        and st.tiers.quick.ready and not st.tiers.standard.ready and #st.tiers.standard.missing == 3, out)
    out = memo("eval status")
    check("status (text): the fetch command and size of a missing dataset",
        out:find("memo eval fetch locomo (2.7 MB)", 1, true), out)

    local fake = tmp .. "/other-checkout"
    write(fake .. "/luamemo/init.lua", 'local M = {}\nM.VERSION = "9.9.9"\nreturn M\n')
    out, code = memo("eval install --from " .. q(fake))
    check("install --from a checkout of another version: refused", code == 1
        and out:find("that checkout is luamemo 9.9.9", 1, true), out)
    check("… the installed kit is left as it was", util.exists(kit_dir .. "/kit.json"))
    out, code = memo("eval install --from " .. q(tmp .. "/nope"))
    check("install --from a missing directory: refused", code == 1, out)
    check("the user's database was never created", not util.exists(user_db))
end)

section("install from a release asset (file://)", function()
    io.write("\n--- install from a release asset ---\n")
    if (H.sh("command -v curl")) == "" then T.pass("SKIP: no curl"); return end
    local rel = tmp .. "/releases/download/v" .. VERSION
    local out, code = H.sh(("bash eval/release/eval_kit.sh %s %s"):format(q(VERSION), q(rel)))
    local asset = "luamemo-evalkit-" .. VERSION .. ".tar.gz"
    check("eval_kit.sh builds the kit and its checksum", code == 0 and util.exists(rel .. "/" .. asset)
        and util.exists(rel .. "/" .. asset .. ".sha256"), out)
    local listing = H.sh("tar -tzf " .. q(rel .. "/" .. asset))
    local files = 0
    for line in listing:gmatch("[^\n]+") do if not line:match("/$") then files = files + 1 end end
    check("… exactly the kit's files, under luamemo-evalkit-<version>/", files == #ev.KIT_FILES
        and listing:find("luamemo-evalkit-" .. VERSION .. "/eval/metrics.lua", 1, true), listing)
    local sum = (H.slurp(rel .. "/" .. asset .. ".sha256") or ""):match("^(%x+)")
    check("… the .sha256 is the archive's", sum == sha(rel .. "/" .. asset))

    local lua_out = tmp .. "/evalkit.lua"
    out, code = H.sh(("%s eval/release/write_evalkit.lua %s %s %s"):format(q(H.lua_bin()), q(VERSION), q(rel),
        q(lua_out)))
    local entry = code == 0 and dofile(lua_out)
    check("write_evalkit.lua: version, sha256, asset (written where told, not the checkout's)",
        entry and entry.version == VERSION and entry.sha256 == sum and entry.asset == asset
        and H.slurp("luamemo/evalkit.lua"):find("return {}", 1, true), out)
    out, code = H.sh(("%s eval/release/write_evalkit.lua %s %s %s"):format(q(H.lua_bin()), q("9.9.9"), q(rel),
        q(tmp .. "/x.lua")))
    check("write_evalkit.lua: no checksum for that version — exit 1", code == 1, out)

    -- In process: the rock's checksum, the release URL at the file:// directory.
    package.loaded["luamemo.evalkit"] = entry
    local saved = ev.REPO_URL
    ev.REPO_URL = "file://" .. tmp
    local dir, why = ev.install_release(VERSION)
    check("install: downloaded, checked, unpacked", dir == ev.kit_dir(VERSION) and util.exists(dir .. "/eval/metrics.lua"),
        tostring(why))
    local kit = ev.kit(VERSION)
    check("… kit.json: source release, the checksum", kit and kit.source == "release" and kit.sha256 == sum)
    check("… no download or staging directory left", (H.sh("ls -A " .. q(ev.kit_dir(VERSION):match("^(.*)/[^/]+$")))) == VERSION)

    package.loaded["luamemo.evalkit"] = { version = VERSION, sha256 = ("0"):rep(64), asset = asset }
    dir, why = ev.install_release(VERSION)
    check("a download that doesn't match the rock's checksum: refused", dir == nil
        and tostring(why):find("doesn't match", 1, true), tostring(why))
    check("… the installed kit stays, nothing left behind", ev.kit(VERSION) ~= nil
        and (H.sh("ls -A " .. q(ev.kit_dir(VERSION):match("^(.*)/[^/]+$")))) == VERSION)
    package.loaded["luamemo.evalkit"] = { version = "9.9.9", sha256 = sum, asset = asset }
    dir, why = ev.install_release(VERSION)
    check("a checksum for another version is not used", dir == nil and tostring(why):find("ships no eval kit", 1, true),
        tostring(why))
    ev.REPO_URL = saved
    package.loaded["luamemo.evalkit"] = nil
end)

section("fetch", function()
    io.write("\n--- fetch ---\n")
    if (H.sh("command -v curl")) == "" then T.pass("SKIP: no curl"); return end
    local src = tmp .. "/upstream/tiny.json"
    write(src, '{"tiny": true}\n')
    local kit = { dir = tmp .. "/fakekit" }
    write(kit.dir .. "/eval/datasets.json", json.encode({ datasets = {
        tiny = { title = "tiny", source = "here", tier = "standard",
                 files = { { path = "sub/tiny.json", bytes = 15, url = "file://" .. src, sha256 = sha(src) } } },
        changed = { title = "changed", source = "here", tier = "full",
                    files = { { path = "changed.json", bytes = 15, url = "file://" .. src, sha256 = ("a"):rep(64) } } },
    } }))
    local data, lines = tmp .. "/data", {}
    local say = function(l) lines[#lines + 1] = l end
    local ok, why = ev.fetch(kit, { "tiny" }, { data = data, say = say })
    check("fetch: the file, checked, at its path", ok and H.slurp(data .. "/sub/tiny.json") == '{"tiny": true}\n',
        tostring(why))
    check("… says what it downloads, from where, and that the dataset's license applies",
        table.concat(lines, "\n"):find("from here (the dataset's own license applies)", 1, true), table.concat(lines, "\n"))
    lines = {}
    ok = ev.fetch(kit, { "tiny" }, { data = data, say = say })
    check("fetch again: already there", ok and table.concat(lines, "\n"):find("already there", 1, true))
    ok, why = ev.fetch(kit, { "changed" }, { data = data, say = say })
    check("a file that differs from the measured copy: refused, not kept", not ok
        and tostring(why):find("differs from the copy the baselines were measured on", 1, true)
        and not util.exists(data .. "/changed.json") and not util.exists(data .. "/changed.json.part"), tostring(why))
    os.remove(data .. "/sub/tiny.json")
    local big = ev.BIG
    ev.BIG = 10
    ok, why = ev.fetch(kit, { "tiny" }, { data = data, say = say })
    check("a big download needs --yes (nothing fetched)", not ok and tostring(why):find("--yes", 1, true)
        and not util.exists(data .. "/sub/tiny.json"), tostring(why))
    ok = ev.fetch(kit, { "tiny" }, { data = data, say = say, yes = true })
    check("… with --yes it is fetched", ok and util.exists(data .. "/sub/tiny.json"))
    ev.BIG = big
    ok, why = ev.fetch(kit, { "nope" }, { data = data })
    check("an unknown dataset: refused, the known ones named", not ok and tostring(why):find("changed, tiny", 1, true),
        tostring(why))
end)

section("a runner's environment", function()
    io.write("\n--- a runner's environment ---\n")
    -- What a runner sees: a probe in a kit prints every MEMO_* variable it gets.
    local kit = { dir = tmp .. "/probekit" }
    write(kit.dir .. "/eval/probe.lua", 'local p = io.popen("env")\nfor l in p:lines() do\n'
        .. '  if l:match("^MEMO_") then print(l) end\nend\np:close()\n')
    local ffi = require("ffi")
    pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
    pcall(ffi.cdef, "int unsetenv(const char *name);")
    local set = { MEMO_RERANK_WEIGHTS = "/x/rw.json", MEMO_PROJECTION_W = "/x/pw.json", MEMO_GGUF_NCTX = "64",
                  MEMO_GGUF_SHIM = "/x/shim.so", MEMO_GGUF_NGL = "99", MEMO_LIB_SQLITE = "/x/libsqlite3.so",
                  MEMO_DB = "/x/the-users.db", MEMO_PROJECT = "/x/proj" }
    for k, v in pairs(set) do ffi.C.setenv(k, v, 1) end
    local log = tmp .. "/probe.log"
    os.execute(ev.kit_command(kit, "probe.lua", {}, { MEMO_DB = "/x/scratch.db", MEMO_PROJECT = "" }, log))
    for k in pairs(set) do ffi.C.unsetenv(k) end
    local seen = {}
    for line in (H.slurp(log) or ""):gmatch("[^\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then seen[k] = v end
    end
    check("the scratch database, an empty MEMO_PROJECT", seen.MEMO_DB == "/x/scratch.db" and seen.MEMO_PROJECT == "",
        H.slurp(log))
    check("the settings that change the numbers are gone (learned reranker, projection, context size)",
        seen.MEMO_RERANK_WEIGHTS == nil and seen.MEMO_PROJECTION_W == nil and seen.MEMO_GGUF_NCTX == nil
        and seen.MEMO_EMBEDDER == nil, H.slurp(log))
    check("the GGUF runtime, its GPU layers and the library paths are kept", seen.MEMO_GGUF_SHIM == "/x/shim.so"
        and seen.MEMO_GGUF_NGL == "99" and seen.MEMO_LIB_SQLITE == "/x/libsqlite3.so", H.slurp(log))
end)

section("embedders", function()
    io.write("\n--- embedders ---\n")
    local ffi = require("ffi")
    pcall(ffi.cdef, "int unsetenv(const char *name);")
    pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
    for _, k in ipairs({ "EMBED_MAX_CHARS", "OLLAMA_URL", "OLLAMA_MODEL", "OLLAMA_DIM", "TEI_URL", "TEI_MODEL",
                         "TEI_DIM" }) do ffi.C.unsetenv(k) end
    local h = ev.embedder("hash")
    check("hash: label hash, nothing set", h and h.label == "hash" and next(h.env) == nil)
    local o, t = ev.embedder("ollama"), ev.embedder("tei")
    check("ollama / tei: labelled by model; texts capped within the model's context (8000 / 24000 chars)",
        o and o.label == "ollama:nomic-embed-text" and o.env.EMBED_MAX_CHARS == "8000"
        and t and t.label == "tei:BAAI/bge-m3" and t.env.EMBED_MAX_CHARS == "24000"
        and t.env.TEI_URL == "http://127.0.0.1:8081/embed")
    ffi.C.setenv("EMBED_MAX_CHARS", "1234", 1)
    check("… the user's EMBED_MAX_CHARS wins", ev.embedder("tei").env.EMBED_MAX_CHARS == "1234")
    ffi.C.unsetenv("EMBED_MAX_CHARS")
    local e, why = ev.embedder("openai")
    check("an API embedder is not one memo eval runs", e == nil and tostring(why):find("unknown embedder", 1, true))
end)

section("compare against the baseline", function()
    io.write("\n--- compare ---\n")
    local base = { n_questions = 36, ["recall@1"] = 0.60, bytes_to_hit_mean = 1000 }
    local function flags(row) return table.concat(ev.compare(row, base), "; ") end
    check("no baseline", table.concat(ev.compare({ n_questions = 36 }, nil)) == "no baseline")
    check("another n: not compared", flags({ n_questions = 20, ["recall@1"] = 0.1 }):find("not compared", 1, true))
    check("R@1 1 pt lower: flagged", flags({ n_questions = 36, ["recall@1"] = 0.59, bytes_to_hit_mean = 1000 })
        :find("R@1 1.0 pts below", 1, true), flags({ n_questions = 36, ["recall@1"] = 0.59, bytes_to_hit_mean = 1000 }))
    check("bytes-to-hit 10 % more: flagged", flags({ n_questions = 36, ["recall@1"] = 0.60, bytes_to_hit_mean = 1100 })
        :find("bytes-to-hit 10 % above", 1, true))
    check("within both: no flag", flags({ n_questions = 36, ["recall@1"] = 0.595, bytes_to_hit_mean = 1090 }) == "")
end)

section("run (quick tier, hash)", function()
    io.write("\n--- run ---\n")
    local out_dir = tmp .. "/run1"
    -- (one benchmark: the history checks below follow one cell; the quick tier's session /
    -- codemap have their own section)
    local out, code = memo("eval run personalization --embedder hash --out " .. q(out_dir))
    check("run: exit 0, the smoke checks pass, the table printed", code == 0 and out:find("smoke  membench", 1, true)
        and out:find("The last 3 measurements", 1, true) and out:find("personalization%s+hash"), out)
    local s = json.decode(H.slurp(out_dir .. "/summary.json") or "")
    local r = s and s.results.personalization and s.results.personalization.hash
    check("summary.json: the new figures beside R@k", r and r.n_questions == 36 and r.miss_rate
        and math.abs(r.miss_rate - (1 - r["recall@10"])) < 1e-9 and r.bytes_to_hit_mean > 0
        and r.bytes_to_hit_median and r.est_tokens_to_hit_mean, H.slurp(out_dir .. "/summary.json"))
    check("… version, date, the command", s and s.luamemo == VERSION and s.measured and s.command
        and s.command:find("memo eval run personalization --embedder hash", 1, true))
    local direct = json.decode(H.slurp(out_dir .. "/personalization-hash.json") or "")
    check("… the runner's own JSON and log are kept beside it", direct and direct.overall
        and util.exists(out_dir .. "/personalization-hash.log"))
    local md = H.slurp(out_dir .. "/report.md") or ""
    check("report.md: the last measurements with miss rate and bytes to hit, and what they mean",
        md:find("## The last 3 measurements", 1, true) and md:find("| Miss rate | Bytes to hit", 1, true)
        and md:find("**Miss rate**", 1, true) and md:find("never averaged", 1, true), md)
    check("the scratch databases are gone", not util.is_dir(out_dir .. "/scratch"))

    -- The project's memory: only the history row (scope eval:proj) — nothing of the runners.
    local function user_rows()
        local h = require("luamemo.db").open(user_db, { readonly = true })
        if not h then return {} end
        local rows = h.query("SELECT scope, kind, title, metadata FROM lm_memories ORDER BY id") or {}
        h.close()
        return rows
    end
    local function meta(row)   -- (the database layer decodes JSON columns already)
        local m = row and row.metadata
        if type(m) == "string" then m = json.decode(m) end
        return type(m) == "table" and m or nil
    end
    local rows = user_rows()
    local hist = meta(rows[1])
    check("the project's database holds one memory: the history of personalization × hash, in eval:proj",
        #rows == 1 and rows[1].scope == "eval:proj" and rows[1].kind == "eval"
        and rows[1].title == "memo eval: Project personalization · hash", json.encode(rows))
    check("… one entry: the version, the time, the figures", hist and #hist.history == 1
        and hist.history[1].luamemo == VERSION and hist.history[1].measured:match("^%d+%-%d+%-%d+ %d+:%d+$")
        and hist.history[1]["recall@1"] == math.floor(r["recall@1"] * 1e6 + 0.5) / 1e6, json.encode(hist))
    check("the run says where it is kept", out:find("kept in the project's memory (scope eval:proj", 1, true), out)

    -- With a baseline the run doesn't reach: flagged.
    local b = json.decode(H.slurp(kit_dir .. "/eval/baselines.json"))
    b.results = { personalization = { hash = { n_questions = 36, ["recall@1"] = 0.95,
        bytes_to_hit_mean = r and r.bytes_to_hit_mean / 2 or 1 } } }
    write(kit_dir .. "/eval/baselines.json", json.encode(b))
    out, code = memo("eval run personalization --embedder hash --no-smoke --out " .. q(tmp .. "/run2"))
    check("against the baseline: R@1 drop and more bytes flagged", code == 0
        and out:find("against the baseline:", 1, true) and out:find("pts below the baseline", 1, true)
        and out:find("above the baseline", 1, true), out)
    b.results.personalization.hash = { n_questions = 36, ["recall@1"] = r and r["recall@1"],
        bytes_to_hit_mean = r and r.bytes_to_hit_mean }
    write(kit_dir .. "/eval/baselines.json", json.encode(b))
    out, code = memo("eval run personalization --embedder hash --no-smoke --out " .. q(tmp .. "/run3"))
    check("the same numbers: no flag; the report says they are within the baseline", code == 0
        and not out:find("against the baseline:", 1, true)
        and (H.slurp(tmp .. "/run3/report.md") or ""):find("| within the baseline |", 1, true), out)

    -- The comparison: three runs kept, side by side; a fourth drops the oldest.
    local md3 = H.slurp(tmp .. "/run3/report.md") or ""
    local _, n_rows = md3:gsub("\n|  |  | %d", "")
    check("the third run's table: three measurements of the cell, the newest marked now, each with its change",
        md3:find("| Project personalization | hash | ", 1, true) and md3:find("(now) |", 1, true) and n_rows == 2
        and md3:find("R@1 +0.0 pts · miss +0.0 pts · bytes +0 %", 1, true), md3)
    out = memo("eval run personalization --embedder hash --no-smoke --out " .. q(tmp .. "/run4"))
    rows = user_rows()
    hist = meta(rows[1])
    check("a fourth run: still one memory, the newest 3 kept", #rows == 1 and hist and #hist.history == 3, json.encode(rows))
    out = memo("eval run personalization --embedder hash --no-smoke --n 5 --out " .. q(tmp .. "/run5"))
    hist = meta(user_rows()[1])
    check("a partial run (--n) is not kept, and says so", out:find("not kept in memory: a partial run", 1, true)
        and hist and #hist.history == 3, out)
    out, code = memo("eval history")
    check("memo eval history: the kept results, without running", code == 0
        and out:find("The last 3 measurements, kept in eval:proj", 1, true)
        and out:find("personalization%s+hash"), out)
    out = memo("eval history --json --embedder gguf")
    local hj = json.decode(out:match("{.*}") or "")
    check("… --embedder filters (gguf: none here), --json", hj and hj.scope == "eval:proj" and #hj.results == 0, out)
    out = memo("eval history personalization --json")
    hj = json.decode(out:match("{.*}") or "")
    check("… by benchmark", hj and #hj.results == 1 and #hj.results[1].history == 3, out)
    out = memo("eval status --json")
    local st = json.decode(out:match("{.*}") or "")
    check("status: the history's scope, how many results and the newest", st and st.history.scope == "eval:proj"
        and st.history.results == 1 and st.history.last, out)

    out, code = memo("eval run scale learned --no-smoke --out " .. q(tmp .. "/run7"))
    check("without the benchmark database the corpus benchmarks are skipped, said once, and the run succeeds", code == 0
        and out:find("skip   scale", 1, true) and out:find("benchmark database not built", 1, true)
        and out:find("memo eval build-corpus", 1, true), out)

    out, code = memo("eval run locomo --embedder hash --data " .. q(tmp .. "/empty"))
    check("a missing dataset: exit 1 before running, the fetch command and size", code == 1
        and out:find("memo eval fetch locomo", 1, true) and out:find("2.7 MB", 1, true), out)
    out, code = memo("eval run nope")
    check("an unknown benchmark: exit 2", code == 2, out)
    out, code = memo("eval run --tier huge")
    check("an unknown tier: exit 2", code == 2, out)
    out, code = memo("eval run personalization --tier quick")
    check("benchmarks and a tier: exit 2", code == 2, out)
    out, code = memo("eval run --embedder nope")
    check("an unknown embedder: exit 1, the known ones named", code == 1 and out:find("mine, hash, gguf", 1, true), out)
end)

section("kinds of benchmarks: their tables, changes and baselines", function()
    io.write("\n--- kinds ---\n")
    local sess = { bench = "session", title = "Session's fixed cost", label = "—", now = true, history = {
        { measured = "2026-10-22 10:00", luamemo = "0.5.2", instructions_bytes = 1700, tools_bytes = 15000,
          tools_core_bytes = 10500, n_tools = 27, n_tools_core = 16, brief_bytes = 300, session_bytes = 17000,
          session_core_bytes = 12500 },
        { measured = "2026-10-21 10:00", luamemo = "0.5.2", session_bytes = 15000, session_core_bytes = 12500 } } }
    local ret = { bench = "personalization", title = "Project personalization", label = "hash", history = {
        { measured = "2026-10-22 10:00", luamemo = "0.5.2", n_questions = 36, ["recall@1"] = 0.6, miss_rate = 0.05,
          bytes_to_hit_mean = 1000, rerank_ms_mean = 1200, rerank_tokens_mean = 3000, rerank_failed = 2 } } }
    local md = ev.history_md({ ret, sess })
    local tables = select(2, md:gsub("\n|%-%-%-|", ""))
    check("history_md: one table per kind, each with its own columns", tables == 2 and md:find("| Usage rules |", 1, true)
        and md:find("| R@1 |", 1, true) and md:find("\n\n| Benchmark |", 1, true), md)
    check("… a column shown only when a result has it: the reranker's cost, its failures",
        md:find("Rerank per search (ms / tokens)", 1, true) and md:find("1200 / 3000 · 2 failed", 1, true)
        and not md:find("grep instead", 1, true), md)
    check("… the session's change: total +13 %", md:find("total +13 % · core +0 %", 1, true), md)
    local txt = ev.history_text({ ret, sess })
    check("history_text: the same, aligned", txt:find("Usage rules", 1, true) and txt:find("now", 1, true) == nil
        and txt:find("10:00*", 1, true), txt)
    check("compare: the session's fixed cost 10 % up is flagged",
        table.concat(ev.compare({ session_bytes = 11000 }, { session_bytes = 10000 }, "session"), "")
            :find("10 % above the baseline", 1, true))
    check("compare: speed is not compared with another machine's",
        ev.compare({}, { cold_start_ms = 1 }, "perf")[1] == "machine-dependent — not compared")
    local r = ev.rerank_spec("ollama:gemma4:e4b")
    check("rerank_spec ollama:<model>: its label, the runners' flags, the model", r and r.label == "ollama:gemma4:e4b"
        and r.env.OLLAMA_RERANK_MODEL == "gemma4:e4b" and table.concat(r.args, " "):find("--rerank-adapter ollama", 1, true))
    check("rerank_spec: ollama without a model, an unknown one — refused", ev.rerank_spec("ollama") == nil
        and ev.rerank_spec("magic") == nil and ev.rerank_spec("noop").label == "noop")
    local e, why = ev.embedder("gguf:no-such-model")
    check("embedder gguf:<model> that isn't there: refused", e == nil and tostring(why):find("no GGUF model", 1, true))
end)

section("the session's cost and the code map, through memo eval", function()
    io.write("\n--- session, codemap ---\n")
    local out, code = memo("eval run session codemap --embedder hash --no-smoke --out " .. q(tmp .. "/run6"))
    check("run session codemap: exit 0, both tables", code == 0 and out:find("Usage rules", 1, true)
        and out:find("grep instead", 1, true), out)
    local s = json.decode(H.slurp(tmp .. "/run6/summary.json") or "")
    local se = s and s.results.session and s.results.session["—"]
    check("session: the rules, all / core tool definitions and the brief, in bytes", se and se.instructions_bytes > 500
        and se.tools_bytes > se.tools_core_bytes and se.n_tools > se.n_tools_core and se.brief_bytes > 0
        and se.session_bytes == se.instructions_bytes + se.tools_bytes + se.brief_bytes, json.encode(se))
    local cm = s and s.results.codemap and s.results.codemap.hash
    check("codemap: R@k and bytes to hit over luamemo's own modules, beside grep's", cm and cm.n_questions >= 40
        and cm["recall@10"] and cm.bytes_to_hit_mean and cm.grep_bytes_to_hit_mean, json.encode(cm))
end)

section("speed and footprint (perf_run, small)", function()
    io.write("\n--- perf ---\n")
    local dir = tmp .. "/perf"
    os.execute("mkdir -p " .. q(dir))
    local out, code = H.sh(("cd %q && env -u MEMO_SCOPE MEMO_DB=%q %q eval/perf_run.lua --memo %q --sizes 100,300 --out %q"):format(
        repo, dir .. "/p.db", H.lua_bin(), repo .. "/cli/memo", dir .. "/p.json"))
    local p = json.decode(H.slurp(dir .. "/p.json") or "")
    local o = p and p.overall or {}
    check("perf_run: search p50 / p95 per size, hash embedding and writes, the server's start, memory, the DB's size",
        code == 0 and o.search_ms_p50_100 and o.search_ms_p95_300 and o.embed_ms_hash and o.writes_per_s_hash
        and o.cold_start_ms and o.first_search_ms and (o.rss_idle_mb or 0) > 0 and (o.rss_search_mb or 0) > 0
        and o.db_kb_per_1k, out)
end)

os.execute("rm -rf " .. q(tmp))
finish()
