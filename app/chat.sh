#!/bin/sh
# D-Pad Chat - a chat client for Onion OS on the Miyoo Mini+.
#
# Runs inside Onion's bundled `st` terminal, which supplies the on-screen
# keyboard. See PLAN.md for the full design and milestone breakdown.
#
# Milestone M0: package scaffold, REPL, and command dispatch. Model responses
# are stubbed; lib/api.sh replaces chat_respond() in M1.

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
readonly APP_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$APP_DIR/lib/ui.sh"

DATA_DIR="${DPAD_DATA_DIR:-$APP_DIR/data}"

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_help() {
    ui_info '/help   this list'
    ui_info '/clear  clear the screen'
    ui_info '/about  version and paths'
    ui_info '/quit   exit'
    printf '\n'
    ui_info 'X toggles the keyboard. Hide it to read'
    ui_info 'long replies.'
}

cmd_about() {
    ui_info "version  $DPADCHAT_VERSION"
    ui_info "width    ${UI_COLS} cols"
    if is_device; then
        ui_info 'host     Miyoo (Onion OS)'
    else
        ui_info 'host     development'
    fi
    ui_info "data     $DATA_DIR"
}

# Returns 0 when the input was handled as a command, 1 when it is chat text.
dispatch_command() {
    case "$1" in
        # '/?' is quoted: unquoted, the ? is a glob and would swallow every
        # other two-character command.
        /help | /h | '/?')
            cmd_help
            ;;
        /clear | /cls)
            ui_clear
            ui_banner
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

# M1 replaces this with a call into lib/api.sh. Keeping the seam explicit means
# the REPL, rendering and command handling are all testable before any network
# code exists, and before an API key is required to run the app at all.
chat_respond() {
    log_info "prompt: $1"
    ui_assistant "Not wired up yet - this is the M0 scaffold. You typed: $1"
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

    require_cmd fold sed date

    ui_init
    ui_clear
    ui_banner
    ui_hints

    repl
}

main "$@"
