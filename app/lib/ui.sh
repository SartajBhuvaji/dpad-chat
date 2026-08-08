#!/bin/sh
# Terminal rendering for D-Pad Chat.
#
# Everything here targets `st` on a 640x480 panel, where horizontal space is
# the scarcest resource. All output is wrapped to the detected column count.

# Fallback width when the terminal does not report a size. `st` runs at a fixed
# resolution, so a wrong guess is consistently wrong rather than intermittent.
#
# 53 is measured, not estimated: it is what `/about` reports on the device. It
# also settles what st is doing, which was guesswork before - 320 pixels across
# at 6 pixels a glyph is 53 columns with nothing left for a border, so the
# doubling to 640 happens after the grid is worked out.
UI_DEFAULT_COLS=53
UI_MIN_COLS=20

# -----------------------------------------------------------------------------
# Capabilities
# -----------------------------------------------------------------------------

ui_init() {
    UI_COLS=$(_detect_cols)

    # Honour NO_COLOR (https://no-color.org) and skip escapes when redirected,
    # which keeps piped output clean for the test harness.
    if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
        C_RESET='' C_DIM='' C_BOLD='' C_UNBOLD='' C_USER='' C_BOT='' C_WARN=''
    else
        C_RESET=$(printf '\033[0m')
        C_DIM=$(printf '\033[2m')
        C_BOLD=$(printf '\033[1m')
        # Normal intensity, not a full reset: a reply is drawn inside a colour,
        # and resetting everything would leave the rest of it uncoloured.
        C_UNBOLD=$(printf '\033[22m')
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

# Markdown emphasis, rendered rather than shown. Models emit **bold** whatever
# the system prompt says, and on a 53-column screen the markers are noise.
#
# Only `**` is handled. A single `*` is a bullet or a multiplication sign far
# more often than it is emphasis, and turning those into escapes would be worse
# than leaving them be.
#
# The separator is held in a variable rather than written into the patterns.
# `*` is a wildcard in a parameter expansion, so it has to be quoted to be
# literal - and a quoted pattern is exactly what Onion's busybox reads
# differently, which is how `{game}` reached a device unsubstituted.
UI_MD_BOLD='**'

ui_markdown() {
    # Colour off means escapes off, not formatting discarded. With nothing to
    # put in their place the markers are what carries the emphasis, so they
    # stay - which is also what keeps piped output the same as it always was.
    if [ -z "${C_BOLD:-}" ]; then
        printf '%s' "$1"
        return 0
    fi

    _md_rest="$1"
    _md_out=''
    _md_open=0

    while :; do
        case "$_md_rest" in
            *"$UI_MD_BOLD"*) ;;
            *) break ;;
        esac

        _md_out="$_md_out${_md_rest%%"$UI_MD_BOLD"*}"
        _md_rest="${_md_rest#*"$UI_MD_BOLD"}"

        if [ "$_md_open" -eq 0 ]; then
            _md_out="$_md_out$C_BOLD"
            _md_open=1
        else
            _md_out="$_md_out$C_UNBOLD"
            _md_open=0
        fi
    done

    printf '%s%s' "$_md_out" "$_md_rest"
}

# Wrapped first, then rendered. `fold` counts bytes, so escapes inserted before
# it would be counted as visible columns and every line would come out short.
# `**` carries no newline, so folding cannot separate a marker from its pair.
ui_assistant() {
    printf '\n%s' "$C_BOT"
    ui_markdown "$(printf '%s\n' "$*" | ui_wrap)"
    printf '\n%s\n' "$C_RESET"
}

# Columns ui_prompt occupies. The colours around it are escapes and take no
# space on screen, so this counts the caret and the space after it. The line
# editor needs it to know which column a typed line starts in.
#
# Read by chat.sh rather than here; static analysis works one file at a time
# and cannot see that use.
# shellcheck disable=SC2034
UI_PROMPT_COLS=2

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

# A replayed turn is shown the way it was originally typed, so the transcript
# on screen reads the same as it did before the app was closed.
ui_replay_user() {
    printf '\n%s> %s%s\n' "$C_USER" "$*" "$C_RESET" | ui_wrap
}

# Marks where an earlier session ended, so resumed context is never mistaken
# for something typed just now.
ui_resume_note() {
    printf '%s-- resumed: %s --%s\n' "$C_DIM" "$*" "$C_RESET" | ui_wrap
}

# Streaming writes straight to the terminal as tokens arrive, so the colour has
# to be opened before the reply starts and closed after it ends.
ui_stream_begin() {
    printf '\n%s' "$C_BOT"
}

ui_stream_end() {
    printf '%s\n' "$C_RESET"
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
