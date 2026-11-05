-- luamemo.cli.usage
--
-- `memo usage [--scope S] [--days N] [--gap SECONDS] [--json]` — what the usage log says about how
-- this project's memory is really used. It only reads. No question has a known right answer in real
-- use, so these are signals, not recall:
--   * searches logged (MEMO_FEEDBACK_ENABLED), how many per day, and how many found nothing (a search is kept
--     MEMO_FEEDBACK_RETENTION_DAYS; a log of gaps, never a memory — see luamemo.feedback);
--   * follow-ups: a search in the same scope within --gap seconds (default 120) of the one before —
--     asked again as it was (repeat) or in other words (reworded: at least half of the words shared),
--     which is what an agent does when the first answer did not help;
--   * what the person said afterwards (lm_reinforcements): praise / direct_command (the memory helped),
--     mistake (it misled), reversal, and miss — recorded when a near-duplicate of a memory is written (the
--     memory was there to be found), whether or not a search came first;
--   * where a memory that was confirmed useful stood in the search that offered it (its rank).
-- A search nobody commented on is not a failed one: read the rates against each other and over time.

local M = {}

local USAGE = "usage: memo usage [--scope SCOPE] [--days N] [--gap SECONDS] [--json]\n"

local die = require("luamemo.cli._common").die_for("usage", 2)

local feedback = require("luamemo.feedback")
local DAY_US = require("luamemo.util").DAY_US
local EMPTIES = "sum(candidate_ids = '" .. feedback.EMPTY .. "')"   -- (how many searches found nothing)

-- The words of a question (lower case, three letters or more) as a set.
local function words(q)
    local set, n = {}, 0
    for w in tostring(q):lower():gmatch("[%w_]+") do
        if #w >= 3 and not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end

-- Share of the smaller question's words that the other has too.
local function overlap(a, b)
    local sa, na = words(a)
    local sb, nb = words(b)
    local small = math.min(na, nb)
    if small == 0 then return 0 end
    local shared = 0
    for w in pairs(sa) do if sb[w] then shared = shared + 1 end end
    return shared / small
end

local function pct(n, d) return d > 0 and (100 * n / d) or 0 end

M.MIN_SEARCHES = 30   -- below this, the rates are anecdotes: the report says so

