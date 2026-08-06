#!/bin/sh
# Terminal rendering for D-Pad Chat.
#
# Everything here targets `st` on a 640x480 panel, where horizontal space is
# the scarcest resource. All output is wrapped to the detected column count.

# Fallback width when the terminal does not report a size. `st` runs at a fixed
# resolution, so a wrong guess is consistently wrong rather than intermittent.
UI_DEFAULT_COLS=40
UI_MIN_COLS=20

# -----------------------------------------------------------------------------
# Capabilities
# -----------------------------------------------------------------------------

ui_init() {
    UI_COLS=$(_detect_cols)

    # Honour NO_COLOR (https://no-color.org) and skip escapes when redirected,
    # which keeps piped output clean for the test harness.
    if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
        C_RESET='' C_DIM='' C_BOLD='' C_USER='' C_BOT='' C_WARN=''
    else
        C_RESET=$(printf '\033[0m')
        C_DIM=$(printf '\033[2m')
        C_BOLD=$(printf '\033[1m')
        C_USER=$(printf '\033[36m')
        C_BOT=$(printf '\033[32m')
        C_WARN=$(printf '\033[33m')
    fi
}

_detect_cols() {
    cols=''

    # COLUMNS is set explicitly by the Docker harness to pin the device width.
    if [ -n "${COLUMNS:-}" ]; then
        cols="$COLUMNS"
    elif command -v stty >/dev/null 2>&1; then
        cols=$(stty size 2>/dev/null | cut -d' ' -f2)
    fi

    case "$cols" in
        '' | *[!0-9]*) cols="$UI_DEFAULT_COLS" ;;
    esac
    [ "$cols" -ge "$UI_MIN_COLS" ] || cols="$UI_DEFAULT_COLS"

    printf '%s' "$cols"
}

# -----------------------------------------------------------------------------
# Primitives
# -----------------------------------------------------------------------------

ui_clear() {
    [ -t 1 ] && printf '\033[2J\033[H'
    return 0
}

ui_hr() {
    i=0
    line=''
    while [ "$i" -lt "$UI_COLS" ]; do
        line="$line-"
        i=$((i + 1))
    done
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
}

# Wrap on whitespace to the terminal width. `fold -s` is a busybox applet and
# is present on the device; the tr/awk path would cost a second process.
ui_wrap() {
    fold -s -w "$UI_COLS"
}

# DPADCHAT_VERSION comes from common.sh; the default keeps this file usable on
# its own, which is what the unit-level tests source.
ui_banner() {
    printf '%s%s%s' "$C_BOLD" 'D-Pad Chat' "$C_RESET"
    printf ' %sv%s%s\n' "$C_DIM" "${DPADCHAT_VERSION:-dev}" "$C_RESET"
    ui_hr
}

ui_hints() {
    printf '%sX keyboard  Start send  Select quit%s\n' "$C_DIM" "$C_RESET"
    printf '%s/help for commands%s\n' "$C_DIM" "$C_RESET"
}

# -----------------------------------------------------------------------------
# Messages
# -----------------------------------------------------------------------------

ui_info() {
    printf '%s\n' "$*" | ui_wrap
}

ui_warn() {
    printf '%s%s%s\n' "$C_WARN" "$*" "$C_RESET" | ui_wrap
}

# Rendered in the shape described in PLAN.md section 4.7. Errors are never
# fatal to the REPL; the caller returns to the prompt afterwards.
ui_error() {
    printf '\n%s !  %s%s\n' "$C_WARN" "$*" "$C_RESET" | ui_wrap
    printf '\n'
}

ui_assistant() {
    printf '\n%s' "$C_BOT"
    printf '%s\n' "$*" | ui_wrap
    printf '%s\n' "$C_RESET"
}

# Written without a trailing newline so the cursor sits after the caret while
# the on-screen keyboard is open.
ui_prompt() {
    printf '%s> %s' "$C_USER" "$C_RESET"
}

# A request can take several seconds over WiFi on this hardware. Without a
# marker the device looks frozen, and the obvious reaction is to press buttons.
ui_thinking() {
    printf '\n%sthinking...%s' "$C_DIM" "$C_RESET"
}

# Erase the thinking marker before the reply lands. Falls back to a newline
# where the escape would be printed literally, as in piped test output.
ui_clear_line() {
    if [ -t 1 ]; then
        printf '\r\033[K'
    else
        printf '\n'
    fi
}
