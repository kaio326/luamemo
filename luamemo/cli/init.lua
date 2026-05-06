-- luamemo.cli.init
--
-- `memo init` — interactive embedder-fit wizard. Probes host, asks a few
-- questions, prints a setup({...}) snippet recommended for the workload.
-- Never edits host code.
--
-- Flags (parsed by run()):
--   --non-interactive          do not prompt; use --multilingual / --long
--                              / --hosted / --allow-hash flags as answers
--   --multilingual             treat content as multilingual
--   --long                     treat rows as long-form (>4k chars)
--   --hosted                   permit hosted-API recommendations
--   --allow-hash               permit the hash fallback
--   --write PATH               also write the snippet to PATH
--   --root DIR                 project root for scan (default ".")

local probe     = require("luamemo.cli.probe")
local recommend = require("luamemo.cli.recommend")

local M = {}

local function ask(prompt, default)
    io.write(prompt)
    if default ~= nil then
        io.write(" [", default and "Y/n" or "y/N", "]")
    end
    io.write(": ")
    io.flush()
    local line = io.read("*l")
    if not line or line == "" then return default end
    line = line:lower():match("^%s*(.-)%s*$")
    if line == "y" or line == "yes" then return true end
    if line == "n" or line == "no"  then return false end
    return default
end

local function fmt_snippet(rec)
    local lines = { "require(\"luamemo\").setup({" }
    local order = {
        "embedder_local", "embedder_adapter", "embedder_url",
        "embedder_model", "embed_dim", "embed_max_chars",
        "embedder_headers",
    }
    for _, key in ipairs(order) do
        local v = rec.setup_keys[key]
        if v ~= nil then
            if type(v) == "string" then
                table.insert(lines, string.format("    %s = %q,", key, v))
            elseif type(v) == "number" then
                table.insert(lines, string.format("    %s = %d,", key, v))
            elseif type(v) == "table" then
                local parts = {}
                for k, vv in pairs(v) do
                    table.insert(parts, string.format("%s = %q", k, vv))
                end
                table.insert(lines, string.format("    %s = { %s },", key,
                    table.concat(parts, ", ")))
            end
        end
    end
    table.insert(lines, "    corpus_health_check = true,")
    table.insert(lines, "    auth_fn = function() return false end,  -- private by default")
    table.insert(lines, "})")
    return table.concat(lines, "\n")
end

local function parse_flags(argv)
    local f = { non_interactive = false, multilingual = false, long = false,
                hosted = false, allow_hash = false, write = nil, root = "." }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if     a == "--non-interactive" then f.non_interactive = true
        elseif a == "--multilingual"    then f.multilingual = true
        elseif a == "--long"            then f.long = true
        elseif a == "--hosted"          then f.hosted = true
        elseif a == "--allow-hash"      then f.allow_hash = true
        elseif a == "--write"           then f.write = argv[i + 1]; i = i + 1
        elseif a == "--root"            then f.root = argv[i + 1]; i = i + 1
        else
            io.stderr:write("memo init: unknown flag: " .. a .. "\n")
            os.exit(2)
        end
        i = i + 1
    end
    return f
end

function M.run(argv)
    local flags = parse_flags(argv or {})

    io.write("memo init — embedder-fit wizard\n")
    io.write("================================\n\n")

    -- Probes
    local gpu     = probe.gpu()
    local docker  = probe.docker()
    local ollama  = probe.ollama()
    local ram     = probe.ram_mb()
    local scan    = probe.scan_project(flags.root)

    io.write("Host probe:\n")
    io.write(string.format("  GPU:    %s\n",
        gpu.ok and string.format("%s (%d MiB free)", gpu.value.name, gpu.value.free_mb)
                or ("none (" .. gpu.err .. ")")))
    io.write(string.format("  Docker: %s\n",
        docker.ok and ("ok, " .. docker.value) or ("none (" .. docker.err .. ")")))
    io.write(string.format("  Ollama: %s\n",
        ollama.ok and ("reachable at " .. ollama.value) or ("none (" .. ollama.err .. ")")))
    io.write(string.format("  RAM:    %s\n",
        ram.ok and (ram.value .. " MiB available") or ("unknown (" .. ram.err .. ")")))
    io.write("\nProject scan (root=" .. flags.root .. "):\n")
    if #scan.ext_census == 0 then
        io.write("  no files found\n")
    else
        for i = 1, math.min(5, #scan.ext_census) do
            local e = scan.ext_census[i]
            io.write(string.format("  .%-10s  %d files\n", e.ext, e.count))
        end
    end
    if scan.multilingual_hint then
        io.write("  i18n/locales directory detected -> multilingual likely\n")
    end
    io.write("\n")

    -- Questions
    local multilingual, long, hosted, allow_hash
    if flags.non_interactive then
        multilingual = flags.multilingual or scan.multilingual_hint
        long         = flags.long
        hosted       = flags.hosted
        allow_hash   = flags.allow_hash
    else
        multilingual = ask("Will you store non-English content?", scan.multilingual_hint or false)
        long         = ask("Are typical rows longer than ~4000 characters?", false)
        hosted       = ask("OK with paying for a hosted API (OpenAI etc.)?", false)
        allow_hash   = false   -- never asked; require explicit --allow-hash
    end

    local profile = {
        has_gpu      = gpu.ok,
        gpu_free_mb  = gpu.ok and gpu.value.free_mb or 0,
        has_docker   = docker.ok,
        has_ollama   = ollama.ok,
        ram_mb       = ram.ok and ram.value or 0,
        multilingual = multilingual,
        long_rows    = long,
        allow_hosted = hosted,
        allow_hash   = allow_hash or flags.allow_hash,
    }

    local rec, err = recommend.decide(profile)
    if not rec then
        io.stderr:write("\nNo recommendation possible:\n  " .. err .. "\n")
        os.exit(1)
    end

    io.write("\nRecommendation:\n")
    io.write(string.format("  adapter:        %s\n", rec.adapter))
    io.write(string.format("  model:          %s\n", rec.model))
    io.write(string.format("  embed_dim:      %d\n", rec.dim))
    if rec.embed_max_chars then
        io.write(string.format("  embed_max_chars: %d\n", rec.embed_max_chars))
    end
    if rec.tei_image then
        io.write(string.format("  tei image:      %s\n", rec.tei_image))
    end
    io.write("\nRationale:\n")
    for _, r in ipairs(rec.rationale) do
        io.write("  - " .. r .. "\n")
    end

    local snippet = fmt_snippet(rec)
    io.write("\nSnippet (paste into your app startup):\n\n")
    io.write(snippet .. "\n")

    if flags.write then
        local f, ferr = io.open(flags.write, "w")
        if not f then
            io.stderr:write("\nmemo init: failed to write " .. flags.write .. ": " .. ferr .. "\n")
            os.exit(1)
        end
        f:write(snippet .. "\n"); f:close()
        io.write("\nWrote: " .. flags.write .. "\n")
    end
    io.write("\nNext step: run `memo doctor` after the app has written some rows " ..
             "to verify the fit.\n")
end

return M
