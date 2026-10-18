#!/usr/bin/env bash
# hooks/claude/pre_compact.sh
#
# Pre-compact hook for Claude Code — saves the last N messages of the
# conversation before Claude Code compacts the context window.
#
# Claude Code runs it on the "PreCompact" event, with the hook input as JSON on
# stdin (read by _save.sh, next to this file, with the saving itself).
#
# Install: in .claude/settings.json (the project's, or ~/.claude/settings.json):
#   {
#     "hooks": {
#       "PreCompact": [
#         { "hooks": [ { "type": "command", "command": "/absolute/path/to/luamemo/hooks/claude/pre_compact.sh" } ] }
#       ]
#     }
#   }
#
# Requires: memo CLI on PATH (set up with `memo calibrate` — the project's
# .luamemorc names its database), jq installed.
# Never exits non-zero — a failed save must never block a context compact.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_save.sh" || exit 0

save_transcript "Pre-compact save $(date -u +%Y-%m-%dT%H:%M:%SZ)" 0.5
exit 0
