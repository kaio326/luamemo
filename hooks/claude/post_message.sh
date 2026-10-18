#!/usr/bin/env bash
# hooks/claude/post_message.sh
#
# Periodic save hook for Claude Code — saves the last N messages after
# each tool use, subject to a per-session cooldown.
#
# Claude Code runs it on the "PostToolUse" event, with the hook input as JSON on
# stdin (read by _save.sh, next to this file, with the saving itself).
#
# Install: in .claude/settings.json (the project's, or ~/.claude/settings.json):
#   {
#     "hooks": {
#       "PostToolUse": [
#         { "matcher": "*",
#           "hooks": [ { "type": "command", "command": "/absolute/path/to/luamemo/hooks/claude/post_message.sh" } ] }
#       ]
#     }
#   }
#
# Requires: memo CLI on PATH (set up with `memo calibrate` — the project's
# .luamemorc names its database), jq installed.
# Never exits non-zero — a failed save must never interfere with tool use.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_save.sh" || exit 0

# ── Cooldown: at most one save per MEMO_HOOK_COOLDOWN_SECS (default 300 = 5min) ──
COOLDOWN="${MEMO_HOOK_COOLDOWN_SECS:-300}"
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] || COOLDOWN=300
# In this user's own cache directory (0700), not the shared /tmp: there another user
# could plant a symlink under this predictable name and have the write below follow it.
LOCK_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/luamemo/hooks"
if [[ ! -d "$LOCK_DIR" ]]; then
    mkdir -p "$LOCK_DIR" 2>/dev/null && chmod 700 "$LOCK_DIR" 2>/dev/null || exit 0
fi
LOCK_FILE="${LOCK_DIR}/${SESSION_ID//[^A-Za-z0-9_-]/_}.last_save"

NOW=$(date +%s)
if [[ -f "$LOCK_FILE" ]]; then
    LAST=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
    if (( NOW - LAST < COOLDOWN )); then
        exit 0   # within cooldown window, skip
    fi
fi
# Update cooldown timestamp immediately (before the write, so a long write
# doesn't cause two concurrent saves to slip through).
echo "$NOW" > "$LOCK_FILE" 2>/dev/null || true

save_transcript "Periodic save $(date -u +%Y-%m-%dT%H:%M:%SZ)" 0.4
exit 0
