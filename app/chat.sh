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
# shellcheck source=lib/screen.sh
. "$APP_DIR/lib/screen.sh"
# shellcheck source=lib/config.sh
. "$APP_DIR/lib/config.sh"
# shellcheck source=lib/net.sh
. "$APP_DIR/lib/net.sh"
# shellcheck source=lib/history.sh
. "$APP_DIR/lib/history.sh"
# shellcheck source=lib/api.sh
. "$APP_DIR/lib/api.sh"
# shellcheck source=lib/update.sh
. "$APP_DIR/lib/update.sh"
# shellcheck source=lib/uninstall.sh
. "$APP_DIR/lib/uninstall.sh"

DATA_DIR="${DPAD_DATA_DIR:-$APP_DIR/data}"
API_CACERT="${DPAD_CACERT:-$APP_DIR/res/cacert.pem}"

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

# The labels are padded to the longest command rather than to the shortest that
# fits, so the descriptions line up in a single column at 40 cols.
cmd_help() {
    ui_info '/help       this list'
    ui_info '/clear      start a new chat  (/c)'
    ui_info '/about      version and settings'
    ui_info '/update     check for a new version'
    ui_info '/uninstall  remove from the device'
    ui_info '/quit       exit'
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

# An empty screen is the confirmation: reporting what was just discarded leaves
# the first thing in a new chat being a note about the old one. The failure is
# still announced, because silence there would look identical to success.
cmd_new() {
    if history_is_empty; then
        screen_clear
        chat_header
        return 0
    fi

    if history_reset "$CFG_SYSTEM_PROMPT"; then
        screen_clear
        chat_header
    else
        ui_error 'Could not clear the chat.'
    fi
}

# Checking is always safe; installing is not, so it never happens without an
# answer at the prompt. What is downloaded is unpacked beside the app and left
# there: the swap belongs to launch.sh, where nothing from the app directory is
# running. See lib/update.sh for why that ordering is not optional.
cmd_update() {
    if update_is_pending; then
        ui_info 'An update is already downloaded.'
        ui_info 'Quit and reopen the app to finish it.'
        return 0
    fi

    if ! net_has_route; then
        ui_error 'No network. Connect to WiFi in Onion settings, then try again.'
        return 0
    fi

    spin_start '' 'checking'
    if update_check; then
        found=1
    else
        found=0
    fi
    spin_stop

    if [ "$found" -ne 1 ]; then
        ui_error "$UPDATE_ERROR"
        return 0
    fi

    if ! update_is_newer "$UPDATE_VERSION" "$DPADCHAT_VERSION"; then
        ui_info "Up to date (v$DPADCHAT_VERSION)."
        return 0
    fi

    printf '\n'
    ui_info "New version available:"
    ui_info "  v$DPADCHAT_VERSION  ->  v$UPDATE_VERSION"
    printf '\n'

    if ! chat_confirm 'Download and install it?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    spin_start '' 'downloading'
    if update_download_and_stage "$UPDATE_VERSION"; then
        staged=1
    else
        staged=0
    fi
    spin_stop

    if [ "$staged" -ne 1 ]; then
        ui_error "$UPDATE_ERROR"
        ui_info 'Nothing was changed.'
        return 0
    fi

    printf '\n'
    ui_info "v$UPDATE_VERSION is ready to install."
    ui_info 'Quit and reopen D-Pad Chat to finish.'
}

# Removing the app from the device itself, because the alternative is pulling
# the card and finding a computer. Onion's Apps menu is MainUI's, not ours, so
# there is nowhere else to put this: an app cannot add an entry to the menu that
# lists it.
#
# The delete happens in uninstall.sh, from a copy outside the app directory. The
# staging failure paths all end with the install untouched, which is why the
# copy is made before anything is said about deleting.
cmd_uninstall() {
    # A checkout is not an install. Deleting one from inside the app it is
    # running would take the repository's app/ directory with it, and on a dev
    # machine `rm -rf` is never the answer to a question typed at a prompt.
    if ! is_device; then
        ui_info 'Uninstall only runs on the device.'
        ui_info "This copy is a checkout at $APP_DIR"
        return 0
    fi

    printf '\n'
    ui_warn 'Uninstalling deletes this folder:'
    ui_info "  $APP_DIR"
    printf '\n'
    ui_info 'Your API key, this chat and the log go'
    ui_info 'with it. Nothing is kept, and there is'
    ui_info 'no undo.'

    # Only reachable when DPAD_DATA_DIR points somewhere else, which nothing on
    # the device does. Saying so is still cheaper than a user discovering their
    # key is still on the card after being told it was deleted.
    case "$DATA_DIR/" in
        "$APP_DIR"/*) ;;
        *)
            printf '\n'
            ui_warn 'Kept, because it is outside the app:'
            ui_warn "  $DATA_DIR"
            ;;
    esac

    printf '\n'
    if ! chat_confirm 'Uninstall D-Pad Chat?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    # Asked twice on purpose. /update can be undone by updating again; this
    # cannot be undone at all, and the on-screen keyboard makes a stray 'y'
    # easier to press than to mean.
    if ! chat_confirm 'Last chance. Delete it now?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    if ! uninstall_stage; then
        ui_error "$UNINSTALL_ERROR"
        ui_info 'Nothing was changed.'
        return 0
    fi

    log_info 'uninstalling; handing over to the remover'

    # Normally the EXIT trap's job, and `exec` never reaches it. The scroll
    # region is global terminal state: left set, it hands Onion a terminal that
    # scrolls inside two rows that are no longer there. The trap itself is left
    # armed, so an exec that fails still ends the session tidily.
    screen_teardown

    printf 'Removing D-Pad Chat...\n'
    uninstall_exec
}

# Reads the answer from the same stdin the REPL uses, so the on-screen keyboard
# works here exactly as it does at the prompt. Anything other than yes is no,
# including EOF: a closed pipe must not be read as consent to overwrite the app.
chat_confirm() {
    printf '\n%s%s [y/N] %s' "$C_USER" "$1" "$C_RESET"

    if ! IFS= read -r answer; then
        printf '\n'
        return 1
    fi

    case "$answer" in
        y | Y | yes | Yes | YES) return 0 ;;
        *) return 1 ;;
    esac
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
        /update | /upgrade)
            cmd_update
            ;;
        # No one- or two-letter form, unlike every other command here. Typing
        # the word out on a d-pad keyboard is the first of the three deliberate
        # acts this needs, and the two confirmations are the others.
        /uninstall | /remove)
            cmd_uninstall
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

# Keep the status field honest about the connection rather than only reporting
# it after something has already failed. net_has_route reads /proc/net/route, so
# this is a file read rather than a probe and is cheap enough to run before every
# prompt; screen_status only repaints when the value actually changed.
chat_refresh_status() {
    if net_has_route; then
        screen_status_from_route 1
    else
        screen_status_from_route 0
    fi
}

# The state bar already carries the name, version and model, so the banner is
# only drawn when there are no bars to carry it.
chat_header() {
    if [ "${SCREEN_BARS:-0}" -ne 1 ]; then
        ui_banner
    fi
}

# A failed request is never fatal: the message is rendered and the REPL carries
# on, because losing the session to a dropped WiFi packet would be worse than
# any error it could report.
chat_respond() {
    if ! history_append user "$1"; then
        ui_error 'Could not record the message.'
        return 0
    fi

    # The indicator runs in the background because the shell blocks inside the
    # streaming pipeline until the first token arrives. It stops itself there,
    # replacing itself with the reply; the calls below cover the paths where no
    # token ever comes.
    #
    # api_send must run in this shell, not a command substitution: its results
    # come back in API_REPLY and API_ERROR, which a subshell would discard.
    if [ "$CFG_STREAM" = 'true' ]; then
        # Opening the line before the indicator starts, not after: the writer is
        # a separate process, and a newline printed underneath it would strand a
        # stale marker on the line above. C_BOT is handed over so the reply
        # keeps its colour once the indicator's own reset has cleared it.
        ui_stream_begin
        spin_start "$C_BOT"

        if api_send_stream "$(history_path)"; then
            spin_stop
            ui_stream_end
            screen_status 'ready'
            _chat_remember "$API_REPLY"
        else
            spin_stop
            ui_stream_end
            _chat_failed
        fi
    else
        spin_start

        if api_send "$(history_path)"; then
            spin_stop
            ui_clear_line
            ui_assistant "$API_REPLY"
            screen_status 'ready'
            _chat_remember "$API_REPLY"
        else
            spin_stop
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
    # curl 6 and 7 are DNS and connect failures, the two that mean the network
    # is gone rather than the request being refused.
    case "${API_TRANSPORT:-0}" in
        6 | 7) screen_status 'offline' ;;
        *) screen_status 'error' ;;
    esac

    ui_error "$API_ERROR"
    history_drop_last
}

repl() {
    RUNNING=1
    while [ "$RUNNING" -eq 1 ]; do
        chat_refresh_status
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

# The scroll region is global terminal state, so releasing it matters more than
# the log line: without this, Onion gets a terminal that scrolls inside two
# rows that are no longer there.
on_exit() {
    screen_teardown
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
    update_init "$APP_DIR" "$DATA_DIR" "$API_CACERT"
    uninstall_init "$APP_DIR"

    ui_init
    screen_init
    chat_refresh_status
    screen_clear
    chat_header

    if [ "$HISTORY_RECOVERED" -eq 1 ]; then
        ui_warn 'The saved chat could not be read; starting a new one.'
    fi

    if [ "$HISTORY_RESUMED" -eq 1 ] && ! history_is_empty; then
        chat_replay
    elif [ "${SCREEN_BARS:-0}" -ne 1 ]; then
        # With the bars up the controls are pinned to the bottom row, so
        # printing them into the transcript as well would just be a repeat.
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
