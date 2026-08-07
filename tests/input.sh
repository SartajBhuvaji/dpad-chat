#!/bin/sh
# Checks for the line editor.
#
# Two halves, because the module has two modes. The piped half exercises the
# fallback, which is what the rest of the suite and `echo /about | simulate.sh`
# run through. The terminal half drives a real pty via tests/keys.py, because
# raw mode, echo and escape sequences do not exist without one - and those are
# precisely the parts that were broken on the device.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide.
# shellcheck source-path=SCRIPTDIR

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok    %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    [ -z "${2:-}" ] || printf '        %s\n' "$2"
}

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find '$3' in '$2'" ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect '$3' in '$2'" ;;
        *) pass "$1" ;;
    esac
}

# -----------------------------------------------------------------------------

printf 'Running input tests\n'

ESC=$(printf '\033')

# -----------------------------------------------------------------------------
# Piped input: the fallback
# -----------------------------------------------------------------------------

printf '\nFalling back without a terminal\n'

# Run in a subshell so the module's variables do not leak between cases.
piped() {
    (
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        # Called bare on purpose: the prompt width is optional, and this is
        # what exercises the default.
        # shellcheck disable=SC2119
        if input_readline; then
            printf '0:%s' "$INPUT_LINE"
        else
            printf '1:%s' "$INPUT_LINE"
        fi
    )
}

assert_eq 'a piped line is read' "$(printf 'hello\n' | piped)" '0:hello'
assert_eq 'end of input is reported' "$(printf '' | piped)" '1:'
assert_eq 'spacing is left alone' "$(printf '  two words  \n' | piped)" '0:  two words  '
assert_eq 'a backslash is not an escape' "$(printf 'a\\b\n' | piped)" '0:a\b'

# The bug this whole module exists for: without a terminal there is nothing to
# put into raw mode, so the bytes are taken literally rather than parsed.
assert_eq 'escapes are literal when piped' \
    "$(printf 'a\033[Hb\n' | piped)" "0:a${ESC}[Hb"

# The prompt width is an optional argument, and the arithmetic using it only
# runs once a width is known. A bare $1 in there is fatal under `set -u`, which
# every script here and the app itself run with - but with no width the block
# is skipped and nothing springs the trap, so one is pinned to make sure it is
# reached with no argument to find.
assert_eq 'a bare call is safe once a width is known' \
    "$(printf 'hi\n' | (
        # Local to this subshell on purpose: the width is for this one case and
        # must not follow the rest of the file.
        # shellcheck disable=SC2030
        COLUMNS=40
        export COLUMNS
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        # shellcheck disable=SC2119
        input_readline && printf '0:%s' "$INPUT_LINE"
    ))" '0:hi'

# There is nothing to draw a suggestion on and nothing to press Right with, so
# the fallback must not put one anywhere near the line. The whole suite reads
# lines through this path, so a suggestion leaking into one here would be a
# question nobody asked being sent.
assert_eq 'a suggestion cannot reach a piped line' \
    "$(printf 'typed\n' | (
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        input_suggest 'ghost'
        # shellcheck disable=SC2119
        input_readline && printf '0:%s' "$INPUT_LINE"
    ))" '0:typed'

assert_eq 'no terminal means no raw mode' \
    "$(printf 'x\n' | (
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        printf '%s' "$INPUT_TTY"
    ))" '0'

# -----------------------------------------------------------------------------
# A real terminal
# -----------------------------------------------------------------------------

printf '\nReading from a terminal\n'

DRIVER="$WORK_DIR/driver.sh"
cat >"$DRIVER" <<'DRIVER_EOF'
#!/bin/sh
set -eu
# shellcheck source=/dev/null
. "$REPO_ROOT/app/lib/input.sh"

# The harness pins COLUMNS to the device width for the whole suite, so a case
# wanting a different one - or none at all - has to say so here.
if [ -n "${DRIVER_COLS:-}" ]; then
    COLUMNS="$DRIVER_COLS"
    export COLUMNS
