# hooks/claude/_save.sh — sourced by post_message.sh and pre_compact.sh (not a hook
# itself): reads the hook input and the limits, and save_transcript TITLE IMPORTANCE
# saves the conversation's last messages as one memory.
#
# Claude Code passes the hook input as JSON on stdin: session_id, transcript_path (the
# session's JSONL file), … The CLAUDE_SESSION_ID / CLAUDE_TRANSCRIPT_PATH variables are
# read when stdin doesn't carry them. Without jq nothing is saved (exit 0).

command -v jq &>/dev/null || exit 0

# ── Hook input (one jq call; \x1f separates the fields, so an empty one stays empty) ──
INPUT=""
[[ -t 0 ]] || INPUT=$(cat 2>/dev/null || true)
SESSION_ID="" TRANSCRIPT=""
if [[ -n "$INPUT" ]]; then
    IFS=$'\x1f' read -r SESSION_ID TRANSCRIPT \
        < <(jq -r '"\(.session_id // "")\u001f\(.transcript_path // "")"' <<<"$INPUT" 2>/dev/null) || true
fi
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
TRANSCRIPT="${TRANSCRIPT:-${CLAUDE_TRANSCRIPT_PATH:-}}"

SCOPE="${MEMO_SCOPE:-session:${SESSION_ID}}"
MAX_MESSAGES="${MEMO_HOOK_MAX_MESSAGES:-20}"
MAX_CHARS="${MEMO_HOOK_MAX_CHARS:-500}"
[[ "$MAX_MESSAGES" =~ ^[0-9]+$ ]] || MAX_MESSAGES=20
[[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || MAX_CHARS=500

# save_transcript TITLE IMPORTANCE — the last MAX_MESSAGES messages of the JSONL
# transcript as one memory in SCOPE. Claude Code's lines: {"type": "user" |
# "assistant", "message": {"content": …}} — content a string or a list of blocks, of
# which the text blocks are kept (tool calls and tool results are not conversation).
# Subagent (isSidechain) and meta lines are skipped. The older shape {"type": "human",
# "content": …} is read too. Nothing happens without a transcript or the memo CLI (it
# finds the project's database); a failed save never makes the hook fail.
save_transcript() {
    [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || return 0
    command -v memo &>/dev/null || return 0
    local body
    body=$(tail -n "$(( MAX_MESSAGES * 50 ))" "$TRANSCRIPT" \
        | jq -r --argjson max "$MAX_CHARS" '
            select((.type == "user" or .type == "human" or .type == "assistant")
                   and (.isSidechain != true) and (.isMeta != true))
            | (.message.content // .content) as $c
            | (if ($c | type) == "array"
               then [ $c[] | select(.type == "text") | .text ] | join(" ")
               else ($c // "") | tostring end
               | gsub("\\s+"; " ")) as $text
            | select($text | test("\\S"))
            | (if .type == "assistant" then "ASSISTANT" else "USER" end) + ": " + $text[:$max]
        ' 2>/dev/null \
        | tail -n "$MAX_MESSAGES" \
        || true)
    [[ -n "$body" ]] || return 0
    # The text goes on stdin, not the command line (other users can read that with ps);
    # memo scrubs anything that looks like a credential before storing it. Tier 0: raw
    # conversation is the digest's input (summarised into tier-1 memories, then removed),
    # not a memory searches return — at tier 1 every unscoped search got the whole
    # transcript chunks (three saves: 30 KB).
    printf '%s' "$body" | memo write --scope "$SCOPE" --body - --importance "$2" --tier 0 --title "$1" \
        >/dev/null 2>&1 || true
}
