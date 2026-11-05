#!/bin/sh
# hooks/claude/block_file_memory.sh
#
# PreToolUse hook for Claude Code (matcher Write|Edit|NotebookEdit) — in a project that
# uses luamemo, Claude Code's own file-based memory (~/.claude/projects/<project>/memory/,
# or $CLAUDE_CONFIG_DIR/projects/<project>/memory/) is not used: a memory kept there is
# invisible to luamemo's search, brief and learning. A write under that directory is
# denied, with the reason telling the agent to use the luamemo tools instead. A project
# without luamemo is not touched.
#
# luamemo is "set up" for a project when a .luamemorc is found from the project directory
# up (CLAUDE_PROJECT_DIR, else the input's cwd) — memo's own rule, in _project.sh next to
# this script — not counting the user's own ~/.luamemorc, which belongs to every project.
#
# Install: `memo agent install` (memo calibrate runs it; skip with --no-agent), or by hand in
# ~/.claude/settings.json:
#   { "hooks": { "PreToolUse": [ { "matcher": "Write|Edit|NotebookEdit",
#       "hooks": [ { "type": "command", "command": "/absolute/path/to/luamemo/hooks/claude/block_file_memory.sh" } ] } ] } }
#
# Requires jq. Prints nothing (allows) on any doubt; never exits non-zero. It runs before EVERY
# Write / Edit, so the common case — a path with no "memory" in it — is answered without starting jq.

INPUT=$(cat 2>/dev/null) || exit 0
case "$INPUT" in *memory*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "$0")/_project.sh" 2>/dev/null || exit 0
p=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
case "$p" in
    */.claude/projects/*/memory/*) ;;
    *)
        # (a Claude Code config directory elsewhere: $CLAUDE_CONFIG_DIR/projects/<project>/memory/…)
        [ -n "${CLAUDE_CONFIG_DIR:-}" ] || exit 0
        case "$p" in "${CLAUDE_CONFIG_DIR%/}"/projects/*/memory/*) ;; *) exit 0 ;; esac ;;
esac
luamemo_project_dir "$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)" >/dev/null || exit 0

jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
    permissionDecisionReason: "Memory files are not used in this project: luamemo is the memory. Save it with the luamemo MCP tools instead — memory_write (kind decision / fact / plan) for the thing itself, memory_sense when the user corrects you or sets a rule. Do not write under .claude/projects/*/memory/."}}'
exit 0
