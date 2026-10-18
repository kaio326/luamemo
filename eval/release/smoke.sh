#!/usr/bin/env bash
# eval/release/smoke.sh — install the rock into a temporary tree and use it (development
# only; never shipped). Catches what the suite, run from the checkout, can't: a module
# left out of the rock, a file it doesn't copy, memo or the MCP server not finding
# their code once installed.
#
#   bash eval/release/smoke.sh luamemo-X.Y.Z-1.rockspec   (builds it from this checkout)
#   bash eval/release/smoke.sh luamemo-X.Y.Z-1.src.rock   (the release's own rock)
#
# Env: LUAROCKS (default luarocks), LUAJIT (default luajit), SMOKE_KEEP=1 keeps the tree.
# Prints one PASS / FAIL line per check; exit 1 when any fails. The tree, home and
# project are temporary: nothing on this machine is read or changed.
set -uo pipefail

SPEC="${1:?usage: smoke.sh ROCKSPEC|ROCK}"
LUAROCKS="${LUAROCKS:-luarocks}"
# LuaRocks may run on another Lua (Debian's: lua5.1): a LUA_PATH set for LuaJIT — the
# test runner's — would hide its own modules.
LUAJIT="${LUAJIT:-luajit}"
# The rock is for Lua 5.1 (LuaJIT). Homebrew's LuaRocks defaults to Lua 5.4 — on macOS it is
# pointed at the LuaJIT install (a tree for 5.4 is one LuaJIT never reads). The distributions'
# LuaRocks is for 5.1 already (and, told so, would look for Lua 5.1's headers).
LR_LUA=()
if [[ "$(uname -s)" == Darwin ]]; then
    LR_LUA=(--lua-version 5.1
        --lua-dir "$(brew --prefix luajit 2>/dev/null || dirname "$(dirname "$(command -v "$LUAJIT")")")")
fi
lr() { env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_1 -u LUA_CPATH_5_1 "$LUAROCKS" ${LR_LUA[@]+"${LR_LUA[@]}"} "$@"; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "$SPEC" == /* ]] || SPEC="$PWD/$SPEC"
SMOKE_TMP="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "${SMOKE_TMP%/}/luamemo-smoke.XXXXXX")
TREE="$WORK/tree" HOMEDIR="$WORK/home" PROJ="$WORK/project"
mkdir -p "$HOMEDIR" "$PROJ/src"
[[ "${SMOKE_KEEP:-}" == 1 ]] || trap 'rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; [[ -n "${2:-}" ]] && printf '      %s\n' "${2:0:600}"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# The rock's version (luamemo-X.Y.Z-R.*).
VERSION=$(basename "$SPEC" | sed -E 's/^luamemo-([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+\..*$/\1/')

# ── Install (no dependency resolution: the system's luasocket is used) ──────────
# A rockspec is built from the files a release would carry — the checkout's tracked and
# new files, never ignored ones (a gguf_shim.so built here, a .luamemorc) — not the
# working tree as it is.
case "$SPEC" in
    *.rockspec)
        mkdir -p "$WORK/src"
        (cd "$REPO" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) \
            | tar -xf - -C "$WORK/src"
        out=$(cd "$WORK/src" && lr --tree "$TREE" make "$(basename "$SPEC")" --deps-mode none 2>&1) ;;
    *)          out=$(lr --tree "$TREE" install "$SPEC" --deps-mode none 2>&1) ;;
esac
if [[ -x "$TREE/bin/memo" ]]; then pass "the rock installs into a fresh tree"; else
    fail "the rock installs into a fresh tree" "$out"; echo "1 or more checks failed"; exit 1; fi

# Only the tree and the system: no checkout, no user settings, no MEMO_*.
LUAJIT_DIR=$(dirname "$(command -v "$LUAJIT")")
JQ_DIR=$(dirname "$(command -v jq)")   # memo needs jq (Homebrew's on macOS: /opt/homebrew/bin)
RUN=(env -i HOME="$HOMEDIR" PATH="$TREE/bin:$LUAJIT_DIR:$JQ_DIR:/usr/local/bin:/usr/bin:/bin" MEMO_LUA="$LUAJIT")
ROCKDIR=$(ls -d "$TREE"/lib/luarocks/rocks-5.1/luamemo/*/ 2>/dev/null | head -1)

