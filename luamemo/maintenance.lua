-- luamemo.maintenance
--
-- Maintenance that happens beside the agent, never in its way: the digest (tier promotion, observations), a
-- bounded batch of summarizing, the review of folded memories (luamemo.fold), the learned reranker's training and the
-- usage log's retention. A write used to run these inside itself — with a language model behind the summarizer that
-- is a call of tens of seconds in the middle of the agent's memory_write. Now the write only CLAIMS the slot (an
-- atomic row, so at most one run per interval per scope) and starts `memo maintain` as a separate process: detached,
-- its output thrown away (an MCP server's stdout is the protocol; nothing a background job says may reach it), and it
-- returns at once. If the process cannot be started the claim is given back, so the next write tries again, and
-- nothing is raised.
--
-- Scheduled work is the one nobody asked for at that moment, so it only uses a model that runs on this machine
-- (gguf, or none): a remote summarizer (openai, an ollama on another host) is used by what the user calls —
-- memory_summarize, memo consolidate — and never in the background.
--
--   after_write(scope, cfg)      what store.write calls: claim the due slots, start ONE process for them → result | false
--   dispatch(what, scope, opts)  run now (MEMO_MAINTENANCE_BACKGROUND=false) or start the process → result | false
--   spawn(scope, what)           start `memo maintain` → true | false
--   claim(tbl, key_col, stamp_col, key, interval_s)   an atomic "at most once per interval" slot → true for the one winner
--   claim_slot(name, scope)      the same for a scope's "digest" / "summarize" slot; its interval is the slot's setting
--                                (SLOTS says where each lives and which setting)
--   release(what, scope)         give a claimed slot back (the process did not start)
--   defer(what, scope)           try a claimed slot again in a couple of minutes (another run holds the lock)
--   run(scope, what, opts)       the work itself (what `memo maintain` does) → { scope, skipped | digest, summarize, review,
--                                learn, pruned, prune_error }; opts.max_seconds | opts.deadline: its time box
--   deadline(max_seconds)        the time a box of max_seconds (MAX_SECONDS, 900, when none) ends at — one for a whole
--                                run of several scopes
--   problems(out)                what went wrong in a run (a part that raised, rows that failed, the usage log's prune)
--                                → a list of texts | nil
--   cloexec(sock)                keep a luasocket socket from the processes this one starts (a server's)
--   learn(scope)                 train the scope's learned reranker if it is due (MEMO_LEARN_INTERVAL_DAYS)
--   lock() / unlock()            one run at a time per database: an flock on <db>.maintenance.lock, held by the running
--                                process and released by the kernel when it ends (a crash leaves nothing to clean up);
--                                lock() → true | false (another run holds it) | false, why (the lock file cannot be made)
--   due_scopes()                 the scopes whose folded memories are due for review (the set fold.run itself takes)
--   kick(scope)                  what the session brief calls, once a day: start the review of what is due, else — usage
--                                log on, retention > 0 — a run for `scope` that ends with the log's prune
--   local_model(cfg)             is the summarizer a model on this machine? (scheduled work needs it)
--
-- what = { digest, summarize, review, learn, all } (booleans). Named nothing, run() does digest, summarize, review
-- and learn; a summarize run also reviews what is due, a digest run ends with the review itself.

local db       = require("luamemo.db")
local util     = require("luamemo.util")
local policy   = require("luamemo.federation.policy")
local settings = require("luamemo.settings")
local fold     = require("luamemo.fold")
local feedback = require("luamemo.feedback")

local M = {}

local cfg = {}
function M.configure(c) cfg = c or {} end

M.spawner = nil   -- (tests: function(scope, what) → true | false, in place of starting a process)

M.MAX_SECONDS = 900   -- a run's time box (seconds), unless it is given another
local RETRY_S = 120   -- a slot that found the lock held comes due again this soon

function M.background()
    return cfg.maintenance_background ~= false
end

--- The time a run's box ends at (an os.time()): max_seconds from now, MAX_SECONDS when none is given.
function M.deadline(max_seconds)
    return os.time() + (tonumber(max_seconds) or M.MAX_SECONDS)
end

--- The summarizers whose model runs on this machine (a remote one is never used by scheduled work).
local LOCAL_ADAPTERS = { gguf = true, noop = true }
function M.local_model(c)
    return LOCAL_ADAPTERS[require("luamemo.summarizers._common").adapter_name(c)] == true
end

-- ── slots ────────────────────────────────────────────────────────────────────

-- A microsecond time as the text a stamp column holds (not tostring: a number this large prints as 1.79e+15)
local function us_text(us) return ("%.0f"):format(us) end

--- Take a time slot at most once per interval → true for the ONE caller that wins it. Atomic (an upsert whose WHERE
--- lets only the first caller past the interval through), so any number of writes and processes race safely.
--- `tbl` is an internal table with a unique key_col and a stamp_col holding microseconds.
function M.claim(tbl, key_col, stamp_col, key, interval_s)
    local now = util.now_us()
    local due_before = now - math.max(0, tonumber(interval_s) or 0) * 1000000
    -- (a read first: a slot that is not due — nearly every call — takes no write lock)
    if db.first(("SELECT 1 AS x FROM %s WHERE %s = ? AND CAST(%s AS INTEGER) > ?"):format(tbl, key_col, stamp_col), key, due_before) then
        return false
    end
    local row = db.first(("INSERT INTO %s (%s, %s) VALUES (?, ?) ON CONFLICT (%s) DO UPDATE SET %s = excluded.%s "
        .. "WHERE CAST(%s.%s AS INTEGER) <= ? RETURNING %s"):format(tbl, key_col, stamp_col, key_col, stamp_col, stamp_col,
        tbl, stamp_col, key_col),
        key, us_text(now), due_before)
    return row ~= nil   -- (nil: not due, or lost the race)
end

-- The two slots a write can claim, per scope: where each is kept (table, and the column that holds the time of the
-- last claim) and which setting gives its interval (seconds).
M.SLOTS = {
    digest    = { tbl = "lm_digest_state",    col = "last_digested_at",   interval = "auto_digest_interval" },
    summarize = { tbl = "lm_summarize_state", col = "last_summarized_at", interval = "summarizer_interval_seconds" },
}

--- Claim the named slot ("digest" | "summarize") of a scope → true for the one caller that wins it. Its interval is
--- the slot's setting (SLOTS), read from the one config — claim, defer and the write's check cannot disagree.
function M.claim_slot(name, scope)
    local s = M.SLOTS[name]
    return M.claim(s.tbl, "scope", s.col, scope, settings.number(cfg, s.interval))
end

-- Stamp the slots `what` names for a scope with value_of(slot) (a failure to write one is not worth stopping for)
local function stamp_slots(what, scope, value_of)
    for name, s in pairs(M.SLOTS) do
        if what[name] then pcall(db.run, ("UPDATE %s SET %s = ? WHERE scope = ?"):format(s.tbl, s.col), value_of(s), scope) end
    end
end

--- Give a claimed slot back (the process did not start), so the next write can try again.
function M.release(what, scope)
    stamp_slots(what, scope, function() return 0 end)
end

--- A run found the lock held — another run is at work. Its slots come due again in RETRY_S seconds, not at once:
--- handing them back at once would have the very next write start another process that finds the lock held too.
function M.defer(what, scope)
    stamp_slots(what, scope, function(s)
        local interval_s = settings.number(cfg, s.interval) or 0
        return us_text(util.now_us() - math.max(0, interval_s - RETRY_S) * 1000000)
    end)
end

-- ── starting the process ─────────────────────────────────────────────────────

local function flags(what)
    local out = {}
    if what.digest then out[#out + 1] = "--digest" end
    if what.summarize then out[#out + 1] = "--summarize" end
    if what.review then out[#out + 1] = "--review" end
    if what.learn then out[#out + 1] = "--learn" end
    if what.all then out[#out + 1] = "--all" end
    return out
end
M._flags = flags   -- (tests)

local setsid
local function have_setsid()
    if setsid == nil then setsid = os.execute("command -v setsid >/dev/null 2>&1") == 0 end
    return setsid
end

--- Start `memo maintain` for a scope, detached → true | false. Nothing it prints reaches this process.
function M.spawn(scope, what)
    if M.spawner then return M.spawner(scope, what) end
    if (os.getenv("MEMO_NO_MAINTENANCE") or "") ~= "" then return true end   -- (benchmarks, tests: no real process)
    local bin = os.getenv("MEMO__BIN")
    if bin == nil or bin == "" then bin = "memo" end
    local parts = { util.shell_quote(bin), "maintain", "--scope", util.shell_quote(scope), "--quiet" }
    for _, f in ipairs(flags(what)) do parts[#parts + 1] = f end
    local project = os.getenv("MEMO__PROJECT_DIR")
    local env = (project and project ~= "") and ("MEMO_PROJECT=" .. util.shell_quote(project) .. " ") or ""
    -- a subshell that backgrounds the job: it is not this process's child to wait for; stdin, stdout and stderr go nowhere,
    -- and neither do descriptors 3 to 9 (a shell cannot close "all above"): luasocket opens its sockets without
    -- close-on-exec, and a run that kept a server's listening socket would hold the port for as long as it lives. The
    -- server marks the higher ones itself (M.cloexec).
    local cmd = "(" .. env .. (have_setsid() and "setsid " or "") .. table.concat(parts, " ")
        .. " </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &)"
    local ok = os.execute(cmd)
    return ok == 0 or ok == true
end

--- Is the scheduled summary on, and possible (a model on this machine)? c: a config.
local function scheduled_summaries(c)
    return (settings.number(c, M.SLOTS.summarize.interval) or 0) > 0 and M.local_model(c)
end

local busy = false
--- What a write does about maintenance: claim whichever slots are due — the digest, the scheduled summary — and, if it
--- won any, start ONE process for all of them (two processes would race for the lock, and the loser's slot would be
--- spent for nothing). c: the store's config. → the dispatch's result | false. Never raises, and never stays busy.
function M.after_write(scope, c)
    if busy or not scope or scope == "" then return false end
    busy = true
    local what = {}
    local ok, res = pcall(function()
        if c.auto_digest_enabled and require("luamemo.digest").claim(scope) then what.digest = true end
        if scheduled_summaries(c) and require("luamemo.summarizer").claim(scope) then what.summarize = true end
        if what.digest or what.summarize then return M.dispatch(what, scope, {}) end
        return false
    end)
    busy = false
    if not ok then
        -- an error after a claim: the slot goes back (or the hour's work is lost for nothing), and the failure leaves a trace
        M.release(what, scope)
        fold.log({ run = "after_write", scope = scope, error = tostring(res) })
        return false
    end
    return res
end

--- A claimed slot's work: start it in the background (default) or do it here → the result of the run, or
--- { spawned = true }, or false when the process could not be started (the slot is given back).
function M.dispatch(what, scope, opts)
    if not M.background() then
        return M.run(scope, what, opts)
    end
    if M.spawn(scope, what) then return { spawned = true } end
    M.release(what, scope)
    return false
end

-- ── one run at a time ────────────────────────────────────────────────────────

--- The lock of THIS database (<file>.maintenance.lock): one project's run must not hold another project's up — the
--- data directory holds them all.
function M.lock_path()
    return db.sibling(".maintenance.lock")
end

-- The lock is an flock(2) on that file, held on a descriptor of the running process: the kernel releases it when the
-- process ends, however it ends, so there is no stale lock to take over, no timestamp to judge, and no way for two
-- runs to hold it (unlike a lock directory, which a crashed run leaves behind).
local lock_ffi
do
    local ok, ffi = pcall(require, "ffi")
    if ok and pcall(ffi.cdef, "int open(const char *path, int flags, ...); int close(int fd); int flock(int fd, int operation);"
        .. " int fcntl(int fd, int cmd, ...);") then lock_ffi = ffi end
end
local O_RDWR, LOCK_EX_NB, F_SETFD, FD_CLOEXEC = 2, 2 + 4, 2, 1   -- (the same numbers on Linux and macOS)
local held   -- the descriptor that holds this process's lock

-- Keep a descriptor from the processes this one starts (fcntl is variadic: the flag goes in as an int) → true | false
local function set_cloexec(fd)
    return lock_ffi.C.fcntl(fd, F_SETFD, lock_ffi.cast("int", FD_CLOEXEC)) == 0
end

--- Keep a luasocket socket from the processes this one starts: luasocket opens its sockets without close-on-exec, and
--- a `memo maintain` that inherited one would hold a listening port, or a connection the peer is waiting to see closed,
--- for as long as it lives (spawn closes the low descriptors itself; a busy server's are higher) → true | false
function M.cloexec(sock)
    if not lock_ffi or not sock then return false end
    local fd = sock:getfd()
    return fd >= 0 and set_cloexec(fd)
end

--- Take the lock → true | false (another run holds it) | false, why (the lock file cannot be made or opened: no run
--- is at work, and none can start until that is fixed — not a busy lock to wait out).
function M.lock()
    if held then return false end   -- (this process has it: a second take is "another run")
    if not lock_ffi then return true end   -- (no FFI: nothing to lock with — luamemo's database needs it anyway)
    local path = M.lock_path()
    local function create()   -- private, like the database; just to be there to open
        local f = util.with_umask("077", io.open, path, "a")
        if f then f:close() end
        return f ~= nil
    end
    local function cannot() return false, "the lock file " .. path .. " cannot be created or opened" end
    if not create() then
        -- a lock DIRECTORY from the first 0.5.2 builds sits at that name: it is not a lock any more
        if not util.is_dir(path) then return cannot() end
        os.execute("rm -rf " .. util.shell_quote(path))
        if not create() then return cannot() end
    end
    local fd = lock_ffi.C.open(path, O_RDWR)
    if fd < 0 then return cannot() end
    -- (not inherited: a child this run starts must not keep the lock alive after the run is gone)
    set_cloexec(fd)
    if lock_ffi.C.flock(fd, LOCK_EX_NB) ~= 0 then lock_ffi.C.close(fd); return false end
    held = fd
    return true
end

--- Let go of the lock (closing the descriptor releases it; so does the process ending).
function M.unlock()
    if held then lock_ffi.C.close(held); held = nil end
end

-- ── the work ─────────────────────────────────────────────────────────────────

--- The scopes that have folded memories whose review is due.
function M.due_scopes()
    local due, p1, p2 = fold.due_clause(util.now_us())   -- (the review's own definition of "due")
    local rows = db.query("SELECT DISTINCT scope FROM lm_memories WHERE " .. policy.NOT_CODEINDEX_SQL .. " AND " .. due, p1, p2) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.scope end
    return out
end

--- Start the review of whatever is due, in any scope, at most once a day → true | false. A folded memory is reviewed
--- when a write makes its scope's maintenance due; in a scope nobody writes to any more that never comes, and the
--- one thing every session does is start with a brief — so the brief asks. Asked today already: nothing (and the
--- table is not looked at). `scope` (the brief's) is where the usage log's daily prune runs when no review is due:
--- a search never runs it itself (it would wait for it), and a session that only reads writes nothing either.
function M.kick(scope)
    if not M.background() then return false end
    if not M.claim("lm_meta", "key", "value", "maintain_kick", util.DAY_S) then return false end
    local due = M.due_scopes()
    local target, what = due[1], { review = true, all = true }
    if not target and cfg.feedback_enabled and feedback.retention_days(cfg) > 0 and scope and scope ~= "" then
        target, what = scope, { review = true }   -- (every run ends with the log's prune)
    end
    if not target then return false end
    if M.spawn(target, what) then return true end
    pcall(db.run, "DELETE FROM lm_meta WHERE key = 'maintain_kick'")   -- not started: the next brief asks again
    return false
end

-- A part of a run, never raising → its result | { error = text } (what went wrong is the part's own, in the run's result)
local function attempt(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok and type(res) == "table" then return res end
    return { error = ok and "returned nothing" or tostring(res) }
end

--- Train the scope's learned reranker if it is due → { decision, … } | { skipped = why } | { error }.
--- At most once per MEMO_LEARN_INTERVAL_DAYS per scope (stamped in lm_meta whether or not there was enough to learn
--- from — a scope with too few outcomes is looked at weekly, not hourly). luamemo.promote does the rest: it trains on
--- the usage log, compares with the current ranking on held-out outcomes, and promotes only if the new one is better.
function M.learn(scope)
    -- (only where the learned reranker is the one in use, and there is a usage log to learn from: a model trained
    -- for a ranking nobody applies is work for nothing)
    if cfg.learn_auto == false or not cfg.feedback_enabled or cfg.rerank_adapter ~= "learned" then return { skipped = "off" } end
    local why = policy.maintenance_skip(scope)
    if why then return { skipped = why } end
    local days = settings.number(cfg, "learn_interval_days")
    if not M.claim("lm_meta", "key", "value", "learn_last:" .. scope, days * util.DAY_S) then return { skipped = "not due" } end
    local res = attempt(require("luamemo.promote").run, scope, {})
    if res.error then return res end
    return { decision = res.decision, reason = res.reason, new_score = res.new_score, incumbent_score = res.incumbent_score,
             n_train = res.n_train, n_gate = res.n_gate, version = res.version }
end

--- Everything that went wrong in a run, as a list of texts | nil: a part that raised (.error) and the rows or
--- clusters that failed inside one (.errors), the reranker's training that failed, the usage log's prune that failed.
function M.problems(out)
    local list = {}
    for _, part in ipairs({ out.digest or false, out.summarize or false, out.review or false, out.learn or false }) do
        if type(part) == "table" then
            if part.error then list[#list + 1] = tostring(part.error) end
            for _, e in ipairs(part.errors or {}) do list[#list + 1] = tostring(e) end
        end
    end
    if out.prune_error then list[#list + 1] = "usage log prune: " .. out.prune_error end
    return #list > 0 and list or nil
end

--- What `memo maintain` does for one scope. what: nothing given = all of it (digest, summarize, review, learn).
--- opts.max_seconds (900) or opts.deadline (an os.time(): one box for several scopes): no part is started after that
--- long, and the review stops at it; a part in progress (a summarizer batch, the digest's clustering) finishes.
--- opts.digest: options handed to the digest run (a remote summarizer's `no_llm` is added to them).
--- → { scope, skipped | digest = result|{ error }, summarize = …, review = fold's result, learn, pruned, prune_error }
function M.run(scope, what, opts)
    opts = opts or {}
    if not what or not (what.digest or what.summarize or what.review or what.learn) then
        what = { digest = true, summarize = true, review = true, learn = true }
    end
    local out = { scope = scope }
    out.skipped = policy.maintenance_skip(scope)
    if out.skipped then return out end
    local deadline = tonumber(opts.deadline) or M.deadline(opts.max_seconds)
    local remote = not M.local_model(cfg)   -- a remote summarizer is for what the user asks, not for this
    if what.digest then
        local dopts = {}
        for k, v in pairs(opts.digest or {}) do dopts[k] = v end
        if remote then dopts.no_llm = true end
        dopts.deadline = deadline   -- (the review at the end of the digest stops there, like the standalone one)
        out.digest = attempt(require("luamemo.digest").run, scope, dopts)   -- (digest.run ends with the review of what is due)
    end
    if what.summarize and remote then
        out.summarize = { skipped = "remote summarizer" }
    elseif what.summarize and os.time() < deadline then
        -- one batch: the model is slow, and the next run takes the next one
        out.summarize = attempt(require("luamemo.summarizer").run, { scope = scope, max_batches = 1 })
    end
    if (what.review or what.summarize) and not what.digest and os.time() < deadline then
        out.review = attempt(fold.run, scope, { deadline = deadline })
    end
    -- the learned reranker: with the digest (the hourly run) or when asked; throttled to MEMO_LEARN_INTERVAL_DAYS
    if (what.learn or what.digest) and os.time() < deadline then
        out.learn = M.learn(scope)
    end
    -- the usage log's retention: once a day per database, whichever scope's run gets there first
    local okp, pruned, perr = pcall(feedback.prune_daily)
    out.pruned = okp and pruned or nil
    if not okp then out.prune_error = tostring(pruned) elseif pruned == nil and perr then out.prune_error = tostring(perr) end
    local function n(t, k) return t and tonumber(t[k]) or 0 end
    fold.log({ run = "maintain", scope = scope, digest = what.digest or nil, summarize = what.summarize or nil,
        remote_summarizer = (remote and what.summarize) or nil, log_pruned = out.pruned,
        digest_processed = n(out.digest, "processed"), digest_deleted = n(out.digest, "deleted"),
        summarised = n(out.summarize, "summarised"), reviewed = n(out.review, "reviewed"),
        deleted = n(out.review, "deleted"), corrected = n(out.review, "corrected"), restored = n(out.review, "restored"),
        kept = n(out.review, "kept"),
        learn = out.learn and (out.learn.decision or out.learn.skipped or out.learn.error) or nil,
        learn_new = out.learn and out.learn.new_score or nil, learn_incumbent = out.learn and out.learn.incumbent_score or nil,
        errors = M.problems(out) })
    return out
end

return M
