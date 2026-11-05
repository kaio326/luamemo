# hooks/claude/_project.sh — sourced by the agent hooks (not a hook itself): which project luamemo is set up for, which
# memo to run, how to read a transcript.
#
# luamemo_project_dir [START] → prints the project's directory when luamemo is set up
# for it, and returns 0; returns 1 (prints nothing) otherwise. "Set up" is memo's own
# rule: a .luamemorc from the project directory up — the user's own ~/.luamemorc is
# every project's and does not count, nor does a project file that is a link to it.
# START: CLAUDE_PROJECT_DIR, else the hook input's cwd (passed by the caller), else the
# current directory.
#
# luamemo_memo → prints the memo to run: $MEMO_BIN (the installer pins it), else the
# one next to these hooks (a checkout or the plugin), else the one on PATH; returns 1
# when there is none.
#
# POSIX sh: the hooks that source it run under sh or bash. No process is started to walk
# up the directories.

luamemo_project_dir() {
    _lm_d="${CLAUDE_PROJECT_DIR:-${1:-$PWD}}"
    _lm_home="${HOME%/}"
    while [ -n "$_lm_d" ] && [ "$_lm_d" != / ] && [ "$_lm_d" != . ]; do
        if [ "$_lm_d" != "$_lm_home" ] && [ -f "$_lm_d/.luamemorc" ] \
            && ! { [ -f "$_lm_home/.luamemorc" ] && [ "$_lm_d/.luamemorc" -ef "$_lm_home/.luamemorc" ]; }; then
            printf '%s' "$_lm_d"
            return 0
        fi
        case "$_lm_d" in */*) _lm_d="${_lm_d%/*}" ;; *) break ;; esac
    done
    return 1
}

# LUAMEMO_JQ_DEFS — jq definitions for reading a Claude Code transcript (JSONL, one message a line:
# {"type": "user" | "assistant", "message": {"content": a string or a list of blocks}}): `conversation`
# keeps the conversation's lines (not subagent or meta ones; the older "human" type too) and `text_of` is a
# message's text — its text blocks only (tool calls and results are not conversation), whitespace collapsed.
# Prepend it to a jq program.
LUAMEMO_JQ_DEFS='
def conversation: select((.type == "user" or .type == "human" or .type == "assistant")
    and (.isSidechain != true) and (.isMeta != true));
def text_of: ((.message.content // .content) as $c
    | (if ($c | type) == "array" then [ $c[] | select(.type == "text") | .text ] | join(" ")
       else ($c // "") | tostring end)
    | gsub("\\s+"; " "));
'

luamemo_memo() {
    if [ -n "${MEMO_BIN:-}" ] && [ -f "$MEMO_BIN" ]; then printf '%s' "$MEMO_BIN"; return 0; fi
    _lm_here=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || _lm_here=""
    if [ -n "$_lm_here" ] && [ -f "$_lm_here/../../cli/memo" ]; then printf '%s' "$_lm_here/../../cli/memo"; return 0; fi
    command -v memo 2>/dev/null
}
