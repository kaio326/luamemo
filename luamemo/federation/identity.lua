-- luamemo.federation.identity
-- Dev identity for federation = the git author e-mail, as a `user:` scope id.
-- No login / user table: the org authenticates the device KEY (paired and
-- approved by the admin); this identity is what the dev claims at pairing and
-- what the approved key's feedback is attributed to.
--
--   identity.resolve(cfg) → "user:<email>" | nil, err
--     1. cfg.org_identity (MEMO_ORG_IDENTITY) — explicit override
--     2. `git config user.email` (run in cfg.root or the current directory)

local M = {}

local trim = require("luamemo.util").trim

-- A plausible e-mail: one @, no whitespace / quotes / control chars.
local function valid_email(e)
    return type(e) == "string" and #e <= 254 and e:match("^[^%s@\"'<>]+@[^%s@\"'<>]+$") ~= nil
end

local shell_quote = require("luamemo.util").shell_quote

local function git_email(root)
    return trim(require("luamemo.util").sh("git " .. (root and ("-C " .. shell_quote(root) .. " ") or "")
        .. "config user.email"))
end

function M.resolve(cfg)
    cfg = cfg or {}
    local explicit = cfg.org_identity
    if explicit and explicit ~= "" then
        local e = trim(explicit):gsub("^user:", "")
        if not valid_email(e) then
            return nil, ("org_identity %q is not an e-mail address"):format(explicit)
        end
        return "user:" .. e:lower()
    end
    local e = git_email(cfg.root)
    if e and e ~= "" then
        if not valid_email(e) then
            return nil, ("git user.email %q is not an e-mail address"):format(e)
        end
        return "user:" .. e:lower()
    end
    return nil, "no dev identity: set MEMO_ORG_IDENTITY or `git config user.email`"
end

--- "user:<email>" with a plausible e-mail.
function M.valid(identity)
    return type(identity) == "string" and identity:sub(1, 5) == "user:" and valid_email(identity:sub(6))
end

M._valid_email = valid_email   -- exposed for tests

return M
