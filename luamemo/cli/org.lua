-- luamemo.cli.org
-- `memo org` — federation from the command line. The subcommands depend on
-- this instance's role:
--
--   dev (MEMO_ORG_URL + MEMO_ORG_FINGERPRINT):
--     memo org probe           the central's public fingerprint (unpinned — to compare
--                              with the one your org admin gave you)
--     memo org pair [--wait N] ask the central to pair this device (shows the code
--                              the org admin approves; --wait polls up to N seconds)
--     memo org status          local replica + sync state
--     memo org pull [--full]   refresh the read-only org replica (--full: resync all)
--     memo org push            send local feedback on org memories to the central
--     memo org sync            pull, then push
--     memo org proposals [list | candidates [--explain] | withdraw <id> | private <id> | public <id>]
--                              project knowledge proposed to the org with each push
--                              (filtered, triples mode only; the org admin approves)
--     memo org adopt [--dry-run] [--no-switch]
--                              copy this project's memories from its own database into
--                              the org database this machine shares across the org's
--                              projects, then switch the project to it (source untouched)
--     memo org leave           last push, then stop syncing this project (the org replica
--                              is removed when no other project here still uses it)
--     memo org link            (calibrate) record this project for its org; a fresh
--                              project joins the org database
--
--   org central (MEMO_ROLE=org + MEMO_ORG_NAME):
--     memo org status                      org scope, devices, directives, feedback, weights
--     memo org devs [pending|list]         paired devices / pending pairing requests
--     memo org devs approve <CODE>         approve the request whose code the dev reads out
--     memo org devs remove <user:email | CODE | FINGERPRINT>
--     memo org devs clear-pending         drop every pending request (junk; real devs pair again)
--     memo org review [list [--status S]] | show <id> | approve <id> [--supersedes <org id>]
--                     | approve --top N | reject <id> [--reason …] | remove <org memory id>
--                                          devs' knowledge proposals (approved → tier 1, decays
--                                          unless used, never deleted by decay)
--     memo org directives <path> [--source NAME] [--project NAME] [--dry-run] [--no-prune] [--allow-empty]
--                                          sync Markdown standards into the core tier
--     memo org aggregate [--dry-run] [--min-samples N]
--                                          digest + gated promotion over devs' feedback
--
-- Exit codes: 0 ok, 1 operation failed (e.g. central unreachable), 2 usage / config.

local M = {}

local USAGE = [==[
usage:
  dev:  memo org pair | status | pull [--full] | push | sync | probe · pair --wait N
        memo org proposals [list | candidates [--explain] | withdraw <id> | private <id> | public <id>]
        memo org adopt [--dry-run] [--no-switch] | leave
        (set MEMO_ORG_URL + MEMO_ORG_FINGERPRINT — see `memo calibrate --org-url`)
  org:  memo org status
        memo org devs [pending | list] | approve <CODE> | remove <user:email | CODE | FINGERPRINT>
        memo org review [list [--status S]] | show <id> | approve <id> [--supersedes <org id>]
                        | approve --top N | reject <id> [--reason …] | remove <org memory id>
        memo org directives <path> [--source NAME] [--project NAME] [--dry-run] [--no-prune] [--allow-empty]
        memo org aggregate [--dry-run] [--min-samples N]
        (set MEMO_ROLE=org + MEMO_ORG_NAME — see `memo calibrate --role org`)
]==]

local die = require("luamemo.cli._common").die_for("org", 2)

local function line(k, v) io.write(("%-14s %s\n"):format(k .. ":", tostring(v))) end