# ── Every module loads, from the tree ───────────────────────────────────────────
mods=$("$LUAJIT" -e "local t = {} ; local f = assert(io.open('$ROCKDIR/luamemo-$VERSION-1.rockspec'))
local env = {}; local c = assert(loadstring(f:read('*a'))); setfenv(c, env); c()
for name in pairs(env.build.modules) do t[#t+1] = name end; table.sort(t); io.write(table.concat(t, ' '))" 2>&1)
# (+ where the dependencies are when they aren't in LuaJIT's own default path, as with
# Homebrew's: the trees LuaRocks knows, and the caller's module path — never the checkout)
dep_path() {
    local IFS=';' p out=""
    set -f   # (the entries hold ? — no globbing while splitting)
    for p in $1; do
        case "$p" in ""|./*|eval/*|"$REPO"/*) continue ;; esac
        out="${out:+$out;}$p"
    done
    set +f
    printf '%s' "$out"
}
DEP_PATH="$(lr path --lr-path 2>/dev/null);$(dep_path "${LUA_PATH:-}")"
DEP_CPATH="$(lr path --lr-cpath 2>/dev/null);$(dep_path "${LUA_CPATH:-}")"
bad=$(cd "$WORK" && "${RUN[@]}" LUA_PATH="$TREE/share/lua/5.1/?.lua;$TREE/share/lua/5.1/?/init.lua;$DEP_PATH;;" \
    LUA_CPATH="$DEP_CPATH;;" "$LUAJIT" -e "local bad = {}
for name in ('$mods'):gmatch('%S+') do
    local where = package.searchpath(name, package.path)
    local ok, err = pcall(require, name)
    if not ok then bad[#bad+1] = name .. ': ' .. tostring(err):sub(1, 120)
    elseif not (where or ''):find('$TREE', 1, true) then bad[#bad+1] = name .. ' loaded from ' .. tostring(where) end
end
io.write(table.concat(bad, '; '))" 2>&1)
n=$(wc -w <<<"$mods")
if [[ -z "$bad" && "$n" -gt 50 ]]; then pass "all $n modules load from the tree"; else fail "all modules load from the tree" "$bad"; fi

# ── memo, as installed ───────────────────────────────────────────────────────────
check "memo help" bash -c "cd '$WORK' && $(printf '%q ' "${RUN[@]}") memo help >/dev/null"
out=$(cd "$WORK" && "${RUN[@]}" memo ping 2>&1)
if grep -q "PASS\] SQLite" <<<"$out" && grep -q "PASS\] libsodium" <<<"$out"; then pass "memo ping: SQLite + libsodium"
else fail "memo ping: SQLite + libsodium" "$out"; fi

# The project's settings, as a user writes them (memo uses a project file memo wrote or
# its user trusted — one written by hand would be ignored).
for kv in "MEMO_DB=$WORK/smoke.db" "MEMO_SCOPE=repo:smoke" "MEMO_EMBEDDER=hash"; do
    out=$(cd "$PROJ" && "${RUN[@]}" memo config set "${kv%%=*}" "${kv#*=}" 2>&1) || fail "memo config set ${kv%%=*}" "$out"
done
out=$(cd "$PROJ/src" && "${RUN[@]}" memo write --kind fact --title "smoke deploy" --body "deploys go through the staging gate" 2>&1)
out2=$(cd "$PROJ/src" && "${RUN[@]}" memo search "staging gate" 2>&1)
if grep -q '"smoke deploy"' <<<"$out2"; then pass "memo write / search in the project's database (from a subfolder)"
else fail "memo write / search in the project's database (from a subfolder)" "$out | $out2"; fi

out=$(cd "$PROJ" && "${RUN[@]}" memo calibrate --probe-only --allow-hash --no-mcp --no-plugin 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then pass "memo calibrate --probe-only"; else fail "memo calibrate --probe-only" "$out"; fi

# ── memo mcp: the server from the rock ───────────────────────────────────────────
req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"staging gate"}}}
{"jsonrpc":"2.0","id":4,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
out=$(cd "$PROJ/src" && printf '%s\n' "$req" | "${RUN[@]}" memo mcp 2>&1)
got() { jq -r "select(.id == $1) | $2" <<<"$out" 2>/dev/null; }
[[ "$(got 1 .result.serverInfo.version)" == "$VERSION" ]] && pass "memo mcp: initialize — the rock's own server ($VERSION)" \
    || fail "memo mcp: initialize — the rock's own server ($VERSION)" "$out"
[[ "$(got 1 '.result.instructions | length')" -gt 200 ]] 2>/dev/null && pass "memo mcp: the usage rules (mcp/instructions.md is in the rock)" \
    || fail "memo mcp: the usage rules (mcp/instructions.md is in the rock)" "$(got 1 .result)"
[[ "$(got 2 '.result.tools | length')" == 27 ]] && pass "memo mcp: 27 tools" || fail "memo mcp: 27 tools" "$(got 2 .result)"
got 3 '.result.content[0].text' | grep -q "smoke deploy" && pass "memo mcp: memory_search finds the memory" \
    || fail "memo mcp: memory_search finds the memory" "$(got 3 .)"
[[ "$(got 4 .result.supportedVersions[0])" == "2026-07-28" ]] && pass "memo mcp: server/discover" \
    || fail "memo mcp: server/discover" "$(got 4 .)"
out=$(cd "$PROJ" && "${RUN[@]}" memo mcp --print-config 2>&1)
# (compared as real paths: macOS's /var is /private/var, and a TMPDIR ending in / doubles a slash)
real_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }
named=$(sed -n 's/^ *"command": "\([^"]*\)".*/\1/p' <<<"$out" | head -1)
[[ -n "$named" && "$(real_path "$named")" == "$(real_path "$TREE/bin/memo")" ]] \
    && pass "memo mcp --print-config names the installed memo" \
    || fail "memo mcp --print-config names the installed memo" "$out"

# ── What the rock copies ─────────────────────────────────────────────────────────
for f in mcp/server.lua mcp/instructions.md hooks/claude/pre_compact.sh hooks/claude/post_message.sh \
         hooks/claude/_save.sh hooks/hooks.json luamemo/embedders/native/build.sh \
         luamemo/embedders/native/gguf_shim.c; do
    [[ -f "$ROCKDIR/$f" ]] || fail "the rock ships $f"
done
[[ -f "$ROCKDIR/luamemo/embedders/native/gguf_shim.so" ]] && fail "no built gguf_shim.so in the rock"
pass "the rock ships mcp/, hooks/, the GGUF shim's source (no built .so checked above)"

echo ""
if [[ $FAILS -eq 0 ]]; then echo "smoke: all checks passed ($VERSION)"; exit 0; fi
echo "smoke: $FAILS check(s) failed"; exit 1
