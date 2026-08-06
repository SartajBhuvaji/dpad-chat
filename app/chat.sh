#!/bin/sh
# D-Pad Chat - a chat client for Onion OS on the Miyoo Mini+.
#
# Runs inside Onion's bundled `st` terminal, which supplies the on-screen
# keyboard. See PLAN.md for the full design and milestone breakdown.
#
# Conversations persist across launches: relaunching resumes where you left off
# and replays the most recent turns, rather than starting over.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide; attached to a single command it only covers that line.
# shellcheck source-path=SCRIPTDIR

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
readonly APP_DIR

# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$APP_DIR/lib/ui.sh"
# shellcheck source=lib/config.sh
. "$APP_DIR/lib/config.sh"
# shellcheck source=lib/net.sh
. "$APP_DIR/lib/net.sh"
# shellcheck source=lib/history.sh
. "$APP_DIR/lib/history.sh"
# shellcheck source=lib/api.sh
. "$APP_DIR/lib/api.sh"

DATA_DIR="${DPAD_DATA_DIR:-$APP_DIR/data}"
API_CACERT="${DPAD_CACERT:-$APP_DIR/res/cacert.pem}"

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_help() {
    ui_info '/help   this list'
    ui_info '/clear  start a new chat  (/c)'
    ui_info '/about  version and settings'
    ui_info '/quit   exit'
    printf '\n'
    ui_info 'Chats are kept when you close the app.'
    printf '\n'
    ui_info 'X toggles the keyboard. Hide it to read'
    ui_info 'long replies.'

    if ! config_has_key; then
        printf '\n'
        ui_warn 'No API key set. Add this line to'
        ui_warn "$DATA_DIR/settings.cfg"
        ui_warn 'api_key=<your key>'
    fi
}

cmd_about() {
    ui_info "version  $DPADCHAT_VERSION"
    ui_info "width    ${UI_COLS} cols"
    if is_device; then
        ui_info 'host     Miyoo (Onion OS)'
    else
        ui_info 'host     development'
    fi
    ui_info "model    $CFG_MODEL"
    ui_info "key      $(config_redact_key)"
    ui_info "history  $(history_count) of $CFG_HISTORY_MESSAGES msgs"
    ui_info "stream   $CFG_STREAM"
    ui_info "tls      $(_about_tls)"
    ui_info "net      $(_about_net)"
    ui_info "data     $DATA_DIR"
}

_about_tls() {
    case "$CFG_BASE_URL" in
        https://*)
            if [ -r "$API_CACERT" ]; then
                printf 'verified (%s certs)' \
                    "$(grep -c 'BEGIN CERTIFICATE' "$API_CACERT" 2>/dev/null || printf '?')"
            else
                printf 'MISSING BUNDLE'
            fi
            ;;
        *) printf 'not used (plain http)' ;;
    esac
}

_about_net() {
    if net_has_route; then
        printf 'route ok, clock %s' "$(clock_year)"
    else
        printf 'no route'
    fi
}

# Now that chats survive a restart, clearing is the only way to lose one, so it
# says what it discarded and where the copy went.
cmd_new() {
    if history_is_empty; then
        ui_clear
        ui_banner
        ui_info 'Already a new chat.'
        return 0
    fi

    count=$(history_count)
    if history_reset "$CFG_SYSTEM_PROMPT"; then
        ui_clear
        ui_banner
        ui_info "New chat. $count messages cleared."
        ui_info 'The previous one is in data/history.json.prev'
    else
        ui_error 'Could not clear the chat.'
    fi
}

# Redraw the tail of a resumed conversation. Without this the model would carry
# context the user cannot see, and its replies would refer to things that are
# not on screen.
chat_replay() {
    total=$(history_count)
    [ "$total" -gt 0 ] || return 0

    length=$(history_length)
    shown="$CFG_REPLAY_MESSAGES"
    [ "$shown" -le "$total" ] || shown="$total"

    if [ "$shown" -lt "$total" ]; then
        ui_resume_note "$total messages, showing last $shown"
    else
        ui_resume_note "$total messages"
    fi

    index=$((length - shown))
    while [ "$index" -lt "$length" ]; do
        role=$(history_role "$index")
        content=$(history_content "$index")

        case "$role" in
            user) ui_replay_user "$content" ;;
            assistant) ui_assistant "$content" ;;
        esac

        index=$((index + 1))
    done
}

