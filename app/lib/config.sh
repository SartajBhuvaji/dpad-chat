#!/bin/sh
# Settings loading for D-Pad Chat.
#
# Settings live in a KEY=VALUE file under the data directory. The file is
# parsed line by line against a whitelist of known keys rather than sourced,
# because it holds the API key and sits on a removable card that anyone can
# edit: `.` or `eval` on it would execute whatever was written there.

# The CFG_* variables are this module's interface, read by api.sh and chat.sh
# after sourcing. shellcheck analyses one file at a time and cannot see those
# uses.
# shellcheck disable=SC2034

CONFIG_FILE_NAME='settings.cfg'

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

config_defaults() {
    CFG_API_KEY=''
    CFG_BASE_URL='https://api.openai.com/v1'
    CFG_MODEL='gpt-4o-mini'

    # A 640x480 panel fits roughly 25 lines of wrapped text. Capping the reply
    # keeps answers readable without scrolling and keeps latency down on a
    # 1.2 GHz CPU.
    CFG_MAX_TOKENS='512'
    CFG_SYSTEM_PROMPT='You are a helpful assistant on a handheld game console with a small screen. Answer concisely, under 120 words, unless the user asks for detail.'

    CFG_CONNECT_TIMEOUT='10'
    CFG_TIMEOUT='60'

    # Only consulted by /update, and only needed for a fork whose repository is
    # private. GitHub serves release metadata for a public repository without
    # any credential at all.
    CFG_GITHUB_TOKEN=''

    # Messages kept besides the system prompt, so five exchanges. Enough for
    # "and how much RAM does it have?" to resolve, without growing the request
    # until every reply costs more than the last.
    CFG_HISTORY_MESSAGES='10'

    # Replies arrive token by token. On a 1.2 GHz CPU over WiFi the buffered
    # path is a five to ten second freeze followed by a wall of text, and the
    # device offers no other sign that it is working.
    CFG_STREAM='true'

    # Messages replayed on screen when a conversation resumes. Two exchanges
    # fit a 640x480 panel; replaying the full retained history would push the
    # prompt off the bottom before the user has typed anything.
    CFG_REPLAY_MESSAGES='4'

    # An opening offered as ghost text at the first prompt of a session, which
    # Right accepts and any other key dismisses. Empty by default: the same
    # sentence every launch is noise, and the setting exists so that an opener
    # worth repeating - or, later, one worked out from what is being played -
    # has somewhere to come from.
    CFG_SUGGEST=''

    # Offered instead when no `suggest` is set and Onion's recently-played list
    # names a game. `{game}` is where the name goes; an empty value turns the
    # whole of it off.
    #
    # A hyphen rather than a dash, and no question after it: what follows is
    # the user's own words, and the opening exists to save them typing the part
    # that is the same every time.
    CFG_SUGGEST_GAME="I'm playing {game} -"

    # Strip trailing bracketed groups - "(USA, Europe)", "[!]" - from the name.
    # They are metadata rather than title and read as noise in a sentence. Off
    # for a title that legitimately ends in brackets.
    CFG_SUGGEST_STRIP_TAGS='true'
}

# -----------------------------------------------------------------------------
# Loading
# -----------------------------------------------------------------------------

