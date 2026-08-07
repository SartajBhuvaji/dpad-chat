#!/bin/sh
# Line editing for D-Pad Chat.
#
# The shell's `read` builtin leaves the terminal in canonical mode, where the
# kernel's line discipline owns both echo and editing. That discipline knows
# exactly one editing key, ERASE, and has no notion of escape sequences. Every
# other key on the on-screen keyboard arrives as several bytes, and all of them
# are echoed and appended to the message: Home sends `ESC [ H` and shows up at
# the prompt as gibberish.
#
# Canonical mode cannot be taught otherwise, so the terminal is switched to raw
# mode and this file does the work. It reads a byte at a time, renders the line
# itself, and consumes a multi-byte key as one unit. A key with no binding is
# discarded rather than typed.
#
# Only used when both ends are terminals. Piped input - the test suite, and
# `echo /about | tools/simulate.sh` - falls back to `read`, which is correct
# there: there is no terminal to put into raw mode and nothing to echo to.

# INPUT_LINE is this module's output, read by chat.sh once input_readline
# returns. Static analysis works one file at a time and cannot see that use.
# shellcheck disable=SC2034

# Bytes are read with `dd` rather than `read -n 1`. `-n` is a bashism that
# busybox ash happens to support and dash does not; the suite runs under dash
# and the device runs busybox, so one portable primitive keeps the code that is
# tested identical to the code that ships. The cost is a fork per keystroke,
# which at the speed anyone can type on a d-pad is not measurable.
INPUT_ESC=$(printf '\033')
INPUT_CR=$(printf '\r')
INPUT_DEL=$(printf '\177')
INPUT_EOT=$(printf '\004')

# Spelled out as a literal because command substitution strips trailing
# newlines: $(printf '\n') is the empty string.
INPUT_LF='
'

# Tenths of a second to wait for the rest of an escape sequence. A lone ESC has
# no continuation, so the follow-up read has to be able to give up or the app
# would hang until the next key. Long enough for bytes that are already in the
# buffer, short enough that nobody feels it.
INPUT_ESC_DELAY=2

# An escape sequence for a key is a handful of bytes. Anything longer is line
# noise, and without a ceiling a stuck terminal would spin here forever.
INPUT_SEQ_MAX=16

# Below two columns every column is a wrap boundary and the position arithmetic
# stops meaning anything. It is also what a terminal with no size reports, so
# this doubles as the "width unknown" case.
INPUT_MIN_COLS=2

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

input_init() {
    INPUT_LINE=''
    INPUT_KEY=''
    _INPUT_STTY=''
    INPUT_TTY=0
    INPUT_COLS=$(_input_detect_cols)
    INPUT_START_COL=0

    # stdin carries the keystrokes and stdout is where the line is drawn, so
    # both have to be a terminal. dd and stty are busybox builtins on the
    # device and coreutils elsewhere, but a missing one falls back rather than
    # failing: a working prompt with the old bugs beats no prompt at all.
    if [ -t 0 ] && [ -t 1 ] &&
        command -v stty >/dev/null 2>&1 &&
        command -v dd >/dev/null 2>&1; then
        INPUT_TTY=1
    fi

    return 0
}

# Erasing across a wrapped row needs the terminal's width: without it there is
# no way to tell that a wrap happened at all, let alone which column to move
# back to. Prefers ui.sh's already-detected value, which honours the COLUMNS
# override the harness uses to pin the device width.
#
# Reports 0 when the width cannot be established. Every caller treats that as
# "stay on one row" rather than guessing, because a wrong width would move the
# cursor to the wrong column and corrupt what is on screen.
_input_detect_cols() {
    _in_c="${UI_COLS:-}"

    if [ -z "$_in_c" ] && command -v stty >/dev/null 2>&1; then
        _in_c=$(stty size 2>/dev/null | cut -d' ' -f2)
    fi

    case "$_in_c" in
        '' | *[!0-9]*) _in_c=0 ;;
    esac

    [ "$_in_c" -ge "$INPUT_MIN_COLS" ] || _in_c=0
    printf '%s' "$_in_c"
}

