-- eval/tests/test_org_central.lua
-- The org paths of the maintenance work, against a real (mock) central: eval/tests/_org.lua starts a `memo serve` of its
-- own — database, keys, encrypted channel — and this process is a dev paired with it.
--   A. the mock central: it starts, a dev pairs, the pull brings the org memory in as a replica
--   B. a dev's maintenance leaves the replica alone, by every road (review, run, claims, archive, decay, promote),
--      the brief's scan for due reviews), while its own scope is maintained as usual
--   B2. the served central marks its listener and its accepted sockets close-on-exec (a write there starts `memo maintain`,
--      which must not inherit them), checked through /proc with a control
--   C. on the central: approved org knowledge is written with no_miss — a near-duplicate of it is not a "miss" of the
--      search (the control: the same write without it is)
--   D. the usage log on the central: a search the dev pushed over the wire (client.push; it has a source) is never
--      pruned; the central's own old searches are
--   E. memo eval's history ledger is written with no_miss too (feedback on, two cells with the same text: no miss)
-- Run: luajit eval/tests/run.lua --only org_central

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local Org = require("eval.tests._org")
local T = H.new("Org central (mock)")
local check, section, finish = T.check, T.section, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local json        = require("luamemo.json")
local client     = require("luamemo.federation.client")
local fold        = require("luamemo.fold")
local maintenance = require("luamemo.maintenance")
local store       = require("luamemo.store")
local util        = require("luamemo.util")

local NAME = "fedmock"
local ORG  = "org:" .. NAME
local DEV_KEYS = H.tmp_path("org_central_dev_keys_" .. os.time())
local org, started_err

local function dev(extra) org:as_dev(extra, DEV_KEYS) end

