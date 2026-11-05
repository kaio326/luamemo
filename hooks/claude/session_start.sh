#!/usr/bin/env bash
# hooks/claude/session_start.sh
#
# SessionStart hook for Claude Code — injects `memo brief` (a few lines: how many memories
# the project has, whether it has a code map, what waits for the user) into the session's
# context, so the agent knows what it can draw on without being asked. The plugin's
# hooks.json and `memo agent install` (in ~/.claude/settings.json) both run this script.
#
# Claude Code adds only hookSpecificOutput.additionalContext to the context (plain stdout
# is not reliably injected), so the brief is wrapped in it. A project without a .luamemorc
# gets nothing — except when LUAMEMO_ANY_PROJECT=1 (the plugin's hooks.json sets it: the plugin
# is luamemo's own, so the brief comes from the global ~/.luamemorc). memo is run through bash (an exec bit may not survive a checkout) and the
# brief is capped by memo itself; the hook never blocks or fails the session.
#
# Requires: memo (see _project.sh: $MEMO_BIN, next to this script, or on PATH) and jq.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/_project.sh" 2>/dev/null || exit 0
INPUT=""
[[ -t 0 ]] || INPUT=$(cat 2>/dev/null || true)
[[ -n "$INPUT" ]] || INPUT='{}'
PROJECT=$(luamemo_project_dir "$(jq -r '.cwd // ""' <<<"$INPUT" 2>/dev/null)") || {
    # (the plugin sets LUAMEMO_ANY_PROJECT: it is luamemo's own, and memo finds its settings, a global ~/.luamemorc
    # included, from wherever the session starts)
    [[ -n "${LUAMEMO_ANY_PROJECT:-}" ]] || exit 0
    PROJECT="${CLAUDE_PROJECT_DIR:-.}"
}
MEMO=$(luamemo_memo) || exit 0
# (the brief only reads the database: the embedder is not probed)
d=$(cd "$PROJECT" 2>/dev/null && MEMO_SKIP_EMBED_PROBE=true bash "$MEMO" brief 2>/dev/null) || exit 0
[[ -n "$d" ]] || exit 0
printf '%s' "$d" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null || true
exit 0
