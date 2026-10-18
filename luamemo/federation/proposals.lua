-- luamemo.federation.proposals
-- Knowledge proposals, dev side (+ the pure rules the central re-checks).
--
-- A dev never pushes its memories wholesale — a dev's personal way of coding
-- must not be imposed on everyone. What IS shared is project knowledge ("this
-- endpoint is called this way"), and only when a deterministic filter (no LLM)
-- says so; the org admin then approves or rejects it on the central.
--
-- A memory is a candidate when ALL hold:
--   * it's the dev's project memory: a `repo:` scope, tier >= 1, kind fact /
--     decision — never preferences, plans, snippets, diary / session notes,
--     pattern-extracted habits (metadata.is_synthetic) or anything marked
--     private (metadata.private);
--   * usage-proven: consolidated to tier 2, or positively reinforced (praise /
--     direct command / miss) AND retrieved (or missed = needed);
--   * no secret-looking content (credential patterns — never proposed);
--   * nothing personal: no first-person preference / style language;
--   * grounded in the code: it names a file or symbol that exists in that
--     project's code index (knowledge ABOUT the repo, not about the dev);
--   * not already in the org: no org row with the same content, nor a
--     near-identical one (cosine distance < NEAR_DUP).
-- Score = grounding + usage + tier. Sent only in `triples` mode, never in
-- `signals` ("no text leaves my machine"), and switched off by org_propose=false.
--
-- Bookkeeping (lm_org_proposed): what was sent from which memory, the central's
-- answer, and — once approved / already known — the org memory it is linked to:
-- the proposer's use of its own memory then counts for the org copy, and a
-- later substantive change of it is re-proposed as an UPDATE of that org memory.
-- A rejection is final until the content changes.
--
--   proposals.content_hash(title, body) / looks_secret(text) / looks_personal(title, body)
--   proposals.refs(text) → { ref, … }                       (pure)
--   proposals.candidates(org_scope, {limit, explain}) → list[, skipped]
--   proposals.outgoing(org_scope, instance_id) → batch | nil
--   proposals.record(org_scope, batch, result)
--   proposals.linked(org_scope) → { [memory id] = org memory id }
--   proposals.list(org_scope) / withdraw(memory_id) / set_private(memory_id, on)

local db   = require("luamemo.db")
local util = require("luamemo.util")

local M = {}

M.MAX_PER_PUSH = 20     -- proposals per push
M.MAX_CHECK    = 50     -- status checks / withdrawals per push (the central's per-list bound)
M.SCAN_LIMIT   = 500    -- memories examined per push
M.MAX_REFS     = 30     -- code references looked up per memory
M.NEAR_DUP     = 0.08   -- cosine distance under which an org row already covers it

local hex = util.to_hex

-- ---------------------------------------------------------------------------
-- Pure rules (shared with the central)
-- ---------------------------------------------------------------------------

local function norm(s) return ((tostring(s or ""):lower():gsub("%s+", " ")):match("^ ?(.-) ?$")) end

--- Content identity of a piece of knowledge (case / whitespace-insensitive).
function M.content_hash(title, body)
    return hex(require("luamemo.native.sodium").sha256(norm(title) .. "\n" .. norm(body))):sub(1, 32)
end

-- Credential-looking content: the key formats the scrubber knows (util.has_token — one
-- list for both), `password = …` style assignments, URLs with credentials, long
-- mixed-case tokens. Conservative by design — a false positive only means a proposal
-- isn't made (the scrubber, which changes what is stored, flags far less).
local TOKEN_PATTERNS = {
    "://[^/%s:@]+:[^/%s@]+@",                                -- URL with user:password@
    -- What the scrubber left of one (memories are stored scrubbed — util.redact_secrets):
    -- a memory that held a credential is still never proposed.
    "%[redacted%]", "//%*%*%*@", "[?&][%w_%-%.]+=%*%*%*",
}
local SECRET_WORDS = { "password", "passwd", "pwd", "secret", "token", "api_key", "api-key", "apikey",
                       "access_key", "access-key", "private_key", "private-key", "client_secret",
                       "connection_string", "connectionstring", "credential" }

function M.looks_secret(text)
    if type(text) ~= "string" or text == "" then return false end
    if util.has_token(text) then return true end
    for _, p in ipairs(TOKEN_PATTERNS) do
        if text:find(p) then return true end
    end
    -- `password = hunter2` / `api_key: "…"` — an assigned value that isn't a plain
    -- word ("the token: passed in the header" is fine).
    local l = text:lower()   -- same byte offsets as `text`
    for _, w in ipairs(SECRET_WORDS) do
        local s = 1
        while true do
            local a, b = l:find(w, s, true)
            if not a then break end
            local v = text:sub(b + 1):match("^[%s\"']*[:=][%s\"']*([^%s\"'<>,;]+)")
            if v and #v >= 6 and (v:find("%d") or v:find("%u") or v:find("[_%-%./%+=$]")) then return true end
            s = b + 1
        end
    end
    -- A long token mixing upper case, lower case and digits (keys, not hashes).
    for run in text:gmatch("[%w%+/=_%-]+") do
        if #run >= 32 and run:find("%u") and run:find("%l") and run:find("%d") then return true end
    end
    return false
end

local PERSONAL = { "[^%a]i prefer", "[^%a]i like", "[^%a]i always", "[^%a]i usually", "[^%a]i tend",
                   "[^%a]i never", "[^%a]i'd rather", "[^%a]i would rather", "[^%a]my style",
                   "[^%a]my preference", "[^%a]my habit", "[^%a]personally", "user prefers",
                   "user likes", "user has mentioned" }
local STYLE_TOPIC = { "indent", "tabs", "spaces", "quotes", "semicolon", "trailing comma", "naming",
                      "formatting", "code style", "camelcase", "snake_case", "pascalcase", "line length" }
local STYLE_VERB  = { "prefer", "[^%a]likes?[^%a]", "[^%a]rather[^%a]", "always use", "never use", "[^%a]style" }

--- First-person preference / habit language, or naming / formatting taste.
function M.looks_personal(title, body)
    local text = (title or "") .. ". " .. (body or "")
    local ok, found = pcall(function() return #require("luamemo.patterns").extract(text) > 0 end)
    if ok and found then return true end
    local l = " " .. text:lower() .. " "
    for _, p in ipairs(PERSONAL) do if l:find(p) then return true end end
    for _, t in ipairs(STYLE_TOPIC) do
        if l:find(t, 1, true) then
            for _, v in ipairs(STYLE_VERB) do if l:find(v) then return true end end
        end
    end
    return false
end

local EXT = {}
for e in ("lua js mjs cjs ts tsx jsx cs csproj razor cshtml vb fs py go rb java kt kts swift rs c h cc cpp "
    .. "hpp m php sql json yaml yml toml xml html htm css scss sass less vue svelte sh ps1 proto graphql gql "
    .. "tf md"):gmatch("%S+") do EXT[e] = true end

--- Code references a text names: backticked spans, paths, file names with a
--- code extension, qualified names (a.b, A::b), snake_case / camelCase
--- identifiers, calls `name(`. Deduplicated, at most MAX_REFS.
function M.refs(text)
    local out, seen = {}, {}
    local function add(t)
        t = t:gsub("^[%.:/]+", ""):gsub("[%.:,;/]+$", "")
        if #t >= 3 and #t <= 200 and not seen[t] and #out < M.MAX_REFS then
            seen[t] = true; out[#out + 1] = t
        end
    end
    text = tostring(text or "")
    for span in text:gmatch("`([^`\n]+)`") do
        local s = span:gsub("%(.*$", "")
        if not s:find("%s") then add(s) end
    end
    for p in text:gmatch("[%w_%-%.]*[%w_%-]/[%w_%-%./]+") do add(p) end
    for name, ext in text:gmatch("([%w_%-]+)%.(%a+)") do
        if EXT[ext:lower()] then add(name .. "." .. ext) end
    end
    for q in text:gmatch("[%a_][%w_]*[%.:]+[%a_][%w_%.:]*") do
        local last = q:match("([%a_][%w_]*)$")
        if last and not EXT[last:lower()] then add(q) end
    end
    for id in text:gmatch("[%a_][%w_]*") do
        if (#id >= 4 and id:find("%w_%w")) or id:find("%l%u") then add(id) end
    end
    for id in text:gmatch("([%a_][%w_]*)%(") do add(id) end
    return out
end

--- The names a project's code index knows — every file path and symbol name
--- with each of its suffixes ("src/api/users.lua", "api/users.lua",
--- "users.lua"; "app.users.create", "users.create", "create"). One query per
--- project; grounding is then set lookups.
function M.index_names(project)
    local set = {}
    local function add(s, sep)
        if type(s) ~= "string" or s == "" then return end
        set[s] = true
        for i in s:gmatch("()" .. sep) do
            if i < #s then set[s:sub(i + 1)] = true end
        end
    end
    for _, r in ipairs(db.query("SELECT title, json_extract(metadata, '$.path') AS path FROM lm_memories "
        .. "WHERE scope = ? AND kind IN ('file', 'symbol')", "codeindex:" .. project) or {}) do
        add(r.title, "[%.:/]")
        add(r.path, "/")
    end
    return set
end

--- Which refs exist in the project's code index (files by path or path suffix,
--- symbols by qualified name or name suffix). → { matched ref, … }
function M.ground(project, refs, names)
    if type(project) ~= "string" or project == "" or #refs == 0 then return {} end
    names = names or M.index_names(project)
    local out = {}
    for _, r in ipairs(refs) do if names[r] then out[#out + 1] = r end end
    return out
end

-- ---------------------------------------------------------------------------
-- Dev side
-- ---------------------------------------------------------------------------

local function has_table()
    return require("luamemo.util").table_exists("lm_org_proposed")
end

local function prev_state(org_scope)
    local out = {}
    for _, r in ipairs(db.query("SELECT memory_id, content_hash, status, org_memory_id FROM lm_org_proposed "
        .. "WHERE org_scope = ?", org_scope) or {}) do
        out[tonumber(r.memory_id)] = r
    end
    return out
end

--- Candidates for the next push, best first. opts.limit (default MAX_PER_PUSH),
--- opts.explain → also returns the examined-but-skipped memories with a reason.
function M.candidates(org_scope, opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or M.MAX_PER_PUSH
    local skipped = {}
    local function skip(r, why) if opts.explain then skipped[#skipped + 1] = { id = tonumber(r.id), title = r.title, reason = why } end end
    if not has_table() then return {}, skipped end
    -- Which projects may propose: opts.scopes / org_propose_scopes (repo: scopes),
    -- default every repo: scope in this database (the org's projects).
    local only = opts.scopes or require("luamemo").config.org_propose_scopes
    local scope_sql, scope_params = "m.scope GLOB 'repo:*'", {}
    if type(only) == "table" then
        for _, s in ipairs(only) do
            if type(s) == "string" and s:sub(1, 5) == "repo:" then scope_params[#scope_params + 1] = s end
        end
        scope_sql = #scope_params > 0 and ("m.scope IN (" .. db.placeholders(#scope_params) .. ")") or "0"
    end
    -- metadata flags compared as text, like Postgres's metadata->>'k' (JSON true → '1')
    local params = {}
    for _, s in ipairs(scope_params) do params[#params + 1] = s end
    params[#params + 1] = M.SCAN_LIMIT
    local rows = db.query("SELECT m.id, m.scope, m.kind, m.title, m.body, m.tier, "
        .. "(SELECT count(*) FROM lm_reinforcements r WHERE r.memory_id = m.id AND r.delta > 0 "
        .. " AND r.event_type IN ('praise', 'direct_command', 'miss')) AS pos, "
        .. "(SELECT count(*) FROM lm_reinforcements r WHERE r.memory_id = m.id AND r.event_type = 'miss') AS misses "
        .. "FROM lm_memories m WHERE " .. scope_sql .. " AND m.tier >= 1 AND m.kind IN ('fact', 'decision') "
        .. "AND m.importance > 0 "
        .. "AND coalesce(CAST(json_extract(m.metadata, '$.private') AS TEXT), '') NOT IN ('true', '1') "
        .. "AND coalesce(CAST(json_extract(m.metadata, '$.is_synthetic') AS TEXT), '') NOT IN ('true', '1') "
        .. "ORDER BY m.tier DESC, m.importance DESC, m.id LIMIT ?", unpack(params, 1, #params)) or {}

    -- Retrieved at least once (only needed for rows proven by reinforcement).
    local need = {}
    for _, r in ipairs(rows) do
        if tonumber(r.tier) < 2 and tonumber(r.pos) > 0 then need[#need + 1] = tonumber(r.id) end
    end
    local retrieved = {}
    if #need > 0 then
        for _, x in ipairs(db.query("SELECT DISTINCT memory_id AS c FROM lm_retrieval_candidates WHERE memory_id IN ("
            .. db.placeholders(#need) .. ")", unpack(need, 1, #need)) or {}) do
            retrieved[tonumber(x.c)] = true
        end
    end

    -- What the org already holds (content identity), and this dev's replica index.
    local org_hash = {}
    for _, o in ipairs(db.query("SELECT title, body FROM lm_memories WHERE scope = ?", org_scope) or {}) do
        org_hash[M.content_hash(o.title, o.body)] = true
    end
    local vectors = require("luamemo.vectors")
    local prev = prev_state(org_scope)

    -- Pass 1 — the cheap checks on every scanned row.
    local pre = {}
    for _, r in ipairs(rows) do
        local id, tier, pos = tonumber(r.id), tonumber(r.tier), tonumber(r.pos)
        local hash = M.content_hash(r.title, r.body)
        local p = prev[id]
        local update_of = p and (p.status == "approved" or p.status == "known") and tonumber(p.org_memory_id) or nil
        if p and p.content_hash == hash then
            skip(r, "already proposed (" .. p.status .. ")")
        elseif not (tier >= 2 or (pos > 0 and (retrieved[id] or tonumber(r.misses) > 0))) then
            skip(r, "not proven by use yet")
        elseif M.looks_secret(r.title .. "\n" .. r.body) then
            skip(r, "looks like it contains a secret")
        elseif M.looks_personal(r.title, r.body) then
            skip(r, "personal preference / style")
        elseif not update_of and org_hash[hash] then
            skip(r, "already in the org's memory")
        else
            pre[#pre + 1] = { r = r, id = id, hash = hash, update_of = update_of,
                usage = math.min(pos, 3) / 3 + (retrieved[id] and 0.25 or 0) + (tier >= 2 and 0.5 or 0) }
        end
    end
    table.sort(pre, function(a, b)
        if a.usage ~= b.usage then return a.usage > b.usage end
        return a.id < b.id
    end)

    -- Pass 2 — grounding (set lookups) and the vector near-duplicate scan, best
    -- first, only until there are enough candidates (all of them for --explain).
    local names = {}
    local want = opts.explain and math.huge or limit * 2
    local out = {}
    for _, c in ipairs(pre) do
        if #out >= want then break end
        local r = c.r
        local dup = false
        if not c.update_of then
            -- an org row within cosine distance NEAR_DUP already covers it (the org
            -- rows' stored vectors compared in place — none is copied into Lua)
            local mine = vectors.unpack(db.value("SELECT embedding FROM lm_memories WHERE id = ?", c.id))
            if mine then
                local q = vectors.query(mine)
                db.scan("SELECT embedding, emb_norm FROM lm_memories WHERE scope = ? AND embedding IS NOT NULL",
                    { org_scope }, function(o)
                        local ptr, bytes = o:blob_ptr(0)
                        if 1 - vectors.cosine_ptr(ptr, bytes, o:double(1), q) < M.NEAR_DUP then
                            dup = true
                            return false
                        end
                    end)
            end
        end
        if dup then
            skip(r, "already in the org's memory")
        else
            local project = require("luamemo.index").project_of(r.scope)
            names[project] = names[project] or M.index_names(project)
            local grounding = M.ground(project, M.refs(r.title .. "\n" .. r.body), names[project])
            if #grounding == 0 then
                skip(r, "names no file or symbol of the project's code index")
            else
                local score = math.min(#grounding, 3) / 3 + c.usage
                out[#out + 1] = { memory_id = c.id, project = project, kind = r.kind, title = r.title,
                    body = r.body, hash = c.hash, score = math.floor(score * 1000 + 0.5) / 1000,
                    grounding = grounding, update_of = c.update_of }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.memory_id < b.memory_id
    end)
    while #out > limit do out[#out] = nil end
    return out, skipped
end

--- The proposals batch for one push: new / changed candidates, pending ones to
--- check, withdrawals to send. nil when there's nothing to say.
function M.outgoing(org_scope, instance_id)
    if not has_table() then return nil end
    local batch = { propose = {}, check = {}, withdraw = {} }
    local ref = function(id) return ("%s:p:%d"):format(instance_id, id) end
    for _, c in ipairs(M.candidates(org_scope)) do
        batch.propose[#batch.propose + 1] = { ref = ref(c.memory_id), project = c.project, kind = c.kind,
            title = c.title, body = c.body, score = c.score, grounding = c.grounding, update_of = c.update_of,
            _hash = c.hash, _memory = c.memory_id }
    end
    -- At most MAX_CHECK of each per push (the central's per-list bound), the
    -- longest-unchecked first — a large backlog drains over several pushes.
    for _, st in ipairs({ "pending", "withdrawing" }) do
        local list = (st == "withdrawing") and batch.withdraw or batch.check
        for _, r in ipairs(db.query("SELECT memory_id FROM lm_org_proposed WHERE org_scope = ? AND status = ? "
            .. "ORDER BY checked_at NULLS FIRST, sent_at LIMIT ?", org_scope, st, M.MAX_CHECK) or {}) do
            list[#list + 1] = ref(tonumber(r.memory_id))
        end
    end
    if #batch.propose == 0 and #batch.check == 0 and #batch.withdraw == 0 then return nil end
    return batch
end

--- The wire form of a batch (bookkeeping fields stripped).
function M.wire(batch)
    local out = { propose = {}, check = batch.check, withdraw = batch.withdraw }
    for i, p in ipairs(batch.propose) do
        local w = {}
        for k, v in pairs(p) do if k:sub(1, 1) ~= "_" then w[k] = v end end
        out.propose[i] = w
    end
    return out
end

local STATUSES = { pending = true, approved = true, known = true, rejected = true, refused = true, withdrawn = true }

--- Store the central's answer. Returns counts by status.
function M.record(org_scope, batch, result)
    local counts = {}
    local sent = {}
    for _, p in ipairs(batch.propose or {}) do sent[p.ref] = p end
    for _, r in ipairs(type(result) == "table" and result.results or {}) do
        local mid = tonumber(tostring(r.ref or ""):match(":p:(%d+)$"))
        local st = STATUSES[r.status] and r.status or nil
        if mid and st then
            counts[st] = (counts[st] or 0) + 1
            local p = sent[r.ref]
            local pid = tonumber(r.proposal)
            local oid = tonumber(r.memory)
            local set = { "status = excluded.status", "checked_at = excluded.checked_at",
                          "proposal_id = coalesce(excluded.proposal_id, lm_org_proposed.proposal_id)",
                          "org_memory_id = coalesce(excluded.org_memory_id, lm_org_proposed.org_memory_id)" }
            if p then set[#set + 1] = "content_hash = excluded.content_hash"; set[#set + 1] = "sent_at = excluded.sent_at" end
            local now = util.now_us()
            db.run("INSERT INTO lm_org_proposed (memory_id, org_scope, content_hash, status, proposal_id, "
                .. "org_memory_id, sent_at, checked_at) SELECT ?, ?, ?, ?, ?, ?, ?, ? "
                .. "WHERE EXISTS (SELECT 1 FROM lm_memories WHERE id = ?) "
                .. "ON CONFLICT (memory_id, org_scope) DO UPDATE SET " .. table.concat(set, ", "),
                mid, org_scope, p and p._hash or "", st, pid, oid, now, now, mid)
        end
    end
    return counts
end

--- Source memory → the org memory it became (approved) or already was (known).
function M.linked(org_scope)
    local out = {}
    if not has_table() then return out end
    for _, r in ipairs(db.query("SELECT memory_id, org_memory_id FROM lm_org_proposed WHERE org_scope = ? "
        .. "AND status IN ('approved', 'known') AND org_memory_id IS NOT NULL", org_scope) or {}) do
        out[tonumber(r.memory_id)] = tonumber(r.org_memory_id)
    end
    return out
end

function M.list(org_scope)
    if not has_table() then return {} end
    local rows = db.query("SELECT p.memory_id, p.status, p.proposal_id, p.org_memory_id, p.sent_at, p.checked_at, "
        .. "m.title, m.scope FROM lm_org_proposed p JOIN lm_memories m ON m.id = p.memory_id "
        .. "WHERE p.org_scope = ? ORDER BY p.sent_at DESC", org_scope) or {}
    for _, r in ipairs(rows) do util.iso_fields(r, { "sent_at", "checked_at" }) end
    return rows
end

--- Withdraw a pending proposal (sent with the next push). → true | nil, err
function M.withdraw(memory_id)
    local id = tonumber(memory_id)
    if not id or not has_table() then return nil, "no such proposal" end
    local st = db.value("SELECT status FROM lm_org_proposed WHERE memory_id = ?", id)
    if not st then return nil, "memory " .. id .. " was never proposed" end
    if st == "approved" or st == "known" then
        return nil, "already part of the org's memory — only the org admin can remove it"
    end
    if st ~= "pending" then return nil, "not pending (" .. st .. ")" end
    db.run("UPDATE lm_org_proposed SET status = 'withdrawing' WHERE memory_id = ?", id)
    return true
end

--- Mark one of this dev's memories private (never proposed) or not. A pending
--- proposal of it is withdrawn. Doesn't restart its decay clock.
function M.set_private(memory_id, on)
    local id = tonumber(memory_id)
    if not id then return nil, "invalid memory id" end
    local scope = db.value("SELECT scope FROM lm_memories WHERE id = ?", id)
    if not scope then return nil, "no memory " .. id end
    if scope:sub(1, 4) == "org:" then return nil, "org memories aren't this dev's to mark" end
    -- The updated_at trigger touches a row unless the UPDATE sets it: +1 µs keeps
    -- the row's age (decay / temporal ranking) as it was.
    db.run("UPDATE lm_memories SET metadata = json_set(coalesce(metadata, '{}'), '$.private', json(?)), "
        .. "updated_at = updated_at + 1 WHERE id = ?", on and "true" or "false", id)
    if on and has_table() then
        db.run("UPDATE lm_org_proposed SET status = 'withdrawing' WHERE memory_id = ? AND status = 'pending'", id)
    end
    return true
end

return M
