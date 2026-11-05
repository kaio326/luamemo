-- luamemo.fold
--
-- The life of a memory that has been folded into something shorter — a summary (memory_summarize, consolidate's
-- merge) or an observation (the digest). Folding used to delete it: the summarizer at once, the digest after a
-- week. A summary keeps a quarter or less of the concrete tokens of what it replaces (eval/summarizer_bench.lua),
-- and deleting a memory also deletes the record of whether it was ever useful (its reinforcements and the searches
-- that offered it go with it). So now:
--
--   archive   the original stays in lm_memories, hidden: tier 0, consolidated_at set, and in its metadata
--             lm_fold = { into_kind, into_id, folded_at, review_at, reviews, tier_before, state }. Every search, the
--             brief and every maintenance pass skip a row that has lm_fold.
--   grace     MEMO_FOLD_GRACE_DAYS (30), or MEMO_DIGEST_GRACE_DAYS for raw conversation the digest folded into an
--             observation. Nothing happens.
--   review    at review_at, in the background (memo maintain), per original, against what replaced it:
--               target gone                                  → restore it (it is the only copy) — except raw
--                                                              conversation the digest folded into an
--                                                              observation that no longer holds it: deleted
--                                                              unless it was ever useful (a memory folded
--                                                              into a SUMMARY is always restored)
--               the summary was marked wrong since folding   → correct
--               the original was useful and the summary
--                 kept less than MEMO_FOLD_MIN_COVERAGE of its
--                 concrete tokens                            → correct
--               otherwise                                    → delete (recorded first in <database>.maintenance.log)
--   correct   the facts the summary lost are added to it (the original's sentences that hold the missing tokens —
--             no model, nothing invented), it is re-embedded, and the original goes back to grace with
--             reviews + 1. Past MEMO_FOLD_MAX_REVIEWS it is restored instead (raw conversation rows, which were
--             hidden to begin with, stay hidden as `kept`), never deleted. A correction that cannot be made (nothing
--             to add, no room left in the summary, its update or the re-embedding fails) restores the original instead,
--             the same way — and so does the dry run say. A summary marked wrong stays marked: at
--             its next review nothing is left to add, and the original is restored — such a summary never stands in
--             for its source.
--   release   an observation that goes away with one of its memories (deleted, given new text, moved to another scope)
--             gives back the originals of the cluster it held that are still waiting — archived, or consolidated and
--             not archived yet: shown again and unconsolidated, so the next digest makes an observation of them again
--             (else their review would delete them as memories nothing holds); a member of a higher tier is only
--             unconsolidated, so its observation and its proof are made again.
--   own again an archived original that is itself edited or moved (edit_sets) is its own memory again: its record goes, it is shown
--             at the tier it had before it was folded, unconsolidated (not reviewed on its old clock in its new place);
--             a metadata patch alone keeps its record. Decided in the UPDATE, on the row as it is then.
--
-- Rows a digest consolidated before folds were recorded (tier 0, consolidated, no lm_fold) are reviewed too, as raw
-- conversation folded into an observation, MEMO_DIGEST_GRACE_DAYS after they were consolidated. A review never guesses:
-- what it cannot look up (a failed query) it leaves as it is and reports; "the summary" is a summary of the same scope
-- that already existed when the original was folded into it (an id is reused once its newest row is deleted) and still
-- stands (one folded into a newer summary is waiting to be deleted itself), and a record with no readable date counts as
-- gone — the original is given back; and every
-- write it makes re-checks that the original is still waiting, as it was decided about (`memory_digest` reviews without
-- the maintenance lock).
--
-- "Useful": praise or a direct command on it, or offered by MEMO_FOLD_USEFUL_OFFERS searches (needs the usage log,
-- MEMO_FEEDBACK_ENABLED; with it off nothing shows a memory useful). Only the searches still in the log count, so
-- MEMO_FEEDBACK_RETENTION_DAYS should stay above the longer of MEMO_FOLD_GRACE_DAYS and MEMO_DIGEST_GRACE_DAYS
-- (memo doctor says when it does not).

local db       = require("luamemo.db")
local util     = require("luamemo.util")
local json     = require("luamemo.json")
local vectors  = require("luamemo.vectors")
local policy   = require("luamemo.federation.policy")
local settings = require("luamemo.settings")
local feedback = require("luamemo.feedback")

