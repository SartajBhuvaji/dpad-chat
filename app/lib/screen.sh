#!/bin/sh
# Pinned status bars and the waiting indicator for D-Pad Chat.
#
# ui.sh renders text that scrolls. This file owns the two rows that do not
# scroll, and the one process that writes to the screen while the shell is
# blocked waiting on a reply.
#
# The bars stay put because of DECSTBM: `ESC [ 2 ; <rows-1> r` restricts
# scrolling to the rows between them, so the transcript moves underneath with
# no per-line redraw. The region is global terminal state and must be released
# on the way out, or Onion inherits a terminal that scrolls wrong.

# SCREEN_* and SPIN_* are this module's interface, read by chat.sh and api.sh
# after sourcing. shellcheck analyses one file at a time and cannot see those
# uses.
# shellcheck disable=SC2034

SCREEN_DEFAULT_ROWS=30

# Below this there is no room for two bars and a usable transcript, so the
# bars are dropped rather than squeezing the conversation into three rows.
SCREEN_MIN_ROWS=8

# Width of the right-hand status field. Fixed so the bar never reflows as the
# text inside it changes length.
SCREEN_FIELD=8

# Black on yellow for state, black on white for the controls. Both are plain
# 16-colour SGR; the bright 90-107 range is not guaranteed on this terminal.
SCREEN_SGR_STATE='\033[30;43m'
SCREEN_SGR_KEYS='\033[30;47m'

SCREEN_KEYS_LEFT=' X keys  Start send  Select quit'
SCREEN_KEYS_RIGHT='/help '

SCREEN_APP_NAME='D-Pad Chat'

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

screen_init() {
    SCREEN_ROWS=$(_screen_detect_rows)
    SCREEN_STATUS='ready'
    SCREEN_BARS=0
    SPIN_PID=''
    SPIN_STOP_FILE=''

    # The spinner writes to stderr (see _spin_loop), the bars to stdout, so
    # each is gated on the stream it actually uses.
    if [ -t 2 ]; then
        SPIN_TTY=1
    else
        SPIN_TTY=0
    fi

    if [ -t 1 ] && [ "$SCREEN_ROWS" -ge "$SCREEN_MIN_ROWS" ]; then
        SCREEN_BARS=1
        printf '\033[2;%dr' "$((SCREEN_ROWS - 1))"
    fi

    _spin_init_tick
}

_screen_detect_rows() {
    rows=''

    # LINES is set explicitly by the Docker harness to pin the device height.
    if [ -n "${LINES:-}" ]; then
        rows="$LINES"
    elif command -v stty >/dev/null 2>&1; then
        rows=$(stty size 2>/dev/null | cut -d' ' -f1)
    fi

    case "$rows" in
        '' | *[!0-9]*) rows="$SCREEN_DEFAULT_ROWS" ;;
    esac

    printf '%s' "$rows"
}

