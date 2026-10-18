-- luamemo.cli.export
--
-- `memo export [--scope S]… [--no-vectors] [--out FILE] [--db NAME|PATH]` — this
-- database's (or --db's) memories and knowledge-graph facts as JSON Lines
-- (luamemo.transfer has the format), to stdout or FILE (created 0600: it holds your
-- memories). Default: every scope but an org replica (it re-syncs). Vectors travel
-- too unless --no-vectors; `memo import` reuses them only when the target uses the
-- same embedder.
--
--   memo export > project.jsonl
--   memo export --db old | memo import --db new -

local M = {}

local USAGE = "usage: memo export [--scope SCOPE]… [--no-vectors] [--out FILE] [--db NAME|PATH]\n"

local die = require("luamemo.cli._common").die_for("export")

function M.run(argv)
    local scopes, vectors, out_path, db_name = {}, true, nil, nil
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--scope" and argv[i + 1] then scopes[#scopes + 1] = argv[i + 1]; i = i + 1
        elseif a == "--no-vectors" then vectors = false
        elseif a == "--out" and argv[i + 1] then out_path = argv[i + 1]; i = i + 1
        elseif a == "--db" and argv[i + 1] then db_name = argv[i + 1]; i = i + 1
        elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
        else io.stderr:write(USAGE); die("unknown argument: " .. a, 2) end
        i = i + 1
    end

    require("luamemo.cli._common").setup_or_die(die, { db = db_name, no_embed = true })   -- exporting never embeds

    local out = io.stdout
    if out_path then
        local f, ferr = require("luamemo.util").with_umask("077", io.open, out_path, "w")
        if not f then die("cannot write " .. out_path .. ": " .. tostring(ferr)) end
        out = f
    end
    local rep, xerr = require("luamemo.transfer").export(function(line) out:write(line, "\n") end,
        { scopes = scopes, vectors = vectors })
    if out ~= io.stdout then
        out:close()
        -- an existing file keeps its mode through io.open — this one holds memories
        -- (a regular file only: --out /dev/stdout or another device is left alone)
        local q = require("luamemo.util").shell_quote(out_path)
        os.execute("[ -f " .. q .. " ] && [ ! -L " .. q .. " ] && chmod 600 " .. q)
    end
    if not rep then die(tostring(xerr)) end
    io.stderr:write(("exported %d memories (%d with vectors) and %d facts from %d scope(s)%s\n"):format(rep.memories,
        rep.vectors, rep.facts, #rep.scopes, out_path and (" → " .. out_path) or ""))
end

return M
