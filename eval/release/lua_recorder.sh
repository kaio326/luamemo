#!/usr/bin/env bash
# eval/release/lua_recorder.sh — LuaJIT, logging "<module>\t<file>" for every Lua module it loads
# (development only; never shipped). LUA_RECORDER_OUT: the log; LUA_RECORDER_BIN: the real luajit.
exec "${LUA_RECORDER_BIN:-luajit}" -e 'local out = os.getenv("LUA_RECORDER_OUT")
if out then
    local lua_loader = package.loaders[2]
    package.loaders[2] = function(name)
        local file = package.searchpath(name, package.path)
        if file then local h = io.open(out, "a"); if h then h:write(name, "\t", file, "\n"); h:close() end end
        return lua_loader(name)
    end
end' "$@"