# Returns 0 when the input was handled as a command, 1 when it is chat text.
dispatch_command() {
    case "$1" in
        # '/?' is quoted: unquoted, the ? is a glob and would swallow every
        # other two-character command.
        /help | /h | '/?')
            cmd_help
            ;;
        # /clear starts a new chat rather than only clearing the screen, which
        # is what it did before conversations persisted. With persistence a
        # blank screen and a blank chat are the same thing to the user, and two
        # commands one letter apart doing different things would be worse.
        /clear | /c | /cls | /new | /reset)
            cmd_new
            ;;
        /about | /version)
            cmd_about
            ;;
        /quit | /exit | /q)
            RUNNING=0
            ;;
        /*)
            ui_error "Unknown command: $1"
            ui_info 'Try /help'
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Conversation
# -----------------------------------------------------------------------------

# A failed request is never fatal: the message is rendered and the REPL carries
# on, because losing the session to a dropped WiFi packet would be worse than
# any error it could report.
chat_respond() {
    if ! history_append user "$1"; then
        ui_error 'Could not record the message.'
        return 0
    fi

    ui_thinking

    # api_send must run in this shell, not a command substitution: its results
    # come back in API_REPLY and API_ERROR, which a subshell would discard.
    if [ "$CFG_STREAM" = 'true' ]; then
        ui_stream_begin
        if api_send_stream "$(history_path)"; then
            ui_stream_end
            _chat_remember "$API_REPLY"
        else
            ui_stream_end
            _chat_failed
        fi
    else
        if api_send "$(history_path)"; then
            ui_clear_line
            ui_assistant "$API_REPLY"
            _chat_remember "$API_REPLY"
        else
            ui_clear_line
            _chat_failed
        fi
    fi
}

_chat_remember() {
    history_append assistant "$1"
    history_trim "$CFG_HISTORY_MESSAGES"
}

# Roll back the unanswered question. Leaving it would send it again as context
# next turn, so the model would see a question it never answered and the user
# would watch it steer later replies.
_chat_failed() {
    ui_error "$API_ERROR"
    history_drop_last
}

repl() {
    RUNNING=1
    while [ "$RUNNING" -eq 1 ]; do
        printf '\n'
        ui_prompt

        # A failed read means EOF: the pipe closed, or `st` exited via Select.
        if ! IFS= read -r input; then
            printf '\n'
            break
        fi

        # Trim surrounding whitespace, which the on-screen keyboard makes easy
        # to introduce and which would otherwise defeat command matching.
        input=$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        [ -n "$input" ] || continue

        if dispatch_command "$input"; then
            continue
        fi

        chat_respond "$input"
    done
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

on_exit() {
    log_info '--- session ended ---'
}

main() {
    setup_paths
    log_init "$DATA_DIR" || die "Cannot write to data directory: $DATA_DIR"
    trap on_exit EXIT
    trap 'RUNNING=0' INT TERM

    require_cmd fold sed date curl jq mktemp

    config_load "$DATA_DIR"
    history_init "$DATA_DIR" "$CFG_SYSTEM_PROMPT" ||
        die "Cannot write history to $DATA_DIR"

    ui_init
    ui_clear
    ui_banner

    if [ "$HISTORY_RECOVERED" -eq 1 ]; then
        ui_warn 'The saved chat could not be read; starting a new one.'
    fi

    if [ "$HISTORY_RESUMED" -eq 1 ] && ! history_is_empty; then
        chat_replay
    else
        ui_hints
    fi

    # Stay in the REPL without a key: /help then explains where to put one,
    # which is more useful than exiting onto a menu with no explanation.
    if ! config_has_key; then
        printf '\n'
        ui_warn 'No API key set - /help explains how.'
    fi

    repl
}

main "$@"