local M = {}

local cfg = {}
function M.configure(c) cfg = c or {} end

local DAY_US = util.DAY_US
local BODY_ROOM = 3900          -- a memory's body is capped at 4 KB: how much a summary may grow to
local ADD_PER_ORIGINAL = 500    -- characters of one original's missing facts added to a summary

local function num(key) return settings.number(cfg, key) end   -- (the config's, else the setting's own default)
local function grace_us(into_kind)
    local days = num(into_kind == "observation" and "digest_grace_days" or "fold_grace_days")
    return math.max(0, days) * DAY_US
end

-- ── SQL: where an original is in its life ────────────────────────────────────

--- The row is not an archived original. An archived original is tier 0, so a row at tier 1 or more never has its
--- metadata read — the usual search pays almost nothing for this. `prefix` is the table alias with its dot, or "".
function M.not_folded_sql(prefix)
    prefix = prefix or ""
    return ("(%stier >= 1 OR json_type(%smetadata, '$.lm_fold') IS NULL)"):format(prefix, prefix)
end

-- An original that is folded and has not been decided yet: tier 0, consolidated, and its lm_fold state (a row from
-- before folds were recorded has none) is still 'grace'. The review's scan and the guard of every write it makes are
-- both built from these two, so they cannot disagree about what "waiting" is.
local TIER0_FOLDED = "tier = 0 AND consolidated_at IS NOT NULL"
local STATE_GRACE  = "COALESCE(json_extract(metadata, '$.lm_fold.state'), 'grace') = 'grace'"

-- An archived original whose review is due (one `?`: now, in microseconds).
local DUE_SQL = "(json_type(metadata, '$.lm_fold') IS NOT NULL AND " .. STATE_GRACE
    .. " AND json_extract(metadata, '$.lm_fold.review_at') <= ?)"

-- An original that is waiting for its review: reviews run in more than one process (`memo maintain` holds a lock, a
-- `memory_digest` call does not), so every change a review makes re-checks that nobody got there first — that the row
-- is still waiting AND still the one that was decided about (not folded again since: consolidated_at; not corrected by
-- another run since: reviews). `pin(row, rec)` gives the two values, in the order PINNED_SQL takes them.
local WAITING_SQL = TIER0_FOLDED .. " AND " .. STATE_GRACE
local PINNED_SQL  = WAITING_SQL .. " AND consolidated_at IS ? AND COALESCE(json_extract(metadata, '$.lm_fold.reviews'), 0) = ?"
-- What makes an original not folded any more (the restore of a review, a release, an edit): not consolidated, no lm_fold
-- record (the rest of its metadata is its own)
local UNFOLD_SET  = "consolidated_at = NULL, metadata = json_remove(COALESCE(NULLIF(metadata, ''), '{}'), '$.lm_fold')"

-- (an id — a row's, a target's, or the record's into_id — as an integer, and the record's count of reviews as a number
-- (0 when it is none): the record is metadata a writer could set. as_id of nothing raises; the caller checks first)
local function as_id(v) return math.floor(tonumber(v)) end
local function row_id(row) return as_id(row.id) end
local function reviews_of(rec) return tonumber(rec.reviews) or 0 end
local function pin(row, rec) return row.consolidated_at, reviews_of(rec) end

--- The originals whose review is due, as a WHERE clause (the one definition: the review itself and the scan that
--- decides whether to start one both use it): the archived ones past their grace, and the tier-0 rows a digest
--- consolidated before folds were recorded (folded_at = consolidated_at), minus what no maintenance may touch.
--- → clause, then the two parameters it takes, in order (`now` and the cutoff for the older rows), in microseconds.
function M.due_clause(now)
    return "(" .. TIER0_FOLDED .. " AND (" .. DUE_SQL
        .. " OR (json_type(metadata, '$.lm_fold') IS NULL AND consolidated_at <= ?))" .. policy.and_exclusion() .. ")",
        now, now - grace_us("observation")
end

-- ── what a text holds that a summary should keep ─────────────────────────────

