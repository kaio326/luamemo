-- luamemo.cli.doctor
--
-- `memo doctor` — health check. Reads live DB stats via the same
-- M.corpus_health_check() the boot WARN uses, then prints a structured
-- OK/WARN/FAIL report with concrete recommendations.
--
-- Reads the same settings as every other memo command (.luamemorc / MEMO_*).
--
-- Exit codes: 0 = OK / WARN, 1 = FAIL (truncation > 10%, DB error, settings), 2 = unknown flag.

local M = {}

local function fmt_int(n)
    -- 12345 -> "12_345"
    n = tostring(n)
    return (n:reverse():gsub("(%d%d%d)", "%1_"):reverse():gsub("^_", ""))
end

local function parse_flags(argv)
    for _, a in ipairs(argv) do
        io.stderr:write("memo doctor: unknown flag: " .. a .. "\n")
        os.exit(2)
    end
end

function M.run(argv)
    parse_flags(argv or {})

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

    -- The language model every generative feature shares (luamemo.llm): one setting, and what follows from it.
    local llm = require("luamemo.llm")
    local model = llm.model(lm.config)
    io.write(string.format("  language model: %s\n", model
        and (llm.basename(lm.config) .. (llm.available(lm.config) and "" or "  (not loadable here: memo gguf status)"))
        or "none (MEMO_GEN_MODEL unset)"))
    local maintenance = require("luamemo.maintenance")
    io.write(string.format("    summarizer:   %s  (MEMO_SUMMARIZER_ADAPTER=%s)%s\n",
        require("luamemo.summarizers._common").adapter_name(lm.config), tostring(lm.config.summarizer_adapter or "noop"),
        maintenance.local_model(lm.config) and ""
            or "; a remote model: memory_summarize and memo consolidate use it, the background maintenance never does"))
    local fold = require("luamemo.fold")
    local last
    local lf = io.open(fold.log_path(), "rb")
    if lf then
        for line in lf:lines() do if line:find('"run":"maintain"', 1, true) then last = line:match('"at":"([^"]+)"') or last end end
        lf:close()
    end
    io.write(string.format("    maintenance:  %s%s\n",
        maintenance.background() and "in the background (memo maintain)" or "inside the write that makes it due",
        last and ("; last run " .. last) or "; no run logged yet"))
    local settings = require("luamemo.settings")
    io.write(string.format("    same memory:  dedup %.2f · miss %.2f · merge %.2f · reinforce %.2f\n",
        settings.same_memory(lm.config),
        settings.same_memory(lm.config, "miss_threshold"),
        settings.same_memory(lm.config, "consolidate_threshold"),
        settings.same_memory(lm.config, "consolidate_reinforce_threshold")))
    for _, l in ipairs(require("luamemo.feedback").status_lines(lm.config)) do io.write(l, "\n") end
    io.write("\n")

    -- The MCP clients that started luamemo here, and what an old one loses (luamemo.clients).
    local client_lines, clients_ok = require("luamemo.clients").report()
    for _, l in ipairs(client_lines) do
        io.write((clients_ok and "[INFO] " or "[WARN] ") .. l .. "\n")
    end
    io.write("\n")

    -- Claude Code: the hooks, the CLAUDE.md block, memory notes still in files (luamemo.cli.agent).
    local agent_ok, agent_lines = pcall(function()
        local agent = require("luamemo.cli.agent")
        return agent.render(agent.check())
    end)
    if agent_ok and #agent_lines > 0 then
        for _, l in ipairs(agent_lines) do io.write(l, "\n") end
        io.write("\n")
    end

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
