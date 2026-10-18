-- eval/tests/test_membench.lua
-- Fixture-based test for the MemBench evaluation harness.
--
-- Uses eval/fixtures/membench_tiny/ — a tiny dataset in the REAL MemBench
-- layout (one JSON file per category, see eval/datasets/membench.lua):
--   aggregative.json       role-keyed, two topic keys ("roles", "events")
--   highlevel.json         topic-keyed ("movie" kept, "food" filtered out)
--   knowledge_update.json  role-keyed
--   simple.json            role-keyed, plus an empty-question item (skipped)
-- → 5 questions, 13 turns.
--
-- Verifies:
--   1. Loader: counts, deterministic id order (category → sorted topic → file
--      order), empty-question skip, topic filter, turn flattening for both turn
--      shapes (sid/user_message vs mid/user), target_sids, limit, categories(),
--      missing category files skipped
--   2. The REAL runner (eval/membench_run.lua) end-to-end on the fixture:
--      exit status, JSON output shape + metrics, rows written, and that its
--      --scope-prefix keeps it off real benchmark scopes (mb:hash:*)
--
-- Run (the test runner sets a new MEMO_DB per file):
--   MEMO_DB=/tmp/test_membench.db luajit eval/tests/test_membench.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path

local cjson = require("luamemo.json")

local pass = 0
local fail = 0
local function check(label, cond, detail)
    if cond then
        pass = pass + 1
        io.write(string.format("  PASS  %s\n", label))
    else
        fail = fail + 1
        io.write(string.format("  FAIL  %s%s\n", label, detail and (" | " .. tostring(detail)) or ""))
    end
end

