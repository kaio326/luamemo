#!/usr/bin/env bash
# hooks/claude/post_message.sh
#
# Periodic save hook for Claude Code — saves the last N messages after
# each tool use, subject to a per-session cooldown.
#
# Claude Code fires this hook as a "PostToolUse" lifecycle event.
# It provides:
#   CLAUDE_TRANSCRIPT_PATH   — path to the current session JSONL file
#   CLAUDE_SESSION_ID        — unique session identifier
#
# Install: add to .claude/settings.json in your project root:
#   {
#     "hooks": {
#       "PostToolUse": [{ "command": "/absolute/path/to/hooks/claude/post_message.sh" }]
#     }
#   }
#
# Requires: memo CLI on PATH, MEMO_DB_URL in environment, jq installed.
# Never exits non-zero — a failed save must never interfere with tool use.

set -uo pipefail

# ── Cooldown: at most one save per MEMO_HOOK_COOLDOWN_SECS (default 300 = 5min) ──
COOLDOWN="${MEMO_HOOK_COOLDOWN_SECS:-300}"
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
LOCK_DIR="${TMPDIR:-/tmp}"
LOCK_FILE="${LOCK_DIR}/memo_hook_${SESSION_ID}.last_save"

NOW=$(date +%s)
if [[ -f "$LOCK_FILE" ]]; then
    LAST=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    DIFF=$(( NOW - LAST ))
    if [[ $DIFF -lt $COOLDOWN ]]; then
        exit 0   # within cooldown window, skip
    fi
fi
# Update cooldown timestamp immediately (before the write, so a long write
# doesn't cause two concurrent saves to slip through).
echo "$NOW" > "$LOCK_FILE" 2>/dev/null || true

# ── Guard: MEMO_DB_URL must be set ───────────────────────────────────────────
if [[ -z "${MEMO_DB_URL:-}" ]]; then
    exit 0
fi

SCOPE="${MEMO_SCOPE:-session:${SESSION_ID}}"
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"
MAX_MESSAGES="${MEMO_HOOK_MAX_MESSAGES:-20}"
MAX_CHARS="${MEMO_HOOK_MAX_CHARS:-500}"

# ── Guard: no transcript ─────────────────────────────────────────────────────
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
    exit 0
fi

# ── Guard: jq must be available ──────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    exit 0
fi

# ── Extract last N messages ───────────────────────────────────────────────────
BODY=$(tail -n "$(( MAX_MESSAGES * 2 ))" "$TRANSCRIPT" \
    | jq -r '
        select(.type == "human" or .type == "assistant")
        | (if .type == "human" then "USER" else "ASSISTANT" end)
          + ": "
          + (
              if (.content | type) == "array"
              then ([ .content[] | select(.type == "text") | .text ] | join(" "))
              else (.content // "")
              end
              | .[:'"${MAX_CHARS}"']
            )
    ' 2>/dev/null \
    | tail -n "${MAX_MESSAGES}" \
    || true)

if [[ -z "$BODY" ]]; then
    exit 0
fi

TITLE="Periodic save $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Write via memo CLI ────────────────────────────────────────────────────────
memo write \
    --scope      "$SCOPE" \
    --body       "$BODY"  \
    --importance 0.4      \
    --title      "$TITLE" \
    2>/dev/null || true

exit 0
