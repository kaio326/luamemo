#!/usr/bin/env bash
# Build gguf_shim.so — the thin C glue over llama.cpp used by the LuaJIT FFI
# embedder (luamemo/embedders/gguf_ffi.lua).
#
#   LLAMA_DIR=/path/to/llama.cpp ./build.sh
#
# Requires: a built llama.cpp with shared libs (libllama.so + libggml*.so in
# $LLAMA_DIR/build/bin) and its headers ($LLAMA_DIR/include, $LLAMA_DIR/ggml/include).
# See the planner Phase 7 for the one-time llama.cpp build recipe.
#
# Output location: gguf_shim.so must land next to the INSTALLED ffi_shim.lua
# (that's where its self-relative FFI lookup expects it), which is NOT
# necessarily next to this script. A LuaRocks install ships gguf_shim.c and
# this script via copy_directories, which lands in a *separate* bookkeeping
# directory from the actual Lua module tree — so this script asks `luarocks
# show` for the real install prefix (the same resolution `memo calibrate`
# already uses to locate mcp/server.lua) and searches it for the true
# ffi_shim.lua location. Deliberately does NOT rely on the ambient Lua
# interpreter's default package.path — that reflects whatever happens to be on
# LUA_PATH / the current directory, not necessarily this install. Falls back
# to building next to this script when luarocks isn't found or nothing
# resolves — correct for a plain git-clone dev tree, where this script's
# directory already IS ffi_shim.lua's directory.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
LIBDIR="$LLAMA_DIR/build/bin"

[ -f "$LLAMA_DIR/include/llama.h" ] || { echo "llama.h not found under $LLAMA_DIR/include" >&2; exit 1; }
[ -f "$LIBDIR/libllama.so" ]       || { echo "libllama.so not found under $LIBDIR" >&2; exit 1; }

OUT_DIR="$HERE"
for _lr in luarocks-5.1 luarocks; do
    if command -v "$_lr" >/dev/null 2>&1; then
        _prefix=$("$_lr" show luamemo 2>/dev/null | grep -i "installed in:" | head -1 \
            | sed 's/.*[Ii]nstalled in:[[:space:]]*//')
        if [ -n "$_prefix" ] && [ -d "$_prefix" ]; then
            # Prune the rocks-tree bookkeeping directory (lib/luarocks/rocks-*) —
            # that's where copy_directories put a SECOND copy of ffi_shim.lua
            # (the one right next to this very script); without pruning it,
            # `find` can return that one instead of the real module-path copy.
            _found=$(find "$_prefix" -path "*/lib/luarocks/*" -prune -o \
                -path "*luamemo/embedders/native/ffi_shim.lua" -print 2>/dev/null | head -1)
            if [ -n "$_found" ]; then
                OUT_DIR="$(dirname "$_found")"
            fi
        fi
        break
    fi
done

cc -O2 -fPIC -shared "$HERE/gguf_shim.c" -o "$OUT_DIR/gguf_shim.so" \
   -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
   -L"$LIBDIR" -Wl,-rpath,"$LIBDIR" -lllama -lm

echo "built $OUT_DIR/gguf_shim.so (rpath -> $LIBDIR)"
if [ "$OUT_DIR" != "$HERE" ]; then
    echo "  (source was $HERE/gguf_shim.c; output placed next to the installed ffi_shim.lua)"
fi