-- Flags: { name = "bool" | "value" }; returns flags table + positional args.
local function parse(argv, spec)
    local flags, pos = {}, {}
    local i = 2
    while i <= #argv do
        local a = argv[i]
        local name = a:match("^%-%-([%w%-]+)$")
        if name and spec[name] == "bool" then flags[name] = true; i = i + 1
        elseif name and spec[name] == "value" then
            if argv[i + 1] == nil then die("--" .. name .. " needs a value") end
            flags[name] = argv[i + 1]; i = i + 2
        elseif a:sub(1, 2) == "--" then die("unknown argument: " .. a)
        else pos[#pos + 1] = a; i = i + 1 end
    end
    return flags, pos
end

-- ---------------------------------------------------------------------------
-- dev
-- ---------------------------------------------------------------------------
local function print_pull(s)
    line("org scope", s.org_scope)
    line("pulled", ("%d new/updated, %d unchanged, %d repaired, %d removed (%d page%s%s)"):format(
        s.upserted, s.unchanged, s.repaired, s.deleted, s.pages, s.pages == 1 and "" or "s",
        s.full and ", full resync" or ""))
    line("vectors", s.vectors_reused and "reused from the central (same embedder)" or "re-embedded locally")
    if (s.weights or 0) > 0 then line("weights", s.weights .. " learned model(s) updated") end
    if s.partial then line("note", "time budget reached — the next pull resumes where this stopped") end
end

local function print_push(s)
    if not s then return end
    line("pushed", ("%d event(s), %d retrieval(s) — %d duplicate(s), %d rejected (share=%s)"):format(
        s.events, s.retrievals, s.duplicates, s.rejected, s.share))
    if s.partial then line("note", "time budget reached — the next push continues") end
end

local function show_db(v) return tostring(v) end
local function keys_norm(fp) return require("luamemo.federation.keys").normalize_code(fp or "") end

-- Do two database values (names or paths) name the same file?
local function same_db(a, b)
    if not a or not b then return false end
    local db = require("luamemo.db")
    return (db.resolve(a) or a) == (db.resolve(b) or b)
end

-- The registry entry of ANOTHER org whose database `dbv` is and that still
-- has projects on it (one org per database), or nil.
local function other_orgs_db(dbv, fp)
    for _, o in ipairs(require("luamemo.federation.registry").list()) do
        if same_db(o.db, dbv) and keys_norm(o.fingerprint) ~= keys_norm(fp) and next(o.projects or {}) then
            return o
        end
    end
end

-- Point a project's .luamemorc at the org database AND its embedder (one
-- embedding space per database). Returns true when the embedder changed.
local function switch_rc(rcfile, e)
    local common = require("luamemo.cli._common")
    common.rc_set(rcfile, "MEMO_DB", e.db)
    if type(e.embed) ~= "table" then return false end
    local changed = false
    for _, k in ipairs(common.EMBED_KEYS) do
        local want = e.embed[k]
        local have = os.getenv(k)
        if have == "" then have = nil end
        if want ~= have then changed = true end
        common.rc_set(rcfile, k, want)
    end
    return changed
end

-- An embed function using the org database's embedder (for adopt) + a restore
-- function (the embedder is switched once, on first use — a local model is not
-- reloaded per row). nil, noop when the org's embedder isn't recorded.
local function org_embedder(e)
    if type(e.embed) ~= "table" then return nil, function() end end
    local luamemo = require("luamemo")
    local embed   = require("luamemo.embed")
    local ecfg = {}
    for k, v in pairs(luamemo.config) do ecfg[k] = v end
    for _, k in ipairs({ "embedder_url", "embedder_local", "embedder_adapter", "embedder_model", "embed_dim",
                         "embed_max_chars" }) do ecfg[k] = nil end
    for k, v in pairs(require("luamemo.cli._common").embed_config(e.embed)) do ecfg[k] = v end
    local active   -- nil = not switched yet; false = the org's embedder can't load
    local function fn(text)
        if active == nil then active = pcall(embed.configure, ecfg) end
        if not active then return nil end
        local ok, v = pcall(embed.embed, text)
        return ok and v or nil
    end
    local function restore() if active ~= nil then embed.configure(luamemo.config) end end
    return fn, restore
end

