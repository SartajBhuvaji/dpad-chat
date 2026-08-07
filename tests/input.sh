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
export REPO_ROOT DRIVER_OUT DRIVER_PROMPT_COLS DRIVER_COLS

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

if ! command -v python3 >/dev/null 2>&1; then
    printf '  skipped: python3 not installed\n'
elif ! keys 'probe\r' || [ "$KEYS_LINE" != 'probe' ]; then
    printf '  skipped: no pseudo-terminal available here\n'
else
    assert_eq 'a typed line is read' "$KEYS_LINE" 'probe'
    assert_eq 'the terminal was taken raw' "$KEYS_RAW" '1'
    assert_eq 'the terminal is handed back' "$KEYS_TTY" 'restored'
    assert_eq 'the editor draws what was typed' "$KEYS_ECHO" "$(printf 'probe\r\n')"

    # Issue #19. Home is `ESC [ H`, and in canonical mode all four bytes were
    # echoed and appended. It must now leave no trace at all.
    keys 'ab\033[Hcd\r'
    assert_eq 'Home does not reach the message' "$KEYS_LINE" 'abcd'
    assert_not_contains 'Home draws nothing' "$KEYS_ECHO" "$ESC"
    assert_not_contains 'no stray bracket from Home' "$KEYS_ECHO" '['

    # The other form of the same key, sent depending on terminal mode.
    keys 'ab\033[1~cd\r'
    assert_eq 'the other Home encoding is dropped too' "$KEYS_LINE" 'abcd'
    assert_not_contains 'and it draws nothing either' "$KEYS_ECHO" '~'

    # Not bound until #22, but they must already be consumed whole rather than
    # typed.
    keys 'ab\033[A\033[B\033[C\033[D\r'
    assert_eq 'arrow keys are consumed, not typed' "$KEYS_LINE" 'ab'
    assert_not_contains 'arrow keys draw nothing' "$KEYS_ECHO" "$ESC"

    # Cursor keys arrive as SS3 rather than CSI when the terminal is in
    # application mode, which is a property of the mode and not of the key.
    keys 'ab\033OAcd\r'
    assert_eq 'the SS3 form is consumed too' "$KEYS_LINE" 'abcd'

    # A parameterised sequence: the digits and the separator are parameters,
    # and the letter ends it. Stopping at the wrong byte would leave the rest
    # to be typed.
    keys 'a\033[1;5Cb\r'
    assert_eq 'parameters are part of the sequence' "$KEYS_LINE" 'ab'

    keys 'x\033[38;5;120my\r'
    assert_eq 'a long parameter list is consumed' "$KEYS_LINE" 'xy'

    keys 'abc\177\r'
    assert_eq 'backspace removes the last character' "$KEYS_LINE" 'ab'

    # Column 3 holds the `c`: the cursor goes there, writes a space over it and
    # comes back. Naming the column rather than backspacing is what lets the
    # same code step onto the row above.
    assert_contains 'backspace writes over the character' \
        "$KEYS_ECHO" "$(printf '\033[3G \033[3G')"
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
    # prefix rather than the whole sequence would fire on these.
    keys 'abc\033[2~\033[4~\033[5~\033[6~\r'
    assert_eq 'the keys either side of Del do not delete' "$KEYS_LINE" 'abc'

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
    assert_eq 'and are not drawn' "$KEYS_ECHO" "$(printf 'ab\r\n')"

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
    assert_contains 'onto the last column of it' \
        "$KEYS_ECHO" "$(printf '\033[10G \033[10G')"

    # The whole exchange, byte for byte, because the assertions above each
    # cover one part of it and would all still pass if the parts arrived in the
    # wrong order. Reading left to right: the ten characters; the wrap forced
    # once the row is full; up one row, over to the last column, a space over
    # the character, back to the column; then the newline that submits.
    #
    # The doubled carriage returns are the terminal's own doing - ONLCR turns
    # every newline written into one - and are what the capture really holds.
    assert_eq 'the erase is drawn exactly this way' "$KEYS_ECHO" \
        "$(printf 'abcdefghij\r\r\n\033[1A\033[10G \033[10G\r\n')"

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
    assert_contains 'by rubbing the character out in place' \
        "$KEYS_ECHO" "$(printf '\b \b')"
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
