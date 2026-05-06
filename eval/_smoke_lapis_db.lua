-- Minimal lapis.db shim for smoke-testing luamemo without a full
-- Lapis install. Wraps pgmoon. NOT for production. Only loaded by
-- eval/smoke harnesses that set package.path explicitly.

local pgmoon = require("pgmoon")
local cjson  = require("cjson.safe")

local M = {}
local conn = nil

function M._connect(opts)
    local pg = pgmoon.new(opts)
    local ok, err = pg:connect()
    if not ok then error("pg connect: " .. tostring(err)) end
    conn = pg
end

function M._disconnect() if conn then conn:disconnect(); conn = nil end end

function M.escape_identifier(s) return '"' .. tostring(s):gsub('"', '""') .. '"' end

function M.escape_literal(v)
    if v == nil then return "NULL" end
    if type(v) == "number" then return tostring(v) end
    if type(v) == "boolean" then return v and "TRUE" or "FALSE" end
    return "'" .. tostring(v):gsub("'", "''") .. "'"
end

function M.interpolate_query(sql, ...)
    local args = { ... }
    local i = 0
    return (sql:gsub("%?", function()
        i = i + 1
        return M.escape_literal(args[i])
    end))
end

function M.query(sql, ...)
    if select("#", ...) > 0 then sql = M.interpolate_query(sql, ...) end
    local res, err = conn:query(sql)
    if not res then return nil, err end
    return res
end

function M.delete(tbl, where)
    local conds = {}
    for k, v in pairs(where or {}) do
        table.insert(conds, M.escape_identifier(k) .. " = " .. M.escape_literal(v))
    end
    local sql = "DELETE FROM " .. M.escape_identifier(tbl)
    if #conds > 0 then sql = sql .. " WHERE " .. table.concat(conds, " AND ") end
    return M.query(sql)
end

function M.update(tbl, fields, where)
    local sets = {}
    for k, v in pairs(fields) do
        table.insert(sets, M.escape_identifier(k) .. " = " .. M.escape_literal(v))
    end
    local sql = "UPDATE " .. M.escape_identifier(tbl) .. " SET " .. table.concat(sets, ", ")
    if where then
        local conds = {}
        for k, v in pairs(where) do
            table.insert(conds, M.escape_identifier(k) .. " = " .. M.escape_literal(v))
        end
        sql = sql .. " WHERE " .. table.concat(conds, " AND ")
    end
    return M.query(sql)
end

return M
