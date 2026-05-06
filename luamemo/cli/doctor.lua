-- luamemo.cli.doctor
--
-- `memo doctor` — health check. Reads live DB stats via the same
-- M.corpus_health_check() the boot WARN uses, then prints a structured
-- OK/WARN/FAIL report with concrete recommendations.
--
-- Requires the host app to have called setup() already (so config is
-- populated). Invoked via `memo doctor --setup PATH` to bootstrap
-- config, or directly when imported by an app that has already wired
-- the library.
--
-- Exit codes: 0 = OK / WARN, 1 = FAIL (truncation > 10% or DB error).

local M = {}

local function fmt_int(n)
    -- 12345 -> "12_345"
    n = tostring(n)
    return (n:reverse():gsub("(%d%d%d)", "%1_"):reverse():gsub("^_", ""))
end

local function parse_flags(argv)
    local f = { setup = nil, json = false }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if     a == "--setup" then f.setup = argv[i + 1]; i = i + 1
        elseif a == "--json"  then f.json = true
        else
            io.stderr:write("memo doctor: unknown flag: " .. a .. "\n")
            os.exit(2)
        end
        i = i + 1
    end
    return f
end

function M.run(argv)
    local flags = parse_flags(argv or {})

    -- If --setup PATH given, dofile() it so the user's setup() call runs.
    if flags.setup then
        local ok, err = pcall(dofile, flags.setup)
        if not ok then
            io.stderr:write("memo doctor: failed to load setup file " ..
                flags.setup .. ":\n  " .. tostring(err) .. "\n")
            os.exit(1)
        end
    end

    local lm = require("luamemo")
    if not lm.config or not lm.config.db_table then
        io.stderr:write("memo doctor: luamemo.setup() has not been called.\n" ..
            "  Pass --setup PATH/TO/setup.lua, or invoke from a host app where setup() has run.\n")
        os.exit(1)
    end

    local stats, err = lm.corpus_health_check()
    if not stats then
        io.stderr:write("memo doctor: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    io.write("memo doctor — corpus health\n")
    io.write("===========================\n")
    io.write(string.format("  table:        %s\n", lm.config.db_table))
    io.write(string.format("  backend:      %s\n", lm.store.backend()))
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
                    "Re-run `memo init` and switch embedder.\n")
                exit_code = 1
            end
        end
    end

    os.exit(exit_code)
end

return M
