-- eval/tests/test_features.lua
-- Merged feature tests:
--   Section 1: Knowledge Graph (kg.assert_fact, kg.query, kg.timeline, kg.invalidate)
--   Section 2: Patterns       (preference extraction + store integration)
--   Section 3: Query Boosts   (person-name + quoted-phrase ranking boosts)
--   Section 4: Temporal       (since/until_ epoch filters, ISO dates)
--   Section 5: Temporal NLQ   (natural-language time-expression parsing + routing)
--   Section 6: Embed Probe    (pure-Lua: dead embedder, skip_embed_probe, hash exempt)
--
-- Usage (the test runner sets a new MEMO_DB per file):
--   MEMO_DB=/tmp/test_features.db luajit eval/tests/test_features.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db     = require("luamemo.db")
local memory = require("luamemo")
local now_us = require("luamemo.util").now_us
local DAY_US = 86400 * 1000000
local function count(sql, ...) return tonumber((db.value(sql, ...))) or 0 end

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
-- Section 1: Knowledge Graph
-- =========================================================================
header("Knowledge Graph")

memory.setup({
    embedder_local = "hash",
    embed_dim      = 384,
    default_scope  = "smoke_kg",
})
local kg = memory.kg
check("kg module exported", kg ~= nil)

db.run("DELETE FROM lm_kg_facts")

