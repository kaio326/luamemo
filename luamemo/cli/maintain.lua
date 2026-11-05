-- luamemo.cli.maintain
--
-- `memo maintain [--scope S] [--all] [--digest] [--summarize] [--review] [--learn] [--quiet] [--max-seconds N]` — the
-- maintenance that runs beside the agent: the digest (tier promotion, observations), one bounded batch of summarizing,
-- the review of folded memories whose grace period is over (luamemo.fold) and the training of the scope's learned
-- reranker when it is due (MEMO_LEARN_INTERVAL_DAYS; promoted only if it beats the current ranking on held-out
-- data). A write that makes it due starts this as a background process, and so does the session brief, once a day,
-- for a review that is due or the usage log's prune (--quiet: once the run has started it prints nothing, whatever
-- happens — the result goes to <database>.maintenance.log, next to the database); run by hand it prints one line per
-- scope, and what went wrong.
--
--   --scope S       the scope (default: the project's)
--   --all           also every scope that has a review due
--   --digest --summarize --review --learn   only those parts (none: all four)
--   --max-seconds N no part is started after N seconds (900), and the review stops there
--
-- The time box is one for the whole run (MAX_SECONDS, 900, unless --max-seconds): when it runs out before every scope was
-- reached, the rest are left for the next run and by hand it says "time box over: N scopes left for the next run".
-- One run at a time per database (a second one exits at once; a lock file that cannot be made is an error, not a
-- second run). Quiet, a run that has started always exits 0 — nobody is there to read an error, and the log has it;
-- a bad option, or settings / a database that stop it from starting, still exit 2 on stderr (there is no log yet).

local M = {}

local USAGE = "usage: memo maintain [--scope SCOPE] [--all] [--digest] [--summarize] [--review] [--learn] [--quiet] [--max-seconds N]\n"

local die = require("luamemo.cli._common").die_for("maintain", 2)

-- Each part of a scope's run, as the words of the line `memo maintain` prints
local function digest_text(d)
    if not d then return "—" end
    if d.error then return "failed: " .. tostring(d.error) end
    return ("%d processed, %d folded memories deleted after review"):format(d.processed or 0, d.deleted or 0)
end
local function summarize_text(s)
    if not s then return "—" end
    if s.error then return "failed" end
    if s.skipped then return "skipped (" .. s.skipped .. ")" end
    return tostring(s.summarised or 0) .. " batch"
end
local function review_text(r, digest_ran)
    if not r then return digest_ran and "with the digest" or "—" end   -- (a digest ends with the review)
    if r.error then return "failed" end
    local kept = (r.kept or 0) > 0 and (", %d kept"):format(r.kept) or ""
    return ("%d reviewed (%d deleted, %d corrected, %d restored%s)"):format(r.reviewed or 0, r.deleted or 0, r.corrected or 0, r.restored or 0, kept)
end
local function learn_text(l)
    if l.error then return "failed: " .. tostring(l.error) end
    if l.decision then return l.decision .. (l.reason and (" — " .. tostring(l.reason)) or "") end
    return "not run (" .. tostring(l.skipped) .. ")"
end

-- What one scope's run did, as lines on stdout
local function report(maintenance, scope, res)
    io.write(("%s: digest %s · summarized %s · review %s\n"):format(scope,
        digest_text(res.digest), summarize_text(res.summarize), review_text(res.review, res.digest ~= nil)))
    local problems = maintenance.problems(res)
    if problems then
        io.write(("%s: %d thing%s went wrong (the maintenance log has them); the first: %s\n"):format(scope,
            #problems, #problems == 1 and "" or "s", problems[1]))
    end
    if res.learn then io.write(("%s: learned reranker %s\n"):format(scope, learn_text(res.learn))) end
end

local function usage() io.stderr:write(USAGE); os.exit(2) end

function M.run(argv)
    local opts, what, quiet = {}, {}, false
    local any = false
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--scope" then
            opts.scope = argv[i + 1]
            if not opts.scope or opts.scope == "" or opts.scope:sub(1, 2) == "--" then usage() end
            i = i + 2
        elseif a == "--max-seconds" then
            opts.max_seconds = tonumber(argv[i + 1])
            -- (a number that is positive and finite: tonumber also reads "nan" and "inf")
            if not opts.max_seconds or not (opts.max_seconds > 0 and opts.max_seconds < math.huge) then usage() end
            i = i + 2
        elseif a == "--all" then opts.all = true; i = i + 1
        elseif a == "--quiet" then quiet = true; i = i + 1
        elseif a == "--digest" then what.digest = true; any = true; i = i + 1
        elseif a == "--summarize" then what.summarize = true; any = true; i = i + 1
        elseif a == "--review" then what.review = true; any = true; i = i + 1
        elseif a == "--learn" then what.learn = true; any = true; i = i + 1
        elseif a == "-h" or a == "--help" then io.write(USAGE); return
        else usage() end
    end
    if not any then what = nil end

    local fold = require("luamemo.fold")
    local ok, err = pcall(function()
        -- (no_embed: no embedder probe — most runs find nothing to do, and the model loads when something needs it)
        local lm = require("luamemo.cli._common").setup_or_die(die, { no_embed = true })
        local maintenance = require("luamemo.maintenance")
        local locked, cannot = maintenance.lock()
        if not locked then
            -- (a run started by a write holds claims on the digest / summary slots: they come due again in a couple
            -- of minutes, or what was due waits a whole interval for a run that never happened — and not at once, or
            -- the very next write starts another process that finds the lock held too)
            if what then maintenance.defer(what, opts.scope or lm.config.default_scope) end
            if cannot then   -- not a run in progress: nothing can run until the lock file can be made
                fold.log({ run = "maintain", error = cannot, scope = opts.scope })
                if not quiet then die(cannot, 1) end
                return
            end
            fold.log({ run = "maintain", skipped = "another run holds the lock", scope = opts.scope })
            if not quiet then io.write("another maintenance run is in progress\n") end
            return
        end
        local ok_run, err_run = pcall(function()
            local scopes, seen = {}, {}
            local function add(s) if s and s ~= "" and not seen[s] then seen[s] = true; scopes[#scopes + 1] = s end end
            add(opts.scope or lm.config.default_scope)
            if opts.all then for _, s in ipairs(maintenance.due_scopes()) do add(s) end end
            -- one time box for the whole run, however many scopes it takes (the lock is held for all of it)
            local deadline = maintenance.deadline(opts.max_seconds)
            for n, scope in ipairs(scopes) do
                if os.time() >= deadline then
                    local left = #scopes - n + 1
                    if not quiet then io.write(("time box over: %d scope%s left for the next run\n"):format(left, left == 1 and "" or "s")) end
                    break
                end
                local res = maintenance.run(scope, what, { deadline = deadline })
                if not quiet then report(maintenance, scope, res) end
            end
        end)
        maintenance.unlock()
        if not ok_run then error(err_run, 0) end
    end)
    if not ok then
        fold.log({ run = "maintain", error = tostring(err), scope = opts.scope })
        if not quiet then die(tostring(err), 1) end
    end
end

return M