# Release the scroll region and hand back a clean screen. Called from the EXIT
# trap, so it must be safe to run twice and safe to run when nothing was set up.
screen_teardown() {
    spin_stop
    if [ "${SCREEN_BARS:-0}" -eq 1 ]; then
        printf '\033[r\033[2J\033[H'
        SCREEN_BARS=0
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Bars
# -----------------------------------------------------------------------------

# Clear the transcript and park the cursor on the first scrolling row. Replaces
# ui_clear once the bars are up, because ui_clear homes the cursor onto row 1,
# which is the state bar.
screen_clear() {
    if [ "${SCREEN_BARS:-0}" -ne 1 ]; then
        ui_clear
        return 0
    fi
    printf '\033[2J'
    screen_draw
    printf '\033[2;1H'
}

screen_draw() {
    [ "${SCREEN_BARS:-0}" -eq 1 ] || return 0

    # Save and restore the cursor around the bars: the transcript is mid-line
    # whenever a redraw is triggered by something other than a clear.
    printf '\033[s'
    printf '\033[1;1H%b%s\033[0m' "$SCREEN_SGR_STATE" "$(_screen_state_bar)"
    printf '\033[%d;1H%b%s\033[0m' "$SCREEN_ROWS" "$SCREEN_SGR_KEYS" \
        "$(_screen_keys_bar)"
    printf '\033[u'
}

# screen_status <text>
#
# Repaints only when the text actually changed: a redraw moves the cursor, and
# doing it on every turn for the same value is a visible flicker on this panel.
screen_status() {
    [ "$1" != "${SCREEN_STATUS:-}" ] || return 0
    SCREEN_STATUS="$1"
    screen_draw
}

# screen_status_from_route <1 when a default route exists, 0 when not>
#
# The connection half of the status field. A failed request outranks a working
# route: that the interface is up is not news when the last thing sent over it
# still came back an error, so 'error' is left alone until something succeeds.
screen_status_from_route() {
    if [ "$1" -eq 1 ]; then
        if [ "${SCREEN_STATUS:-}" = 'offline' ]; then
            screen_status 'ready'
        fi
    else
        screen_status 'offline'
    fi
}

_screen_state_bar() {
    _screen_compose " $SCREEN_APP_NAME  ${CFG_MODEL:-}" \
        "$(_screen_field "$SCREEN_STATUS") "
}

_screen_keys_bar() {
    _screen_compose "$SCREEN_KEYS_LEFT" "$SCREEN_KEYS_RIGHT"
}

# Left text, then spaces, then right text, totalling exactly UI_COLS. The left
# side is trimmed when the two would collide, because the right side carries
# the state and is the half worth keeping.
_screen_compose() {
    _c_left="$1"
    _c_right="$2"

    if [ $((${#_c_left} + ${#_c_right})) -gt "$UI_COLS" ]; then
        _c_left=$(_screen_fit "$_c_left" $((UI_COLS - ${#_c_right})))
    fi

    _c_gap=''
    _c_i=$((${#_c_left} + ${#_c_right}))
    while [ "$_c_i" -lt "$UI_COLS" ]; do
        _c_gap="$_c_gap "
        _c_i=$((_c_i + 1))
    done

    printf '%s%s%s' "$_c_left" "$_c_gap" "$_c_right"
}

# Right-align into SCREEN_FIELD columns.
_screen_field() {
    _f_text=$(_screen_fit "$1" "$SCREEN_FIELD")
    _f_pad=''
    _f_i="${#_f_text}"
    while [ "$_f_i" -lt "$SCREEN_FIELD" ]; do
        _f_pad="$_f_pad "
        _f_i=$((_f_i + 1))
    done
    printf '%s%s' "$_f_pad" "$_f_text"
}

# POSIX sh has no substring operator, so trimming is done one character at a
# time with ${var%?}. The strings here are one screen wide at most.
_screen_fit() {
    _t_text="$1"
    _t_max="$2"

    if [ "$_t_max" -le 0 ]; then
        return 0
    fi

    while [ "${#_t_text}" -gt "$_t_max" ]; do
        _t_text="${_t_text%?}"
    done

    printf '%s' "$_t_text"
}

# -----------------------------------------------------------------------------
# Waiting indicator
# -----------------------------------------------------------------------------

# Smooth motion needs a sub-second tick, which busybox only provides when it
# was compiled with fancy sleep. Without it `sleep 0.1` is a hard error rather
# than a silent no-op, so asking costs one fork and answers immediately.
#
# A build that accepted the argument and then ignored it would spin the loop
# below at CPU speed, so _spin_loop keeps a guard for that case rather than
# trusting this result outright.
_spin_init_tick() {
    if sleep 0.1 2>/dev/null; then
        SPIN_TICK='0.1'
        SPIN_FPS=10
    else
        SPIN_TICK='1'
        SPIN_FPS=1
    fi
    return 0
}

_spin_glyph() {
    _g_n="$1"
    # A single-quoted backslash is one literal backslash and needs no escaping;
    # shellcheck reads it as a misplaced quote escape.
    # shellcheck disable=SC1003
    case $((_g_n % 4)) in
        0) SPIN_GLYPH='-' ;;
        1) SPIN_GLYPH='\' ;;
        2) SPIN_GLYPH='|' ;;
        *) SPIN_GLYPH='/' ;;
    esac
}

# Everything here goes to stderr. spin_stop is called from inside the streaming
# pipeline, where stdout is jq's input and anything written to it would be
# parsed as JSON.
_spin_loop() {
    _l_frames=0
    _l_start=$(date +%s)
    _l_guard=1

    while [ ! -f "$SPIN_STOP_FILE" ]; do
        _l_secs=$((_l_frames / SPIN_FPS))

        if [ "$SPIN_FPS" -gt 1 ]; then
            _spin_glyph "$_l_frames"
            printf '\r%s%s thinking %ss%s' "$C_DIM" "$SPIN_GLYPH" "$_l_secs" \
                "$C_RESET" >&2
        else
            printf '\r%sthinking %ss%s' "$C_DIM" "$_l_secs" "$C_RESET" >&2
        fi

        _l_frames=$((_l_frames + 1))
        sleep "$SPIN_TICK"

        # Two seconds' worth of frames should take at least one second of wall
        # clock. Finishing them sooner means `sleep` accepted the fractional
        # argument and ignored it, so drop to the tick that always works. One
        # date(1) call per request, and only while the fast tick is in use.
        if [ "$_l_guard" -eq 1 ] && [ "$_l_frames" -ge $((SPIN_FPS * 2)) ]; then
            _l_guard=0
            if [ $(($(date +%s) - _l_start)) -lt 1 ]; then
                SPIN_FPS=1
                SPIN_TICK='1'
                _l_frames=0
            fi
        fi
    done
}

# spin_start [restore-sequence]
#
# Each frame ends with a colour reset, which would also cancel the colour the
# caller opened for the reply that follows. The restore sequence is re-emitted
# by spin_stop so the reply streams in the colour it was meant to have.
spin_start() {
    SPIN_PID=''
    SPIN_RESTORE="${1:-}"

    # Piped output gets one static line instead of an animation: redrawing with
    # \r into a pipe produces a wall of repeated text, but printing nothing at
    # all would leave a session run over SSH with no sign it is working.
    if [ "${SPIN_TTY:-0}" -ne 1 ]; then
        printf 'thinking...\n' >&2
        return 0
    fi

    SPIN_STOP_FILE="${TMPDIR:-/tmp}/dpad-spin.$$"
    rm -f "$SPIN_STOP_FILE" 2>/dev/null || :

    _spin_loop &
    SPIN_PID=$!
    return 0
}

# Safe to call more than once per request, and safe to call from the streaming
# pipeline's subshell, where the loop is a sibling rather than a child: the
# stop file ends it even when the kill is the one that does not land.
spin_stop() {
    [ -n "${SPIN_PID:-}" ] || return 0

    : >"$SPIN_STOP_FILE" 2>/dev/null || :
    kill "$SPIN_PID" 2>/dev/null || :
    wait "$SPIN_PID" 2>/dev/null || :

    # Erase the indicator so the reply starts on a clean line. The stop file is
    # left for spin_start to clear, because a subshell removing it here would
    # release a loop the kill had not reached yet.
    printf '\r\033[K%s' "${SPIN_RESTORE:-}" >&2
    SPIN_PID=''
    return 0
}
