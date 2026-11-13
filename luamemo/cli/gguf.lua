-- luamemo.cli.gguf
--
-- `memo gguf [status]` — the in-process GGUF embedder's runtime: the shim in use (and which
-- rule found it), whether it loads, where gguf/build.sh is, whether this release has a
-- prebuilt runtime for this machine, the model.
-- `memo gguf install` — download that prebuilt runtime (checked against the checksum the
-- rock ships), unpack it into ~/.local/share/luamemo/native/; prints `SHIM <path>` last —
-- cli/memo then records it: memo config set --user MEMO_GGUF_SHIM <path>.
-- Exit: 0 ok, 1 not possible / failed, 2 usage.

local M = {}

local bundle = require("luamemo.embedders.native.bundle")
local exists = require("luamemo.util").exists

local function status()
    local ffi_shim = require("luamemo.embedders.native.ffi_shim")
    local shim = ffi_shim.shim_path()
    local set = ffi_shim.override()
    io.write("GGUF runtime\n")
    io.write(("  shim:      %s (%s)\n"):format(shim, set and "MEMO_GGUF_SHIM" or "the default place"))
    local loads, stale = false, false
    -- Nothing is loaded (dlopen'd, even to test it) from a place missing() refuses.
    local unusable = ffi_shim.missing()
    if not unusable then loads, stale = bundle.loads(shim) end
    if unusable then
        io.write("  state:     not installed\n")
        io.write("             " .. unusable .. "\n")
    elseif stale then io.write("  state:     loads, but " .. ffi_shim.STALE .. "\n")
    elseif loads then io.write("  state:     loads\n")
    else io.write("  state:     present, but it doesn't load on this machine\n") end
    if set and exists(ffi_shim.default_path()) then
        io.write("  note:      a shim built from source is at " .. ffi_shim.default_path()
            .. ", unused while MEMO_GGUF_SHIM is set\n")
    end
    local build = ffi_shim.build_script()
    io.write("  build:     " .. (build or ("not found from here — get " .. ffi_shim.build_hint())) .. "\n")
    local b, why = bundle.available()
    if b then
        io.write(("  prebuilt:  %s for %s — memo gguf install%s\n"):format(b.asset, b.platform,
            exists(b.shim) and " (installed: " .. b.shim .. ")" or ""))
    else
        io.write("  prebuilt:  none — " .. tostring(why) .. "\n")
    end
    local model = require("luamemo.cli.probe").gguf_model_path()
    io.write("  model:     " .. (model or ("none — MEMO_GGUF_MODEL, or ~/models/"
        .. require("luamemo.cli.probe").GGUF_DEFAULT_MODEL .. " (memo calibrate shows the download)")) .. "\n")
    return 0
end

local function install()
    local shim, why = bundle.install(nil, { say = function(line) io.write("  ", line, "\n"); io.flush() end })
    if not shim then
        io.stderr:write("memo gguf install: " .. tostring(why) .. "\n")
        return 1
    end
    io.write("  installed and loads: ", shim, "\n")
    io.write("SHIM ", shim, "\n")
    return 0
end

function M.run(argv)
    local cmd = argv[1] or "status"
    local code
    if cmd == "status" then code = status()
    elseif cmd == "install" then code = install()
    elseif cmd == "-h" or cmd == "--help" then
        io.write("Usage: memo gguf [status | install]\n")
        code = 0
    else
        io.stderr:write("memo gguf: unknown command " .. cmd .. " (memo gguf --help)\n")
        code = 2
    end
    os.exit(code)
end

return M
