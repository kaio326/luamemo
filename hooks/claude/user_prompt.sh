#!/usr/bin/env bash
# hooks/claude/user_prompt.sh
#
# UserPromptSubmit hook for Claude Code — lets memory learn from what the user says,
# without the agent having to remember to call memory_sense: the prompt (and the
# assistant's last message, for context) goes to `memo sense`, which attributes a
# correction or praise to the memory it is about and stores a standing rule ("always …",
# "from now on …") that no memory holds yet (MEMO_SENSE_CAPTURE).
#
# Claude Code runs it on the "UserPromptSubmit" event, with the hook input as JSON on
# stdin: prompt, transcript_path, cwd, …
#
# Install: `memo agent install` (memo calibrate runs it; skip with --no-agent), or by hand in
# ~/.claude/settings.json:
#   { "hooks": { "UserPromptSubmit": [
#       { "hooks": [ { "type": "command", "command": "/absolute/path/to/luamemo/hooks/claude/user_prompt.sh" } ] } ] } }
#
# Requires: memo (next to this script in a checkout or plugin, else on PATH) and jq. The
# project is the one the hook starts in (CLAUDE_PROJECT_DIR, else the input's cwd): memo
# reads its .luamemorc for the database and the scope; a project without one stores nothing.
# Never blocks and prints nothing — the work happens in the background, so the prompt is
# not delayed and nothing is added to the conversation; never exits non-zero.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
INPUT=""
[[ -t 0 ]] || INPUT=$(cat 2>/dev/null || true)
[[ -n "$INPUT" ]] || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/_project.sh" 2>/dev/null || exit 0
# (one jq for both fields; a project that does not use luamemo costs nothing: no memo is started for it)
IFS=$'\x1f' read -r CWD TRANSCRIPT < <(jq -r '"\(.cwd // "")\u001f\(.transcript_path // "")"' <<<"$INPUT" 2>/dev/null) || exit 0
PROJECT=$(luamemo_project_dir "$CWD") || exit 0
MEMO=$(luamemo_memo) || exit 0

# ── The turns: the assistant's last message (what the user is answering), then the prompt ──
PREV=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    PREV=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | jq -Rr "$LUAMEMO_JQ_DEFS"'
        fromjson? | conversation | select(.type == "assistant") | text_of | select(test("\\S"))' 2>/dev/null \
        | tail -n 1 | cut -c1-500) || PREV=""
fi
# (a prompt that is a slash command, or too short to say anything, is not a signal)
TURNS=$(jq -c --arg prev "$PREV" '
    (.prompt // "") as $p
    | select(($p | length) >= 8 and ($p | startswith("/") | not))
    | [ (if $prev != "" then {role: "assistant", text: $prev} else empty end), {role: "user", text: $p} ]' \
    <<<"$INPUT" 2>/dev/null) || exit 0
[[ -n "$TURNS" ]] || exit 0

# ── In the background, in the project: memo finds its settings from there. The embedder is not probed: a prompt
# with nothing to learn from needs none, and one that has asks it lazily (a load of the model, or a request to a
# server, for every prompt was the cost of checking first) ──
{
    cd "$PROJECT" 2>/dev/null || exit 0
    printf '%s' "$TURNS" | MEMO_SKIP_EMBED_PROBE=true bash "$MEMO" sense
} >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true
exit 0
