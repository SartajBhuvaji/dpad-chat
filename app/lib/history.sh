#!/bin/sh
# Conversation history.
#
# The transcript is a JSON array on disk, in the shape the API expects, with the
# system prompt pinned at index 0. A file rather than a shell variable because
# jq has to read it on every request anyway, and because a growing string in
# 128 MB of RAM is not worth the risk.
#
# The transcript persists across launches: reopening the app resumes the
# conversation, and chat.sh replays the most recent turns so the context is
# visible rather than merely implied.
#
# Clearing is therefore destructive, and deliberately so: a reset disposes of
# the conversation rather than filing a copy beside it. A transcript still
# readable on a removable card is not cleared in any sense a user would mean.

# SC2016: the jq programs below use $role, $content and $limit, which are jq
# variables bound by --arg and --argjson. Single quotes are required — letting
# the shell expand them first is exactly the interpolation bug this module
# exists to avoid.
#
# SC2034: HISTORY_RESUMED and HISTORY_RECOVERED are this module's interface,
# read by chat.sh after sourcing. Static analysis works one file at a time and
# cannot see those uses.
# shellcheck disable=SC2016,SC2034

HISTORY_FILE=''
HISTORY_RESUMED=0
HISTORY_RECOVERED=0

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------

# history_init <data-dir> <system-prompt>
history_init() {
    HISTORY_FILE="$1/history.json"
    HISTORY_RESUMED=0
    HISTORY_RECOVERED=0

    mkdir -p "$1" || return 1

    if _history_is_valid; then
        # The system prompt lives in settings, not in the transcript, so it is
        # refreshed on load. Otherwise editing it would have no effect until the
        # user happened to start a new conversation.
        _history_set_system "$2" || return 1
        HISTORY_RESUMED=1
        return 0
    fi

    if [ -f "$HISTORY_FILE" ]; then
        # A half-written file survives a battery pull. Keep it for inspection
        # rather than deleting evidence, but do not try to use it.
        log_warn 'the stored transcript could not be read; starting fresh'
        mv -f "$HISTORY_FILE" "$HISTORY_FILE.corrupt" 2>/dev/null || :
        HISTORY_RECOVERED=1
    fi

    history_reset "$2"
}

# Shape check rather than a bare parse: a file that is valid JSON but not a
# conversation would fail later, inside a request, where the error is opaque.
_history_is_valid() {
    [ -s "$HISTORY_FILE" ] || return 1
    jq -e 'type == "array"
           and length >= 1
           and .[0].role == "system"
           and all(.[]; (.role | type) == "string" and (.content | type) == "string")' \
        "$HISTORY_FILE" >/dev/null 2>&1
}

_history_set_system() {
    _history_write --arg content "$1" '.[0] = { role: "system", content: $content }'
}

# Starts a fresh transcript containing only the system prompt. The outgoing
# conversation is not kept: clearing means gone.
history_reset() {
    # Also removes the copy earlier versions filed here, so upgrading disposes
    # of the conversation they held onto rather than leaving it on the card.
    rm -f "$HISTORY_FILE.prev" 2>/dev/null || :

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

# history_role <index> / history_content <index>
#
# Indices are into the whole array, so 0 is the system prompt. Used by the
# replay, which walks the tail of the transcript one message at a time; jq
# cannot emit role and content as one line safely, because a reply may contain
# any delimiter that might be chosen.
history_role() {
    jq -r --argjson i "$1" '.[$i].role // empty' "$HISTORY_FILE" 2>/dev/null
}

history_content() {
    jq -r --argjson i "$1" '.[$i].content // empty' "$HISTORY_FILE" 2>/dev/null
}

history_length() {
    jq 'length' "$HISTORY_FILE" 2>/dev/null || printf '1'
}
