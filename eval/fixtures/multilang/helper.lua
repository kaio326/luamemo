-- A small Lua module in the mixed-language fixture.
local M = {}

-- Greet someone by name.
function M.greet(name)
    return "hi " .. name
end

local function _internal()
    return true
end

return M