section("A the mock central", function()
    -- (decay_rate 1.0: a row that decay WOULD select if it were the dev's own — the replica test below is a real one)
    org, started_err = Org.start({ name = NAME, central_config = "feedback_enabled = true",
        seed = ([[assert(store.write({ scope = %q, title = "Soft delete", tier = 1, importance = 0.6, decay_rate = 1.0,
            body = "Users are soft-deleted by api/users.lua (deleted_at is set)." }))]]):format(ORG) })
    check("it starts, with a fingerprint, and listens on a port", org ~= nil and org.fp ~= nil and org.port ~= nil, started_err)
    if not org then return end
    dev()
    check("a dev pairs and the central approves the device", org:pair(client) == true)
    local s, e = client.pull()
    check("the first pull learns the org scope", s and s.org_scope == ORG, e)
    check("… and the org memory is in the dev's database, as a replica",
        tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", ORG)) == 1)
end)

section("B a dev's maintenance leaves the replica alone", function()
    if not org then return end
    dev()
    local cfg = luamemo.config
    local rid = tonumber(db.value("SELECT id FROM lm_memories WHERE scope = ?", ORG))
    local function replica() return db.first("SELECT tier, importance, decay_rate, consolidated_at, metadata, body FROM lm_memories WHERE id = ?", rid) end
    local before = replica()
    check("(the replica is a row decay would take if it were the dev's own: decay_rate and importance above 0)",
        tonumber(before.decay_rate) > 0 and tonumber(before.importance) > 0, json.encode(before))
    H.with(cfg, "rerank_adapter", "learned", function()
        H.with(cfg, "feedback_enabled", true, function()
            check("the review skips it", fold.run(ORG).skipped == "replica")
            check("a maintenance run skips it", maintenance.run(ORG, { review = true, digest = true }).skipped == "replica")
            check("the reranker's training skips it", maintenance.learn(ORG).skipped == "replica")
        end)
    end)
    check("no digest or summary slot is claimed for it",
        require("luamemo.digest").claim(ORG) == false and require("luamemo.summarizer").claim(ORG) == false)
    local started = 0
    H.with(maintenance, "spawner", function() started = started + 1; return true end, function()
        H.with(cfg, "auto_digest_enabled", true, maintenance.after_write, ORG, cfg)
    end)
    check("a write-time maintenance pass for it starts nothing", started == 0)
    check("archiving its row changes nothing", fold.archive({ rid }, "summary", nil) == 0)

    -- decay: the same call selects a row of the dev's own with the same numbers, and does not select the replica
    local own = "repo:orgdev"
    local c = assert(store.write({ scope = own, title = "decaying note", body = "a note of the dev's own that decays", tier = 1,
        importance = 0.6, decay_rate = 1.0, dedup_strategy = "append" }))
    local function selects(scope, id)
        for _, got in ipairs(store.find_decayed({ scope = scope, decay_threshold = 99, apply = false }) or {}) do
            if tonumber(got) == tonumber(id) then return true end
        end
        return false
    end
    check("(control) the decay pass selects the dev's own row", selects(own, c.id))
    check("the decay pass does not select the replica", not selects(ORG, rid))

    local pr = require("luamemo.summarizer").promote({ from_scope = ORG, to_scope = own, delete_source = true })
    check("promoting it away with delete_source is refused", pr and pr.promoted == 0)
    local after = replica()
    check("the replica row is exactly as the central sent it",
        after and before and after.tier == before.tier and after.importance == before.importance and after.consolidated_at == nil
        and after.body == before.body and H.same(after.metadata, before.metadata),
        json.encode(after) .. " vs " .. json.encode(before))
    -- the control: the dev's own scope is maintained as usual
    local a = assert(store.write({ scope = own, title = "own note", body = "a note of the dev's own", tier = 0, importance = 0.2, dedup_strategy = "append" }))
    check("(control) a scope of the dev's own is not skipped", maintenance.run(own, { review = true }).skipped == nil
        and fold.archive({ a.id }, "observation", nil) == 1)

    -- the brief's scan (what its once-a-day kick asks) leaves the replica out, by the review's own exclusion
    local legacy = assert(store.write({ scope = own, title = "legacy", body = "a tier-0 note consolidated long ago", tier = 0,
        importance = 0.2, dedup_strategy = "append" })).id
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id IN (?, ?)", util.now_us() - 40 * util.DAY_US, legacy, rid)
    db.run("UPDATE lm_memories SET tier = 0 WHERE id = ?", rid)
    local function listed(scope)
        for _, s in ipairs(maintenance.due_scopes()) do if s == scope then return true end end
        return false
    end
    check("the scan lists the dev's own scope (a tier-0 row consolidated long ago) but not the replica's, which looks the same",
        listed(own) and not listed(ORG))
    db.run("UPDATE lm_memories SET tier = ?, consolidated_at = NULL WHERE id = ?", before.tier, rid)
    db.run("DELETE FROM lm_memories WHERE id = ?", legacy)
end)

section("B2 the served central marks its sockets close-on-exec (a write there starts `memo maintain`)", function()
    if not org then return end
    if not util.is_dir("/proc/self/fd") then io.write("[SKIP] no /proc here: the central's descriptors cannot be listed\n"); return end
    local socket = require("socket")
    -- the sockets a process holds, and how many of them are not close-on-exec → total, unmarked, the raw listing
    local function sockets_of(pid)
        local listing = H.sh(([[for f in /proc/%d/fd/*; do l=$(readlink "$f"); case "$l" in socket:*) fd=${f##*/}; ]]
            .. [[echo "$fd $(grep '^flags' /proc/%d/fdinfo/$fd | cut -f2)";; esac; done]]):format(pid, pid))
        local total, unmarked = 0, 0
        for _, flags in listing:gmatch("(%d+)%s+(%d+)") do
            total = total + 1
            if require("bit").band(tonumber(flags, 8), tonumber("2000000", 8)) == 0 then unmarked = unmarked + 1 end
        end
        return total, unmarked, listing
    end
    -- (control: a luasocket socket of THIS process is opened without the flag, and the listing says so)
    local plain = assert(socket.tcp()); assert(plain:bind("127.0.0.1", 0))
    local own = tonumber((H.slurp("/proc/self/stat") or ""):match("^(%d+)"))
    local own_total, own_unmarked = sockets_of(own)
    check("(control) the listing sees an unmarked socket of this process", own_total >= 1 and own_unmarked >= 1, ("%d %d"):format(own_total, own_unmarked))
    plain:close()
    -- an open connection the central has accepted and is waiting on, besides its listener
    local conn = assert(socket.connect("127.0.0.1", org.port))
    os.execute("sleep 0.5")
    -- (the server runs under `timeout` when there is one; without it the pid we hold IS the server)
    local pid = tonumber((H.sh("pgrep -P " .. tostring(org.pid)):match("%d+"))) or (H.timeout(1) == "" and org.pid or nil)
    if not pid then
        io.write("[SKIP] the served process is not found under its `timeout` wrapper\n")
    else
        local total, unmarked, listing = sockets_of(pid)
        check("the listener and the accepted connection are both there, and every one of the central's sockets is close-on-exec",
            total >= 2 and unmarked == 0, ("sockets=%d unmarked=%d %s"):format(total, unmarked, listing))
    end
    conn:close()
end)

section("C org knowledge is never a 'miss'", function()
    if not org then return end
    local r = org:call(("local ORG = %q\n"):format(ORG) .. [[
local real, seen = store.write, nil
store.write = function(a) if type(a.metadata) == "table" and a.metadata.lm_org_knowledge then seen = a.no_miss end return real(a) end
local T1, B1 = "Creating users", "POST /users goes through users.create() in api/users.lua; it validates the email first."
local res = k.ingest("user:a@corp.io", { propose = { { ref = "a:1", project = "fedmock", kind = "fact", title = T1, body = B1,
    score = 1.2, grounding = { "api/users.lua" } } } }).results[1]
local mem = k.approve(res.proposal, "admin")
store.write = real
local function misses() return tonumber(db.value("SELECT count(*) FROM lm_reinforcements WHERE event_type = 'miss'")) end
local after_approve = misses()
-- the control: the same words written again by an ordinary write, with the usage log on, are a miss
assert(store.write({ scope = ORG, title = T1, body = B1, tier = 1, importance = 0.6, dedup_strategy = "append" }))
result({ no_miss = seen, mem = mem, after_approve = after_approve, after_control = misses() })]])
    check("approving a proposal writes the org memory with no_miss", r.no_miss == true and r.mem ~= nil, json.encode(r))
    check("… and no miss was recorded for it", r.after_approve == 0, r.after_approve)
    check("(control) the same words written by an ordinary write DO record a miss — so the flag is what spared it", r.after_control == 1, r.after_control)
end)

section("D the central's usage log", function()
    if not org then return end
    -- a real push over the wire: the dev's search of a replica row reaches the central with a source
    dev({ feedback_enabled = true })
    local rid = tonumber(db.value("SELECT id FROM lm_memories WHERE scope = ?", ORG))
    require("luamemo.feedback").log_retrieval(ORG, "a question a dev asked long ago", { rid })
    local pushed, perr = client.push()
    check("the dev's push sends the search", pushed and pushed.retrievals == 1, perr or json.encode(pushed))
    local r = org:call(("local ORG = %q\n"):format(ORG) .. [[
local feedback = require("luamemo.feedback")
local K = tonumber(db.value("SELECT id FROM lm_memories WHERE scope = ? ORDER BY id LIMIT 1", ORG))
feedback.log_retrieval(ORG, "a search the central itself logged long ago", { K })
db.run("UPDATE lm_retrieval_feedback SET created_at = 1")
local pushed = tonumber(db.value("SELECT count(*) FROM lm_retrieval_feedback WHERE source IS NOT NULL"))
local removed = feedback.prune()
result({ pushed = pushed, removed = removed,
    sourced_left = tonumber(db.value("SELECT count(*) FROM lm_retrieval_feedback WHERE source IS NOT NULL")),
    local_left = tonumber(db.value("SELECT count(*) FROM lm_retrieval_feedback WHERE source IS NULL")) })]])
    check("the central holds the dev's search, with a source", r.pushed == 1, json.encode(r))
    check("pruning removes the central's own old search and keeps the dev's", r.removed == 1 and r.sourced_left == 1 and r.local_left == 0,
        json.encode(r))
end)

section("E memo eval's ledger is no 'miss' either", function()
    local ledger_db = H.create_db("lm_ledger_" .. os.time())
    local script = os.tmpname()
    local f = assert(io.open(script, "w"))
    f:write([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local ev = require("luamemo.cli.eval")
local function row(bench) return { bench = bench, label = "hash", title = "Same title", kind = "retrieval", summary = {} } end
local problem = ev.record({ row("alpha"), row("beta") }, "2026-10-26 10:00")
local db = require("luamemo.db")
local scope = ev.history_scope()
local mem = require("luamemo")
io.write("\n@@RESULT@@", require("luamemo.json").encode({
    problem = problem, cells = tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", scope)),
    misses = tonumber(db.value("SELECT count(*) FROM lm_reinforcements WHERE event_type = 'miss'")),
    -- the control: the same words written by an ordinary write with the usage log on are a miss
    control = (function()
        local first = mem.search({ scope = scope, query = "Same title", limit = 1, skip_feedback = true })[1]
        assert(mem.write({ scope = scope, kind = "note", title = first.title, body = first.body, dedup_strategy = "append" }))
        return tonumber(db.value("SELECT count(*) FROM lm_reinforcements WHERE event_type = 'miss'"))
    end)() }), "\n")
]])
    f:close()
    local out = H.sh(("env -u MEMO_SCOPE MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_FEEDBACK_ENABLED=true MEMO_SCOPE=repo:ledger %q %q")
        :format(ledger_db, H.lua_bin(), script))
    os.remove(script)
    local body = out:match("@@RESULT@@([^\n]*)")
    local r = body and json.decode(body) or {}
    check("two history cells with the very same text were written", r.problem == nil and r.cells == 2, out:sub(1, 400))
    check("… and no miss was recorded for the second", r.misses == 0, tostring(r.misses))
    check("(control) an ordinary write of that text is a miss with the usage log on", r.control == 1, tostring(r.control))
end)

if org then org:stop() end
os.execute(("rm -rf %q"):format(DEV_KEYS))
H.drop_dbs()
finish()
