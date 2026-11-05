-- billing: turns usage events into invoice lines.
local rates = require("lib.rates")
local queue = require("lib.queue")

local M = {}

--- The price of one usage event under a customer's plan.
function M.price(event, plan)
    return rates.lookup(plan, event.kind) * event.units
end

--- Invoice every pending event of a customer; returns the total.
function M.invoice(customer)
    local total = 0
    for _, event in ipairs(queue.pending(customer)) do
        total = total + M.price(event, customer.plan)
    end
    return total
end

return M
