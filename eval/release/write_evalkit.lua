-- eval/release/write_evalkit.lua VERSION DIR [OUT] — luamemo/evalkit.lua (or OUT: the
-- tests') for a release, from the kit eval/release/eval_kit.sh built
-- (DIR/luamemo-evalkit-VERSION.tar.gz.sha256). Development / CI only: the release
-- workflow runs it in the commit the tag points to.

local version, dir, out_path = arg[1], arg[2], arg[3] or "luamemo/evalkit.lua"
if not (version and version:match("^%d+%.%d+%.%d+$") and dir) then
    io.stderr:write("usage: luajit eval/release/write_evalkit.lua VERSION DIR [OUT]\n"); os.exit(2)
end
local asset = ("luamemo-evalkit-%s.tar.gz"):format(version)
local f = io.open(dir .. "/" .. asset .. ".sha256")
if not f then io.stderr:write("write_evalkit: no ", dir, "/", asset, ".sha256\n"); os.exit(1) end
local line = f:read("*l") or ""; f:close()
local sum, name = line:match("^(%x+)%s+(%S+)$")
if not (sum and #sum == 64 and name == asset) then
    io.stderr:write("write_evalkit: not the kit's checksum for ", version, ": ", line, "\n"); os.exit(1)
end
local out = table.concat({
    "-- luamemo/evalkit.lua — the SHA-256 of this release's eval kit, written by",
    "-- eval/release/write_evalkit.lua (`memo eval install` checks the download against it).",
    "-- Used only when `version` is luamemo.VERSION.",
    "return {",
    ("    version = %q,"):format(version),
    ("    sha256  = %q,"):format(sum:lower()),
    ("    asset   = %q,"):format(asset),
    "}",
    "",
}, "\n")
local w = assert(io.open(out_path, "w")); w:write(out); w:close()
io.write(out)
