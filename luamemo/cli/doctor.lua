-- luamemo.cli.doctor
--
-- `memo doctor` — health check. Reads live DB stats via the same
-- M.corpus_health_check() the boot WARN uses, then prints a structured
-- OK/WARN/FAIL report with concrete recommendations.
--
-- Reads the same settings as every other memo command (.luamemorc / MEMO_*).
--
-- Exit codes: 0 = OK / WARN, 1 = FAIL (truncation > 10%, DB error, settings).

local M = {}

local function fmt_int(n)
    -- 12345 -> "12_345"
    n = tostring(n)
    return (n:reverse():gsub("(%d%d%d)", "%1_"):reverse():gsub("^_", ""))
end

local function parse_flags(argv)
    local f = { json = false }
    for _, a in ipairs(argv) do
        if a == "--json" then f.json = true
        else
            io.stderr:write("memo doctor: unknown flag: " .. a .. "\n")
            os.exit(2)
        end
    end
    return f
end

function M.run(argv)
    local flags = parse_flags(argv or {})

    local lm = require("luamemo")
    local ok, err = pcall(lm.setup, require("luamemo.cli._common").config_from_env())
    if not ok then
        io.stderr:write("memo doctor: luamemo can't start — " .. tostring(err) .. "\n"
            .. "  Check the settings (memo config check), or run memo calibrate.\n")
        os.exit(1)
    end

    local stats, err = lm.corpus_health_check()
    if not stats then
        io.stderr:write("memo doctor: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    io.write("memo doctor — corpus health\n")
    io.write("===========================\n")
    io.write(string.format("  database:     %s\n", tostring(require("luamemo.db").path())))
    io.write(string.format("  storage:      SQLite %s\n", require("luamemo.native.sqlite").version()))
    io.write(string.format("  embedder:     %s (dim=%d)\n",
        lm.config.embedder_local or lm.config.embedder_adapter or "?",
        lm.config.embed_dim or 0))
    io.write(string.format("  embed_max_chars: %s\n",
        lm.config.embed_max_chars and tostring(lm.config.embed_max_chars) or "unset"))
    io.write("\n")
    io.write(string.format("  rows:         %s\n", fmt_int(stats.rows)))
    io.write(string.format("  avg chars:    %s\n", fmt_int(stats.avg_chars)))
    io.write(string.format("  p95 chars:    %s\n", fmt_int(stats.p95_chars)))
    io.write(string.format("  max chars:    %s\n", fmt_int(stats.max_chars)))
    io.write(string.format("  truncated:    %s\n", fmt_int(stats.truncated)))
    io.write("\n")

    -- The MCP clients that started luamemo here, and what an old one loses (luamemo.clients).
    local client_lines, clients_ok = require("luamemo.clients").report()
    for _, l in ipairs(client_lines) do
        io.write((clients_ok and "[INFO] " or "[WARN] ") .. l .. "\n")
    end
    io.write("\n")

    local exit_code = 0
    if #stats.warnings == 0 then
        io.write("[OK] No issues detected.\n")
    else
        for _, w in ipairs(stats.warnings) do
            io.write("[WARN] " .. w .. "\n")
        end
        if stats.rows > 0 then
            local ratio = stats.truncated / stats.rows
            if ratio > 0.10 then
                io.write("\n[FAIL] Truncation ratio " ..
                    string.format("%.1f%%", ratio * 100) ..
                    " exceeds 10% — recall is materially degraded. " ..
                    "Re-run `memo calibrate` and switch embedder.\n")
                exit_code = 1
            end
        end
    end

    os.exit(exit_code)
end

return M
