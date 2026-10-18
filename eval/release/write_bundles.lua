-- eval/release/write_bundles.lua VERSION DIR — luamemo/embedders/native/bundles.lua for a
-- release, from the bundles eval/release/gguf_bundle.sh built (DIR/*.tar.gz.sha256).
-- Development / CI only: the release workflow runs it in the commit the tag points to.

local version, dir = arg[1], arg[2]
if not (version and version:match("^%d+%.%d+%.%d+$") and dir) then
    io.stderr:write("usage: luajit eval/release/write_bundles.lua VERSION DIR\n"); os.exit(2)
end
local p = assert(io.popen(("ls %q/*.tar.gz.sha256 2>/dev/null | LC_ALL=C sort"):format(dir)))
local rows = {}
for path in p:lines() do
    local f = assert(io.open(path)); local line = f:read("*l") or ""; f:close()
    local sum, asset = line:match("^(%x+)%s+(%S+)$")
    local platform = asset and asset:match("^luamemo%-gguf%-" .. version:gsub("%.", "%%.") .. "%-(.+)%.tar%.gz$")
    if not (sum and #sum == 64 and platform) then
        io.stderr:write("write_bundles: not a bundle checksum for ", version, ": ", path, "\n"); os.exit(1)
    end
    rows[#rows + 1] = ('    [%q] = { sha256 = %q, asset = %q },'):format(platform, sum:lower(), asset)
end
p:close()
if #rows == 0 then io.stderr:write("write_bundles: no *.tar.gz.sha256 in ", dir, "\n"); os.exit(1) end
local out = table.concat({
    "-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of",
    "-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the",
    "-- download against them). Used only when `version` is luamemo.VERSION.",
    "return {",
    ("    version = %q,"):format(version),
    table.concat(rows, "\n"),
    "}",
    "",
}, "\n")
local f = assert(io.open("luamemo/embedders/native/bundles.lua", "w")); f:write(out); f:close()
io.write(out)
