-- eval/tests/test_fold.lua
-- The life of a folded memory (luamemo.fold): archive → grace → analyze and compare → delete or correct.
-- The clock is driven (util.now_us), so every outcome is reached in a test, not waited for.
--   A. archive: a memory folded into a summary stays, hidden, with its record; nothing sees it (search, recent,
--      the maintenance passes); the summary does
--   B. before the grace period nothing happens; after it, a memory that was not useful and whose facts are in the
--      summary is deleted (and the decision logged first)
--   C. useful, and the summary lost its facts → the summary is corrected (the facts added, no model), the memory
--      goes back to grace, and is deleted at the next review once the summary holds them
--   D. the summary was marked wrong → corrected even if the memory was never useful; corrected past the limit →
--      restored, never deleted
--   E. the summary is gone → restored (it is the only copy)
--   F. raw conversation the digest consolidated: archived, reviewed, deleted — or kept when it helped; the
--      observation is corrected like a summary
--   G. the pure parts (salient tokens, coverage, the decision) and the code index (never reviewed or folded)
--   H. the log (written before a delete, private, rotated, never through a symlink) and the audit-first rule: with no
--      way to record the decision nothing is deleted
--   I. what cannot be trusted or looked up: a forged record, a review that raises, a failed archive, a lookup or a
--      count that fails (decides nothing), a delete that finds the row taken by another run, a restore that fails;
--      a summary that is gone gives the memory back (a tier-0 one is kept); the review's limit and deadline
--   J. what a review trusts: an id that was reused (or a note, or a row dated after the fold) is not the summary; a
--      second archive keeps the first record; every write (delete, restore, 'kept', correction) re-checks that the row
--      is still waiting AND as it was decided about; a correction that cannot be made (no room, an update or an embed
--      that fails) gives the original back; a summary marked wrong once is not trusted at the next review either; a
--      record without the tier it had counts as an ordinary memory; a summary is one scope's
--   K. what a review leaves alone or gives back: a summary that was itself folded away holds nothing; a row from before
--      folds were recorded stays raw conversation after a correction; the dry run answers what the real run does when a
--      correction cannot be made; a record that cannot be checked (a date that is no number, a summary or an observation
--      of another scope) is a summary that is gone; a summary takes its scope from its originals and fails closed
--   L. the digest: escalation of a cluster with mistakes (not when an observation is as close as the reinforce threshold
--      — the configured one —, and still when one about something else exists; every cluster, whatever its order; the
--      escalated member stays visible at its new tier while its copies are folded), a dry run changes nothing, one
--      consolidation per run (none for an empty scope), a consolidation that raises — or reports `failed` — leaves the
--      rows for the next run
--   M. the digest's escalation in detail: which member, how far by how many mistakes, which events count, a lookup that
--      fails, a note raised meanwhile (not overwritten), an escalation that lost a race (read again and applied; a second
--      race is not chased; a note deleted meanwhile raises nothing), a note with no vector — left alone, and taken once it
--      is re-embedded
--   N. reinforcement events: the event-type lists, record_event / apply_event_effect normalisation (ids and deltas that are
--      no number — 0, negative, NaN, none; a negative delta) and compare-and-set (importance, tier)
--   O. a reinforced observation's fresh trend and evidence; the promotions (tier 1 → 2 by an observation's proof, tier 2 → 3
--      by mistakes; a failed statement is reported); the tunables (promote_tier2_at / tier3_at, escalate_alpha)
--   P. digest.run in detail: a dry run, an empty scope ("no scope"), the 500-row fetch cap and the tie-break by id,
--      escalation by the number of mistakes (not the importance), a scope of notes with and without a vector, a note with
--      a title only (an observation of its title), a cluster of 450 notes (marked in one statement)
--   Q. what the digest cannot read or the consolidation cannot do — reported, nothing archived: the notes, the mistake
--      counts (in a dry run too), the consolidation's fetch ("not configured"; the scope stays pending; a limited fetch is
--      not retried without its limit), the insert / update of an observation (the notes are left for the next run; the
--      digest over a failing insert), a mark that fails, a summarizer that gives no text, a search whose inline
--      consolidation fails, the review's errors in the digest's
--   R. a reinforcement by the consolidation (two clusters on one observation, an observation gone); opts.threshold
--      (library and ops)
--   S. a note rewritten (after process, or between its read and its mark) or moved to another scope while the digest
--      consolidates (not archived; taken by the next run — a moved one by its new scope's); an observation that goes with
--      its memory (deleted, rewritten, moved) gives the archived notes back, and a release that fails changes nothing;
--      fold.archive in the digest's mode; fold.release's guards (summary, decided, higher tier; any number of ids)
--   T. higher-tier rows: consolidated, never archived or reviewed
--   U. the fold record in one place (edit_sets; a forged tier, a metadata patch, an edited original reviewed on a fresh
--      clock, an edit that races a fold, a list as metadata); fold.release scoped, atomic inside a transaction, a real id among thousands; a stale cluster costs
--      no summarizer call; a cluster that cannot be checked is an error; the reinforce path (a failed mark undone, a
--      cluster changed since it was read, quotes kept in step with the evidence a note is added to); the warnings of
--      an update (observations, companions)
-- Run: luajit eval/tests/run.lua --only fold

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Fold lifecycle")
local check, finish = T.check, T.finish

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local util     = require("luamemo.util")
local json     = require("luamemo.json")
local store    = require("luamemo.store")
local fold     = require("luamemo.fold")
local digest   = require("luamemo.digest")
local feedback = require("luamemo.feedback")

local DAY = util.DAY_US

-- (luamemo.setup merges onto the config before it: every call names all the fold settings and the digest's tunables
-- the tests change, and the end of each section puts them back, a failed check or a crash included)
local function conf(over)
    H.setup(over, { fold_grace_days = 30, digest_grace_days = false, fold_max_reviews = 2, fold_min_coverage = 0.6, fold_useful_offers = 3,
                    consolidate_reinforce_threshold = false, digest_promote_tier2_at = false, digest_promote_tier3_at = false,
                    digest_escalate_alpha = false, consolidate_threshold = false })
end
conf()
local function section(name, fn) T.section(name, fn, function() conf() end) end

-- the clock
local real_now = util.now_us
local base = real_now()
local offset = 0
util.now_us = function() return base + offset end
local function advance(days) offset = offset + days * DAY end

local n = H.count
local function row(id) return db.first("SELECT id, tier, consolidated_at, body, metadata FROM lm_memories WHERE id = ?", id) end
local function rec(id)
    local r = row(id)
    if not r then return nil end
    local m = type(r.metadata) == "table" and r.metadata or json.decode(tostring(r.metadata)) or {}
    return m.lm_fold
end
local function seed(scope, items)
    local ids = {}
    for i, it in ipairs(items) do
        local r = assert(store.write({ scope = scope, title = it.title or ("note " .. i), body = it.body, importance = it.importance or 0.3,
            dedup_strategy = "append" }))
        ids[i] = r.id
    end
    return ids
end
local function fold_into_summary(scope, ids, title, body)
    return assert(store.replace_with_summary(ids, { scope = scope, title = title, body = body }))
end
-- An observation of `scope` that holds the memories `ids` (what the digest writes), with its vector (so that a search for
-- observations finds it)
local function observe(scope, body, ids)
    local now = util.now_us()
    local blob, norm = require("luamemo.vectors").pack(assert(require("luamemo.embed").embed(body)))
    assert(db.run("INSERT INTO lm_observations (scope, body, evidence_ids, proof_count, last_reinforced, created_at, embedding, emb_norm) "
        .. "VALUES (?, ?, ?, 1, ?, ?, ?, ?)", scope, body, db.json(ids), now, now, db.blob(blob), norm))
end
-- A tier-0 note of `scope` (title = body = text; importance 0.2 unless given) → its id; and `times` (2) reinforcement
-- events of `kind` ("mistake", "praise", …) on a memory
local function put(scope, text, importance)
    return assert(store.write({ scope = scope, title = text, body = text, importance = importance or 0.2, tier = 0, dedup_strategy = "append" })).id
end
local function events(id, scope, kind, times) for _ = 1, times or 2 do assert(feedback.record_reinforcement(id, scope, kind)) end end
-- probes of one memory / one scope (rec and row above answer the fold record and the columns they read)
local consolidate = require("luamemo.consolidate")
local function tier_of(id) local r = row(id); return r and tonumber(r.tier) end
local function imp_of(id) return tonumber(db.value("SELECT importance FROM lm_memories WHERE id = ?", id)) end
local function folded_id(id) return rec(id) ~= nil end
local function consolidated(id) local r = row(id); return r ~= nil and r.consolidated_at ~= nil end
local function obs_count(sc) return n("SELECT count(*) FROM lm_observations WHERE scope = ?", sc) end
-- A note a digest does not take (no vector) at `tier`, and an observation of `sc` that holds `ids` with a proof count and a
-- trend: what the promotions are tested on
local function member(sc, tier, text)
    local id = put(sc, text or ("member of an observation, tier " .. tier .. " in " .. sc .. " " .. tostring(math.random(1e9))))
    db.run("UPDATE lm_memories SET tier = ?, embedding = NULL WHERE id = ?", tier, id)   -- (no vector: the digest does not fold it)
    return id
end
local function holds(sc, ids, proof, trend)
    observe(sc, "observation " .. tostring(math.random(1e9)) .. " holding " .. #ids .. " memories", ids)
    db.run("UPDATE lm_observations SET proof_count = ?, freshness_trend = ? WHERE id = (SELECT max(id) FROM lm_observations)", proof, trend)
end
-- a text long enough that a variant with one more word is still far above the reinforce threshold of it
local BASE = "the quarterly capacity review covers storage compute network database cache queue gateway balancer cluster backup restore failover logging metrics tracing alerting dashboards runbooks onboarding rotation escalation postmortem"
local function log_lines()
    local f = io.open(fold.log_path(), "rb")
    if not f then return {} end
    local out = {}
    for line in f:lines() do local t = json.decode(line); if t then out[#out + 1] = t end end
    f:close()
    return out
end
local function last_log() local l = log_lines(); return l[#l] end

local ORIGINALS = {
    { title = "retry", body = "The client retries with exponential backoff. RETRY_MAX=5 and the cap is 5 s." },
    { title = "cache", body = "The cache key holds tenant_id. See cache.lua for build_key." },
    { title = "notes", body = "Release notes are written before tagging." },
}

section("archive: hidden, kept, recorded", function()
    local scope = "repo:fold-a"
    local ids = seed(scope, ORIGINALS)
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap); the cache key holds tenant_id (cache.lua build_key); release notes precede tagging.")
    check("the three originals are still there", n("SELECT count(*) FROM lm_memories WHERE scope = ? AND kind != 'summary'", scope) == 3)
    local r = rec(ids[1])
    check("each is hidden (tier 0, consolidated) and carries its record",
        row(ids[1]).tier == 0 and row(ids[1]).consolidated_at ~= nil and r and r.into_kind == "summary" and r.into_id == s.id
        and r.reviews == 0 and r.tier_before == 1 and r.review_at - r.folded_at == 30 * DAY, json.encode(r))
    local hits = luamemo.search({ scope = scope, query = "retry backoff RETRY_MAX tenant_id release notes", limit = 20, skip_feedback = true })
    local kinds = {}
    for _, h in ipairs(hits or {}) do kinds[h.kind] = (kinds[h.kind] or 0) + 1 end
    check("a search finds the summary, not the archived originals", kinds.summary == 1 and (kinds.fact or 0) + (kinds.note or 0) == 0
        and #(hits or {}) == 1, json.encode(kinds))
    local hits0 = luamemo.search({ scope = scope, query = "retry backoff RETRY_MAX", limit = 20, tier_min = 0, skip_feedback = true })
    check("… not even when it asks for tier 0", #(hits0 or {}) == 1 and hits0[1].kind == "summary")
    check("recent does not list them", #(store.recent({ scope = scope }) or {}) == 1)
    check("no maintenance pass selects them: clustering, summarizing, expiring",
        #(store.find_clusters({ scope = scope, similarity_threshold = 0 }) or {}) == 0
        and #(store.select_for_summarization({ scope = scope, weight_threshold = 99, retention_days = 0 }) or {}) == 0
        and #(store.find_decayed({ scope = scope, apply = false }) or {}) == 0)
end)

section("before and after the grace period: delete", function()
    local scope = "repo:fold-b"
    local ids = seed(scope, ORIGINALS)
    fold_into_summary(scope, ids, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap); the cache key holds tenant_id (cache.lua build_key); release notes precede tagging.")
    advance(29)
    local early = fold.run(scope)
    check("29 days in: nothing is due", early.reviewed == 0 and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND kind != 'summary'", scope) == 3)
    advance(2)
    local res = fold.run(scope)
    check("31 days in: all three reviewed and deleted (not useful; the summary holds their facts)",
        res.reviewed == 3 and res.deleted == 3 and n("SELECT count(*) FROM lm_memories WHERE scope = ?", scope) == 1, json.encode(res))
    local l = last_log()
    check("the decision was logged: who, why, the coverage", l and l.decision == "delete" and l.scope == scope and l.coverage and l.memory, json.encode(l))
end)

section("useful, summary lost the facts: correct, grace again, then delete", function()
    local scope = "repo:fold-c"
    local ids = seed(scope, ORIGINALS)
    fold_into_summary(scope, ids, "Notes", "Some notes on retries, caching and releases.")   -- keeps none of RETRY_MAX, tenant_id, cache.lua
    assert(feedback.record_reinforcement(ids[1], scope, "praise"))   -- the retry note was useful
    advance(31)
    local res = fold.run(scope)
    check("the useful one is corrected; the other two (never useful) are deleted",
        res.corrected == 1 and res.deleted == 2, json.encode(res))
    local s = db.first("SELECT id, body FROM lm_memories WHERE scope = ? AND kind = 'summary'", scope)
    check("the summary now holds what it lost (RETRY_MAX=5), added from the note itself",
        s.body:find("RETRY_MAX=5", 1, true) and s.body:find("Kept from an earlier note", 1, true), s.body)
    local r = rec(ids[1])
    check("the note is back in grace: still there, hidden, review in 30 days, one correction",
        row(ids[1]) and row(ids[1]).tier == 0 and r.reviews == 1 and r.review_at - (base + offset) == 30 * DAY, json.encode(r))
    local logged_correct = false
    for _, l in ipairs(log_lines()) do if l.memory == ids[1] and l.decision == "correct" then logged_correct = true end end
    check("the correction was logged", logged_correct)
    advance(31)
    local again = fold.run(scope)
    check("at the next review the summary holds its facts: deleted", again.deleted == 1 and row(ids[1]) == nil, json.encode(again))
end)

section("the summary was marked wrong: correct; past the limit: restored", function()
    local scope = "repo:fold-d"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap) and RETRY_MAX=5.")   -- holds every token
    advance(5)
    assert(feedback.record_reinforcement(s.id, scope, "mistake"))   -- the person corrected the agent that used the summary
    advance(26)
    local r1 = fold.run(scope)
    check("never useful and fully covered, but the summary was marked wrong: nothing missing to add, so the note is restored (not corrected, not deleted)",
        r1.restored == 1 and r1.corrected == 0 and r1.deleted == 0, json.encode(r1))
    -- a summary that lost a fact and keeps being marked wrong: corrected twice, then restored
    local scope2 = "repo:fold-d2"
    local ids2 = seed(scope2, { { title = "retry", body = "Backoff doubles. RETRY_MAX=5 caps it. Alert INC-2291 was the cause." } })
    local s2 = fold_into_summary(scope2, ids2, "Notes", "A note on retries.")
    local outcomes = {}
    for _ = 1, 3 do
        advance(2)
        assert(feedback.record_reinforcement(s2.id, scope2, "mistake"))
        advance(29)
        local r = fold.run(scope2)
        outcomes[#outcomes + 1] = (r.corrected > 0 and "correct") or (r.restored > 0 and "restore") or (r.deleted > 0 and "delete") or "none"
        -- the summary is rewritten, losing the facts again (the case where another correction helps)
        db.run("UPDATE lm_memories SET body = 'A note on retries.' WHERE id = ?", s2.id)
    end
    check("each review while the summary stays marked wrong and lost its facts corrects it — until the limit (2), then the note is restored, never deleted",
        outcomes[1] == "correct" and outcomes[2] == "correct" and outcomes[3] == "restore", table.concat(outcomes, ","))
    -- marked wrong, but it already holds every fact of the note: there is nothing to add, the note is the only reference → restored
    local scope3 = "repo:fold-d3"
    local ids3 = seed(scope3, { ORIGINALS[1] })
    local s3 = fold_into_summary(scope3, ids3, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap).")
    advance(2)
    assert(feedback.record_reinforcement(s3.id, scope3, "mistake"))
    advance(29)
    local r3 = fold.run(scope3)
    check("marked wrong with nothing to add: the note is restored, not deleted", r3.restored == 1 and r3.deleted == 0 and row(ids3[1]).tier == 1, json.encode(r3))
    local back = row(ids2[1])
    check("restored: visible again at the tier it had, no fold record", back and back.tier == 1 and rec(ids2[1]) == nil)
end)

section("the summary is gone: restored", function()
    local scope = "repo:fold-e"
    local ids = seed(scope, { ORIGINALS[2] })
    local s = fold_into_summary(scope, ids, "Notes", "tenant_id and cache.lua build_key.")
    db.run("DELETE FROM lm_memories WHERE id = ?", s.id)
    advance(31)
    local res = fold.run(scope)
    check("the only copy of the facts comes back", res.restored == 1 and row(ids[1]).tier == 1 and rec(ids[1]) == nil, json.encode(res))
end)

section("raw conversation the digest consolidated", function()
    local scope = "repo:fold-f"
    local raws = {}
    for i = 1, 3 do
        raws[i] = assert(store.write({ scope = scope, title = "step " .. i, importance = 0.2, dedup_strategy = "append",
            body = "ran migration " .. i .. " on staging; table orders_v" .. i .. " rebuilt" })).id
    end
    local d = digest.run(scope)
    check("the digest ran and archived the rows (not deleted): hidden, recorded as folded into an observation",
        d.processed >= 1 and row(raws[1]) and rec(raws[1]) and rec(raws[1]).into_kind == "observation", json.encode(d))
    check("the old purge is gone: a digest run right after deletes nothing", (digest.run(scope).deleted or 0) == 0 and row(raws[1]) ~= nil)
    assert(feedback.record_reinforcement(raws[2], scope, "praise"))
    -- make the observation lose raws[2]'s facts, so its review has something to correct
    db.run("UPDATE lm_observations SET body = 'an unrelated note' WHERE scope = ? AND EXISTS (SELECT 1 FROM json_each(evidence_ids) WHERE CAST(value AS INTEGER) = ?)", scope, raws[2])
    advance(31)
    local res = fold.run(scope)
    check("the useful row is corrected into its observation, the other two deleted", res.corrected == 1 and res.deleted == 2, json.encode(res))
    local obs = db.first("SELECT body FROM lm_observations WHERE scope = ? AND EXISTS (SELECT 1 FROM json_each(evidence_ids) WHERE CAST(value AS INTEGER) = ?)", scope, raws[2])
    check("the observation holds the facts it lost", obs and obs.body:find("orders_v2", 1, true) ~= nil, obs and obs.body)
    -- no observation holds it at all: kept if it ever helped
    local scope2 = "repo:fold-f2"
    local lone = assert(store.write({ scope = scope2, title = "lone", importance = 0.2, body = "one more step orders_v9" })).id
    require("luamemo.fold").archive({ lone }, "observation", nil)
    assert(feedback.record_reinforcement(lone, scope2, "praise"))
    advance(31)
    local res2 = fold.run(scope2)
    check("raw row no observation holds, but useful: kept (hidden for good), not deleted", res2.kept == 1 and row(lone) and rec(lone).state == "kept", json.encode(res2))
    advance(31)
    check("a kept row is out of every pass", fold.run(scope2).reviewed == 0 and row(lone) ~= nil)
end)

section("the pure parts and the code index", function()
    local sal = fold.salient("Set RETRY_MAX=5 in cache.lua; see build_key, camelCase and HTTP 500 at v0.4.2.")
    check("salient tokens: numbers, identifiers, file names, camelCase, ALLCAPS",
        sal["retry_max"] and sal["cache.lua"] and sal["build_key"] and sal["camelcase"] and sal["http"] and sal["v0.4.2"] and sal["500"]
        and not sal["see"] and not sal["set"], json.encode(sal))
    local cov, missing = fold.coverage("RETRY_MAX and tenant_id", "only tenant_id here")
    check("coverage: half kept; the missing token named", math.abs(cov - 0.5) < 1e-9 and missing[1] == "retry_max", cov .. " " .. json.encode(missing))
    check("coverage: nothing specific to lose is full coverage", fold.coverage("just plain words here", "anything") == 1)
    local d = fold.decide
    local base_ev = { coverage = 1, reviews = 0, max_reviews = 2, min_coverage = 0.6 }
    local function ev(over) local e = {}; for k, v in pairs(base_ev) do e[k] = v end; for k, v in pairs(over) do e[k] = v end; return e end
    check("decide: not useful, covered → delete", d(ev({})) == "delete")
    check("decide: useful and covered → delete", d(ev({ useful = true })) == "delete")
    check("decide: useful and under the coverage → correct", d(ev({ useful = true, coverage = 0.3 })) == "correct")
    check("decide: not useful and under the coverage → delete (its facts were not worth keeping)", d(ev({ coverage = 0.1 })) == "delete")
    check("decide: summary marked wrong → correct, restore once out of corrections",
        d(ev({ target_flawed = true })) == "correct" and d(ev({ target_flawed = true, reviews = 2 })) == "restore")
    check("decide: summary gone → restore (raw: only if useful)", d(ev({ target_missing = true })) == "restore"
        and d(ev({ target_missing = true, raw = true })) == "delete" and d(ev({ target_missing = true, raw = true, useful = true })) == "restore")
    local s = fold._sentences("First one. See cache.lua for build_key! Third?\nFourth line")
    check("sentences: a dot inside cache.lua is not an end", #s == 4 and s[2] == "See cache.lua for build_key", json.encode(s))
    -- the code index is never reviewed, folded or selected
    local scope = "codeindex:fold-g"
    local dep = assert(store.write({ scope = scope, kind = "dependency", title = "a.lua → b", body = "a requires b", importance = 0.2, dedup_strategy = "append" })).id
    db.run("UPDATE lm_memories SET updated_at = 1 WHERE id = ?", dep)
    check("fold.run on the code index does nothing", fold.run(scope).skipped == "codeindex")
    check("digest.run on the code index does nothing", digest.run(scope).skipped == "codeindex")
    check("summarizing never selects a code-index row, however old and light",
        #(store.select_for_summarization({ scope = scope, weight_threshold = 99, retention_days = 0 }) or {}) == 0)
    check("the settings exist with their defaults", require("luamemo.settings").defaults().fold_grace_days == 30
        and require("luamemo.settings").defaults().fold_max_reviews == 2)
end)

section("a new raw write never lands in an archived original", function()
    local scope = "repo:fold-h"
    local TEXT = "ran migration 41 on staging; table orders_v41 rebuilt and checked"
    local raw = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, body = TEXT, dedup_strategy = "append" }))
    fold.archive({ raw.id }, "observation", nil)
    local one = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, body = TEXT .. " (single)", dedup_strategy = "update" }))
    check("a single write that repeats it makes a row of its own", one.id ~= raw.id)
    store.write_many({ { scope = scope, title = "step", importance = 0.2, tier = 0, body = TEXT .. " (many)" } }, { dedup_strategy = "update" })
    check("write_many does the same", n("SELECT count(*) FROM lm_memories WHERE scope = ? AND body LIKE '%(many)'", scope) == 1
        and n("SELECT count(*) FROM lm_memories WHERE id = ? AND body LIKE '%(many)'", raw.id) == 0)
    check("the archived original is untouched: its words, its record", row(raw.id).body == TEXT and rec(raw.id) ~= nil)
end)

section("what makes a memory useful, and that the settings are read", function()
    local LOST = "Some notes on retries, caching and releases."   -- keeps none of RETRY_MAX, tenant_id, cache.lua
    local function lossy(scope)
        local ids = seed(scope, { ORIGINALS[1] })
        fold_into_summary(scope, ids, "Notes", LOST)
        return ids[1]
    end
    local function offer(id, scope, times)
        for i = 1, times do feedback.log_retrieval(scope, "retry question " .. i, { id }) end
    end
    local a = "repo:fold-i1"
    local ida = lossy(a); offer(ida, a, 2)
    advance(31)
    check("offered twice (under MEMO_FOLD_USEFUL_OFFERS): not useful, deleted", fold.run(a).deleted == 1 and row(ida) == nil)
    local b = "repo:fold-i2"
    local idb = lossy(b); offer(idb, b, 3)
    advance(31)
    check("offered three times: useful, and the summary lost its facts → corrected", fold.run(b).corrected == 1 and row(idb) ~= nil)
    local c = "repo:fold-i3"
    local idc = lossy(c)
    assert(feedback.record_reinforcement(idc, c, "direct_command"))
    advance(31)
    check("a direct command on it: useful → corrected", fold.run(c).corrected == 1 and row(idc) ~= nil)

    -- the settings: a 5-day grace, nothing may be corrected twice (none at all), a high bar for the summary
    local PART = "The client retries with exponential backoff. RETRY_MAX and tenant_id and cache.lua build_key."
    local function partial(scope)   -- a summary that kept 3 of the note's 4 concrete tokens (75 %)
        local ids = seed(scope, { { title = "tokens", body = "RETRY_MAX tenant_id cache.lua build_key all matter here." } })
        fold_into_summary(scope, ids, "Notes", PART:gsub("build_key", "x"))
        assert(feedback.record_reinforcement(ids[1], scope, "praise"))
        return ids[1]
    end
    local d = "repo:fold-i4"
    local idd = partial(d)
    advance(31)
    check("default bar (0.6): 75 % kept is enough → deleted", fold.run(d).deleted == 1 and row(idd) == nil)
    conf({ fold_grace_days = 5, fold_max_reviews = 0, fold_min_coverage = 0.9, fold_useful_offers = 1 })
    local e = "repo:fold-i5"
    local ide = partial(e)
    check("MEMO_FOLD_GRACE_DAYS is read: review in 5 days", rec(ide).review_at - rec(ide).folded_at == 5 * DAY, json.encode(rec(ide)))
    advance(6)
    local res = fold.run(e)
    check("MEMO_FOLD_MIN_COVERAGE (0.9) and MEMO_FOLD_MAX_REVIEWS (0) are read: under the bar, no corrections allowed → restored, not deleted",
        res.restored == 1 and res.deleted == 0 and row(ide).tier == 1, json.encode(res))
    local f = "repo:fold-i6"
    local idf = lossy(f); offer(idf, f, 1)
    advance(6)
    check("MEMO_FOLD_USEFUL_OFFERS (1) is read: one offer is enough → restored", fold.run(f).restored == 1 and row(idf) ~= nil)
end)

section("rows consolidated before folds were recorded (no lm_fold)", function()
    local scope = "repo:fold-j"
    local function legacy(title, body, days_ago)
        local id = assert(store.write({ scope = scope, title = title, importance = 0.2, tier = 0, body = body, dedup_strategy = "append" })).id
        db.run("UPDATE lm_memories SET consolidated_at = ?, metadata = '{}' WHERE id = ?", util.now_us() - days_ago * DAY, id)
        return id
    end
    local praised = legacy("a", "legacy step one about deploy_keys rotation", 40)
    local plain   = legacy("b", "legacy step two about cron_jobs listing", 40)
    local young   = legacy("c", "legacy step three about log_rotate", 5)
    assert(feedback.record_reinforcement(praised, scope, "praise"))
    local r1 = fold.run(scope)
    check("an old one nobody praised is deleted; a praised one is kept, hidden for good; a young one is left alone",
        row(plain) == nil and row(praised) ~= nil and rec(praised) and rec(praised).state == "kept" and row(young) ~= nil and r1.reviewed == 2,
        json.encode(r1))
    check("the decision was written: the kept one is not reviewed again", fold.run(scope).reviewed == 0)
end)

section("the decay pass leaves a folded original and the code index alone", function()
    local scope = "repo:fold-k"
    local ids = seed(scope, { { title = "old a", body = "decaying note about nightly_backup" }, { title = "old b", body = "decaying note about weekly_report" } })
    local ctrl = ids[2]
    fold.archive({ ids[1] }, "observation", nil)
    local code = assert(store.write({ scope = "codeindex:fold-k", kind = "dependency", title = "x → y", body = "x requires y", importance = 0.3, dedup_strategy = "append" })).id
    db.run("UPDATE lm_memories SET decay_rate = 1.0, updated_at = ? WHERE id IN (?, ?, ?)", util.now_us() - 400 * DAY, ids[1], ctrl, code)
    local found = {}
    for _, r in ipairs(store.find_decayed({ scope = scope, decay_threshold = 99, apply = false }) or {}) do
        found[tonumber(type(r) == "table" and r.id or r)] = true
    end
    check("the ordinary old memory is found (the control: the pass does select)", found[ctrl] == true)
    check("… the archived original is not", found[ids[1]] == nil)
    store.find_decayed({ scope = scope, decay_threshold = 99, apply = true })
    store.find_decayed({ scope = "codeindex:fold-k", decay_threshold = 99, apply = true })
    check("applying the pass changes neither: their importance is what it was",
        n("SELECT importance FROM lm_memories WHERE id = ?", ids[1]) == 0.3 and n("SELECT importance FROM lm_memories WHERE id = ?", code) == 0.3)
end)

section("the log: written before the delete, private, rotated", function()
    local scope = "repo:fold-l"
    local ids = seed(scope, { ORIGINALS[3] })
    fold_into_summary(scope, ids, "Notes", "Release notes are written before tagging.")
    advance(31)
    -- the log is read at the very moment the DELETE statement is issued: the decision has to be there already
    local real_run, there_at_delete = db.run, nil
    local ok, err = pcall(H.with, db, "run", function(sql, ...)
        if tostring(sql):find("DELETE FROM lm_memories WHERE id = ?", 1, true) then
            there_at_delete = false
            for _, l in ipairs(log_lines()) do if l.memory == ids[1] and l.decision == "delete" then there_at_delete = true end end
        end
        return real_run(sql, ...)
    end, fold.run, scope)
    check("the decision to delete is in the log at the moment the delete is issued", ok and there_at_delete == true, tostring(err))
    check("… and the delete went through", row(ids[1]) == nil)
    check("the log is private to its owner (0600), like the database", H.mode(fold.log_path()) == "600")
    -- a log an older version made world-readable is made private on the first write of this process
    fold._private[fold.log_path()] = nil
    os.execute(("chmod 644 %q"):format(fold.log_path()))
    check("(set up: the log is 0644)", H.mode(fold.log_path()) == "644")
    fold.log({ run = "test", note = "after an older version's log" })
    check("an existing log is made private (0600)", H.mode(fold.log_path()) == "600")
    -- past 1 MB it is rotated, not grown for ever
    local f = assert(io.open(fold.log_path(), "ab")); f:write(("x"):rep(1024 * 1024 + 10), "\n"); f:close()
    fold.log({ run = "test", note = "after the rotation" })
    check("past 1 MB the log is rotated to .1 and a new one starts", util.exists(fold.log_path() .. ".1")
        and (last_log() or {}).note == "after the rotation")
    check("… the new log is private too (created under the umask, not by the one-time chmod)", H.mode(fold.log_path()) == "600")
    -- a rotation an older version left world-readable
    os.execute(("chmod 644 %q"):format(fold.log_path() .. ".1"))
    fold._private[fold.log_path()] = nil
    fold.log({ run = "test", note = "again" })
    check("… and so is the rotated .1 (made private with the log)", H.mode(fold.log_path() .. ".1") == "600")
    os.remove(fold.log_path() .. ".1")
end)

section("the audit line comes first, or nothing is deleted", function()
    local scope = "repo:fold-s"
    local ids = seed(scope, { ORIGINALS[1], ORIGINALS[3] })
    fold_into_summary(scope, ids, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap); release notes precede tagging.")
    advance(31)
    -- the log cannot be written: its directory does not exist
    local path = fold.log_path()
    local res = H.with(fold, "log_path", function() return "/nonexistent-luamemo-dir/maintenance.log" end, fold.run, scope)
    check("with no way to record the decision nothing is deleted, and the run says so once and stops (every later delete would fail alike)",
        res.deleted == 0 and res.reviewed == 0 and #res.errors == 1 and res.errors[1]:find("log could not be written", 1, true)
        and row(ids[1]) ~= nil and row(ids[2]) ~= nil, json.encode(res))
    fold._private[path] = nil
    check("… once the log works again the same review goes through", fold.run(scope).deleted == 2 and row(ids[1]) == nil)
    -- a symlink at the log's name is not followed: no append, no chmod through it
    local target = os.tmpname()
    local fh = assert(io.open(target, "w")); fh:write("precious\n"); fh:close()
    os.execute(("chmod 644 %q; mv %q %q.keep 2>/dev/null; ln -s %q %q"):format(target, path, path, target, path))
    fold._private[path] = nil
    local wrote = fold.log({ run = "test", note = "through a link" })
    local after = H.slurp(target)
    os.execute(("rm -f %q; mv %q.keep %q 2>/dev/null"):format(path, path, path))
    check("a symlink where the log should be is refused: nothing is appended to its target, its mode is not changed",
        wrote == false and after == "precious\n" and H.mode(target) == "644", tostring(wrote) .. " / " .. tostring(after))
    os.remove(target)
    fold._private[path] = nil
end)

section("a summary that is gone gives the memory back; a summary marked wrong by a reversal is corrected", function()
    -- a tier-0 memory folded into a SUMMARY, the summary deleted: the memory is the only copy of its facts
    local scope = "repo:fold-t"
    local ids = seed(scope, { { title = "ephemeral a", body = "the nightly_backup runs at 03:00 and keeps 7 copies", importance = 0.2 },
                              { title = "ephemeral b", body = "the weekly_report goes out on friday", importance = 0.2 } })
    db.run("UPDATE lm_memories SET tier = 0 WHERE id IN (?, ?)", ids[1], ids[2])
    local s = assert(store.replace_with_summary(ids, { scope = scope, title = "S", body = "backups and reports" }))
    check("(set up: tier 0 before the fold)", rec(ids[1]).tier_before == 0 and rec(ids[1]).into_kind == "summary")
    db.run("DELETE FROM lm_memories WHERE id = ?", s.id)
    advance(31)
    local res = fold.run(scope)
    check("both are kept (hidden for good, like any tier-0 memory), neither deleted", res.kept == 2 and res.deleted == 0
        and row(ids[1]) ~= nil and row(ids[2]) ~= nil, json.encode(res))
    -- the other road: conversation the digest folded into an observation that no longer holds it, never useful → deleted
    local scope2 = "repo:fold-t2"
    local raw = assert(store.write({ scope = scope2, title = "step", importance = 0.2, tier = 0, body = "ran step 77 on staging", dedup_strategy = "append" })).id
    fold.archive({ raw }, "observation", nil)
    advance(31)
    check("(control) raw conversation no observation holds, never useful: deleted", fold.run(scope2).deleted == 1 and row(raw) == nil)
    -- a reversal on the summary marks it wrong as much as a mistake does
    local scope3 = "repo:fold-t3"
    local ids3 = seed(scope3, { ORIGINALS[1] })
    local s3 = fold_into_summary(scope3, ids3, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap).")
    advance(2)
    assert(feedback.record_reinforcement(s3.id, scope3, "reversal"))
    advance(29)
    local r3 = fold.run(scope3)
    check("a summary contradicted since the fold (a reversal): the original is restored, not deleted as 'not shown useful'",
        r3.deleted == 0 and (r3.restored + r3.corrected) == 1 and row(ids3[1]) ~= nil, json.encode(r3))
end)

section("a failed archive is an error, and the errors reach the report", function()
    local scope = "repo:fold-u"
    for i = 1, 2 do
        assert(store.write({ scope = scope, title = "step " .. i, importance = 0.2, tier = 0, dedup_strategy = "append",
            body = "ran migration " .. (80 + i) .. " on staging; table orders_w" .. i .. " rebuilt" }))
    end
    -- (the archive's own write — the fold record in metadata — fails; the consolidation's mark of the rows is not blocked)
    local d = H.with_trigger("fold_test_no_archive3", "BEFORE UPDATE OF metadata ON lm_memories WHEN json_type(NEW.metadata, '$.lm_fold') IS NOT NULL "
        .. "BEGIN SELECT RAISE(ABORT, 'no archive'); END", digest.run, false, scope)
    check("the digest says the cluster could not be archived and does not count it processed",
        d.processed == 0 and #d.errors >= 1 and tostring(d.errors[1]):find("archive error", 1, true)
        and H.folded(scope) == 0, json.encode(d))
    local mnt = require("luamemo.maintenance")
    local p = mnt.problems({ digest = { errors = { "archive error: x" } }, review = { errors = { "memory 1: boom", "memory 2: boom" } },
                             summarize = { error = "it raised" } })
    check("maintenance.problems lists what went wrong in a run: a part that raised and the rows or clusters that failed",
        p and #p == 4 and mnt.problems({ digest = { processed = 3 }, review = { errors = {} } }) == nil)
end)

section("a record nobody can trust, and a review that cannot stop", function()
    -- the record is metadata any writer can set: a summary in ANOTHER scope, or a number that is not one
    local foreign_scope, scope = "repo:fold-n-other", "repo:fold-n"
    local foreign = assert(store.write({ scope = foreign_scope, title = "not mine", body = "a memory of another scope about retry_max", importance = 1, dedup_strategy = "append" }))
    local function forged(title, body, into_id)
        local id = assert(store.write({ scope = scope, title = title, body = body, importance = 0.2, tier = 0, dedup_strategy = "append" })).id
        db.run("UPDATE lm_memories SET consolidated_at = ?, metadata = ? WHERE id = ?", util.now_us() - 40 * DAY,
            json.encode({ lm_fold = { into_kind = "summary", into_id = into_id, state = "grace", review_at = util.now_us() - DAY,
                                      tier_before = 1, reviews = 0, folded_at = util.now_us() - 40 * DAY } }), id)
        assert(feedback.record_reinforcement(id, scope, "praise"))   -- useful: with a summary that lost its facts, it would be 'corrected'
        return id
    end
    forged("across", "tenant_id and RETRY_MAX and cache.lua matter here", foreign.id)
    forged("junk", "build_key and nightly_backup matter here", "abc")
    local res = fold.run(scope, {})
    check("a record pointing at another scope's memory, or at nothing numeric, is a summary that is gone: restored, not corrected, no error",
        res.restored == 2 and res.corrected == 0 and #res.errors == 0, json.encode(res))
    check("… and the other scope's memory was not written to", row(foreign.id).body == "a memory of another scope about retry_max")
    -- a review that raises on one row goes on with the rest
    local scope2 = "repo:fold-o"
    local ids = seed(scope2, { { title = "BOOM", body = "this one makes the review raise" }, { title = "fine", body = "this one is reviewed after it" } })
    fold_into_summary(scope2, ids, "Notes", "this one makes the review raise; this one is reviewed after it.")
    advance(31)
    local real_coverage = fold.coverage
    local res2 = H.with(fold, "coverage", function(a, b)
        if tostring(a):find("BOOM", 1, true) then error("boom") end
        return real_coverage(a, b)
    end, fold.run, scope2, {})
    check("one row raised: it is reported, the other was still reviewed", #res2.errors == 1 and res2.errors[1]:find("boom", 1, true) and res2.deleted == 1
        and row(ids[2]) == nil and row(ids[1]) ~= nil, json.encode(res2))
    local logged_error = false
    for _, l in ipairs(log_lines()) do if l.run == "review" and l.memory == ids[1] and tostring(l.error):find("boom", 1, true) then logged_error = true end end
    check("… and the failure is in the maintenance log", logged_error)
end)

section("folding is all or nothing", function()
    local scope = "repo:fold-p"
    local ids = seed(scope, { { title = "a", body = "all or nothing note one" }, { title = "b", body = "all or nothing note two" } })
    local NO_ARCHIVE = "BEFORE UPDATE OF tier ON lm_memories WHEN NEW.tier = 0 AND OLD.tier != 0 BEGIN SELECT RAISE(ABORT, 'no archive'); END"
    local s, err = H.with_trigger("fold_test_no_archive", NO_ARCHIVE, store.replace_with_summary, false, ids,
        { scope = scope, title = "S", body = "a summary" })
    check("when the originals cannot be archived the call fails", s == nil and tostring(err):find("archive failed", 1, true), tostring(err))
    check("… and no summary is left beside the visible originals",
        n("SELECT count(*) FROM lm_memories WHERE scope = ? AND kind = 'summary'", scope) == 0
        and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND tier >= 1", scope) == 2)
    local archived, why = H.with_trigger("fold_test_no_archive2", NO_ARCHIVE, fold.archive, false, { ids[1] }, "summary", nil)
    check("fold.archive says why instead of answering 0", archived == nil and why ~= nil)
end)

section("the grace of a raw row follows the one setting, and the control for the dedup guard", function()
    local settings = require("luamemo.settings")
    check("settings.number: unset → the default; set → the config's; a numeric string; false/unset → the default",
        settings.number({}, "fold_grace_days") == 30 and settings.number({ fold_grace_days = 5 }, "fold_grace_days") == 5
        and settings.number({ fold_grace_days = "7" }, "fold_grace_days") == 7 and settings.number({ fold_grace_days = false }, "fold_grace_days") == 30)
    check("digest_grace_days follows fold_grace_days unless it is set",
        settings.number({}, "digest_grace_days") == 30 and settings.number({ fold_grace_days = 5 }, "digest_grace_days") == 5
        and settings.number({ fold_grace_days = 5, digest_grace_days = 9 }, "digest_grace_days") == 9)
    local function grace_of_raw(extra)
        conf(extra)
        local id = assert(store.write({ scope = "repo:fold-q" .. (extra.fold_grace_days or 0), title = "raw", importance = 0.2, tier = 0,
            body = "ran step " .. (extra.fold_grace_days or 0) .. " on staging", dedup_strategy = "append" })).id
        fold.archive({ id }, "observation", nil)
        return rec(id).review_at - rec(id).folded_at
    end
    check("a raw row folded by the digest waits the 30 days of MEMO_FOLD_GRACE_DAYS", grace_of_raw({ fold_grace_days = 30 }) == 30 * DAY)
    check("… 5 when that is 5 (no setting of its own to keep in step)", grace_of_raw({ fold_grace_days = 5 }) == 5 * DAY)
    check("… and its own MEMO_DIGEST_GRACE_DAYS wins when set", grace_of_raw({ fold_grace_days = 5, digest_grace_days = 9 }) == 9 * DAY)
    conf()

    -- the control for "a new raw write never lands in an archived original": the very same write DOES merge into a visible twin
    local scope = "repo:fold-r"
    local TEXT = "ran migration 52 on staging; table orders_v52 rebuilt and checked"
    local twin = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, body = TEXT, dedup_strategy = "append" }))
    local again = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, body = TEXT .. " (single)", dedup_strategy = "update" }))
    check("(control) with the twin visible the same write is merged into it — so the archived case above is the guard at work", again.id == twin.id)
end)

section("a dry run reports what the real run would do, raw rows included", function()
    local scope = "repo:fold-m"
    local lone = assert(store.write({ scope = scope, title = "lone", importance = 0.2, tier = 0, body = "one more step orders_v77" })).id
    fold.archive({ lone }, "observation", nil)
    assert(feedback.record_reinforcement(lone, scope, "praise"))
    advance(31)
    local dry = fold.run(scope, { dry_run = true })
    check("a praised raw row no observation holds is 'kept' in the dry run too, and nothing changed",
        dry.kept == 1 and dry.restored == 0 and rec(lone).state ~= "kept", json.encode(dry))
    check("… and the real run agrees", fold.run(scope).kept == 1)
end)

section("a lookup or a query that fails decides nothing", function()
    local real_first, real_value = db.first, db.value
    local function locked_on(fragment)   -- db.first / db.value that fail on a statement holding `fragment`
        return function(sql, ...)
            if tostring(sql):find(fragment, 1, true) then return nil, "database is locked" end
            return real_first(sql, ...)
        end
    end
    -- raw conversation an observation DOES hold
    local scope = "repo:fold-v"
    local raw = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, body = "ran step 91 on staging", dedup_strategy = "append" })).id
    observe(scope, "ran step 91 on staging", { raw })
    fold.archive({ raw }, "observation", nil)
    assert(feedback.record_reinforcement(raw, scope, "praise"))   -- useful: found, its facts are in the observation → deleted; not found → kept
    advance(31)
    local res = H.with(db, "first", locked_on("FROM lm_observations"), fold.run, scope)
    check("the observation could not be looked up: raw conversation it holds is not taken for unheld and deleted",
        res.deleted == 0 and row(raw) ~= nil and #res.errors == 1 and res.errors[1]:find("could not be looked up", 1, true), json.encode(res))
    check("… the row waits as it was (still in grace, no record changed)", rec(raw) and rec(raw).state == nil and rec(raw).reviews == 0)
    local res1 = fold.run(scope)
    check("(control) with the lookup working the same review finds the observation (praised, but its facts are in it: deleted, not kept)",
        res1.deleted == 1 and res1.kept == 0 and row(raw) == nil, json.encode(res1))

    -- the same for a summary: a lookup that fails is not "the summary is gone"
    local scope2 = "repo:fold-v2"
    local ids = seed(scope2, { ORIGINALS[3] })
    fold_into_summary(scope2, ids, "Notes", "Release notes are written before tagging.")
    advance(31)
    local res2 = H.with(db, "first", locked_on("FROM lm_memories WHERE id = ? AND scope = ?"), fold.run, scope2)
    check("a summary that could not be looked up is an error, not a restore", res2.restored == 0 and #res2.errors == 1
        and rec(ids[1]) ~= nil and row(ids[1]).tier == 0, json.encode(res2))

    -- and for the evidence: "could not ask whether it was praised" is not "never praised"
    local scope3 = "repo:fold-v3"
    local lone = assert(store.write({ scope = scope3, title = "lone", importance = 0.2, tier = 0, body = "one more step orders_v91", dedup_strategy = "append" })).id
    fold.archive({ lone }, "observation", nil)
    advance(31)
    local res3 = H.with(db, "value", function(sql, ...)
        if tostring(sql):find("lm_reinforcements", 1, true) then return nil, "database is locked" end
        return real_value(sql, ...)
    end, fold.run, scope3)
    check("a count of praise that fails is an error: the row is not deleted as 'never shown useful'",
        res3.deleted == 0 and row(lone) ~= nil and #res3.errors == 1 and res3.errors[1]:find("query failed", 1, true), json.encode(res3))
end)

section("another run got there first: nothing is deleted from under it", function()
    local scope = "repo:fold-w"
    local ids = seed(scope, { ORIGINALS[3] })
    fold_into_summary(scope, ids, "Notes", "Release notes are written before tagging.")
    advance(31)
    -- between this review's decision and its delete another process (memory_digest takes no lock) restores the memory
    local res = H.with(fold, "log", function()
        db.run("UPDATE lm_memories SET tier = 1, consolidated_at = NULL, metadata = json_remove(metadata, '$.lm_fold') WHERE id = ?", ids[1])
        return true
    end, fold.run, scope)
    check("the delete finds the memory no longer waiting and does nothing; the run says so",
        res.deleted == 0 and row(ids[1]) ~= nil and row(ids[1]).tier == 1 and #res.errors == 1
        and res.errors[1]:find("no longer waiting", 1, true), json.encode(res))
end)

section("a write of the review that fails is an error, not a result", function()
    local scope = "repo:fold-x"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff.")
    db.run("DELETE FROM lm_memories WHERE id = ?", s.id)   -- the summary is gone: the memory is to be restored
    advance(31)
    local function failing_update(name, event, id, fn, ...)   -- an UPDATE of `event` on that memory fails while fn runs
        return H.with_trigger(name, ("BEFORE UPDATE OF %s ON lm_memories WHEN OLD.id = %d BEGIN SELECT RAISE(ABORT, 'no'); END")
            :format(event, id), fn, false, ...)
    end
    local res = failing_update("fold_test_no_restore", "tier", ids[1], fold.run, scope)
    check("a restore that fails is reported and not counted as restored",
        res.restored == 0 and #res.errors == 1 and res.errors[1]:find("the restore failed", 1, true) and row(ids[1]).tier == 0, json.encode(res))
    check("(control) once the write works the same review restores it", fold.run(scope).restored == 1 and row(ids[1]).tier == 1)

    -- a tier-0 memory is 'kept' through set_fold: the same
    local scope2 = "repo:fold-x2"
    local ids2 = seed(scope2, { ORIGINALS[3] })
    db.run("UPDATE lm_memories SET tier = 0 WHERE id = ?", ids2[1])
    local s2 = fold_into_summary(scope2, ids2, "Notes", "Release notes.")
    db.run("DELETE FROM lm_memories WHERE id = ?", s2.id)
    advance(31)
    local res2 = failing_update("fold_test_no_keep", "metadata", ids2[1], fold.run, scope2)
    check("a 'kept' that cannot be written is reported, not counted", res2.kept == 0 and #res2.errors == 1, json.encode(res2))
end)

section("the review's limit and deadline; the .1 symlink; a refused log is not looked at again", function()
    local scope = "repo:fold-y"
    local raws = {}
    for i = 1, 3 do
        raws[i] = assert(store.write({ scope = scope, title = "step " .. i, importance = 0.2, tier = 0, dedup_strategy = "append",
            body = "ran migration " .. (90 + i) .. " on staging; table orders_y" .. i .. " rebuilt" })).id
    end
    fold.archive(raws, "observation", nil)
    advance(31)
    check("a past deadline stops before the first row and says the run was partial",
        (function() local r = fold.run(scope, { deadline = os.time() - 1 }); return r.partial == true and r.reviewed == 0 end)()
        and n("SELECT count(*) FROM lm_memories WHERE scope = ?", scope) == 3)
    check("limit 2 reviews two rows", fold.run(scope, { limit = 2 }).reviewed == 2 and n("SELECT count(*) FROM lm_memories WHERE scope = ?", scope) == 1)
    check("the next run takes the rest", fold.run(scope).reviewed == 1)

    local path = fold.log_path()
    local target = os.tmpname()
    local fh = assert(io.open(target, "w")); fh:write("precious\n"); fh:close()
    os.execute(("ln -s %q %q"):format(target, path .. ".1"))
    fold._private[path] = nil
    local wrote = fold.log({ run = "test", note = "with a link beside it" })
    os.execute(("rm -f %q"):format(path .. ".1"))
    check("a symlink at the rotated name is refused too: nothing is written, the target is untouched",
        wrote == false and H.slurp(target) == "precious\n", tostring(wrote))
    check("a refusal is remembered for the process (the link is not looked for again with every line)",
        fold._private[path] == false and fold.log({ run = "test" }) == false)
    fold._private[path] = nil
    check("(control) with the link gone and the check done again the log is written", fold.log({ run = "test", note = "after" }) == true)
    os.remove(target)
end)

section("an id that was reused is not the summary", function()
    local scope = "repo:fold-j1"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff.")
    assert(store.delete(s.id))
    advance(1)
    -- (ids are not AUTOINCREMENT: the newest row's id is given out again)
    local other = assert(store.write({ scope = scope, title = "unrelated", body = "buy milk", importance = 0.3, dedup_strategy = "append" }))
    check("(set up: the next write takes the deleted summary's id)", other.id == s.id)
    advance(30)
    local res = fold.run(scope)
    check("the summary is gone: the original is restored, not deleted on the strength of an unrelated memory",
        res.restored == 1 and res.deleted == 0 and res.corrected == 0 and row(ids[1]) ~= nil and row(ids[1]).tier == 1, json.encode(res))
    check("… and the unrelated memory was not written to", row(other.id).body == "buy milk")
    -- the same scope, an id that exists, but it is a note and not a summary
    local scope2 = "repo:fold-j2"
    local note = assert(store.write({ scope = scope2, title = "plain note", body = "not a summary at all", importance = 0.3, dedup_strategy = "append" }))
    local o2 = seed(scope2, { ORIGINALS[3] })
    fold.archive({ o2[1] }, "summary", note.id)
    advance(31)
    local r2 = fold.run(scope2)
    check("a record that points at a memory which is not a summary: the summary is gone, the original restored",
        r2.restored == 1 and r2.deleted == 0 and row(note.id).body == "not a summary at all" and row(o2[1]).tier == 1, json.encode(r2))
    -- a memory written AFTER the fold cannot be what it was folded into (the summary is written before its originals are archived)
    local scope3 = "repo:fold-j3"
    local o3 = seed(scope3, { ORIGINALS[3] })
    local s3 = fold_into_summary(scope3, o3, "Notes", "Release notes are written before tagging.")
    check("(control) a summary written before the fold is found: the original is deleted, its facts are in the summary",
        (function() advance(31); return fold.run(scope3).deleted == 1 end)())
    local o4 = seed(scope3, { ORIGINALS[1] })
    fold.archive({ o4[1] }, "summary", s3.id)
    db.run("UPDATE lm_memories SET created_at = ? WHERE id = ?", util.now_us() + DAY, s3.id)
    advance(31)
    local r4 = fold.run(scope3)
    check("… the same row dated after the fold is not: the original is restored", r4.restored == 1 and r4.deleted == 0, json.encode(r4))
end)

section("a second archive does not write over the record", function()
    local scope = "repo:fold-k1"
    local id = assert(store.write({ scope = scope, title = "two", body = "a tier two note", importance = 0.5, tier = 2, dedup_strategy = "append" })).id
    check("(set up) the first archive hides it, remembering tier 2", fold.archive({ id }, "summary", 1) == 1 and rec(id).tier_before == 2)
    local first = rec(id)
    advance(3)
    check("a second archive of the same row changes nothing and says 0",
        fold.archive({ id }, "summary", 2) == 0 and rec(id).tier_before == 2 and rec(id).into_id == 1
        and rec(id).folded_at == first.folded_at and rec(id).review_at == first.review_at, json.encode(rec(id)))
end)

-- Run fn while a competing write happens once, between the review's lookup and its decision (the first count the
-- evidence makes): the other process of a review got there first.
local function racing(competing, fn, ...)
    local real_value, done = db.value, false
    return H.with(db, "value", function(sql, ...)
        if not done and tostring(sql):find("lm_reinforcements", 1, true) then done = true; competing() end
        return real_value(sql, ...)
    end, fn, ...)
end

section("another run got there first: every write of the review re-checks the row", function()
    -- the restore
    local scope = "repo:fold-l1"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff.")
    db.run("DELETE FROM lm_memories WHERE id = ?", s.id)   -- the summary is gone: the memory is to be restored
    advance(31)
    local res = racing(function()
        db.run("UPDATE lm_memories SET tier = 1, consolidated_at = NULL, metadata = json_remove(metadata, '$.lm_fold') WHERE id = ?", ids[1])
    end, fold.run, scope)
    check("a restore finds the memory already restored: nothing is counted, the run says so",
        res.restored == 0 and #res.errors == 1 and res.errors[1]:find("no longer waiting", 1, true) and row(ids[1]).tier == 1, json.encode(res))

    -- 'kept' (a tier-0 memory)
    local scope2 = "repo:fold-l2"
    local ids2 = seed(scope2, { ORIGINALS[3] })
    db.run("UPDATE lm_memories SET tier = 0 WHERE id = ?", ids2[1])
    local s2 = fold_into_summary(scope2, ids2, "Notes", "Release notes.")
    db.run("DELETE FROM lm_memories WHERE id = ?", s2.id)
    advance(31)
    local res2 = racing(function()
        db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.state', 'kept') WHERE id = ?", ids2[1])
    end, fold.run, scope2)
    check("a 'kept' finds the memory already decided: not counted again", res2.kept == 0 and #res2.errors == 1
        and res2.errors[1]:find("no longer waiting", 1, true), json.encode(res2))

    -- the correction: the facts are in the summary by then, the original was not sent back to grace
    local scope3 = "repo:fold-l3"
    local ids3 = seed(scope3, { ORIGINALS[1] })
    fold_into_summary(scope3, ids3, "Notes", "Some notes on retries.")
    assert(feedback.record_reinforcement(ids3[1], scope3, "praise"))
    advance(31)
    local res3 = racing(function()
        db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.state', 'kept') WHERE id = ?", ids3[1])
    end, fold.run, scope3)
    check("a correction whose original was decided meanwhile is not counted, and the run says what was and was not done",
        res3.corrected == 0 and #res3.errors == 1 and res3.errors[1]:find("the target was corrected, but", 1, true)
        and res3.errors[1]:find("no longer waiting", 1, true), json.encode(res3))

    -- not only 'still waiting': still the one that was decided about
    local scope4 = "repo:fold-l4"
    local ids4 = seed(scope4, { ORIGINALS[3] })
    fold_into_summary(scope4, ids4, "Notes", "Release notes are written before tagging.")
    advance(31)
    local res4 = racing(function()   -- corrected by another run: one review more, a new date, still in grace
        db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.reviews', 1, '$.lm_fold.review_at', ?) WHERE id = ?",
            util.now_us() + 30 * DAY, ids4[1])
    end, fold.run, scope4)
    check("a delete decided on the row as it was is refused once another run has reviewed it since",
        res4.deleted == 0 and row(ids4[1]) ~= nil and #res4.errors == 1 and res4.errors[1]:find("no longer waiting", 1, true), json.encode(res4))
    local scope5 = "repo:fold-l5"
    local ids5 = seed(scope5, { ORIGINALS[3] })
    fold_into_summary(scope5, ids5, "Notes", "Release notes are written before tagging.")
    advance(31)
    local res5 = racing(function()   -- restored and folded anew by another run: a new consolidated_at
        db.run("UPDATE lm_memories SET consolidated_at = consolidated_at + 1000 WHERE id = ?", ids5[1])
    end, fold.run, scope5)
    check("… and so is one that was folded again since", res5.deleted == 0 and row(ids5[1]) ~= nil and #res5.errors == 1, json.encode(res5))
end)

section("a correction that cannot be made gives the original back", function()
    local function last_why() return (last_log() or {}).why end
    -- no room left in the summary
    local scope = "repo:fold-n2"
    local ids = seed(scope, { ORIGINALS[1] })
    fold_into_summary(scope, ids, "Notes", ("word "):rep(770))   -- 3850 characters: the added line does not fit under the 4 KB cap
    assert(feedback.record_reinforcement(ids[1], scope, "praise"))
    advance(31)
    local res = fold.run(scope)
    check("a summary with no room left: restored, not corrected, never deleted",
        res.restored == 1 and res.corrected == 0 and res.deleted == 0 and row(ids[1]).tier == 1, json.encode(res))
    check("… the log says it was restored and why", (last_log() or {}).decision == "restore" and tostring(last_why()):find("no room left", 1, true), json.encode(last_log()))
    -- the summary cannot be updated
    local scope2 = "repo:fold-n3"
    local ids2 = seed(scope2, { ORIGINALS[1] })
    fold_into_summary(scope2, ids2, "Notes", "Some notes on retries.")
    assert(feedback.record_reinforcement(ids2[1], scope2, "praise"))
    advance(31)
    local res2 = H.with(store, "update", function() return nil, "boom" end, fold.run, scope2)
    check("an update of the summary that fails: restored, and the log carries the reason",
        res2.restored == 1 and res2.corrected == 0 and tostring(last_why()):find("update: boom", 1, true), json.encode(res2))
    -- the observation cannot be embedded: a hidden raw row is kept, hidden
    local scope3 = "repo:fold-n4"
    local raw = assert(store.write({ scope = scope3, title = "step", importance = 0.2, tier = 0, body = "ran migration 91 on staging; table orders_v91 rebuilt", dedup_strategy = "append" })).id
    observe(scope3, "a migration ran", { raw })
    fold.archive({ raw }, "observation", nil)
    assert(feedback.record_reinforcement(raw, scope3, "praise"))
    advance(31)
    local res3 = H.with(require("luamemo.embed"), "embed", function() return nil, "boom" end, fold.run, scope3)
    check("an observation that cannot be embedded: the raw row is kept (hidden as before), not corrected, not deleted",
        res3.kept == 1 and res3.corrected == 0 and res3.deleted == 0 and row(raw) ~= nil and tostring(last_why()):find("embed: boom", 1, true), json.encode(res3))
end)

section("a summary marked wrong once is not trusted at the next review either", function()
    local scope = "repo:fold-q2"
    local ids = seed(scope, { { title = "retry", body = "Backoff doubles. RETRY_MAX=5 caps it. Alert INC-2291 was the cause." } })
    local s = fold_into_summary(scope, ids, "Notes", "A note on retries.")
    advance(2)
    assert(feedback.record_reinforcement(s.id, scope, "mistake"))
    advance(29)
    check("the first review corrects the summary", fold.run(scope).corrected == 1)
    advance(31)   -- no new complaint: the mark still counts (it is dated after the fold), and there is nothing left to add
    local again = fold.run(scope)
    check("the second review restores the original instead of deleting it: a summary once marked wrong never stands in for its source",
        again.restored == 1 and again.deleted == 0 and row(ids[1]).tier == 1, json.encode(again))
end)

section("a record without the tier it had counts as an ordinary memory", function()
    local scope = "repo:fold-o2"
    local id = assert(store.write({ scope = scope, title = "plain", body = "a memory the record forgot", importance = 0.3, dedup_strategy = "append" })).id
    db.run("UPDATE lm_memories SET tier = 0, consolidated_at = ?, metadata = ? WHERE id = ?", util.now_us() - 40 * DAY,
        json.encode({ lm_fold = { into_kind = "summary", into_id = 999999, state = "grace", review_at = util.now_us() - DAY,
                                  reviews = 0, folded_at = util.now_us() - 40 * DAY } }), id)
    local res = fold.run(scope)
    check("it is restored and visible again, never taken for raw conversation and kept hidden",
        res.restored == 1 and res.kept == 0 and row(id).tier == 1 and rec(id) == nil, json.encode(res))
end)

section("a summary is one scope's", function()
    local A, B = "repo:fold-sa", "user:fold-sb"
    local TEXT = "run make all then make install to build the whole project from source"
    local function note(scope) return assert(store.write({ scope = scope, title = "build", body = TEXT, importance = 1, dedup_strategy = "append" })) end
    local a, b, a2 = note(A), note(B), note(A)
    local mixed, together = false, false
    for _, c in ipairs(store.find_clusters({}) or {}) do
        local scopes, has_a, has_a2 = {}, false, false
        for _, m in ipairs(c.members) do
            scopes[m.scope] = true
            has_a = has_a or m.id == a.id
            has_a2 = has_a2 or m.id == a2.id
        end
        if scopes[A] and scopes[B] then mixed = true end
        if has_a and has_a2 then together = true end
    end
    check("the same note in two scopes is not one cluster", not mixed)
    check("(control) two copies in one scope are", together)
    local s, err = store.replace_with_summary({ a.id, b.id }, { scope = A, title = "S", body = "build" })
    check("a summary refuses originals of another scope, and nothing is hidden",
        s == nil and tostring(err):find("another scope", 1, true) and row(b.id).tier ~= 0 and row(a.id).tier ~= 0
        and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND kind = 'summary'", A) == 0, tostring(err))
    local meta = { keep = "me" }
    local s2 = assert(store.replace_with_summary({ a.id, "x" }, { scope = A, title = "S", body = "build", metadata = meta }))
    local stored = db.first("SELECT metadata FROM lm_memories WHERE id = ?", s2.id)
    local m = type(stored.metadata) == "table" and stored.metadata or json.decode(tostring(stored.metadata))
    check("summarized_ids holds the ids that were used (not the junk the caller passed), beside the caller's metadata",
        #m.summarized_ids == 1 and m.summarized_ids[1] == a.id and m.keep == "me", json.encode(m))
    check("… and the caller's table is left as it was", meta.summarized_ids == nil and meta.keep == "me")
end)

section("a summary that was itself folded away holds nothing", function()
    local scope = "repo:fold-k2"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff.")
    advance(2)
    fold_into_summary(scope, { s.id }, "Notes of notes", "Backoff.")   -- the summary is folded into a newer one: hidden, waiting
    check("(set up: the summary is itself archived)", row(s.id).tier == 0 and rec(s.id) ~= nil)
    advance(29)   -- the original's review is due (30 days after its fold); the summary's own is not (folded 2 days later)
    local res = fold.run(scope)
    check("the original is not judged against it: restored, not deleted", res.restored == 1 and res.deleted == 0 and row(ids[1]).tier == 1,
        json.encode(res))
end)

section("a row from before folds were recorded stays raw conversation after a correction", function()
    local scope = "repo:fold-k3"
    local raw = assert(store.write({ scope = scope, title = "step", importance = 0.2, tier = 0, dedup_strategy = "append",
        body = "ran migration 91 on staging; table orders_v91 rebuilt" })).id
    observe(scope, "a migration ran", { raw })
    db.run("UPDATE lm_memories SET consolidated_at = ?, metadata = '{}' WHERE id = ?", util.now_us() - 40 * DAY, raw)
    assert(feedback.record_reinforcement(raw, scope, "praise"))
    check("(set up) the first review corrects the observation", fold.run(scope).corrected == 1)
    advance(31)
    db.run("DELETE FROM lm_observations WHERE scope = ?", scope)   -- the observation is gone by the next review
    local res = fold.run(scope)
    check("the next review keeps it hidden, as it would a fresh row: not restored as a visible tier-1 memory",
        res.kept == 1 and res.restored == 0 and row(raw).tier == 0 and rec(raw).state == "kept", json.encode(res))
end)

section("a dry run answers what the real run does when a correction cannot be made", function()
    -- marked wrong, but the summary holds every fact: nothing to add
    local scope = "repo:fold-k4"
    local ids = seed(scope, { ORIGINALS[1] })
    local s = fold_into_summary(scope, ids, "Notes", "Retries use backoff (RETRY_MAX=5, 5 s cap).")
    advance(2)
    assert(feedback.record_reinforcement(s.id, scope, "mistake"))
    advance(29)
    local dry = fold.run(scope, { dry_run = true })
    check("nothing to add: the dry run says restored, and changed nothing", dry.restored == 1 and dry.corrected == 0 and row(ids[1]).tier == 0, json.encode(dry))
    local real = fold.run(scope)
    check("… and the real run agrees", real.restored == 1 and real.corrected == 0, json.encode(real))
    -- useful, the summary lost facts, but has no room left
    local scope2 = "repo:fold-k5"
    local ids2 = seed(scope2, { ORIGINALS[1] })
    fold_into_summary(scope2, ids2, "Notes", ("word "):rep(770))
    assert(feedback.record_reinforcement(ids2[1], scope2, "praise"))
    advance(31)
    local dry2 = fold.run(scope2, { dry_run = true })
    check("no room left: the dry run says restored", dry2.restored == 1 and dry2.corrected == 0, json.encode(dry2))
    check("… and the real run agrees", fold.run(scope2).restored == 1)
end)

section("a record that cannot be checked is a summary that is gone", function()
    -- a date that is not a number: the reused-id check cannot be made
    local scope = "repo:fold-k6"
    local ids = seed(scope, { ORIGINALS[3] })
    fold_into_summary(scope, ids, "Notes", "Release notes are written before tagging.")
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.folded_at', 'abc') WHERE id = ?", ids[1])
    advance(31)
    local res = fold.run(scope)
    check("folded_at 'abc': the original is restored, not deleted on the strength of a summary whose age is unknown",
        res.restored == 1 and res.deleted == 0, json.encode(res))
    -- an observation of ANOTHER scope that holds the same id is not the observation of this one
    local mine, other = "repo:fold-k7", "repo:fold-k7x"
    local raw = assert(store.write({ scope = mine, title = "step", importance = 0.2, tier = 0, dedup_strategy = "append",
        body = "ran step 91 on staging" })).id
    observe(other, "ran step 91 on staging", { raw })
    fold.archive({ raw }, "observation", nil)
    assert(feedback.record_reinforcement(raw, mine, "praise"))   -- useful: found → its facts are in the observation → deleted; not found → kept
    advance(31)
    local r2 = fold.run(mine)
    check("… so no observation holds it: a praised raw row is kept, not deleted", r2.kept == 1 and r2.deleted == 0 and row(raw) ~= nil, json.encode(r2))
    -- a REAL summary of another scope (it existed before the fold, it stands) that a record in this scope points at
    local theirs, ours = "repo:fold-k9x", "repo:fold-k9"
    local their_ids = seed(theirs, { ORIGINALS[1] })
    local their_sum = fold_into_summary(theirs, their_ids, "Theirs", "Release notes are written before tagging.")
    advance(1)
    local mine_ids = seed(ours, { ORIGINALS[3] })
    fold.archive({ mine_ids[1] }, "summary", their_sum.id)
    advance(31)
    local r3 = fold.run(ours)
    check("a summary of another scope is not this scope's summary: the original is restored, and that summary is untouched",
        r3.restored == 1 and r3.deleted == 0 and r3.corrected == 0
        and row(their_sum.id).body == "Release notes are written before tagging.", json.encode(r3))
end)

section("a summary takes its scope from its originals, and fails closed", function()
    local A, B = "repo:fold-k8", "repo:fold-k8b"
    local function note(scope, text) return assert(store.write({ scope = scope, title = text, body = text .. " distinct words", importance = 0.5, dedup_strategy = "append" })) end
    local a, b = note(A, "alpha"), note(B, "bravo")
    local s = assert(store.replace_with_summary({ a.id }, { title = "S", body = "alpha summary" }))
    check("no scope given: the summary is written into the originals' scope",
        db.first("SELECT scope FROM lm_memories WHERE id = ?", s.id).scope == A)
    local mixed, merr = store.replace_with_summary({ note(A, "charlie").id, b.id }, { title = "S", body = "mixed" })
    check("originals of two scopes and no scope given: refused, nothing hidden", mixed == nil and tostring(merr):find("another scope", 1, true)
        and row(b.id).tier ~= 0)
    local c = note(A, "delta")
    local real_query = db.query
    local failed, ferr = H.with(db, "query", function(sql, ...)
        if tostring(sql):find("SELECT DISTINCT scope", 1, true) then return nil, "database is locked" end
        return real_query(sql, ...)
    end, store.replace_with_summary, { c.id }, { scope = A, title = "S", body = "x" })
    check("a scope check that cannot be made is a refusal, and nothing is hidden",
        failed == nil and tostring(ferr):find("could not be checked", 1, true) and row(c.id).tier ~= 0, tostring(ferr))
end)

section("the digest: escalation of a cluster with mistakes, one consolidation per run, a failure leaves the rows", function()
    -- the rows a digest run left visible at a tier (the members it escalated), and the ones it folded away
    local visible, folded = H.visible, H.folded
    local function top_tier(scope) return n("SELECT max(tier) FROM lm_memories WHERE scope = ?", scope) end
    -- two copies of a note, mistakes on one, no observation that matches: the best member is escalated — and stays
    -- visible at its new tier (it is the memory the mistakes said matters), while its copy is folded away
    local scope = "repo:fold-g1"
    local TEXT = "ran migration 51 on staging; table orders_g1 rebuilt and verified"
    events(put(scope, TEXT), scope, "mistake"); put(scope, TEXT)
    local d = digest.run(scope, { no_llm = true })
    check("(set up) both rows of the cluster are processed", d.processed == 2 and #d.errors == 0, json.encode(d))
    check("a cluster with mistakes behind it and no matching observation: its best member is escalated (2 mistakes: tier 1) and NOT folded away",
        visible(scope) == 1 and top_tier(scope) == 1 and folded(scope) == 1, ("visible=%d top=%d folded=%d"):format(visible(scope), top_tier(scope), folded(scope)))
    -- the control: the same, with an observation that matches — it is reinforced, nothing is escalated
    local scope2 = "repo:fold-g2"
    events(put(scope2, TEXT .. " again"), scope2, "mistake"); put(scope2, TEXT .. " again")
    observe(scope2, TEXT .. " again", {})
    local d2 = digest.run(scope2, { no_llm = true })
    check("(control) with a matching observation nothing is escalated: both rows are folded", d2.processed == 2 and visible(scope2) == 0 and folded(scope2) == 2,
        json.encode(d2))
    -- an observation about something else is not a match (it is far under the reinforce threshold): still escalated
    local scope5 = "repo:fold-g5"
    observe(scope5, "ran migration on staging for the billing service and checked the rollout", {})
    events(put(scope5, TEXT .. " third"), scope5, "mistake"); put(scope5, TEXT .. " third")
    local d5 = digest.run(scope5, { no_llm = true })
    check("a scope that already holds an unrelated observation: the cluster with mistakes is escalated all the same",
        d5.processed == 2 and visible(scope5) == 1 and folded(scope5) == 1, json.encode(d5))
    -- … and the threshold is the configured one: with it at 0.05 the unrelated observation IS close enough
    conf({ consolidate_reinforce_threshold = 0.05 })
    local scope7 = "repo:fold-g7"
    observe(scope7, "ran migration on staging for the billing service and checked the rollout", {})
    events(put(scope7, TEXT .. " fourth"), scope7, "mistake"); put(scope7, TEXT .. " fourth")
    local d7 = digest.run(scope7, { no_llm = true })
    check("MEMO_CONSOLIDATE_REINFORCE_THRESHOLD is the digest's too: at 0.05 the same fixture is reinforced, not escalated",
        d7.processed == 2 and visible(scope7) == 0 and folded(scope7) == 2, json.encode(d7))
    conf()
    check("(the setting is put back)", require("luamemo.settings").same_memory(luamemo.config, "consolidate_reinforce_threshold") == 0.95)
    -- two topics with mistakes: both are escalated, not only the first (the consolidation makes an observation of each
    -- AFTER the escalation, so the order of the clusters does not decide)
    local scope6 = "repo:fold-g6"
    for _, t in ipairs({ "apple orchard harvest schedule for october", "kernel scheduler preemption latency tuning notes" }) do
        events(put(scope6, t), scope6, "mistake"); put(scope6, t)
    end
    local d6 = digest.run(scope6, { no_llm = true })
    check("two clusters with mistakes: each one's best member is escalated and stays", d6.processed == 4 and visible(scope6) == 2 and folded(scope6) == 2,
        json.encode(d6) .. " " .. visible(scope6))
    -- a dry run changes nothing: no escalation, no consolidation, no fold
    local scope8 = "repo:fold-g8"
    local m8 = put(scope8, TEXT .. " fifth"); put(scope8, TEXT .. " fifth")
    events(m8, scope8, "mistake")
    local dry_calls = 0
    local d8 = H.with(consolidate, "process", function() dry_calls = dry_calls + 1; return {} end, digest.run, scope8, { no_llm = true, dry_run = true })
    check("a dry run only counts: it escalates nothing, consolidates nothing and folds nothing",
        d8.processed == 2 and dry_calls == 0 and visible(scope8) == 0 and folded(scope8) == 0 and top_tier(scope8) == 0, json.encode(d8))
    -- a scope with no tier-0 rows does not pay for a consolidation
    local empty_calls = 0
    local d9 = H.with(consolidate, "process", function() empty_calls = empty_calls + 1; return {} end, digest.run, "repo:fold-g9", { no_llm = true })
    check("an empty scope: consolidate.process is not called", empty_calls == 0 and d9.processed == 0, json.encode(d9))
    -- consolidate.process takes the whole scope: once per run, however many clusters
    local scope3 = "repo:fold-g3"
    for _, t in ipairs({ "apple orchard harvest schedule", "kernel scheduler preemption latency", "invoice template for quarterly tax" }) do put(scope3, t) end
    local calls = 0
    local d3 = H.with(consolidate, "process", function() calls = calls + 1; return {} end, digest.run, scope3, { no_llm = true })
    check("three clusters, one consolidate.process call", calls == 1 and d3.processed == 3, ("calls=%d %s"):format(calls, json.encode(d3)))
    -- a consolidation that raises: reported once, and no cluster is folded without its observation
    local scope4 = "repo:fold-g4"
    for _, t in ipairs({ "garden hose pressure test", "compiler register allocation spill" }) do put(scope4, t) end
    local d4 = H.with(consolidate, "process", function() error("boom") end, digest.run, scope4, { no_llm = true })
    check("it is reported as a consolidate error and nothing is folded or counted",
        #d4.errors == 1 and d4.errors[1]:find("^consolidate error: .*boom") and d4.processed == 0
        and folded(scope4) == 0, json.encode(d4))
    -- … and the next run, with the real consolidation, takes the rows
    local retry = digest.run(scope4, { no_llm = true })
    check("the next run folds them (a raise leaves the rows for it)", retry.processed == 2 and #retry.errors == 0 and folded(scope4) == 2, json.encode(retry))
end)

section("the digest's escalation in detail: which member, how far, a failed lookup, a note with no vector", function()

    -- four clusters in one scope: with mistakes on its LOWER-importance row (the best member is the other one), with
    -- nothing, with only praise and misses, with a direct command
    local scope = "repo:fold-esc"
    local TB, TA, TC, TD = "mistaken cluster about the billing job schedule", "quiet cluster about the office plants watering",
        "praised cluster about the release checklist wording", "commanded cluster about the retry budget numbers"
    local b_hi, b_lo = put(scope, TB, 0.4), put(scope, TB, 0.2)
    local a1, a2 = put(scope, TA), put(scope, TA)
    local c1, c2 = put(scope, TC), put(scope, TC)
    local d1, d2 = put(scope, TD), put(scope, TD)
    events(b_lo, scope, "mistake"); events(c2, scope, "praise"); events(c2, scope, "miss"); events(d2, scope, "direct_command")
    local d = digest.run(scope, { no_llm = true })
    check("(set up) all eight rows are processed", d.processed == 8 and #d.errors == 0, json.encode(d))
    check("the mistaken cluster: its best member (the higher-importance row, not the one that has the events) is escalated and stays",
        tier_of(b_hi) == 1 and imp_of(b_hi) > 0.4 and not folded_id(b_hi) and folded_id(b_lo))
    check("a direct command counts as a mistake: that cluster's best member is escalated too", tier_of(d1) == 1 and not folded_id(d1) and folded_id(d2))
    check("a cluster with no events, and one with only praise and misses, are left alone: all four rows folded",
        folded_id(a1) and folded_id(a2) and folded_id(c1) and folded_id(c2))

    -- an observation that matches only ONE of two clusters: the other, with mistakes, is still escalated (the answers are
    -- read per asked cluster, not per cluster of the plan)
    local scope2 = "repo:fold-esc2"
    local PA, PB = "plain cluster about the lunch menu on friday", "flagged cluster about the deploy window on tuesday"
    put(scope2, PA); put(scope2, PA)
    local f1, f2 = put(scope2, PB), put(scope2, PB)
    events(f2, scope2, "mistake")
    observe(scope2, PB, {})
    digest.run(scope2, { no_llm = true })
    check("the flagged cluster has a matching observation (it is reinforced, not escalated) while a plain one precedes it in the plan",
        tier_of(f1) == 0 and folded_id(f1) and folded_id(f2))

    -- the lookup of the observations raises: every cluster with mistakes is escalated, and the run goes on
    local scope3 = "repo:fold-esc3"
    local g1 = put(scope3, "matched cluster about the invoice export format"); put(scope3, "matched cluster about the invoice export format")
    events(g1, scope3, "mistake")
    observe(scope3, "matched cluster about the invoice export format", {})
    local d3 = H.with(consolidate, "would_reinforce", function() error("boom") end, digest.run, scope3, { no_llm = true })
    check("a failed observation lookup escalates (and does not abort the run: the rest is folded, no error)",
        tier_of(g1) >= 1 and not folded_id(g1) and d3.processed == 2 and #d3.errors == 0   -- (tier 2 if the reinforced observation promoted it)
        and H.folded(scope3) == 1,
        json.encode(d3))

    -- the row is raised by someone else while the observations are being asked about: the escalation (decided on the row
    -- as it was read) does not overwrite that, and the archive leaves the row visible
    local scope6 = "repo:fold-esc6"
    local k1 = put(scope6, "raced cluster about the vendor contract renewal"); put(scope6, "raced cluster about the vendor contract renewal")
    events(k1, scope6, "mistake")
    H.with(consolidate, "would_reinforce", function()
        db.run("UPDATE lm_memories SET tier = 2, importance = 5 WHERE id = ?", k1)
        return { false }
    end, digest.run, scope6, { no_llm = true })
    check("an escalation does not overwrite a raise made meanwhile: the member keeps its importance and tier, and is not folded",
        tier_of(k1) >= 2 and imp_of(k1) == 5 and not folded_id(k1))

    -- … and one whose row changed since it was read (an event raised its importance a little) reads the row again and
    -- applies: left at tier 0 the cluster would be archived and its mistaken note deleted at the review. Two copies, the
    -- mistakes on the second; `race(first id, nth write)` runs before each escalation write → the ids, the writes tried
    local function race_escalation(scope_name, text, race)
        local first, second = put(scope_name, text), put(scope_name, text)
        events(second, scope_name, "mistake", 2)
        local writes = 0
        H.on_sql(db, "run", "UPDATE lm_memories SET importance = ?, tier = ?", function(real, sql, ...)
            writes = writes + 1
            race(first, writes)
            return real(sql, ...)
        end, digest.run, scope_name, { no_llm = true })
        return first, second, writes
    end
    local r1, r2, rw = race_escalation("repo:fold-casretry", "a plain note about the server room access list",
        function(id, nth) if nth == 1 then db.run("UPDATE lm_memories SET importance = 0.45 WHERE id = ?", id) end end)
    check("an escalation that lost a race is applied on the second read: the best note is tier 1 and visible, its copy archived",
        rw == 2 and tier_of(r1) == 1 and not folded_id(r1) and folded_id(r2) and imp_of(r1) == 0.45, ("writes=%d tier=%s"):format(rw, tostring(tier_of(r1))))
    local t1, t2, tw = race_escalation("repo:fold-casretry2", "a plain note about the loading dock key safe",
        function(id, nth) db.run("UPDATE lm_memories SET importance = ? WHERE id = ?", 0.4 + nth / 100, id) end)
    check("two races in a row are not chased (the bound): two writes, the best note stays at tier 0 and is archived like its copy",
        tw == 2 and tier_of(t1) == 0 and folded_id(t1) and folded_id(t2), ("writes=%d"):format(tw))
    local ok_gone, g_first, _, gw = pcall(race_escalation, "repo:fold-casretry3", "a plain note about the badge office hours",
        function(id, nth) if nth == 1 then db.run("DELETE FROM lm_memories WHERE id = ?", id) end end)
    check("a best note deleted between the read and the write: one write, nothing raised", ok_gone and gw == 1 and row(g_first) == nil,
        tostring(g_first))

    -- a note with no vector (the embedder was down, or the text too long for it) is not taken at all: consolidate.process
    -- cannot make an observation from it, and a fold with no observation behind it ends in a delete after the grace
    local scope4 = "repo:fold-esc4"
    local h1, h2 = put(scope4, "a long chat save that has no vector at all"), put(scope4, "another save from while the embedder was down")
    db.run("UPDATE lm_memories SET embedding = NULL WHERE id IN (?, ?)", h1, h2)
    events(h1, scope4, "mistake")
    local d4 = digest.run(scope4, { no_llm = true })
    check("a note with no vector: not folded, not escalated, not counted, no error", tier_of(h1) == 0 and not folded_id(h1) and not folded_id(h2)
        and d4.processed == 0 and #d4.errors == 0, json.encode(d4))
    advance(31)
    local r4 = fold.run(scope4)
    check("… and the review has nothing to delete: both notes are still there, a month on",
        r4.deleted == 0 and n("SELECT count(*) FROM lm_memories WHERE scope = ?", scope4) == 2, json.encode(r4))

    -- consolidate.would_reinforce itself: one pass, an answer per vector (a false is "no vector")
    local scope5 = "repo:fold-esc5"
    local O = "observation text about the quarterly planning meeting agenda"
    observe(scope5, O, {})
    local embed = require("luamemo.embed")
    local near, far = assert(embed.embed(O)), assert(embed.embed("zebra crossing paint thickness measurement"))
    local got = consolidate.would_reinforce(scope5, { near, false, far })
    check("would_reinforce: the observation's own vector → true; no vector → false; an unrelated one → false",
        got[1] == true and got[2] == false and got[3] == false, json.encode(got))
    local none = consolidate.would_reinforce("repo:fold-esc-empty", { near, far })
    check("… and a scope with no observation: all false", none[1] == false and none[2] == false)

    -- the observations are asked about ONCE for all the clusters with mistakes, and not at all when none has any
    local function asks(scope_name, texts_with_mistakes, plain_texts)
        for _, t in ipairs(texts_with_mistakes) do local id = put(scope_name, t); put(scope_name, t); events(id, scope_name, "mistake") end
        for _, t in ipairs(plain_texts) do put(scope_name, t); put(scope_name, t) end
        local calls, count = 0, nil
        local real = consolidate.would_reinforce
        H.with(consolidate, "would_reinforce", function(s, vecs) calls = calls + 1; count = #vecs; return real(s, vecs) end,
            digest.run, scope_name, { no_llm = true })
        return calls, count
    end
    local asked_calls, asked_about = asks("repo:fold-ask1", { "first flagged cluster about the sprint review notes", "second flagged cluster about the hiring pipeline stages" },
        { "plain cluster about the cafeteria opening hours" })
    check("two clusters with mistakes and a plain one: one call, asked about the two", asked_calls == 1 and asked_about == 2,
        ("calls=%d n=%s"):format(asked_calls, tostring(asked_about)))
    local none_calls = asks("repo:fold-ask2", {}, { "plain cluster about the bicycle shed repairs", "another plain cluster about the elevator inspection dates" })
    check("clusters with no mistakes: no lookup at all", none_calls == 0, none_calls)

    -- how far a cluster is escalated, by how many mistakes (the default alpha 0.4: 1 → importance up, tier 0; 2 → tier 1;
    -- 4 → tier 2; 15 → tier 3), counting the mistakes of ALL the cluster's members, not of one
    local scope7 = "repo:fold-esc7"
    local one, two_a, four, fifteen = {}, {}, {}, {}
    for _, c in ipairs({ { one, "single mistake about the parking permit renewal" }, { two_a, "two members each flagged about the lease clause wording" },
                         { four, "four mistakes about the invoice rounding rule" }, { fifteen, "fifteen mistakes about the production database host" } }) do
        c[1][1], c[1][2] = put(scope7, c[2]), put(scope7, c[2])
    end
    events(one[1], scope7, "mistake", 1)
    events(two_a[1], scope7, "mistake", 1); events(two_a[2], scope7, "mistake", 1)
    events(four[1], scope7, "mistake", 4)
    events(fifteen[1], scope7, "mistake", 15)
    digest.run(scope7, { no_llm = true })
    check("1 mistake: the importance is raised, the tier is not (the row is folded like its copy)",
        imp_of(one[1]) > 0.2 and tier_of(one[1]) == 0 and folded_id(one[1]) and folded_id(one[2]))
    check("2 mistakes spread over two members: counted together, tier 1", tier_of(two_a[1]) == 1 and not folded_id(two_a[1]) and folded_id(two_a[2]))
    check("4 mistakes: tier 2", tier_of(four[1]) == 2 and not folded_id(four[1]))
    check("15 mistakes: tier 3 (an ordinary scope)", tier_of(fifteen[1]) == 3 and not folded_id(fifteen[1]))

    -- the other kinds of event: a reversal is not a mistake of the digest's; a direct command promotes a tier-2 memory
    -- to the core tier once it has enough of them (like a mistake)
    local scope8 = "repo:fold-esc8"
    local rev1 = put(scope8, "reversed cluster about the old naming convention"); put(scope8, "reversed cluster about the old naming convention")
    events(rev1, scope8, "reversal", 3)
    digest.run(scope8, { no_llm = true })
    check("a cluster with only reversals behind it is not escalated", tier_of(rev1) == 0 and folded_id(rev1))
    local lifted = put(scope8, "settled memory about the quarterly budget cap")
    db.run("UPDATE lm_memories SET tier = 2 WHERE id = ?", lifted)
    events(lifted, scope8, "direct_command", 5)
    digest.run(scope8, { no_llm = true })
    check("a tier-2 memory with 5 direct commands is promoted to tier 3 by the digest", tier_of(lifted) == 3)

end)

section("reinforcement events: the event-type lists, record_event / apply_event_effect (ids and deltas that are no number, compare-and-set)", function()
    -- the lists of event types are one set: the weights, the valid events, the mistake list and what the schema takes
    local weights, valid = require("luamemo.feedback").REINFORCE_WEIGHT, require("luamemo.federation.common").EVENT_TYPES
    local agree, listed = true, {}
    for k in pairs(weights) do if not valid[k] then agree = false end end
    for k in pairs(valid) do if not weights[k] then agree = false end end
    for kind in require("luamemo.feedback").MISTAKE_SQL:gmatch("'([%w_]+)'") do listed[#listed + 1] = kind; if not valid[kind] then agree = false end end
    check("REINFORCE_WEIGHT, EVENT_TYPES and MISTAKE_SQL name only the same event types", agree and #listed == 2)
    local target = put("repo:fold-esc9", "memory the events are recorded against")
    local accepted = true
    for kind in pairs(valid) do
        digest.record_event(target, "repo:fold-esc9", kind, 0.5, "t")
        if n("SELECT count(*) FROM lm_reinforcements WHERE memory_id = ? AND event_type = ?", target, kind) ~= 1 then accepted = false end
    end
    check("digest.record_event stores each of them (the schema accepts every valid type)", accepted)

    -- record_event / apply_event_effect normalise the id and the delta
    local m1, m2 = put("repo:fold-esc9", "memory for the id and delta cases"), put("repo:fold-esc9", "another memory for the same cases")
    local function stored(id) return db.first("SELECT delta FROM lm_reinforcements WHERE memory_id = ? ORDER BY id DESC LIMIT 1", id) end
    digest.record_event(m1 + 0.9, "repo:fold-esc9", "praise", 5, "big delta and a fractional id")
    check("a fractional id is floored and a delta above 1 is clamped to 1", stored(m1) and tonumber(stored(m1).delta) == 1.0)
    digest.record_event(m1, "repo:fold-esc9", "praise", "abc", "no delta")
    check("a delta that is no number is 0.5", tonumber(stored(m1).delta) == 0.5)
    local before = n("SELECT count(*) FROM lm_reinforcements")
    digest.record_event(0, "repo:fold-esc9", "praise", 0.5); digest.record_event(m1, "repo:fold-esc9", "typo", 0.5)
    digest.record_event(nil, "repo:fold-esc9", "praise", 0.5); digest.record_event(m1, nil, "praise", 0.5)
    check("no id, id 0, an unknown event type, no scope: nothing is stored", n("SELECT count(*) FROM lm_reinforcements") == before)
    db.run("UPDATE lm_memories SET importance = 0.4 WHERE id IN (?, ?)", m1, m2)
    digest.apply_event_effect(m1, "repo:fold-esc9", "miss", 99); digest.apply_event_effect(m2, "repo:fold-esc9", "miss", 1)
    check("apply_event_effect clamps the delta the same way: 99 acts as 1", imp_of(m1) == imp_of(m2) and imp_of(m1) > 0.4)
    -- … and its write is refused when somebody changed the row's importance (tier unchanged) after it was read
    -- a "miss" on a row (importance 0.4) while somebody else changes it right after it was read: `competing_sql` runs then
    local function raced(id, competing_sql)
        db.run("UPDATE lm_memories SET importance = 0.4 WHERE id = ?", id)
        H.on_sql(db, "first", "SELECT importance, tier FROM lm_memories", function(real, sql, ...)
            local row, err = real(sql, ...)
            db.run(competing_sql, id)
            return row, err
        end, digest.apply_event_effect, id, "repo:fold-esc9", "miss", 1)
    end
    local m3 = put("repo:fold-esc9", "memory raced by two events")
    raced(m3, "UPDATE lm_memories SET importance = 6 WHERE id = ?")
    check("an event's effect does not overwrite an importance changed meanwhile (the tier did not move)", imp_of(m3) == 6)
    -- … and when somebody changed only the TIER meanwhile (the importance is as it was read): the write is refused too,
    -- else the member would be put back to the tier it had when it was read
    local m4 = put("repo:fold-esc9", "memory whose tier was changed meanwhile")
    raced(m4, "UPDATE lm_memories SET tier = 2 WHERE id = ?")
    check("an event's effect does not overwrite a tier changed meanwhile either (nothing is written: importance and tier stay)",
        tier_of(m4) == 2 and imp_of(m4) == 0.4, ("tier=%s importance=%s"):format(tostring(tier_of(m4)), tostring(imp_of(m4))))
    -- the id: a fractional one is floored; none, 0, a negative one or a NaN is ignored before the row is even read
    local m5 = put("repo:fold-esc9", "memory for the id cases of an event's effect")
    db.run("UPDATE lm_memories SET importance = 0.4 WHERE id = ?", m5)
    digest.apply_event_effect(m5 + 0.9, "repo:fold-esc9", "miss", 1)
    check("apply_event_effect floors a fractional id: the row's importance is raised", imp_of(m5) > 0.4)
    local nan = tonumber("nan")   -- (a NaN: what a "nan" string becomes in tonumber, and math.min / math.max let it through)
    local reads, inserts = 0, 0
    H.on_sql(db, "first", "", function(real, ...) reads = reads + 1; return real(...) end, function()
        H.on_sql(db, "run", "INSERT INTO lm_reinforcements", function(real, ...) inserts = inserts + 1; return real(...) end, function()
            -- (control: a valid id reads the row once and inserts the event once — the counters count)
            digest.record_event(m5, "repo:fold-esc9", "miss", 1)
            check("(control) a valid id is read once and its event inserted once", reads == 1 and inserts == 1, ("reads=%d inserts=%d"):format(reads, inserts))
            reads, inserts = 0, 0
            for _, bad in ipairs({ 0, -m5, nan, "abc" }) do
                digest.apply_event_effect(bad, "repo:fold-esc9", "miss", 1)
                digest.record_event(bad, "repo:fold-esc9", "miss", 1)
            end
            digest.apply_event_effect(nil, "repo:fold-esc9", "reversal", 1); digest.record_event(nil, "repo:fold-esc9", "reversal", 1)
        end)
    end)
    check("an id of 0, a negative one, a NaN, none or no number: ignored — the row is not read, no event is inserted", reads == 0 and inserts == 0,
        ("reads=%d inserts=%d"):format(reads, inserts))

    -- the delta: a NaN is no number (0.5), as it is for a string that is none — it used to pass the clamp and send a miss on an
    -- importance of 1 or more straight to the ceiling (7), with the event not even stored
    local m6, m7 = put("repo:fold-esc9", "memory hit by a nan delta"), put("repo:fold-esc9", "memory hit by a half delta")
    db.run("UPDATE lm_memories SET importance = 1.0 WHERE id IN (?, ?)", m6, m7)
    digest.record_event(m6, "repo:fold-esc9", "miss", nan, "nan delta"); digest.record_event(m7, "repo:fold-esc9", "miss", 0.5, "half delta")
    check("a NaN delta acts as 0.5: the same raise as a delta of 0.5, not the ceiling", imp_of(m6) == imp_of(m7) and imp_of(m6) < 7,
        ("%s %s"):format(tostring(imp_of(m6)), tostring(imp_of(m7))))
    check("… and the event is stored with the delta of 0.5", tonumber(stored(m6).delta) == 0.5)
    -- an event that cannot be stored has no effect either (an effect nothing records can never be counted)
    local m8 = put("repo:fold-esc9", "memory whose event cannot be stored")
    db.run("UPDATE lm_memories SET importance = 1.0 WHERE id = ?", m8)
    H.on_sql(db, "run", "INSERT INTO lm_reinforcements", function() return nil, "boom" end,
        digest.record_event, m8, "repo:fold-esc9", "miss", 1, "the insert fails")
    check("record_event whose INSERT fails changes nothing on the row", imp_of(m8) == 1.0, tostring(imp_of(m8)))

    -- a negative delta (the central clamps the deltas it is pushed to [-1, 1]) acts as its absolute value
    local m9, m10, m11, m12 = put("repo:fold-esc9", "miss row with a positive delta"), put("repo:fold-esc9", "miss row with a negative delta"),
        put("repo:fold-esc9", "reversal row with a positive delta"), put("repo:fold-esc9", "reversal row with a negative delta")
    db.run("UPDATE lm_memories SET importance = 2.0 WHERE id IN (?, ?, ?, ?)", m9, m10, m11, m12)
    digest.apply_event_effect(m9, "repo:fold-esc9", "miss", 1); digest.apply_event_effect(m10, "repo:fold-esc9", "miss", -1)
    digest.apply_event_effect(m11, "repo:fold-esc9", "reversal", 1); digest.apply_event_effect(m12, "repo:fold-esc9", "reversal", -1)
    check("a miss with delta -1 raises the importance as +1 does", imp_of(m10) == imp_of(m9) and imp_of(m10) > 2.0, ("%s %s"):format(tostring(imp_of(m9)), tostring(imp_of(m10))))
    check("a reversal with delta -1 lowers the importance as +1 does", imp_of(m12) == imp_of(m11) and imp_of(m12) < 2.0, ("%s %s"):format(tostring(imp_of(m11)), tostring(imp_of(m12))))
end)

section("a reinforced observation's trend and evidence; the promotions (tier 1 → 2, 2 → 3), a failed one, the tunables", function()
    -- a reinforced observation's trend is fresh: it was reinforced NOW, so it is not "stale" any more (the promotion
    -- skips the memories of a stale observation, and would go on skipping them after the very run that reinforced it)
    local scope9 = "repo:fold-trend"
    local TT = "observation about the nightly backup rotation and its retention"
    local held = put(scope9, "a memory the observation already holds, kept at tier 1")
    db.run("UPDATE lm_memories SET tier = 1 WHERE id = ?", held)
    observe(scope9, TT, { held })
    -- (200 days before the REAL now: the freshness trend counts days against os.time(), which the test's clock leaves alone)
    db.run("UPDATE lm_observations SET freshness_trend = 'stale', last_reinforced = ? WHERE scope = ?", (os.time() - 200 * 86400) * 1000000, scope9)
    check("(set up) the observation is stale and old", db.value("SELECT freshness_trend FROM lm_observations WHERE scope = ?", scope9) == "stale")
    local new1, new2 = put(scope9, TT), put(scope9, TT)
    local d9 = digest.run(scope9, { no_llm = true })
    local obs9 = db.first("SELECT proof_count, freshness_trend, last_reinforced FROM lm_observations WHERE scope = ?", scope9)
    check("(set up) the stale observation was reinforced by the two new notes", d9.processed == 2 and tonumber(obs9.proof_count) == 3, json.encode(d9) .. json.encode(obs9))
    check("a reinforced observation ends the run with the trend of NOW and its new proof (3 within the week: strengthening) and a fresh last_reinforced",
        obs9.freshness_trend == "strengthening" and tonumber(obs9.last_reinforced) > util.now_us() - 86400 * 1000000, json.encode(obs9))
    check("… so the memory it holds is promoted tier 1 → 2 in the same run", tier_of(held) == 2 and d9.promoted2 == 1, ("tier=%s %s"):format(tostring(tier_of(held)), json.encode(d9)))
    -- the reinforcement records what backs the observation now: the new notes' ids and a quote of each (the review and the
    -- promotion find a memory through them)
    check("the reinforced observation's evidence gains the two notes and a quote of each",
        n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope9) == 3
        and n("SELECT count(*) FROM lm_observations o, json_each(o.evidence_ids) e WHERE o.scope = ? AND CAST(e.value AS INTEGER) IN (?, ?)", scope9, new1, new2) == 2
        and n("SELECT json_array_length(evidence_quotes) FROM lm_observations WHERE scope = ?", scope9) == 2)
    -- … with a proof under 3 it is "stable" (reinforced now, but not enough proof to be strengthening)
    local scope9b = "repo:fold-trend2"
    local TT2 = "observation about the weekly vendor invoice reconciliation"
    observe(scope9b, TT2, {})
    db.run("UPDATE lm_observations SET freshness_trend = 'stale', last_reinforced = ? WHERE scope = ?", (os.time() - 200 * 86400) * 1000000, scope9b)
    put(scope9b, TT2)
    local d9b = digest.run(scope9b, { no_llm = true })
    local obs9b = db.first("SELECT proof_count, freshness_trend FROM lm_observations WHERE scope = ?", scope9b)
    check("a stale observation reinforced to a proof of 2 is stable, not stale and not strengthening",
        d9b.processed == 1 and tonumber(obs9b.proof_count) == 2 and obs9b.freshness_trend == "stable", json.encode(d9b) .. json.encode(obs9b))

    -- the promotion of tier 1 → 2: by an observation's proof (digest_promote_tier2_at, 3), of this scope, not stale
    local scope10 = "repo:fold-promo"
    local p_yes, p_exact, p_low, p_stale = member(scope10, 1), member(scope10, 1), member(scope10, 1), member(scope10, 1)
    local p_t0, p_t3 = member(scope10, 0), member(scope10, 3)
    holds(scope10, { p_yes, p_t0, p_t3 }, 9, "stable")
    holds(scope10, { p_exact }, 3, "new")
    holds(scope10, { p_low }, 2, "strengthening")
    holds(scope10, { p_stale }, 9, "stale")
    local pd = digest.run(scope10, { no_llm = true })
    check("a tier-1 member of an observation with proof >= 3 (exactly 3 too) is promoted; the count is reported",
        tier_of(p_yes) == 2 and tier_of(p_exact) == 2 and pd.promoted2 == 2 and #pd.errors == 0, json.encode(pd))
    check("proof 2 does not promote, nor does a stale trend", tier_of(p_low) == 1 and tier_of(p_stale) == 1)
    check("a tier-0 and a tier-3 member of the same observation are left as they are", tier_of(p_t0) == 0 and tier_of(p_t3) == 3)
    local pd2 = digest.run(scope10, { no_llm = true })
    check("a second run promotes nothing more", pd2.promoted2 == 0 and pd2.promoted3 == 0 and #pd2.errors == 0, json.encode(pd2))
    -- … and an observation in ANOTHER scope that lists this scope's member does not count: promoting is per scope
    local p_foreign = member(scope10, 1)
    holds("repo:fold-promo-other", { p_foreign }, 9, "stable")
    digest.run(scope10, { no_llm = true })
    check("an observation of another scope that lists this scope's member does not promote it", tier_of(p_foreign) == 1)

    -- tier 2 → 3 needs digest_promote_tier3_at (5) mistakes
    local scope11 = "repo:fold-promo3"
    local q_four, q_five = member(scope11, 2), member(scope11, 2)
    events(q_four, scope11, "mistake", 4); events(q_five, scope11, "mistake", 4); events(q_five, scope11, "direct_command", 1)
    local qd = digest.run(scope11, { no_llm = true })
    check("tier 2 with 4 mistakes stays; with 5 (a direct command counts) it goes to 3", tier_of(q_four) == 2 and tier_of(q_five) == 3 and qd.promoted3 == 1, json.encode(qd))

    -- a statement of the promotion that fails is REPORTED (not swallowed), and the other one still runs
    local scope12 = "repo:fold-perr"
    local r_two = member(scope12, 2)
    events(r_two, scope12, "mistake", 5)
    observe(scope12, "observation with evidence that is not json", {})
    -- (with enough proof to pass the statement's filters: the evidence is only read for an observation that does)
    db.run("UPDATE lm_observations SET evidence_ids = 'not json', proof_count = 9, freshness_trend = 'stable' WHERE scope = ?", scope12)
    local ed = digest.run(scope12, { no_llm = true })
    check("a failed tier-1 → 2 statement is in summary.errors, and the tier-2 → 3 one still ran",
        #ed.errors >= 1 and tostring(ed.errors[1]):find("promote tier 2", 1, true) and ed.promoted2 == 0 and ed.promoted3 == 1 and tier_of(r_two) == 3, json.encode(ed))

    -- … and the other way round: the tier-2 → 3 statement fails, the tier-1 → 2 promotion of the same run still counts
    local scope12b = "repo:fold-perr3"
    local s_one, s_two = member(scope12b, 1), member(scope12b, 2)
    holds(scope12b, { s_one }, 9, "stable")
    events(s_two, scope12b, "mistake", 5)
    local ed3 = H.on_sql(db, "run", "SET tier = 3", function() return nil, "boom" end, digest.run, scope12b, { no_llm = true })
    check("a failed tier-2 → 3 statement is in summary.errors as 'promote tier 3: …', and the tier-1 → 2 promotion still counted",
        tostring(ed3.errors[1]):find("promote tier 3: boom", 1, true) and ed3.promoted3 == 0 and ed3.promoted2 == 1
        and tier_of(s_one) == 2 and tier_of(s_two) == 2, json.encode(ed3))

    -- the tunables are read from the config, each call: at 2 an observation of proof 2 promotes its tier-1 member, and 2
    -- mistakes take a tier-2 memory to the core tier
    local scope15 = "repo:fold-tunables"
    local u_low, u_two = member(scope15, 1), member(scope15, 2)
    holds(scope15, { u_low }, 2, "strengthening")
    events(u_two, scope15, "mistake", 2)
    local ud0 = digest.run(scope15, { no_llm = true })
    check("(control) at the defaults proof 2 and 2 mistakes promote nothing", ud0.promoted2 == 0 and ud0.promoted3 == 0 and tier_of(u_low) == 1 and tier_of(u_two) == 2, json.encode(ud0))
    conf({ digest_promote_tier2_at = 2, digest_promote_tier3_at = 2 })
    local ud = digest.run(scope15, { no_llm = true })
    check("MEMO_DIGEST_PROMOTE_TIER2_AT / TIER3_AT = 2: both promote", ud.promoted2 == 1 and ud.promoted3 == 1 and tier_of(u_low) == 2 and tier_of(u_two) == 3, json.encode(ud))
    conf()
    -- the escalation slope: at alpha 1 a single mistake is relevance 0.5 → tier 1 (at the default 0.4 it is 0.29 → tier 0)
    conf({ digest_escalate_alpha = 1 })
    local scope16 = "repo:fold-alpha"
    local al1 = put(scope16, "cluster about the sprint planning poker cards"); put(scope16, "cluster about the sprint planning poker cards")
    events(al1, scope16, "mistake", 1)
    digest.run(scope16, { no_llm = true })
    check("MEMO_DIGEST_ESCALATE_ALPHA = 1: one mistake escalates to tier 1", tier_of(al1) == 1 and not folded_id(al1), tostring(tier_of(al1)))
    conf()

end)

section("digest.run in detail: a dry run, no scope, the 500-row fetch, escalation by mistakes (not by importance), notes with no vector", function()
    -- a dry run only counts: no promotion either (and no review)
    local scope17 = "repo:fold-dry-promo"
    local v_one, v_two = member(scope17, 1), member(scope17, 2)
    holds(scope17, { v_one }, 9, "stable")
    events(v_two, scope17, "mistake", 5)
    local dd = digest.run(scope17, { no_llm = true, dry_run = true })
    check("a dry run with promotable rows promotes nothing", dd.promoted2 == 0 and dd.promoted3 == 0 and tier_of(v_one) == 1 and tier_of(v_two) == 2, json.encode(dd))

    -- no scope: skipped, nothing touched
    local rows_before = n("SELECT count(*) FROM lm_memories")
    local nd, ed_ = digest.run(nil, { no_llm = true }), digest.run("", { no_llm = true })
    check("digest.run(nil) and digest.run('') are skipped as 'no scope' and change nothing",
        nd.skipped == "no scope" and ed_.skipped == "no scope" and nd.processed == 0 and n("SELECT count(*) FROM lm_memories") == rows_before)

    -- the fetch: at most 500 rows (the best ones), ties in importance and age broken by id
    local scope18 = "repo:fold-tie"
    local tie_a, tie_b = put(scope18, "twin note about the badge printer toner order"), put(scope18, "twin note about the badge printer toner order")
    db.run("UPDATE lm_memories SET created_at = 1000, importance = 0.2 WHERE id IN (?, ?)", tie_a, tie_b)
    events(tie_b, scope18, "mistake", 2)
    digest.run(scope18, { no_llm = true })
    check("two copies equal in importance and age: the lower id is the best member — it is the one escalated and kept visible",
        tier_of(tie_a) == 1 and not folded_id(tie_a) and folded_id(tie_b), ("a=%s b=%s"):format(tostring(tier_of(tie_a)), tostring(tier_of(tie_b))))
    local scope19 = "repo:fold-500"
    for i = 1, 501 do put(scope19, ("saved note number %d about subject %d"):format(i, i * 7919)) end
    local big = digest.run(scope19, { no_llm = true })
    check("501 tier-0 notes: the run takes 500 of them", big.processed == 500 and #big.errors == 0, json.encode(big))
    check("… the 501st is consolidated but not archived: still tier 0, visible, no fold record",
        n("SELECT count(*) FROM lm_memories WHERE scope = ? AND tier = 0 AND consolidated_at IS NOT NULL AND json_type(metadata, '$.lm_fold') IS NULL", scope19) == 1)
    local left_out = db.first("SELECT id FROM lm_memories WHERE scope = ? AND tier = 0 AND consolidated_at IS NOT NULL AND json_type(metadata, '$.lm_fold') IS NULL", scope19)
    check("… and an observation holds it (the review of a pre-fold row finds it there)", left_out ~= nil
        and n("SELECT count(*) FROM lm_observations o, json_each(o.evidence_ids) e WHERE o.scope = ? AND CAST(e.value AS INTEGER) = ?", scope19, tonumber(left_out.id)) == 1)

    -- escalation: the tier follows the NUMBER OF MISTAKES, not the row's own importance (which is on a 0–10 scale: a
    -- tier-0 row of importance 3 is not a core memory after one mistake)
    local scope13 = "repo:fold-escimp"
    local i1, i2 = put(scope13, "important single-mistake cluster about the root password policy", 3), put(scope13, "important single-mistake cluster about the root password policy", 3)
    local j1, j2 = put(scope13, "important double-mistake cluster about the backup encryption key", 3), put(scope13, "important double-mistake cluster about the backup encryption key", 3)
    events(i2, scope13, "mistake", 1); events(j1, scope13, "mistake", 2)
    check("(set up) the members are tier 0 with importance 3", tier_of(i1) == 0 and imp_of(i1) == 3 and tier_of(j1) == 0)
    digest.run(scope13, { no_llm = true })
    check("1 mistake on a row of importance 3: still tier 0 and its importance is untouched (it is not above the relevance)",
        tier_of(i1) == 0 and tier_of(i2) == 0 and imp_of(i1) == 3, ("%s %s"):format(tostring(tier_of(i1)), tostring(imp_of(i1))))
    check("2 mistakes on a row of importance 3: tier 1, not 3 (and its copy is folded)", tier_of(j1) == 1 and not folded_id(j1) and folded_id(j2) and imp_of(j1) == 3,
        ("tier=%s importance=%s"):format(tostring(tier_of(j1)), tostring(imp_of(j1))))

    -- a mixed scope: the notes with no vector are left alone while the others are folded; once they are re-embedded the
    -- next run takes them
    local scope14 = "repo:fold-mixed"
    local w1, w2 = put(scope14, "a saved page about the warehouse shelving layout"), put(scope14, "a saved page about the warehouse shelving layout")
    local v1, v2 = put(scope14, "a long export about the courier tracking numbers"), put(scope14, "another long export about the courier tracking numbers")
    db.run("UPDATE lm_memories SET embedding = NULL WHERE id IN (?, ?)", v1, v2)
    local md = digest.run(scope14, { no_llm = true })
    check("a scope with notes with and without a vector: the first two are folded, the others untouched and uncounted",
        md.processed == 2 and folded_id(w1) and folded_id(w2) and not folded_id(v1) and not folded_id(v2) and #md.errors == 0, json.encode(md))
    assert(store.reembed_scope(scope14))
    local md2 = digest.run(scope14, { no_llm = true })
    check("once re-embedded they are taken by the next run", md2.processed >= 2 and folded_id(v1) and folded_id(v2), json.encode(md2))

    -- a note written with a title only (it has a vector: the title is embedded) is made into an observation of its title —
    -- an empty text left it unconsolidated, taken again by every run, with no error
    local scope42 = "repo:fold-titleonly"
    local TITLE42 = "reminder: rotate the staging keys on friday"
    local to = assert(store.write({ scope = scope42, title = TITLE42, body = "", importance = 0.2, tier = 0, dedup_strategy = "append" })).id
    local td = digest.run(scope42, { no_llm = true })
    check("a title-only note: consolidated and archived, an observation of its title holds it",
        consolidated(to) and folded_id(to) and #td.errors == 0
        and db.value("SELECT body FROM lm_observations WHERE scope = ?", scope42) == TITLE42, json.encode(td))

    -- a cluster of 450 notes (the mark was once chunked, 400 a statement; it is one statement, whatever the size): every
    -- note is marked, and archived
    local scope43 = "repo:fold-bigcluster"
    for _ = 1, 450 do put(scope43, "the same saved page about the warehouse forklift charging rota") end
    local bd = digest.run(scope43, { no_llm = true })
    check("a 450-note cluster: all 450 consolidated and archived (one marking statement, whatever the size)",
        n("SELECT count(*) FROM lm_memories WHERE scope = ? AND consolidated_at IS NOT NULL", scope43) == 450 and H.folded(scope43) == 450
        and #bd.errors == 0, json.encode(bd))

end)

section("what the digest cannot read or the consolidation cannot do: reported, nothing archived", function()
    -- a query the digest cannot read is REPORTED, and nothing is clustered, consolidated or archived: a mistaken note
    -- archived because its mistakes could not be counted would be hidden for good, never escalated
    local scope20 = "repo:fold-qfail"
    local qa = put(scope20, "mistaken note about the staging deploy window"); put(scope20, "mistaken note about the staging deploy window")
    events(qa, scope20, "mistake", 3)
    local member20 = member(scope20, 1)
    holds(scope20, { member20 }, 9, "stable")
    local qd1 = H.on_sql(db, "query", "GROUP BY memory_id", function() return nil, "database is locked" end, digest.run, scope20, { no_llm = true })
    check("the mistake counts cannot be read: reported as 'mistake counts error: …', nothing is archived or consolidated",
        qd1.processed == 0 and #qd1.errors == 1 and qd1.errors[1] == "mistake counts error: database is locked"
        and not folded_id(qa) and tier_of(qa) == 0 and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND consolidated_at IS NOT NULL", scope20) == 0, json.encode(qd1))
    check("… the promotion of the same run still ran", qd1.promoted2 == 1 and tier_of(member20) == 2, json.encode(qd1))
    local qd2 = digest.run(scope20, { no_llm = true })
    check("… and the next run escalates the mistaken note (3 mistakes: tier 1) and folds its copy",
        qd2.processed == 2 and #qd2.errors == 0 and tier_of(qa) == 1 and not folded_id(qa), json.encode(qd2))
    local scope20b = "repo:fold-qfail2"
    put(scope20b, "note about the badge printer toner order"); put(scope20b, "another note about the lobby plant watering")
    local qd3 = H.on_sql(db, "query", "FROM lm_memories WHERE scope = ? AND tier = 0", function() return nil, "boom" end, digest.run, scope20b, { no_llm = true })
    check("the notes cannot be read: reported as 'fetch tier-0 error: …', nothing is done with the scope's notes",
        qd3.processed == 0 and #qd3.errors == 1 and qd3.errors[1] == "fetch tier-0 error: boom" and H.folded(scope20b) == 0, json.encode(qd3))
    -- … in a dry run too: the error is reported, not read as "nothing to digest"
    local scope20c = "repo:fold-qfail3"
    local dq = put(scope20c, "mistaken note about the dry run deploy window"); put(scope20c, "mistaken note about the dry run deploy window")
    events(dq, scope20c, "mistake", 2)
    local dd1 = H.on_sql(db, "query", "GROUP BY memory_id", function() return nil, "database is locked" end, digest.run, scope20c, { no_llm = true, dry_run = true })
    check("a dry run whose mistake counts cannot be read reports it and counts nothing",
        dd1.processed == 0 and #dd1.errors == 1 and dd1.errors[1] == "mistake counts error: database is locked", json.encode(dd1))
    local dd2 = H.on_sql(db, "query", "FROM lm_memories WHERE scope = ? AND tier = 0", function() return nil, "boom" end, digest.run, scope20c, { no_llm = true, dry_run = true })
    check("a dry run whose notes cannot be read reports it and counts nothing",
        dd2.processed == 0 and #dd2.errors == 1 and dd2.errors[1] == "fetch tier-0 error: boom", json.encode(dd2))

    -- the consolidation cannot read the rows it is to take: nothing was made from them, so nothing is archived (the review
    -- would delete a note no observation holds); the next run does it
    local scope26 = "repo:fold-pfail"
    put(scope26, "a plain note about the loading dock schedule"); put(scope26, "a plain note about the loading dock schedule")
    local pd1 = H.on_sql(db, "query", "IS NOT NULL ORDER BY id", function() return nil, "database is locked" end, digest.run, scope26, { no_llm = true })
    check("consolidate.process cannot read the rows: 'consolidate error: fetch error: …', nothing archived, no observation made",
        pd1.processed == 0 and #pd1.errors == 1 and pd1.errors[1] == "consolidate error: fetch error: database is locked"
        and H.folded(scope26) == 0 and obs_count(scope26) == 0, json.encode(pd1))
    local pd2 = digest.run(scope26, { no_llm = true })
    check("… the next run folds both and an observation holds them",
        pd2.processed == 2 and #pd2.errors == 0 and H.folded(scope26) == 2 and obs_count(scope26) == 1, json.encode(pd2))
    local scope27 = "repo:fold-pfail2"
    put(scope27, "a plain note about the fire drill route"); put(scope27, "another note about the fire drill muster point")
    local tries = 0
    local pr = H.on_sql(db, "query", "IS NOT NULL ORDER BY id", function() tries = tries + 1; return nil, "database is locked" end,
        consolidate.process, scope27, { no_llm = true, limit = 1 })
    check("consolidate.process whose fetch fails: failed + the error, the scope stays pending, and a limited fetch is not retried without its limit",
        pr.failed == "fetch error: database is locked" and #pr.errors == 1 and pr.errors[1] == "consolidate: " .. pr.failed and pr.reinforced == 0 and pr.synthesised == 0
        and consolidate.pending(scope27) and tries == 1, ("tries=%d %s"):format(tries, json.encode(pr)))
    -- a process that reports it did nothing (not configured) archives nothing either: the real thing — consolidate.process of
    -- a module that is not configured says so itself, and the digest on top of it archives nothing (restored by conf() — and
    -- by the section's end, a crash included)
    local scope29 = "repo:fold-notconf"
    put(scope29, "a plain note about the office move checklist"); put(scope29, "another note about the office move checklist")
    consolidate.configure(nil)
    consolidate.notify(scope29)
    local nr = consolidate.process(scope29, { no_llm = true })
    check("consolidate.process when not configured: failed 'not configured', one error, nothing done, the scope stays pending",
        nr.failed == "not configured" and #nr.errors == 1 and nr.errors[1] == "consolidate: not configured" and nr.reinforced == 0 and nr.synthesised == 0
        and consolidate.pending(scope29), json.encode(nr))
    local nd2 = digest.run(scope29, { no_llm = true })
    conf()
    check("… the digest on an unconfigured consolidation archives nothing and reports it",
        nd2.processed == 0 and #nd2.errors == 1 and nd2.errors[1] == "consolidate error: not configured" and H.folded(scope29) == 0, json.encode(nd2))

    -- the errors of the observation writes read as 'insert obs: <why>' / 'reinforce obs N: <why>' (no file:line, said once)
    local scope30 = "repo:fold-insfail"
    local ins = put(scope30, "a plain note about the badge reader firmware")
    local ir = H.on_sql(db, "run", "INSERT INTO lm_observations", function() return nil, "boom" end, consolidate.process, scope30, { no_llm = true })
    check("an observation that cannot be inserted: one error 'insert obs: boom', nothing synthesised, the note is NOT marked consolidated",
        ir.synthesised == 0 and #ir.errors == 1 and ir.errors[1] == "insert obs: boom"
        and not consolidated(ins), json.encode(ir))
    local ir2 = consolidate.process(scope30, { no_llm = true })
    check("… the next call makes the observation and marks the note", ir2.synthesised == 1 and #ir2.errors == 0 and consolidated(ins), json.encode(ir2))
    local scope31 = "repo:fold-updfail"
    local OBS31 = "observation about the nightly log rotation job and its retention window"
    observe(scope31, OBS31, {})
    local obs31 = n("SELECT id FROM lm_observations WHERE scope = ?", scope31)
    local upd31 = put(scope31, OBS31)
    local ur = H.with_trigger("t_fold_obs_upd", "BEFORE UPDATE ON lm_observations BEGIN SELECT RAISE(ABORT, 'locked by a trigger'); END",
        consolidate.process, false, scope31, { no_llm = true })
    check("an observation whose update fails: one error 'reinforce obs N: <the database's reason>', nothing reinforced, the note NOT marked consolidated",
        ur.reinforced == 0 and #ur.errors == 1 and ur.errors[1]:find("^reinforce obs " .. obs31 .. ": ") and ur.errors[1]:find("locked by a trigger", 1, true)
        and not ur.errors[1]:find("consolidate.lua", 1, true) and n("SELECT proof_count FROM lm_observations WHERE id = ?", obs31) == 1
        and not consolidated(upd31), json.encode(ur))

    -- a search whose inline consolidation cannot read its rows: it still answers, raises nothing, the scope stays pending for
    -- the next search, and that one does the work
    local scope32 = "repo:fold-searchfail"
    local sn = put(scope32, "a settled note about the badge reader firmware rollout plan")
    db.run("UPDATE lm_memories SET tier = 1 WHERE id = ?", sn)
    consolidate.notify(scope32)
    local fetch_failures = 0
    local search_res, search_err = H.on_sql(db, "query", "IS NOT NULL AND tier >= 1 ORDER BY id",
        function() fetch_failures = fetch_failures + 1; return nil, "database is locked" end,
        store.search, { query = "badge reader firmware", scope = scope32, limit = 3 })
    check("a search whose inline consolidation fails (the failure was hit once): still answers (the note), the scope stays pending, nothing consolidated",
        fetch_failures == 1 and search_res ~= nil and search_err == nil and #search_res >= 1 and consolidate.pending(scope32)
        and not consolidated(sn), ("hits=%d %s"):format(fetch_failures, tostring(search_err)))
    store.search({ query = "badge reader firmware", scope = scope32, limit = 3 })
    check("… the next search consolidates it: no longer pending, the note is consolidated", not consolidate.pending(scope32) and consolidated(sn))

    -- the review's errors and deleted count are the digest's: "review: …"; a dry run does not review
    local scope21 = "repo:fold-reviewerr"
    local rv = H.with(fold, "run", function() return { errors = { "memory 7: boom" }, deleted = 3 } end, digest.run, scope21, { no_llm = true })
    check("a review that reports an error: it is in the digest's errors with 'review: ', and its deleted count is the digest's",
        #rv.errors == 1 and rv.errors[1] == "review: memory 7: boom" and rv.deleted == 3, json.encode(rv))
    local reviewed = false
    H.with(fold, "run", function() reviewed = true; return { errors = {}, deleted = 0 } end, digest.run, scope21, { no_llm = true, dry_run = true })
    check("a dry run does not review", not reviewed)

    -- one cluster's observation cannot be written: its notes are neither marked nor archived (the review would delete them as
    -- notes nothing holds), the error is the digest's, and the next run does it
    local scope35 = "repo:fold-insfail-digest"
    local TEXT35 = "a plain note about the stairwell lighting schedule"
    local f1, f2 = put(scope35, TEXT35), put(scope35, TEXT35)
    local fd = H.on_sql(db, "run", "INSERT INTO lm_observations", function() return nil, "boom" end, digest.run, scope35, { no_llm = true })
    check("the digest on a cluster whose observation cannot be written: reported as 'consolidate: insert obs: boom', the notes are neither marked nor archived",
        #fd.errors == 1 and fd.errors[1] == "consolidate: insert obs: boom" and not consolidated(f1) and not consolidated(f2)
        and not folded_id(f1) and not folded_id(f2), json.encode(fd))
    local fd2 = digest.run(scope35, { no_llm = true })
    check("… the next run makes the observation and archives them", #fd2.errors == 0 and folded_id(f1) and folded_id(f2) and obs_count(scope35) == 1, json.encode(fd2))

    -- the notes cannot be marked: the cluster's write is one transaction, so the observation made for them goes too — the
    -- error is the digest's, nothing is consolidated, archived or observed, and the next run does it all (the proof and the
    -- evidence are counted once)
    local scope40 = "repo:fold-markfail"
    local TEXT40 = "a plain note about the fire extinguisher inspection tags"
    local g1, g2 = put(scope40, TEXT40), put(scope40, TEXT40)
    local gd = H.on_sql(db, "run", "SET consolidated_at = ? WHERE id IN", function() return nil, "boom" end, digest.run, scope40, { no_llm = true })
    check("a mark that fails: 'consolidate: mark consolidated: boom', no observation either, the notes neither consolidated nor archived",
        #gd.errors == 1 and tostring(gd.errors[1]):find("^consolidate: mark consolidated: .*boom") and not consolidated(g1) and not consolidated(g2)
        and not folded_id(g1) and not folded_id(g2) and obs_count(scope40) == 0, json.encode(gd))
    local gd2 = digest.run(scope40, { no_llm = true })
    check("… the next run: one observation holding both notes, counted once; both archived",
        #gd2.errors == 0 and folded_id(g1) and folded_id(g2) and obs_count(scope40) == 1
        and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope40) == 2
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope40) == 2, json.encode(gd2))

    -- a summarizer that gives no text for a cluster: no observation, the notes wait — and it is said, not silent
    package.loaded["luamemo.summarizers.testempty"] = { summarize = function() return { title = "", body = "" } end }
    local with_empty = {}
    for k, v in pairs(luamemo.config) do with_empty[k] = v end
    with_empty.summarizer_adapter = "testempty"
    local scope41 = "repo:fold-emptysynth"
    local TEXT41 = "a plain note about the parking garage height limit"
    local h1, h2 = put(scope41, TEXT41), put(scope41, TEXT41)
    consolidate.configure(with_empty)
    local er = consolidate.process(scope41)   -- (not no_llm: a cluster of two goes to the summarizer)
    conf()
    check("a summarizer that gives no text: 'synthesize: empty body', no observation, the notes not consolidated",
        #er.errors == 1 and er.errors[1] == "synthesize: empty body" and er.synthesised == 0 and obs_count(scope41) == 0
        and not consolidated(h1) and not consolidated(h2), json.encode(er))

    -- A summarizer stub for the digest to use (consolidate configured with a copy of the config; put back by conf())
    local function summarizing(name, stub, extra, fn)
        package.loaded["luamemo.summarizers." .. name] = stub
        local with = {}
        for k, v in pairs(luamemo.config) do with[k] = v end
        with.summarizer_adapter = name
        for k, v in pairs(extra or {}) do with[k] = v end
        consolidate.configure(with)
        local ok, res = pcall(fn)
        conf()
        if not ok then error(res, 0) end
        return res
    end
    -- an answer with a title and an EMPTY body is an observation of its title (it used to be asked again at every run)
    local scope46 = "repo:fold-titleanswer"
    local TEXT46 = "a plain note about the keycard renewal process"
    local ta1, ta2 = put(scope46, TEXT46), put(scope46, TEXT46)
    local tr = summarizing("testtitle", { summarize = function() return { title = "Rotate the staging keys", body = "" } end }, nil,
        function() return consolidate.process(scope46) end)
    check("a summarizer answering a title and an empty body: an observation of the title, the notes consolidated, no error",
        #tr.errors == 0 and tr.synthesised == 1 and db.value("SELECT body FROM lm_observations WHERE scope = ?", scope46) == "Rotate the staging keys"
        and consolidated(ta1) and consolidated(ta2), json.encode(tr))
    -- a title-only note is made into an observation WITHOUT an embedder call: its own vector is the title's
    local embed_calls = 0
    local scope47 = "repo:fold-titleonly-vector"
    local tv = assert(store.write({ scope = scope47, title = "reminder: renew the visitor badge printer licence", body = "", importance = 0.2, tier = 0, dedup_strategy = "append" })).id
    H.on_sql(require("luamemo.embed"), "embed", "", function(real, ...) embed_calls = embed_calls + 1; return real(...) end, digest.run, scope47, { no_llm = true })
    check("a title-only note's observation reuses its stored vector: no embedder call", embed_calls == 0 and folded_id(tv), tostring(embed_calls))

    -- the second kind of "consolidate: …" entry: a notice about an observation that WAS written — the notes are archived
    local scope48 = "repo:fold-notice"
    local TEXT48 = "a plain note about the lobby screen content schedule"
    local nt1, nt2 = put(scope48, TEXT48), put(scope48, TEXT48)
    local nd = summarizing("testdown", { summarize = function() return nil, "model down" end }, { consolidate_log_errors = true },
        function() return digest.run(scope48) end)
    check("a summarizer that failed (logged): 'consolidate: synthesize: model down' — and the observation of the best member's text is made, the notes archived",
        #nd.errors == 1 and nd.errors[1] == "consolidate: synthesize: model down" and folded_id(nt1) and folded_id(nt2) and obs_count(scope48) == 1, json.encode(nd))
    local scope49 = "repo:fold-notice-embed"
    local TEXT49 = "a plain note about the atrium plant watering rota"
    local ne1, ne2 = put(scope49, TEXT49), put(scope49, TEXT49)
    local ned = summarizing("testmerged", { summarize = function() return { title = "Atrium plants", body = "the atrium plants are watered on mondays and fridays" } end }, nil,
        function()
            return H.with(require("luamemo.embed"), "embed", function() return nil, "embedder down" end, digest.run, scope49)
        end)
    check("an observation whose wording could not be embedded: 'consolidate: embed obs body: embedder down' — made with the cluster's vector, the notes archived",
        #ned.errors == 1 and tostring(ned.errors[1]):find("^consolidate: embed obs body: .*embedder down") and folded_id(ne1) and folded_id(ne2)
        and obs_count(scope49) == 1, json.encode(ned))
    -- one cluster fails and another does not: the one is archived, the other waits, and only its error is reported
    local scope50 = "repo:fold-two-fates"
    local fa1, fa2 = put(scope50, "a plain note about the roof access ladder inspection"), put(scope50, "a plain note about the roof access ladder inspection")
    local fb1, fb2 = put(scope50, "a plain note about the cold storage temperature log"), put(scope50, "a plain note about the cold storage temperature log")
    local inserts = 0
    local fate = H.on_sql(db, "run", "INSERT INTO lm_observations", function(real, ...)
        inserts = inserts + 1
        if inserts == 1 then return nil, "boom" end
        return real(...)
    end, digest.run, scope50, { no_llm = true })
    local archived_count = (folded_id(fa1) and 1 or 0) + (folded_id(fa2) and 1 or 0) + (folded_id(fb1) and 1 or 0) + (folded_id(fb2) and 1 or 0)
    check("two clusters, the first observation fails: one error, the other cluster archived (2 notes), the failed one waits (2 notes)",
        #fate.errors == 1 and fate.errors[1] == "consolidate: insert obs: boom" and archived_count == 2 and obs_count(scope50) == 1, json.encode(fate))
end)

section("a reinforcement by the consolidation (two clusters on one observation, an observation gone); opts.threshold", function()
    -- a reinforcement from the consolidation: two clusters of one run reinforce the SAME observation (the proof adds up
    -- from the row, once per cluster); an observation that is gone by then is an error and its notes are left for the next run
    local scope22 = "repo:fold-two-clusters"
    conf({ consolidate_threshold = 0.99999 })   -- (the two variants below are two clusters, each close enough to the observation)
    observe(scope22, BASE, {})
    local cl1, cl2 = put(scope22, BASE .. " alpha"), put(scope22, BASE .. " bravo")
    local cr = consolidate.process(scope22, { no_llm = true })
    conf()
    check("two clusters of one consolidation both reinforce the observation: reinforced 2, proof 1 + 1 + 1, no error",
        cr.reinforced == 2 and #cr.errors == 0 and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope22) == 3
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope22) == 2
        and n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?) AND consolidated_at IS NOT NULL", cl1, cl2) == 2, json.encode(cr))
    local scope23 = "repo:fold-reinforce-gone"
    observe(scope23, BASE, {})
    local obs23 = n("SELECT id FROM lm_observations WHERE scope = ?", scope23)
    local gone = put(scope23, BASE)
    local real_tx = db.transaction
    local fr = H.with(db, "transaction", function(fn, ...)
        db.run("DELETE FROM lm_observations WHERE scope = ?", scope23)   -- (gone between the scan and the reinforcement)
        return real_tx(fn, ...)
    end, consolidate.process, scope23, { no_llm = true })
    check("an observation that is gone when it is reinforced: 'reinforce obs N: observation N not found' (no file:line, said once), nothing reinforced, the note is NOT marked consolidated",
        fr.reinforced == 0 and #fr.errors == 1 and fr.errors[1] == ("reinforce obs %d: observation %d not found"):format(obs23, obs23)
        and not consolidated(gone), json.encode(fr))

    -- opts.threshold: the grouping of the digest's own pass. Two near-identical notes, the mistakes on the lower-importance
    -- one: grouped (the default), the higher-importance note is the cluster's best and the one escalated; apart (a threshold
    -- nothing reaches), each is its own cluster and the mistaken one is the one escalated
    local function twins(scope_name)
        local hi_note, lo_note = put(scope_name, BASE .. " alpha", 0.6), put(scope_name, BASE .. " bravo", 0.2)
        events(lo_note, scope_name, "mistake", 2)
        return hi_note, lo_note
    end
    local thr_default, thr_apart = "repo:fold-thr-default", "repo:fold-thr-apart"
    local hi_g, lo_g = twins(thr_default)
    digest.run(thr_default, { no_llm = true })
    check("(control) by default the two notes are one cluster: the higher-importance one is escalated and visible",
        tier_of(hi_g) == 1 and not folded_id(hi_g) and folded_id(lo_g), ("hi=%s lo=%s"):format(tostring(tier_of(hi_g)), tostring(tier_of(lo_g))))
    local hi_a, lo_a = twins(thr_apart)
    digest.run(thr_apart, { no_llm = true, threshold = 1.1 })
    check("opts.threshold = 1.1: two clusters — the mistaken note is the one escalated and visible, the other is folded",
        tier_of(lo_a) == 1 and not folded_id(lo_a) and folded_id(hi_a), ("hi=%s lo=%s"):format(tostring(tier_of(hi_a)), tostring(tier_of(lo_a))))
    check("… the observations are not made at that threshold: process groups the twins as it does by default (one observation holding both)",
        obs_count(thr_apart) == 1 and obs_count(thr_default) == 1
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", thr_apart) == 2
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", thr_default) == 2)

    -- an observation that already holds notes (their ids are in its evidence) is not credited with them a second time when
    -- the notes are consolidated again: no proof, evidence or quote is added for a note it already holds
    local scope51 = "repo:fold-reinforce-held"
    observe(scope51, BASE, {})
    local hn1, hn2 = put(scope51, BASE), put(scope51, BASE)
    db.run("UPDATE lm_observations SET evidence_ids = ?, proof_count = 2 WHERE scope = ?", db.json({ hn1, hn2 }), scope51)
    local hr = consolidate.process(scope51, { no_llm = true })
    check("notes an observation already holds: reinforced, but proof and evidence unchanged (2 and 2); the notes marked",
        hr.reinforced == 1 and #hr.errors == 0 and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope51) == 2
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope51) == 2
        and consolidated(hn1) and consolidated(hn2), json.encode(hr))

    -- memory_digest / memo digest `threshold` (a string from the CLI) reaches the digest's own grouping
    local thr_ops = "repo:fold-thr-ops"
    local hi_o, lo_o = twins(thr_ops)
    local ops_res = require("luamemo.ops").digest({ threshold = "1.0" }, thr_ops)
    check("ops.digest: a threshold of '1.0' (a string) puts the twins in two clusters: the mistaken one is escalated and visible",
        ops_res and ops_res.ok and tier_of(lo_o) == 1 and not folded_id(lo_o) and folded_id(hi_o), json.encode(ops_res))
end)

section("a note changed while the digest consolidates, and an observation that goes with its memory", function()
    -- Two copies of a note; the digest runs, and `mutate(first_id)` happens in the middle of it: "between" — once
    -- consolidate.process has READ its rows (before it makes the observation and marks them), "after" — once process has
    -- returned (before the archive) → the digest's result, the two ids.
    local function digest_with_change(scope_name, text, when, mutate)
        local first, second = put(scope_name, text), put(scope_name, text)
        local res
        if when == "between" then
            res = H.on_sql(db, "query", "IS NOT NULL ORDER BY id", function(real, sql, ...)
                local rows, err = real(sql, ...)
                mutate(first)
                return rows, err
            end, digest.run, scope_name, { no_llm = true })
        else
            local real_process = consolidate.process
            res = H.with(consolidate, "process", function(...)
                local r = real_process(...)
                mutate(first)
                return r
            end, digest.run, scope_name, { no_llm = true })
        end
        return res, first, second
    end
    local function rewrite(id) assert(store.update(id, { body = "EDITED: the toner order now goes through procurement, ticket 4411" })) end
    -- rewritten after the observation was made: the edit deletes the observation (its text is the old one) and gives back
    -- the copy it held — neither is archived, and the next run makes the observation again
    local scope33 = "repo:fold-edited"
    local d33, ed1, ed2 = digest_with_change(scope33, "a plain note about the badge printer toner order", "after", rewrite)
    check("a note rewritten after process and before the archive: it and its copy are left (the observation went with the edit); no error, and the rows still count in `processed`",
        not folded_id(ed1) and not folded_id(ed2) and not consolidated(ed1) and not consolidated(ed2) and obs_count(scope33) == 0
        and #d33.errors == 0 and d33.processed == 2, json.encode(d33))
    local d33b = digest.run(scope33, { no_llm = true })
    check("… the next run takes both: archived, an observation holds them",
        folded_id(ed1) and folded_id(ed2) and obs_count(scope33) >= 1 and #d33b.errors == 0, json.encode(d33b))
    -- rewritten between process's read and its write: the cluster was read out of date, so no observation is made from it
    -- (it would carry the old text and the id) and nothing is marked or archived — the whole cluster waits, without an error
    local scope33b = "repo:fold-edited-between"
    local d33c, bt1, bt2 = digest_with_change(scope33b, "a plain note about the badge printer toner order", "between", rewrite)
    check("a note rewritten while process works: its cluster waits — no observation, neither note marked or archived, no error",
        not consolidated(bt1) and not folded_id(bt1) and not consolidated(bt2) and not folded_id(bt2) and obs_count(scope33b) == 0
        and #d33c.errors == 0, json.encode(d33c))
    digest.run(scope33b, { no_llm = true })
    check("… the next run takes both", consolidated(bt1) and folded_id(bt1) and folded_id(bt2) and obs_count(scope33b) >= 1)
    -- moved to another scope between process's read and its write: no observation of the old scope carries it either
    local scope33c, scope33c_to = "repo:fold-moved-between", "repo:fold-moved-between-to"
    local _, mb1, mb2 = digest_with_change(scope33c, "a plain note about the loading bay camera schedule", "between",
        function(id) assert(store.update(id, { scope = scope33c_to })) end)
    check("a note moved while process works: no observation of the old scope lists it; its copy waits too",
        db.value("SELECT scope FROM lm_memories WHERE id = ?", mb1) == scope33c_to and obs_count(scope33c) == 0
        and not consolidated(mb2) and not folded_id(mb2))
    -- moved to another scope after the mark: a move takes what was distilled from the note in its old scope with it (the
    -- observation, which may carry its text) and gives its copy back; the destination's digest takes the note — it used to
    -- stay consolidated, taken by no digest, and the destination's review deleted it as a note nothing holds
    local scope34, scope34_to = "repo:fold-moved", "repo:fold-moved-to"
    local _, mv1, mv2 = digest_with_change(scope34, "a plain note about the loading bay door codes", "after",
        function(id) assert(store.update(id, { scope = scope34_to })) end)
    check("a note moved to another scope while the digest consolidates: not archived; unconsolidated in its new scope; the old observation is gone and its copy given back",
        db.value("SELECT scope FROM lm_memories WHERE id = ?", mv1) == scope34_to and not folded_id(mv1) and not consolidated(mv1)
        and obs_count(scope34) == 0 and not folded_id(mv2) and not consolidated(mv2))
    digest.run(scope34_to, { no_llm = true }); digest.run(scope34, { no_llm = true })
    check("… each scope's next digest takes its note: archived, held by an observation of its own scope",
        folded_id(mv1) and folded_id(mv2)
        and n("SELECT count(*) FROM lm_observations o, json_each(o.evidence_ids) e WHERE o.scope = ? AND CAST(e.value AS INTEGER) = ?", scope34_to, mv1) == 1
        and n("SELECT count(*) FROM lm_observations o, json_each(o.evidence_ids) e WHERE o.scope = ? AND CAST(e.value AS INTEGER) = ?", scope34, mv2) == 1)

    -- … and a consolidated note that no observation holds (its observation went some other way) is unconsolidated by a
    -- move all the same: the destination's digest must be able to take it
    local scope34b, scope34b_to = "repo:fold-moved-bare", "repo:fold-moved-bare-to"
    local bare = put(scope34b, "a plain note about the visitor parking passes")
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), bare)
    assert(store.update(bare, { scope = scope34b_to }))
    check("a consolidated note no observation holds, moved: unconsolidated in its new scope", not consolidated(bare))

    -- An observation goes with one of the memories it was made from: three copies of a note, the third (more important,
    -- mistakes behind it) escalated and visible, the two others archived; then `mutate(visible id)` → whether the set-up held
    -- and the two archived notes came back (the observation gone, both shown again and unconsolidated), their ids
    local TEXT36 = "a plain note about the conference room booking rules"
    local function given_back(scope_name, mutate)
        local a, b, v = put(scope_name, TEXT36), put(scope_name, TEXT36), put(scope_name, TEXT36, 0.5)
        events(v, scope_name, "mistake", 2)
        digest.run(scope_name, { no_llm = true })
        -- (the visible one is tier 2 once the observation's proof of 3 promotes it)
        local set_up = tier_of(v) >= 1 and not folded_id(v) and folded_id(a) and folded_id(b) and obs_count(scope_name) == 1
        mutate(v)
        return set_up and obs_count(scope_name) == 0 and not folded_id(a) and not folded_id(b) and not consolidated(a)
            and not consolidated(b), a, b
    end
    local back, k1, k2 = given_back("repo:fold-forget", function(v) assert(store.delete(v)) end)
    check("deleting the visible note deletes the observation and gives the archived notes back: visible and unconsolidated", back)
    digest.run("repo:fold-forget", { no_llm = true })
    check("… the next digest takes them again: archived, an observation holds them", folded_id(k1) and folded_id(k2) and obs_count("repo:fold-forget") == 1)
    check("giving the visible note new text does the same", (given_back("repo:fold-forget-edit",
        function(v) assert(store.update(v, { body = "EDITED: the conference rooms are booked through the new portal" })) end)))
    check("moving the visible note to another scope does the same", (given_back("repo:fold-forget-move",
        function(v) assert(store.update(v, { scope = "repo:fold-forget-move-to" })) end)))
    -- … one transaction: a release that fails rolls the delete of the observation back — the archived notes keep their
    -- holder — and the failure is SAID: a warning on the delete's answer and a line on stderr (the observation may still
    -- serve the text of a note that is gone)
    local seen_stderr, fail_res
    local _, s1, s2 = given_back("repo:fold-forget-fail", function(v)
        fail_res, seen_stderr = H.failing_sql("run", "json_remove", store.delete, v)
    end)
    check("a release that fails: nothing changes — the observation stays and still holds the archived notes",
        obs_count("repo:fold-forget-fail") == 1 and folded_id(s1) and folded_id(s2))
    check("… and it is said: the delete's answer carries a warning, and stderr a line",
        fail_res and fail_res.affected_rows == 1 and tostring(fail_res.warning):find("could not be removed", 1, true)
        and tostring(fail_res.warning):find("boom", 1, true) and tostring(seen_stderr[1]):find("[luamemo]", 1, true), json.encode(fail_res))
    -- … a DELETE of the observation that fails AFTER the release went through undoes the release too (one transaction)
    local d_res
    local _, u1, u2 = given_back("repo:fold-forget-delfail", function(v)
        d_res = H.failing_sql("run", "DELETE FROM lm_observations WHERE id IN", store.delete, v)
    end)
    check("an observation delete that fails after the release: the release is undone — the notes stay archived and consolidated, the observation stays",
        d_res and d_res.warning ~= nil and obs_count("repo:fold-forget-delfail") == 1 and folded_id(u1) and folded_id(u2) and consolidated(u1) and consolidated(u2))
    local q_res
    local _, w1, w2 = given_back("repo:fold-forget-readfail", function(v)
        q_res = H.failing_sql("query", "SELECT o.id, o.scope, o.evidence_ids", store.delete, v)
    end)
    check("observations that cannot be read: warned, nothing changes", q_res and q_res.warning ~= nil and obs_count("repo:fold-forget-readfail") == 1
        and folded_id(w1) and folded_id(w2))
    -- an update that neither rewrites nor moves a note (the same scope given, or only importance / tags) leaves everything as it is
    local keep_scope = "repo:fold-forget-keep"
    local _, y1, y2 = given_back(keep_scope, function(v)
        assert(store.update(v, { scope = keep_scope, importance = 3 })); assert(store.update(v, { tags = { "x" } }))
    end)
    check("an update with the note's own scope, or only importance and tags, keeps the observation and its archived notes",
        obs_count(keep_scope) == 1 and folded_id(y1) and folded_id(y2))
    -- … a move tells the destination (a note of tier >= 1 is consolidated there by a search, not by a digest)
    local dest = "repo:fold-forget-move-notified"
    local moved_note = put("repo:fold-forget-move-from", "a plain note about the cafeteria recycling rota")
    db.run("UPDATE lm_memories SET tier = 1, consolidated_at = ? WHERE id = ?", util.now_us(), moved_note)
    assert(store.update(moved_note, { scope = dest }))
    check("a move leaves the note unconsolidated and the destination pending", not consolidated(moved_note) and consolidate.pending(dest))

    -- an archived original that is edited or moved is its own memory again: its fold record goes, it is shown again at
    -- the tier it had before it was folded (not hidden in its new place, and not reviewed on its old clock)
    local scope44 = "repo:fold-edit-archived"
    local ea_raw, ea_sum = put(scope44, "a raw note about the shuttle bus timetable"), put(scope44, "a settled note about the shuttle bus stops")
    db.run("UPDATE lm_memories SET tier = 1 WHERE id = ?", ea_sum)
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id IN (?, ?)", util.now_us(), ea_raw, ea_sum)
    fold.archive({ ea_raw }, "observation", nil); fold.archive({ ea_sum }, "summary", ea_raw)
    assert(store.update(ea_raw, { scope = "repo:fold-edit-archived-to" })); assert(store.update(ea_sum, { body = "the shuttle bus stops moved to the north gate" }))
    check("an archived original that is moved or edited: no fold record, unconsolidated, back at the tier it had",
        not folded_id(ea_raw) and not folded_id(ea_sum) and not consolidated(ea_raw) and not consolidated(ea_sum)
        and tier_of(ea_raw) == 0 and tier_of(ea_sum) == 1)

    -- the members of an observation that went away with a tier of 1 or more are not hidden, but they are unconsolidated:
    -- their observation is made again (else its proof and the promotions it drove are gone for good)
    local scope45 = "repo:fold-tier2-kin"
    local kin_a, kin_b = put(scope45, "deploys go through the blue green switch"), put(scope45, "deploys go through the blue green switch")
    db.run("UPDATE lm_memories SET tier = 2, consolidated_at = ? WHERE id IN (?, ?)", util.now_us(), kin_a, kin_b)
    observe(scope45, "deploys go through the blue green switch", { kin_a, kin_b })
    assert(store.delete(kin_a))
    check("deleting one member of an observation: the observation goes; a tier-2 member is unconsolidated (and the scope pending) to be observed again",
        obs_count(scope45) == 0 and tier_of(kin_b) == 2 and not consolidated(kin_b) and consolidate.pending(scope45))

    -- fold.archive in the digest's mode (a scope): only a row that is consolidated, tier 0 and of that scope; the others are
    -- left as they are — 0, not an error — and a scope that is not a string is refused (the old boolean would bind as one)
    local scope38 = "repo:fold-archive-mode"
    local ar1, ar2 = put(scope38, "a plain note about the label printer ribbons"), put(scope38, "a plain note about the postage meter refill")
    check("fold.archive (digest mode) on notes that are not consolidated: 0, untouched",
        fold.archive({ ar1, ar2 }, "observation", nil, nil, scope38) == 0 and not folded_id(ar1) and not folded_id(ar2))
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id IN (?, ?)", util.now_us(), ar1, ar2)
    check("… consolidated but of another scope: 0, untouched", fold.archive({ ar1 }, "observation", nil, nil, "repo:somewhere-else") == 0 and not folded_id(ar1))
    check("… consolidated, tier 0, this scope: archived", fold.archive({ ar1, ar2 }, "observation", nil, nil, scope38) == 2 and folded_id(ar1) and folded_id(ar2))
    check("a digest scope that is not a string is refused", not pcall(fold.archive, { ar1 }, "observation", nil, nil, true))

    -- fold.release gives back the originals still waiting that are the digest's: archived into an observation (their own
    -- metadata kept), or consolidated and not archived yet — at tier 0; not one archived into a summary, not one already
    -- decided; a higher tier's is only unconsolidated. Any number of ids (one bound parameter); a failed statement says why.
    local scope39 = "repo:fold-release"
    check("fold.release of no ids: 0", fold.release({}) == 0)
    local r_obs, r_sum, r_kept = put(scope39, "a note archived into an observation"), put(scope39, "a note archived into a summary"),
        put(scope39, "a note archived and decided: kept")
    local r_t2, r_cons = put(scope39, "a tier-2 note the digest consolidated"), put(scope39, "a tier-0 note consolidated, not archived yet")
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.source', 'kept-by-release') WHERE id = ?", r_obs)
    fold.archive({ r_obs }, "observation", nil); fold.archive({ r_sum }, "summary", r_obs); fold.archive({ r_kept }, "observation", nil)
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.state', 'kept') WHERE id = ?", r_kept)
    db.run("UPDATE lm_memories SET tier = 2, consolidated_at = ? WHERE id = ?", util.now_us(), r_t2)
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), r_cons)
    local released = fold.release({ r_obs, r_sum, r_kept, r_t2, r_cons })
    check("fold.release: the one archived into an observation and the one consolidated but not archived come back; the tier-2 one is only unconsolidated; not a summary's or a decided one",
        released == 3 and not folded_id(r_obs) and not consolidated(r_obs) and not consolidated(r_cons)
        and folded_id(r_sum) and folded_id(r_kept) and not consolidated(r_t2) and tier_of(r_t2) == 2, tostring(released))
    check("… a released original keeps the rest of its own metadata",
        db.value("SELECT json_extract(metadata, '$.source') FROM lm_memories WHERE id = ?", r_obs) == "kept-by-release")
    local many = {}
    for i = 1, 9000 do many[i] = 10000000 + i end
    many[#many + 1] = r_sum
    local ok_many, n_many = pcall(fold.release, many)
    check("fold.release of 9,000 ids: one bound parameter, no limit hit", ok_many and n_many == 0, tostring(n_many))
    local rn, rwhy = H.on_sql(db, "run", "json_remove", function() return nil, "boom" end, fold.release, { r_cons })
    check("a release whose statement fails: nil and why", rn == nil and rwhy == "boom", tostring(rwhy))
end)

section("higher tiers: consolidated, never archived or reviewed", function()
    -- the rows of higher tiers the consolidation took are not the digest's to archive or the review's to delete
    local scope25 = "repo:fold-high-tiers"
    local ht2, ht3 = put(scope25, "settled memory about the vendor payment terms"), put(scope25, "core memory about the production freeze rule")
    db.run("UPDATE lm_memories SET tier = 2 WHERE id = ?", ht2); db.run("UPDATE lm_memories SET tier = 3 WHERE id = ?", ht3)
    put(scope25, "an ordinary note about the cafeteria menu")   -- (the consolidation runs when the digest has a tier-0 note to take; it takes the others with it)
    digest.run(scope25, { no_llm = true })
    check("tier-2 and tier-3 notes with a vector: consolidated (an observation holds them), still visible, no fold record",
        n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?) AND consolidated_at IS NOT NULL AND json_type(metadata, '$.lm_fold') IS NULL", ht2, ht3) == 2
        and tier_of(ht2) == 2 and tier_of(ht3) == 3)
    advance(31)
    local hr = fold.run(scope25)
    check("… and a month on the review looks only at the folded tier-0 note: the two are still there, visible and unchanged",
        hr.reviewed == 1 and n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?)", ht2, ht3) == 2 and tier_of(ht2) == 2 and tier_of(ht3) == 3
        and n("SELECT count(*) FROM lm_memories WHERE id IN (?, ?) AND json_type(metadata, '$.lm_fold') IS NULL", ht2, ht3) == 2, json.encode(hr))
end)

section("the fold record in one place: edit_sets, a forged tier, a metadata patch, an edited original on a fresh clock", function()
    -- fold.edit_sets: the clauses and their parameters (one `?` each, in order) — none for an edit that renews nothing
    local s0, p0 = fold.edit_sets({})
    local s1, p1 = fold.edit_sets({ renewed = true, max_tier = 2 })
    local s2, p2 = fold.edit_sets({ renewed = true, max_tier = 3, else_tier = 2, metadata = "{}" })
    local s3, p3 = fold.edit_sets({ metadata = "{}" })
    local function marks(sets) local c = 0; for _, s in ipairs(sets) do c = c + select(2, s:gsub("%?", "")) end; return c end
    check("fold.edit_sets: nothing for a plain edit; tier and metadata for a renewal; the record kept for a patch",
        #s0 == 0 and #p0 == 0 and #s1 == 2 and #p1 == 1 and p1[1] == 2 and #s2 == 2 and #p2 == 4 and #s3 == 1 and #p3 == 2
        and marks(s1) == #p1 and marks(s2) == #p2 and marks(s3) == #p3)

    -- an archived original whose record says a tier nobody could have had comes back at 0..3, never above
    local scope_f = "repo:fold-forged"
    local function archived(text, forged)
        local id = put(scope_f, text)
        db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), id)
        assert(fold.archive({ id }, "observation", nil) == 1)
        db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.lm_fold.tier_before', ?) WHERE id = ?", forged, id)
        return id
    end
    local f_hi, f_neg, f_txt, f_real, f_frac = archived("a plain note about the dock scheduler alpha", 99), archived("a plain note about the dock scheduler bravo", -4),
        archived("a plain note about the dock scheduler charlie", "x"), archived("a plain note about the dock scheduler delta", 3),
        archived("a plain note about the dock scheduler echo", 1.7)
    for _, id in ipairs({ f_hi, f_neg, f_txt, f_real, f_frac }) do assert(store.update(id, { body = "EDITED " .. id .. ": the dock scheduler moved to the new portal" })) end
    local function tiers(...) local out = {}; for _, id in ipairs({ ... }) do out[#out + 1] = tostring(tier_of(id)) end; return table.concat(out, " ") end
    check("an archived original edited, its record forged: back at a tier of 0..3 (99 → 3, -4 → 0, text → 1, 3 → 3, 1.7 → 1), no record",
        tiers(f_hi, f_neg, f_txt, f_real, f_frac) == "3 0 1 3 1" and not folded_id(f_hi) and not folded_id(f_neg) and not folded_id(f_txt)
        and not folded_id(f_real) and not folded_id(f_frac), tiers(f_hi, f_neg, f_txt, f_real, f_frac))
    -- a record that is no object (written through memory_write with tier 0) is a record all the same: the edit ends it
    local junk = assert(store.write({ scope = scope_f, title = "junk", body = "a note about the dock scheduler holding a record that is text",
        tier = 0, metadata = { lm_fold = "x", keep = 1 }, dedup_strategy = "append" })).id
    assert(store.update(junk, { body = "EDITED: the dock scheduler holds no record any more" }))
    check("a tier-0 note whose lm_fold is text, edited: no record, an ordinary memory's tier, the rest of its metadata kept",
        not folded_id(junk) and tier_of(junk) == 1 and db.value("SELECT json_extract(metadata, '$.keep') FROM lm_memories WHERE id = ?", junk) == 1)

    -- a core memory the summarizer folded comes back as a core memory
    local core = put(scope_f, "a core note about the dock scheduler escalation rule")
    db.run("UPDATE lm_memories SET tier = 3 WHERE id = ?", core)
    fold_into_summary(scope_f, { core }, "dock scheduler summary", "the dock scheduler escalation rule, summarized")
    check("(set up) the core note is archived, its record says tier 3", folded_id(core) and rec(core).tier_before == 3)
    assert(store.update(core, { body = "EDITED: the dock scheduler escalation rule changed" }))
    check("a core (tier 3) original that is edited comes back at tier 3, not lower", tier_of(core) == 3 and not folded_id(core))

    -- an edit that races a fold: the fold lands while the new text is embedded — the edit sees the row as the UPDATE finds it
    local race_note = put(scope_f, "a plain note about the dock scheduler race")
    db.run("UPDATE lm_memories SET tier = 1 WHERE id = ?", race_note)
    local race_sum = put(scope_f, "a summary the race note is folded into")
    local embed_mod, real_embed = require("luamemo.embed"), require("luamemo.embed").embed
    local raced = H.with(embed_mod, "embed", function(...)
        embed_mod.embed = real_embed
        fold.archive({ race_note }, "summary", race_sum)   -- (another process folds it now)
        return real_embed(...)
    end, store.update, race_note, { body = "EDITED: the dock scheduler race, new text long enough to embed" })
    check("a fold that lands while the new text is embedded: the edited note is its own again — visible, no record, unconsolidated",
        raced ~= nil and not folded_id(race_note) and tier_of(race_note) == 1 and not consolidated(race_note)
        and n("SELECT count(*) FROM lm_memories WHERE id = ? AND " .. fold.not_folded_sql(), race_note) == 1)

    -- metadata is an object: a list is refused (it would make the patch lose the record of an archived original)
    local listed = put(scope_f, "a plain note about the dock scheduler list")
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), listed)
    assert(fold.archive({ listed }, "observation", nil) == 1)
    local lres, lerr = store.update(listed, { metadata = { "x" } })
    check("a list as metadata on an update: refused, the record stays", lres == nil and tostring(lerr):find("metadata must be an object", 1, true) ~= nil
        and folded_id(listed))
    check("… on a write too", store.write({ scope = scope_f, title = "list", body = "a note with a list as metadata", metadata = { 1, 2 } }) == nil)

    -- a patch that carries a record of its own never writes it: with new text the record is gone; without, the row's own stays
    local FORGED = { into_kind = "summary", into_id = 1, review_at = 0, state = "grace", tier_before = 0, reviews = 0, folded_at = 1 }
    local fp1, fp2 = archived("a plain note about the dock scheduler forged patch one", 0), archived("a plain note about the dock scheduler forged patch two", 0)
    local own_review_at = rec(fp2).review_at
    assert(store.update(fp1, { body = "EDITED: the dock scheduler forged patch one", metadata = { lm_fold = FORGED } }))
    assert(store.update(fp2, { metadata = { lm_fold = FORGED, topic = "patched" } }))
    check("a metadata patch carrying its own lm_fold: with new text the note is its own again, no record; without, the row's own record stays",
        not folded_id(fp1) and rec(fp2) ~= nil and rec(fp2).into_kind == "observation" and rec(fp2).review_at == own_review_at
        and db.value("SELECT json_extract(metadata, '$.topic') FROM lm_memories WHERE id = ?", fp2) == "patched")

    -- a metadata patch (no new text) on an archived original keeps its fold record; with new text it is its own again and
    -- the patch is the metadata it has
    local scope_m = "repo:fold-metadata-patch"
    local mp1, mp2 = put(scope_m, "a plain note about the loading dock keys"), put(scope_m, "a plain note about the loading dock lights")
    for _, id in ipairs({ mp1, mp2 }) do
        db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), id)
        assert(fold.archive({ id }, "observation", nil) == 1)
    end
    -- (the stamps as the row holds them: integers of microseconds, which a round trip through a Lua number and JSON rounds)
    local STAMPS = "SELECT typeof(json_extract(metadata, '$.lm_fold.folded_at')) || ' ' || json_extract(metadata, '$.lm_fold.folded_at') || ' ' || "
        .. "json_extract(metadata, '$.lm_fold.review_at') FROM lm_memories WHERE id = ?"
    local stamps_before = db.value(STAMPS, mp1)
    assert(store.update(mp1, { metadata = { topic = "dock" } }))
    local after = rec(mp1)
    check("a metadata patch on an archived original: it stays archived — the same record, the patch's keys, still tier 0 and consolidated",
        after ~= nil and after.into_kind == "observation" and db.value("SELECT json_extract(metadata, '$.topic') FROM lm_memories WHERE id = ?", mp1) == "dock"
        and tier_of(mp1) == 0 and consolidated(mp1), json.encode(after))
    check("… and its stamps are exactly what they were: integers, not rounded",
        stamps_before:find("^integer ") ~= nil and db.value(STAMPS, mp1) == stamps_before, tostring(stamps_before) .. " → " .. tostring(db.value(STAMPS, mp1)))
    assert(store.update(mp2, { body = "EDITED: the loading dock lights are on a timer now", metadata = { topic = "lights" } }))
    check("new text with a metadata patch: its own memory again — no record, the patch is its metadata, unconsolidated",
        not folded_id(mp2) and db.value("SELECT json_extract(metadata, '$.topic') FROM lm_memories WHERE id = ?", mp2) == "lights"
        and not consolidated(mp2) and tier_of(mp2) == 0)

    -- an original that is edited, taken by the digest again and reviewed a month on its OLD clock would have been decided
    -- at once: its new record starts at the day it was archived again
    local scope_r = "repo:fold-reowned"
    local TEXT_R = "a plain note about the fire drill assembly points"
    local ro1, ro2 = put(scope_r, TEXT_R), put(scope_r, TEXT_R)
    digest.run(scope_r, { no_llm = true })
    check("(set up) both notes archived", folded_id(ro1) and folded_id(ro2))
    advance(31)
    assert(store.update(ro1, { body = "EDITED: the fire drill assembly point is the north car park" }))
    digest.run(scope_r, { no_llm = true })
    local fresh = rec(ro1)
    check("an edited original archived again: its record is new — today's day, a full grace, no reviews",
        fresh ~= nil and fresh.folded_at == util.now_us() and fresh.review_at - fresh.folded_at == 30 * DAY and fresh.reviews == 0, json.encode(fresh))
    local rr = fold.run(scope_r)
    check("… and a review right away leaves it alone (it is not due for a month)",
        row(ro1) ~= nil and rec(ro1) ~= nil and rec(ro1).reviews == 0 and rec(ro1).state ~= "kept", json.encode(rr))
end)

section("fold.release: scoped, atomic inside a transaction, a real id among thousands", function()
    local sa, sb = "repo:fold-release-a", "repo:fold-release-b"
    local function waiting(sc, text, tier)
        local id = put(sc, text)
        if tier then db.run("UPDATE lm_memories SET tier = ? WHERE id = ?", tier, id) end
        db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id = ?", util.now_us(), id)
        if not tier then assert(fold.archive({ id }, "observation", nil) == 1) end
        return id
    end
    local a_raw, b_raw, a_t2, b_t2 = waiting(sa, "a note of scope a, archived"), waiting(sb, "a note of scope b, archived"),
        waiting(sa, "a tier-2 note of scope a", 2), waiting(sb, "a tier-2 note of scope b", 2)
    check("fold.release of ids of two scopes, asked for scope a: only scope a's come back (the archived one and the tier-2 one)",
        fold.release({ a_raw, b_raw, a_t2, b_t2 }, sa) == 2 and not folded_id(a_raw) and not consolidated(a_raw) and not consolidated(a_t2)
        and folded_id(b_raw) and consolidated(b_raw) and consolidated(b_t2))
    check("… without a scope, the others come back too", fold.release({ b_raw, b_t2 }) == 2 and not folded_id(b_raw) and not consolidated(b_t2))

    -- two statements: a failure of the second inside a transaction undoes the first
    local c_raw, c_t2 = waiting(sa, "a second note of scope a, archived"), waiting(sa, "a second tier-2 note of scope a", 2)
    local tx_ok, tx_err = db.transaction(function()
        local count, why = fold.release({ c_raw, c_t2 }, sa)
        if not count then error(why, 0) end
    end)
    check("sanity: a release inside a transaction commits with it", tx_ok and not folded_id(c_raw) and not consolidated(c_t2), tostring(tx_err))
    local d_raw, d_t2 = waiting(sa, "a third note of scope a, archived"), waiting(sa, "a third tier-2 note of scope a", 2)
    local fail_ok = H.on_sql(db, "run", "AND tier >= 1 AND consolidated_at IS NOT NULL", function() return nil, "boom" end, function()
        return db.transaction(function()
            local count, why = fold.release({ d_raw, d_t2 }, sa)
            if not count then error(why, 0) end
        end)
    end)
    check("the second statement fails inside a transaction: the first is undone too — the archived note is still archived",
        fail_ok == nil and folded_id(d_raw) and consolidated(d_raw) and consolidated(d_t2),
        ("%s %s %s %s"):format(tostring(fail_ok), tostring(folded_id(d_raw)), tostring(consolidated(d_raw)), tostring(consolidated(d_t2))))
    local second_n, second_why = H.on_sql(db, "run", "AND tier >= 1 AND consolidated_at IS NOT NULL", function() return nil, "boom" end, fold.release, { d_t2 }, sa)
    check("… outside a transaction: nil and why", second_n == nil and second_why == "boom", tostring(second_why))

    -- a real id among thousands of others: found
    local many = {}
    for i = 1, 9000 do many[i] = 20000000 + i end
    many[#many + 1] = d_t2
    many[#many + 1] = d_raw
    check("fold.release of 9,000 ids and two real ones: both come back", fold.release(many, sa) == 2 and not consolidated(d_t2) and not folded_id(d_raw))

    -- … and the store passes the observation's own scope: an observation's evidence keeps the id of a note the review deleted,
    -- an id the next note written takes — of any scope. Deleting a member must not give back that other scope's note.
    local st_a, st_b = "repo:fold-release-store-a", "repo:fold-release-store-b"
    local held_a = put(st_a, "a note of scope a, held by an observation")
    local foreign = waiting(st_b, "an archived note of scope b whose id is in scope a's evidence")
    observe(st_a, "an observation of scope a", { held_a, foreign })
    assert(store.delete(held_a))
    check("store.delete of a member: the observation goes; a note of another scope its evidence names stays archived and consolidated",
        obs_count(st_a) == 0 and folded_id(foreign) and consolidated(foreign))
    -- … without a scope (delete_where by kind) the observations of every scope go, each giving back its own scope's notes
    local ws_a, ws_b = "repo:fold-release-where-a", "repo:fold-release-where-b"
    local wa, wb = put(ws_a, "a note of scope a to be deleted by kind"), put(ws_b, "a note of scope b to be deleted by kind")
    db.run("UPDATE lm_memories SET kind = 'round21kind' WHERE id IN (?, ?)", wa, wb)
    local wa_kin, wb_kin = waiting(ws_a, "an archived note of scope a"), waiting(ws_b, "an archived note of scope b")
    observe(ws_a, "an observation of scope a", { wa, wa_kin, wb_kin })   -- (wb_kin: an id of scope b in scope a's evidence)
    observe(ws_b, "an observation of scope b", { wb })
    -- (an unscoped read looks at every observation: the one an earlier test of this file left with evidence that is no JSON
    -- would make it fail — a scoped delete never reaches it)
    db.run("DELETE FROM lm_observations WHERE evidence_ids = 'not json'")
    assert(store.delete_where({ kind = "round21kind" }) == 2)
    check("store.delete_where with no scope: both observations go; scope a's archived note comes back, scope b's — named only by a's evidence — stays",
        obs_count(ws_a) + obs_count(ws_b) == 0 and not folded_id(wa_kin) and not consolidated(wa_kin)
        and folded_id(wb_kin) and consolidated(wb_kin))
end)

section("a stale cluster costs no summarizer call; a cluster that cannot be checked is an error", function()
    local function summarizing(name, stub, fn)
        package.loaded["luamemo.summarizers." .. name] = stub
        local with = {}
        for k, v in pairs(luamemo.config) do with[k] = v end
        with.summarizer_adapter = name
        consolidate.configure(with)
        local ok, res = pcall(fn)
        conf()
        if not ok then error(res, 0) end
        return res
    end
    -- two clusters; while the first is summarized one note of the other is rewritten: the other waits, and no call is
    -- made for it
    local scope_s = "repo:fold-stale-cluster"
    local TA, TB = "a plain note about the roof drain inspection", "a plain note about the cold room door seal"
    local ids = { put(scope_s, TA), put(scope_s, TA), put(scope_s, TB), put(scope_s, TB) }
    local calls = 0
    local sr = summarizing("teststale", { summarize = function(cluster)
        calls = calls + 1
        if calls == 1 then
            local inside = {}
            for _, m in ipairs(cluster) do inside[tonumber(m.id)] = true end
            for _, id in ipairs(ids) do
                if not inside[id] then assert(store.update(id, { body = "EDITED: " .. id .. " the inspection moved to the autumn" })); break end
            end
        end
        return { title = "", body = cluster[1].body }
    end }, function() return consolidate.process(scope_s) end)
    check("the other cluster changed while the first was summarized: one call, one observation, no error; its notes wait",
        calls == 1 and sr.synthesised == 1 and #sr.errors == 0 and obs_count(scope_s) == 1
        and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND consolidated_at IS NULL", scope_s) == 2, json.encode(sr) .. " calls=" .. calls)

    -- a read that fails while the cluster is checked is an error with its cause, not a quiet "changed"
    local scope_e = "repo:fold-uncheckable"
    local e1, e2 = put(scope_e, "a plain note about the badge reader firmware"), put(scope_e, "a plain note about the badge reader firmware")
    local er = H.on_sql(db, "value", "SELECT count(*) FROM lm_memories WHERE scope = ? AND consolidated_at IS NULL", function() return nil, "boom" end,
        consolidate.process, scope_e, { no_llm = true })
    check("a failed check of the cluster: 'could not check the cluster: boom', no observation, the notes wait",
        #er.errors == 1 and tostring(er.errors[1]):find("could not check the cluster: boom", 1, true) and er.synthesised == 0
        and obs_count(scope_e) == 0 and not consolidated(e1) and not consolidated(e2), json.encode(er))
end)

section("the reinforce path: a failed mark undone, a cluster changed since it was read, quotes in step with the evidence", function()
    -- a mark that fails takes the reinforcement with it: proof and evidence as they were, counted once at the next run
    local scope_a = "repo:fold-reinforce-rollback"
    observe(scope_a, BASE, {})
    local ja = put(scope_a, BASE)
    local jr = H.on_sql(db, "run", "SET consolidated_at = ? WHERE id IN (SELECT value", function() return nil, "boom" end,
        consolidate.process, scope_a, { no_llm = true })
    check("a reinforcement whose mark fails: an error, the proof and the evidence as they were, the note not consolidated",
        jr.reinforced == 0 and #jr.errors == 1 and tostring(jr.errors[1]):find("mark consolidated", 1, true)
        and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope_a) == 1
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope_a) == 0 and not consolidated(ja), json.encode(jr))
    local jr2 = consolidate.process(scope_a, { no_llm = true })
    check("… the next run counts the note once: proof 2, one id of evidence, the note consolidated",
        jr2.reinforced == 1 and #jr2.errors == 0 and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope_a) == 2
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope_a) == 1 and consolidated(ja), json.encode(jr2))

    -- a note rewritten between the read and the write of a cluster that reinforces: the observation is not touched
    local scope_b = "repo:fold-reinforce-changed"
    observe(scope_b, BASE, {})
    local jb = put(scope_b, BASE)
    local done = false
    local br = H.on_sql(db, "query", "IS NOT NULL ORDER BY id", function(real, sql, ...)
        local rows, err = real(sql, ...)
        if not done then done = true; assert(store.update(jb, { body = "EDITED: the quarterly review moved to the annex" })) end
        return rows, err
    end, consolidate.process, scope_b, { no_llm = true })
    check("a note rewritten while its cluster reinforces: the observation is untouched (proof 1, no evidence), the note waits, no error",
        done and br.reinforced == 0 and #br.errors == 0 and n("SELECT proof_count FROM lm_observations WHERE scope = ?", scope_b) == 1
        and n("SELECT json_array_length(evidence_ids) FROM lm_observations WHERE scope = ?", scope_b) == 0 and not consolidated(jb), json.encode(br))

    -- an observation that holds one of three notes already: the other two are added, with THEIR quotes (in step with the ids)
    local scope_c = "repo:fold-reinforce-quotes"
    observe(scope_c, BASE, {})
    local words = { "alpha", "bravo", "charlie" }
    local qids = {}
    for i, w in ipairs(words) do qids[i] = put(scope_c, w .. " " .. BASE) end
    db.run("UPDATE lm_observations SET evidence_ids = ?, evidence_quotes = ?, proof_count = 1 WHERE scope = ?",
        db.json({ qids[1] }), db.json({ "alpha quote kept" }), scope_c)
    local qr = consolidate.process(scope_c, { no_llm = true })
    local qobs = db.first("SELECT proof_count, evidence_ids, evidence_quotes FROM lm_observations WHERE scope = ?", scope_c)
    local ev, qs = qobs.evidence_ids, qobs.evidence_quotes
    local aligned = #ev == 3 and #qs == 3 and qs[1] == "alpha quote kept"
    for i = 2, #ev do
        local at
        for k, id in ipairs(qids) do if id == tonumber(ev[i]) then at = k end end
        aligned = aligned and at ~= nil and tostring(qs[i]):find("^" .. words[at] .. " ") ~= nil
    end
    check("an observation that already holds one of three notes: proof 3, three ids, three quotes — each added quote belongs to its id",
        qr.reinforced == 1 and tonumber(qobs.proof_count) == 3 and aligned, json.encode(qobs))
end)

section("an update that cannot retire what was made from a memory says so", function()
    local function failing(sql_fragment, fn, ...) return H.failing_sql("run", sql_fragment, fn, ...) end
    -- a visible note with an observation behind it and two archived copies
    local TEXT_W = "a plain note about the print room paper stock"
    local function trio(sc)
        local a, b, v = put(sc, TEXT_W), put(sc, TEXT_W), put(sc, TEXT_W, 0.5)
        events(v, sc, "mistake", 2)
        digest.run(sc, { no_llm = true })
        assert(tier_of(v) >= 1 and folded_id(a) and folded_id(b) and obs_count(sc) == 1, "set-up of the trio")
        return a, b, v
    end
    local sc_u = "repo:fold-update-warning"
    local ua, ub, uv = trio(sc_u)
    local ur, ulines = failing("json_remove", store.update, uv, { body = "EDITED: the print room paper now comes from the new supplier" })
    check("an update whose observations cannot be retired: the edit is made, the answer carries a warning, stderr a line, the archived notes keep their holder",
        ur and ur.warning and tostring(ur.warning):find("could not be removed", 1, true) and tostring(ur.warning):find("boom", 1, true)
        and db.value("SELECT body FROM lm_memories WHERE id = ?", uv):find("^EDITED") and tostring(ulines[1]):find("[luamemo]", 1, true)
        and obs_count(sc_u) == 1 and folded_id(ua) and folded_id(ub), json.encode(ur))
    local ok_row = assert(store.update(uv, { importance = 4 }))
    check("(control) an update that retires nothing: no warning", ok_row.warning == nil)

    -- a move without new text carries a note's companions along; one that cannot be carried is said
    local sc_from, sc_to = "repo:fold-carry-from", "repo:fold-carry-to"
    local parent = put(sc_from, "a plain note about the cafeteria tray return")
    local comp = put(sc_from, "User has mentioned the cafeteria tray return")
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.is_synthetic', json('true'), '$.source_id', ?) WHERE id = ?", parent, comp)
    local cr, clines = failing("SET scope = ?, consolidated_at = NULL WHERE scope = ?", store.update, parent, { scope = sc_to })
    check("a move whose companions cannot be carried: the note is moved, the answer carries a warning, stderr a line",
        cr and db.value("SELECT scope FROM lm_memories WHERE id = ?", parent) == sc_to
        and tostring(cr.warning):find("companions could not be moved (boom)", 1, true) and tostring(clines[1]):find("[luamemo]", 1, true), json.encode(cr))
    -- … both causes at once (observations that cannot be retired, companions that cannot be carried): one warning with both,
    -- joined by "; ", and a stderr line for each
    local sc_j_from, sc_j_to = "repo:fold-joined-from", "repo:fold-joined-to"
    local ja, jb, jv = trio(sc_j_from)
    local jc = put(sc_j_from, "User has mentioned the print room paper stock")
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.is_synthetic', json('true'), '$.source_id', ?) WHERE id = ?", jv, jc)
    local joined_lines
    local jr = failing("SET scope = ?, consolidated_at = NULL WHERE scope = ?", function()
        local row, lines = failing("json_remove", store.update, jv, { scope = sc_j_to })
        joined_lines = lines
        return row
    end)
    check("observations and companions both fail on a move: one warning with both causes, joined by '; ', and two stderr lines",
        jr and db.value("SELECT scope FROM lm_memories WHERE id = ?", jv) == sc_j_to
        and tostring(jr.warning):find("could not be removed", 1, true) and tostring(jr.warning):find("; its companions could not be moved", 1, true)
        and #joined_lines == 2 and folded_id(ja) and folded_id(jb), json.encode(jr))
    local parent2 = put(sc_from, "a plain note about the cafeteria napkin dispenser")
    local comp2 = put(sc_from, "User has mentioned the cafeteria napkin dispenser")
    db.run("UPDATE lm_memories SET metadata = json_set(metadata, '$.is_synthetic', json('true'), '$.source_id', ?) WHERE id = ?", parent2, comp2)
    local cr2 = assert(store.update(parent2, { scope = sc_to }))
    check("(control) companions carried: no warning, the companion in the new scope",
        cr2.warning == nil and db.value("SELECT scope FROM lm_memories WHERE id = ?", comp2) == sc_to)
end)

util.now_us = real_now
finish()