else
    unset COLUMNS
fi

input_init
input_suggest "${DRIVER_SUGGEST:-}"

before=$(stty -g)
if input_readline "${DRIVER_PROMPT_COLS:-0}"; then
    rc=0
else
    rc=1
fi
after=$(stty -g)

{
    printf 'rc=%s\n' "$rc"
    printf 'raw=%s\n' "$INPUT_TTY"
    printf 'cols=%s\n' "$INPUT_COLS"
    if [ "$before" = "$after" ]; then
        printf 'tty=restored\n'
    else
        printf 'tty=changed\n'
    fi
    printf 'line=%s\n' "$INPUT_LINE"
} >"$DRIVER_OUT"
DRIVER_EOF
chmod +x "$DRIVER"

DRIVER_OUT="$WORK_DIR/driver.out"
DRIVER_PROMPT_COLS=0
DRIVER_COLS=''
DRIVER_SUGGEST=''
export REPO_ROOT DRIVER_OUT DRIVER_PROMPT_COLS DRIVER_COLS DRIVER_SUGGEST

# Types the given keystrokes at a pty and leaves the outcome in KEYS_RC,
# KEYS_LINE and KEYS_ECHO. KEYS_ECHO is everything the editor drew, with none
# of the kernel's own echo mixed in; see tests/keys.py for how that is arranged.
#
# $2 is the terminal width, defaulting to something wide enough that nothing
# wraps. The wrap cases pass a small one so a boundary is a few keys away.
#
# $3 says where the editor should find that width: `env` puts it in COLUMNS,
# the way the harness and tools/simulate.sh do, and `tty` leaves the terminal
# as the only thing that knows. Both have to work, and which one answers has to
# be the same everywhere - busybox's stty consults COLUMNS itself when the
# window size is unset, so a case that left both in play would read 40 under
# the harness and 10 here.
keys() {
    _k_cols="${2:-80}"

    case "${3:-env}" in
        env) DRIVER_COLS="$_k_cols" ;;
        *) DRIVER_COLS='' ;;
    esac
    export DRIVER_COLS

    : >"$DRIVER_OUT"
    KEYS_ECHO=$("$REPO_ROOT/tests/keys.py" --cols "$_k_cols" --input "$1" \
        -- "$DRIVER" 2>/dev/null) || :
    KEYS_RC=$(sed -n 's/^rc=//p' "$DRIVER_OUT")
    KEYS_LINE=$(sed -n 's/^line=//p' "$DRIVER_OUT")
    KEYS_TTY=$(sed -n 's/^tty=//p' "$DRIVER_OUT")
    KEYS_RAW=$(sed -n 's/^raw=//p' "$DRIVER_OUT")
    KEYS_COLS=$(sed -n 's/^cols=//p' "$DRIVER_OUT")
}

# Recall cannot be exercised in a single read: there has to be something to
# recall. This driver reads lines until end of input, remembering each the way
# the REPL does, and reports every line it read.
SESSION="$WORK_DIR/session.sh"
cat >"$SESSION" <<'SESSION_EOF'
#!/bin/sh
set -eu
# shellcheck source=/dev/null
. "$REPO_ROOT/app/lib/input.sh"

if [ -n "${DRIVER_COLS:-}" ]; then
    COLUMNS="$DRIVER_COLS"
    export COLUMNS
else
    unset COLUMNS
fi

input_init
input_suggest "${DRIVER_SUGGEST:-}"
: >"$DRIVER_OUT"

while input_readline "${DRIVER_PROMPT_COLS:-0}"; do
    printf 'line=%s\n' "$INPUT_LINE" >>"$DRIVER_OUT"
    input_remember "$INPUT_LINE"
done
SESSION_EOF
chmod +x "$SESSION"

