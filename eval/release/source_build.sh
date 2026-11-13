#!/usr/bin/env bash
# eval/release/source_build.sh [LLAMA_DIR] — builds the GGUF shim from source the way a user
# does (development and CI only; never shipped): llama.cpp at the pinned tag (M.LLAMA_TAG in
# luamemo/embedders/native/bundle.lua), built with the commands `memo calibrate` prints, then
# gguf/build.sh, then checks what came out. Run by CI on Linux and macOS.
#
#   bash eval/release/source_build.sh                  clones and builds llama.cpp in $TMPDIR
#   bash eval/release/source_build.sh ~/llama.cpp      reuses a llama.cpp that is built already
#   bash eval/release/source_build.sh --llama-only DIR only builds llama.cpp there (CI caches it before the checks)
#   bash eval/release/source_build.sh --tag            prints the llama.cpp tag (M.LLAMA_TAG) and exits
#
# Nothing on this machine is read or changed: the shim goes to a temporary HOME. It does not
# embed (CI has no model): the stand-in shim (smoke.sh, test_install_layouts) covers that path,
# and the release's smoke loads the prebuilt runtime.
# Prints one PASS / FAIL line per check; exit 1 when any fails.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LUAJIT="${LUAJIT:-luajit}"
TAG=$(sed -n 's/^M\.LLAMA_TAG = "\(.*\)"$/\1/p' "$REPO/luamemo/embedders/native/bundle.lua")
[[ -n "$TAG" ]] || { echo "source_build: no M.LLAMA_TAG in luamemo/embedders/native/bundle.lua" >&2; exit 1; }
if [[ "${1:-}" == "--tag" ]]; then echo "$TAG"; exit 0; fi
LLAMA_ONLY=0
if [[ "${1:-}" == "--llama-only" ]]; then LLAMA_ONLY=1; shift; fi
LLAMA_DIR="${1:-${TMPDIR:-/tmp}/luamemo-llama-$TAG}"

FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; [[ -n "${2:-}" ]] && printf '      %s\n' "${2:0:800}"; FAILS=$((FAILS + 1)); }

# ── llama.cpp, as `memo calibrate` says to build it (luamemo/cli/calibrate.lua) ─────
if [[ ! -e "$LLAMA_DIR/build/bin/libllama.so" && ! -e "$LLAMA_DIR/build/bin/libllama.dylib" ]]; then
    echo "== llama.cpp $TAG in $LLAMA_DIR"
    if [[ ! -f "$LLAMA_DIR/include/llama.h" ]]; then
        git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$LLAMA_DIR" \
            || { echo "source_build: cloning llama.cpp $TAG failed" >&2; exit 1; }
    fi
    cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" -DBUILD_SHARED_LIBS=ON -DGGML_CUDA=OFF -DLLAMA_CURL=OFF \
          -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
          -DLLAMA_BUILD_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null \
        && cmake --build "$LLAMA_DIR/build" --target llama -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null \
        || { echo "source_build: building llama.cpp failed" >&2; exit 1; }
fi
[[ $LLAMA_ONLY -eq 0 ]] || exit 0

# ── gguf/build.sh, in a home of its own ─────────────────────────────────────────────
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/luamemo-source-build.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
export HOME="$HOME_DIR"
unset XDG_DATA_HOME MEMO_GGUF_SHIM MEMO_GEMMA_SHIM

out=$(LLAMA_DIR="$LLAMA_DIR" bash "$REPO/gguf/build.sh" 2>&1); rc=$?
where=$(bash "$REPO/gguf/build.sh" --where 2>&1)
if [[ $rc -eq 0 && -f "$where" ]]; then pass "build.sh builds the shim ($where)"; else fail "build.sh builds the shim" "exit $rc: $out"; fi

# Every function luamemo calls (gguf_ffi.lua, sensing/generate.lua). Loading the shim also proves
# its rpath finds libllama and libggml.
syms=$(SHIM="$where" "$LUAJIT" -e '
local ffi = require("ffi")
local ok, lib = pcall(ffi.load, os.getenv("SHIM"))
if not ok then io.write("does not load: ", tostring(lib)) return end
local decl = {
    lmembed_load           = "void * lmembed_load(const char * path, int n_ctx, int n_gpu_layers);",
    lmembed_dim            = "int lmembed_dim(void * handle);",
    lmembed_embed          = "int lmembed_embed(void * handle, const char * text, float * out, int max_dim);",
    lmembed_last_truncated = "int lmembed_last_truncated(void * handle);",
    lmembed_free           = "void lmembed_free(void * handle);",
    lmgen_load             = "void * lmgen_load(const char * path, int n_ctx, int n_gpu_layers);",
    lmgen_complete         = "int lmgen_complete(void * handle, const char * prompt, char * out, int max_out, int max_tokens);",
    lmgen_chat_template    = "const char * lmgen_chat_template(void * handle);",
    lmgen_free             = "void lmgen_free(void * handle);",
}
local names = {}
for n in pairs(decl) do names[#names + 1] = n end
table.sort(names)
local lines = {}
for _, n in ipairs(names) do lines[#lines + 1] = decl[n] end
ffi.cdef(table.concat(lines, "\n"))
local missing = {}
for _, n in ipairs(names) do
    if not pcall(function() return lib[n] end) then missing[#missing + 1] = n end
end
io.write(table.concat(missing, " "))' 2>&1)
if [[ -z "$syms" ]]; then pass "the shim loads and has every symbol luamemo calls"
else fail "the shim loads and has every symbol luamemo calls" "$syms"; fi

status=$("$REPO/cli/memo" gguf status 2>&1)
if grep -q "state:     loads" <<<"$status" && ! grep -q "built before" <<<"$status" \
    && grep -F "shim:" <<<"$status" | grep -qF "$where"; then
    pass "memo gguf status: loads, at the default place"
else fail "memo gguf status: loads, at the default place" "$status"; fi

if LLAMA_DIR=/nonexistent bash "$REPO/gguf/build.sh" --where >/dev/null 2>&1; then pass "build.sh --where needs no llama.cpp"
else fail "build.sh --where needs no llama.cpp"; fi

HOME2=$(mktemp -d "${TMPDIR:-/tmp}/luamemo-source-build.XXXXXX")
if ! HOME="$HOME2" LLAMA_DIR=/nonexistent bash "$REPO/gguf/build.sh" >/dev/null 2>&1 && [[ ! -e "$HOME2/.local" ]]; then
    pass "build.sh without llama.cpp fails and writes nothing"
else fail "build.sh without llama.cpp fails and writes nothing"; fi
rm -rf "$HOME2"

echo ""
if [[ $FAILS -eq 0 ]]; then echo "source_build: all checks passed (llama.cpp $TAG)"; exit 0; fi
echo "source_build: $FAILS check(s) failed"; exit 1