# config_load <data-dir>
#
# Applies defaults, then the settings file, then environment overrides. The
# environment wins so the test suite can point the app at a mock server without
# writing to a settings file.
config_load() {
    config_defaults

    # Written as an `if` rather than `[ ... ] && ...`: under `set -e` the
    # and-or list would return non-zero when the file is absent, which is the
    # normal case on a fresh install, and abort startup.
    CONFIG_FILE="$1/$CONFIG_FILE_NAME"
    if [ -f "$CONFIG_FILE" ]; then
        _config_read_file "$CONFIG_FILE"
    fi

    [ -z "${DPAD_API_KEY:-}" ] || CFG_API_KEY="$DPAD_API_KEY"
    [ -z "${DPAD_BASE_URL:-}" ] || CFG_BASE_URL="$DPAD_BASE_URL"
    [ -z "${DPAD_MODEL:-}" ] || CFG_MODEL="$DPAD_MODEL"
    [ -z "${DPAD_TIMEOUT:-}" ] || CFG_TIMEOUT="$DPAD_TIMEOUT"
    [ -z "${DPAD_HISTORY_MESSAGES:-}" ] || CFG_HISTORY_MESSAGES="$DPAD_HISTORY_MESSAGES"
    [ -z "${DPAD_STREAM:-}" ] || CFG_STREAM="$DPAD_STREAM"
    [ -z "${DPAD_REPLAY_MESSAGES:-}" ] || CFG_REPLAY_MESSAGES="$DPAD_REPLAY_MESSAGES"
    [ -z "${DPAD_GITHUB_TOKEN:-}" ] || CFG_GITHUB_TOKEN="$DPAD_GITHUB_TOKEN"
    [ -z "${DPAD_SUGGEST:-}" ] || CFG_SUGGEST="$DPAD_SUGGEST"
    [ -z "${DPAD_SUGGEST_GAME:-}" ] || CFG_SUGGEST_GAME="$DPAD_SUGGEST_GAME"
    [ -z "${DPAD_SUGGEST_STRIP_TAGS:-}" ] ||
        CFG_SUGGEST_STRIP_TAGS="$DPAD_SUGGEST_STRIP_TAGS"

    _config_validate
}

_config_read_file() {
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))

        case "$line" in
            '' | '#'*) continue ;;
            *'='*) ;;
            *)
                log_warn "$CONFIG_FILE:$line_no: not a KEY=VALUE line, ignored"
                continue
                ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"

        # Tolerate ' key = value ', which is what a hand-edited file tends to
        # look like after being opened on a desktop.
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        case "$key" in
            api_key) CFG_API_KEY="$value" ;;
            base_url) CFG_BASE_URL="$value" ;;
            model) CFG_MODEL="$value" ;;
            max_tokens) CFG_MAX_TOKENS="$value" ;;
            system_prompt) CFG_SYSTEM_PROMPT="$value" ;;
            connect_timeout) CFG_CONNECT_TIMEOUT="$value" ;;
            timeout) CFG_TIMEOUT="$value" ;;
            history_messages) CFG_HISTORY_MESSAGES="$value" ;;
            stream) CFG_STREAM="$value" ;;
            replay_messages) CFG_REPLAY_MESSAGES="$value" ;;
            github_token) CFG_GITHUB_TOKEN="$value" ;;
            suggest) CFG_SUGGEST="$value" ;;
            suggest_game) CFG_SUGGEST_GAME="$value" ;;
            suggest_strip_tags) CFG_SUGGEST_STRIP_TAGS="$value" ;;
            *) log_warn "$CONFIG_FILE:$line_no: unknown setting '$key', ignored" ;;
        esac
    done <"$CONFIG_FILE"
}

# Bad values here surface as confusing curl or API errors much later, so they
# are caught at startup and replaced with the default.
_config_validate() {
    _config_require_positive_int CFG_MAX_TOKENS "$CFG_MAX_TOKENS" 512
    _config_require_positive_int CFG_CONNECT_TIMEOUT "$CFG_CONNECT_TIMEOUT" 10
    _config_require_positive_int CFG_TIMEOUT "$CFG_TIMEOUT" 60
    _config_require_positive_int CFG_HISTORY_MESSAGES "$CFG_HISTORY_MESSAGES" 10
    _config_require_positive_int CFG_REPLAY_MESSAGES "$CFG_REPLAY_MESSAGES" 4

    case "$CFG_BASE_URL" in
        http://* | https://*) ;;
        *)
            log_warn "base_url must start with http:// or https://, got '$CFG_BASE_URL'"
            CFG_BASE_URL='https://api.openai.com/v1'
            ;;
    esac

    case "$CFG_STREAM" in
        true | false) ;;
        *)
            log_warn "stream must be true or false, got '$CFG_STREAM'; using true"
            CFG_STREAM='true'
            ;;
    esac

    case "$CFG_SUGGEST_STRIP_TAGS" in
        true | false) ;;
        *)
            log_warn "suggest_strip_tags must be true or false, got '$CFG_SUGGEST_STRIP_TAGS'; using true"
            CFG_SUGGEST_STRIP_TAGS='true'
            ;;
    esac

    # A trailing slash would produce a double slash in the request path, which
    # some proxies reject.
    CFG_BASE_URL="${CFG_BASE_URL%/}"
}

