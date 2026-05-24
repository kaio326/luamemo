#!/usr/bin/env bash
# hooks/cursor/pre_compact.sh
#
# Pre-compact hook for Cursor (0.43+) — saves the last N messages before
# the model compresses the context window.
#
# Cursor provides the same hook infrastructure as Claude Code:
#   CURSOR_SESSION_ID        — unique session identifier
#   CURSOR_TRANSCRIPT_PATH   — path to the current session JSONL file
#
# Install: add to .cursor/mcp.json in your project root:
#   {
#     "hooks": {
#       "PreCompact": [{ "command": "/absolute/path/to/hooks/cursor/pre_compact.sh" }]
#     }
#   }
#
# Requires: memo CLI on PATH, MEMO_DB_URL in environment, jq installed.
# Never exits non-zero — a failed save must never block a context compact.

set -uo pipefail

# Cursor uses CURSOR_* env vars instead of CLAUDE_*
SCOPE="${MEMO_SCOPE:-session:${CURSOR_SESSION_ID:-default}}"
TRANSCRIPT="${CURSOR_TRANSCRIPT_PATH:-}"
MAX_MESSAGES="${MEMO_HOOK_MAX_MESSAGES:-20}"
MAX_CHARS="${MEMO_HOOK_MAX_CHARS:-500}"

# ── Guard: no transcript ─────────────────────────────────────────────────────
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
    exit 0
fi

# ── Guard: MEMO_DB_URL must be set ───────────────────────────────────────────
if [[ -z "${MEMO_DB_URL:-}" ]]; then
    exit 0
fi

# ── Guard: jq must be available ──────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    exit 0
fi

# ── Extract last N messages from the JSONL transcript ────────────────────────
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

TITLE="Pre-compact save $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Write via memo CLI ────────────────────────────────────────────────────────
memo write \
    --scope      "$SCOPE" \
    --body       "$BODY"  \
    --importance 0.5      \
    --title      "$TITLE" \
    2>/dev/null || true

exit 0
