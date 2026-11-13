-- eval/tests/test_rock.lua
-- The rock, installed: eval/release/smoke.sh builds the current version's rockspec from
-- the files a release carries, installs it into a temporary tree and uses it — every
-- module loads from the tree, memo works from a project's subfolder, memo mcp starts the
-- rock's own server (usage rules, 27 tools, a search). Skipped without luarocks / git / jq.
-- Run: luajit eval/tests/run.lua --only rock

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("rock")
local check, section, finish = T.check, T.section, T.finish

local function have(cmd) return (H.sh("command -v " .. cmd .. " 2>/dev/null")) ~= "" end

section("smoke test of the installed rock", function()
io.write("\n--- the rock, installed ---\n")
for _, cmd in ipairs({ "luarocks", "git", "jq", "tar" }) do
    if not have(cmd) then io.write("[SKIP] ", cmd, " not found — the rock isn't built here\n"); return end
end
local spec = dofile("eval/release/rockspec.lua").file(require("luamemo").VERSION)
local out, code = H.sh(("LUAJIT=%q bash eval/release/smoke.sh %q 2>&1"):format(H.lua_bin(), spec))
local passed = select(2, out:gsub("\nPASS ", "")) + (out:match("^PASS ") and 1 or 0)
local failed = {}
for line in out:gmatch("FAIL  ([^\n]+)") do failed[#failed + 1] = line end
check(("the smoke test passes (%d checks)"):format(passed), code == 0 and #failed == 0 and passed >= 17,
    out:sub(1, 2000))
-- A skipped or deleted block is not a failure to smoke.sh: with a C compiler these must all have run.
if have("cc") then
    local missing = {}
    for _, name in ipairs({
        "the server started on its own loads every luamemo module from the tree",
        "memo gguf status says the stand-in shim loads",
        "memo write / search with gguf_ffi",
        "memo mcp: memory_write with gguf_ffi",
        "memo mcp: memory_search with gguf_ffi",
        "memo mcp with gguf_ffi loads every luamemo module from the tree",
        "gguf/build.sh --where names the shim memo looks for",
        "a prebuilt-runtime tarball (the release's layout) loads through the installed rock",
    }) do
        if not out:find("PASS  " .. name, 1, true) then missing[#missing + 1] = name end
    end
    check("… including the GGUF embedder checks (a C compiler is here)", #missing == 0, table.concat(missing, "; "))
end
end)

finish()