local function count_keys(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

local FIXTURE_DIR = "eval/fixtures/membench_tiny"
local CATS        = { "aggregative", "highlevel", "knowledge_update", "simple" }

-- ---------------------------------------------------------------------------
-- 1. Loader
-- ---------------------------------------------------------------------------
print("\n-- membench dataset loader --")

local membench = require("membench")

local ok, data = pcall(membench.load, FIXTURE_DIR, { cats = CATS })
check("load fixture dir without error", ok and type(data) == "table", tostring(data))
data = ok and data or {}
check("fixture yields 5 questions (empty question skipped, food filtered)", #data == 5, "got " .. #data)

-- Deterministic order: category order, then topic keys SORTED, then file order.
local want = {
    { "aggregative",      "events" },
    { "aggregative",      "roles"  },
    { "highlevel",        "movie"  },
    { "knowledge_update", "events" },
    { "simple",           "roles"  },
}
for i, w in ipairs(want) do
    local q = data[i] or {}
    check(("q[%d] = %s/%s with id %d"):format(i, w[1], w[2], i),
        q.category == w[1] and q.topic == w[2] and q.id == i,
        ("got %s/%s id=%s"):format(tostring(q.category), tostring(q.topic), tostring(q.id)))
end

local again = membench.load(FIXTURE_DIR, { cats = CATS })
local same = #again == #data
for i = 1, #data do
    if not again[i] or again[i].question ~= data[i].question then same = false end
end
check("two loads give the same id → question mapping", same)

local empties = 0
for _, q in ipairs(data) do if q.question == "" then empties = empties + 1 end end
check("no empty-question item loaded", empties == 0)

-- Turn flattening — role-keyed shape (sid / user_message / assistant_message),
-- sessions concatenated in order.
local simple = data[5] or { turns = {} }
check("simple: 3 turns across 2 sessions", #simple.turns == 3, "got " .. #simple.turns)
check("simple: turn sids are strings 1,2,3",
    simple.turns[1] and simple.turns[1].sid == "1" and simple.turns[2].sid == "2" and simple.turns[3].sid == "3")
check("simple: turn text = 'User: …\\nAssistant: …'",
    simple.turns[1] and simple.turns[1].text
        == "User: I prefer Lua for scripting tasks.\nAssistant: Got it! Lua is a great choice for scripting.",
    simple.turns[1] and simple.turns[1].text)
check("simple: target_sids = {'1'}",
    simple.target_sids and simple.target_sids["1"] == true and count_keys(simple.target_sids) == 1)

-- Topic-keyed shape (mid / user / assistant).
local movie = data[3] or { turns = {} }
check("highlevel: 2 turns from mid/user/assistant",
    #movie.turns == 2 and movie.turns[1].sid == "1"
        and (movie.turns[1].text or ""):find("User: I loved Inception", 1, true) ~= nil)

-- Multi-target question.
local agg = data[2] or {}
check("aggregative/roles: 2 target sids (20, 21)",
    agg.target_sids and agg.target_sids["20"] and agg.target_sids["21"] and count_keys(agg.target_sids) == 2)

-- Topic filter applies to topic-keyed files only.
local food = membench.load(FIXTURE_DIR, { cats = { "highlevel" }, topic = "food" })
check("topic=food selects the food item of a topic-keyed file",
    #food == 1 and food[1].topic == "food" and food[1].question:find("food", 1, true) ~= nil)
local agg_food = membench.load(FIXTURE_DIR, { cats = { "aggregative" }, topic = "food" })
check("topic filter does not apply to role-keyed files", #agg_food == 2, "got " .. #agg_food)

-- limit
local limited = membench.load(FIXTURE_DIR, { cats = CATS, limit = 2 })
check("limit=2 returns the first 2 questions",
    #limited == 2 and limited[1].id == 1 and limited[2].id == 2)

-- categories()
local cats = membench.categories(data)
check("categories() = sorted distinct categories",
    table.concat(cats, ",") == "aggregative,highlevel,knowledge_update,simple", table.concat(cats, ","))

-- Default category list: files absent from the fixture are skipped (the
-- loader reports each on stderr), the rest load normally.
local all = membench.load(FIXTURE_DIR)
check("default cats: missing category files skipped, 5 questions", #all == 5, "got " .. #all)

-- ---------------------------------------------------------------------------
-- 2. The real runner, end to end on the fixture
-- ---------------------------------------------------------------------------
print("\n-- membench_run.lua on the fixture --")

local db_name = os.getenv("MEMO_DB")
if not db_name or db_name == "" then
    print("  [SKIP] MEMO_DB not set — skipping the runner run")
else
    local memory = require("luamemo")
    memory.setup({ embedder_local = "hash", patterns_enabled = false, skip_embed_probe = true })
    local db = require("luamemo.db")

    local PREFIX = "smoke_mb"
    local function scope_rows(pattern)
        return tonumber((db.value("SELECT count(*) FROM lm_memories WHERE scope LIKE ?", pattern))) or -1
    end
    local function cleanup()
        db.run("DELETE FROM lm_memories WHERE scope LIKE ?", PREFIX .. ":hash:%")
    end
    cleanup()
    local real_before = scope_rows("mb:hash:%")

    -- The interpreter is the lowest negative arg index (options like -e sit between).
    local lua_bin = "luajit"
    if arg then
        local i = -1
        while arg[i - 1] do i = i - 1 end
        lua_bin = arg[i] or lua_bin
    end
    local out_path = os.tmpname()
    local cmd = ("%s eval/membench_run.lua --embedder hash --data-dir %s --cats %s --k-max 5 "
        .. "--scope-prefix %s --out %s 2>&1; echo \"__EXIT__$?\""):format(
        lua_bin, FIXTURE_DIR, table.concat(CATS, ","), PREFIX, out_path)
    local p = io.popen(cmd)
    local log = p and p:read("*a") or ""
    if p then p:close() end
    local exit_code = tonumber(log:match("__EXIT__(%d+)"))
    check("runner exits 0", exit_code == 0, "exit=" .. tostring(exit_code) .. " log: " .. log:sub(1, 400))

    local fh = io.open(out_path, "r")
    local raw = fh and fh:read("*a") or ""
    if fh then fh:close() end
    os.remove(out_path)
    local res, jerr = cjson.decode(raw)
    check("runner wrote parseable JSON", type(res) == "table", tostring(jerr))
    res = type(res) == "table" and res or {}

    check("result n = 5", res.n == 5, tostring(res.n))
    local by_cat = res.by_category or {}
    check("by_category has the 4 fixture categories",
        by_cat.aggregative and by_cat.highlevel and by_cat.knowledge_update and by_cat.simple
            and count_keys(by_cat) == 4)
    check("by_category.aggregative.n = 2", by_cat.aggregative and by_cat.aggregative.n == 2)
    check("per_question has 5 entries", type(res.per_question) == "table" and #res.per_question == 5)

    local shape_ok = true
    for i, pq in ipairs(res.per_question or {}) do
        local q = data[i] or {}
        if pq.id ~= q.id or pq.n_turns ~= #(q.turns or {}) or pq.n_target ~= count_keys(q.target_sids) then
            shape_ok = false
        end
    end
    check("per_question ids / n_turns / n_target match the loader", shape_ok)

    local ov = res.overall or {}
    -- Each question's scope holds ≤ 3 turns and k_max = 5, so every target is
    -- retrievable: R@5 must be 1. R@1 / MRR show the ranking actually works.
    check("overall R@5 = 1 (every target within k)", ov.r5 == 1, tostring(ov.r5))
    check("overall R@1 > 0", (ov.r1 or 0) > 0, tostring(ov.r1))
    check("overall MRR > 0", (ov.mrr or 0) > 0, tostring(ov.mrr))

    check("runner wrote one memory per turn (13) under the test prefix",
        scope_rows(PREFIX .. ":hash:%") == 13, "got " .. scope_rows(PREFIX .. ":hash:%"))
    check("--scope-prefix left real mb:hash:* scopes untouched",
        scope_rows("mb:hash:%") == real_before, ("before=%d after=%d"):format(real_before, scope_rows("mb:hash:%")))

    cleanup()
    check("test scopes cleaned up", scope_rows(PREFIX .. ":hash:%") == 0)
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
