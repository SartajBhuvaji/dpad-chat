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

    # Messages kept besides the system prompt, so five exchanges. Enough for
    # "and how much RAM does it have?" to resolve, without growing the request
    # until every reply costs more than the last.
    CFG_HISTORY_MESSAGES='10'

    # Replies arrive token by token. On a 1.2 GHz CPU over WiFi the buffered
    # path is a five to ten second freeze followed by a wall of text, and the
    # device offers no other sign that it is working.
    CFG_STREAM='true'
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
    esac
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