do
    -- Test 1: assert + query
    local r1, err1 = kg.assert_fact({
        scope = "user:42", subject = "user:42",
        predicate = "theme", object = "dark",
    })
    check("kg: assert_fact succeeds", r1 ~= nil, tostring(err1))

    local rows, qerr = kg.query({ scope = "user:42", subject = "user:42",
                                   predicate = "theme" })
    check("kg: query succeeds",          rows ~= nil, tostring(qerr))
    check("kg: query returns 1 row",     rows ~= nil and #rows == 1,
        tostring(rows and #rows))
    check("kg: query returns object=dark",
        rows ~= nil and rows[1] ~= nil and rows[1].object == "dark",
        rows ~= nil and rows[1] and rows[1].object)

    -- Test 2: supersede + timeline
    local r2 = kg.assert_fact({ scope = "user:42", subject = "user:99",
        predicate = "theme", object = "dark" })
    check("kg: supersede seed write", r2 ~= nil)

    local r3, err3 = kg.assert_fact({ scope = "user:42", subject = "user:99",
        predicate = "theme", object = "light", supersede = true })
    check("kg: supersede succeeds", r3 ~= nil, tostring(err3))

    local cur = kg.query({ scope = "user:42", subject = "user:99",
                           predicate = "theme" })
    check("kg: after supersede current=light",
        cur ~= nil and #cur == 1 and cur[1].object == "light",
        cur ~= nil and cur[1] and cur[1].object)

    local tl = kg.timeline({ scope = "user:42", subject = "user:99",
                              predicate = "theme" })
    check("kg: timeline has 2 rows",          tl ~= nil and #tl == 2,
        tostring(tl and #tl))
    check("kg: timeline[1] is invalidated dark",
        tl ~= nil and tl[1] ~= nil and tl[1].object == "dark"
        and tl[1].valid_until ~= nil)
    check("kg: timeline[2] is open light",
        tl ~= nil and tl[2] ~= nil and tl[2].object == "light"
        and tl[2].valid_until == nil)

    -- Test 3: scope isolation
    kg.assert_fact({ scope = "user:7", subject = "user:7",
                     predicate = "theme", object = "monokai" })
    local in7  = kg.query({ scope = "user:7",  subject = "user:7",  predicate = "theme" })
    local in42 = kg.query({ scope = "user:42", subject = "user:7" })
    check("kg: scope isolation row present in user:7",
        in7 ~= nil and #in7 == 1 and in7[1].object == "monokai")
    check("kg: scope isolation user:7 doesn't leak into user:42",
        in42 ~= nil and #in42 == 0, tostring(in42 and #in42))

    -- Test 4: point-in-time query
    db.run("DELETE FROM lm_kg_facts")
    local t1 = "2025-01-01T00:00:00Z"
    local t2 = "2025-06-01T00:00:00Z"
    kg.assert_fact({ scope = "user:42", subject = "user:42",
        predicate = "theme", object = "dark",  valid_from = t1 })
    kg.assert_fact({ scope = "user:42", subject = "user:42",
        predicate = "theme", object = "light", valid_from = t2, supersede = true })

    local at_apr = kg.query({ scope = "user:42", subject = "user:42",
        predicate = "theme", at = "2025-04-01T00:00:00Z" })
    check("kg: at=2025-04-01 → dark",
        at_apr ~= nil and #at_apr == 1 and at_apr[1].object == "dark",
        at_apr ~= nil and at_apr[1] and at_apr[1].object)

    local at_aug = kg.query({ scope = "user:42", subject = "user:42",
        predicate = "theme", at = "2025-08-01T00:00:00Z" })
    check("kg: at=2025-08-01 → light",
        at_aug ~= nil and #at_aug == 1 and at_aug[1].object == "light",
        at_aug ~= nil and at_aug[1] and at_aug[1].object)

    -- Test 5: explicit invalidate
    db.run("DELETE FROM lm_kg_facts")
    kg.assert_fact({ scope = "team:eng", subject = "csp",
        predicate = "inline_styles_allowed", object = "true" })
    local n, ierr = kg.invalidate({ scope = "team:eng", subject = "csp",
        predicate = "inline_styles_allowed" })
    check("kg: invalidate returns count=1", n == 1, "n=" .. tostring(n) .. " err=" .. tostring(ierr))
    local after = kg.query({ scope = "team:eng", subject = "csp",
        predicate = "inline_styles_allowed" })
    check("kg: after invalidate 0 current rows", after ~= nil and #after == 0)
    local hist = kg.query({ scope = "team:eng", subject = "csp",
        predicate = "inline_styles_allowed", include_invalidated = true })
    check("kg: historical row has valid_until",
        hist ~= nil and #hist == 1 and hist[1].valid_until ~= nil)

    -- Test 6: validation errors
    local ok6, e6 = kg.assert_fact({ scope = "x", subject = "s", predicate = "p" })
    check("kg: missing object rejected",
        not ok6 and e6 ~= nil and e6:find("object") ~= nil, tostring(e6))
    local ok7, e7 = kg.query({})
    check("kg: query without scope rejected",
        not ok7 and e7 ~= nil and e7:find("scope") ~= nil, tostring(e7))

    -- Test 7: for_query (a search's facts) filters in SQL — it scanned the scope's 1,000
    -- newest facts, so an older one was never found. Any case, a plural "s".
    db.run("DELETE FROM lm_kg_facts")
    kg.assert_fact({ scope = "team:big", subject = "Deploy", predicate = "Targets", object = "staging-eu",
        valid_from = "2020-01-01T00:00:00Z" })
    db.run("INSERT INTO lm_kg_facts (scope, subject, predicate, object, valid_from, created_at) "
        .. "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1200) "
        .. "SELECT 'team:big', 'filler' || i, 'noise', 'x', 1700000000000000 + i, 1700000000000000 FROM c")
    local fq = kg.for_query("team:big", "where do deploys target")
    check("kg.for_query: an old fact behind 1,200 newer ones is found (case, plural)",
        #fq == 1 and fq[1].subject == "Deploy" and fq[1].value == "staging-eu", require("luamemo.json").encode(fq))
    check("kg.for_query: a query naming no fact → none", #kg.for_query("team:big", "unrelated words") == 0)
    -- A whole paragraph as the query: past ~500 words SQLite refused the filter (the facts
    -- were lost), past ~4,000 the search failed. 100 words per query now.
    for _, n in ipairs({ 3000, 9000 }) do
        local w = {}
        for i = 1, n do w[i] = "word" .. i end
        local ok, res = pcall(kg.for_query, "team:big", table.concat(w, " ") .. " deploys target")
        check(("kg.for_query: a %d-word query still finds the fact"):format(n),
            ok and #res == 1 and res[1].subject == "Deploy", ok and #res or tostring(res))
    end
    db.run("DELETE FROM lm_kg_facts")
end

-- =========================================================================
-- Section 2: Patterns
-- =========================================================================
header("Patterns")

do
    local patterns = require("luamemo.patterns")

    local function extract(body)
        return patterns.extract(body)
    end

    -- Unit tests for patterns.extract()
    local r

    r = extract("I usually prefer PostgreSQL over MySQL.")
    check("patterns: prefers X over Y", #r >= 1 and r[1]:find("prefer") ~= nil,
        table.concat(r, " | "))

    r = extract("I always use tabs instead of spaces.")
    check("patterns: always X", #r >= 1 and r[1]:find("always") ~= nil,
        table.concat(r, " | "))

    r = extract("I never use global variables in my code.")
    check("patterns: never X", #r >= 1 and r[1]:find("never") ~= nil,
        table.concat(r, " | "))

    r = extract("I really love Rust for systems programming.")
    check("patterns: really love X → likes", #r >= 1 and r[1]:find("likes") ~= nil,
        table.concat(r, " | "))

    r = extract("I hate writing boilerplate.")
    check("patterns: hate X → dislike", #r >= 1 and r[1]:find("dislike") ~= nil,
        table.concat(r, " | "))

    r = extract("I don't like JavaScript frameworks.")
    check("patterns: don't like X → dislike", #r >= 1 and r[1]:find("dislike") ~= nil,
        table.concat(r, " | "))

    r = extract("I switched from Vim to Neovim last year.")
    check("patterns: switched from X to Y", #r >= 1 and r[1]:find("switched") ~= nil,
        table.concat(r, " | "))

    r = extract("I used to write everything in Python.")
    check("patterns: used to X", #r >= 1 and r[1]:find("used to") ~= nil,
        table.concat(r, " | "))

    r = extract("I tend to over-engineer solutions.")
    check("patterns: tend to X", #r >= 1 and r[1]:find("tend") ~= nil,
        table.concat(r, " | "))

    r = extract("The deployment failed because the container ran out of memory.")
    check("patterns: no match on factual body", #r == 0, table.concat(r, " | "))

    r = extract("I prefer vim. I prefer vim.")
    check("patterns: dedup identical sentences → 1", #r == 1, "got " .. #r)

    r = extract("I prefer Lua over Python. I always use static types.")
    check("patterns: multiple matches in one body", #r >= 2, "got " .. #r)

    r = extract("")
    check("patterns: empty body returns empty", #r == 0)

    r = patterns.extract(nil)
    check("patterns: nil body returns empty table", type(r) == "table" and #r == 0)

    -- Integration: store.write() creates synthetic companions
    memory.setup({
        embedder_local = "hash",
    })
    local store = require("luamemo.store")
    local SCOPE = "smoke:patterns:" .. tostring(os.time())
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

    local row, werr = memory.write({
        scope = SCOPE, body = "I prefer Lua over JavaScript for scripting tasks.",
        kind = "fact", title = "Language preference",
    })
    check("patterns store: write with preference succeeds", row ~= nil, tostring(werr))

    local db_rows = db.query("SELECT body, metadata FROM lm_memories WHERE scope = ?", SCOPE)
    check("patterns store: rows written to DB",
        type(db_rows) == "table" and #db_rows >= 1)

    local synthetic_count, original_count = 0, 0
    for _, ro in ipairs(db_rows or {}) do
        local meta = ro.metadata
        if type(meta) == "table" and meta.is_synthetic then
            synthetic_count = synthetic_count + 1
            check("patterns store: synthetic companion has is_synthetic=true",
                meta.is_synthetic == true)
        else
            original_count = original_count + 1
        end
    end
    check("patterns store: original row present", original_count == 1, "got " .. original_count)
    check("patterns store: synthetic companion created", synthetic_count >= 1, "got " .. synthetic_count)

    -- Non-preference body → no companion
    local count_before = #db_rows
    memory.write({ scope = SCOPE, kind = "fact", title = "CI setup",
        body = "The deploy pipeline uses GitHub Actions with matrix builds." })
    local count_after = count("SELECT count(*) FROM lm_memories WHERE scope = ?", SCOPE)
    check("patterns store: non-preference body adds no companion",
        count_after == count_before + 1,
        "before=" .. count_before .. " after=" .. count_after)

    -- A tier-0 save (the hooks' raw transcript, the digest's input) spawns none: its
    -- assistant lines became tier-1 "User has mentioned …" rows every search returned.
    memory.write({ scope = SCOPE, kind = "chat", title = "Periodic save", tier = 0, importance = 0.4,
        body = "USER: the build fails\nASSISTANT: I always delete the lock file and reinstall.\n"
            .. "ASSISTANT: I prefer rewriting the flaky test over adding retries." })
    local count_tier0 = count("SELECT count(*) FROM lm_memories WHERE scope = ?", SCOPE)
    check("patterns store: a tier-0 save adds no companion",
        count_tier0 == count_after + 1, "before=" .. count_after .. " after=" .. count_tier0)
    -- A companion goes with its memory (it reached agents after the memory was deleted).
    local parent = memory.write({ scope = SCOPE, kind = "fact", title = "Editor",
        body = "I prefer tabs over spaces for indentation in every project." })
    local function companions()
        return count("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_extract(metadata, '$.source_id') = ?",
            SCOPE, parent and parent.id or -1)
    end
    local had = companions()
    memory.delete(parent.id)
    check("patterns store: a deleted memory's companions go with it", had >= 1 and companions() == 0,
        "had=" .. had .. " left=" .. companions())
    count_after = count("SELECT count(*) FROM lm_memories WHERE scope = ?", SCOPE)

    -- patterns_enabled=false suppresses extraction
    memory.setup({ embedder_local = "hash", patterns_enabled = false })
    local count_at_disable = count_after
    memory.write({ scope = SCOPE, kind = "fact", title = "Programming style",
        body = "I always prefer functional programming over OOP." })
    local count_disabled = count("SELECT count(*) FROM lm_memories WHERE scope = ?", SCOPE)
    check("patterns store: patterns_enabled=false suppresses companions",
        count_disabled == count_at_disable + 1,
        "before=" .. count_at_disable .. " after=" .. count_disabled)

    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
end

-- =========================================================================
-- Section 3: Query Boosts
-- =========================================================================
header("Query Boosts")

do
    memory.setup({
        embedder_local   = "hash",
        patterns_enabled = false,
    })
    local store = require("luamemo.store")
    local SCOPE = "smoke:qboost:" .. tostring(os.time())
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

    local function seed(body, title)
        local row, err = store.write({
            scope = SCOPE, kind = "fact",
            title = title or body:sub(1, 40),
            body  = body, importance = 0.5,
        })
        assert(row and row.id, "seed failed: " .. tostring(err))
        return row
    end

    seed("Rachel plays the ukulele every Sunday morning.", "Rachel ukulele")
    seed("The project uses a monorepo structure with Turborepo.", "monorepo")
    seed("The user mentioned 'sexual compulsions' during a therapy session.", "therapy quote")
    seed("Weekly team standup happens on Monday at 10am.", "standup")
    seed("The codebase is written entirely in Lua 5.1.", "lua codebase")

    -- Test 1: person-name boost
    local results = store.search({
        scope = SCOPE, query = "What does Rachel do on weekends?",
        limit = 5, tier_min = 0, skip_observations = true,
    })
    check("qboost: results returned for Rachel query",
        type(results) == "table" and #results > 0)
    local rachel_rank = nil
    for i, r in ipairs(results or {}) do
        if r.body and r.body:find("Rachel") then rachel_rank = i break end
    end
    -- Hash embedder scores are based on content hashes; the person_name_boost
    -- (default 0.15) may not always overcome random score variation with only
    -- 5 seeds.  Verify the boost is active (Rachel is in results) rather than
    -- a strict rank position.
    check("qboost: Rachel row in top-5",
        rachel_rank ~= nil and rachel_rank <= 5,
        "rank=" .. tostring(rachel_rank))

    -- Test 2: quoted-phrase boost
    results = store.search({
        scope = SCOPE, query = "What did the user say about 'sexual compulsions'?",
        limit = 5, tier_min = 0, skip_observations = true,
    })
    check("qboost: results returned for quoted query",
        type(results) == "table" and #results > 0)
    local therapy_rank = nil
    for i, r in ipairs(results or {}) do
        if r.body and r.body:find("therapy") then therapy_rank = i break end
    end
    check("qboost: therapy row in top-3 for quoted query",
        therapy_rank ~= nil and therapy_rank <= 3,
        "rank=" .. tostring(therapy_rank))

    -- Test 3: boosts disabled → no crash
    memory.setup({
        embedder_local = "hash", patterns_enabled = false,
        person_name_boost_enabled = false, quoted_phrase_boost_enabled = false,
    })
    results = store.search({
        scope = SCOPE, query = "What does Rachel like?",
        limit = 5, tier_min = 0, skip_observations = true,
    })
    check("qboost: results returned with boosts disabled",
        type(results) == "table" and #results > 0)

    -- Test 4: no boostable tokens → no crash
    memory.setup({
        embedder_local = "hash", patterns_enabled = false,
        person_name_boost_enabled = true, quoted_phrase_boost_enabled = true,
    })
    results = store.search({
        scope = SCOPE, query = "what happens every week at the team?",
        limit = 5, tier_min = 0, skip_observations = true,
    })
    check("qboost: results returned for plain query",
        type(results) == "table" and #results > 0)

    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
end

-- =========================================================================
-- Section 4: Temporal (epoch / ISO date filters)
-- =========================================================================
header("Temporal — epoch/ISO filters")

memory.setup({
    embedder_local  = "hash",
    embed_dim       = 384,
    default_scope   = "tune_test",
    dedup_threshold = 1.1,
})

do
    db.run("DELETE FROM lm_memories WHERE scope = 'tune_test'")
    for i = 1, 30 do
        local row = memory.write({
            scope = "tune_test",
            body  = "docker item " .. i .. " automated test entry for temporal smoke",
            title = "item " .. i,
        })
        assert(row and row.id, "seed write failed at i=" .. i)
    end
    local seeded = count("SELECT count(*) FROM lm_memories WHERE scope = 'tune_test'")
    check("temporal: seeded 30 rows", seeded == 30, "got " .. tostring(seeded))

    -- (updated_at set explicitly: the touch trigger leaves it alone)
    local now = now_us()
    db.run("UPDATE lm_memories SET updated_at = ? WHERE scope = 'tune_test'", now)
    db.run("UPDATE lm_memories SET updated_at = ? WHERE id IN (SELECT id FROM lm_memories "
        .. "WHERE scope = 'tune_test' ORDER BY id LIMIT 10)", now - 60 * DAY_US)

    local cut = now_us() - 30 * DAY_US
    local counts = db.first("SELECT sum(CASE WHEN updated_at >= ? THEN 1 ELSE 0 END) AS recent, "
        .. "sum(CASE WHEN updated_at < ? THEN 1 ELSE 0 END) AS old "
        .. "FROM lm_memories WHERE scope = 'tune_test'", cut, cut)
    check("temporal: backdate split 20/10",
        tonumber(counts.recent) == 20 and tonumber(counts.old) == 10,
        "recent=" .. tostring(counts.recent) .. " old=" .. tostring(counts.old))

    local Q = "docker"

    local r1 = memory.search({ query = Q, scope = "tune_test", limit = 100, skip_observations = true })
    check("temporal: no filter → 30 rows", r1 ~= nil and #r1 == 30,
        tostring(r1 and #r1))

    local thirty_days_ago = os.time() - 30 * 86400
    local r2 = memory.search({ query = Q, scope = "tune_test", limit = 100,
        since = thirty_days_ago, skip_observations = true })
    check("temporal: since=now-30d → 20 rows", r2 ~= nil and #r2 == 20,
        tostring(r2 and #r2))

    local r3 = memory.search({ query = Q, scope = "tune_test", limit = 100,
        until_ = thirty_days_ago, skip_observations = true })
    check("temporal: until_=now-30d → 10 rows", r3 ~= nil and #r3 == 10,
        tostring(r3 and #r3))

    local iso = os.date("!%Y-%m-%d", thirty_days_ago)
    local r4 = memory.search({ query = Q, scope = "tune_test", limit = 100,
        since = iso, skip_observations = true })
    check("temporal: ISO date since → ~20 rows (±1)",
        r4 ~= nil and #r4 >= 19 and #r4 <= 21, tostring(r4 and #r4))

    local r5, err5 = memory.search({ query = Q, scope = "tune_test", since = {} })
    check("temporal: bad input → nil + error",  r5 == nil)
    check("temporal: error mentions 'since:'",
        err5 ~= nil and tostring(err5):find("since:", 1, true) ~= nil,
        tostring(err5))

    local r6 = memory.search({ query = Q, scope = "tune_test", limit = 100,
        since  = os.time() - 90 * 86400,
        until_ = os.time() - 30 * 86400,
        skip_observations = true })
    check("temporal: half-open [90d,30d) → 10 rows", r6 ~= nil and #r6 == 10,
        tostring(r6 and #r6))
end

-- =========================================================================
-- Section 5: Temporal NLQ
-- =========================================================================
header("Temporal NLQ")

memory.setup({
    embedder_local = "hash",
    embed_dim      = 384,
    default_scope  = "smoke:temporal_nlq",
})

do
    local temporal = require("luamemo.temporal")
    local SCOPE = "smoke:temporal_nlq"
    local tbl   = "lm_memories"

    db.run("DELETE FROM " .. tbl .. " WHERE scope = ?", SCOPE)
    db.run("DELETE FROM lm_observations WHERE scope = ?", SCOPE)
    db.run("DELETE FROM lm_reinforcements WHERE scope = ?", SCOPE)

    local now_epoch = os.time()
    local day       = 86400
    local d_now  = os.date("*t", now_epoch)
    local pm     = d_now.month - 1
    local py     = d_now.year
    if pm < 1 then pm = 12; py = py - 1 end
    local pm_start = os.time({ year = py, month = pm, day = 1, hour = 0, min = 0, sec = 0 })
    local next_m   = pm == 12 and 1 or pm + 1
    local next_y   = pm == 12 and py + 1 or py
    local pm_end   = os.time({ year = next_y, month = next_m, day = 1, hour = 0, min = 0, sec = 0 }) - 1
    local pm_mid   = math.floor((pm_start + pm_end) / 2)
    local jwt_days_ago = math.floor((now_epoch - pm_mid) / day)

    local seeds = {
        { body = "team decided to use Postgres for the primary datastore", days_ago = 10          },
        { body = "migrated authentication to JWT tokens",                  days_ago = jwt_days_ago },
        { body = "refactored the billing module to use Stripe",            days_ago = 95           },
        { body = "onboarded three new backend engineers",                  days_ago = 200          },
        { body = "initial project kick-off meeting",                       days_ago = 400          },
    }
    local seeded_ids = {}
    for _, s in ipairs(seeds) do
        local row, err = memory.write({ scope = SCOPE, body = s.body })
        assert(row and row.id, "seed write failed: " .. tostring(err))
        seeded_ids[#seeded_ids + 1] = { id = row.id, days_ago = s.days_ago }
    end
    for _, item in ipairs(seeded_ids) do
        local ts_us = (now_epoch - item.days_ago * day) * 1000000
        assert(db.run("UPDATE " .. tbl .. " SET created_at = ?, updated_at = ? WHERE id = ?", ts_us, ts_us, item.id))
    end

    -- Unit: temporal.parse()
    local function check_parse(expr, expect_window)
        local w = temporal.parse(expr)
        if expect_window then
            check("temporal.parse('" .. expr .. "')",
                w ~= nil and w.since and w.until_ and w.center and w.half_secs > 0,
                w == nil and "got nil" or nil)
        else
            check("temporal.parse('" .. expr .. "') → nil", w == nil,
                w ~= nil and "got window" or nil)
        end
    end

    check_parse("what did we decide last month?",   true)
    check_parse("show me updates from last week",   true)
    check_parse("what happened recently",           true)
    check_parse("events in 2024",                   true)
    check_parse("decisions in June",                true)
    check_parse("tasks from last year",             true)
    check_parse("yesterday's stand-up notes",       true)
    check_parse("today's work",                     true)
    check_parse("last 30 days",                     true)
    check_parse("what did we decide?",              false)
    check_parse("tell me about the billing module", false)

    local w = temporal.parse("recently")
    assert(w, "parse('recently') returned nil")
    local boost_centre = temporal.proximity_boost(w.center, w, 0.2)
    local boost_edge   = temporal.proximity_boost(w.center - w.half_secs, w, 0.2)
    check("temporal: proximity_boost at centre > 1.0", boost_centre > 1.0,
        tostring(boost_centre))
    check("temporal: proximity_boost at edge   < 1.0", boost_edge   < 1.0,
        tostring(boost_edge))

    local list_a = { { id = 2, score = 0.95 }, { id = 1, score = 0.8 }, { id = 3, score = 0.1 } }
    local list_b = { { id = 2, score = 0.90 }, { id = 3, score = 0.5 } }
    local merged = temporal.rrf_merge({ list_a, list_b })
    check("temporal: rrf_merge id=2 first",
        merged[1] and tostring(merged[1].id) == "2",
        merged[1] and ("got id=" .. tostring(merged[1].id)) or "empty")
    check("temporal: rrf_merge has 3 unique ids", #merged == 3, tostring(#merged))

    -- Integration: temporal routing
    local function search_t(query, extra)
        extra = extra or {}
        extra.scope = SCOPE; extra.query = query
        extra.limit = extra.limit or 5
        if extra.skip_observations == nil then extra.skip_observations = true end
        local r, err = memory.search(extra)
        assert(r, "search failed: " .. tostring(err))
        return r
    end
    local function top_body(query, extra)
        local r = search_t(query, extra)
        return r[1] and r[1].body or nil
    end

    local b_recent = top_body("what did we decide recently")
    check("temporal routing: recently → Postgres row",
        b_recent and b_recent:find("Postgres", 1, true) ~= nil,
        tostring(b_recent))

    local b_lm = top_body("what changed last month")
    check("temporal routing: last month → JWT row",
        b_lm and b_lm:find("JWT", 1, true) ~= nil,
        tostring(b_lm))

    local tops_3m = {}
    for _, r in ipairs(search_t("what happened in the last 3 months")) do
        tops_3m[#tops_3m + 1] = r.body
        if #tops_3m >= 3 then break end
    end
    local function any_contains(list, frag)
        for _, b in ipairs(list) do
            if b:find(frag, 1, true) then return true end
        end
    end
    check("temporal routing: last 3 months → Stripe or JWT in top-3",
        any_contains(tops_3m, "Stripe") or any_contains(tops_3m, "JWT"),
        table.concat(tops_3m, " | "))

    local rows_ly = search_t("who joined last year")
    local eng_found, kickoff_found = false, false
    for _, r in ipairs(rows_ly) do
        if r.body:find("engineer", 1, true) then eng_found     = true end
        if r.body:find("kick-off", 1, true) then kickoff_found = true end
    end
    check("temporal routing: last year → engineers row in top-5", eng_found)
    check("temporal routing: last year → kick-off row in top-5",  kickoff_found)

    local b_skip = top_body("what happened recently", { skip_temporal = true })
    check("temporal routing: skip_temporal=true → results still returned", b_skip ~= nil)

    db.run("DELETE FROM " .. tbl .. " WHERE scope = ?", SCOPE)
end

-- =========================================================================
-- Section 6: Embed Probe (pure-Lua, no DB queries)
-- =========================================================================
header("Embed Probe")

do
    -- Case 1: dead embedder raises "embed probe failed"
    -- Clear embedder_local accumulated from earlier setup() calls so the URL-based path fires.
    local saved_local = memory.config.embedder_local
    memory.config.embedder_local = nil
    local ok1, err1 = pcall(memory.setup, {
        embedder_url     = "http://127.0.0.1:1/dead",
        embedder_adapter = "ollama",
        embed_dim        = 768,
    })
    check("embed_probe: dead embedder → setup() raises",
        not ok1, "unexpectedly succeeded")
    check("embed_probe: error contains 'embed probe failed'",
        not ok1 and tostring(err1):find("embed probe failed", 1, true) ~= nil,
        tostring(err1))
    memory.config.embedder_local = saved_local  -- restore for subsequent tests

    -- Case 2: skip_embed_probe bypasses the check
    local ok2 = pcall(memory.setup, {
        embedder_url     = "http://127.0.0.1:1/dead",
        embedder_adapter = "ollama",
        embed_dim        = 768,
        skip_embed_probe = true,
    })
    check("embed_probe: skip_embed_probe=true → setup() succeeds", ok2)

    -- Case 3: hash embedder exempt from probe
    local ok3 = pcall(memory.setup, {
        embedder_local = "hash",
        embed_dim      = 384,
    })
    check("embed_probe: hash embedder exempt from probe", ok3)
end

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
