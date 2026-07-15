#!/usr/bin/env bash
# Build gguf_shim.so — the thin C glue over llama.cpp used by the LuaJIT FFI
# embedder (luamemo/embedders/gguf_ffi.lua).
#
#   LLAMA_DIR=/path/to/llama.cpp ./build.sh
#
# Requires: a built llama.cpp with shared libs (libllama.so + libggml*.so in
# $LLAMA_DIR/build/bin) and its headers ($LLAMA_DIR/include, $LLAMA_DIR/ggml/include).
# See the planner Phase 7 for the one-time llama.cpp build recipe.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
LIBDIR="$LLAMA_DIR/build/bin"

[ -f "$LLAMA_DIR/include/llama.h" ] || { echo "llama.h not found under $LLAMA_DIR/include" >&2; exit 1; }
[ -f "$LIBDIR/libllama.so" ]       || { echo "libllama.so not found under $LIBDIR" >&2; exit 1; }

cc -O2 -fPIC -shared "$HERE/gguf_shim.c" -o "$HERE/gguf_shim.so" \
   -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
   -L"$LIBDIR" -Wl,-rpath,"$LIBDIR" -lllama -lm

echo "built $HERE/gguf_shim.so (rpath -> $LIBDIR)"
