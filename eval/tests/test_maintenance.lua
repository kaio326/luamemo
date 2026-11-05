-- eval/tests/test_maintenance.lua
-- Maintenance beside the agent, never in its way (luamemo.maintenance, memo maintain):
--   A. a write that makes the digest or a scheduled summary due only CLAIMS the slot and starts a background
--      process; nothing is run inside the write; one start per interval; a failed start gives the slot back
--   B. the real start: detached, returns at once, and nothing the process prints reaches the caller (an MCP
--      server's stdout is the protocol)
--   C. `memo maintain`: quiet prints nothing, by hand prints a line; it does the work (the review deletes what
--      is due) and says what went wrong; one run at a time — the lock is an flock: refused while another process
--      holds it, free the moment that process ends; a lock file that cannot be made is an error, not a busy lock;
--      the process a run starts keeps none of the caller's sockets (a server marks its own close-on-exec, above the
--      descriptors the start closes); a bad option value is a usage error; the run's report (a part that raised,
--      returned nothing, a prune that raised, what was kept); the slots a run puts back when its lock file cannot be
--      made; the time box reaches the digest's review; `memo maintain --all` gives the scopes ONE deadline and says how
--      many are left when it runs out
--   (and the brief's kick, the slots' own intervals, the scan for due reviews)
--   D. a SEARCH never waits on a language model: the consolidation it runs inline synthesizes without the summarizer
--   E. MEMO_MAINTENANCE_BACKGROUND=false does it inside the write, as before
-- Run: luajit eval/tests/run.lua --only maintenance

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Background maintenance")
local check, finish = T.check, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local util        = require("luamemo.util")
local store       = require("luamemo.store")
local fold        = require("luamemo.fold")
local digest      = require("luamemo.digest")
local summarizer  = require("luamemo.summarizer")
local maintenance = require("luamemo.maintenance")

-- (a section that stubs the process start puts it back when it ends, a failed check or a crash included)
local function section(name, fn) T.section(name, fn, function() maintenance.spawner = nil end) end

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()
local DAY = util.DAY_US
local TMP = os.tmpname(); os.remove(TMP); os.execute(("mkdir -p %q"):format(TMP))