_config_require_positive_int() {
    name="$1"
    value="$2"
    fallback="$3"

    case "$value" in
        '' | *[!0-9]*)
            log_warn "$name must be a positive integer, got '$value'; using $fallback"
            ;;
        *)
            if [ "$value" -gt 0 ]; then
                return 0
            fi
            log_warn "$name must be greater than zero; using $fallback"
            ;;
    esac

    # No indirect assignment in POSIX sh, so the cases are spelled out.
    case "$name" in
        CFG_MAX_TOKENS) CFG_MAX_TOKENS="$fallback" ;;
        CFG_CONNECT_TIMEOUT) CFG_CONNECT_TIMEOUT="$fallback" ;;
        CFG_TIMEOUT) CFG_TIMEOUT="$fallback" ;;
        CFG_HISTORY_MESSAGES) CFG_HISTORY_MESSAGES="$fallback" ;;
        CFG_REPLAY_MESSAGES) CFG_REPLAY_MESSAGES="$fallback" ;;
    esac
}

# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------

# config_set <key> <value>
#
# Rewrites one setting in the settings file, leaving everything else exactly as
# it was. Called by /config, so the file it edits is one somebody may well have
# hand-written on a card: comments, spacing, blank lines and settings this
# version has never heard of all have to survive, because losing a comment
# somebody typed on a handheld is not a fair price for changing a number.
#
# The key is assumed to be one of the known ones; the caller matched it against
# a list before getting here.
config_set() {
    _cs_key="$1"
    _cs_value="$2"

    [ -n "${CONFIG_FILE:-}" ] || return 1

    _cs_dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$_cs_dir" 2>/dev/null || return 1

    # Written beside the target and moved over it, so an interrupted write
    # cannot leave a truncated settings file - which on this file means an app
    # that comes back with no API key.
    _cs_tmp="$CONFIG_FILE.new"

    # The file carries the API key, so it is created private and stays private.
    # FAT32 keeps none of this, but a card imaged onto a real filesystem does.
    (
        umask 077

        _cs_done=0
        if [ -f "$CONFIG_FILE" ]; then
            while IFS= read -r _cs_line || [ -n "$_cs_line" ]; do
                # Only a line that actually sets this key is replaced. A
                # comment mentioning it, or a line for a different key, is
                # copied through untouched.
                case "$_cs_line" in
                    '#'* | *'='*) ;;
                    *)
                        printf '%s\n' "$_cs_line"
                        continue
                        ;;
                esac

                _cs_this=$(printf '%s' "${_cs_line%%=*}" | tr -d '[:space:]')

                if [ "$_cs_this" = "$_cs_key" ] && [ "$_cs_done" -eq 0 ]; then
                    printf '%s=%s\n' "$_cs_key" "$_cs_value"
                    _cs_done=1
                elif [ "$_cs_this" = "$_cs_key" ]; then
                    # A duplicate. The loader takes the last one, so leaving it
                    # would silently undo the write.
                    continue
                else
                    printf '%s\n' "$_cs_line"
                fi
            done <"$CONFIG_FILE"
        fi

        [ "$_cs_done" -eq 1 ] || printf '%s=%s\n' "$_cs_key" "$_cs_value"
    ) >"$_cs_tmp" 2>/dev/null || {
        rm -f "$_cs_tmp" 2>/dev/null || :
        return 1
    }

    chmod 600 "$_cs_tmp" 2>/dev/null || :
    mv -f "$_cs_tmp" "$CONFIG_FILE" 2>/dev/null || {
        rm -f "$_cs_tmp" 2>/dev/null || :
        return 1
    }

    return 0
}

# -----------------------------------------------------------------------------
# Queries
# -----------------------------------------------------------------------------

config_has_key() {
    [ -n "$CFG_API_KEY" ]
}

# Never print a key in full: the screen is the one place a shoulder-surfer or a
# screenshot in a bug report will catch it.
config_redact_key() {
    if [ -z "$CFG_API_KEY" ]; then
        printf 'not set'
    else
        printf '%s...%s' "$(printf '%s' "$CFG_API_KEY" | cut -c1-6)" \
            "$(printf '%s' "$CFG_API_KEY" | tail -c 5)"
    fi
}
