#!/usr/bin/env bash
# Build gguf_shim.so — the thin C glue over llama.cpp used by the LuaJIT FFI
# embedder (luamemo/embedders/gguf_ffi.lua).
#
#   LLAMA_DIR=/path/to/llama.cpp ./build.sh
#   ./build.sh --where     print where the shim goes, and exit (no llama.cpp needed)
#
# Requires: a built llama.cpp with shared libs (libllama.so — macOS: libllama.dylib — and
# libggml* in $LLAMA_DIR/build/bin) and its headers ($LLAMA_DIR/include, $LLAMA_DIR/ggml/include).
# Linux and macOS (eval/release/source_build.sh checks both in CI). The output is named
# gguf_shim.so on macOS too, as in the prebuilt bundle.
#
# Output: $XDG_DATA_HOME/luamemo/native/gguf_shim.so (default ~/.local/share/luamemo/native)
# — where luamemo looks when MEMO_GGUF_SHIM is not set (luamemo.embedders.native.ffi_shim),
# whichever copy of luamemo runs: a checkout, the plugin or a LuaRocks install. No root needed.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="${XDG_DATA_HOME:-${HOME:-.}/.local/share}/luamemo"
OUT_DIR="$DATA/native"
if [ "${1:-}" = "--where" ]; then echo "$OUT_DIR/gguf_shim.so"; exit 0; fi
# luamemo never loads a shim from a place that depends on the working directory.
case "$OUT_DIR" in
    /*) ;;
    *) echo "build.sh: HOME is not set, or XDG_DATA_HOME is not an absolute path ($OUT_DIR)" >&2; exit 1 ;;
esac

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
LIBDIR="$LLAMA_DIR/build/bin"

[ -f "$LLAMA_DIR/include/llama.h" ] || { echo "llama.h not found under $LLAMA_DIR/include" >&2; exit 1; }
[ -f "$LIBDIR/libllama.so" ] || [ -f "$LIBDIR/libllama.dylib" ] \
    || { echo "libllama.so (macOS: libllama.dylib) not found under $LIBDIR" >&2; exit 1; }

# A directory luamemo creates is 0700; one that already exists is left as it is.
mkdir -p "$(dirname "$DATA")"
[ -d "$DATA" ] || mkdir -m 700 "$DATA"
[ -d "$OUT_DIR" ] || mkdir -m 700 "$OUT_DIR"

cc -O2 -fPIC -shared "$HERE/gguf_shim.c" -o "$OUT_DIR/gguf_shim.so" \
   -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
   -L"$LIBDIR" -Wl,-rpath,"$LIBDIR" -lllama -lm

echo "built $OUT_DIR/gguf_shim.so (rpath -> $LIBDIR)"
if [ -n "${MEMO_GGUF_SHIM:-}${MEMO_GEMMA_SHIM:-}" ]; then
    echo "  note: MEMO_GGUF_SHIM is set and wins over this file — memo gguf status shows which is in use;" \
         "memo config unset --user MEMO_GGUF_SHIM to use this one"
fi
