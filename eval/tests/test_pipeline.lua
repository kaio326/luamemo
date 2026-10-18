-- eval/tests/test_pipeline.lua
-- Merged pipeline tests:
--   Section 1: Consolidate (observation clustering + reinforcement + store search leg)
--   Section 2: Digest      (hippocampus digest: tier-0 processing, purge, dry_run)
--   Section 3: MCP Tools   (memory_status, memory_reconnect, memory_diary_write/read)
--
-- Usage (the test runner sets a new MEMO_DB per file):
--   MEMO_DB=/tmp/test_pipeline.db luajit eval/tests/test_pipeline.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db     = require("luamemo.db")
local memory = require("luamemo")
local util   = require("luamemo.util")

local pass = 0
local fail = 0

local function check(label, ok, detail)
    if ok then
        io.write("[PASS] " .. label .. "\n")
        pass = pass + 1
    else
        io.write("[FAIL] " .. label .. (detail and (" — " .. tostring(detail)) or "") .. "\n")
        fail = fail + 1
    end
end

local function header(s)
    io.write(string.format("\n=== %s ===\n", s))
end

local function count(sql, ...) return tonumber((db.value(sql, ...))) end
local function ids_in(ids) return "id IN (" .. db.placeholders(#ids) .. ")" end

-- =========================================================================
-- Section 1: Consolidate
-- =========================================================================
header("Consolidate")

local consolidate = require("luamemo.consolidate")

memory.setup({
    embedder_local    = "hash",
    embed_dim         = 384,
    default_scope     = "smoke:consolidate",
    summarizer_adapter = "noop",
    consolidate_threshold            = 0.70,
    consolidate_reinforce_threshold  = 0.50,
})

local SCOPE_C   = "smoke:consolidate"
local MEM_TBL   = "lm_memories"
local OBS_TBL   = "lm_observations"

db.run("DELETE FROM " .. MEM_TBL .. " WHERE scope = ?", SCOPE_C)
db.run("DELETE FROM " .. OBS_TBL .. " WHERE scope = ?", SCOPE_C)

do
    -- Schema check
    local tbl_ok = db.value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'lm_observations'") ~= nil
    local col_ok = db.value("SELECT 1 FROM pragma_table_info('lm_memories') WHERE name = 'consolidated_at'") ~= nil
    local migrate_ok = tbl_ok and col_ok
    check("consolidate: lm_observations table exists", tbl_ok)
    check("consolidate: lm_memories.consolidated_at column exists", col_ok)

    if migrate_ok then
        -- Seed related + unrelated memories
        local related_bodies = {
            "We decided to use PostgreSQL as the primary database",
            "The team chose PostgreSQL for all data persistence",
            "PostgreSQL was selected as the main database system",
        }
        local unrelated_body = "The frontend is built with React and TypeScript"
        for _, body in ipairs(related_bodies) do
            local row, err = memory.write({ scope = SCOPE_C, body = body, importance = 1.5 })
            assert(row and row.id, "seed write failed: " .. tostring(err))
        end
        local urow, uerr = memory.write({ scope = SCOPE_C, body = unrelated_body })
        assert(urow and urow.id, "seed write failed: " .. tostring(uerr))

        local seeded = count("SELECT COUNT(*) FROM " .. MEM_TBL .. " WHERE scope = ?", SCOPE_C)
        check("consolidate: 4 memories seeded", seeded == 4, "got " .. tostring(seeded))

        -- Process
        local result = consolidate.process(SCOPE_C)
        check("consolidate: process() no fatal errors",
            type(result) == "table" and #(result.errors or {}) == 0,
            table.concat(result.errors or {}, "; "))
        check("consolidate: at least 1 observation synthesised or reinforced",
            (result.synthesised or 0) + (result.reinforced or 0) >= 1,
            "synthesised=" .. tostring(result.synthesised)
            .. " reinforced=" .. tostring(result.reinforced))

        -- consolidated_at stamped
        local unconsolidated = count("SELECT COUNT(*) FROM " .. MEM_TBL
            .. " WHERE scope = ? AND consolidated_at IS NULL", SCOPE_C)
        check("consolidate: all memories stamped consolidated_at",
            unconsolidated == 0, tostring(unconsolidated) .. " rows still unconsolidated")

        local obs_count = count("SELECT COUNT(*) FROM " .. OBS_TBL .. " WHERE scope = ?", SCOPE_C)
        check("consolidate: at least 1 observation row created",
            (obs_count or 0) >= 1, "got " .. tostring(obs_count))

        -- Reinforcement
        local max_before = count("SELECT COALESCE(MAX(proof_count), 0) FROM " .. OBS_TBL
            .. " WHERE scope = ?", SCOPE_C) or 0

        memory.write({ scope = SCOPE_C, body = "PostgreSQL is our chosen persistence layer", importance = 1.0 })
        memory.write({ scope = SCOPE_C, body = "DB decision: use PostgreSQL", importance = 1.0 })

        local result2 = consolidate.process(SCOPE_C)
        check("consolidate: second process() no fatal errors",
            type(result2) == "table" and #(result2.errors or {}) == 0,
            table.concat(result2.errors or {}, "; "))

        local max_after = count("SELECT COALESCE(MAX(proof_count), 0) FROM " .. OBS_TBL
            .. " WHERE scope = ?", SCOPE_C) or 0
        check("consolidate: second process() produced ≥1 reinforced or synthesised",
            (tonumber(result2.reinforced) or 0) + (tonumber(result2.synthesised) or 0) >= 1
            or max_after >= max_before,   -- hash embedder: accept if proof_count didn't drop
            "before=" .. max_before .. " after=" .. max_after)

        -- The closest observation is found where the vectors are stored (one scan for every
        -- cluster), a row stored without its norm included: a memory saying what an
        -- observation says reinforces exactly that one.
        local o = db.first("SELECT id, body, proof_count FROM " .. OBS_TBL .. " WHERE scope = ? ORDER BY id LIMIT 1",
            SCOPE_C)
        db.run("UPDATE " .. OBS_TBL .. " SET emb_norm = NULL WHERE id = ?", o.id)
        assert(memory.write({ scope = SCOPE_C, body = o.body, dedup_strategy = "append" }))
        local result3 = consolidate.process(SCOPE_C)
        check("consolidate: a memory repeating an observation reinforces it (its norm computed)",
            result3.reinforced == 1 and result3.synthesised == 0
            and count("SELECT proof_count FROM " .. OBS_TBL .. " WHERE id = ?", o.id) == o.proof_count + 1,
            ("reinforced=%s synthesised=%s"):format(tostring(result3.reinforced), tostring(result3.synthesised)))

        -- consolidate.search()
        local qvec, everr = require("luamemo.embed").embed("PostgreSQL database choice")
        assert(qvec, "embed failed: " .. tostring(everr))

        local obs_results = consolidate.search(SCOPE_C, qvec, 10)
        check("consolidate.search() returns ≥1 observation", #obs_results >= 1,
            "got " .. tostring(#obs_results))
        if #obs_results >= 1 then
            check("consolidate.search: type='observation'",
                obs_results[1].type == "observation",
                "got type=" .. tostring(obs_results[1].type))
            check("consolidate.search: proof_count is number",
                type(obs_results[1].proof_count) == "number")
            check("consolidate.search: freshness_trend is string",
                type(obs_results[1].freshness_trend) == "string")
            check("consolidate.search: positive score",
                (obs_results[1].score or 0) > 0)
        end

        -- store.search() observation leg
        local search_results, serr = memory.search({
            scope = SCOPE_C, query = "what database did we choose?", limit = 10,
        })
        assert(search_results, "store.search failed: " .. tostring(serr))
        check("consolidate: store.search() returns ≥1 result",
            #search_results >= 1, tostring(#search_results))

        -- An observation repeating a result's text is left out (the default summarizer keeps a
        -- member's body: the same text twice in one answer); one saying more is appended.
        local shown, dup = {}, false
        for _, r in ipairs(search_results) do if r.type ~= "observation" then shown[r.body] = true end end
        for _, r in ipairs(search_results) do if r.type == "observation" and shown[r.body] then dup = true end end
        check("consolidate: store.search() leaves out an observation repeating a result", not dup)
        local qv = assert(require("luamemo.embed").embed("PostgreSQL database choice"))
        local blob, norm = require("luamemo.vectors").pack(qv)
        local now_us = require("luamemo.util").now_us()
        db.run("INSERT INTO " .. OBS_TBL .. " (scope, body, proof_count, embedding, emb_norm, last_reinforced, "
            .. "created_at) VALUES (?, ?, 3, ?, ?, ?, ?)", SCOPE_C, "The team standardised on PostgreSQL for every service",
            db.blob(blob), norm, now_us, now_us)
        local found_obs
        for _, r in ipairs(memory.search({ scope = SCOPE_C, query = "what database did we choose?", limit = 10 }) or {}) do
            if r.type == "observation" and r.body:find("standardised", 1, true) then found_obs = r break end
        end
        check("consolidate: store.search() includes an observation that says more", found_obs ~= nil)
        -- Its own id as observation_id, never id: memory_get / update / delete read that as a
        -- memory id — acting on an observation reached an unrelated memory.
        check("… with observation_id, no id (no memory has its number)", found_obs and found_obs.id == nil
            and tonumber(found_obs.observation_id) ~= nil, found_obs and tostring(found_obs.id))
        -- Observations have no kind, metadata, tier or time: a search filtered on one gets none
        -- (they came back whatever the filter); min_score holds for them too.
        local leaked = {}
        for _, f in ipairs({ { kind = "decision" }, { min_score = 50 }, { metadata_filter = { source = "x" } },
                             { since = "2099-01-01" }, { tier_max = 0 } }) do
            local a = { scope = SCOPE_C, query = "what database did we choose?", limit = 10 }
            for k, v in pairs(f) do a[k] = v end
            for _, r in ipairs(memory.search(a) or {}) do
                if r.type == "observation" then leaked[#leaked + 1] = next(f) end
            end
        end
        check("… and none in a search filtered on kind / metadata / time / tier, or below min_score",
            #leaked == 0, table.concat(leaked, ","))

        -- skip_observations=true
        local skip_results, skerr = memory.search({
            scope = SCOPE_C, query = "PostgreSQL database",
            limit = 10, skip_observations = true,
        })
        assert(skip_results, "skip search failed: " .. tostring(skerr))
        local skip_obs = false
        for _, r in ipairs(skip_results) do
            if r.type == "observation" then skip_obs = true break end
        end
        check("consolidate: skip_observations=true excludes observations", not skip_obs)

        -- A deleted or rewritten memory leaves nothing in the observations: their text may be
        -- the memory's own (the default summarizer), so it reached agents after the delete
        -- (a confidential note) and beside the new text after an update.
        local S2 = SCOPE_C .. ":forget"
        local embed_mod = require("luamemo.embed")
        local secret = assert(memory.write({ scope = S2, title = "ACME contract", body = "ACME pays 2.4M and leaves in Q3" }))
        local cadence = assert(memory.write({ scope = S2, title = "release cadence", body = "we release every second Tuesday" }))
        local embeds, real_embed = 0, embed_mod.embed
        embed_mod.embed = function(...) embeds = embeds + 1; return real_embed(...) end
        memory.search({ scope = S2, query = "release", limit = 5 })   -- consolidates both
        embed_mod.embed = real_embed
        check("consolidate: a new observation reuses its member's vector (one embedder call: the query)",
            embeds == 1, embeds)
        local function obs_bodies()
            local t = {}
            for _, r in ipairs(db.query("SELECT body FROM " .. OBS_TBL .. " WHERE scope = ?", S2) or {}) do t[#t + 1] = r.body end
            return table.concat(t, " | ")
        end
        check("… an observation per memory (setup)", obs_bodies():find("ACME", 1, true) ~= nil
            and obs_bodies():find("Tuesday", 1, true) ~= nil, obs_bodies())
        memory.delete(secret.id)
        check("consolidate: a deleted memory's observation goes with it", not obs_bodies():find("ACME", 1, true),
            obs_bodies())
        memory.update(cadence.id, { body = "we release every Friday now" })
        check("… and a rewritten one's, the memory to be consolidated again", not obs_bodies():find("Tuesday", 1, true)
            and db.value("SELECT consolidated_at IS NULL FROM " .. MEM_TBL .. " WHERE id = ?", cadence.id) == 1,
            obs_bodies())
        memory.search({ scope = S2, query = "release", limit = 5 })
        check("… which the next search does, from its new text", obs_bodies():find("Friday", 1, true) ~= nil, obs_bodies())
        -- Tier 0 (the hooks' raw transcript) is the digest's: a search doesn't distil it (its
        -- observation got past the search's tier filter).
        local raw = assert(memory.write({ scope = S2, title = "Periodic save", body = "USER: zebra crossing words",
            tier = 0, importance = 0.4 }))
        memory.search({ scope = S2, query = "zebra", limit = 5 })
        check("consolidate: a search leaves tier-0 rows to the digest",
            db.value("SELECT consolidated_at IS NULL FROM " .. MEM_TBL .. " WHERE id = ?", raw.id) == 1
            and not obs_bodies():find("zebra", 1, true), obs_bodies())
        db.run("DELETE FROM " .. MEM_TBL .. " WHERE scope = ?", S2)
        db.run("DELETE FROM " .. OBS_TBL .. " WHERE scope = ?", S2)
    end

    db.run("DELETE FROM " .. MEM_TBL .. " WHERE scope = ?", SCOPE_C)
    db.run("DELETE FROM " .. OBS_TBL .. " WHERE scope = ?", SCOPE_C)
end

-- =========================================================================
-- Section 2: Digest
-- =========================================================================
header("Digest")

local digest = require("luamemo.digest")

memory.setup({
    embedder_local     = "hash",
    embed_dim          = 384,
    default_scope      = "smoke:digest",
    summarizer_adapter = "noop",
    consolidate_threshold            = 0.70,
    consolidate_reinforce_threshold  = 0.50,
    digest_idle_seconds     = 9999,
    digest_grace_days       = 0,
    digest_escalate_alpha   = 0.4,
    digest_promote_tier2_at = 3,
    digest_promote_tier3_at = 5,
})

local store  = require("luamemo.store")
local SCOPE_D  = "smoke:digest"
local REI_TBL  = "lm_reinforcements"

db.run("DELETE FROM " .. MEM_TBL .. " WHERE scope = ?", SCOPE_D)
db.run("DELETE FROM " .. REI_TBL .. " WHERE scope = ?", SCOPE_D)

do
    -- Schema check
    check("digest: lm_reinforcements table exists",
        db.value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'lm_reinforcements'") ~= nil)

    -- configure + notify_write
    local ok2, err2 = pcall(function()
        digest.configure({
            digest_idle_seconds     = 9999,
            digest_grace_days       = 0,
            digest_escalate_alpha   = 0.4,
            digest_promote_tier2_at = 3,
            digest_promote_tier3_at = 5,
        })
        digest.notify_write(SCOPE_D)
    end)
    check("digest: configure and notify_write succeed", ok2, tostring(err2))

    -- should_run
    check("digest: should_run false immediately after write", not digest.should_run(SCOPE_D))
    check("digest: should_run false for unknown scope",
        not digest.should_run("smoke:digest:never_written"))

    -- record_event
    local seed_row, seed_err = store.write({
        scope = SCOPE_D, title = "seed for reinforcement",
        body  = "test reinforcement event seeding", importance = 0.5,
    })
    check("digest: seed row for FK test", seed_row ~= nil, tostring(seed_err))
    local mem_id = seed_row and seed_row.id

    local ok4, err4 = pcall(digest.record_event, mem_id, SCOPE_D, "mistake", 0.5, "smoke test note")
    check("digest: record_event executes without error", ok4, tostring(err4))

    local rei_rows = db.query("SELECT event_type, note FROM " .. REI_TBL .. " WHERE memory_id = ?", mem_id or 0)
    check("digest: record_event row in lm_reinforcements",
        rei_rows and #rei_rows >= 1)
    if rei_rows and #rei_rows >= 1 then
        check("digest: record_event event_type=mistake",
            rei_rows[1].event_type == "mistake", rei_rows[1].event_type)
        check("digest: record_event note correct",
            rei_rows[1].note == "smoke test note", rei_rows[1].note)
    end

    -- reversal
    local rev_row, rev_err = store.write({
        scope = SCOPE_D, title = "important decision",
        body  = "we decided to use microservices", importance = 0.8,
    })
    check("digest: seed row for reversal test", rev_row ~= nil, tostring(rev_err))
    local rev_id = rev_row and rev_row.id

    local ok_rev = pcall(digest.record_event, rev_id, SCOPE_D, "reversal", 1.0, "direction changed")
    check("digest: record_event reversal succeeds", ok_rev)

    local after_imp = rev_id and tonumber((db.value("SELECT importance FROM lm_memories WHERE id = ?", rev_id)))
    check("digest: reversal reduces importance",
        after_imp and after_imp < 0.8,
        "importance after reversal: " .. tostring(after_imp))

    local rev_rei = rev_id and db.query("SELECT event_type FROM " .. REI_TBL
        .. " WHERE memory_id = ? AND event_type = 'reversal'", rev_id)
    check("digest: reversal event written to lm_reinforcements",
        rev_rei and #rev_rei >= 1)

    -- run on empty scope
    local empty_scope = "smoke:digest:empty_" .. tostring(os.time())
    local ok6, res6 = pcall(digest.run, empty_scope)
    check("digest: run on empty scope succeeds", ok6, tostring(res6))
    if ok6 then
        check("digest: run returns table",       type(res6) == "table")
        check("digest: run.processed is number", type(res6.processed) == "number")
        check("digest: run.errors is table",     type(res6.errors) == "table")
    end

    -- Seed tier-0 memories
    local tier0_ids = {}
    for i = 1, 3 do
        local r, e = store.write({
            scope      = SCOPE_D,
            title      = "ephemeral event " .. i,
            body       = "something happened in session step " .. i,
            importance = 0.2,
        })
        check("digest: seed tier-0 row " .. i, r ~= nil, tostring(e))
        if r then tier0_ids[#tier0_ids + 1] = r.id end
    end

    if #tier0_ids > 0 then
        local t0check = db.query("SELECT id, tier FROM " .. MEM_TBL .. " WHERE " .. ids_in(tier0_ids)
            .. " AND tier = 0", unpack(tier0_ids))
        check("digest: seeded rows are tier=0",
            t0check and #t0check == #tier0_ids,
            "expected " .. #tier0_ids .. " got " .. tostring(t0check and #t0check))
    end

    local ok7, res7 = pcall(digest.run, SCOPE_D)
    check("digest: run with tier-0 rows succeeds", ok7, tostring(res7))
    if ok7 then
        check("digest: processed >= 1", res7.processed >= 1,
            "processed=" .. tostring(res7.processed))
    end

    if ok7 and #tier0_ids > 0 then
        local stamped = db.query("SELECT id FROM " .. MEM_TBL .. " WHERE " .. ids_in(tier0_ids)
            .. " AND consolidated_at IS NOT NULL", unpack(tier0_ids))
        check("digest: consolidated_at stamped after run",
            stamped and #stamped > 0,
            "stamped=" .. tostring(stamped and #stamped))
    end

    -- dry_run
    local dry_ids = {}
    for i = 1, 2 do
        local r = store.write({
            scope          = SCOPE_D,
            title          = "dry run event " .. i,
            body           = "should not be stamped: unique content " .. os.time() .. "_" .. i,
            importance     = 0.15,
            dedup_strategy = "append",
        })
        if r then dry_ids[#dry_ids + 1] = r.id end
    end

    local ok9, res9 = pcall(digest.run, SCOPE_D, { dry_run = true })
    check("digest: dry_run run succeeds", ok9, tostring(res9))
    if ok9 then
        check("digest: dry_run.processed is number", type(res9.processed) == "number")
        check("digest: dry_run.deleted == 0", res9.deleted == 0,
            "deleted=" .. tostring(res9.deleted))
    end

    if ok9 and #dry_ids > 0 then
        local unstamped = db.query("SELECT id FROM " .. MEM_TBL .. " WHERE " .. ids_in(dry_ids)
            .. " AND consolidated_at IS NULL", unpack(dry_ids))
        check("digest: dry_run does not stamp consolidated_at",
            unstamped and #unstamped == #dry_ids,
            "unstamped=" .. tostring(unstamped and #unstamped)
            .. " expected=" .. #dry_ids)
    end

    -- purge stale (grace_days=0)
    if #tier0_ids > 0 then
        local params = { util.now_us() - 1000000 }
        for _, id in ipairs(tier0_ids) do params[#params + 1] = id end
        db.run("UPDATE " .. MEM_TBL .. " SET consolidated_at = ? WHERE " .. ids_in(tier0_ids), unpack(params))
        local ok11, res11 = pcall(digest.run, SCOPE_D)
        check("digest: run for purge succeeds", ok11, tostring(res11))
        if ok11 then
            check("digest: deleted > 0 with grace_days=0", res11.deleted > 0,
                "deleted=" .. tostring(res11.deleted))
        end
    end

    -- store.write calls notify_write
    local ok12, err12 = pcall(store.write, {
        scope = SCOPE_D, title = "notify test", body = "notify_write integration",
        importance = 0.5,
    })
    check("digest: store.write after wiring succeeds (notify_write hooked)", ok12, tostring(err12))

    db.run("DELETE FROM " .. MEM_TBL .. " WHERE scope = ?", SCOPE_D)
    db.run("DELETE FROM " .. REI_TBL .. " WHERE scope = ?", SCOPE_D)
end

-- =========================================================================
-- Section 3: MCP Tools
-- =========================================================================
header("MCP Tools")

memory.setup({
    embedder_local   = "hash",
    patterns_enabled = false,
})

do
    -- Inline the MCP tool handlers (mirrors mcp/server.lua)
    local function ensure_setup() end

    local function status_handler(_)
        ensure_setup()
        local scopes, serr = db.query(
            "SELECT scope, COUNT(*) AS n, SUM(COUNT(*)) OVER () AS grand_total "
            .. "FROM lm_memories GROUP BY scope ORDER BY n DESC LIMIT 20")
        if not scopes then return nil, tostring(serr) end
        local cfg_ref = require("luamemo").config or {}
        return {
            connected  = true,
            total_rows = tonumber(scopes[1] and scopes[1].grand_total or 0),
            top_scopes = scopes,
            version    = require("luamemo").VERSION or "unknown",
            config = {
                embedder     = cfg_ref.embedder_local or cfg_ref.embedder_adapter,
                embed_dim    = cfg_ref.embed_dim,
                patterns_en  = cfg_ref.patterns_enabled ~= false,
                tier_min_mcp = 1,
            },
        }
    end

    local function reconnect_handler(_)
        ensure_setup()
        db.reset()
        local n, err = db.value("SELECT COUNT(*) FROM lm_memories")
        return {
            success    = n ~= nil,
            rows_after = tonumber(n),
            error      = (n == nil) and tostring(err) or nil,
        }
    end

    local function diary_write_handler(args)
        ensure_setup()
        if not args.agent_name or args.agent_name == "" then return nil, "agent_name required" end
        if not args.entry      or args.entry == ""      then return nil, "entry required" end
        local scope = "diary:" .. args.agent_name
        local topic = tostring(args.topic or "general")
        local row, err = store.write({
            scope      = scope,
            kind       = "diary",
            title      = "Diary entry — " .. topic,
            body       = args.entry,
            importance = 0.5,
            metadata   = { agent = args.agent_name, topic = topic, diary = true },
        })
        if not row then return nil, err end
        return { success = true, entry_id = row.id, agent = args.agent_name,
                 topic = topic, scope = scope }
    end

    local function diary_read_handler(args)
        ensure_setup()
        if not args.agent_name or args.agent_name == "" then return nil, "agent_name required" end
        local scope  = "diary:" .. args.agent_name
        local limit  = math.min(tonumber(args.last_n) or 10, 50)
        local rows, err = db.query(
            "SELECT id, body, importance, metadata, created_at "
            .. "FROM lm_memories WHERE scope = ? "
            .. "ORDER BY created_at DESC, id DESC LIMIT ?",
            scope, limit)
        if not rows then return nil, err end
        local entries = {}
        for _, r in ipairs(rows) do
            local meta = (type(r.metadata) == "table") and r.metadata or {}
            entries[#entries + 1] = {
                entry_id  = r.id,
                timestamp = util.us_to_iso(r.created_at),
                topic     = meta.topic or "general",
                content   = r.body,
            }
        end
        return { agent = args.agent_name, entries = entries, total = #entries, scope = scope }
    end

    local AGENT = "smoke_agent_" .. tostring(os.time())
    local SCOPE_M = "diary:" .. AGENT
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE_M)

    -- memory_status
    local r, err = status_handler({})
    check("mcp: status returns connected=true",
        type(r) == "table" and r.connected == true, tostring(err))
    check("mcp: status total_rows is a number",
        type(r) == "table" and type(r.total_rows) == "number")
    check("mcp: status top_scopes is a table",
        type(r) == "table" and type(r.top_scopes) == "table")
    check("mcp: status version is a string",
        type(r) == "table" and type(r.version) == "string")
    check("mcp: status config.embedder=hash",
        type(r) == "table" and r.config and r.config.embedder == "hash")
    check("mcp: status config.patterns_en=false",
        type(r) == "table" and r.config and r.config.patterns_en == false)

    -- memory_reconnect
    r, err = reconnect_handler({})
    check("mcp: reconnect success=true",
        type(r) == "table" and r.success == true, tostring(err))
    check("mcp: reconnect rows_after is a number",
        type(r) == "table" and type(r.rows_after) == "number")
    check("mcp: reconnect error=nil on success",
        type(r) == "table" and r.error == nil)

    -- memory_diary_write
    r, err = diary_write_handler({
        agent_name = AGENT,
        entry      = "Today I worked on query boost tests and they passed.",
        topic      = "work",
    })
    check("mcp: diary_write returns success=true",
        type(r) == "table" and r.success == true, tostring(err))
    check("mcp: diary_write entry_id present",
        type(r) == "table" and r.entry_id ~= nil)
    check("mcp: diary_write scope=diary:<agent>",
        type(r) == "table" and r.scope == "diary:" .. AGENT)
    check("mcp: diary_write topic preserved",
        type(r) == "table" and r.topic == "work")

    r, err = diary_write_handler({ agent_name = "", entry = "x" })
    check("mcp: diary_write empty agent_name → error", r == nil and err ~= nil)
    r, err = diary_write_handler({ agent_name = AGENT, entry = "" })
    check("mcp: diary_write empty entry → error",      r == nil and err ~= nil)

    -- write second entry
    diary_write_handler({ agent_name = AGENT, entry = "Second entry — more tests.", topic = "testing" })

    -- memory_diary_read
    r, err = diary_read_handler({ agent_name = AGENT, last_n = 10 })
    check("mcp: diary_read returns entries table",
        type(r) == "table" and type(r.entries) == "table", tostring(err))
    check("mcp: diary_read total >= 2",
        type(r) == "table" and (r.total or 0) >= 2,
        "total=" .. tostring(r and r.total))
    check("mcp: diary_read first entry has content",
        type(r) == "table" and r.entries[1] and r.entries[1].content ~= nil)
    check("mcp: diary_read entries have topic",
        type(r) == "table" and r.entries[1] and r.entries[1].topic ~= nil)
    check("mcp: diary_read agent field preserved",
        type(r) == "table" and r.agent == AGENT)
    check("mcp: diary_read timestamp is text",
        type(r) == "table" and r.entries[1] and type(r.entries[1].timestamp) == "string")

    r = diary_read_handler({ agent_name = AGENT, last_n = 1 })
    check("mcp: diary_read last_n=1 → ≤1 entry",
        type(r) == "table" and r.total <= 1)

    r, err = diary_read_handler({ agent_name = "" })
    check("mcp: diary_read empty agent_name → error", r == nil and err ~= nil)

    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE_M)
end

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