--- → the report (a table) for the window. Pure over the database: opts = { scope, days, gap }.
function M.report(db, opts)
    opts = opts or {}
    local now = require("luamemo.util").now_us()
    local days = tonumber(opts.days) or 30
    local gap_us = (tonumber(opts.gap) or 120) * 1000000
    local since = now - days * DAY_US
    local scope_sql, scope_args = "", {}
    if opts.scope then scope_sql = " AND scope = ?"; scope_args = { opts.scope } end
    local function args(...)
        local a = { ... }
        for _, s in ipairs(scope_args) do a[#a + 1] = s end
        return a
    end

    local r = { days = days, gap_s = gap_us / 1000000, scope = opts.scope }
    local first = db.query("SELECT count(*) AS n, min(created_at) AS t0, max(created_at) AS t1, "
        .. EMPTIES .. " AS empty FROM lm_retrieval_feedback WHERE created_at >= ?" .. scope_sql,
        unpack(args(since)))[1] or {}
    r.searches, r.empty = tonumber(first.n) or 0, tonumber(first.empty) or 0
    if r.searches > 0 then
        r.first_at, r.last_at = tonumber(first.t0), tonumber(first.t1)
        r.span_days = math.max((r.last_at - r.first_at) / DAY_US, 1)
        r.searches_per_day = r.searches / r.span_days
    end

    -- follow-ups, in the order the searches were made
    local rows = db.query("SELECT scope, query, created_at FROM lm_retrieval_feedback WHERE created_at >= ?" .. scope_sql
        .. " ORDER BY scope, created_at, id LIMIT 200000", unpack(args(since))) or {}
    r.follow_ups, r.repeats, r.reworded = 0, 0, 0
    for i = 2, #rows do
        local a, b = rows[i - 1], rows[i]
        if a.scope == b.scope and tonumber(b.created_at) - tonumber(a.created_at) <= gap_us then
            r.follow_ups = r.follow_ups + 1
            if a.query == b.query then r.repeats = r.repeats + 1
            elseif overlap(a.query, b.query) >= 0.5 then r.reworded = r.reworded + 1 end
        end
    end

    -- what was said afterwards
    r.reinforcements = {}
    for _, e in ipairs(db.query("SELECT event_type, count(*) AS n FROM lm_reinforcements WHERE created_at >= ?" .. scope_sql
        .. " GROUP BY event_type", unpack(args(since))) or {}) do
        r.reinforcements[e.event_type] = tonumber(e.n)
    end
    -- a miss is a near-duplicate being written again; whether a search had run first says whose miss it was
    r.miss_kinds = { other = 0 }
    for _, k in ipairs(feedback.MISS_KINDS) do r.miss_kinds[k] = 0 end
    for _, e in ipairs(db.query("SELECT note, count(*) AS n FROM lm_reinforcements WHERE event_type = 'miss' AND created_at >= ?"
        .. scope_sql .. " GROUP BY note", unpack(args(since))) or {}) do
        local kind = feedback.parse_miss_note(e.note) or "other"
        r.miss_kinds[kind] = r.miss_kinds[kind] + (tonumber(e.n) or 0)
    end

    -- where a memory confirmed useful stood in the latest search that offered it
    local conf = db.query("SELECT (SELECT c.rank FROM lm_retrieval_candidates c JOIN lm_retrieval_feedback f ON f.id = c.feedback_id "
        .. "WHERE c.memory_id = r.memory_id AND f.scope = r.scope AND f.created_at <= r.created_at "
        .. "ORDER BY f.created_at DESC LIMIT 1) AS rank FROM lm_reinforcements r "
        .. "WHERE r.event_type IN " .. feedback.POSITIVE_SQL .. " AND r.created_at >= ?"
        .. (opts.scope and " AND r.scope = ?" or ""), unpack(args(since))) or {}
    local c = { n = #conf, rank1 = 0, top3 = 0, top10 = 0, unseen = 0, rr = 0 }
    for _, x in ipairs(conf) do
        local rank = tonumber(x.rank)
        if not rank then c.unseen = c.unseen + 1
        else
            if rank == 1 then c.rank1 = c.rank1 + 1 end
            if rank <= 3 then c.top3 = c.top3 + 1 end
            if rank <= 10 then c.top10 = c.top10 + 1 end
            c.rr = c.rr + 1 / rank
        end
    end
    c.mrr = c.n > 0 and c.rr / c.n or nil
    c.rr = nil
    r.confirmed = c

    -- the learned reranker: what the background training did, and where a model is in use
    local l = { attempts = 0, promoted = 0, rejected = 0, skipped = 0 }
    for _, e in ipairs(db.query("SELECT decision, count(*) AS n FROM lm_promotion_runs WHERE created_at >= ?" .. scope_sql
        .. " GROUP BY decision", unpack(args(since))) or {}) do
        local n = tonumber(e.n) or 0
        l.attempts = l.attempts + n
        if e.decision == "promote" then l.promoted = n elseif e.decision == "reject" then l.rejected = n else l.skipped = l.skipped + n end
    end
    l.scopes_with_model = tonumber(db.value("SELECT count(DISTINCT scope) FROM lm_learner_weights WHERE is_current = 1 AND kind = 'reranker'"
        .. scope_sql, unpack(args()))) or 0
    r.learned = l

    r.by_scope = {}
    for _, s in ipairs(db.query("SELECT scope, count(*) AS n, " .. EMPTIES .. " AS empty FROM lm_retrieval_feedback "
        .. "WHERE created_at >= ?" .. scope_sql .. " GROUP BY scope ORDER BY n DESC LIMIT 8", unpack(args(since))) or {}) do
        r.by_scope[#r.by_scope + 1] = { scope = s.scope, searches = tonumber(s.n), empty = tonumber(s.empty) or 0 }
    end
    return r
end

local function text(r)
    local out = {}
    local function put(...) out[#out + 1] = table.concat({ ... }) end
    put(("usage log, last %d days%s"):format(r.days, r.scope and (" · scope " .. r.scope) or ""))
    if r.retention_days then
        put(r.retention_days > 0
            and ("the log keeps a search %d days (MEMO_FEEDBACK_RETENTION_DAYS), longer for the newest %d that offered a memory with a recorded reinforcement")
                :format(r.retention_days, feedback.KEEP_PER_REINFORCED)
            or "the log keeps every search (MEMO_FEEDBACK_RETENTION_DAYS=0)")
        if r.retention_days > 0 and r.days > r.retention_days then
            put(("  (asked for %d days, so older searches are not there)"):format(r.days))
        end
    end
    if r.searches == 0 then
        put("no searches logged.")
        put("the log is off by default: memo config set MEMO_FEEDBACK_ENABLED true (it keeps the text of each search in this database)")
        return table.concat(out, "\n")
    end
    put(("searches:        %d  (%.1f a day over %.0f days) · found nothing %d (%.1f %%)"):format(
        r.searches, r.searches_per_day, r.span_days, r.empty, pct(r.empty, r.searches)))
    put(("follow-ups:      %d (%.1f %%) within %d s of the search before — asked again as it was %d, in other words %d"):format(
        r.follow_ups, pct(r.follow_ups, r.searches), r.gap_s, r.repeats, r.reworded))
    local rf = r.reinforcements
    put(("said afterwards: praise %d · direct_command %d · mistake %d · miss (near-duplicate written) %d · reversal %d"):format(
        rf.praise or 0, rf.direct_command or 0, rf.mistake or 0, rf.miss or 0, rf.reversal or 0))
    local mk = r.miss_kinds
    if (rf.miss or 0) > 0 then
        put(("  the misses: the ranking missed it %d (a search ran and did not offer it) · offered but written again anyway %d · "
            .. "no search first %d%s"):format(mk["not-offered"], mk.offered, mk["no-search"],
            mk.other > 0 and (" · before this was recorded %d"):format(mk.other) or ""))
    end
    put(("per 100 searches: praise %.1f · mistake %.1f · miss %.1f"):format(
        100 * (rf.praise or 0) / r.searches, 100 * (rf.mistake or 0) / r.searches, 100 * (rf.miss or 0) / r.searches))
    if r.searches < M.MIN_SEARCHES then
        put(("  (only %d searches: too few to read the rates above as rates — a single event moves them by %.0f points; the counts are exact)")
            :format(r.searches, 100 / r.searches))
    end
    local c = r.confirmed
    if c.n > 0 then
        put(("confirmed useful: %d · first in the results %.0f %% · in the first three %.0f %% · in the first ten %.0f %% · "
            .. "not in the latest search %.0f %% · MRR %s"):format(c.n, pct(c.rank1, c.n), pct(c.top3, c.n), pct(c.top10, c.n),
            pct(c.unseen, c.n), c.mrr and ("%.2f"):format(c.mrr) or "—"))
    else
        put("confirmed useful: none yet (praise and direct_command come from memory_sense)")
    end
    local l = r.learned
    if l and (l.attempts > 0 or l.scopes_with_model > 0) then
        put(("learned reranker: %d training attempts (%d promoted, %d rejected by the gate, %d without enough to learn from) · %d scopes with a model in use"):format(
            l.attempts, l.promoted, l.rejected, l.skipped, l.scopes_with_model))
    end
    if #r.by_scope > 1 then
        put("by scope:")
        for _, s in ipairs(r.by_scope) do put(("  %-36s %6d searches · %d found nothing"):format(s.scope, s.searches, s.empty)) end
    end
    put("read these as signals: a search nobody commented on is not a failed one.")
    return table.concat(out, "\n")
end

function M.run(argv)
    local opts, as_json = {}, false
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--scope" then opts.scope = argv[i + 1]; i = i + 2
        elseif a == "--days" then opts.days = tonumber(argv[i + 1]); i = i + 2
        elseif a == "--gap" then opts.gap = tonumber(argv[i + 1]); i = i + 2
        elseif a == "--json" then as_json = true; i = i + 1
        elseif a == "-h" or a == "--help" then io.write(USAGE); return
        else io.stderr:write(USAGE); os.exit(2) end
    end
    if (opts.days and opts.days <= 0) or (opts.gap and opts.gap <= 0) then die("--days and --gap take a positive number") end
    require("luamemo.cli._common").setup_or_die(die, { no_embed = true })
    local r = M.report(require("luamemo.db"), opts)
    r.retention_days = feedback.retention_days()
    if as_json then io.write(require("luamemo.json").encode(r), "\n") else io.write(text(r), "\n") end
end

return M
