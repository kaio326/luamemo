-- eval/release/luarocks_text.lua — the text luarocks.org should show for the module, taken from a rockspec.
--
--   luajit eval/release/luarocks_text.lua luamemo-X.Y.Z-1.rockspec OUTDIR
--
-- Writes OUTDIR/summary.txt (description.summary) and OUTDIR/description.txt (description.detailed, its common
-- indentation removed). luarocks.org takes the module's summary and description from the FIRST rockspec uploaded and
-- never updates them from a later one: the owner edits them on the site (/edit/modules/<user>/<module>; summary up to 512
-- characters, description up to 5120). The release workflow runs this to say what to paste, and whether the page is stale.

local path, dir = arg[1], arg[2]
if not (path and dir) then
    io.stderr:write("usage: luajit eval/release/luarocks_text.lua ROCKSPEC OUTDIR\n")
    os.exit(2)
end

local env = {}
setfenv(assert(loadfile(path)), env)()
local d = assert(env.description, "no description in " .. path)

local function out(name, text)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
end

out("summary.txt", d.summary)
local detailed = d.detailed:gsub("^%s*\n", ""):gsub("%s+$", "")
local indent = detailed:match("^([ \t]*)")
if indent ~= "" then detailed = detailed:gsub("\n" .. indent, "\n"):gsub("^" .. indent, "") end
out("description.txt", detailed .. "\n")
