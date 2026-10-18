-- eval/tests/test_gguf_bundle.lua
-- The prebuilt GGUF runtime (luamemo.embedders.native.bundle, `memo gguf`): with no
-- checksum shipped (a checkout) nothing is offered and build.sh is named; a download
-- that doesn't match the shipped checksum is refused and leaves nothing; one that
-- matches but doesn't load is refused; memo gguf status reports. With a real bundle
-- (MEMO_LIVE_GGUF_BUNDLE=path/to/luamemo-gguf-<v>-<platform>.tar.gz, as
-- eval/release/gguf_bundle.sh builds it) and a model (MEMO_GGUF_MODEL): it installs and
-- the embedder runs on it. Downloads go to a local file:// "release" here.
-- Run: luajit eval/tests/run.lua --only gguf_bundle

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("gguf bundle")
local check, section, finish = T.check, T.section, T.finish
local sh = H.sh

local bundle = require("luamemo.embedders.native.bundle")
local VERSION = require("luamemo").VERSION
local platform = bundle.platform()
local base = os.tmpname(); os.remove(base)
local data = base .. "-data"
local releases = base .. "-releases"
os.execute(("mkdir -p %q %q"):format(data, releases .. "/releases/download/v" .. VERSION))
local function setenv(k, v)
    local ffi = require("ffi"); pcall(ffi.cdef, "int setenv(const char*, const char*, int);")
    ffi.C.setenv(k, v, 1)
end
setenv("XDG_DATA_HOME", data)
local function sha(path) return (sh(("sha256sum %q"):format(path))):match("^(%x+)") end
local function ship(sums, version)   -- what a release's bundles.lua would hold
    if next(sums) ~= nil then sums.version = version or VERSION end
    package.loaded["luamemo.embedders.native.bundles"] = sums
end
local ASSET = ("luamemo-gguf-%s-%s.tar.gz"):format(VERSION, tostring(platform))
local DL = releases .. "/releases/download/v" .. VERSION .. "/" .. ASSET

section("no checksum shipped (a checkout)", function()
io.write("\n--- a checkout ---\n")
ship({})
local b, why = bundle.available()
check("nothing offered; build.sh named", b == nil and tostring(why):find("build.sh", 1, true) ~= nil, why)
local out = sh("./cli/memo gguf status 2>&1")
check("memo gguf status says so", out:find("prebuilt:  none", 1, true) ~= nil and out:find("model:", 1, true) ~= nil, out)
local _, code = sh("./cli/memo gguf install 2>&1")
check("memo gguf install: exit 1, nothing to install", code == 1)
if platform then
    ship({ [platform] = { sha256 = ("a"):rep(64), asset = "x.tar.gz" } }, "0.0.1")
    check("checksums of another version are never used", bundle.available() == nil)
end
end)

if not platform then io.write("[SKIP] no prebuilt platform here\n"); finish() end
bundle.REPO_URL = "file://" .. releases

section("a download that doesn't match is refused", function()
io.write("\n--- checksum ---\n")
local stage = base .. "-fake/" .. ASSET:gsub("%.tar%.gz$", "")
os.execute(("mkdir -p %q && printf 'not a library' > %q"):format(stage, stage .. "/gguf_shim.so"))
os.execute(("tar -czf %q -C %q %q"):format(DL, base .. "-fake", (ASSET:gsub("%.tar%.gz$", ""))))
ship({ [platform] = { sha256 = ("0"):rep(64), asset = ASSET } })
local b = bundle.available()
local ok_cpu = bundle.cpu_ok(platform)
if not b then io.write("[SKIP] ", select(2, bundle.available()) or "", "\n"); return end
local shim, why = bundle.install()
check("mismatch → refused, named", shim == nil and tostring(why):find("doesn't match the checksum", 1, true) ~= nil, why)
check("… and nothing unpacked, no partial file", H.slurp(b.shim) == nil
    and sh(("ls -A %q"):format(b.dir)) == "", sh(("ls -A %q"):format(b.dir)))
ship({ [platform] = { sha256 = sha(DL), asset = ASSET } })
local shim2, why2 = bundle.install()
check("matches but doesn't load → refused", shim2 == nil and tostring(why2):find("doesn't load", 1, true) ~= nil, why2)
check("(this CPU suits the bundle)", ok_cpu == true)
os.execute(("rm -rf %q %q"):format(b.dir, base .. "-fake"))
end)

section("a real bundle installs and runs the embedder", function()
io.write("\n--- the real runtime ---\n")
local real, model = os.getenv("MEMO_LIVE_GGUF_BUNDLE"), os.getenv("MEMO_GGUF_MODEL")
if not (real and H.slurp(real) and model and H.slurp(model)) then
    io.write("[SKIP] MEMO_LIVE_GGUF_BUNDLE (a built bundle) and MEMO_GGUF_MODEL needed\n"); return
end
if not tostring(real):find(platform, 1, true) then io.write("[SKIP] the bundle is for another platform\n"); return end
os.execute(("cp %q %q"):format(real, DL))
ship({ [platform] = { sha256 = sha(DL), asset = ASSET } })
local shim, why = bundle.install(nil, { say = function(l) io.write("  ", l, "\n") end })
check("installs: checksum matches, unpacked, loads", shim ~= nil and bundle.loads(shim), why)
if not shim then return end
check("… into the data directory, per version and platform", shim:find(data .. "/luamemo/native/" .. VERSION
    .. "-" .. platform, 1, true) == 1, shim)
local code = 'package.path="./?.lua;./?/init.lua;"..package.path local e = require("luamemo.embedders.gguf_ffi") '
    .. 'local ok, err = e.selftest({}) io.write(ok and ("OK " .. tostring(e.dim({}))) or ("ERR " .. tostring(err)))'
-- (llama.cpp logs to stderr; H.sh folds stderr in — the subshell keeps it out.)
local out = sh(("(MEMO_GGUF_SHIM=%q MEMO_GGUF_MODEL=%q %q -e %q 2>/dev/null)"):format(shim, model, H.lua_bin(), code))
check("the GGUF embedder runs on the prebuilt runtime (selftest)", out:match("^OK %d+") ~= nil, out)
local again = bundle.install()
check("installing again reuses it (no download)", again == shim)
end)

os.execute(("rm -rf %q %q"):format(data, releases))
finish()
