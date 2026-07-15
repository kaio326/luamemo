-- luamemo.index.differ
-- Symbol-level diff for incremental updates. Pure function, no DB.
-- Safe to require() directly without setup().
--
-- Compares two lists of symbols (from parser.parse_file) by full_name.
-- Used by index.update() to skip unchanged symbols and avoid unnecessary embeds.

local M = {}

-- diff(old_symbols, new_symbols) → { added, removed, changed, unchanged }
--
-- old_symbols, new_symbols: lists of symbol tables from parser.parse_source()
--
-- "changed" means the symbol exists in both but its body/metadata differs.
-- The caller decides what constitutes the body (typically full_name + docstring).
-- We compare: full_name, symbol_type, arity, vararg, docstring.
--
-- Return:
--   added     = symbols only in new  (write as new rows)
--   removed   = symbols only in old  (delete existing rows)
--   changed   = { old=..., new=... } pairs (re-embed + update row)
--   unchanged = symbols identical in both (skip entirely)
function M.diff(old_symbols, new_symbols)
    -- Index by full_name for O(1) lookup.
    local old_by_name = {}
    for _, s in ipairs(old_symbols or {}) do
        old_by_name[s.full_name] = s
    end
    local new_by_name = {}
    for _, s in ipairs(new_symbols or {}) do
        new_by_name[s.full_name] = s
    end

    local added, removed, changed, unchanged = {}, {}, {}, {}

    for _, ns in ipairs(new_symbols or {}) do
        local os = old_by_name[ns.full_name]
        if not os then
            added[#added + 1] = ns
        else
            -- Compare the fields that affect the stored body.
            local same = (os.symbol_type == ns.symbol_type)
                      and (os.arity == ns.arity)
                      and (os.vararg == ns.vararg)
                      and ((os.docstring or "") == (ns.docstring or ""))
                      and (os.line == ns.line)
            if same then
                unchanged[#unchanged + 1] = ns
            else
                changed[#changed + 1] = { old = os, new = ns }
            end
        end
    end

    for _, os in ipairs(old_symbols or {}) do
        if not new_by_name[os.full_name] then
            removed[#removed + 1] = os
        end
    end

    return { added = added, removed = removed, changed = changed, unchanged = unchanged }
end

return M