# Raw mode is entered per line rather than held for the session. While a reply
# is downloading the terminal is back in its normal state, so a crash or a kill
# in the middle of a request cannot leave the user with a terminal that has no
# echo.
_input_raw_on() {
    _INPUT_STTY=$(stty -g 2>/dev/null) || _INPUT_STTY=''
    [ -n "$_INPUT_STTY" ] || return 1

    # -icanon hands over editing, -echo hands over rendering. ISIG is left
    # alone so Ctrl-C still interrupts, and the output flags are untouched so a
    # newline still returns the carriage. min 1 time 0 blocks until a key.
    stty -icanon -echo min 1 time 0 2>/dev/null || return 1
    return 0
}

# Safe to call at any time, including when raw mode was never entered. Wired
# into chat.sh's exit trap as well as the end of every read, because the trap
# is the only thing that runs if the app is killed mid-line.
input_restore() {
    [ -n "${_INPUT_STTY:-}" ] || return 0
    stty "$_INPUT_STTY" 2>/dev/null || :
    _INPUT_STTY=''
    return 0
}

# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------

# Reads one byte into _in_b. Returns non-zero at end of input.
_input_byte() {
    # Command substitution strips trailing newlines, which would make a newline
    # byte indistinguishable from end of input. The sentinel is appended and
    # then removed, so a newline reads back as "\nX" -> "\n" while end of input
    # reads back as "X" -> "".
    #
    # A NUL byte cannot be held in a shell variable and is dropped here. No key
    # on the on-screen keyboard produces one.
    _in_b=$(
        dd bs=1 count=1 2>/dev/null
        printf X
    )
    _in_b=${_in_b%X}

    [ -n "$_in_b" ] || return 1
    return 0
}

# Consumes the rest of an escape sequence, leaving it in INPUT_KEY without the
# leading ESC. Empty when the ESC stood alone.
#
# Nothing binds these yet, so every one of them is discarded - which is exactly
# what stops Home from typing. The parse still happens because the bytes have
# to be taken off the input either way; leaving them would put `[H` into the
# message instead of `ESC [ H`.
_input_escape() {
    INPUT_KEY=''

    stty min 0 time "$INPUT_ESC_DELAY" 2>/dev/null || :

    if _input_byte; then
        case "$_in_b" in
            '[')
                # CSI. Parameter bytes are digits and separators; the first
                # byte outside that set is the final byte naming the key.
                # Keyboard keys never use the intermediate byte range, so this
                # stays a two-case test rather than a full CSI parser.
                INPUT_KEY='['
                _in_n=0
                while [ "$_in_n" -lt "$INPUT_SEQ_MAX" ] && _input_byte; do
                    _in_n=$((_in_n + 1))
                    INPUT_KEY="$INPUT_KEY$_in_b"
                    case "$_in_b" in
                        [0-9] | ';') ;;
                        *) break ;;
                    esac
                done
                ;;
            O)
                # SS3, sent for the cursor keys when the terminal is in
                # application mode. Exactly one byte follows.
                INPUT_KEY='O'
                if _input_byte; then
                    INPUT_KEY="O$_in_b"
                fi
                ;;
            *)
                # Alt-modified key, or a stray ESC. Discarded whole.
                INPUT_KEY="$_in_b"
                ;;
        esac
    fi

    stty min 1 time 0 2>/dev/null || :
    return 0
}

# -----------------------------------------------------------------------------
# Editing
# -----------------------------------------------------------------------------