local function run_dev(sub, argv)
    local flags, pos = parse(argv, { full = "bool", wait = "value", project = "value", scope = "value",
                                     ["dry-run"] = "bool", ["no-switch"] = "bool", explain = "bool" })
    local client = require("luamemo.federation.client")
    local cfg = require("luamemo").config
    local project = flags.project
    if not project or project == "" then project = os.getenv("MEMO__PROJECT_DIR") end   -- the one memo found
    if not project or project == "" then project = os.getenv("MEMO_PROJECT") end
    if not project or project == "" then project = require("luamemo.settings").project_dir() end
    local rcfile = project .. "/.luamemorc"
    if sub == "link" or sub == "adopt" or sub == "leave" then   -- these rewrite it
        local settings = require("luamemo.settings")
        local ok, why = settings.trusted(rcfile)
        if ok == false then die(settings.untrusted_message(rcfile, why), 1) end
    end
    local cur_db = cfg.db or os.getenv("MEMO_DB")
    if cur_db == "" then cur_db = nil end
    if sub == "link" then
        -- One local database per org on this machine: the first project's database
        -- becomes the org database; later projects join it. (Used by calibrate.)
        local registry = require("luamemo.federation.registry")
        local fp = cfg.org_fingerprint
        if not fp or fp == "" then die("no pinned central fingerprint (MEMO_ORG_FINGERPRINT)") end
        local _, info = client.central_key(3000)
        local fields = { url = cfg.org_url, org_scope = info and info.org_scope or nil }
        local e = registry.get(fp)
        local owner = other_orgs_db(cur_db, fp)
        if owner then
            -- One org per database: this one is another org's, still used by its
            -- projects (joining would mix orgs; adopting would copy their memories).
            line("database", "this project's database is another org's database on this machine (central "
                .. tostring(owner.fingerprint) .. "), still used by its other projects")
            line("to join", "give this project its own database — set MEMO_DB in .luamemorc — and run calibrate again")
            local common = require("luamemo.cli._common")
            common.rc_set(rcfile, "MEMO_ORG_URL", nil)
            common.rc_set(rcfile, "MEMO_ORG_FINGERPRINT", nil)
            io.write("LINK=conflict\n")
            return
        end
        if not e then
            fields.db = cur_db
            fields.embed, fields.embed_sig = require("luamemo.cli._common").embed_env(),
                require("luamemo.federation.common").embedder_sig(cfg)
            registry.link(fp, fields, project, flags.scope)
            line("database", "this project's database is now this org's database on this machine")
            io.write("LINK=register\n")
        elseif same_db(e.db, cur_db) then
            registry.link(fp, fields, project, flags.scope)
            local changed = switch_rc(rcfile, e)   -- same database → same embedder
            line("database", "already the org database (" .. show_db(cur_db) .. ")")
            if changed then line("embedder", "now the org database's (" .. tostring(e.embed_sig) .. ")") end
            io.write("LINK=same\n")
        else
            local n = tonumber((require("luamemo.db").value("SELECT count(*) FROM lm_memories "
                .. "WHERE scope NOT GLOB 'org:*'"))) or 0
            -- Only projects ON the org database count as its users (leave's last-project rule).
            registry.link(fp, fields, n == 0 and project or nil, flags.scope)
            if n == 0 then
                local changed = switch_rc(rcfile, e)
                line("database", "joined the org database shared with this org's other projects ("
                    .. show_db(e.db) .. ")")
                if changed then line("embedder", "now the org database's (" .. tostring(e.embed_sig) .. ")") end
                io.write("LINK=switched\n")
            else
                line("database", ("this project has %d memories in its own database; the org's other projects "
                    .. "use %s"):format(n, show_db(e.db)))
                io.write(("LINK=adopt %d\n"):format(n))
            end
        end
    elseif sub == "adopt" then
        local registry = require("luamemo.federation.registry")
        local e = registry.get(cfg.org_fingerprint or "")
        if not (e and e.db) then
            die("this machine has no org database for this org yet — calibrate a project with --org-url first", 1)
        end
        if same_db(e.db, cur_db) then line("database", "this project already uses the org database"); return end
        if other_orgs_db(cur_db, cfg.org_fingerprint) then
            die("this project's database is another org's database, shared with its projects — adopt would copy "
                .. "their memories too; give this project its own database first", 1)
        end
        local same = e.embed_sig == nil or e.embed_sig == require("luamemo.federation.common").embedder_sig(cfg)
        local embed_fn, restore = org_embedder(e)
        local rep, err = require("luamemo.federation.adopt").run(cur_db, e.db, { dry_run = flags["dry-run"],
            same_space = same, embed = embed_fn })
        restore()
        if not rep then die(err, 1) end
        line(rep.dry_run and "would copy" or "copied", ("%d memories (%d already adopted)"):format(rep.memories, rep.skipped))
        if not rep.dry_run then
            line("with", ("%d reinforcement(s), %d retrieval event(s), %d graph fact(s), %d observation(s), "
                .. "%d learned weight version(s)"):format(rep.reinforcements, rep.retrievals, rep.facts,
                rep.observations, rep.weights))
            if rep.reembedded > 0 then
                line("re-embedded", rep.reembedded .. " (the org database uses another embedder)")
            end
            if rep.unembedded > 0 then
                line("not embedded", ("%d — the org database's embedder did not answer; after switching run: "
                    .. "memo reembed --scope %s"):format(rep.unembedded, flags.scope or "<scope>"))
            end
            if not flags["no-switch"] then
                local changed = switch_rc(rcfile, e)
                registry.link(cfg.org_fingerprint, {}, project, flags.scope)
                line("database", "this project now uses the org database (" .. show_db(e.db) .. ")")
                if changed then line("embedder", "now the org database's (" .. tostring(e.embed_sig) .. ")") end
                line("note", "the old database was not modified — drop it yourself once you are sure")
            end
        end
    elseif sub == "leave" then
        -- Stop syncing this project with its org: a last push, then remove the
        -- org's replica — unless other projects here still share it.
        local registry = require("luamemo.federation.registry")
        local fp = cfg.org_fingerprint
        if fp == "" then fp = nil end
        local pushed, perr
        if fp then pushed, perr = client.push({ budget_s = 10, timeout_ms = 3000 }) end
        if pushed then
            line("pushed", ("%d event(s), %d retrieval(s) before leaving"):format(pushed.events, pushed.retrievals))
        elseif fp then
            line("push", "skipped — " .. tostring(perr))
        end
        local e = fp and registry.get(fp)
        local remaining = e and registry.unlink(fp, project) or 0
        local shared = e and same_db(e.db, cur_db)
        if not fp then
            -- No pinned central: nothing of an org can be told apart here — only
            -- the settings go.
            line("replica", "left as is (no pinned central fingerprint in this project)")
        elseif shared and remaining > 0 then
            line("replica", ("kept — %d other project(s) on this machine still use this org"):format(remaining))
            line("database", "still the one shared with them (memories stay per scope); for a separate one, "
                .. "set MEMO_DB in .luamemorc")
        else
            -- The org's scope: recorded at link time, else from the central, else
            -- this database's only sync state (one org per database — never a guess
            -- between several).
            local scope = e and e.org_scope
            if not scope then
                local _, info = client.central_key(3000)
                scope = info and info.org_scope
            end
            if not scope and not other_orgs_db(cur_db, fp)
                and require("luamemo.util").table_exists("lm_federation_state") then
                local rows = require("luamemo.db").query("SELECT org_scope FROM lm_federation_state") or {}
                if #rows == 1 then scope = rows[1].org_scope end
            end
            if scope then
                local r, ferr = client.forget(scope)
                if not r then die("could not remove the org replica: " .. tostring(ferr), 1) end
                line("replica", ("removed %s (%d memories, pulled weights, sync state)"):format(scope, r.replica))
            else
                line("replica", "none found (never synced)")
            end
            if shared then registry.remove(fp) end   -- the org database's last user
        end
        local common = require("luamemo.cli._common")
        common.rc_set(rcfile, "MEMO_ORG_URL", nil)
        common.rc_set(rcfile, "MEMO_ORG_FINGERPRINT", nil)
        line("left", "this project no longer syncs with the org (its own memories are kept)")
    elseif sub == "probe" then
        -- Public, unpinned: for comparing with the fingerprint the org admin gave you.
        local r, err = client.probe_central()
        if not r then die(err, 1) end
        line("fingerprint", r.fingerprint)
        line("org", tostring(r.org_name) .. " (" .. tostring(r.org_scope) .. ")")
    elseif sub == "pair" then
        local r, err = client.pair({})
        if not r then die(err, 1) end
        line("central", r.central_fingerprint .. " (pinned)")
        line("identity", r.identity)
        line("device", r.device_fingerprint)
        if r.status == "approved" then
            line("status", "approved — run: memo org sync")
            return
        end
        line("status", "pending — the org admin must approve this device")
        line("code", r.code)
        io.write("\nRead this code to your org admin; they approve it with:\n"
            .. "  memo org devs approve " .. r.code .. "\n")
        local wait = tonumber(flags.wait)
        if not wait or wait <= 0 then
            io.write("Then run: memo org sync\n")
            return
        end
        io.write(("Waiting up to %ds for the approval …\n"):format(wait))
        io.stdout:flush()
        local socket = require("socket")
        local deadline = socket.gettime() + wait
        local last_err
        while socket.gettime() < deadline do
            socket.sleep(math.min(5, math.max(0, deadline - socket.gettime())))
            local st, serr = client.pair_status()
            if st == "approved" then line("status", "approved — run: memo org sync"); return end
            if st == "removed" or st == "unknown" then die("the central no longer has this pairing request — run: memo org pair", 1) end
            last_err = (st == nil) and serr or nil   -- a failed check is not "still pending"
        end
        if last_err then
            die("could not check the approval — " .. tostring(last_err)
                .. ". Once the central is reachable (and the admin approved the code), run: memo org sync", 1)
        end
        die("not approved yet — once the org admin approves the code, run: memo org sync", 1)
    elseif sub == "status" then
        local s = client.status()
        local url = s.org_url and require("luamemo.util").redact_url(s.org_url) or "-"   -- never print credentials
        line("role", s.role); line("central", url); line("org scope", s.org_scope or "not synced yet")
        line("pinned key", s.central_fingerprint or "none — MEMO_ORG_FINGERPRINT not set")
        line("device key", s.device_fingerprint or "none yet — run: memo org pair")
        line("identity", s.identity or ("unresolved — " .. tostring(s.identity_error)))
        line("share", s.share)
        if s.org_scope then
            line("replica", (s.replica_rows or 0) .. " org memories (read-only)")
            line("last pull", tostring(s.last_pull_at or "never") .. (s.last_pull_ok == false and " (failed)" or ""))
            line("last push", tostring(s.last_push_at or "never"))
            if s.last_error then line("last error", s.last_error) end
            local n = {}
            for _, r in ipairs(require("luamemo.federation.proposals").list(s.org_scope)) do
                n[r.status] = (n[r.status] or 0) + 1
            end
            local mode = (s.share == "signals" and "off (signals)") or (cfg.org_propose == false and "off")
                or "on (filtered, approved by the org admin)"
            line("proposals", ("%s — %d pending, %d approved, %d known, %d rejected"):format(mode, n.pending or 0,
                n.approved or 0, n.known or 0, (n.rejected or 0) + (n.refused or 0)))
        end
    elseif sub == "pull" then
        local s, perr = client.pull({ full = flags.full })
        if not s then die(perr, 1) end
        print_pull(s)
    elseif sub == "push" then
        local s, perr = client.push({})
        if not s then die(perr, 1) end
        print_push(s)
    elseif sub == "sync" then
        local s, perr = client.sync({ full = flags.full })
        if not s then die(perr, 1) end
        print_pull(s.pull)
        if s.push then print_push(s.push) else line("push", "failed — " .. tostring(s.push_error)) end
    elseif sub == "proposals" then
        -- Project knowledge this instance proposes to the org (filtered; the org admin approves).
        local props = require("luamemo.federation.proposals")
        local scope = client.org_scope()
        if not scope then die("not synced yet — run: memo org sync", 1) end
        local action = pos[1] or "list"
        if action == "list" then
            local rows = props.list(scope)
            if #rows == 0 then io.write("nothing proposed yet (see: memo org proposals candidates --explain)\n") end
            for _, r in ipairs(rows) do
                io.write(("%-11s #%-6d %s%s\n"):format(r.status, tonumber(r.memory_id), r.title,
                    r.org_memory_id and ("  → org #" .. tonumber(r.org_memory_id)) or ""))
            end
        elseif action == "candidates" then
            local explain = flags.explain == true
            if cfg.org_share == "signals" then line("note", "share=signals — nothing is proposed (no text leaves this machine)") end
            if cfg.org_propose == false then line("note", "MEMO_ORG_PROPOSE is off — nothing is proposed") end
            local list, skipped = props.candidates(scope, { explain = explain })
            if #list == 0 then io.write("no candidates\n") end
            for _, c in ipairs(list) do
                io.write(("%.2f  #%-6d [%s] %s%s\n        grounded in: %s\n"):format(c.score, c.memory_id, c.project,
                    c.title, c.update_of and ("  (update of org #" .. c.update_of .. ")") or "",
                    table.concat(c.grounding, ", ")))
            end
            if explain then
                for _, s in ipairs(skipped) do io.write(("skip  #%-6d %s — %s\n"):format(s.id, s.title, s.reason)) end
            end
        elseif action == "withdraw" then
            local ok, err = props.withdraw(pos[2])
            if not ok then die(err, 1) end
            line("withdrawn", "#" .. pos[2] .. " (the central hears it with the next push)")
        elseif action == "private" or action == "public" then
            local ok, err = props.set_private(pos[2], action == "private")
            if not ok then die(err, 1) end
            line(action, "#" .. pos[2] .. (action == "private" and " — never proposed" or " — may be proposed"))
        else
            die("usage: memo org proposals [list | candidates [--explain] | withdraw <id> | private <id> | public <id>]")
        end
    else
        die(("'%s' is not a dev subcommand (probe | pair | status | pull | push | sync | proposals | adopt | leave)")
            :format(tostring(sub)))
    end
