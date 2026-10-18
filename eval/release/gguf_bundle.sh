#!/usr/bin/env bash
# eval/release/gguf_bundle.sh VERSION [OUTDIR] — the in-process GGUF embedder's native
# runtime, prebuilt (development / CI only; never shipped): llama.cpp at the pinned tag
# (M.LLAMA_TAG in luamemo/embedders/native/bundle.lua) built as shared libraries, the shim built against
# it, all in one directory that finds its own libraries ($ORIGIN / @loader_path):
#
#   OUTDIR/luamemo-gguf-VERSION-<os>-<arch>.tar.gz   gguf_shim.so + libllama + libggml*
#   OUTDIR/luamemo-gguf-VERSION-<os>-<arch>.tar.gz.sha256
#
# CPU only (macOS: + Metal). Linux x86_64 targets x86-64-v3 (AVX2 / FMA / F16C — CPUs
# since ~2013; memo gguf install checks the CPU first). The release attaches the bundles
# and ships their checksums in the rock (luamemo/embedders/native/bundles.lua);
# `memo gguf install` downloads the one for this machine.
# Needs: git, cmake, a C/C++ compiler, tar, sha256sum or shasum.
set -euo pipefail

VERSION="${1:?usage: gguf_bundle.sh VERSION [OUTDIR]}"
OUT="${2:-dist}"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NATIVE="$REPO/luamemo/embedders/native"
TAG="${LLAMA_TAG:-$(sed -n 's/^M\.LLAMA_TAG = "\(.*\)"$/\1/p' "$NATIVE/bundle.lua")}"
[[ -n "$TAG" ]] || { echo "gguf_bundle: no M.LLAMA_TAG in $NATIVE/bundle.lua" >&2; exit 1; }

case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) echo "gguf_bundle: unsupported system $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "gguf_bundle: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac
NAME="luamemo-gguf-$VERSION-$os-$arch"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gguf-bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$NAME"; mkdir -p "$STAGE"

echo "== llama.cpp $TAG ($os-$arch)"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
LL="$WORK/llama.cpp"

cmake_args=(-DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_SERVER=OFF -DGGML_NATIVE=OFF -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON)
if [[ $os == linux ]]; then
    cmake_args+=(-DCMAKE_INSTALL_RPATH='$ORIGIN')
    [[ $arch == x86_64 ]] && cmake_args+=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)
else
    cmake_args+=(-DCMAKE_INSTALL_RPATH=@loader_path -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
fi
cmake -S "$LL" -B "$LL/build" "${cmake_args[@]}" >/dev/null
cmake --build "$LL/build" --target llama -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null

echo "== shim"
if [[ $os == linux ]]; then
    cp -P "$LL"/build/bin/lib*.so* "$STAGE"/
    cc -O2 -fPIC -shared "$NATIVE/gguf_shim.c" -o "$STAGE/gguf_shim.so" \
        -I"$LL/include" -I"$LL/ggml/include" -L"$STAGE" -Wl,-rpath,'$ORIGIN' -lllama -lm
else
    cp -P "$LL"/build/bin/lib*.dylib "$STAGE"/
    cc -O2 -fPIC -shared "$NATIVE/gguf_shim.c" -o "$STAGE/gguf_shim.so" \
        -I"$LL/include" -I"$LL/ggml/include" -L"$STAGE" -Wl,-rpath,@loader_path -lllama -lm
fi
printf '%s\n' "llama.cpp $TAG, built $(date -u +%Y-%m-%d) for $os-$arch by eval/release/gguf_bundle.sh" \
    > "$STAGE/BUILD_INFO"

# It must load on its own: from the bundle's directory, nothing from the build tree.
mv "$LL" "$WORK/llama.cpp.moved"
if command -v luajit >/dev/null 2>&1; then
    luajit -e "local ffi = require('ffi'); ffi.load('$STAGE/gguf_shim.so')" \
        || { echo "gguf_bundle: the shim doesn't load from the bundle" >&2; exit 1; }
    echo "   loads from the bundle"
fi

tar -czf "$OUT/$NAME.tar.gz" -C "$WORK" "$NAME"
if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$OUT/$NAME.tar.gz" | cut -d' ' -f1)
else sum=$(shasum -a 256 "$OUT/$NAME.tar.gz" | cut -d' ' -f1); fi
printf '%s  %s\n' "$sum" "$NAME.tar.gz" > "$OUT/$NAME.tar.gz.sha256"
echo "== $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1)) sha256 $sum"
