-- luamemo.cli.import
--
-- `memo import FILE|- [--dedup append|skip|update] [--scope S] [--dry-run] [--db NAME|PATH]`
-- — memories and facts from JSON Lines (a `memo export`, or one memory per line from
-- any tool — see luamemo.transfer) into this database (or --db). Keeps each memory's
-- timestamps, tier, importance, tags and metadata. Vectors from an export of the same
-- embedder are reused; otherwise each memory is embedded here. Re-importing an export
-- adds nothing twice; an export of this very database is refused. --dedup: what to do
-- with a memory near-identical to one already here (append: keep both — the default;
-- skip; update: merge into it). --scope: the scope of a line that names none.
-- --dry-run checks every line and writes nothing. Exit code 1 when any line failed.

local M = {}

local USAGE = "usage: memo import FILE|- [--dedup append|skip|update] [--scope SCOPE] [--dry-run] "
    .. "[--db NAME|PATH]\n"

local die = require("luamemo.cli._common").die_for("import")

local function line(k, v) io.write(("%-10s %s\n"):format(k .. ":", tostring(v))) end

function M.run(argv)
    local path, opts = nil, {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--dedup" and argv[i + 1] then opts.dedup = argv[i + 1]; i = i + 1
        elseif a == "--scope" and argv[i + 1] then opts.scope = argv[i + 1]; i = i + 1
        elseif a == "--dry-run" then opts.dry_run = true
        elseif a == "--db" and argv[i + 1] then opts.db = argv[i + 1]; i = i + 1
        elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
        elseif a:sub(1, 2) ~= "--" and not path then path = a
        else io.stderr:write(USAGE); die("unknown argument: " .. a, 2) end
        i = i + 1
    end
    if not path then io.stderr:write(USAGE); os.exit(2) end
    if opts.dedup and not ({ append = true, skip = true, update = true })[opts.dedup] then
        die("--dedup must be append, skip or update", 2)
    end

    local f = io.stdin
    if path ~= "-" then
        local ferr
        f, ferr = io.open(path, "r")
        if not f then die("cannot read " .. path .. ": " .. tostring(ferr)) end
    end

    require("luamemo.cli._common").setup_or_die(die, { db = opts.db })

    local rep = require("luamemo.transfer").import(function() return f:read("*l") end, opts)
    if f ~= io.stdin then f:close() end

    local h = rep.header
    if h and h.db_id then
        line("source", ("%s (luamemo %s, %s)"):format(tostring(h.db_id):sub(1, 12), tostring(h.version),
            tostring(h.embedder_sig)))
    end
    line(rep.dry_run and "would add" or "added", ("%d memories (%d merged, %d skipped as duplicates, "
        .. "%d already imported)"):format(rep.memories, rep.merged, rep.skipped, rep.already))
    line("facts", ("%d (%d already here)"):format(rep.facts, rep.facts_present))
    if not rep.dry_run then
        line("vectors", ("%d reused, %d embedded here%s"):format(rep.vectors_reused, rep.embedded,
            (h and h.embedder_sig and not rep.reuse) and " (the export's embedder is another one)" or ""))
    end
    if rep.error_count > 0 then
        line("errors", rep.error_count)
        for _, e in ipairs(rep.errors) do io.write("  " .. e .. "\n") end
        if rep.error_count > #rep.errors then io.write(("  … and %d more\n"):format(rep.error_count - #rep.errors)) end
        os.exit(1)
    end
end

return M
