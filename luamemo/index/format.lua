-- luamemo.index.format
-- Compact, token-lean rendering of index rows for agent consumption. Pure — no
-- config, no DB. Turns store rows into one-line-per-symbol text so an agent
-- spends ~30 tokens locating code instead of reading files or parsing JSON.
--
-- Row shape (from store.search / index APIs):
--   symbol: { title, body, kind="symbol",
--             metadata = { path, line, symbol_type, exported, ... } }
--   file:   { title, body, kind="file",
--             metadata = { path, lines, checksum, ... } }

local M = {}

local DOC_CLIP = 100   -- max chars of docstring shown per symbol line

-- Safe metadata accessor (JSONB usually decodes to a table; guard otherwise).
local function meta(row)
    return (type(row.metadata) == "table") and row.metadata or {}
end

-- One-line docstring for a symbol: the body with the trailing generated
-- signature ("… — <type> <qualified>(<n> args)") removed, newlines flattened,
-- clipped. Returns "" when the symbol has no docstring.
local function _doc_of(row)
    local body = row.body or ""
    local st   = meta(row).symbol_type
    -- _symbol_body builds "<doc> — <type> <name>(...)" or just "<type> <name>(...)".
    if st and body:sub(1, #st) == st then
        return ""  -- no docstring: body starts with the type
    end
    if st then
        -- _symbol_body joins "<doc> — <type> …" with an em dash (multibyte);
        -- use plain (literal) find so the UTF-8 bytes match as-is.
        local cut = body:find(" — " .. st .. " ", 1, true)
        if not cut then cut = body:find(" - " .. st .. " ", 1, true) end
        if cut then body = body:sub(1, cut - 1) end
    end
    body = body:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #body > DOC_CLIP then body = body:sub(1, DOC_CLIP):gsub("%s+%S*$", "") .. "…" end
    return body
end

-- symbol_line(row) → "path:line  title (type) — doc"
-- Falls back gracefully when fields are missing.
function M.symbol_line(row)
    local m    = meta(row)
    local loc  = m.path and (m.path .. (m.line and (":" .. tostring(m.line)) or "")) or "?"
    local name = row.title or m.source_name or "?"
    local typ  = m.symbol_type and (" (" .. m.symbol_type .. ")") or ""
    local doc  = _doc_of(row)
    local line = loc .. "  " .. name .. typ
    if doc ~= "" then line = line .. " — " .. doc end
    return line
end

-- file_line(row) → "path  (file, N lines)"
function M.file_line(row)
    local m = meta(row)
    local loc = m.path or row.title or "?"
    local n   = m.lines and (" (" .. tostring(m.lines) .. " lines)") or ""
    return loc .. n
end

-- Render a mixed list of search-result rows. Symbol rows get symbol_line;
-- file rows get file_line; anything else falls back to title.
function M.results(rows, opts)
    opts = opts or {}
    rows = rows or {}
    if #rows == 0 then return "(no matches)" end
    local out = {}
    for _, r in ipairs(rows) do
        if r.kind == "symbol" then
            out[#out + 1] = M.symbol_line(r)
        elseif r.kind == "file" then
            out[#out + 1] = M.file_line(r)
        else
            local m = meta(r)
            local loc = m.path and (" " .. m.path) or ""
            out[#out + 1] = (r.title or "?") .. loc
        end
    end
    return table.concat(out, "\n")
end

-- outline(file_row, symbol_rows) → file header + one symbol_line each.
-- symbol_rows are expected pre-sorted by line (index.outline does this).
function M.outline(file_row, symbol_rows)
    symbol_rows = symbol_rows or {}
    local header
    if file_row then
        local m = meta(file_row)
        header = (m.path or file_row.title or "?")
            .. (m.lines and (" — " .. tostring(m.lines) .. " lines") or "")
            .. (", " .. #symbol_rows .. " symbols")
    else
        header = "(file not indexed)"
    end
    if #symbol_rows == 0 then
        return header .. "\n(no symbols)"
    end
    local out = { header }
    for _, r in ipairs(symbol_rows) do
        out[#out + 1] = "  " .. M.symbol_line(r)
    end
    return table.concat(out, "\n")
end

-- explore(res) → grouped matched / callers / callees sections.
function M.explore(res)
    if not res then return "(no result)" end
    local function section(label, rows)
        rows = rows or {}
        if #rows == 0 then return nil end
        local lines = { label .. " (" .. #rows .. "):" }
        for _, r in ipairs(rows) do lines[#lines + 1] = "  " .. M.symbol_line(r) end
        return table.concat(lines, "\n")
    end
    local parts = {}
    parts[#parts + 1] = section("matched", res.matched) or "matched (0): (none)"
    local callers = section("callers (depend on these)", res.callers)
    local callees = section("callees (these depend on)", res.callees)
    if callers then parts[#parts + 1] = callers end
    if callees then parts[#parts + 1] = callees end
    return table.concat(parts, "\n")
end

return M