# Where the cursor is, in the terminal's own terms, is the whole difficulty
# here. The line starts at column INPUT_START_COL of some row, and from there
# the character at offset n of the buffer sits at absolute column
# INPUT_START_COL + n, which is row (that / INPUT_COLS), column (that %
# INPUT_COLS). That arithmetic is only trustworthy because of the wrap forced
# in _input_insert; see the note there.
#
# It holds for as long as every row of the line is still on screen. A line long
# enough to fill the scrolling region pushes its own first rows off the top,
# and erasing back into one of those would write where it used to be. That
# needs a full repaint to fix rather than better arithmetic, and it takes
# roughly 1400 characters to reach on the device, so it is left alone.
_input_insert() {
    INPUT_LINE="$INPUT_LINE$1"
    printf '%s' "$1"

    [ "$INPUT_COLS" -ge "$INPUT_MIN_COLS" ] || return 0

    # Filling the last column of a row does not move the cursor to the next
    # row. The terminal leaves it on the last column with the wrap pending and
    # acts on it only when the next character arrives, so at this moment the
    # cursor's row is genuinely ambiguous: it is one row above where the
    # arithmetic above says it is, until something else is printed.
    #
    # Forcing the wrap now settles it. The row the cursor moves to is the row
    # it was going to move to anyway on the next keystroke, so nothing is
    # displaced - and every relative move made afterwards starts from a
    # position that matches the arithmetic instead of being off by one.
    if [ $(((INPUT_START_COL + ${#INPUT_LINE}) % INPUT_COLS)) -eq 0 ]; then
        printf '\r\n'
    fi

    return 0
}

# Removes the character before the cursor from the buffer and from the screen.
#
# The line discipline used to do this with `\b \b`, which only ever works
# inside one row: at column 0 a backspace has nowhere to go, so the character
# at the end of the row above stayed on screen even though it had already been
# dropped from the message being sent. Moving up explicitly is what makes
# erasing continue across the boundary.
_input_erase() {
    [ -n "$INPUT_LINE" ] || return 0

    _in_len=${#INPUT_LINE}
    INPUT_LINE=${INPUT_LINE%?}

    if [ "$INPUT_COLS" -lt "$INPUT_MIN_COLS" ]; then
        # No width, so a wrap cannot be located. Rubbing the character out in
        # place is right on a single row and stuck at the boundary, which is
        # the old behaviour: a prompt that edits within one row beats one that
        # moves the cursor somewhere the terminal was not.
        printf '\b \b'
        return 0
    fi

    # Absolute column of the character being removed. The cursor is one column
    # further on, so the two can fall on different rows - which is exactly the
    # case that was broken.
    _in_at=$((INPUT_START_COL + _in_len - 1))
    _in_up=$(((_in_at + 1) / INPUT_COLS - _in_at / INPUT_COLS))
    _in_col=$((_in_at % INPUT_COLS + 1))

    [ "$_in_up" -eq 0 ] || printf '\033[%dA' "$_in_up"

    # Absolute column rather than backspaces: CHA lands on the column named
    # regardless of where the cursor started, and it clears any pending wrap
    # left over from the row above.
    printf '\033[%dG \033[%dG' "$_in_col" "$_in_col"
    return 0
}

# -----------------------------------------------------------------------------
# The read
# -----------------------------------------------------------------------------

# Reads one line into INPUT_LINE. Returns non-zero at end of input, which is
# how the REPL learns that `st` has exited or the pipe has closed.
#
# $1 is how many columns the prompt already drew on this row, so the editor
# knows which column the line starts in. Getting it wrong only misplaces the
# cursor by that much, so callers with no prompt can leave it out.
input_readline() {
    INPUT_LINE=''
    INPUT_START_COL=0

    # A prompt long enough to wrap leaves the cursor part-way along its last
    # row, and that row is the one the line starts on.
    if [ "$INPUT_COLS" -ge "$INPUT_MIN_COLS" ]; then
        case "${1:-0}" in
            '' | *[!0-9]*) ;;
            *) INPUT_START_COL=$(($1 % INPUT_COLS)) ;;
        esac
    fi

    if [ "${INPUT_TTY:-0}" -ne 1 ] || ! _input_raw_on; then
        IFS= read -r INPUT_LINE || return 1
        return 0
    fi

    _in_eof=0

    while :; do
        if ! _input_byte; then
            _in_eof=1
            break
        fi

        case "$_in_b" in
            "$INPUT_CR" | "$INPUT_LF")
                printf '\n'
                break
                ;;
            "$INPUT_ESC")
                _input_escape
                ;;
            "$INPUT_DEL")
                _input_erase
                ;;
            "$INPUT_EOT")
                # End of input, but only on an empty line: the same rule the
                # line discipline applied, so Ctrl-D over SSH still quits.
                if [ -z "$INPUT_LINE" ]; then
                    _in_eof=1
                    break
                fi
                ;;
            [[:cntrl:]])
                # Every other control byte is a key this app does not bind.
                # Printing it would corrupt the display.
                ;;
            *)
                _input_insert "$_in_b"
                ;;
        esac
    done

    input_restore

    [ "$_in_eof" -eq 0 ] || return 1
    return 0
}
