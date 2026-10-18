-- luamemo.native.loader
-- Finds and loads the native libraries luamemo uses through LuaJIT's FFI.
--
-- Search order for each library (first that loads wins):
--   1. MEMO_LIB_<NAME> — an explicit path (e.g. MEMO_LIB_SQLITE3=/opt/sqlite/lib/libsqlite3.so)
--   2. a copy shipped with luamemo, in luamemo/native/lib/<os>-<arch>/
--   3. the system library, by its versioned name first (runtime-only installs ship
--      libsqlite3.so.0 / libsodium.so.23, not the unversioned dev symlink)
-- A missing library, or one older than luamemo needs, fails with one message that
-- names the package to install and the variable to set.
--
-- loader.ffi is LuaJIT's FFI: the modules that use it take it from here, so a Lua
-- without one (not LuaJIT) fails with this message, whichever module loads first.

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then
    error("luamemo runs on LuaJIT (its FFI reaches SQLite and libsodium) — start it with luajit, "
        .. "not " .. tostring(_VERSION), 0)
end

local M = {}
M.ffi = ffi

M.LIBS = {
    sqlite3 = {
        env = "MEMO_LIB_SQLITE3",
        file = "libsqlite3",
        names = {
            Linux = { "libsqlite3.so.0", "libsqlite3.so" },
            OSX   = { "libsqlite3.0.dylib", "libsqlite3.dylib" },
        },
        install = "apt install libsqlite3-0 (Debian / Ubuntu / WSL) · dnf install sqlite-libs (Fedora) · "
            .. "brew install sqlite (macOS)",
    },
    sodium = {
        env = "MEMO_LIB_SODIUM",
        file = "libsodium",
        names = {
            Linux = { "libsodium.so.23", "libsodium.so.26", "libsodium.so" },
            OSX   = { "libsodium.23.dylib", "libsodium.26.dylib", "libsodium.dylib" },
        },
        install = "apt install libsodium23 (Debian / Ubuntu / WSL) · dnf install libsodium (Fedora) · "
            .. "brew install libsodium (macOS)",
    },
}

-- Directory of this file (…/luamemo/native/), for the bundled copies.
local function here()
    local src = debug.getinfo(1, "S").source
    return (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]*$") or "."
end

local function bundled_path(spec)
    local ext = (ffi.os == "OSX") and ".dylib" or ".so"
    return ("%s/lib/%s-%s/%s%s"):format(here(), ffi.os:lower(), ffi.arch, spec.file, ext)
end

local exists = require("luamemo.util").exists

local loaded = {}

--- Load library `name` ("sqlite3" | "sodium") → clib, where | nil, err
function M.load(name)
    if loaded[name] then return loaded[name].lib, loaded[name].where end
    local spec = M.LIBS[name]
    if not spec then return nil, "native: unknown library " .. tostring(name) end

    local tried = {}
    local function try(path, where)
        local ok, lib = pcall(ffi.load, path)
        if ok then
            loaded[name] = { lib = lib, where = where }
            return lib, where
        end
        tried[#tried + 1] = path
        return nil
    end

    local override = os.getenv(spec.env)
    if override and override ~= "" then
        local lib, where = try(override, spec.env)
        if lib then return lib, where end
        return nil, ("native: %s=%s could not be loaded — point it at a %s shared library, or unset it to use "
            .. "the system's (%s)"):format(spec.env, override, spec.file, spec.install)
    end

    local b = bundled_path(spec)
    if exists(b) then
        local lib, where = try(b, "bundled")
        if lib then return lib, where end
    end

    for _, soname in ipairs(spec.names[ffi.os] or spec.names.Linux) do
        local lib, where = try(soname, "system")
        if lib then return lib, where end
    end
    -- macOS: Homebrew (/opt/homebrew on Apple silicon, /usr/local on Intel) and MacPorts
    -- install outside the loader's default search — a `brew install libsodium` was not found.
    if ffi.os == "OSX" then
        for _, dir in ipairs({ "/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib" }) do
            for _, soname in ipairs(spec.names.OSX) do
                local p = dir .. "/" .. soname
                if exists(p) then
                    local lib, where = try(p, "system")
                    if lib then return lib, where end
                end
            end
        end
    end

    return nil, ("native: %s not found (tried %s). Install it — %s — or set %s to its path.")
        :format(spec.file, table.concat(tried, ", "), spec.install, spec.env)
end

--- Like load(), but raises the error.
function M.require(name)
    local lib, err = M.load(name)
    if not lib then error(err, 2) end
    return lib
end

M._bundled_path = bundled_path   -- tests

return M
