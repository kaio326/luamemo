#!/usr/bin/env bash
# hooks/claude/pre_compact.sh
#
# Pre-compact hook for Claude Code — saves the last N messages before
# the model compresses the context window.
#
# Claude Code fires this hook as a "PreCompact" lifecycle event.
# It provides:
#   CLAUDE_TRANSCRIPT_PATH   — path to the current session JSONL file
#   CLAUDE_SESSION_ID        — unique session identifier
#
# Install: add to .claude/settings.json in your project root:
#   {
#     "hooks": {
#       "PreCompact": [{ "command": "/absolute/path/to/hooks/claude/pre_compact.sh" }]
#     }
#   }
#
# Requires: memo CLI on PATH, MEMO_DB_URL in environment, jq installed.
# Never exits non-zero — a failed save must never block a context compact.

set -uo pipefail

SCOPE="${MEMO_SCOPE:-session:${CLAUDE_SESSION_ID:-default}}"
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"
MAX_MESSAGES="${MEMO_HOOK_MAX_MESSAGES:-20}"
MAX_CHARS="${MEMO_HOOK_MAX_CHARS:-500}"

# ── Guard: no transcript, skip silently ──────────────────────────────────────
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
# Each JSONL line may be a turn object with .type ("human"/"assistant") and
# .content (string or [{type:"text",text:"..."}] array).
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
# || true ensures non-zero exit from memo never propagates.
memo write \
    --scope      "$SCOPE" \
    --body       "$BODY"  \
    --importance 0.5      \
    --title      "$TITLE" \
    2>/dev/null || true

exit 0
