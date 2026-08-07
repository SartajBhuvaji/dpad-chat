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
INPUT_EOT=$(printf '\004')

# The two bytes a terminal sends for the key marked Backspace. Which one it is
# depends on how the terminal was built rather than on anything visible to the
# user, so both are bound: guessing wrong leaves the key doing nothing at all.
INPUT_DEL=$(printf '\177')
INPUT_BS=$(printf '\010')

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
    _input_reset_line
    _input_recall_init

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
# back to.
#
# The same three sources ui.sh uses, in the same order, because the editor and
# the renderer disagreeing about how wide a row is would put the wrap in two
# different places. ui.sh's already-detected value comes first so that in the
# app there is only ever one answer; the rest is for this file used alone.
#
# COLUMNS before the terminal, since it is how the harness and
# tools/simulate.sh pin a device-shaped width onto a terminal that is not one.
#
# Reports 0 when the width cannot be established. Every caller treats that as
# "stay on one row" rather than guessing, because a wrong width would move the
# cursor to the wrong column and corrupt what is on screen.
_input_detect_cols() {
    _in_c="${UI_COLS:-}"
    [ -n "$_in_c" ] || _in_c="${COLUMNS:-}"

    if [ -z "$_in_c" ] && command -v stty >/dev/null 2>&1; then
        # Not simply the terminal's own answer under busybox: its stty falls
        # back to $COLUMNS when the window size is unset, which is why that is
        # read above rather than left to surface here as a different number.
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
# Parsing and binding are separate on purpose. The bytes have to come off the
# input whether or not the key means anything - leaving them would put `[H`
# into the message instead of `ESC [ H` - so this consumes the sequence, and
# input_readline decides what, if anything, it does. A key with no binding is
# discarded by having nothing act on it, which is what stops Home from typing.
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

# The line is held as two halves split at the cursor: INPUT_HEAD is what is
# before it, INPUT_TAIL what is at and after it. Every edit is then a parameter
# expansion on one end of one half, and the cursor's offset is ${#INPUT_HEAD}.
#
# The obvious alternative - one string and an integer offset - needs a
# substring of it on every keystroke, and the shell has no cheap way to take
# one. Splitting the string is where the cursor already is.
_input_reset_line() {
    INPUT_HEAD=''
    INPUT_TAIL=''

    # Where the cursor was left and how long the line was when it was last
    # drawn. The redraw needs both: one to find its way back to the start of
    # the line, the other to know how much of what is on screen is stale.
    _INPUT_DRAWN_POS=0
    _INPUT_DRAWN_LEN=0
}

# Where the cursor is, in the terminal's own terms, is the whole difficulty
# here. The line starts at column INPUT_START_COL of some row, and from there
# offset n sits at absolute column INPUT_START_COL + n, which is row (that /
# INPUT_COLS), column (that % INPUT_COLS).
#
# That holds for as long as every row of the line is still on screen. A line
# long enough to fill the scrolling region pushes its own first rows off the
# top, and editing back into one of those would write where it used to be. It
# takes roughly 1400 characters to reach on the device, so it is left alone.

# Moves the cursor from offset $1 of the line to offset $2, which is never to
# the right of it: the redraw walks back to the start, and then back from the
# end of what it printed to where the cursor belongs.
_input_move_back() {
    if [ "$INPUT_COLS" -lt "$INPUT_MIN_COLS" ]; then
        # No width means no rows to speak of, so the line is treated as the one
        # row it is until it wraps. Backspace is the only move available.
        _mv_n=$(($1 - $2))
        while [ "$_mv_n" -gt 0 ]; do
            printf '\b'
            _mv_n=$((_mv_n - 1))
        done
        return 0
    fi

    _mv_from=$((INPUT_START_COL + $1))
    _mv_to=$((INPUT_START_COL + $2))
    _mv_up=$((_mv_from / INPUT_COLS - _mv_to / INPUT_COLS))

    [ "$_mv_up" -eq 0 ] || printf '\033[%dA' "$_mv_up"

    # Absolute column rather than a count of backspaces: CHA lands on the
    # column named regardless of where the cursor started, and it clears any
    # pending wrap left over from the row above.
    printf '\033[%dG' $((_mv_to % INPUT_COLS + 1))
    return 0
}

# Redraws the whole line and leaves the cursor where the buffer says it is.
#
# Working out the smallest update for each operation was reasonable while the
# cursor could only be at the end. It is not now: inserting mid-line shifts the
# whole tail right and deleting shifts it left, so nearly every edit touches
# the rest of the line anyway. One path that is always right beats several that
# are each nearly so, and the cost is one printf - against the fork this file
# already does for every byte it reads, which is far more expensive.
_input_redraw() {
    _rd_all="$INPUT_HEAD$INPUT_TAIL"
    _rd_len=${#_rd_all}
    _rd_cur=${#INPUT_HEAD}

    # Whatever the line used to be longer by is still on screen behind it.
    # Spaces cover it, which is cheaper than erasing to the end of each row the
    # line occupies - and erasing to end of display would take the status bar
    # with it.
    _rd_pad=0
    if [ "$_INPUT_DRAWN_LEN" -gt "$_rd_len" ]; then
        _rd_pad=$((_INPUT_DRAWN_LEN - _rd_len))
    fi

    _input_move_back "$_INPUT_DRAWN_POS" 0

    printf '%s' "$_rd_all"
    _rd_i=0
    while [ "$_rd_i" -lt "$_rd_pad" ]; do
        printf ' '
        _rd_i=$((_rd_i + 1))
    done

    _rd_printed=$((_rd_len + _rd_pad))

    # Filling the last column of a row does not move the cursor to the next
    # row. The terminal leaves it there with the wrap pending and acts on it
    # only when the next character arrives, so at this moment the cursor's row
    # is genuinely ambiguous - it is one row above where the arithmetic says it
    # is. Forcing the wrap settles it, and moves the cursor to the row it was
    # going to move to anyway, so nothing is displaced.
    if [ "$INPUT_COLS" -ge "$INPUT_MIN_COLS" ] && [ "$_rd_printed" -gt 0 ] &&
        [ $(((INPUT_START_COL + _rd_printed) % INPUT_COLS)) -eq 0 ]; then
        printf '\r\n'
    fi

    _input_move_back "$_rd_printed" "$_rd_cur"

    _INPUT_DRAWN_POS="$_rd_cur"
    _INPUT_DRAWN_LEN="$_rd_len"
    return 0
}

# -----------------------------------------------------------------------------
# Editing, all relative to the cursor
# -----------------------------------------------------------------------------

_input_insert() {
    INPUT_HEAD="$INPUT_HEAD$1"
    _input_redraw
}

# Backspace: the character behind the cursor.
_input_erase() {
    [ -n "$INPUT_HEAD" ] || return 0
    INPUT_HEAD=${INPUT_HEAD%?}
    _input_redraw
}

# Del. Forward delete - the character the cursor is on, with the rest of the
# line pulled left - is what the key means where a cursor can sit mid-line.
# At the end of the line there is nothing in front of it, and that is where the
# key is most often pressed, so it erases behind instead of doing nothing.
_input_delete() {
    if [ -z "$INPUT_TAIL" ]; then
        _input_erase
        return 0
    fi

    INPUT_TAIL=${INPUT_TAIL#?}
    _input_redraw
}

# Both ends are clamped by having nothing to move: the halves are only ever
# rebalanced when the side being taken from is non-empty.
_input_left() {
    [ -n "$INPUT_HEAD" ] || return 0

    # The last character of HEAD, by removing everything that is not it.
    _lf_c=${INPUT_HEAD#"${INPUT_HEAD%?}"}
    INPUT_HEAD=${INPUT_HEAD%?}
    INPUT_TAIL="$_lf_c$INPUT_TAIL"
    _input_redraw
}

_input_right() {
    [ -n "$INPUT_TAIL" ] || return 0

    _rt_c=${INPUT_TAIL%"${INPUT_TAIL#?}"}
    INPUT_TAIL=${INPUT_TAIL#?}
    INPUT_HEAD="$INPUT_HEAD$_rt_c"
    _input_redraw
}

_input_home() {
    [ -n "$INPUT_HEAD" ] || return 0
    INPUT_TAIL="$INPUT_HEAD$INPUT_TAIL"
    INPUT_HEAD=''
    _input_redraw
}

# Guarded like the rest so that submitting a line the cursor is already at the
# end of - which is most of them - draws nothing at all.
_input_end() {
    [ -n "$INPUT_TAIL" ] || return 0
    INPUT_HEAD="$INPUT_HEAD$INPUT_TAIL"
    INPUT_TAIL=''
    _input_redraw
}

# -----------------------------------------------------------------------------
# Recalling what was sent
# -----------------------------------------------------------------------------

# Every character costs several d-pad presses, so resending or amending an
# earlier line is worth far more here than it is on a desk keyboard.
#
# This is an editing convenience and nothing else. It is held in memory for the
# session and never written down: data/history.json is the model's context, and
# what was typed at the prompt is not the same question as what the
# conversation contains.
#
# The list is newline-separated with the most recent first, which is the order
# Up walks. Lines cannot themselves contain a newline - the editor submits on
# one - so nothing needs escaping.
INPUT_RECALL_MAX=50

_input_recall_init() {
    INPUT_RECALL=''
    INPUT_RECALL_N=0

    # 0 is the line being typed now, which is not in the list. 1 is the most
    # recent entry, and so on.
    INPUT_RECALL_AT=0

    # What was being typed when the walk started, so Down can come back to it.
    INPUT_RECALL_LIVE=''
}

# Records a line as recallable. Called by the REPL for what it accepts, so
# commands are remembered along with questions - retyping /update on a d-pad is
# exactly the kind of thing this is for.
input_remember() {
    [ -n "${1:-}" ] || return 0

    # Repeating the same line twice running would otherwise need two presses of
    # Up to get past.
    [ "$1" != "${INPUT_RECALL%%"$INPUT_LF"*}" ] || return 0

    INPUT_RECALL="$1$INPUT_LF$INPUT_RECALL"
    INPUT_RECALL_N=$((INPUT_RECALL_N + 1))

    [ "$INPUT_RECALL_N" -gt "$INPUT_RECALL_MAX" ] || return 0

    # Drop the oldest by keeping only the first MAX entries. A session long
    # enough to reach this is not one where the fiftieth-oldest line is wanted.
    _rm_keep=''
    _rm_rest="$INPUT_RECALL"
    _rm_i=0
    while [ "$_rm_i" -lt "$INPUT_RECALL_MAX" ]; do
        _rm_keep="$_rm_keep${_rm_rest%%"$INPUT_LF"*}$INPUT_LF"
        _rm_rest=${_rm_rest#*"$INPUT_LF"}
        _rm_i=$((_rm_i + 1))
    done

    INPUT_RECALL="$_rm_keep"
    INPUT_RECALL_N="$INPUT_RECALL_MAX"
    return 0
}

# The $1'th entry, counting the most recent as 1.
_input_recall_entry() {
    _re_rest="$INPUT_RECALL"
    _re_i=1

    while [ "$_re_i" -lt "$1" ]; do
        _re_rest=${_re_rest#*"$INPUT_LF"}
        _re_i=$((_re_i + 1))
    done

    printf '%s' "${_re_rest%%"$INPUT_LF"*}"
}

# Replaces the line with $1 and puts the cursor at the end of it, which is
# where it is wanted for amending what was recalled.
_input_recall_show() {
    INPUT_HEAD="$1"
    INPUT_TAIL=''
    _input_redraw
}

_input_recall_up() {
    [ "$INPUT_RECALL_AT" -lt "$INPUT_RECALL_N" ] || return 0

    # Leaving the live line for the first time, so keep it to come back to.
    if [ "$INPUT_RECALL_AT" -eq 0 ]; then
        INPUT_RECALL_LIVE="$INPUT_HEAD$INPUT_TAIL"
    fi

    INPUT_RECALL_AT=$((INPUT_RECALL_AT + 1))
    _input_recall_show "$(_input_recall_entry "$INPUT_RECALL_AT")"
}

_input_recall_down() {
    [ "$INPUT_RECALL_AT" -gt 0 ] || return 0

    INPUT_RECALL_AT=$((INPUT_RECALL_AT - 1))

    if [ "$INPUT_RECALL_AT" -eq 0 ]; then
        _input_recall_show "$INPUT_RECALL_LIVE"
        return 0
    fi

    _input_recall_show "$(_input_recall_entry "$INPUT_RECALL_AT")"
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

    # Defaulted once, into a variable: the argument is optional, and under
    # `set -u` a bare $1 anywhere below would abort the session rather than
    # fall back to zero.
    _in_p="${1:-0}"

    # A prompt long enough to wrap leaves the cursor part-way along its last
    # row, and that row is the one the line starts on.
    if [ "$INPUT_COLS" -ge "$INPUT_MIN_COLS" ]; then
        case "$_in_p" in
            '' | *[!0-9]*) ;;
            *) INPUT_START_COL=$((_in_p % INPUT_COLS)) ;;
        esac
    fi

    if [ "${INPUT_TTY:-0}" -ne 1 ] || ! _input_raw_on; then
        IFS= read -r INPUT_LINE || return 1
        return 0
    fi

    _input_reset_line

    # A walk through the recall list belongs to the line it was started from,
    # not to the session.
    INPUT_RECALL_AT=0
    INPUT_RECALL_LIVE=''

    _in_eof=0

    while :; do
        if ! _input_byte; then
            _in_eof=1
            break
        fi

        case "$_in_b" in
            "$INPUT_CR" | "$INPUT_LF")
                # The cursor can be anywhere in the line now, and the newline
                # goes wherever it is. Moving to the end first is what keeps
                # the reply from being printed over the tail of the question.
                _input_end
                printf '\n'
                break
                ;;
            "$INPUT_ESC")
                _input_escape

                # Both encodings of every cursor key. Which one arrives depends
                # on whether the terminal is in application cursor key mode,
                # which is a property of the mode and not of the key, so
                # binding one form would leave the key dead in the other.
                case "$INPUT_KEY" in
                    '[D' | 'OD') _input_left ;;
                    '[C' | 'OC') _input_right ;;
                    '[A' | 'OA') _input_recall_up ;;
                    '[B' | 'OB') _input_recall_down ;;

                    # Home and End. #19 made Home a no-op deliberately, because
                    # there was nowhere else for the cursor to be; now there is.
                    '[H' | 'OH' | '[1~' | '[7~') _input_home ;;
                    '[F' | 'OF' | '[4~' | '[8~') _input_end ;;

                    '[3~') _input_delete ;;

                    # Every other sequence is a key with no binding. Consumed
                    # by the parse above, which is what stops it being typed.
                    *) ;;
                esac
                ;;
            "$INPUT_DEL" | "$INPUT_BS")
                _input_erase
                ;;
            "$INPUT_EOT")
                # End of input, but only on an empty line: the same rule the
                # line discipline applied, so Ctrl-D over SSH still quits.
                if [ -z "$INPUT_HEAD$INPUT_TAIL" ]; then
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

    INPUT_LINE="$INPUT_HEAD$INPUT_TAIL"

    [ "$_in_eof" -eq 0 ] || return 1
    return 0
}
