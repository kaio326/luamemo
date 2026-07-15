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

-- ---------------------------------------------------------------------------
-- Shared math / ML helpers
-- ---------------------------------------------------------------------------

--- Cosine similarity over two Lua numeric arrays.
--- Returns 0 for nil, non-table, or zero-magnitude input.
--- Handles mismatched lengths by using the shorter of the two.
--- @param a  table  numeric array
--- @param b  table  numeric array
--- @return number  value in [0, 1]
function M.cosine(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return 0 end
    local dot, na, nb = 0, 0, 0
    local len = math.min(#a, #b)
    if len == 0 then return 0 end
    for i = 1, len do
        local ai, bi = tonumber(a[i]) or 0, tonumber(b[i]) or 0
        dot = dot + ai * bi
        na  = na  + ai * ai
        nb  = nb  + bi * bi
    end
    local denom = math.sqrt(na) * math.sqrt(nb)
    if denom == 0 then return 0 end
    return dot / denom
end

--- Greedy single-linkage cosine clustering.
--- Assigns each memory to the first existing cluster whose pivot has
--- cosine similarity >= threshold; otherwise starts a new cluster.
--- Memories without a table-type embedding are placed in singleton clusters.
--- @param memories   table  array of rows; each may have an `.embedding` field
--- @param threshold  number cosine similarity cutoff (e.g. 0.80)
--- @return table  array of clusters; each cluster is an array of memory rows
function M.cluster(memories, threshold)
    local clusters = {}
    local pivots   = {}
    for _, mem in ipairs(memories) do
        local vec = type(mem.embedding) == "table" and mem.embedding or nil
        local assigned = false
        if vec then
            for ci = 1, #clusters do
                if M.cosine(pivots[ci], vec) >= threshold then
                    local cl = clusters[ci]
                    cl[#cl + 1] = mem
                    assigned = true
                    break
                end
            end
        end
        if not assigned then
            clusters[#clusters + 1] = { mem }
            pivots[#pivots + 1]     = vec
        end
    end
    return clusters
end

--- Derive a memory tier (0–3) from an importance value.
--- Mirrors the formula used on write; keeps tier derivation in one place.
--- @param imp  number  importance value (0.0 – 1.0)
--- @return number  tier integer 0–3
function M.importance_to_tier(imp)
    local v = tonumber(imp) or 0
    if v < 0.3  then return 0 end
    if v < 0.6  then return 1 end
    if v < 0.85 then return 2 end
    return 3
end

-- Module-level cache shared by util.table_exists across all callers in the
-- same Lua VM.  Deliberately never invalidated at runtime (see docs).
local _table_ok_cache = {}

--- Check whether a PostgreSQL table exists in the public schema.
--- Results are cached permanently within the process lifetime.
--- Requires luamemo.db to be available (called lazily to avoid a circular
--- require at load time).
--- @param name  string  unquoted table name
--- @return boolean
function M.table_exists(name)
    if _table_ok_cache[name] then return true end
    local db = require("luamemo.db")
    local rows = db.query(
        "SELECT 1 FROM information_schema.tables "
        .. "WHERE table_schema = 'public' AND table_name = "
        .. db.escape_literal(name)
        .. " LIMIT 1")
    if rows and #rows > 0 then
        _table_ok_cache[name] = true
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- DJB2 polynomial hash (pure Lua 5.1, no bit library) mod 2^32. The project's
-- checksum of choice for change-detection and dedup markers. NOTE: this is NOT
-- the embedder's hash (luamemo.embedders.hash uses a different modulus and must
-- stay byte-stable for stored embeddings — do not route it through here).
-- ---------------------------------------------------------------------------
local _DJB2_MASK = 4294967296  -- 2^32

function M.djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % _DJB2_MASK end
    return h
end

-- Zero-padded 8-char lowercase hex of djb2(s).
function M.djb2_hex(s)
    return ("%08x"):format(M.djb2(s))
end

return M
