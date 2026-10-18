-- luamemo.cli.backup
--
-- `memo backup [PATH] [--force] [--db NAME|PATH]` — a consistent copy of this project's
-- database (or --db's), safe
-- while luamemo is in use (SQLite's VACUUM INTO copies one snapshot, other processes
-- go on reading and writing). PATH: a file, or a directory to put it in; default
-- <data dir>/backups/<name>-<UTC date-time>.db. --force replaces an existing PATH
-- (never the database itself). The copy is a complete luamemo database, 0600: to use
-- it, point MEMO_DB at it — or copy it over the database while nothing has it open.
-- The vault's secrets are in it, encrypted: reading them needs this machine's vault
-- key (by default ~/.config/luamemo/vault.key), which is not in it — nor is the
-- federation keyring (~/.config/luamemo).

local M = {}

local USAGE = "usage: memo backup [PATH] [--force] [--db NAME|PATH]\n"

local die = require("luamemo.cli._common").die_for("backup")

local exists = require("luamemo.util").exists
local is_dir = require("luamemo.util").is_dir
local realpath = require("luamemo.util").realpath   -- (symlinks and ".." resolved)

local function size_text(n)
    if n >= 1048576 then return ("%.1f MB"):format(n / 1048576) end
    if n >= 1024 then return ("%.1f KB"):format(n / 1024) end
    return n .. " bytes"
end

function M.run(argv)
    local path, force, db_name = nil, false, nil
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--force" then force = true
        elseif a == "--db" and argv[i + 1] then db_name = argv[i + 1]; i = i + 1
        elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
        elseif a:sub(1, 2) ~= "--" and not path then path = a
        else io.stderr:write(USAGE); die("unknown argument: " .. a, 2) end
        i = i + 1
    end

    require("luamemo.cli._common").setup_or_die(die, { db = db_name, no_embed = true })   -- a backup never embeds

    local db = require("luamemo.db")
    local src, perr = db.path()
    if not src then die(tostring(perr)) end
    if src == ":memory:" then die("an in-memory database can't be backed up") end
    if not exists(src) then die("no database at " .. src .. " yet — nothing to back up") end

    local name = src:match("([^/]+)%.db$") or src:match("([^/]+)$")
    local file = name .. "-" .. os.date("!%Y%m%d-%H%M%S") .. ".db"
    local target
    if not path then
        local dir = db.data_dir() .. "/backups"
        db.private_dir(dir)
        target = dir .. "/" .. file
    elseif is_dir(path) then
        target = path:gsub("/+$", "") .. "/" .. file
    else
        target = path
    end
    if exists(target) then
        local rt = realpath(target)
        if rt and rt == realpath(src) then die(target .. " is the database itself") end
        if not force then die(target .. " exists — pick another path, or replace it with --force") end
        for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(target .. sfx) end
    end

    local vok, verr = db.vacuum_into(target)
    if not vok then die(tostring(verr)) end

    -- Read the copy back: it is a database luamemo can open, and holds what it should.
    local b, berr = db.open(target, { readonly = true })
    if not b then die("the copy can't be opened: " .. tostring(berr)) end
    local n = tonumber(b.value("SELECT count(*) FROM lm_memories")) or 0
    local secrets = tonumber(b.value("SELECT count(*) FROM lm_secrets")) or 0
    b.close()
    local f = io.open(target, "rb")
    local size = f and f:seek("end") or 0
    if f then f:close() end

    io.write(("backup:    %s\n"):format(target))
    io.write(("size:      %s\n"):format(size_text(size)))
    io.write(("memories:  %d\n"):format(n))
    if secrets > 0 then
        io.write(("secrets:   %d, encrypted — reading them needs this machine's vault key (by default "
            .. "~/.config/luamemo/vault.key), which is not in the backup\n"):format(secrets))
    end
    if require("luamemo.federation.policy").role() ~= "solo" then
        io.write("keyring:   the federation keyring (~/.config/luamemo) is not in it — back it up separately\n")
    end
    io.write("restore:   point MEMO_DB at the backup, or copy it over the database while nothing has it open\n")
end

return M
