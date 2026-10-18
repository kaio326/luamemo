-- luamemo.federation.registry
-- Per-user record of the orgs this machine belongs to, so that every project
-- of one org shares ONE local database (the org database) and the last project
-- leaving an org cleans its data up. Solo projects are not recorded here.
--
--   registry.get(fingerprint)                        → entry | nil
--   registry.link(fingerprint, fields, project, scope) → entry
--       fields: url, db, embed, embed_sig, org_scope (only the given ones
--       are updated; db + embed + embed_sig are set when the org is first
--       recorded — the first project's database and the embedder it was built
--       with: every project joining it must embed the same way)
--   registry.unlink(fingerprint, project)            → remaining project count
--   registry.remove(fingerprint)
--   registry.list()                                  → { entry, … }
--
-- entry = { fingerprint, url, org_scope, db (the database's name or path),
--           embed = { MEMO_EMBED… = value }, embed_sig,
--           projects = { [abs path] = scope } }  — projects = the ones
--           USING the org database (a project that kept its own isn't counted)
-- File: <federation keyring dir>/orgs.json, mode 0600. Keyed by the central's
-- key fingerprint: the org's identity, not its address (an address change is
-- just an update).

local json = require("luamemo.json")
local keys = require("luamemo.federation.keys")

local M = {}

local function path()
    local dir = keys.dir()
    return dir and (dir .. "/orgs.json") or nil
end

local function load()
    local p = path()
    local f = p and io.open(p, "r")
    if not f then return { orgs = {} } end
    local data = json.decode(f:read("*a") or "")
    f:close()
    if type(data) ~= "table" or type(data.orgs) ~= "table" then return { orgs = {} } end
    return data
end

local function save(data)
    local p = path()
    if not p then return nil, "registry: no keyring directory" end
    local util = require("luamemo.util")
    util.private_dir(p:match("^(.*)/[^/]+$"), true)   -- the keyring dir, 0700
    return util.write_private(p, json.encode(data))   -- 0600, atomic (no readable window)
end

local function norm(fp) return keys.normalize_code(fp) end

function M.get(fingerprint)
    return load().orgs[norm(fingerprint)]
end

function M.list()
    local out = {}
    for _, e in pairs(load().orgs) do out[#out + 1] = e end
    return out
end

function M.link(fingerprint, fields, project, scope)
    local data = load()
    local k = norm(fingerprint)
    local e = data.orgs[k] or { fingerprint = fingerprint, projects = {} }
    fields = fields or {}
    if fields.url then e.url = fields.url end
    if fields.org_scope then e.org_scope = fields.org_scope end
    if fields.db and not e.db then
        e.db, e.embed, e.embed_sig = fields.db, fields.embed, fields.embed_sig
    end
    if type(e.projects) ~= "table" then e.projects = {} end
    if project then e.projects[project] = scope or true end
    data.orgs[k] = e
    local ok, err = save(data)
    if not ok then return nil, err end
    return e
end

function M.unlink(fingerprint, project)
    local data = load()
    local e = data.orgs[norm(fingerprint)]
    if not e then return 0 end
    if type(e.projects) == "table" then e.projects[project] = nil end
    save(data)
    local n = 0
    for _ in pairs(e.projects or {}) do n = n + 1 end
    return n
end

function M.remove(fingerprint)
    local data = load()
    data.orgs[norm(fingerprint)] = nil
    return save(data)
end

return M
