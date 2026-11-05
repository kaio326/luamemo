#!/usr/bin/env bash
# eval/release/eval_kit.sh VERSION [OUTDIR] — the eval kit of a release (development / CI
# only; never in the rock): the benchmark runners, their loaders, the personalization set,
# the fixtures, the baselines and the dataset list — the files luamemo.cli.eval lists
# (M.KIT_FILES), so `memo eval install --from` and this archive hold the same:
#
#   OUTDIR/luamemo-evalkit-VERSION.tar.gz          luamemo-evalkit-VERSION/<the files>
#   OUTDIR/luamemo-evalkit-VERSION.tar.gz.sha256
#
# The release attaches both and ships the checksum in the rock (luamemo/evalkit.lua,
# eval/release/write_evalkit.lua); `memo eval install` downloads the kit and checks it.
# Needs: luajit, tar, sha256sum or shasum.
set -euo pipefail

VERSION="${1:?usage: eval_kit.sh VERSION [OUTDIR]}"
OUT="${2:-dist}"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NAME="luamemo-evalkit-$VERSION"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/evalkit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

cd "$REPO"
lua_path="$REPO/?.lua;$REPO/?/init.lua;${LUA_PATH:-;}"
have=$(LUA_PATH="$lua_path" luajit -e 'io.write(require("luamemo").VERSION)')
[[ "$have" == "$VERSION" ]] || { echo "eval_kit: luamemo.VERSION is $have, not $VERSION" >&2; exit 1; }
LUA_PATH="$lua_path" luajit -e 'for _, f in ipairs(require("luamemo.cli.eval").KIT_FILES) do print(f) end' \
    > "$WORK/files"

mkdir -p "$WORK/$NAME"
n=0
while IFS= read -r f; do
    [[ -f "$f" ]] || { echo "eval_kit: $f is missing" >&2; exit 1; }
    mkdir -p "$WORK/$NAME/$(dirname "$f")"
    cp "$f" "$WORK/$NAME/$f"
    n=$((n + 1))
done < "$WORK/files"

tar -czf "$OUT/$NAME.tar.gz" -C "$WORK" "$NAME"
if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$OUT/$NAME.tar.gz")
else sum=$(shasum -a 256 "$OUT/$NAME.tar.gz"); fi
printf '%s  %s\n' "${sum%% *}" "$NAME.tar.gz" > "$OUT/$NAME.tar.gz.sha256"
echo "eval_kit: $OUT/$NAME.tar.gz ($n files)"
