-- eval/tests/test_rockspec.lua
-- The rock carries every module: the rockspec of the current version (luamemo.VERSION)
-- is what eval/release/rockspec.lua generates — every luamemo/**/*.lua listed, each path
-- there, nothing listed that isn't — its dependencies install with the LuaRocks most
-- systems package (Lua 5.1: not "luajit"), the directories it copies exist, and the
-- CHANGELOG has the version's section. (0.4.1's hand-kept list missed 16 modules.)
-- Run: luajit eval/tests/run.lua --only rockspec

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("rockspec")
local check, section, finish = T.check, T.section, T.finish

local gen = dofile("eval/release/rockspec.lua")
local version = require("luamemo").VERSION

section("the current version's rockspec", function()
io.write("\n--- rockspec ---\n")
local path = gen.file(version)
local text = H.slurp(path)
check(path .. " exists (luamemo.VERSION " .. version .. ")", text ~= nil)
if not text then return end
check("… and is what eval/release/rockspec.lua generates (run it after adding a module)",
    text == gen.render(version), "luajit eval/release/rockspec.lua " .. version)
local env = {}
local chunk = assert(loadstring(text, path))
setfenv(chunk, env); chunk()
check("version and tag follow luamemo.VERSION", env.version == version .. "-1"
    and env.source and env.source.tag == "v" .. version, tostring(env.version))
local listed, missing, stray = {}, {}, {}
for name, file in pairs(env.build.modules) do
    listed[file] = name
    if not H.slurp(file) then stray[#stray + 1] = name .. " → " .. file end
end
for _, m in ipairs(gen.modules()) do
    if listed[m.path] ~= m.name then missing[#missing + 1] = m.name end
end
check(("every luamemo module is in the rock (%d)"):format(#gen.modules()), #missing == 0, table.concat(missing, ", "))
check("every listed file exists", #stray == 0, table.concat(stray, ", "))
local deps = table.concat(env.dependencies, " | ")
check("installs with a Lua 5.1 LuaRocks: depends on lua ~> 5.1, not luajit", deps:find("lua ~> 5.1", 1, true)
    and not deps:find("luajit", 1, true), deps)
local absent = {}
for _, d in ipairs(env.build.copy_directories) do
    local ok = os.execute(("test -d %q"):format(d))
    if ok ~= 0 and ok ~= true then absent[#absent + 1] = d end
end
check("the directories it copies exist (mcp/ with instructions.md)", #absent == 0
    and H.slurp("mcp/instructions.md") ~= nil, table.concat(absent, ", "))
check("bin: memo", env.build.install.bin.memo == "cli/memo")
end)

section("optional dependencies stay optional", function()
-- lua-cjson is optional (luamemo.json falls back to the bundled dkjson): a module that
-- loads it directly fails on a machine without it (0.5.0's clean-machine CI run found
-- the learned reranker and projection trainers doing so).
local p = io.popen("git ls-files -co --exclude-standard -- '*.lua' | xargs grep -ln 'require *(\\?[\"'\\'']cjson' 2>/dev/null")
local hits = {}
for f in p:lines() do if f ~= "luamemo/json.lua" then hits[#hits + 1] = f end end
p:close()
check("nothing but luamemo/json.lua loads cjson", #hits == 0, table.concat(hits, ", "))
-- …and the fallback encodes as lua-cjson does (the bundled dkjson, changed for it).
local dk = require("luamemo.vendor.dkjson")
local arr = setmetatable({}, { __jsontype = "array" })
check("bundled dkjson: {n = 7} → {\"n\":7}, {} → {}, a marked empty array → [], {1,2} → [1,2]",
    dk.encode({ n = 7 }) == '{"n":7}' and dk.encode({}) == "{}" and dk.encode({ tools = {} }) == '{"tools":{}}'
    and dk.encode(arr) == "[]" and dk.encode({ 1, 2 }) == "[1,2]",
    table.concat({ dk.encode({ n = 7 }), dk.encode({}), dk.encode(arr) }, " "))
end)

section("the CHANGELOG", function()
local log = H.slurp("CHANGELOG.md") or ""
check("has a section for " .. version, log:find("\n## %[" .. version:gsub("%.", "%%.") .. "%]") ~= nil)
end)

finish()