-- the environment `memo` runs in for a scope of a database (the run's, unless one is given): the shell prefix of a command
local function memo_env(scope, db_path)
    return ("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_SCOPE=%q MEMO_LUA=%q"):format(db_path or MAIN, scope, lua_bin)
end
-- The last line the log holds for a `memo maintain` run of `scope` (a JSON text), or ""
local function last_maintain_line(scope)
    local last = ""
    for line in (H.slurp(fold.log_path()) or ""):gmatch("[^\n]+") do
        if line:find('"run":"maintain"', 1, true) and line:find(scope, 1, true) then last = line end
    end
    return last
end

-- Run Lua in a child luajit whose maintenance.spawn starts `script` (the stand-in for `memo`; OUT is the prefix of the
-- files it writes) → what the child printed
local function in_child(script, out, lua_code)
    return H.sh(("env -u MEMO_NO_MAINTENANCE MEMO__BIN=%q MEMO__PROJECT_DIR=%q OUT=%q %q -e %s 2>&1"):format(script, TMP, out, lua_bin,
        util.shell_quote("package.path='./?.lua;./?/init.lua;'..package.path; " .. lua_code)))
end
-- an executable shell script under the test's temporary directory (a stand-in for `memo`) → its path
local function fake_bin(name, body)
    local path = TMP .. "/" .. name
    local f = assert(io.open(path, "w")); f:write("#!/bin/sh\n", body); f:close()
    os.execute("chmod +x " .. path)
    return path
end

-- (luamemo.setup merges onto the config before it, so every call puts back what a section may have changed)
local BASE = { summarizer_adapter = "noop", consolidate_threshold = false, summarizer_interval_seconds = 0,
    auto_digest_enabled = false, maintenance_background = true }
local function setup(extra) H.setup(extra, BASE) end
local n = H.count

-- a slot's stamp (the row has to exist: no row is not a stamp of 0) → number | nil
local function slot_stamp(name, scope)
    local s = maintenance.SLOTS[name]
    local row = db.first(("SELECT %s AS v FROM %s WHERE scope = ?"):format(s.col, s.tbl), scope)
    return row and tonumber(row.v)
end
-- how many seconds ago a slot was last claimed → number | nil
local function slot_age_s(name, scope)
    local stamp = slot_stamp(name, scope)
    return stamp and (util.now_us() - stamp) / 1000000
end

-- when the review of two folded notes comes: `days` from now (negative: it is due)
local function review_in(ids, days)
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.review_at', ?) WHERE id IN (?, ?)", util.now_us() + days * DAY, ids[1], ids[2])
end
-- two notes of a scope, folded into a summary, whose review is due (or `due_in` days off) → their ids
local function folded_pair(scope, label, due_in)
    local ids = {}
    for i = 1, 2 do ids[i] = assert(store.write({ scope = scope, title = label .. i, body = label .. " old note " .. i, importance = 0.3, dedup_strategy = "append" })).id end
    assert(store.replace_with_summary(ids, { scope = scope, title = "S", body = label .. " old notes" }))
    review_in(ids, due_in or -1)
    return ids
end

section("the shipped defaults: a write starts the digest and the daily summary on its own", function()
    local d = require("luamemo.settings").defaults()
    check("digest on, a summary every day, the summarizer follows the language model",
        d.auto_digest_enabled == true and d.summarizer_interval_seconds == 86400 and d.summarizer_adapter == "auto")
    -- a configuration that names none of them: the defaults decide
    H.setup()
    local started = {}
    maintenance.spawner = function(scope, what) started[#started + 1] = what; return true end
    assert(store.write({ scope = "repo:bg-defaults", title = "a", body = "a note about the shipped defaults", importance = 0.2, dedup_strategy = "append" }))
    maintenance.spawner = nil
    check("one write, one background process, for the digest and (no model configured: nothing remote) the summary",
        #started == 1 and started[1].digest == true and started[1].summarize == true, #started)
end)

section("a write only claims and starts", function()
    setup({ auto_digest_enabled = true, summarizer_interval_seconds = 3600 })
    digest.configure({ auto_digest_interval = 100000 })
    local calls = {}
    maintenance.spawner = function(scope, what) calls[#calls + 1] = { scope = scope, what = what }; return true end
    local scope = "repo:bg-a"
    local raw = assert(store.write({ scope = scope, title = "step", body = "ran migration 7 on staging", importance = 0.2, dedup_strategy = "append" }))
    check("one write that wins both slots (the digest and the scheduled summary) starts ONE process for both — two would race for the lock and the loser's slot would be spent for nothing",
        #calls == 1 and calls[1].scope == scope and calls[1].what.digest and calls[1].what.summarize, #calls)
    check("nothing ran inside the write: the raw row is still unconsolidated",
        n("SELECT count(*) FROM lm_memories WHERE id = ? AND consolidated_at IS NULL", raw.id) == 1)
    local before = #calls
    assert(store.write({ scope = scope, title = "step 2", body = "ran migration 8 on staging", importance = 0.2, dedup_strategy = "append" }))
    check("a second write in the interval starts nothing (the claim is held)", #calls == before, #calls - before)
    -- a start that fails gives the slot back
    local scope2 = "repo:bg-b"
    maintenance.spawner = function() return false end
    assert(store.write({ scope = scope2, title = "x", body = "first", importance = 0.2, dedup_strategy = "append" }))
    check("a start that fails gives the claim back (the cursor is reset: the row is there, at 0)", slot_stamp("digest", scope2) == 0, slot_stamp("digest", scope2))
    check("… the summary slot too", slot_stamp("summarize", scope2) == 0, slot_stamp("summarize", scope2))
    local retry = 0
    maintenance.spawner = function() retry = retry + 1; return true end
    assert(store.write({ scope = scope2, title = "y", body = "second", importance = 0.2, dedup_strategy = "append" }))
    check("… so the next write starts it again", retry >= 1)
    maintenance.spawner = nil
    setup({ auto_digest_enabled = false, summarizer_interval_seconds = 0 })   -- (setup merges: switch them off for the sections below)
end)

section("the real start: detached and silent", function()
    local out = TMP .. "/spawned"
    local script = fake_bin("fakememo", "printf '%s\\n' \"$@\" > \"$OUT.args\"\necho NOISE-stdout\necho NOISE-stderr >&2\nsleep 2\necho done > \"$OUT.done\"\n")
    -- (the time is taken inside the caller, around the call, by the wall clock: the process it starts sleeps 2 s)
    local text = in_child(script, out,
        "local ffi = require('ffi'); ffi.cdef('typedef struct { long s; long us; } lm_tv; int gettimeofday(lm_tv *tv, void *tz);'); "
        .. "local function now() local tv = ffi.new('lm_tv'); ffi.C.gettimeofday(tv, nil); return tonumber(tv.s) + tonumber(tv.us) / 1e6 end; "
        .. "local m = require('luamemo.maintenance'); local t = now(); local ok = m.spawn('repo:bg-c', { digest = true, summarize = true }); "
        .. "io.write(tostring(ok), ' ', string.format('%.2f', now() - t))")
    local took = tonumber(text:match("^true ([%d%.]+)"))
    check("it returns true at once (under half a second), before the process has finished (it sleeps 2 s)",
        took and took < 0.5 and not util.exists(out .. ".done"), text)
    check("nothing the process printed (stdout or stderr) reached the caller", not text:find("NOISE", 1, true), text)
    local seen = false
    for _ = 1, 40 do
        if util.exists(out .. ".args") then seen = true; break end
        os.execute("sleep 0.1")
    end
    local args = seen and H.slurp(out .. ".args") or ""
    check("it ran `maintain --scope … --quiet` with the parts asked for",
        args:find("maintain\n--scope\nrepo:bg-c\n--quiet\n--digest\n--summarize", 1, true) ~= nil, args)
    for _ = 1, 40 do if util.exists(out .. ".done") then break end os.execute("sleep 0.1") end
    check("and went on to finish by itself", util.exists(out .. ".done"))
end)

section("memo maintain", function()
    setup({})
    local scope = "repo:bg-d"
    local function seed_due() return folded_pair(scope, "old") end   -- (two notes folded into a summary, their grace over)
    local env = memo_env(scope)
    local ids = seed_due()
    local quiet, qcode = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --quiet 2>&1")
    check("--quiet prints nothing at all", qcode == 0 and quiet == "", quiet)
    check("… and did the work: the due folded notes were reviewed and deleted",
        n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?)", ids[1], ids[2]) == 0)
    local log = H.slurp(fold.log_path()) or ""
    check("… and the run is in the database's maintenance log", log:find('"run":"maintain"', 1, true) ~= nil and log:find(scope, 1, true) ~= nil)
    seed_due()
    local loud, lcode = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " 2>&1")
    check("by hand it says what it did", lcode == 0 and loud:find(scope, 1, true) and loud:find("2 folded memories deleted", 1, true), loud)
    -- one at a time
    local lock = maintenance.lock_path()
    local ids2 = seed_due()
    local release = H.hold_flock(lock, 60)   -- (another `memo maintain` is at work)
    local held = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " 2>&1")
    check("a run while another holds the lock leaves at once, touching nothing",
        held:find("in progress", 1, true) and n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?)", ids2[1], ids2[2]) == 2, held)
    -- a run that could not take the lock puts the slots it was started for back, to come due again in a couple of
    -- minutes (or what was due would wait a whole interval; and handed back at once, the very next write would
    -- start another process that finds the lock held too)
    local gscope = "repo:bg-give"
    db.run("DELETE FROM lm_digest_state WHERE scope = ?", gscope)
    db.run("INSERT INTO lm_digest_state (scope, last_digested_at) VALUES (?, ?)", gscope, util.now_us())
    H.sh(env .. " ./cli/memo maintain --scope " .. gscope .. " --digest --quiet 2>&1")
    local age_s = slot_age_s("digest", gscope)
    check("… and the digest slot it was started for comes due again in about two minutes (not at once, not in an hour)",
        age_s and age_s > 3600 - 120 - 60 and age_s < 3600 - 120 + 60, age_s)
    check("… so the very next write does not claim it", require("luamemo.digest").claim(gscope) == false)
    -- … but only for THIS database: the data directory holds every project's, and one's run is not another's
    local other_db = TMP .. "/other-project.db"
    local elsewhere = H.sh(memo_env("repo:other", other_db) .. " ./cli/memo maintain --scope repo:other 2>&1")
    check("the lock of one database does not hold another's run up", not elsewhere:find("in progress", 1, true), elsewhere)
    check("each database has its own lock and its own log",
        lock:find(MAIN, 1, true) == 1 and lock ~= other_db .. ".maintenance.lock"
        and fold.log_path():find(MAIN, 1, true) == 1 and util.exists(other_db .. ".maintenance.log"), lock)
    release()   -- the other run is gone (killed: nothing cleans up after it)
    local after = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --quiet 2>&1")
    check("once its holder is gone the next run takes the lock and does the work (nothing stale to wait out)",
        after == "" and n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?)", ids2[1], ids2[2]) == 0)
    check("… and the lock was let go of when that run ended", maintenance.lock() == true)
    maintenance.unlock()
    -- --all finds the scopes with a review due
    local other = "repo:bg-e"
    local oids = folded_pair(other, "other")
    local due = maintenance.due_scopes()
    local found = false
    for _, s in ipairs(due) do if s == other then found = true end end
    check("due_scopes lists a scope with a review due", found, table.concat(due, ","))
    H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --all --quiet 2>&1")
    check("--all reviews it too", n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?)", oids[1], oids[2]) == 0)
end)

section("the session brief asks for the reviews that are due", function()
    setup({})
    local started = {}
    maintenance.spawner = function(scope, what) started[#started + 1] = { scope = scope, what = what }; return true end
    db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
    -- nothing due anywhere: the brief starts nothing
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.review_at', ?) WHERE json_type(metadata, '$.lm_fold') IS NOT NULL", util.now_us() + 40 * DAY)
    require("luamemo.brief").text("repo:brief")
    check("nothing due: the brief starts nothing", #started == 0, #started)
    check("… and it looked: asked for today (the table is not scanned again before tomorrow)",
        n("SELECT count(*) FROM lm_meta WHERE key = 'maintain_kick'") == 1)
    db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")   -- (a review that comes due after the look waits for tomorrow's)
    local scope = "repo:bg-brief"
    local ids = folded_pair(scope, "brief")
    require("luamemo.brief").text("repo:brief")
    check("a review is due somewhere: the brief starts one (review, every scope with one due)",
        #started == 1 and started[1].what.review and started[1].what.all and started[1].scope == scope, #started)
    require("luamemo.brief").text("repo:brief")
    check("… once a day: the next brief starts nothing", #started == 1, #started)
    db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
    maintenance.spawner = function() return false end
    require("luamemo.brief").text("repo:brief")
    check("a start that fails is not counted as asked today",
        n("SELECT count(*) FROM lm_meta WHERE key = 'maintain_kick'") == 0)
    maintenance.spawner = nil
    review_in(ids, 40)
end)

section("a search never waits on the language model", function()
    local calls = 0
    package.loaded["luamemo.summarizers.countme"] = {
        summarize = function(members) calls = calls + 1; return { title = "synth", body = "a synthesised observation " .. #members, metadata = {} } end,
    }
    setup({ summarizer_adapter = "countme", consolidate_threshold = 0.5 })
    local scope = "repo:bg-f"
    for i = 1, 3 do
        assert(store.write({ scope = scope, title = "deploy " .. i, body = "the deploy runs on friday after the freeze, step " .. i,
            importance = 1, dedup_strategy = "append" }))
    end
    luamemo.search({ scope = scope, query = "when does the deploy run", limit = 5, skip_feedback = true })
    check("a search that consolidates what is pending did not call the summarizer", calls == 0, calls)
    check("… and it did consolidate: an observation exists", n("SELECT count(*) FROM lm_observations WHERE scope = ?", scope) >= 1)
    local scope2 = "repo:bg-g"
    for i = 1, 3 do
        assert(store.write({ scope = scope2, title = "release " .. i, body = "release notes are written before tagging, take " .. i,
            importance = 1, dedup_strategy = "append" }))
    end
    require("luamemo.consolidate").process(scope2)
    check("the same consolidation run in the background does ask it (for a group of several memories)", calls >= 1, calls)
    -- … but not for a memory on its own: nothing to summarize
    local before = calls
    local scope3 = "repo:bg-g2"
    assert(store.write({ scope = scope3, title = "lone", body = "a lone memory about vacuum cleaners and nothing else", importance = 1, dedup_strategy = "append" }))
    require("luamemo.consolidate").process(scope3)
    check("a cluster of one is not sent to the model", calls == before, calls - before)
    package.loaded["luamemo.summarizers.countme"] = nil
    setup({})
end)

section("through a real MCP server", function()
    -- the server a client starts, with the digest on: its write returns, and `memo maintain` runs on its own beside it
    local scope = "repo:bg-i"
    -- (started the way a client does, `memo mcp` — which tells the server which memo to start `memo maintain` with)
    local s = H.mcp_session(("MEMO_NO_MAINTENANCE= MEMO_AUTO_DIGEST=1 MEMO_SCOPE=%s MEMO_EMBEDDER=hash MEMO_LUA=%q"):format(scope, lua_bin),
        { cmd = "./cli/memo mcp" })
    local w = s.call("memory_write", { title = "step", body = "ran migration 11 on staging", importance = 0.2, tier = 0 })
    check("memory_write answers", w and (w.ok == true or w.memory ~= nil), require("luamemo.json").encode(w))
    local archived, log = false, ""
    for _ = 1, 100 do   -- up to 20 s for the background process (loading the runtime, the digest, its log line)
        archived = n("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_type(metadata, '$.lm_fold') IS NOT NULL", scope) >= 1
        log = H.slurp(fold.log_path()) or ""
        if archived and log:find('"run":"maintain"', 1, true) and log:find(scope, 1, true) then break end
        os.execute("sleep 0.2")
    end
    s.close()
    check("the digest ran in a process the write started: the raw row is archived", archived)
    check("… and it left its line in maintenance.log", log:find('"run":"maintain"', 1, true) and log:find(scope, 1, true))
end)

section("MEMO_MAINTENANCE_BACKGROUND=false", function()
    setup({ auto_digest_enabled = true, maintenance_background = false })
    check("the setting defaults to true", require("luamemo.settings").defaults().maintenance_background == true)
    local started = 0
    maintenance.spawner = function() started = started + 1; return true end
    local scope = "repo:bg-h"
    local raw = assert(store.write({ scope = scope, title = "step", body = "ran migration 9", importance = 0.2, dedup_strategy = "append" }))
    check("the write that made the digest due ran it itself: the raw row is archived when the write returns",
        n("SELECT count(*) FROM lm_memories WHERE id = ? AND json_type(metadata, '$.lm_fold') IS NOT NULL", raw.id) == 1)
    check("… and started no process", started == 0, started)
    maintenance.spawner = nil
    setup({ auto_digest_enabled = false, maintenance_background = true })   -- (setup merges: put it back)
end)

section("the process is started with the parts asked for", function()
    local f = maintenance._flags
    check("a write's start: --digest --summarize", table.concat(f({ digest = true, summarize = true }), " ") == "--digest --summarize")
    check("the brief's start: --review --all", table.concat(f({ review = true, all = true }), " ") == "--review --all")
    check("training: --learn", table.concat(f({ learn = true }), " ") == "--learn")
    check("nothing asked: no flag (memo maintain then does all of it)", #f({}) == 0)
end)

section("the lock: an flock held by the running process", function()
    local lock = maintenance.lock_path()
    os.execute(("rm -rf %q"):format(lock))
    check("the first run takes it", maintenance.lock() == true)
    check("a second take in the same process is 'another run': refused", maintenance.lock() == false)
    maintenance.unlock()
    -- another process holds it: this one is refused, and takes it once that process is gone, however it ended
    local release, held = H.hold_flock(lock, 60)
    check("(set up: another process holds the lock)", held)
    check("a run is refused while another process holds it", maintenance.lock() == false)
    release()   -- the process is killed: nothing runs to clean up after it
    local taken = false
    for _ = 1, 30 do
        if maintenance.lock() then taken = true; break end
        os.execute("sleep 0.1")
    end
    check("… and takes it as soon as that process is gone: there is no stale lock to wait out", taken)
    maintenance.unlock()
    check("unlock lets go: the next run takes it", maintenance.lock() == true)
    -- a process this run starts (a short shell, a child) does not keep the lock alive after the run lets go of it
    os.execute("(sleep 3 >/dev/null 2>&1 &)")
    maintenance.unlock()
    check("… even with a child of the run still alive (the descriptor is not inherited)", maintenance.lock() == true)
    maintenance.unlock()
    -- the first 0.5.2 builds made a lock DIRECTORY at that name: it is not a lock, and is cleared away
    os.execute(("rm -rf %q"):format(lock))
    os.execute(("mkdir -p %q && printf 1 > %q/ts"):format(lock, lock))
    check("an old lock directory is replaced by the lock file", maintenance.lock() == true and not util.exists(lock .. "/ts"))
    maintenance.unlock()
    check("the lock file is private to its owner (0600)", H.mode(lock) == "600")
end)

section("the brief asks again a day later", function()
    setup({})
    local started = 0
    maintenance.spawner = function() started = started + 1; return true end
    local scope = "repo:bg-day"
    local ids = folded_pair(scope, "day")
    db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
    require("luamemo.brief").text("repo:brief")
    require("luamemo.brief").text("repo:brief")
    check("two briefs in a day start one review", started == 1, started)
    db.run("UPDATE lm_meta SET value = ? WHERE key = 'maintain_kick'", ("%.0f"):format(util.now_us() - 2 * DAY))
    require("luamemo.brief").text("repo:brief")
    check("the next day's brief asks again", started == 2, started)
    maintenance.spawner = nil
    review_in(ids, 40)
end)

section("scheduled work never uses a remote summarizer", function()
    local calls = 0
    package.loaded["luamemo.summarizers.remotefake"] = {
        summarize = function(members) calls = calls + 1; return { title = "synth", body = "a synthesised observation " .. #members, metadata = {} } end,
    }
    setup({ summarizer_adapter = "remotefake", summarizer_interval_seconds = 3600, auto_digest_enabled = true,
            consolidate_threshold = 0.5, maintenance_background = true })
    digest.configure({ auto_digest_interval = 100000 })
    check("a named adapter that is not gguf or noop is a remote model; gguf and noop are local",
        maintenance.local_model({ summarizer_adapter = "remotefake" }) == false and maintenance.local_model({ summarizer_adapter = "noop" })
        and maintenance.local_model({ summarizer_adapter = "gguf" }) and maintenance.local_model({}))
    local started = {}
    maintenance.spawner = function(scope, what) started[#started + 1] = what; return true end
    local scope = "repo:bg-remote"
    assert(store.write({ scope = scope, title = "a", body = "a note about vacuum cleaners", importance = 0.2, dedup_strategy = "append" }))
    check("a write claims the digest but not the summary (and starts one process)",
        #started == 1 and started[1].digest and not started[1].summarize
        and n("SELECT count(*) FROM lm_summarize_state WHERE scope = ?", scope) == 0, #started)
    maintenance.spawner = nil
    local res = maintenance.run(scope, { summarize = true })
    check("a run asked to summarize says it skipped, and called nothing", res.summarize and res.summarize.skipped == "remote summarizer" and calls == 0)
    -- the digest's observation wording: without the model
    local scope2 = "repo:bg-remote2"
    for i = 1, 3 do
        assert(store.write({ scope = scope2, title = "step " .. i, tier = 0, importance = 0.2, dedup_strategy = "append",
            body = "the deploy runs on friday after the freeze, step " .. i }))
    end
    maintenance.run(scope2, { digest = true })
    check("a background digest wrote its observations without asking the model", calls == 0 and n("SELECT count(*) FROM lm_observations WHERE scope = ?", scope2) >= 1, calls)
    -- on demand it is used: the same adapter, asked for
    local scope3 = "repo:bg-remote3"
    for i = 1, 3 do
        assert(store.write({ scope = scope3, title = "step " .. i, tier = 0, importance = 0.2, dedup_strategy = "append",
            body = "the release runs on monday after the freeze, step " .. i }))
    end
    digest.run(scope3, {})
    check("… while the digest run by hand does ask it (the control: the adapter is reachable)", calls >= 1, calls)
    package.loaded["luamemo.summarizers.remotefake"] = nil
    setup({})
end)

section("slots: put back in two minutes, given back at once, claimed once", function()
    setup({ summarizer_interval_seconds = 3600, auto_digest_enabled = true })
    local scope = "repo:bg-slots"
    check("the first claim of each slot wins (the interval is the slot's setting: 3600 s)",
        maintenance.claim_slot("digest", scope) and maintenance.claim_slot("summarize", scope))
    check("a second claim inside the interval loses",
        maintenance.claim_slot("digest", scope) == false and maintenance.claim_slot("summarize", scope) == false)
    maintenance.defer({ digest = true, summarize = true }, scope)
    check("defer: the digest slot comes due again in about two minutes", math.abs((slot_age_s("digest", scope) or 0) - (3600 - 120)) < 30)
    check("… and the summary slot too", math.abs((slot_age_s("summarize", scope) or 0) - (3600 - 120)) < 30)
    check("… not at once", maintenance.claim_slot("digest", scope) == false)
    maintenance.release({ digest = true, summarize = true }, scope)
    check("release gives both back at once", slot_stamp("digest", scope) == 0 and slot_stamp("summarize", scope) == 0)
    check("… so the next claim wins", maintenance.claim_slot("digest", scope) == true)
    setup({})
end)

section("each slot has its own interval", function()
    setup({ auto_digest_enabled = true, auto_digest_interval = 3600, summarizer_interval_seconds = 86400 })
    local scope = "repo:bg-intervals"
    check("both claimed once", maintenance.claim_slot("digest", scope) and maintenance.claim_slot("summarize", scope))
    -- both were claimed two hours ago: the hourly digest is due again, the daily summary is not
    local ago = util.now_us() - 2 * 3600 * 1000000
    db.run("UPDATE lm_digest_state SET last_digested_at = ? WHERE scope = ?", ago, scope)
    db.run("UPDATE lm_summarize_state SET last_summarized_at = ? WHERE scope = ?", ago, scope)
    check("two hours on: the digest (every hour) is due, the summary (every day) is not",
        maintenance.claim_slot("digest", scope) == true and maintenance.claim_slot("summarize", scope) == false)
    -- defer puts each back by its own interval less the retry
    maintenance.defer({ digest = true, summarize = true }, scope)
    check("defer: the digest is put back to 3600 - 120 s ago, the summary to 86400 - 120 s ago",
        math.abs((slot_age_s("digest", scope) or 0) - (3600 - 120)) < 30
        and math.abs((slot_age_s("summarize", scope) or 0) - (86400 - 120)) < 30)
    setup({})
end)

section("the code index starts nothing, and an error in a claim gives the slot back", function()
    setup({ summarizer_interval_seconds = 3600, auto_digest_enabled = true })
    local started = 0
    maintenance.spawner = function() started = started + 1; return true end
    assert(store.write({ scope = "codeindex:bg-x", kind = "file", title = "a.lua", body = "a file of the code map", importance = 0.3, dedup_strategy = "append" }))
    check("a write into a code-index scope claims no slot and starts no process (nothing there is memory)",
        started == 0 and n("SELECT count(*) FROM lm_digest_state WHERE scope = 'codeindex:bg-x'") == 0
        and require("luamemo.digest").claim("codeindex:bg-x") == false and require("luamemo.summarizer").claim("codeindex:bg-x") == false, started)
    -- the summary claim raises after the digest slot was won: the digest slot is not burned, and the failure is in the log
    local scope = "repo:bg-burn"
    local res = H.with(require("luamemo.summarizer"), "claim", function() error("the database is locked") end,
        maintenance.after_write, scope, luamemo.config)
    local entries = (H.slurp(fold.log_path()) or "")
    check("after_write returns false, and the digest slot it had won is given back",
        res == false and started == 0 and n("SELECT last_digested_at FROM lm_digest_state WHERE scope = ?", scope) == 0)
    check("… and the error is in the maintenance log", entries:find('"run":"after_write"', 1, true) and entries:find("the database is locked", 1, true))
    maintenance.spawner = nil
    setup({})
end)

section("the brief looks for due reviews once a day, not on every brief", function()
    setup({})
    local scans = 0
    local real = maintenance.due_scopes
    H.with(maintenance, "due_scopes", function() scans = scans + 1; return real() end, function()
        H.with(maintenance, "spawner", function() return true end, function()
            db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
            for _ = 1, 3 do require("luamemo.brief").text("repo:brief") end
        end)
    end)
    check("three briefs, one look", scans == 1, scans)
end)

section("a lock file that cannot be made is an error with a reason, not a busy lock", function()
    local locked, why = H.with(maintenance, "lock_path", function() return "/nonexistent-luamemo-dir/x.maintenance.lock" end, maintenance.lock)
    check("lock() says why it could not", locked == false and tostring(why):find("cannot be created or opened", 1, true) ~= nil, tostring(why))
    local release, held = H.hold_flock(maintenance.lock_path(), 60)
    local l2, w2 = maintenance.lock()
    release()
    check("(control) a lock another run holds is false with no reason", held and l2 == false and w2 == nil)
    -- `memo maintain` on a database whose lock file cannot be made: not 'another run in progress'
    local other = TMP .. "/nolock.db"
    os.execute(("ln -sf /nonexistent-luamemo-dir/lock %q"):format(other .. ".maintenance.lock"))
    local env = memo_env("repo:nolock", other)
    local loud, lcode = H.sh(env .. " ./cli/memo maintain --scope repo:nolock 2>&1")
    check("by hand it fails and says the lock file is the problem", lcode ~= 0 and loud:find("cannot be created or opened", 1, true)
        and not loud:find("in progress", 1, true), loud)
    local quiet, qcode = H.sh(env .. " ./cli/memo maintain --scope repo:nolock --quiet 2>&1")
    check("--quiet still prints nothing and exits 0", qcode == 0 and quiet == "", quiet)
    check("… and the log has the reason", (H.slurp(other .. ".maintenance.log") or ""):find("cannot be created or opened", 1, true) ~= nil)
    os.execute(("rm -f %q"):format(other .. ".maintenance.lock"))
end)

section("the brief's scan finds what the review would review, rows from before folds included", function()
    setup({})
    local scope = "repo:bg-legacy"
    local id = assert(store.write({ scope = scope, title = "old", body = "a note from before folds were recorded", importance = 0.2, tier = 0, dedup_strategy = "append" })).id
    -- consolidated by a digest of an older version: no lm_fold record, older than the grace
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us() - 40 * DAY, id)
    local function listed()
        for _, s in ipairs(maintenance.due_scopes()) do if s == scope then return true end end
        return false
    end
    check("the scan lists the scope, as the review itself would take the row", listed() and fold.run(scope, { dry_run = true }).reviewed == 1)
    db.run("DELETE FROM lm_memories WHERE id = ?", id)
    check("(control) with the row gone it does not", not listed())
end)

section("the brief's kick: background off, nothing due and the usage log on, no scope", function()
    setup({ feedback_enabled = true, feedback_retention_days = 90 })
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.review_at', ?) WHERE json_type(metadata, '$.lm_fold') IS NOT NULL", util.now_us() + 40 * DAY)
    local started = {}
    H.with(maintenance, "spawner", function(scope, what) started[#started + 1] = { scope = scope, what = what }; return true end, function()
        db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
        setup({ feedback_enabled = true, feedback_retention_days = 90, maintenance_background = false })
        check("with maintenance_background off the kick starts nothing and does not use up today", maintenance.kick("repo:kick") == false
            and #started == 0 and n("SELECT count(*) FROM lm_meta WHERE key = 'maintain_kick'") == 0)
        setup({ feedback_enabled = true, feedback_retention_days = 90 })
        check("no scope and nothing due: nothing to start", maintenance.kick(nil) == false and #started == 0)
        db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
        check("nothing due, the usage log on: it starts the daily run (a review, which ends with the log's prune) for the brief's scope",
            maintenance.kick("repo:kick") == true and #started == 1 and started[1].scope == "repo:kick"
            and started[1].what.review == true and started[1].what.all == nil)
        db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
        setup({ feedback_enabled = false })
        check("the usage log off: nothing due means nothing to start", maintenance.kick("repo:kick") == false and #started == 1)
        db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
        setup({ feedback_enabled = true, feedback_retention_days = 0 })
        check("retention 0 (keep everything): no prune to start", maintenance.kick("repo:kick") == false and #started == 1)
    end)
    setup({})
end)

section("what went wrong in a run reaches the log and the screen", function()
    setup({})
    local scope = "repo:bg-prob"
    folded_pair(scope, "problem")
    -- (a shared trigger, not a temporary one: `memo maintain` below is another process on the same database)
    H.with_trigger("bg_prob_no_delete", "BEFORE DELETE ON lm_memories WHEN OLD.scope = 'repo:bg-prob' BEGIN SELECT RAISE(ABORT, 'no delete'); END", function()
        local out = maintenance.run(scope, { review = true })
        check("a review whose deletes fail has errors in its result", out.review and #out.review.errors == 2 and out.review.deleted == 0,
            require("luamemo.json").encode(out.review))
        local last = last_maintain_line(scope)
        check("… and the run's line in maintenance.log carries them", last:find('"errors"', 1, true) and last:find("the delete failed", 1, true), last)
        local env = memo_env(scope)
        local shown = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " 2>&1")
        check("`memo maintain` says how many things went wrong", shown:find("2 things went wrong", 1, true) ~= nil, shown)
    end, true)
    -- the time box: a run whose box is already over starts no review
    local boxed = maintenance.run(scope, { review = true }, { max_seconds = -1 })
    check("max_seconds already spent: the review is not started", boxed.review == nil)
    check("a deadline already over (one box for a run of several scopes): the same",
        maintenance.run(scope, { review = true }, { deadline = os.time() - 1 }).review == nil)
    check("(control) with the default box it is", maintenance.run(scope, { review = true }).review ~= nil)
end)

-- How many sockets the process `spawn` starts holds. The caller runs `before` (Lua: opens files, so that the socket
-- gets a high descriptor) and `after` (Lua run once the socket `s` exists) before it starts the process.
local function sockets_kept(name, before, after)
    local out = TMP .. "/fds-" .. name
    -- (the count is written aside and moved into place: a reader never sees the file half written)
    local script = fake_bin("fakememo-" .. name, "ls -l /proc/$$/fd 2>/dev/null | grep -c 'socket:' > \"$OUT.tmp\"; mv \"$OUT.tmp\" \"$OUT.sockets\"\n")
    local text = in_child(script, out, ("local keep = {}; %s local s = assert(require('socket').tcp()); assert(s:bind('127.0.0.1', 0)); s:listen(1); "
        .. "local m = require('luamemo.maintenance'); %s "
        .. "io.write(tostring(m.spawn('repo:bg-fds', { review = true })))"):format(before, after))
    local counted
    for _ = 1, 40 do
        counted = H.slurp(out .. ".sockets")
        if counted then break end
        os.execute("sleep 0.1")
    end
    return text:match("^true") and tonumber(counted) or nil, text
end

-- Is the close-on-exec flag set on a descriptor? (fcntl F_GETFD: the same call on Linux and macOS)
local function cloexec_set(fd)
    local ffi, bit = require("ffi"), require("bit")
    pcall(ffi.cdef, "int fcntl(int fd, int cmd, ...);")
    return bit.band(ffi.C.fcntl(fd, 1), 1) ~= 0   -- F_GETFD = 1, FD_CLOEXEC = 1
end

section("maintenance.cloexec marks a socket close-on-exec (also on a platform with no /proc)", function()
    local s = assert(require("socket").tcp()); assert(s:bind("127.0.0.1", 0))
    check("a luasocket socket is opened without the flag", cloexec_set(s:getfd()) == false)
    check("cloexec sets it", maintenance.cloexec(s) == true and cloexec_set(s:getfd()) == true)
    s:close()
    check("… and says false for a closed socket or nothing", maintenance.cloexec(s) == false and maintenance.cloexec(nil) == false)
end)

section("the process a run starts does not keep the caller's sockets", function()
    if not util.is_dir("/proc/self/fd") then io.write("[SKIP] no /proc here: the descriptors of the child cannot be listed\n"); return end
    local OPEN_TEN = "for i = 1, 10 do keep[i] = io.open('/dev/null') end"
    local low = sockets_kept("low", "", "")
    check("a socket at a low descriptor is not kept (the start closes 3 to 9)", low == 0, tostring(low))
    local high = sockets_kept("high", OPEN_TEN, "")
    check("(control: the count sees a socket) one above the closed range is kept — the server marks its own", high and high >= 1, tostring(high))
    local marked = sockets_kept("marked", OPEN_TEN, "assert(m.cloexec(s))")
    check("… and once it is marked close-on-exec (maintenance.cloexec) it is not", marked == 0, tostring(marked))
end)

section("memo maintain: values it cannot use, and what its line says when a part did not run", function()
    setup({})
    local scope = "repo:bg-args"
    local env = memo_env(scope)
    for _, args in ipairs({ "--scope", "--scope --quiet", "--max-seconds", "--max-seconds abc", "--max-seconds 0", "--max-seconds -5",
                            "--max-seconds nan", "--max-seconds inf", "--bogus" }) do
        local out, code = H.sh(env .. " ./cli/memo maintain " .. args .. " 2>&1")
        check("`memo maintain " .. args .. "` is a usage error (exit 2), not a run with the default", code == 2 and out:find("usage: memo maintain", 1, true) ~= nil, out)
    end
    local boxed, bcode = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --review --max-seconds 5 2>&1")
    check("(control) a valid --max-seconds runs and prints its line", bcode == 0 and boxed:find(scope .. ": digest —", 1, true) ~= nil, boxed)
    local broken, ccode = H.sh(env .. " MEMO_ROLE=nonsense ./cli/memo maintain --quiet 2>&1")
    check("a setting that stops the run from starting still exits 2 with a message under --quiet (there is no log yet), as the header says",
        ccode == 2 and broken:find("MEMO_ROLE", 1, true) ~= nil, tostring(ccode) .. " " .. broken)
    local learn = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --learn 2>&1")
    check("with --learn alone nothing reviewed and the line does not say 'with the digest'",
        learn:find("review —", 1, true) ~= nil and not learn:find("with the digest", 1, true), learn)
    local dig = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --digest 2>&1")
    check("(control) with the digest it does", dig:find("review with the digest", 1, true) ~= nil, dig)
end)

section("a run's report: a part that raised, one that returned nothing, a prune that raised, and what was kept", function()
    setup({})
    local json = require("luamemo.json")
    local scope = "repo:bg-rep"
    local raised = H.with(digest, "run", function() error("digest broke") end, maintenance.run, scope, { digest = true })
    check("a part that raises is its error, not the run's", raised.digest and tostring(raised.digest.error):find("digest broke", 1, true)
        and (maintenance.problems(raised) or {})[1] == raised.digest.error, json.encode(raised.digest))
    local nothing = H.with(digest, "run", function() return nil end, maintenance.run, scope, { digest = true })
    check("a part that returns nothing says so", nothing.digest and nothing.digest.error == "returned nothing", json.encode(nothing.digest))
    local pr = H.with(require("luamemo.feedback"), "prune_daily", function() error("prune broke") end, maintenance.run, scope, { review = true })
    local list = maintenance.problems(pr) or {}
    check("a prune that raises is reported as a problem of the run", tostring(pr.prune_error):find("prune broke", 1, true)
        and tostring(list[#list]):find("usage log prune: ", 1, true) == 1, json.encode(pr))
    -- a tier-0 memory whose summary is gone is kept, hidden as before: counted in the log line and on the screen
    local ids = {}
    for i = 1, 2 do ids[i] = assert(store.write({ scope = scope, title = "eph " .. i, body = "ephemeral note " .. i, importance = 0.2, dedup_strategy = "append" })).id end
    db.run("UPDATE lm_memories SET tier = 0 WHERE id IN (?, ?)", ids[1], ids[2])
    local sum = assert(store.replace_with_summary(ids, { scope = scope, title = "S", body = "ephemeral notes" }))
    db.run("DELETE FROM lm_memories WHERE id = ?", sum.id)
    review_in(ids, -1)
    local env = memo_env(scope)
    local shown = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --review 2>&1")
    check("the line says how many were kept", shown:find("2 kept", 1, true) ~= nil, shown)
    local last = last_maintain_line(scope)
    check("… and the run's line in the log has kept", last:find('"kept":2', 1, true) ~= nil, last)
end)

section("a lock file that cannot be made puts the slots back, even though the run does not happen", function()
    setup({})
    local scope = "repo:bg-slot"
    local lock = maintenance.lock_path()
    os.execute(("rm -f %q; ln -s /nonexistent-luamemo-dir/lock %q"):format(lock, lock))
    db.run("DELETE FROM lm_digest_state WHERE scope = ?", scope)
    db.run("INSERT INTO lm_digest_state (scope, last_digested_at) VALUES (?, ?)", scope, util.now_us())
    local env = memo_env(scope)
    local out, code = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --digest --quiet 2>&1")
    os.execute(("rm -f %q"):format(lock))
    local age_s = slot_age_s("digest", scope)
    check("the digest slot the run was started for is due again in about two minutes, not an interval later",
        code == 0 and out == "" and age_s and age_s > 3600 - 120 - 60 and age_s < 3600 - 120 + 60, tostring(age_s) .. " " .. out)
end)

section("memo maintain --all: one time box for the whole run; the scopes left over are said", function()
    setup({})
    -- `memo maintain --scope A --all` in this process, with maintenance.due_scopes answering `due` and the first scope
    -- using up the whole box → the scopes it ran, the deadline it was given, the start time, what it printed
    local function box_run(args, due)
        local clock, ran, deadline, printed = os.time(), {}, nil, {}
        local start = clock
        H.with(os, "time", function() return clock end, function()
            H.with(maintenance, "due_scopes", function() return due end, function()
                H.with(maintenance, "run", function(scope, _, o)
                    ran[#ran + 1] = scope; deadline = o.deadline
                    clock = clock + 5000
                    return {}
                end, function()
                    H.with(io, "write", function(...) for _, s in ipairs({ ... }) do printed[#printed + 1] = tostring(s) end end, function()
                        require("luamemo.cli.maintain").run(args)
                    end)
                end)
            end)
        end)
        return ran, deadline, start, table.concat(printed)
    end
    local ran, deadline, start, text = box_run({ "--scope", "repo:bg-box-a", "--all", "--max-seconds", "60" }, { "repo:bg-box-b" })
    check("the CLI hands maintenance.run ONE deadline (max-seconds from the start of the run), not a per-scope budget",
        deadline == start + 60 and #ran == 1 and ran[1] == "repo:bg-box-a", ("%s ran=%s"):format(tostring(deadline), table.concat(ran, ",")))
    check("… the scope after it is not run, and it says so (one scope left: singular)",
        text:find("time box over: 1 scope left for the next run", 1, true) ~= nil, text)
    local _, _, _, text2 = box_run({ "--scope", "repo:bg-box-a", "--all", "--max-seconds", "60" }, { "repo:bg-box-b", "repo:bg-box-c" })
    check("… two scopes left: plural", text2:find("time box over: 2 scopes left for the next run", 1, true) ~= nil, text2)
    local _, deadline3, start3 = box_run({ "--scope", "repo:bg-box-a", "--all" }, { "repo:bg-box-b" })
    check("without --max-seconds the box is the default one", deadline3 == start3 + maintenance.MAX_SECONDS, tostring(deadline3))
    setup({})
end)

section("the time box reaches the digest's review", function()
    setup({})
    H.with(os, "time", function() return 1000 end, function()
        check("maintenance.deadline: max_seconds from now; the default box when none is given or it is not a number",
            maintenance.deadline(30) == 1030 and maintenance.deadline("45") == 1045
            and maintenance.deadline(nil) == 1000 + maintenance.MAX_SECONDS and maintenance.deadline("abc") == 1000 + maintenance.MAX_SECONDS)
    end)
    local seen
    H.with(fold, "run", function(_, opts) seen = opts; return { errors = {}, deleted = 0 } end, function()
        digest.run("repo:bg-dl", { deadline = 12345 })
    end)
    check("digest.run hands its deadline to the review at its end", seen and seen.deadline == 12345, seen and tostring(seen.deadline))
    local captured
    H.with(digest, "run", function(_, opts) captured = opts; return {} end, maintenance.run, "repo:bg-dl", { digest = true }, { max_seconds = 60 })
    check("maintenance.run gives the digest the run's deadline (max_seconds from now)",
        captured and captured.deadline and math.abs(captured.deadline - (os.time() + 60)) <= 2, captured and tostring(captured.deadline))
end)

os.execute("rm -rf " .. TMP)
finish()
