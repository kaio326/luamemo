-- luamemo.util
-- Shared helpers used across multiple modules.

local M = {}

--- Truncate a string to n characters, appending a UTF-8 horizontal ellipsis
--- (U+2026) if the string was clipped.  Returns "" for non-string input.
function M.clip(s, n)
    if type(s) ~= "string" then return "" end
    if #s <= n then return s end
    return s:sub(1, n) .. "\xe2\x80\xa6"
end

--- Strip leading and trailing whitespace from a string.
--- Returns "" for non-string input.
function M.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Read a file and return its contents, or nil if the file cannot be opened.
function M.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

--- Coerce a value to boolean.
--- "true"/"1" → true, "false"/"0" → false, booleans pass through, else nil.
function M.to_bool(v)
    if type(v) == "boolean" then return v end
    if v == "true"  or v == "1" then return true  end
    if v == "false" or v == "0" then return false end
    return nil
end

--- Load a sub-module by directory prefix and name, caching the result in
--- the provided cache table.  The loaded module must expose `required_fn`.
--- Returns module, nil on success or nil, err on failure.
--- @param cache       table   caller-owned cache: { [name] = module }
--- @param pkg_prefix  string  e.g. "luamemo.rerankers"
--- @param name        string  adapter name, e.g. "ollama"
--- @param required_fn string  method that must exist on the module
function M.load_submodule(cache, pkg_prefix, name, required_fn)
    name = name or "noop"
    if cache[name] then return cache[name] end
    local ok, mod = pcall(require, pkg_prefix .. "." .. name)
    if not ok then
        return nil, pkg_prefix .. ": adapter not found: " .. name
            .. " (" .. tostring(mod) .. ")"
    end
    if type(mod[required_fn]) ~= "function" then
        return nil, pkg_prefix .. ": adapter '" .. name
            .. "' missing " .. required_fn .. "()"
    end
    cache[name] = mod
    return mod
end

--- Check an HTTP response (status, body, err) from luamemo.http.request.
--- Returns nil, errmsg on failure/non-2xx; otherwise returns true.
--- @param status     number|nil  HTTP status code, or nil on transport error
--- @param body       string|nil  response body
--- @param err        string|nil  transport error string
--- @param ctx        string      human-readable context for error messages
function M.check_http(status, body, err, ctx)
    if not status then
        return nil, ctx .. ": HTTP error: " .. tostring(err)
    end
    if status >= 300 then
        return nil, ctx .. ": HTTP " .. status .. ": " .. tostring(body)
    end
    return true
end

--- Build a safe comma-separated SQL id list from an array of ids.
--- Each element is validated as a number; non-numeric ids are silently
--- dropped.  Returns nil, err when the validated list is empty.
function M.sql_id_list(ids)
    local list = {}
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n then list[#list + 1] = tostring(math.floor(n)) end
    end
    if #list == 0 then return nil, "no valid numeric ids" end
    return table.concat(list, ",")
end

--- Validate that a numeric value is within [lo, hi].
--- Returns the coerced number (or nil when val is nil/not provided),
--- plus an error string on failure.
function M.clamp_check(name, val, lo, hi)
    if val == nil then return nil, nil end
    local n = tonumber(val)
    if not n then
        return nil, name .. " must be a number, got: " .. tostring(val)
    end
    if n < lo or n > hi then
        return nil, ("%s must be between %g and %g, got %g"):format(name, lo, hi, n)
    end
    return n, nil
end

--- Shell-safe single-quote a value for use in os.execute() / io.popen() calls.
--- Wraps the value in single quotes, escaping any embedded single quotes
--- using the standard POSIX idiom  '  →  '\''  so the shell sees them
--- as a literal apostrophe.
--- @param s  any  Value to quote (coerced to string)
--- @return string
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Validate that a value is a non-empty string.
--- Returns the value on success, or nil plus an error message on failure.
--- Follows the same (value, err) convention as the rest of the library.
--- @param v     any     Value to check
--- @param name  string  Field name used in the error message
--- @return string|nil, string|nil
function M.require_str(v, name)
    if type(v) ~= "string" or v == "" then
        return nil, (name or "value") .. " is required (non-empty string)"
    end
    return v
end

--- Parse a { scores = [{index, score}, ...] } LLM response table into a
--- normalised output array.  Used by the ollama and openai reranker adapters.
--- @param tbl  table  the `scores` array from the decoded LLM response
--- @return table      array of { index = number, score = number }
function M.parse_scores(tbl)
    local out = {}
    for _, s in ipairs(tbl) do
        out[#out + 1] = {
            index = tonumber(s.index),
            score = tonumber(s.score) or 0,
        }
    end
    return out
end

return M
