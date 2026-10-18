-- luamemo/embedders/native/bundle.lua — the prebuilt GGUF runtime (gguf_shim.so with the
-- llama.cpp libraries it needs), downloaded from this release's GitHub assets instead of
-- built (owner, 2026-10-15). The checksums come with the rock (bundles.lua): a download
-- that doesn't match is refused. Installed into ~/.local/share/luamemo/native/<version>-
-- <platform>/; MEMO_GGUF_SHIM points luamemo at it. Without a checksum for this machine
-- (a checkout, another platform) the shim is built from source (build.sh) as before.

local M = {}

local util = require("luamemo.util")
local shq, sh = util.shell_quote, util.sh

M.REPO_URL = "https://github.com/kaio326/luamemo"
-- The llama.cpp release the shim is built and tested against (eval/release/gguf_bundle.sh
-- builds the prebuilt runtime from it; memo calibrate's build-from-source steps name it).
M.LLAMA_TAG = "b9976"

--- "<os>-<arch>" of this machine (linux-x86_64, macos-arm64, …), or nil, why.
function M.platform()
    local os_name = ({ Linux = "linux", Darwin = "macos" })[sh("uname -s")]
    local arch = ({ x86_64 = "x86_64", amd64 = "x86_64", arm64 = "arm64", aarch64 = "arm64" })[sh("uname -m")]
    if not (os_name and arch) then return nil, "no prebuilt runtime for " .. sh("uname -sm") end
    return os_name .. "-" .. arch
end

--- Can this CPU run the bundle? (Linux x86_64 is built for AVX2 / FMA / F16C.)
function M.cpu_ok(platform)
    if platform ~= "linux-x86_64" then return true end
    local f = io.open("/proc/cpuinfo", "r")
    if not f then return true end
    local info = f:read("*a"); f:close()
    local flags = info:match("\nflags%s*:([^\n]*)") or info:match("^flags%s*:([^\n]*)") or ""
    for _, need in ipairs({ "avx2", "fma", "f16c" }) do
        if not (" " .. flags .. " "):find(" " .. need .. " ", 1, true) then
            return false, "this CPU lacks " .. need .. " (the prebuilt runtime needs AVX2 / FMA / F16C)"
        end
    end
    return true
end

--- The bundle for this machine and release: { platform, asset, sha256, url, dir, shim } or
--- nil, why (no checksum shipped — a checkout or another platform; an unsuited CPU).
function M.available(version)
    version = version or require("luamemo").VERSION
    local platform, perr = M.platform()
    if not platform then return nil, perr end
    local ok_sums, sums = pcall(require, "luamemo.embedders.native.bundles")
    local entry = ok_sums and type(sums) == "table" and sums.version == version and sums[platform]
    if not (entry and entry.sha256 and entry.asset) then
        return nil, ("no prebuilt runtime for %s in luamemo %s (a checkout, or not built for it) — "
            .. "build it from source: luamemo/embedders/native/build.sh"):format(platform, version)
    end
    local cok, cerr = M.cpu_ok(platform)
    if not cok then return nil, cerr end
    local data = os.getenv("XDG_DATA_HOME")
    data = ((data and data ~= "") and data or ((os.getenv("HOME") or "") .. "/.local/share")) .. "/luamemo"
    local dir = ("%s/native/%s-%s"):format(data, version, platform)
    return {
        platform = platform, asset = entry.asset, sha256 = entry.sha256:lower(),
        url = ("%s/releases/download/v%s/%s"):format(M.REPO_URL, version, entry.asset),
        dir = dir, shim = dir .. "/" .. entry.asset:gsub("%.tar%.gz$", "") .. "/gguf_shim.so",
    }
end

-- The file's SHA-256, hex, computed in process (libsodium) — no sha256sum / shasum needed.
local function sha256(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local data = f:read("*a"); f:close()
    local ok, digest = pcall(require("luamemo.native.sodium").sha256, data or "")
    return (ok and util.to_hex(digest) or ""):lower()
end

--- Download, check and unpack the bundle. → the shim's path, or nil, why. Nothing is
--- left behind on a failure; an installed bundle that loads is reused.
function M.install(version, opts)
    opts = opts or {}
    local b, why = M.available(version)
    if not b then return nil, why end
    local say = opts.say or function(_) end
    if util.exists(b.shim) and M.loads(b.shim) then return b.shim end
    for _, cmd in ipairs({ "curl", "tar" }) do
        if sh("command -v " .. cmd) == "" then return nil, cmd .. " is needed to download the prebuilt runtime" end
    end
    util.private_dir(b.dir, true)
    local tmp = b.dir .. "/." .. b.asset .. ".part"
    say("downloading " .. b.url)
    -- HTTPS only (file:// only when a test points M.REPO_URL at a local directory).
    local proto = b.url:match("^file://") and "=file" or "=https"
    local ok = os.execute(("curl -fsSL --proto %s --tlsv1.2 --retry 2 -o %s %s"):format(
        shq(proto), shq(tmp), shq(b.url)))
    if ok ~= 0 and ok ~= true then os.remove(tmp); return nil, "download failed: " .. b.url end
    local got = sha256(tmp)
    if got ~= b.sha256 then
        os.remove(tmp)
        return nil, ("the download doesn't match the checksum this release ships (got %s, want %s) — "
            .. "not installed"):format(got ~= "" and got or "?", b.sha256)
    end
    local tok = os.execute(("tar -xzf %s -C %s"):format(shq(tmp), shq(b.dir)))
    os.remove(tmp)
    if tok ~= 0 and tok ~= true then return nil, "unpacking failed" end
    if not M.loads(b.shim) then return nil, "the prebuilt runtime doesn't load on this machine: " .. b.shim end
    return b.shim
end

--- Does the shim load here (in a separate luajit, so a crash can't take memo down)?
function M.loads(path)
    local code = ("local ffi = require('ffi'); local ok = pcall(ffi.load, %q); io.write(ok and 'OK' or 'NO')")
        :format(path)
    return sh(("%s -e %s"):format(shq(os.getenv("MEMO_LUA") or "luajit"), shq(code))) == "OK"
end

return M