end

-- ---------------------------------------------------------------------------
-- org central
-- ---------------------------------------------------------------------------
local function run_org(sub, argv)
    local db = require("luamemo.db")
    if sub == "status" then
        local central = require("luamemo.federation.central")
        local agg     = require("luamemo.federation.aggregate")
        local scope   = central.org_scope()
        local tiers = {}
        for _, r in ipairs(db.query("SELECT tier, count(*) AS n FROM lm_memories WHERE scope = ? "
            .. "GROUP BY tier ORDER BY tier", scope) or {}) do
            tiers[#tiers + 1] = ("t%d=%d"):format(tonumber(r.tier) or 0, tonumber(r.n) or 0)
        end
        local fb = agg.feedback_summary(scope)
        local keys = require("luamemo.federation.keys")
        local cpk = keys.public_key("central")
        local nd = { approved = 0, pending = 0 }
        for _, d in ipairs(require("luamemo.federation.devs").list()) do
            nd[d.status] = (nd[d.status] or 0) + 1
        end
        line("role", "org central"); line("org scope", scope)
        line("fingerprint", cpk and keys.fingerprint(cpk) or "no identity yet — memo serve / memo calibrate --role org")
        line("devices", ("%d approved, %d pending"):format(nd.approved, nd.pending))
        line("memories", #tiers > 0 and table.concat(tiers, " ") .. "  (t3 = directives)" or "none")
        line("feedback", ("%d event(s), %d retrieval(s) from %d dev(s)"):format(fb.events, fb.retrievals, fb.devs))
        if require("luamemo.util").table_exists("lm_org_proposals") then
            local pc = require("luamemo.federation.knowledge").counts()
            line("proposals", ("%d pending review, %d approved, %d rejected%s"):format(pc.pending or 0,
                pc.approved or 0, pc.rejected or 0,
                require("luamemo").config.org_proposals == false and " (not taking new ones)" or ""))
        end
        local ls = require("luamemo.learner_store")
        local v = ls.current_version(scope, "reranker")
        line("reranker", v and ("v" .. v .. " (pulled by devs)") or "none promoted")
        local run = db.first("SELECT decision, note, created_at FROM lm_promotion_runs WHERE scope = ? "
            .. "ORDER BY id DESC LIMIT 1", scope)
        if run then line("last run", ("%s %s%s"):format(require("luamemo.util").us_to_iso(run.created_at), run.decision,
            run.note and (" — " .. run.note) or "")) end
    elseif sub == "devs" then
        local devs = require("luamemo.federation.devs")
        local _, pos = parse(argv, {})
        local action = pos[1] or "pending"
        if action == "pending" or action == "list" then
            local rows = devs.list(action == "pending" and "pending" or nil)
            if #rows == 0 then io.write(action == "pending" and "no pending pairing requests\n" or "no devices\n") end
            for _, d in ipairs(rows) do
                io.write(("%-9s %-10s %-32s device %s  requested %s\n"):format(d.status,
                    d.status == "pending" and d.pairing_code or "", d.identity, d.fingerprint, tostring(d.requested_at)))
            end
            if action == "pending" and #rows > 0 then
                io.write("\nApprove one ONLY after the dev reads you the same code:  memo org devs approve <CODE>\n")
            end
        elseif action == "approve" then
            if not pos[2] then die("usage: memo org devs approve <CODE>  (the code the dev's `memo org pair` shows)") end
            local r, err = devs.approve(pos[2], os.getenv("USER"))
            if not r then die(err, 1) end
            line("approved", ("%s (device %s)"):format(r.identity, r.fingerprint))
        elseif action == "remove" then
            if not pos[2] then die("usage: memo org devs remove <user:email | CODE | FINGERPRINT>") end
            local n, err = devs.remove(pos[2], os.getenv("USER"))
            if not n then die(err, 1) end
            line("removed", n .. " device key(s) — their sessions ended")
        elseif action == "clear-pending" then
            line("cleared", devs.clear_pending() .. " pending request(s) — approved devices untouched; "
                .. "a real dev simply pairs again (memo org pair)")
        else
            die("usage: memo org devs [pending | list] | approve <CODE> | remove <ref> | clear-pending")
        end
    elseif sub == "directives" then
        local flags, pos = parse(argv, { source = "value", project = "value", ["dry-run"] = "bool",
                                         ["no-prune"] = "bool", ["allow-empty"] = "bool" })
        if #pos ~= 1 then
            die("usage: memo org directives <file-or-dir> [--source NAME] [--project NAME] [--dry-run] [--no-prune]")
        end
        local r, err = require("luamemo.federation.directives").sync(pos[1], {
            source = flags.source, project = flags.project, dry_run = flags["dry-run"],
            prune = not flags["no-prune"], allow_empty = flags["allow-empty"] })
        if not r then die(err, 1) end
        line("org scope", r.scope)
        line("source", ("%s (%d file%s, %d section%s)"):format(r.source, r.files, r.files == 1 and "" or "s",
            r.sections, r.sections == 1 and "" or "s"))
        line("project", r.project or "(org-wide)")
        line(r.dry_run and "would" or "directives", ("%d added, %d updated, %d unchanged, %d removed"):format(
            r.added, r.updated, r.unchanged, r.removed))
        if r.dry_run then
            for _, p in ipairs(r.plan) do io.write(("  %-7s %s  (%s)\n"):format(p.action, p.title, p.key)) end
        end
        for _, e in ipairs(r.errors) do io.write("  error: " .. e .. "\n") end
        if r.prune_skipped then line("note", r.prune_skipped) end
        if #r.errors > 0 then os.exit(1) end
    elseif sub == "aggregate" then
        local flags = parse(argv, { ["dry-run"] = "bool", ["min-samples"] = "value" })
        local r, err = require("luamemo.federation.aggregate").run({
            dry_run = flags["dry-run"], min_samples = tonumber(flags["min-samples"]) })
        if not r then die(err, 1) end
        line("org scope", r.scope)
        line("feedback", ("%d event(s), %d retrieval(s) from %d dev(s)"):format(
            r.feedback.events, r.feedback.retrievals, r.feedback.devs))
        local d = r.digest
        if d then
            line("digest", ("%d processed, %d → tier 2, %d deleted%s"):format(d.processed or 0, d.promoted2 or 0,
                d.deleted or 0, (d.errors and #d.errors > 0) and (" (" .. #d.errors .. " error(s))") or ""))
        end
        local p = r.promotion or {}
        line("reranker", tostring(p.decision) .. (p.version and (" v" .. p.version) or "")
            .. (p.reason and (" — " .. p.reason) or ""))
        for _, g in ipairs(p.gates or {}) do
            line("gate " .. g.name, (g.pass and "pass" or "FAIL") .. (g.info and (" — " .. g.info) or ""))
        end
    elseif sub == "review" then
        -- Knowledge proposals from devs. The decision is the admin's.
        local k = require("luamemo.federation.knowledge")
        local flags, pos = parse(argv, { status = "value", limit = "value", top = "value", supersedes = "value",
                                         reason = "value" })
        local action = pos[1] or "list"
        local by = os.getenv("USER")
        local function names(v)
            local out = {}
            for _, p in ipairs(type(v) == "table" and v or (require("luamemo.json").decode(v or "[]") or {})) do
                out[#out + 1] = p.identity
            end
            return out
        end
        if action == "list" then
            local rows = k.list({ status = flags.status or "pending", limit = flags.limit })
            if #rows == 0 then io.write(("no %s proposals\n"):format(flags.status or "pending")) end
            for _, r in ipairs(rows) do
                io.write(("#%-5d %.2f×%d  [%s] %s%s\n"):format(tonumber(r.id), tonumber(r.score) or 0,
                    tonumber(r.support) or 1, r.project or "org-wide", r.title,
                    r.update_of and ("  (updates org #" .. tonumber(r.update_of) .. ")") or ""))
            end
            if #rows > 0 and (flags.status or "pending") == "pending" then
                io.write("\nmemo org review show <id> · approve <id> | --top N · reject <id> [--reason …]\n")
            end
        elseif action == "show" then
            local r = k.get(pos[2])
            if not r then die("no proposal " .. tostring(pos[2]), 1) end
            line("proposal", "#" .. r.id .. " (" .. r.status .. ")")
            line("project", r.project or "org-wide")
            line("kind", r.kind)
            line("title", r.title)
            line("score", ("%.2f × %d dev(s): %s"):format(tonumber(r.score) or 0, tonumber(r.support) or 1,
                table.concat(names(r.proposers), ", ")))
            local g = type(r.grounding) == "table" and r.grounding or (require("luamemo.json").decode(r.grounding or "[]") or {})
            line("grounded in", table.concat(g, ", "))
            if r.update_of then line("updates", "org memory #" .. tonumber(r.update_of)) end
            if r.memory_id then line("org memory", "#" .. tonumber(r.memory_id)) end
            if r.reason then line("reason", r.reason) end
            io.write("\n" .. r.body .. "\n")
        elseif action == "approve" then
            if flags.top then
                for _, a in ipairs(k.approve_top(tonumber(flags.top) or 1, by)) do
                    line("#" .. a.id, a.memory and ("approved → org memory #" .. a.memory) or ("failed — " .. tostring(a.error)))
                end
            else
                if not pos[2] then die("usage: memo org review approve <id> [--supersedes <org memory id>] | --top N") end
                local mid, err = k.approve(pos[2], by, { supersedes = flags.supersedes })
                if not mid then die(err, 1) end
                line("approved", ("#%s → org memory #%d (tier 1, decays unless used)"):format(pos[2], mid))
            end
        elseif action == "reject" then
            if not pos[2] then die("usage: memo org review reject <id> [--reason TEXT]") end
            local ok, err = k.reject(pos[2], by, flags.reason)
            if not ok then die(err, 1) end
            line("rejected", "#" .. pos[2] .. " (the same content won't come back unless it changes)")
        elseif action == "remove" then
            if not pos[2] then die("usage: memo org review remove <org memory id>") end
            local ok, err = k.remove(pos[2], by)
            if not ok then die(err, 1) end
            line("removed", "org memory #" .. pos[2] .. " (leaves devs' replicas with their next pull)")
        else
            die("usage: memo org review [list [--status S]] | show <id> | approve <id> | approve --top N | "
                .. "reject <id> [--reason …] | remove <org memory id>")
        end
    else
        die(("'%s' is not an org-central subcommand (status | devs | review | directives | aggregate)"):format(tostring(sub)))
    end
end

function M.run(argv)
    local sub = argv[1]
    if not sub or sub == "-h" or sub == "--help" or sub == "help" then io.write(USAGE); return end

    local luamemo = require("luamemo.cli._common").setup_or_die(die, { prefix = "setup failed: ", code = 2 })
    local role = require("luamemo.federation.policy").role()
    if role == "dev" then return run_dev(sub, argv) end
    if role == "org" then return run_org(sub, argv) end
    die("this instance is not federated — a dev sets MEMO_ORG_URL + MEMO_ORG_FINGERPRINT "
        .. "(memo calibrate --org-url …); an org central sets MEMO_ROLE=org + MEMO_ORG_NAME")
end

return M
