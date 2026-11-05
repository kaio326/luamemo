-- rates: the price list per plan.
local M = {}

local TABLE = { default = { api = 0.002, storage = 0.1 }, pro = { api = 0.001, storage = 0.05 } }

--- The unit price of a kind of event under a plan (the default plan when missing).
function M.lookup(plan, kind)
    local p = TABLE[plan] or TABLE.default
    return p[kind] or 0
end

return M
