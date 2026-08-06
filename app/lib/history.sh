#!/bin/sh
# Conversation history.
#
# The transcript is a JSON array on disk, in the shape the API expects, with the
# system prompt pinned at index 0. A file rather than a shell variable because
# jq has to read it on every request anyway, and because a growing string in
# 128 MB of RAM is not worth the risk.
#
# History is per session: history_init truncates it at startup. Persistence
# across launches is deliberately out of scope for v1 (see PLAN.md section 13) —
# resuming a conversation you cannot see the start of is more confusing than
# beginning a new one.

# The jq programs below use $role, $content and $limit, which are jq variables
# bound by --arg and --argjson. Single quotes are required: letting the shell
# expand them first is exactly the interpolation bug this module exists to
# avoid.
# shellcheck disable=SC2016

HISTORY_FILE=''

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------

# history_init <data-dir> <system-prompt>
history_init() {
    HISTORY_FILE="$1/history.json"
    mkdir -p "$1" || return 1
    history_reset "$2"
}

# Starts a fresh transcript containing only the system prompt.
history_reset() {
    jq -n --arg content "$1" '[{ role: "system", content: $content }]' \
        >"$HISTORY_FILE" || return 1
}

history_path() {
    printf '%s' "$HISTORY_FILE"
}

# -----------------------------------------------------------------------------
# Mutation
# -----------------------------------------------------------------------------

# Every write goes through jq and a temporary file. jq does the escaping, so an
# apostrophe or a newline in a reply cannot corrupt the transcript; the rename
# means a failure part-way through leaves the previous transcript intact rather
# than a truncated one.
_history_write() {
    tmp="$HISTORY_FILE.tmp"
    if jq "$@" "$HISTORY_FILE" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$HISTORY_FILE"
        return 0
    fi
    rm -f "$tmp"
    log_error "history write failed: $*"
    return 1
}

# history_append <role> <content>
history_append() {
    _history_write --arg role "$1" --arg content "$2" \
        '. + [{ role: $role, content: $content }]'
}

# Removes the most recent entry. Used to roll back a question whose request
# failed: leaving it in would send it again as context on the next turn, so the
# model would see a question that was never answered and the user would see it
# silently influencing later replies.
history_drop_last() {
    _history_write '.[0:-1]'
}

# Keeps the system prompt and the most recent messages. The limit is on
# messages rather than exchanges because a failed turn can leave an odd number.
history_trim() {
    _history_write --argjson limit "$1" '.[0:1] + (.[1:] | .[-$limit:])'
}

# -----------------------------------------------------------------------------
# Queries
# -----------------------------------------------------------------------------

# Messages excluding the system prompt, which is an implementation detail the
# user never typed and should not be counted as part of their conversation.
history_count() {
    jq 'length - 1' "$HISTORY_FILE" 2>/dev/null || printf '0'
}

history_is_empty() {
    [ "$(history_count)" -eq 0 ]
}