# Types keystrokes at that driver and prints every line it read, one per line.
# End the input with \004 - Ctrl-D on an empty line - or the driver waits for
# the capture to time out instead of finishing.
session() {
    : >"$DRIVER_OUT"
    DRIVER_COLS="${2:-80}"
    export DRIVER_COLS
    "$REPO_ROOT/tests/keys.py" --cols "${2:-80}" --input "$1" \
        -- "$SESSION" >/dev/null 2>&1 || :
    sed -n 's/^line=//p' "$DRIVER_OUT"
}

if ! command -v python3 >/dev/null 2>&1; then
    printf '  skipped: python3 not installed\n'
elif ! keys 'probe\r' || [ "$KEYS_LINE" != 'probe' ]; then
    printf '  skipped: no pseudo-terminal available here\n'
else
    assert_eq 'a typed line is read' "$KEYS_LINE" 'probe'
    assert_eq 'the terminal was taken raw' "$KEYS_RAW" '1'
    assert_eq 'the terminal is handed back' "$KEYS_TTY" 'restored'

    # Every edit redraws the line and then puts the cursor back where the
    # buffer says it is, so what a keystroke draws is the line so far bracketed
    # by two absolute column moves. Spelled out once, here, rather than at every
    # case below: the rest assert on the line, which is what the user sees.
    keys 'ab\r'
    assert_eq 'the editor draws what was typed' "$KEYS_ECHO" \
        "$(printf '\033[1Ga\033[2G\033[1Gab\033[3G\r\n')"

    # Issue #19 stopped Home typing its bytes. #22 gives it a real binding, so
    # it now moves the cursor to the start and typing goes in front.
    keys 'ab\033[HX\r'
    assert_eq 'Home moves to the start of the line' "$KEYS_LINE" 'Xab'
    assert_not_contains 'and none of its bytes are typed' "$KEYS_ECHO" '~'

    # The forms of Home and End differ by terminal mode, not by key.
    for _home in '\033[H' '\033OH' '\033[1~' '\033[7~'; do
        keys "ab${_home}X\r"
        assert_eq "Home as ${_home} reaches the start" "$KEYS_LINE" 'Xab'
    done

    for _end in '\033[F' '\033OF' '\033[4~' '\033[8~'; do
        keys "ab\033[H${_end}Z\r"
        assert_eq "End as ${_end} reaches the end" "$KEYS_LINE" 'abZ'
    done

    # A parameterised sequence: the digits and the separator are parameters,
    # and the letter ends it. Stopping at the wrong byte would leave the rest
    # to be typed.
    keys 'a\033[1;5Cb\r'
    assert_eq 'parameters are part of the sequence' "$KEYS_LINE" 'ab'

    keys 'x\033[38;5;120my\r'
    assert_eq 'a long parameter list is consumed' "$KEYS_LINE" 'xy'

    keys 'abc\177\r'
    assert_eq 'backspace removes the last character' "$KEYS_LINE" 'ab'

    # The redraw prints what is left and then a space to cover the character
    # that went, so the shortened line and the cover are one write.
    assert_contains 'backspace covers the character that went' \
        "$KEYS_ECHO" "$(printf '\033[1Gab \033[3G')"
    assert_not_contains 'and nothing moves rows on a line that never wrapped' \
        "$KEYS_ECHO" "$(printf '\033[1A')"

    keys '\177\177x\r'
    assert_eq 'backspace on an empty line is harmless' "$KEYS_LINE" 'x'

    # -------------------------------------------------------------------------
    # Issue #21: Del, and the other byte for Backspace
    # -------------------------------------------------------------------------

    printf '\nDeleting\n'

    # `ESC [ 3 ~` used to be echoed as its four bytes and appended to the
    # message. It deletes now.
    keys 'abc\033[3~\r'
    assert_eq 'Del removes a character' "$KEYS_LINE" 'ab'
    assert_not_contains 'and types nothing' "$KEYS_ECHO" '~'

    keys '\033[3~x\r'
    assert_eq 'Del on an empty line is harmless' "$KEYS_LINE" 'x'

    keys 'abcde\033[3~\177\033[3~\r'
    assert_eq 'Del and backspace are interchangeable here' "$KEYS_LINE" 'ab'

    # Which byte the key marked Backspace sends is a property of the terminal,
    # not of the key. Before this, one of the two did nothing.
    keys 'abc\010\r'
    assert_eq 'the other backspace byte erases too' "$KEYS_LINE" 'ab'

    keys 'ab\010\010\010\010c\r'
    assert_eq 'and it stops at the start of the line' "$KEYS_LINE" 'c'

    # Del goes through the same erase as backspace, so it crosses a wrapped row
    # rather than stalling at the boundary the way it would have.
    keys 'abcdefghij\033[3~\r' 10
    assert_eq 'Del crosses a wrap' "$KEYS_LINE" 'abcdefghi'
    assert_contains 'stepping up to the row above' "$KEYS_ECHO" "$(printf '\033[1A')"

    keys 'abcdefghij\010\r' 10
    assert_eq 'and so does the other backspace byte' "$KEYS_LINE" 'abcdefghi'

    # A modified Del - Ctrl-Del here - is a different key and is not bound.
    # Matching it loosely would delete on a keypress nobody asked to delete on.
    keys 'abc\033[3;5~\r'
    assert_eq 'a modified Del is left unbound' "$KEYS_LINE" 'abc'
    assert_not_contains 'and still types nothing' "$KEYS_ECHO" '~'

    # The neighbouring sequences differ from Del by one byte. Binding on a
    # prefix rather than the whole sequence would fire on these. `[4~` is End
    # and does move the cursor, so it is checked separately above.
    keys 'abc\033[2~\033[5~\033[6~\r'
    assert_eq 'the keys either side of Del do not delete' "$KEYS_LINE" 'abc'

    # -------------------------------------------------------------------------
    # Issue #22: moving the cursor
    # -------------------------------------------------------------------------

    printf '\nMoving the cursor\n'

    keys 'ab\033[Dc\r'
    assert_eq 'Left moves back, and typing inserts there' "$KEYS_LINE" 'acb'

    keys 'abc\033[D\033[D\033[CX\r'
    assert_eq 'Right moves forward again' "$KEYS_LINE" 'abXc'

    # Both encodings, which depend on terminal mode rather than on the key.
    keys 'ab\033ODc\r'
    assert_eq 'the SS3 form of Left moves too' "$KEYS_LINE" 'acb'

    keys 'abc\033[D\033OCX\r'
    assert_eq 'and the SS3 form of Right' "$KEYS_LINE" 'abcX'

    # Clamped at both ends by having nothing left to move.
    keys 'ab\033[D\033[D\033[D\033[DX\r'
    assert_eq 'Left stops at the start of the line' "$KEYS_LINE" 'Xab'

    keys 'ab\033[C\033[CX\r'
    assert_eq 'Right stops at the end' "$KEYS_LINE" 'abX'

    # Erase and delete are relative to the cursor, so where it sits decides
    # which character goes.
    keys 'abc\033[D\177\r'
    assert_eq 'backspace takes the character behind the cursor' "$KEYS_LINE" 'ac'

    keys 'abc\033[D\033[3~\r'
    assert_eq 'and Del takes the one under it' "$KEYS_LINE" 'ab'

    keys 'abc\033[H\033[3~\r'
    assert_eq 'Del at the start of the line deletes forward' "$KEYS_LINE" 'bc'

    keys 'abc\033[H\177\r'
    assert_eq 'backspace at the start has nothing to take' "$KEYS_LINE" 'abc'

    # Submitting with the cursor part-way along must send the whole line, and
    # must put the newline after the end of it - not where the cursor is, which
    # would leave the tail on screen for the reply to be printed over.
    keys 'abc\033[D\033[D\r'
    assert_eq 'the whole line is submitted from mid-line' "$KEYS_LINE" 'abc'
    assert_contains 'and the cursor goes to the end before the newline' \
        "$KEYS_ECHO" "$(printf '\033[4G\r\n')"

    # The cursor has to cross wrapped rows the same way erasing does.
    keys 'abcdefghijk\033[D\033[D\033[DX\r' 10
    assert_eq 'Left crosses a wrap' "$KEYS_LINE" 'abcdefghXijk'
    assert_contains 'stepping up a row to do it' "$KEYS_ECHO" "$(printf '\033[1A')"

    keys 'abcdefghijkl\033[HX\r' 10
    assert_eq 'Home crosses back over two rows' "$KEYS_LINE" 'Xabcdefghijkl'

    keys 'abcdefghijkl\033[H\033[FZ\r' 10
    assert_eq 'and End returns across them' "$KEYS_LINE" 'abcdefghijklZ'

    # -------------------------------------------------------------------------
    # Issue #22: recalling what was sent
    # -------------------------------------------------------------------------

    printf '\nRecalling\n'

    assert_eq 'Up recalls the line before' \
        "$(session 'one\rtwo\r\033[A\r\004')" "$(printf 'one\ntwo\ntwo')"

    assert_eq 'Up twice reaches the one before that' \
        "$(session 'one\rtwo\r\033[A\033[A\r\004')" "$(printf 'one\ntwo\none')"

    assert_eq 'Up stops at the oldest line' \
        "$(session 'one\r\033[A\033[A\033[A\r\004')" "$(printf 'one\none')"

    # The line being typed is kept when the walk starts, so Down comes back to
    # it rather than to an empty prompt.
    assert_eq 'Down returns to what was being typed' \
        "$(session 'one\rliv\033[A\033[B\r\004')" "$(printf 'one\nliv')"

    assert_eq 'Down on the live line does nothing' \
        "$(session 'one\rx\033[B\r\004')" "$(printf 'one\nx')"

    # What is recalled is a starting point, not a fixed choice: the cursor
    # lands at the end of it so it can be added to.
    assert_eq 'a recalled line can be edited' \
        "$(session 'one\r\033[AX\r\004')" "$(printf 'one\noneX')"

    assert_eq 'and the cursor is at the end of it' \
        "$(session 'abc\r\033[A\033[HX\r\004')" "$(printf 'abc\nXabc')"

    # Sending the same line twice would otherwise cost two presses of Up to
    # get past.
    assert_eq 'the same line twice is remembered once' \
        "$(session 'a\rb\rb\r\033[A\033[A\r\004')" "$(printf 'a\nb\nb\na')"

    # A walk belongs to the line it was started from. If the position carried
    # over, this Down would restore the previous line's saved live text - which
    # was empty - instead of leaving Z alone.
    assert_eq 'the walk starts again on the next line' \
        "$(session 'a\rb\r\033[A\rZ\033[B\r\004')" "$(printf 'a\nb\nb\nZ')"

    # Commands are recallable too: retyping /update on a d-pad is exactly what
    # this is for. The REPL is what calls input_remember, so this checks the
    # editor keeps whatever it is given rather than filtering it.
    assert_eq 'a command is recallable like anything else' \
        "$(session '/update\r\033[A\r\004')" "$(printf '/update\n/update')"

    # Ctrl-D keeps the meaning the line discipline gave it, so quitting over
    # SSH still works.
    keys '\004'
    assert_eq 'Ctrl-D on an empty line ends input' "$KEYS_RC" '1'

    keys 'kept\004\r'
    assert_eq 'Ctrl-D mid-line does not end input' "$KEYS_RC" '0'
    assert_eq 'and does not disturb the line' "$KEYS_LINE" 'kept'

    # An unbound control byte - Ctrl-G here - would ring the bell or corrupt
    # the display if it were echoed.
    keys 'a\007b\r'
    assert_eq 'unbound control bytes are ignored' "$KEYS_LINE" 'ab'
    assert_not_contains 'and are not drawn' "$KEYS_ECHO" "$(printf '\007')"

    keys 'a\tb\r'
    assert_eq 'tab is not typed into the line' "$KEYS_LINE" 'ab'

    # Enter arrives as CR from the terminal and as LF through some paths;
    # both submit.
    keys 'crlf\n'
    assert_eq 'a newline submits as well' "$KEYS_LINE" 'crlf'

    keys '\r'
    assert_eq 'an empty line is a line, not end of input' "$KEYS_RC" '0'
    assert_eq 'and it is empty' "$KEYS_LINE" ''

    # The other way input ends on a terminal - `st` closing - arrives as
    # SIGHUP and kills the shell outright, so there is no return value left to
    # assert on. The end-of-input path itself is covered by Ctrl-D above and by
    # the piped cases.

    # ESC followed by an ordinary key is Alt-key: unbound, so the whole thing
    # goes, rather than the ESC being dropped and the letter typed.
    keys 'a\033zb\r'
    assert_eq 'an Alt-key combination is dropped whole' "$KEYS_LINE" 'ab'

    # Without a ceiling on the sequence length a terminal stuck mid-sequence
    # would spin here forever.
    keys 'a\033[111111111111111111111111Zb\r'
    assert_eq 'an overlong sequence still terminates' "$KEYS_RC" '0'

    # -------------------------------------------------------------------------
    # Suggesting an opening
    # -------------------------------------------------------------------------

    printf '\nSuggesting an opening\n'

    # The suggestion is drawn but is not the line. Everything here turns on
    # that distinction, so it is asserted first and from both sides: what
    # reached the screen, and what reached INPUT_LINE.
    DRIVER_SUGGEST='hi'
    export DRIVER_SUGGEST

    keys '\r'
    assert_eq 'a suggestion is not in the line' "$KEYS_LINE" ''
    assert_contains 'but it is drawn, dimmed' "$KEYS_ECHO" \
        "$(printf '\033[2mhi\033[0m')"
    # Drawn, then the cursor sent back to where the line starts, so what is
    # typed next goes in front of it rather than after it.
    assert_contains 'with the cursor left at the start of the line' \
        "$KEYS_ECHO" "$(printf '\033[1G\033[2mhi\033[0m\033[1G')"

    keys '\033[C\r'
    assert_eq 'Right takes it' "$KEYS_LINE" 'hi '

    keys '\033OC\r'
    assert_eq 'in either encoding' "$KEYS_LINE" 'hi '

    # The space is the point: what follows a suggestion is the user's own
    # words, and having to press for the space between them would give back
    # part of what accepting it saved.
    keys '\033[Cthere\r'
    assert_eq 'and leaves the cursor ready to carry on' "$KEYS_LINE" 'hi there'

    # Accepting is a one-off, not a rebinding of Right. Once the suggestion has
    # gone the key is a cursor move again.
    keys '\033[Cx\033[D\033[CY\r'
    assert_eq 'after which Right is a cursor move again' "$KEYS_LINE" 'hi xY'

    # Anything else dismisses. Typing is the ordinary case: the character
    # typed is the whole line, with no trace of the suggestion in it.
    keys 'x\r'
    assert_eq 'typing dismisses it' "$KEYS_LINE" 'x'
    assert_contains 'covering it with spaces' "$KEYS_ECHO" \
        "$(printf '\033[1G  \033[1G')"

    # Keys that do nothing on an empty line still have to take it off the
    # screen, and they are the ones that would not have redrawn otherwise.
    for _dismiss in '\033[D' '\033[H' '\033[F' '\033[3~' '\033[2~' '\177'; do
        keys "${_dismiss}\r"
        assert_eq "dismissed by ${_dismiss}, leaving nothing behind" \
            "$KEYS_LINE" ''
        assert_contains "and ${_dismiss} covers it" "$KEYS_ECHO" \
            "$(printf '\033[1G  \033[1G')"
    done

    # Up is bound to recall, which replaces the line. The suggestion has to be
    # gone before that happens or its columns would still be counted against a
    # line it is no longer part of.
    assert_eq 'recall dismisses it rather than appending to it' \
        "$(session 'one\r\033[A\r\004')" "$(printf 'one\none')"

    # Offered once. The second prompt of the session has none, so Right there
    # is a cursor move on an empty line and does nothing.
    assert_eq 'the offer is made once per session' \
        "$(session '\033[C\r\033[C\r\004')" "$(printf 'hi \n')"

    # A suggestion that exactly fills the row leaves the terminal with a wrap
    # pending, the same ambiguity the line itself has at a boundary. Covering
    # it has to force that wrap too, or the spaces would land a row high.
    DRIVER_SUGGEST='abcdefghij'
    export DRIVER_SUGGEST

    keys 'z\r' 10
    assert_eq 'a suggestion that fills the row is dismissed cleanly' \
        "$KEYS_LINE" 'z'
    # Left to right: over to the first column of the row the line starts on;
    # ten spaces covering the ghost; the wrap forced, because those ten fill
    # the row and the terminal would otherwise leave the cursor on it with the
    # wrap still pending; and back up to where the line starts. Without the
    # forced wrap the step up would be one row too many and the prompt would
    # be typed over.
    assert_contains 'forcing the wrap the cover would otherwise leave pending' \
        "$KEYS_ECHO" "$(printf '\033[1G          \r\r\n\033[1A\033[1G')"

    # Column arithmetic here counts characters as columns, which multi-byte
    # text breaks, and a control byte would be an escape the terminal obeys
    # rather than text it draws. Refused, and the prompt is simply plain.
    DRIVER_SUGGEST=$(printf 'caf\303\251')
    export DRIVER_SUGGEST

    keys 'x\r'
    assert_eq 'a suggestion that is not printable ASCII is refused' \
        "$KEYS_LINE" 'x'
    assert_not_contains 'and nothing of it is drawn' "$KEYS_ECHO" 'caf'

    DRIVER_SUGGEST=$(printf 'a\033[31mb')
    export DRIVER_SUGGEST

    keys 'x\r'
    assert_not_contains 'nor is one carrying an escape sequence' \
        "$KEYS_ECHO" '[31m'

    # Ghost text that cannot be dimmed is indistinguishable from what the user
    # typed, which is worse than no suggestion at all.
    DRIVER_SUGGEST='hi'
    export DRIVER_SUGGEST
    NO_COLOR=1
    export NO_COLOR

    keys '\033[Cx\r'
    assert_eq 'NO_COLOR means no offer' "$KEYS_LINE" 'x'
    assert_not_contains 'and nothing is drawn to dismiss' "$KEYS_ECHO" 'hi'

    unset NO_COLOR

    # An invisible ghost that still costs a keystroke to dismiss. This is what
    # a template emptied out to turn the feature off arrives as.
    DRIVER_SUGGEST='   '
    export DRIVER_SUGGEST

    keys '\033[Cx\r'
    assert_eq 'a suggestion of nothing but spaces is refused' "$KEYS_LINE" 'x'

    DRIVER_SUGGEST=''
    export DRIVER_SUGGEST

    keys 'x\r'
    assert_eq 'no suggestion set is the prompt as it was' "$KEYS_LINE" 'x'

    # -------------------------------------------------------------------------
    # Issue #20: erasing across a wrapped row
    # -------------------------------------------------------------------------

    printf '\nErasing across a wrap\n'

    # Ten columns, so a boundary is ten keys away instead of eighty.
    keys 'abc\r' 10
    assert_eq 'the width is taken from COLUMNS' "$KEYS_COLS" '10'

    # And from the terminal itself when nothing has pinned one, which is how
    # the app runs on the device.
    keys 'abc\r' 10 tty
    assert_eq 'or from the terminal when COLUMNS says nothing' "$KEYS_COLS" '10'

    # The case from the report. Ten characters exactly fill the row, so the
    # cursor is at the start of the next one and the character to remove is on
    # the row above. `\b` could not get there and the character stayed on
    # screen after it had already left the message.
    keys 'abcdefghij\177\r' 10
    assert_eq 'the character at the boundary is removed' "$KEYS_LINE" 'abcdefghi'
    assert_contains 'and erasing steps up to the row above' \
        "$KEYS_ECHO" "$(printf '\033[1A')"
    # The erase byte for byte, because the assertions above each cover one part
    # of it and would all still pass if the parts arrived in the wrong order.
    # Reading left to right: up onto the row the line starts on and over to its
    # first column; the nine characters that are left, then a space covering
    # the tenth; the wrap forced again because those ten still fill the row;
    # and back up to the column the cursor now belongs in.
    #
    # The doubled carriage returns are the terminal's own doing - ONLCR turns
    # every newline written into one - and are what the capture really holds.
    assert_contains 'the erase is drawn in this order' "$KEYS_ECHO" \
        "$(printf '\033[1A\033[1Gabcdefghi \r\r\n\033[1A\033[10G')"

    # One short of the boundary: same line, no wrap involved, so nothing should
    # move rows. This is what proves the step up is driven by the arithmetic
    # rather than emitted on every erase.
    keys 'abcdefghi\177\r' 10
    assert_eq 'a character below the boundary is removed too' "$KEYS_LINE" 'abcdefgh'
    assert_not_contains 'without changing rows' "$KEYS_ECHO" "$(printf '\033[1A')"

    # Three rows, erased back to the first. Both boundaries have to be crossed,
    # and the buffer has to survive twenty erases in a row.
    keys 'abcdefghijklmnopqrstuvwxy\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177\r' 10
    assert_eq 'erasing runs back through more than one wrap' "$KEYS_LINE" 'abcde'

    # Erasing the whole thing away must not walk off the top of the line: the
    # buffer empties and further presses do nothing.
    keys 'abcdefghijkl\177\177\177\177\177\177\177\177\177\177\177\177\177\177\177ok\r' 10
    assert_eq 'erasing past the start stops at the start' "$KEYS_LINE" 'ok'

    # With a prompt in front of it the line no longer starts at column 0, so
    # the boundary arrives earlier. Eight characters after a two-column prompt
    # fill the row.
    DRIVER_PROMPT_COLS=2
    keys 'abcdefgh\177\r' 10
    assert_eq 'a prompt shifts where the row ends' "$KEYS_LINE" 'abcdefg'
    assert_contains 'and erasing still steps up' "$KEYS_ECHO" "$(printf '\033[1A')"

    # The same eight characters with no prompt do not reach the boundary,
    # which is what shows the prompt width is being applied rather than ignored.
    DRIVER_PROMPT_COLS=0
    keys 'abcdefgh\177\r' 10
    assert_not_contains 'and without the prompt they do not reach it' \
        "$KEYS_ECHO" "$(printf '\033[1A')"

    # A width too small to hold a wrap, which is how a terminal that cannot say
    # how wide it is arrives here. Wraps cannot be located, so the editor stays
    # on one row rather than moving the cursor somewhere it guessed.
    #
    # Pinned through COLUMNS rather than by leaving the terminal unsized,
    # because the two implementations disagree on what an unsized terminal
    # reports: coreutils stty prints 0, and busybox substitutes 80 rather than
    # admitting it does not know. Only the pinned form means the same thing in
    # both places - and on the device that busybox fallback is why the width
    # always resolves to something.
    keys 'abc\177\r' 0
    assert_eq 'too narrow to wrap is reported as zero' "$KEYS_COLS" '0'
    assert_eq 'and the line is still edited' "$KEYS_LINE" 'ab'
    # Backspaces only. Without a width there is no way to know which row any
    # column is on, so the cursor is never moved by an escape that names one.
    assert_contains 'using backspaces to get about' "$KEYS_ECHO" "$(printf '\b')"
    assert_not_contains 'and never naming a row or column' "$KEYS_ECHO" "$ESC"
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
