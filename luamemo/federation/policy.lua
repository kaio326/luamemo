-- luamemo.federation.policy
-- Write policy for federated (`org:`) scopes. Pure decisions, no I/O: every
-- code path that mutates memory rows asks this module first.
--
-- Roles (config `role`, or implied `dev` when `org_url` is set):
--   solo — no federation. Every check below is a no-op (zero behaviour change).
--   dev  — `org:` scopes on this instance are a READ-ONLY replica of the central
--          org's memory; only the sync writer (replica capability) may change them.
--   org  — this instance IS the org central. `org:` scopes are protected: the core
--          tier (3) holds the org's directives and can only be written by directive
--          ingest (directive capability); every other write or feedback effect on an
--          org scope is capped at tier 2, and directive rows are immutable to them.
--
-- Capabilities are unforgeable: private sentinel tables compared by identity.
-- Nothing that arrives as JSON (MCP tool args, HTTP bodies, CLI input) can equal
-- one, so remote callers can never claim them. They are handed only to the
-- in-process sync writer / directive ingest.

local M = {}

local ROLES = { solo = true, dev = true, org = true }
local SHARE = { triples = true, signals = true }

local _role = "solo"

local CAPS = {
    replica   = setmetatable({}, { __tostring = function() return "capability<replica>" end }),
    directive = setmetatable({}, { __tostring = function() return "capability<directive>" end }),
}

local REPLICA_MSG = "%s is a read-only replica of the org's memory on this instance "
    .. "(role=dev) — make changes on the org's central instance"
local DIRECTIVE_MSG = "tier-3 org directives in %s are read-only — change them with "
    .. "`memo org directives` on the org's central instance"

--- Resolve + validate the federation config. Raises on invalid values so a
--- misconfigured instance fails at setup, not at the first write.
function M.configure(cfg)
    cfg = cfg or {}
    local role = cfg.role
    if role == nil or role == "" then
        role = (cfg.org_url and cfg.org_url ~= "") and "dev" or "solo"
    end
    if not ROLES[role] then
        error(("setup(): role must be 'solo', 'dev' or 'org' (got %q)"):format(tostring(role)))
    end
    if role == "dev" and not (cfg.org_url and cfg.org_url ~= "") then
        error("setup(): role 'dev' requires org_url (MEMO_ORG_URL) — the org's central instance")
    end
    if role == "org" and not M.valid_org_name(cfg.org_name) then
        error("setup(): role 'org' requires org_name (MEMO_ORG_NAME) — letters, digits, . _ - "
            .. "(the org scope becomes org:<org_name>)")
    end
    if cfg.org_share ~= nil and not SHARE[cfg.org_share] then
        error(("setup(): org_share must be 'triples' or 'signals' (got %q)"):format(tostring(cfg.org_share)))
    end
    _role = role
    return role
end

function M.valid_org_name(name)
    return type(name) == "string" and name:match("^[%w][%w%._%-]*$") ~= nil and #name <= 64
end

function M.role()   return _role end
function M.active() return _role ~= "solo" end

--- Internal: the sentinel for a capability ("replica" | "directive").
--- Only the sync writer and directive ingest may call this.
function M.capability(name)
    local c = CAPS[name]
    if not c then error("unknown capability: " .. tostring(name)) end
    return c
end

local function has(cap, name) return cap ~= nil and rawequal(cap, CAPS[name]) end

function M.is_org_scope(scope)
    return type(scope) == "string" and scope:sub(1, 4) == "org:"
end

--- dev: an `org:` scope here is a read-only replica.
function M.replica(scope)   return _role == "dev" and M.is_org_scope(scope) end
--- org: an `org:` scope here is protected (core tier = directives only).
function M.protected(scope) return _role == "org" and M.is_org_scope(scope) end

--- Gate for creating a row in `scope` (insert, or moving a row into it).
function M.check_insert(scope, cap)
    if M.replica(scope) and not has(cap, "replica") then
        return nil, REPLICA_MSG:format(scope)
    end
    return true
end

--- Gate for changing or deleting an existing row (`scope`, `tier` = its values).
function M.check_mutation(scope, tier, cap)
    if M.replica(scope) and not has(cap, "replica") then
        return nil, REPLICA_MSG:format(scope)
    end
    if M.protected(scope) and tonumber(tier) == 3 and not has(cap, "directive") then
        return nil, DIRECTIVE_MSG:format(scope)
    end
    return true
end

--- The tier of a write that names none: `derived` (from importance) — except a
--- directive (the directive capability, on a protected scope), which IS the
--- core tier: a directive must never land somewhere unprotected.
function M.default_tier(scope, cap, derived)
    if M.protected(scope) and has(cap, "directive") then return 3 end
    return derived
end

--- Highest tier a write to `scope` may land at: 2 on protected scopes unless the
--- caller holds the directive capability.
function M.cap_tier(scope, tier, cap)
    tier = tonumber(tier) or 1
    if tier > 2 and M.protected(scope) and not has(cap, "directive") then return 2 end
    return tier
end

--- May feedback / maintenance change this existing row's importance or tier?
--- No on dev replicas (they mirror the central); no for directives on the central.
function M.feedback_may_mutate(scope, tier)
    if M.replica(scope) then return false end
    if M.protected(scope) and tonumber(tier) == 3 then return false end
    return true
end

--- SQL predicate for bulk maintenance (decay, summarization, bulk deletes) that
--- excludes rows this role must not touch; nil when nothing is excluded.
--- With the matching capability the rows are in bounds again. On the central,
--- approved org knowledge (metadata.lm_org_knowledge) is out of bounds too:
--- decay makes it rank lower but never removes it — only the admin does
--- (`memo org review remove`), one row at a time.
function M.maintenance_exclusion_sql(cap)
    if _role == "dev" and not has(cap, "replica") then
        return "scope NOT GLOB 'org:*'"
    end
    if _role == "org" and not has(cap, "directive") then
        return "NOT (scope GLOB 'org:*' AND (tier = 3 OR json_type(metadata, '$.lm_org_knowledge') IS NOT NULL))"
    end
    return nil
end

return M