--- The salient tokens of a text, as a set: numbers, identifiers with an underscore or a dot, file names,
--- camelCase, ALLCAPS (three letters or more).
function M.salient(text)
    local set = {}
    for w in tostring(text or ""):gmatch("[%w_%.%-/]+") do
        w = w:gsub("^[%.%-/]+", ""):gsub("[%.%-/]+$", "")
        if #w >= 3 then
            local keep = w:find("%d") or w:find("_") or (w:find("%.") and w:find("%a")) or w:find("%l%u") or w:match("^%u%u%u+$")
            if keep then set[w:lower()] = true end
        end
    end
    return set
end

--- The share of the original's salient tokens the target keeps → 0..1 (1 when it has none to lose), and the
--- missing ones (a list).
function M.coverage(original, target)
    local have, missing, n, kept = M.salient(target), {}, 0, 0
    for tok in pairs(M.salient(original)) do
        n = n + 1
        if have[tok] then kept = kept + 1 else missing[#missing + 1] = tok end
    end
    table.sort(missing)
    return n > 0 and kept / n or 1, missing
end

-- ── the decision (pure) ──────────────────────────────────────────────────────

--- ev = { target_missing, raw (the original is conversation that was never a memory), target_flawed, useful,
---        coverage, reviews, max_reviews, min_coverage } → "delete" | "correct" | "restore", reason
function M.decide(ev)
    if ev.target_missing then
        -- raw conversation with no observation that holds it: kept only if it ever helped; a summarized memory
        -- whose summary is gone is the only copy left
        if ev.raw then return (ev.useful and "restore" or "delete"), "no observation holds it" end
        return "restore", "the summary is gone"
    end
    local why
    if ev.target_flawed then why = "the summary was marked wrong"
    elseif ev.useful and ev.coverage < ev.min_coverage then why = "useful, and the summary kept only part of its facts" end
    if why then
        if ev.reviews >= ev.max_reviews then return "restore", why .. "; corrected " .. ev.reviews .. " times already" end
        return "correct", why
    end
    return "delete", ev.useful and "its facts are in the summary" or "not shown useful"
end

-- ── archive ──────────────────────────────────────────────────────────────────

--- Hide the folded originals instead of deleting them → how many | nil, err (the statement failed: nothing was
--- archived). A row that is already folded is left as it is — its record (tier_before, where it went, its grace) is
--- not written over by a second run that picked the same notes. into_kind "summary" | "observation"; into_id the
--- memory (nil for an observation: the review finds it by its evidence). cap: the federation capability. digest_scope:
--- the digest's mode — hide a row only if it is still what the digest read and consolidated: at tier 0 (not what was
--- promoted since — by its own escalation of a mistake, or by a write that merged into it), in that scope (not moved),
--- and consolidated (a rewrite while the consolidation ran clears it: the new text has not been made into an
--- observation, and the review would delete the note as one nothing holds). A row left as it is is taken by the next run.
function M.archive(ids, into_kind, into_id, cap, digest_scope)
    assert(digest_scope == nil or type(digest_scope) == "string", "fold.archive: digest_scope is a scope (a string) or nil")
    local clean = util.ints(ids)
    if #clean == 0 then return 0 end
    local now = util.now_us()
    local params = { now, into_kind, into_id, now, now + grace_us(into_kind) }
    for _, id in ipairs(clean) do params[#params + 1] = id end
    if digest_scope then params[#params + 1] = digest_scope end
    -- (every expression of an UPDATE reads the row as it was: tier_before is the tier it had)
    local n, err = db.run("UPDATE lm_memories SET consolidated_at = ?, metadata = json_set(COALESCE(NULLIF(metadata, ''), '{}'), "
        .. "'$.lm_fold', json_object('into_kind', ?, 'into_id', ?, 'folded_at', ?, 'review_at', ?, 'reviews', 0, "
        .. "'tier_before', tier)), tier = 0 WHERE id IN (" .. db.placeholders(#clean) .. ") AND " .. M.not_folded_sql()
        .. (digest_scope and (" AND " .. TIER0_FOLDED .. " AND scope = ?") or "") .. policy.and_exclusion(cap),
        unpack(params, 1, #params))
    if n == nil then return nil, err end
    return n
end

--- Give back the originals of an observation that is going away (it is deleted, or given new text, or moved, with the
--- memory it was made from): those still waiting — archived into an observation, or consolidated by the digest and not
--- archived yet (tier 0) — are shown again and not consolidated, so the next digest makes an observation from them again;
--- else the review would delete them as memories nothing holds. One already decided ("kept") stays decided and one
--- archived into a summary is the summary's. A memory of a higher tier (a search consolidates those too, and the digest
--- takes them with a cluster) is not hidden — it is only unconsolidated, so the next consolidation makes an observation
--- of it again and its proof counts again. `ids`: any number (one bound parameter); `scope`: only the memories of that
--- scope (an observation's evidence keeps the id of a memory the review deleted, and an id is reused by the next memory
--- written — in any scope). → how many | nil, why. Two statements: call it inside a db.transaction, as the store does
--- (a `nil, why` from the second leaves the first applied otherwise).
function M.release(ids, scope)
    local clean = util.ints(ids)
    if #clean == 0 then return 0 end
    local in_ids, ids_json = db.in_list(clean)
    local in_scope = scope and " AND scope = ?" or ""
    local args = scope and { ids_json, scope } or { ids_json }   -- (both statements bind the same)
    local n, err = db.run("UPDATE lm_memories SET " .. UNFOLD_SET .. " WHERE id IN " .. in_ids .. in_scope .. " AND " .. WAITING_SQL
        .. " AND COALESCE(json_extract(metadata, '$.lm_fold.into_kind'), 'observation') = 'observation'", unpack(args))
    if n == nil then return nil, err end
    local n2, err2 = db.run("UPDATE lm_memories SET consolidated_at = NULL WHERE id IN " .. in_ids .. in_scope
        .. " AND tier >= 1 AND consolidated_at IS NOT NULL", unpack(args))
    if n2 == nil then return nil, err2 end
    return n + n2
end

-- ── the log ──────────────────────────────────────────────────────────────────

local LOG_CAP = 1024 * 1024
--- The database's own log, <database file>.maintenance.log. (One per database: the data directory holds every
--- project's, and what one run did is not another's.)
function M.log_path()
    return db.sibling(".maintenance.log")
end

local private = {}   -- the log paths this process has checked: true = made private, false = refused (a symlink)
M._private = private   -- (tests)

--- Append one JSON line to the log (rotated at 1 MB; created private, 0600, like the database — it names the
--- memories a review deleted) → true when the line was written | false (never raises). A review writes the line
--- before it deletes anything and does not delete without it.
function M.log(entry)
    local ok, wrote = pcall(function()
        local path = M.log_path()
        if private[path] == nil then
            -- once per process: the append and the chmod would follow a symlink planted at the log's name (a shared
            -- directory), and a log from before it was made private keeps the mode it was created with
            if util.is_symlink(path) or util.is_symlink(path .. ".1") then
                private[path] = false   -- (refused for good: not looked at again by every line a run writes)
            else
                os.execute("chmod 600 " .. util.shell_quote(path) .. " " .. util.shell_quote(path .. ".1") .. " 2>/dev/null")
                private[path] = true
            end
        end
        if not private[path] then return false end
        local f = io.open(path, "rb")
        if f then
            local size = f:seek("end"); f:close()
            if size and size > LOG_CAP then os.rename(path, path .. ".1") end
        end
        entry.at = entry.at or os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(util.now_us() / 1000000))
        local out = util.with_umask("077", io.open, path, "ab")
        if not out then return false end
        local written = out:write(json.encode(entry), "\n")
        return out:close() and written ~= nil
    end)
    return ok and wrote == true
end

-- ── review ───────────────────────────────────────────────────────────────────

--- What the original was folded into → the target { kind, id, text, body } | nil (it is gone) | nil, err (the lookup
--- failed: nothing is known, and a review must not take a failed query for a summary that is gone).
local function target_of(row, rec)
    local t, err
    if rec.into_kind == "summary" then
        -- (the record is metadata a writer could set, and an id is reused once its newest row is deleted: the summary
        -- has to be a SUMMARY of the same scope that already existed when the original was folded into it, and still
        -- stand — one that was itself folded into a newer summary is waiting to be reviewed and deleted — or it is gone;
        -- a record with no usable date cannot be checked, so it counts as gone: the original is given back)
        local into = tonumber(rec.into_id)
        if not into then return nil end
        t, err = db.first("SELECT id, title, body FROM lm_memories WHERE id = ? AND scope = ? AND kind = 'summary' "
            .. "AND created_at <= ? AND " .. M.not_folded_sql(), as_id(into), row.scope, tonumber(rec.folded_at) or 0)
        if err then return nil, err end
        if t then return { kind = "summary", id = t.id, text = (t.title or "") .. " " .. (t.body or ""), body = t.body or "" } end
        return nil
    end
    t, err = db.first("SELECT id, body FROM lm_observations WHERE scope = ? AND EXISTS (SELECT 1 FROM json_each(evidence_ids) "
        .. "WHERE CAST(value AS INTEGER) = ?) ORDER BY proof_count DESC LIMIT 1", row.scope, row_id(row))
    if err then return nil, err end
    if t then return { kind = "observation", id = t.id, text = t.body or "", body = t.body or "" } end
    return nil
end

-- (a failed query is an error, never a zero: "never praised" and "could not ask" must not look alike)
local function count(sql, ...)
    local v, err = db.value(sql, ...)
    if err then error("query failed: " .. tostring(err), 0) end
    return tonumber(v) or 0
end

-- How many reinforcements of one kind a memory has (list_sql: feedback.POSITIVE_SQL / NEGATIVE_SQL), since a time (µs).
local function reinforcements(memory_id, list_sql, since)
    return count("SELECT count(*) FROM lm_reinforcements WHERE memory_id = ? AND event_type IN " .. list_sql
        .. " AND created_at >= ?", memory_id, since or 0)
end

local function evidence(row, rec, target)
    local id = row_id(row)
    local need = num("fold_useful_offers")
    local ev = {
        praise  = reinforcements(id, feedback.POSITIVE_SQL),
        -- (only whether it reached the number of offers matters: count no further)
        offered = count("SELECT count(*) FROM (SELECT 1 FROM lm_retrieval_candidates WHERE memory_id = ? LIMIT ?)", id, need),
        wrong   = reinforcements(id, feedback.NEGATIVE_SQL),
    }
    ev.useful = ev.praise > 0 or ev.offered >= need
    if target and target.kind == "summary" then   -- the summary was marked wrong since this memory was folded into it
        ev.target_flawed = reinforcements(as_id(target.id), feedback.NEGATIVE_SQL, tonumber(rec.folded_at)) > 0
    end
    return ev
end

-- A text's sentences: ended by . ! ? followed by a space, or by a line break (a dot inside cache.lua is not an end).
local function sentences(text)
    text = tostring(text or ""):gsub("\n+", ". ") .. " "
    local out, i = {}, 1
    while i <= #text do
        local a, b = text:find("[%.!?]%s", i)
        local s = a and text:sub(i, a - 1) or text:sub(i)
        i = b and (b + 1) or (#text + 1)
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 0 then out[#out + 1] = s end
    end
    return out
end
M._sentences = sentences   -- (tests)

-- The original's sentences that hold what the target lost, capped.
local function missing_facts(original_body, missing)
    local want = {}
    for _, t in ipairs(missing) do want[t] = true end
    local out, used = {}, 0
    for _, s in ipairs(sentences(original_body)) do
        local wanted = false
        for tok in pairs(M.salient(s)) do if want[tok] then wanted = true; break end end
        if wanted and used + #s <= ADD_PER_ORIGINAL then out[#out + 1] = s; used = used + #s + 1 end
    end
    -- a body with no sentence stops (one long run): its missing tokens by themselves
    if #out == 0 and #missing > 0 then out[1] = table.concat(missing, ", "):sub(1, ADD_PER_ORIGINAL) end
    return table.concat(out, ". ")
end

--- What a correction would add to the target → the text | nil, why (nothing it lost is in the original's sentences,
--- or the target has no room left). The dry run asks the same question.
local function correction_line(row, target, missing)
    local add = missing_facts(row.body, missing)
    if add == "" then return nil, "nothing to add" end
    local line = "\n\nKept from an earlier note (" .. tostring(row.title or ""):sub(1, 60) .. "): " .. add
    if #target.body + #line > BODY_ROOM then return nil, "no room left in the summary" end
    return line
end

--- Add that text to the target (a summary is updated, an observation is re-embedded) → true | nil, why
local function correct_target(target, line)
    local body = target.body .. line
    if target.kind == "summary" then
        local r, err = require("luamemo.store").update(target.id, { body = body })
        if not r then return nil, "update: " .. tostring(err) end
        return true
    end
    local vec, err = require("luamemo.embed").embed(body)
    if not vec then return nil, "embed: " .. tostring(err) end
    local blob, norm = vectors.pack(vec)
    local n, uerr = db.run("UPDATE lm_observations SET body = ?, embedding = ?, emb_norm = ? WHERE id = ?",
        body, db.blob(blob), norm, as_id(target.id))
    if not n then return nil, "update: " .. tostring(uerr) end
    return true
end

-- One UPDATE or DELETE of the review, as `hit(what, db.run(…))` → true | nil, why: it ran, and it changed the one row
-- waiting for its review.
local function hit(what, n, err)
    if n == nil then return nil, what .. " failed: " .. tostring(err) end
    if n == 0 then return nil, what .. ": the memory is no longer waiting for its review (another run got there first)" end
    return true
end

local function set_fold(row, rec, sets)   -- sets: { path = value, … } on $.lm_fold.* → true | nil, why
    local parts, params = {}, {}
    for k, v in pairs(sets) do
        parts[#parts + 1] = "'$.lm_fold." .. k .. "', ?"
        params[#params + 1] = v
    end
    local consolidated_at, reviews = pin(row, rec)
    params[#params + 1] = row_id(row)
    params[#params + 1] = consolidated_at
    params[#params + 1] = reviews
    -- (a row consolidated before folds were recorded has no lm_fold object yet, and json_set does not make a missing
    -- parent: it is made first, so the review's decision on such a row is written, not lost)
    return hit("the update", db.run("UPDATE lm_memories SET metadata = json_set(COALESCE(NULLIF(metadata, ''), '{}'), "
        .. "'$.lm_fold', json(COALESCE(json_extract(metadata, '$.lm_fold'), '{}')), " .. table.concat(parts, ", ")
        .. ") WHERE id = ? AND " .. PINNED_SQL, unpack(params, 1, #params)))
end

-- The tier an original had before it was folded: 0 to 3 (the summarizer folds a core memory too). A record that does not
-- say (forged, or from a build that did not write it) counts as an ordinary memory: it is shown again, never taken for
-- raw conversation — and a value out of range is clamped, never a tier the writer could not have made.
local function tier_before(rec)
    return util.clamp_tier(rec.tier_before)
end

-- The same rule as `tier_before`, for a statement: the record of the row it finds (a number in range, else 1).
local TIER_BEFORE_SQL = "max(0, min(3, COALESCE(CASE WHEN json_type(metadata, '$.lm_fold.tier_before') IN ('integer', 'real') "
    .. "THEN CAST(json_extract(metadata, '$.lm_fold.tier_before') AS INTEGER) END, 1)))"
-- An archived original, as the statement finds the row: the test of `not_folded_sql`, negated.
local ARCHIVED_SQL = "(tier = 0 AND json_type(metadata, '$.lm_fold') IS NOT NULL)"

--- What an edit (new text), a move or a metadata patch does to an archived original — the ONE place that says it, as SQL so
--- that it is decided on the row as the UPDATE finds it (a fold that landed while the caller embedded the new text is seen):
---   · edited or moved (`opts.renewed`): it is its own memory again, not an original waiting for its review — shown at the
---     tier it had, no more than `opts.max_tier` (what the destination allows), its fold record gone (the rest of its
---     metadata is its own); a row that is no archived original keeps its tier — `opts.else_tier`, if the caller moves it to
---     one — and its metadata;
---   · only patched (`opts.metadata`, the new object as JSON): the patch replaces the metadata but not the record — else the
---     review takes the note for raw conversation nothing holds, and deletes it. Never one in the patch itself.
--- → the SET clauses and their parameters, in order (both empty for a plain edit of the other fields); the caller appends the
--- two lists to its statement together.
function M.edit_sets(opts)
    local sets, params = {}, {}
    if opts.renewed then
        sets[#sets + 1] = "tier = CASE WHEN " .. ARCHIVED_SQL .. " THEN min(?, " .. TIER_BEFORE_SQL .. ") ELSE "
            .. (opts.else_tier and "?" or "tier") .. " END"
        params[#params + 1] = opts.max_tier or 3
        if opts.else_tier then params[#params + 1] = opts.else_tier end
        if opts.metadata then
            sets[#sets + 1] = "metadata = CASE WHEN " .. ARCHIVED_SQL .. " THEN json_remove(?, '$.lm_fold') ELSE ? END"
            params[#params + 1] = opts.metadata
            params[#params + 1] = opts.metadata
        else
            sets[#sets + 1] = "metadata = CASE WHEN " .. ARCHIVED_SQL .. " THEN json_remove(metadata, '$.lm_fold') ELSE metadata END"
        end
    elseif opts.metadata then
        sets[#sets + 1] = "metadata = CASE WHEN " .. ARCHIVED_SQL
            .. " THEN json_set(?, '$.lm_fold', json_extract(metadata, '$.lm_fold')) ELSE ? END"
        params[#params + 1] = opts.metadata
        params[#params + 1] = opts.metadata
    end
    return sets, params
end

--- A reviewed original that stays: visible again at the tier it had, or — raw conversation, which was hidden to
--- begin with — hidden for good, out of every pass.
local function restore_kind(rec)   -- "restored" (visible again) | "kept" (hidden for good)
    return tier_before(rec) >= 1 and "restored" or "kept"
end

--- → "restored" | "kept" | nil, why
local function restore(row, rec)
    local kind = restore_kind(rec)
    local ok, why
    if kind == "restored" then
        ok, why = hit("the restore", db.run("UPDATE lm_memories SET tier = ?, " .. UNFOLD_SET .. " "
            .. "WHERE id = ? AND " .. PINNED_SQL, math.floor(tier_before(rec)), row_id(row), pin(row, rec)))
    else
        ok, why = set_fold(row, rec, { state = "kept" })
    end
    if not ok then return nil, why end
    return kind
end

-- A step of the review (`delete`, `correct`, and the review_row that calls them) that did not happen is answered
-- `nil, why, flag`: no flag, the original was not changed (a write failed, another run got there first; a correction
-- already written to its target stays — `why` says so); "log": the log is what failed, so every delete of this pass
-- would fail the same way; "restore": the correction cannot be made, so the original is given back instead.

--- The line comes first, and the delete does not happen without it: a deleted memory has no other record.
--- → "deleted" | nil, why [, "log"]
local function delete(row, rec, entry)
    if not M.log(entry) then return nil, "the maintenance log could not be written: not deleted", "log" end
    local ok, err = hit("the delete", db.run("DELETE FROM lm_memories WHERE id = ? AND " .. PINNED_SQL, row_id(row), pin(row, rec)))
    if not ok then return nil, err end
    return "deleted"
end

--- Add what the target lost to it and send the original back to grace → "corrected" | nil, why [, "restore"]
local function correct(row, rec, target, missing, now, entry)
    local line, why = correction_line(row, target, missing)
    if not line then return nil, why, "restore" end
    local ok, err = correct_target(target, line)
    if not ok then return nil, err, "restore" end
    local done, why_not = set_fold(row, rec, { review_at = now + grace_us(rec.into_kind), reviews = reviews_of(rec) + 1 })
    -- (the facts are in the target by now and stay there: the original just has not been marked as waiting again)
    if not done then return nil, "the target was corrected, but " .. why_not end
    M.log(entry)
    return "corrected"
end

local BUCKET = { delete = "deleted", correct = "corrected" }   -- (the decision → what became of the original; a restore: restore_kind)

--- Review one folded original: decide (M.decide) and act → what became of it: "deleted" | "corrected" | "restored" |
--- "kept" (with opts.dry_run: what would) | nil, why [, "log"] (the original was not changed: a lookup or a write
--- failed, the delete could not be recorded first, or another run had already reviewed it; a correction already
--- written to its target stays — `why` says so; "log": the log is what failed, see `delete`).
local function review_row(row, now, opts)
    local meta = type(row.metadata) == "table" and row.metadata or json.decode(tostring(row.metadata or "{}")) or {}
    local rec = type(meta.lm_fold) == "table" and meta.lm_fold or {}
    if rec.into_kind == nil then
        -- a row a digest consolidated before folds were recorded: no record at all, or the one a correction of such a
        -- row made (set_fold writes only the keys it changes) — raw conversation folded into an observation
        rec.into_kind, rec.tier_before, rec.folded_at = "observation", rec.tier_before or 0, rec.folded_at or row.consolidated_at
    end
    local target, lookup_err = target_of(row, rec)   -- (nil, with no error: it is gone)
    if lookup_err then return nil, "the memory it was folded into could not be looked up (nothing done): " .. tostring(lookup_err) end
    local ev = evidence(row, rec, target)
    local cov, missing = 1, {}
    if target then cov, missing = M.coverage((row.title or "") .. " " .. (row.body or ""), target.text) end
    local decision, why = M.decide({
        -- raw: conversation the digest folded into an observation. A tier-0 memory folded into a SUMMARY is not: if
        -- that summary is gone the memory is the only copy of its facts.
        target_missing = target == nil, raw = tier_before(rec) == 0 and rec.into_kind == "observation",
        target_flawed = ev.target_flawed,
        useful = ev.useful, coverage = cov, reviews = reviews_of(rec),
        max_reviews = num("fold_max_reviews"), min_coverage = num("fold_min_coverage") })
    if opts.dry_run then
        -- (a correction that cannot be made is a restore in the real run: the dry run asks the same question)
        if decision == "correct" and not correction_line(row, target, missing) then return restore_kind(rec) end
        return BUCKET[decision] or restore_kind(rec)
    end
    local entry = { scope = row.scope, memory = row_id(row), title = tostring(row.title or ""):sub(1, 80),
                    into = rec.into_kind, decision = decision, why = why, coverage = math.floor(cov * 100) / 100,
                    praise = ev.praise, offered = ev.offered, wrong = ev.wrong, reviews = reviews_of(rec) }
    -- (only a delete needs its line first: what a restore or a correction did is still there to see in the database)
    if decision == "delete" then return delete(row, rec, entry) end
    if decision == "correct" then
        local bucket, err, flag = correct(row, rec, target, missing, now, entry)
        if bucket or flag ~= "restore" then return bucket, err, flag end
        -- it cannot be corrected: the original is the only place its facts are
        entry.why, entry.decision = tostring(why) .. "; not corrected: " .. tostring(err), "restore"
    end
    local kind, err = restore(row, rec)
    if not kind then return nil, err end
    M.log(entry)
    return kind
end

--- Review the folded originals of `scope` that are due → { reviewed, deleted, corrected, restored, kept, errors,
--- skipped, partial }
--- (errors: a list of what went wrong with a row, as text — a row that raised, a delete that could not be recorded;
--- skipped: why the scope is not maintained, and nothing was done; partial: the deadline stopped the pass with rows
--- still due — the next run takes them).
--- opts: limit (200), deadline (os.time() to stop at), dry_run (decide and report, change nothing).
function M.run(scope, opts)
    opts = opts or {}
    local res = { reviewed = 0, deleted = 0, corrected = 0, restored = 0, kept = 0, errors = {} }
    res.skipped = policy.maintenance_skip(scope)
    if res.skipped then return res end
    local now = util.now_us()
    local due, p1, p2 = M.due_clause(now)
    local rows, qerr = db.query("SELECT id, scope, kind, title, body, tier, metadata, consolidated_at FROM lm_memories "
        .. "WHERE scope = ? AND " .. due .. " ORDER BY consolidated_at LIMIT ?", scope, p1, p2, tonumber(opts.limit) or 200)
    if not rows then
        res.errors[1] = "the originals due for review could not be listed: " .. tostring(qerr)
        return res
    end
    for _, row in ipairs(rows) do
        if opts.deadline and os.time() >= opts.deadline then res.partial = true; break end
        -- (one record that cannot be read — a forged lm_fold, say — must not stop the rest of the scope's review)
        local ok, result, why, flag = pcall(review_row, row, now, opts)   -- (result: the bucket, or the error when not ok)
        if not ok then
            res.errors[#res.errors + 1] = ("memory %s: %s"):format(tostring(row.id), tostring(result))
            M.log({ run = "review", scope = row.scope, memory = tonumber(row.id), error = tostring(result) })
        elseif result then
            local bucket = result
            res.reviewed = res.reviewed + 1
            res[bucket] = res[bucket] + 1
        else
            res.errors[#res.errors + 1] = ("memory %s: %s"):format(tostring(row.id), tostring(why))
            -- (a log that cannot be written fails every delete the same way, and its rows stay at the head of the
            -- next pass: say so once and stop, instead of re-reviewing the same rows to refuse them again)
            if flag == "log" then break end
        end
    end
    return res
end

return M
